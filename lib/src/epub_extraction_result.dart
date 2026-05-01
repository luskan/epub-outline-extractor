/// Result of EPUB extraction.
///
/// Wraps the neutral [BookSection] tree (per the EPUB-support plan §3) plus
/// minimal book-level metadata that the [BookSection] surface intentionally
/// does not encode (book title from [BookSection.title] is *also* exposed
/// here for consumer convenience; author/authors live only here).
///
/// The plan's Phase 2 §4 lists the API as `Future<BookSection> extract(...)`.
/// That is shorthand: the BookSection tree is the primary deliverable, but
/// the mobile adapter still needs author/authors for round-trip parity with
/// the existing `epub_metadata` block in `ConversionResult.metadata`. Rather
/// than overload [BookSection.structuredContentJson] for root-level metadata
/// (which would surprise downstream code that strict-parses
/// [StructuredContent] from that field), we surface metadata as a sibling
/// field on the result. This is a non-breaking expansion of the plan's API
/// — the result still does NOT contain `SectionData`/`ConversionResult`
/// (those are mobile-internal).
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

@immutable
class EpubExtractionResult {
  /// Hierarchical book section tree.
  ///
  /// Shape:
  /// - root: book itself; `title` = book title; `location` = sentinel
  ///   `EpubChapterLocation(spineIndex: 0, href: null)`; `subsections` =
  ///   chapter [BookSection]s.
  /// - chapter level (root.subsections[i]): one per spine HTML/XHTML file,
  ///   in spine order; `title` = chapter title (from TOC or HTML);
  ///   `location` = `EpubChapterLocation(spineIndex: i, href: filename)`;
  ///   `content[0]` = full chapter plain text; `subsections` = TOC
  ///   sections within this chapter (hierarchical, mirrors original TOC).
  /// - section level: TOC entries; `title` = TOC label; `location` =
  ///   `EpubChapterLocation(spineIndex: chapterIdx, href: filename,
  ///   anchor: fragment?)`; `content[0]` = section plain text;
  ///   `structuredContentJson` = optional offset-based annotations.
  final BookSection root;

  /// Book-level metadata (title/author/authors). Title is also reachable
  /// via [root.title]; this field exists so consumers can access OPF
  /// metadata that the BookSection surface does not carry.
  final EpubBookMetadata metadata;

  const EpubExtractionResult({required this.root, required this.metadata});
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
