/// EPUB ingestion guardrails — defends against OOM and zip-bomb-style
/// inputs before [EpubExtractor] hands the bytes to `epub_pro` (which
/// transitively decompresses + decodes every manifest entry).
///
/// Layered defenses, in firing order:
///   1. **EOCD parse + ZIP64 rejection.** Parses the End-Of-Central-
///      Directory record (and rejects archives that carry ZIP64 markers,
///      since legitimate EPUBs never need ZIP64). Throws if the EOCD is
///      missing.
///   2. **Pre-decode central-directory walk.** Walks the cdir region
///      [cdir_offset, cdir_offset + cdir_size) and counts CDH records by
///      their `PK\x01\x02` signature, bailing at `maxEntries + 1`. This
///      bounds the [ArchiveFile] graph that [ZipDecoder] will allocate
///      *regardless* of what `total_entries` claims — `ZipDecoder` itself
///      walks until `cdir_size` bytes are consumed, not by entry count,
///      so `total_entries` is not a reliable bound.
///   3. **File-size cap.** Applied at the caller layer (CLI does
///      `stat()`; mobile holds bytes already and checks `bytes.length`).
///   4. **Per-entry declared-size cap** (`_perEntryMaxBytes`). Rejects
///      any single entry whose central-directory `uncompressedSize` claim
///      is implausibly large.
///   5. **Per-entry compression-ratio cap** (`_maxPerEntryRatio`).
///      Rejects when `entry.size / entry.rawContent.length` exceeds the
///      ratio. Catches "lying central directory" bombs where
///      `uncompressedSize` is honest but the decompressed payload is
///      vastly larger than the compressed bytes; equivalently catches
///      attackers disguising text-deflate bombs as `.png`/`.font` etc.
///      since legitimate binary content rarely exceeds 2× DEFLATE ratio.
///   6. **Cumulative declared-bytes cap** (`maxTextBytes`). Sums
///      `entry.size` across all entries (incl. binaries — `epub_pro`
///      eagerly loads them). Defends against honest-large payloads.
///
/// Residual risk (acknowledged):
///
/// All caps above trust either the central-directory `uncompressedSize`
/// claim or its ratio against compressed bytes. A sophisticated attacker
/// can craft a deflate stream whose CDH `uncompressedSize` is honest but
/// whose actual decompressed output exceeds `_maxPerEntryRatio`, OR
/// whose CDH `uncompressedSize` is *low* (passing both per-entry size
/// and ratio caps) while the deflate stream actually expands far beyond
/// it. In either case `epub_pro` will inflate the real bytes after this
/// guard returns, which can cause a process-OOM if the attacker hits the
/// DEFLATE-spec theoretical max (~1032×).
///
/// **Threat-model classification:** this is a bounded availability
/// (DoS) risk, NOT an integrity / confidentiality / RCE risk. The
/// file-size cap (default 100 MB) ceilings worst-case decompressed
/// output at ~100 GB, which crashes the host process but does not
/// compromise data, escape the sandbox, or persist past the run. CLI
/// users see a non-zero exit; mobile users see an import error. No
/// data corruption, no code execution.
///
/// **Closing the residual** requires bounded inflation of the actual
/// deflate stream — Phase 4 TODO: replace metadata-trust caps with
/// `dart:io` `ZLibCodec.startChunkedConversion` driving a custom sink
/// that aborts when cumulative output exceeds `maxTextBytes`. Also fold
/// in per-entry ZIP64 (0x0001) CDH extra-field rejection at that point.
///
/// `maxDataUriBytes` is consumed by the (Phase 4) image extractor.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Default thresholds. Match plan §4 Phase 3.
const int defaultEpubMaxBytes = 100 * 1024 * 1024; // 100 MB
const int defaultEpubMaxEntries = 5000;
const int defaultEpubMaxTextBytes = 200 * 1024 * 1024; // 200 MB
const int defaultEpubMaxDataUriBytes = 10 * 1024 * 1024; // 10 MB

/// Per-entry hard cap on declared uncompressed size (50 MB). Larger than
/// the largest legitimate single EPUB chapter, font, or chapter-image,
/// smaller than typical zip-bomb single-entry payloads.
const int _perEntryMaxBytes = 50 * 1024 * 1024;

/// Maximum permitted per-entry expansion ratio
/// (`uncompressedSize / compressedSize`). Real EPUB content typically
/// deflates 1×–15×; rare extreme outliers (e.g. all-zero CSS files) hit
/// ~30×. A 100× cap is generous enough for any honest content while
/// catching obvious DEFLATE bombs that pack megabytes of decompressed
/// output into kilobytes of compressed bytes.
const int _maxPerEntryRatio = 100;

/// Maximum bytes per central-directory header we count toward the
/// pre-decode cdir-size sanity gate. Used when no `cdir_offset` is
/// available; the more accurate signature-count walk takes precedence
/// when offset/size are present.
const int _maxBytesPerCentralDirHeader = 512;

/// Tunable limits.
class EpubGuardLimits {
  final int maxBytes;
  final int maxEntries;
  final int maxTextBytes;
  final int maxDataUriBytes;

  const EpubGuardLimits({
    this.maxBytes = defaultEpubMaxBytes,
    this.maxEntries = defaultEpubMaxEntries,
    this.maxTextBytes = defaultEpubMaxTextBytes,
    this.maxDataUriBytes = defaultEpubMaxDataUriBytes,
  });

  /// Build limits from a string-keyed map (typically `Platform.environment`).
  /// Unrecognized keys are ignored. Invalid integer values throw
  /// [FormatException] so misconfiguration surfaces loudly rather than
  /// silently using defaults.
  factory EpubGuardLimits.fromEnv(Map<String, String> env) {
    int parse(String key, int fallback) {
      final raw = env[key];
      if (raw == null || raw.isEmpty) return fallback;
      final parsed = int.tryParse(raw.trim());
      if (parsed == null || parsed <= 0) {
        throw FormatException(
          '$key must be a positive integer (got "$raw")',
        );
      }
      return parsed;
    }

    return EpubGuardLimits(
      maxBytes: parse('EPUB_MAX_BYTES', defaultEpubMaxBytes),
      maxEntries: parse('EPUB_MAX_ENTRIES', defaultEpubMaxEntries),
      maxTextBytes: parse('EPUB_MAX_TEXT_BYTES', defaultEpubMaxTextBytes),
      maxDataUriBytes: parse(
        'EPUB_MAX_DATA_URI_BYTES',
        defaultEpubMaxDataUriBytes,
      ),
    );
  }
}

/// Thrown when an EPUB exceeds an [EpubGuardLimits] threshold. The CLI
/// translates this to exit-code 64; mobile surfaces it as an import error.
class EpubGuardException implements Exception {
  final String message;
  const EpubGuardException(this.message);

  @override
  String toString() => 'EpubGuardException: $message';
}

/// Enforce archive-level guards on raw EPUB bytes. Throws
/// [EpubGuardException] on violation. Does not modify the input.
void enforceArchiveGuards(Uint8List bytes, EpubGuardLimits limits) {
  // (1) EOCD parse + ZIP64 rejection.
  final eocd = _parseEocd(bytes);
  if (eocd == null) {
    throw const EpubGuardException(
      'EPUB archive has no readable End-Of-Central-Directory record',
    );
  }
  // ZIP64 is signaled by any of these magic values appearing in the
  // standard EOCD's u16/u32 fields, OR by a ZIP64 EOCD locator
  // (signature 0x07064b50) preceding the EOCD. Legitimate EPUBs never
  // need ZIP64; reject unconditionally.
  if (eocd.totalEntries == 0xFFFF ||
      eocd.centralDirSize == 0xFFFFFFFF ||
      eocd.centralDirOffset == 0xFFFFFFFF ||
      _hasZip64Locator(bytes, eocd.eocdOffset)) {
    throw const EpubGuardException(
      'EPUB declares ZIP64-sized fields or carries a ZIP64 locator; '
      'not supported (legitimate EPUBs do not need ZIP64)',
    );
  }
  if (eocd.totalEntries > limits.maxEntries) {
    throw EpubGuardException(
      'EPUB declares ${eocd.totalEntries} archive entries, exceeds '
      'EPUB_MAX_ENTRIES=${limits.maxEntries}',
    );
  }

  // (2) Pre-decode cdir signature walk. Counts actual CDH records in the
  // [cdir_offset, cdir_offset + cdir_size) region. ZipDecoder walks the
  // same region until cdir_size bytes are consumed (not via
  // total_entries), so this count is what actually constrains its
  // ArchiveFile allocation. Bails at `maxEntries + 1` so the worst-case
  // pre-decode walk is bounded.
  final actualCount = _countCentralDirectoryHeaders(
    bytes,
    eocd.centralDirOffset,
    eocd.centralDirSize,
    limits.maxEntries + 1,
  );
  if (actualCount > limits.maxEntries) {
    throw EpubGuardException(
      'EPUB central directory contains > ${limits.maxEntries} '
      'records (signature scan); exceeds EPUB_MAX_ENTRIES.',
    );
  }
  // Defense-in-depth: if cdir is implausibly large for the declared
  // entry count (e.g., padded with non-CDH bytes that signature-walk
  // skipped), still bound the walk.
  final maxAllowedCdirSize = limits.maxEntries * _maxBytesPerCentralDirHeader;
  if (eocd.centralDirSize > maxAllowedCdirSize) {
    throw EpubGuardException(
      'EPUB central directory size ${eocd.centralDirSize} bytes exceeds '
      'plausible bound (EPUB_MAX_ENTRIES=${limits.maxEntries} × '
      '$_maxBytesPerCentralDirHeader bytes/header = $maxAllowedCdirSize)',
    );
  }

  // Now safe to decode.
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: false);
  } catch (e) {
    throw EpubGuardException('failed to read EPUB archive: $e');
  }

  // Defense-in-depth: re-check actual entries count after decode.
  if (archive.length > limits.maxEntries) {
    throw EpubGuardException(
      'EPUB has ${archive.length} archive entries, exceeds '
      'EPUB_MAX_ENTRIES=${limits.maxEntries}',
    );
  }

  // (4)+(5)+(6) Per-entry caps + cumulative declared cap.
  var declaredSum = 0;
  for (final entry in archive) {
    if (!entry.isFile) continue;

    // Per-entry declared-size hard cap.
    if (entry.size > _perEntryMaxBytes) {
      throw EpubGuardException(
        'EPUB entry "${entry.name}" declares uncompressed size '
        '${entry.size}, exceeds per-entry cap $_perEntryMaxBytes',
      );
    }

    // Per-entry compression-ratio cap. `entry.rawContent.length` is the
    // on-disk compressed bytes — physically present in the archive,
    // cannot lie. A high `entry.size / compressed` ratio indicates
    // either a deflate bomb or a deeply pathological compression payload.
    final raw = entry.rawContent;
    if (raw != null) {
      final compressedLen = raw.length;
      if (compressedLen > 0 &&
          entry.size > compressedLen * _maxPerEntryRatio) {
        throw EpubGuardException(
          'EPUB entry "${entry.name}" expansion ratio '
          '${entry.size}/$compressedLen exceeds max $_maxPerEntryRatio',
        );
      }
    }

    // Cumulative declared-bytes cap. Includes ALL entries (binaries
    // count too, since `epub_pro` eagerly loads them via `readContent`).
    declaredSum += entry.size;
    if (declaredSum > limits.maxTextBytes) {
      throw EpubGuardException(
        'EPUB cumulative declared payload exceeds '
        'EPUB_MAX_TEXT_BYTES=${limits.maxTextBytes} '
        '(declaredSum=$declaredSum after entry "${entry.name}")',
      );
    }
  }
}

/// Parsed End-Of-Central-Directory record fields used by guards.
class _Eocd {
  /// Offset of EOCD signature in the original byte buffer.
  final int eocdOffset;
  final int totalEntries;
  final int centralDirSize;
  final int centralDirOffset;
  const _Eocd({
    required this.eocdOffset,
    required this.totalEntries,
    required this.centralDirSize,
    required this.centralDirOffset,
  });
}

/// Parse the EOCD record at the end of [bytes]. Returns `null` if no
/// EOCD signature is found in the last 64 KiB + 22 bytes (which means
/// the archive is malformed or the EOCD is past the legal comment
/// region).
///
/// EOCD layout (PK\x05\x06):
///   off  0  u32   signature
///   off  4  u16   disk number
///   off  6  u16   disk where central dir starts
///   off  8  u16   this disk's central dir entries count
///   off 10  u16   total central dir entries count
///   off 12  u32   central dir size (bytes)
///   off 16  u32   central dir offset (from disk start)
///   off 20  u16   comment length
///   ...           comment ...
_Eocd? _parseEocd(Uint8List bytes) {
  if (bytes.length < 22) return null;
  final lastIdx = bytes.length - 22;
  final firstIdx = lastIdx >= 0xFFFF ? lastIdx - 0xFFFF : 0;
  for (var i = lastIdx; i >= firstIdx; i--) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4B &&
        bytes[i + 2] == 0x05 &&
        bytes[i + 3] == 0x06) {
      final totalEntries = bytes[i + 10] | (bytes[i + 11] << 8);
      final cdirSize = bytes[i + 12] |
          (bytes[i + 13] << 8) |
          (bytes[i + 14] << 16) |
          (bytes[i + 15] << 24);
      final cdirOffset = bytes[i + 16] |
          (bytes[i + 17] << 8) |
          (bytes[i + 18] << 16) |
          (bytes[i + 19] << 24);
      return _Eocd(
        eocdOffset: i,
        totalEntries: totalEntries,
        centralDirSize: cdirSize,
        centralDirOffset: cdirOffset,
      );
    }
  }
  return null;
}

/// Returns true if a ZIP64 EOCD locator (signature 0x07064b50,
/// PK\x06\x07) is present immediately preceding the EOCD record.
bool _hasZip64Locator(Uint8List bytes, int eocdOffset) {
  // The ZIP64 EOCD locator is a fixed 20-byte record.
  final locOffset = eocdOffset - 20;
  if (locOffset < 0) return false;
  return bytes[locOffset] == 0x50 &&
      bytes[locOffset + 1] == 0x4B &&
      bytes[locOffset + 2] == 0x06 &&
      bytes[locOffset + 3] == 0x07;
}

/// Count CDH records (signature `PK\x01\x02`, 0x504b0102 LE) by
/// walking the cdir region [start, start + size). Stops walking at
/// `maxToCount` records so the worst-case pre-decode loop is bounded.
///
/// Returns the count, capped at `maxToCount`. The caller compares to
/// its `maxEntries` threshold.
int _countCentralDirectoryHeaders(
  Uint8List bytes,
  int start,
  int size,
  int maxToCount,
) {
  if (start < 0 || size < 0) return 0;
  final end = start + size;
  if (end > bytes.length) return 0;
  var count = 0;
  var i = start;
  // CDH record minimum is 46 bytes; on each match we read the
  // variable-length fields to advance to the next record.
  while (i + 46 <= end) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4B &&
        bytes[i + 2] == 0x01 &&
        bytes[i + 3] == 0x02) {
      count++;
      if (count > maxToCount) return count;
      final fnLen = bytes[i + 28] | (bytes[i + 29] << 8);
      final exLen = bytes[i + 30] | (bytes[i + 31] << 8);
      final cmLen = bytes[i + 32] | (bytes[i + 33] << 8);
      i += 46 + fnLen + exLen + cmLen;
    } else {
      // Non-CDH bytes mid-region: stop scanning. ZipDecoder also
      // stops here.
      break;
    }
  }
  return count;
}
