/// Result of EPUB extraction.
///
/// Wraps the neutral [BookSection] tree (per the EPUB-support plan §3) plus
/// per-spine-file chapter content and book-level OPF metadata that the
/// neutral surface intentionally does not encode.
///
/// **Plan-vs-reality note.** Plan §4 Phase 2 lists the API as
/// `Future<BookSection> extract(...)`. That is shorthand: the neutral
/// [BookSection] tree carries the *section* (TOC) view of the book, and a
/// faithful round-trip back to mobile's existing `ConversionResult`
/// requires two more pieces:
///   1. **chapters** — per-spine-file plain text (one [PageData] each).
///      Pages and TOC sections are orthogonal views; a chapter may have
///      zero or many TOC sections, and TOC sections can span chapter
///      files (their hrefs determine assignment, not their nesting under
///      a parent TOC entry). Folding chapter content into the
///      [BookSection] tree would either lose information or overload
///      `content`/`subsections` semantically.
///   2. **metadata** — author/authors from the OPF; only `title` is
///      reachable from the [BookSection] surface.
///
/// `EpubExtractionResult` is therefore a non-breaking expansion of the
/// plan's API: it does NOT return `SectionData`/`ConversionResult` (those
/// are mobile-internal); it bundles the [BookSection] tree with the
/// page-level and metadata data the mobile adapter needs.
library;

import 'package:meta/meta.dart';
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';

@immutable
class EpubBookMetadata {
  /// Book title as recorded in the EPUB OPF metadata (`dc:title`). May be
  /// `null` if absent.
  final String? title;

  /// Primary author as recorded in OPF metadata. May be `null` if absent.
  final String? author;

  /// All authors as recorded in OPF metadata. Individual entries may be
  /// `null` (epub_pro returns `List&lt;String?&gt;`).
  final List<String?> authors;

  const EpubBookMetadata({
    this.title,
    this.author,
    this.authors = const [],
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EpubBookMetadata &&
          runtimeType == other.runtimeType &&
          title == other.title &&
          author == other.author &&
          _listEquals(authors, other.authors);

  @override
  int get hashCode => Object.hash(title, author, Object.hashAll(authors));

  @override
  String toString() =>
      'EpubBookMetadata(title=$title, author=$author, authors=$authors)';
}

/// Per-spine-file chapter content — one entry per HTML/XHTML file in the
/// spine, in spine order. Used to produce page-level views (mobile's
/// `PageData` / `ConversionResult.pages`).
@immutable
class EpubChapterContent {
  /// 0-based spine index.
  final int spineIndex;

  /// OPF-relative filename of the chapter HTML/XHTML.
  final String filename;

  /// Chapter title, derived from the TOC label or HTML headings.
  final String title;

  /// Full chapter plain text (post text-cleaner).
  final String text;

  const EpubChapterContent({
    required this.spineIndex,
    required this.filename,
    required this.title,
    required this.text,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EpubChapterContent &&
          runtimeType == other.runtimeType &&
          spineIndex == other.spineIndex &&
          filename == other.filename &&
          title == other.title &&
          text == other.text;

  @override
  int get hashCode => Object.hash(spineIndex, filename, title, text);

  @override
  String toString() =>
      'EpubChapterContent(spine=$spineIndex, file=$filename, title=$title, '
      'textLen=${text.length})';
}

@immutable
class EpubExtractionResult {
  /// Hierarchical TOC section tree.
  ///
  /// - **root**: the book itself; `title` = book title;
  ///   `location` = sentinel `EpubChapterLocation(spineIndex: 0)`;
  ///   `subsections` = depth-0 TOC entries' [BookSection]s.
  /// - **depth-0 sections** (root.subsections): one per top-level TOC
  ///   entry. `title` = TOC label;
  ///   `location` = `EpubChapterLocation(spineIndex, href, anchor?)`
  ///   reflecting THIS entry's own href; `content[0]` = section plain
  ///   text; `structuredContentJson` = optional offset annotations;
  ///   `subsections` = depth-1 TOC entries (children of this entry in the
  ///   original TOC tree). Depth-2+ entries are not emitted; their text
  ///   is merged into depth-1 (or depth-0) parent's section text by the
  ///   extractor's heading-stop logic.
  final BookSection root;

  /// Per-spine-file chapter content (page-level view). One entry per
  /// HTML/XHTML file in the spine, in spine order. Pages and TOC sections
  /// are orthogonal views (see top-of-file note).
  final List<EpubChapterContent> chapters;

  /// Book-level OPF metadata (title/author/authors).
  final EpubBookMetadata metadata;

  /// OPF-relative chapter href → raw HTML/XHTML content, for consumers
  /// that need to render the original markup (e.g. `book_tools`'s
  /// `EpubChapterPreviewPanel`). The map is unmodifiable; absent if the
  /// extractor was constructed with HTML retention disabled.
  ///
  /// Pre-Phase-6 builds returned `const {}` here; populating it adds
  /// memory proportional to chapter HTML size — acceptable for the dev
  /// tool, used by the GUI preview pane only.
  final Map<String, String> rawHtmlByHref;

  const EpubExtractionResult({
    required this.root,
    required this.chapters,
    required this.metadata,
    this.rawHtmlByHref = const {},
  });
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
