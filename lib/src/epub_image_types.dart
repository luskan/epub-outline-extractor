import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';

/// Per-figure result returned by [EpubImageExtractor.extract].
///
/// Combines the format-neutral [Figure] (which goes into structured
/// content) with storage metadata. Native callers write the bytes to
/// [absolutePath]; web callers keep [bytes] for IndexedDB persistence.
@immutable
class ExtractedFigure {
  /// Format-neutral figure descriptor. `figure.path` is the
  /// **relative** path supplied by the caller's `namingScheme`; it is
  /// what gets embedded into structured content for downstream rendering.
  final Figure figure;

  /// Absolute filesystem path of the written image inside `targetDir` on
  /// native platforms. Web extraction uses `figure.path` here because there
  /// is no filesystem-backed target path.
  final String absolutePath;

  /// The [BookSection] this figure was attributed to. Determined by
  /// fragment position in the chapter DOM.
  final BookSection? ownerSection;

  /// Section-local index used by the caller's `namingScheme`.
  final int sectionLocalIndex;

  /// Extracted image payload. Native callers may ignore this because the
  /// bytes were already written to [absolutePath]; web callers persist this
  /// into browser storage after the section rows exist.
  final Uint8List? bytes;

  /// MIME type inferred from the EPUB reference.
  final String? mimeType;

  /// SHA-256 hex digest of [bytes], when available.
  final String? sha256;

  const ExtractedFigure({
    required this.figure,
    required this.absolutePath,
    required this.ownerSection,
    required this.sectionLocalIndex,
    this.bytes,
    this.mimeType,
    this.sha256,
  });
}

/// Aggregate result of [EpubImageExtractor.extract].
@immutable
class EpubImageExtractionResult {
  /// All extracted figures in deterministic chapter-pre-order order.
  final List<ExtractedFigure> figures;

  /// Anchor -> relative path map, where anchor =
  /// `<chapter_href>:<dom_pre_order_index>`.
  final Map<String, String> anchorToPath;

  EpubImageExtractionResult({required this.figures})
    : anchorToPath = Map.unmodifiable({
        for (final f in figures) f.figure.anchor: f.figure.path,
      });
}

/// Naming-scheme callback signature.
///
/// Returns the **relative** path the image should be written to or stored
/// under. Caller picks the convention; mobile uses
/// `section_figures/{guid}/{idx}.{ext}`.
typedef EpubFigureNamingScheme =
    String Function(BookSection section, int sectionLocalIdx, String extension);
