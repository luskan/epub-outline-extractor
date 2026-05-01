import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:test/test.dart';

void main() {
  group('EpubGuardLimits.fromEnv', () {
    test('uses defaults for missing keys', () {
      final l = EpubGuardLimits.fromEnv(const {});
      expect(l.maxBytes, defaultEpubMaxBytes);
      expect(l.maxEntries, defaultEpubMaxEntries);
      expect(l.maxTextBytes, defaultEpubMaxTextBytes);
      expect(l.maxDataUriBytes, defaultEpubMaxDataUriBytes);
    });

    test('parses positive integers', () {
      final l = EpubGuardLimits.fromEnv(const {
        'EPUB_MAX_BYTES': '1048576',
        'EPUB_MAX_ENTRIES': '10',
        'EPUB_MAX_TEXT_BYTES': '512',
        'EPUB_MAX_DATA_URI_BYTES': '64',
      });
      expect(l.maxBytes, 1048576);
      expect(l.maxEntries, 10);
      expect(l.maxTextBytes, 512);
      expect(l.maxDataUriBytes, 64);
    });

    test('rejects non-positive / non-numeric values', () {
      expect(
        () => EpubGuardLimits.fromEnv(const {'EPUB_MAX_BYTES': '0'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => EpubGuardLimits.fromEnv(const {'EPUB_MAX_ENTRIES': '-3'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => EpubGuardLimits.fromEnv(const {'EPUB_MAX_TEXT_BYTES': 'abc'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('enforceArchiveGuards', () {
    test('passes a small valid zip', () {
      final bytes = _makeZip([
        ArchiveFile('a.html', 4, utf8.encode('<p/>')),
        ArchiveFile('b.xhtml', 5, utf8.encode('<p/>x')),
      ]);
      enforceArchiveGuards(bytes, const EpubGuardLimits());
    });

    test('rejects bytes with no EOCD signature', () {
      final bytes = Uint8List(200);
      expect(
        () => enforceArchiveGuards(bytes, const EpubGuardLimits()),
        throwsA(
          isA<EpubGuardException>().having(
            (e) => e.message,
            'message',
            contains('End-Of-Central-Directory'),
          ),
        ),
      );
    });

    test('rejects ZIP64 marker on entry-count field', () {
      final bytes = _makeZip([
        ArchiveFile('a.html', 4, utf8.encode('<p/>')),
      ]).toList();
      final eocd = _findEocd(bytes);
      bytes[eocd + 10] = 0xFF;
      bytes[eocd + 11] = 0xFF;
      expect(
        () => enforceArchiveGuards(
          Uint8List.fromList(bytes),
          const EpubGuardLimits(),
        ),
        throwsA(
          isA<EpubGuardException>().having(
            (e) => e.message,
            'message',
            contains('ZIP64'),
          ),
        ),
      );
    });

    test('rejects ZIP64 marker on cdir-size field (0xFFFFFFFF)', () {
      final bytes = _makeZip([
        ArchiveFile('a.html', 4, utf8.encode('<p/>')),
      ]).toList();
      final eocd = _findEocd(bytes);
      bytes[eocd + 12] = 0xFF;
      bytes[eocd + 13] = 0xFF;
      bytes[eocd + 14] = 0xFF;
      bytes[eocd + 15] = 0xFF;
      expect(
        () => enforceArchiveGuards(
          Uint8List.fromList(bytes),
          const EpubGuardLimits(),
        ),
        throwsA(
          isA<EpubGuardException>().having(
            (e) => e.message,
            'message',
            contains('ZIP64'),
          ),
        ),
      );
    });

    test('rejects ZIP64 marker on cdir-offset field (0xFFFFFFFF)', () {
      final bytes = _makeZip([
        ArchiveFile('a.html', 4, utf8.encode('<p/>')),
      ]).toList();
      final eocd = _findEocd(bytes);
      bytes[eocd + 16] = 0xFF;
      bytes[eocd + 17] = 0xFF;
      bytes[eocd + 18] = 0xFF;
      bytes[eocd + 19] = 0xFF;
      expect(
        () => enforceArchiveGuards(
          Uint8List.fromList(bytes),
          const EpubGuardLimits(),
        ),
        throwsA(
          isA<EpubGuardException>().having(
            (e) => e.message,
            'message',
            contains('ZIP64'),
          ),
        ),
      );
    });

    test('rejects ZIP64 EOCD locator preceding the regular EOCD', () {
      // Build a valid zip then splice 20 bytes of ZIP64 locator
      // (signature PK\x06\x07) immediately before the EOCD.
      final raw = _makeZip([
        ArchiveFile('a.html', 4, utf8.encode('<p/>')),
      ]).toList();
      final eocdIdx = _findEocd(raw);
      final z64Loc = <int>[
        0x50, 0x4B, 0x06, 0x07, // signature
        ...List.filled(16, 0),
      ];
      final patched = <int>[
        ...raw.sublist(0, eocdIdx),
        ...z64Loc,
        ...raw.sublist(eocdIdx),
      ];
      expect(
        () => enforceArchiveGuards(
          Uint8List.fromList(patched),
          const EpubGuardLimits(),
        ),
        throwsA(
          isA<EpubGuardException>().having(
            (e) => e.message,
            'message',
            contains('ZIP64'),
          ),
        ),
      );
    });

    test('rejects when EOCD declares total_entries > maxEntries', () {
      final entries = <ArchiveFile>[
        for (var i = 0; i < 6; i++)
          ArchiveFile('e$i.txt', 1, utf8.encode('x')),
      ];
      final bytes = _makeZip(entries);
      expect(
        () => enforceArchiveGuards(
          bytes,
          const EpubGuardLimits(maxEntries: 5),
        ),
        throwsA(
          isA<EpubGuardException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('EPUB_MAX_ENTRIES=5'),
              contains('declares 6 archive entries'),
            ),
          ),
        ),
      );
    });

    test('forged EOCD with low total_entries but actual cdir contains '
        'many CDH records — pre-decode signature scan fires', () {
      // Build a real zip with 100 entries then patch EOCD to claim
      // total_entries=1. The signature-walk (not total_entries) is the
      // bound that constrains ZipDecoder's allocation, so this must be
      // rejected by the cdir signature count.
      final entries = <ArchiveFile>[
        for (var i = 0; i < 100; i++)
          ArchiveFile('e$i.html', 4, utf8.encode('<p/>')),
      ];
      final raw = _makeZip(entries).toList();
      final eocd = _findEocd(raw);
      raw[eocd + 10] = 0x01;
      raw[eocd + 11] = 0x00;
      expect(
        () => enforceArchiveGuards(
          Uint8List.fromList(raw),
          const EpubGuardLimits(maxEntries: 5),
        ),
        throwsA(
          isA<EpubGuardException>().having(
            (e) => e.message,
            'message',
            contains('central directory contains > 5'),
          ),
        ),
      );
    });

    test('rejects when cumulative declared bytes exceed maxTextBytes '
        'for ALL entries (binaries counted too)', () {
      final big = utf8.encode('a' * 200);
      final bytes = _makeZip([
        // Both types included in cumulative cap now — codex round 3.
        ArchiveFile('img.png', big.length, big),
      ]);
      expect(
        () => enforceArchiveGuards(
          bytes,
          const EpubGuardLimits(maxTextBytes: 100),
        ),
        throwsA(
          isA<EpubGuardException>().having(
            (e) => e.message,
            'message',
            contains('EPUB_MAX_TEXT_BYTES=100'),
          ),
        ),
      );
    });

    test('per-entry declared-size cap rejects single huge entry', () {
      // We can synthesize a case where the per-entry cap fires before
      // the cumulative cap: very large maxTextBytes, but a single entry
      // exceeds the per-entry cap of 50 MB. The fixture file would be
      // huge to construct in-test; instead we exercise the cap
      // indirectly by inflating the entry header's `uncompressedSize`
      // claim via a zip-bytes patch.
      final raw = _makeZip([
        ArchiveFile('big.html', 100, utf8.encode('a' * 100)),
      ]).toList();
      // Find the CDH record for big.html and patch the
      // `uncompressedSize` field (offset 24, u32 LE) to 0x04000000
      // (64 MB > 50 MB cap).
      // EOCD's centralDirOffset tells us where cdir starts.
      final eocd = _findEocd(raw);
      final cdirOffset = raw[eocd + 16] |
          (raw[eocd + 17] << 8) |
          (raw[eocd + 18] << 16) |
          (raw[eocd + 19] << 24);
      // CDH starts at cdirOffset; uncompressedSize is at +24.
      raw[cdirOffset + 24] = 0x00;
      raw[cdirOffset + 25] = 0x00;
      raw[cdirOffset + 26] = 0x00;
      raw[cdirOffset + 27] = 0x04;
      expect(
        () => enforceArchiveGuards(
          Uint8List.fromList(raw),
          const EpubGuardLimits(
            maxTextBytes: 1 << 30, // 1 GB — high enough that cum cap doesn't fire
          ),
        ),
        throwsA(
          isA<EpubGuardException>().having(
            (e) => e.message,
            'message',
            contains('per-entry cap'),
          ),
        ),
      );
    });

    test('per-entry compression-ratio cap rejects deflate bombs '
        'regardless of file extension', () {
      // 5 KB of zero bytes deflates to ~20 bytes. Ratio = 5000/20 = 250×
      // → exceeds default _maxPerEntryRatio=100, gets rejected.
      final compressible = Uint8List(5000);
      final bytes = _makeZipDeflated([
        ArchiveFile('a.xhtml', compressible.length, compressible),
      ]);
      expect(
        () => enforceArchiveGuards(
          bytes,
          const EpubGuardLimits(maxTextBytes: 1 << 20),
        ),
        throwsA(
          isA<EpubGuardException>().having(
            (e) => e.message,
            'message',
            contains('expansion ratio'),
          ),
        ),
      );
    });

    test('per-entry ratio cap also catches binary-disguised text bombs',
        () {
      // Same pathological compression but named `.png` to defeat
      // extension-based filtering. Ratio cap fires regardless.
      final compressible = Uint8List(5000);
      final bytes = _makeZipDeflated([
        ArchiveFile('attack.png', compressible.length, compressible),
      ]);
      expect(
        () => enforceArchiveGuards(
          bytes,
          const EpubGuardLimits(maxTextBytes: 1 << 20),
        ),
        throwsA(
          isA<EpubGuardException>().having(
            (e) => e.message,
            'message',
            contains('expansion ratio'),
          ),
        ),
      );
    });

    test('legitimate small text passes ratio cap (deflate < 100×)', () {
      // Real text deflates 5–15× typically; the byte string below has
      // enough entropy to keep ratio comfortably under 100.
      final mixedText =
          'Hello, world! This is a chapter with mixed content. '
          'Numbers: 12345, 67890. Punctuation: !@#\$%^&*()-+=[]{}|;:.';
      final bytes = _makeZipDeflated([
        ArchiveFile(
          'a.xhtml',
          mixedText.length,
          utf8.encode(mixedText),
        ),
      ]);
      // Should not throw.
      enforceArchiveGuards(bytes, const EpubGuardLimits());
    });
  });
}

Uint8List _makeZip(List<ArchiveFile> files) {
  final archive = Archive();
  for (final f in files) {
    archive.addFile(f);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _makeZipDeflated(List<ArchiveFile> files) {
  final archive = Archive();
  for (final f in files) {
    f.compression = CompressionType.deflate;
    archive.addFile(f);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

int _findEocd(List<int> bytes) {
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4B &&
        bytes[i + 2] == 0x05 &&
        bytes[i + 3] == 0x06) {
      return i;
    }
  }
  return -1;
}
