/// Internal data structures for EPUB conversion.
///
/// These types represent intermediate state used during EPUB extraction:
/// table-of-contents trees, spine ordering, and per-chapter extracted text.
/// They are intentionally separate from the public [BookSection] surface
/// because they preserve epub_pro-flavored detail (HTML filenames, anchor
/// fragments, parent titles) that the neutral [BookSection] does not need
/// to encode hierarchically.
library;

/// Represents a chapter (one HTML/XHTML file in the spine) with its
/// extracted plain text. One [ChapterData] = one [PageData] in the
/// downstream mobile [ConversionResult].
class ChapterData {
  /// 1-based chapter index (== spine index + 1).
  final int chapter;

  /// HTML/XHTML filename within the EPUB (OPF-relative, e.g. `chapter01.xhtml`).
  final String name;

  /// Chapter title — either from the TOC entry or extracted from the HTML
  /// (h1/h2/h3/title tag); falls back to the filename stem.
  final String title;

  /// Extracted plain text of the entire chapter (post text-cleaner).
  final String text;

  /// Confidence score (always 1.0 for EPUB; field exists for shape-symmetry
  /// with PDF [PageData] which carries OCR confidence).
  final double confidence;

  /// Currently identical to [text] for EPUB. Field exists for shape-symmetry
  /// with downstream [PageData] which has separate raw and corrected text.
  final String correctedText;

  const ChapterData({
    required this.chapter,
    required this.name,
    required this.title,
    required this.text,
    this.confidence = 1.0,
    String? correctedText,
  }) : correctedText = correctedText ?? text;
}

/// Represents a table-of-contents entry (tree-shaped).
class TocEntry {
  final String title;

  /// OPF-relative href, optionally with fragment (`chapter01.xhtml#sec1`).
  /// `null` for purely virtual entries that have no anchor.
  final String? href;

  /// Title of the parent entry, if any. `null` at top level.
  final String? parentTitle;

  /// Depth in the original TOC tree (0 = top level).
  final int depth;

  final List<TocEntry> children;

  TocEntry({
    required this.title,
    this.href,
    this.parentTitle,
    this.depth = 0,
    this.children = const [],
  });

  bool get hasChildren => children.isNotEmpty;
}

/// Flattened TOC item — a single row of a [TocEntry] tree expanded to
/// some maximum depth. Used by section-extraction passes that want a
/// linear scan rather than recursion.
class TocItemFlat {
  final String title;
  final String? href;
  final String? parentTitle;
  final int depth;

  /// `true` if this entry had children in the original tree (but the
  /// children were not included in this flattening pass).
  final bool isSection;

  /// First child's href, useful when a parent section lacks its own href
  /// and callers want to navigate to its first sub-anchor.
  final String? firstChildHref;

  TocItemFlat({
    required this.title,
    this.href,
    this.parentTitle,
    required this.depth,
    this.isSection = false,
    this.firstChildHref,
  });
}

/// Internal epub_pro-derived data: metadata, spine ordering, TOC tree.
class EpubData {
  final Map<String, String> metadata;
  final List<String> spineOrder;
  final List<TocEntry> tocEntries;

  /// OPF directory (currently always empty since epub_pro handles path
  /// resolution internally; retained for forward-compat with non-epub_pro
  /// parsers that might be plugged in later).
  final String opfDir;

  EpubData({
    required this.metadata,
    required this.spineOrder,
    required this.tocEntries,
    required this.opfDir,
  });
}
