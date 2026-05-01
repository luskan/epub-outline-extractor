/// Public EPUB extractor API.
///
/// Migrated from `quizpilgrim-app/.../core/converters/epub_converter.dart` in
/// EPUB-plan Phase 2. Replaces mobile-private `AppLogger` with injected
/// `package:logging` `Logger`. Returns a neutral [BookSection] tree (the
/// TOC view) plus per-spine-file chapter content and OPF metadata; see
/// `EpubExtractionResult` for why those last two pieces are bundled
/// separately rather than folded into the [BookSection] tree.
library;

import 'dart:typed_data';

import 'package:epub_pro/epub_pro.dart';
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';

import 'epub_data.dart';
import 'epub_extraction_result.dart';
import 'epub_structured_content_builder.dart';
import 'html_text_extractor.dart';
import 'text_cleaner.dart';
import 'text_parsing_utils.dart';

const String _loggerName = 'EpubExtractor';

class EpubExtractor {
  final bool fixLineBreaks;
  final bool extractSections;
  final Logger _logger;

  EpubExtractor({
    this.fixLineBreaks = true,
    this.extractSections = true,
    Logger? logger,
  }) : _logger = logger ?? Logger(_loggerName);

  /// Convert EPUB bytes into an [EpubExtractionResult] (TOC tree +
  /// per-spine chapter content + OPF metadata).
  ///
  /// [epubBytes] — Raw EPUB bytes.
  /// [filename] — Original filename, surfaced in error messages and useful
  ///   when the EPUB OPF lacks a title.
  /// [onProgress] — Optional progress callback. Stage strings are
  ///   `'Parsing EPUB'`, `'Extracting chapters'`, `'Extracting sections'`.
  Future<EpubExtractionResult> extract(
    Uint8List epubBytes, {
    String? filename,
    void Function(int current, int total, String stage)? onProgress,
  }) async {
    // Logs are emitted at FINE level so the legacy silent-by-default
    // behavior is preserved when consumers don't explicitly raise the
    // logger threshold (legacy `EpubToJsonConverter` defaulted
    // `verbose: false`, making `_log()` a no-op in release builds).
    _logger.fine('Converting EPUB: ${filename ?? "unknown"}');

    onProgress?.call(0, 100, 'Parsing EPUB');
    final epubBook = await EpubReader.readBook(epubBytes);
    onProgress?.call(100, 100, 'Parsing EPUB');
    _logger.fine('Parsed EPUB: "${epubBook.title}"');

    final epubData = _buildEpubDataFromEpubPro(epubBook);

    final chapters = _extractChapters(
      epubBook,
      onProgress: (current, total) =>
          onProgress?.call(current, total, 'Extracting chapters'),
    );
    _logger.fine('Extracted ${chapters.length} chapters');

    final tocSections = (extractSections && epubData.tocEntries.isNotEmpty)
        ? _buildTocSections(
            epubBook,
            epubData,
            chapters,
            onProgress: (current, total) =>
                onProgress?.call(current, total, 'Extracting sections'),
          )
        : <BookSection>[];

    final root = BookSection(
      title: epubBook.title ?? '',
      location: const EpubChapterLocation(spineIndex: 0),
      subsections: tocSections,
    );

    final chapterContents = <EpubChapterContent>[
      for (var i = 0; i < chapters.length; i++)
        EpubChapterContent(
          spineIndex: i,
          filename: chapters[i].name,
          title: chapters[i].title,
          text: chapters[i].text,
        ),
    ];

    final metadata = EpubBookMetadata(
      title: epubBook.title,
      author: epubBook.author,
      authors: List<String?>.unmodifiable(epubBook.authors),
    );

    _logger.fine(
      'EPUB extraction complete — chapters=${chapters.length}, '
      'sections=${_countTree(tocSections)}',
    );

    return EpubExtractionResult(
      root: root,
      chapters: chapterContents,
      metadata: metadata,
    );
  }

  /// Build internal EpubData from epub_pro structures.
  EpubData _buildEpubDataFromEpubPro(EpubBook epubBook) {
    final metadata = <String, String>{};
    if (epubBook.title != null) metadata['title'] = epubBook.title!;
    if (epubBook.author != null) metadata['creator'] = epubBook.author!;
    final authors = epubBook.authors;
    for (var i = 0; i < authors.length; i++) {
      final author = authors[i];
      if (author != null) {
        metadata['author_$i'] = author;
      }
    }

    final spineOrder = <String>[];
    void collectSpineOrder(EpubChapter chapter) {
      if (chapter.contentFileName != null &&
          !spineOrder.contains(chapter.contentFileName)) {
        spineOrder.add(chapter.contentFileName!);
      }
      for (final sub in chapter.subChapters) {
        collectSpineOrder(sub);
      }
    }

    for (final chapter in epubBook.chapters) {
      collectSpineOrder(chapter);
    }

    final tocEntries = _buildTocFromChapters(epubBook.chapters, null, 0);

    return EpubData(
      metadata: metadata,
      spineOrder: spineOrder,
      tocEntries: tocEntries,
      opfDir: '',
    );
  }

  /// Build TocEntry tree from epub_pro chapters.
  List<TocEntry> _buildTocFromChapters(
    List<EpubChapter> chapters,
    String? parentTitle,
    int depth,
  ) {
    final entries = <TocEntry>[];

    for (final chapter in chapters) {
      String? href;
      if (chapter.contentFileName != null) {
        href = chapter.anchor != null
            ? '${chapter.contentFileName}#${chapter.anchor}'
            : chapter.contentFileName;
      }

      final childEntries = chapter.subChapters.isNotEmpty
          ? _buildTocFromChapters(chapter.subChapters, chapter.title, depth + 1)
          : <TocEntry>[];

      // If parent has a generic title and first child has numbered version,
      // use the child's title for parent (e.g., "Data Structures" → "I. Data Structures")
      String title = chapter.title?.trim() ?? 'Untitled';
      if (chapter.subChapters.isNotEmpty) {
        final firstChildTitle = chapter.subChapters.first.title?.trim();
        if (firstChildTitle != null && firstChildTitle.isNotEmpty) {
          final strippedChildTitle = TextParsingUtils.stripPartPrefix(
            firstChildTitle,
          ).trim();
          if (strippedChildTitle.toLowerCase() == title.toLowerCase()) {
            title = firstChildTitle;
          }
        }
      }

      entries.add(
        TocEntry(
          title: title,
          href: href,
          parentTitle: parentTitle,
          depth: depth,
          children: childEntries,
        ),
      );
    }

    return entries;
  }

  /// Extract chapters from epub_pro book — one [ChapterData] per HTML file.
  List<ChapterData> _extractChapters(
    EpubBook epubBook, {
    void Function(int current, int total)? onProgress,
  }) {
    final chapters = <ChapterData>[];
    final seenFiles = <String>{};
    final totalChapters = _countChapters(epubBook.chapters);
    var processed = 0;

    if (totalChapters > 0) {
      onProgress?.call(0, totalChapters);
    }

    void processChapter(EpubChapter chapter) {
      processed++;
      onProgress?.call(processed, totalChapters);

      // Decide whether the current node contributes a [ChapterData].
      // Recursion into subChapters runs unconditionally afterward — a
      // skipped parent (e.g., a part-divider navPoint with no content,
      // duplicate file, or empty body) must not silently drop its
      // descendants, otherwise the TOC pass later sees `chapterIndex ==
      // -1` for those descendants and fails to materialise them as
      // depth-1 BookSections (Round 1/2 review feedback).
      final fileName = chapter.contentFileName;
      final hasFile = fileName != null && !seenFiles.contains(fileName);
      final isHtml = hasFile && _isHtmlFile(fileName);
      final htmlContent = isHtml ? chapter.htmlContent : null;
      final hasContent = htmlContent != null && htmlContent.isNotEmpty;

      if (hasFile && isHtml && hasContent) {
        final text = extractTextFromHtml(htmlContent);
        if (text.trim().isNotEmpty) {
          seenFiles.add(fileName);
          final cleanedText = fixLineBreaks
              ? TextCleaner.cleanText(text, fixLineBreaks: true)
              : text;
          final title =
              chapter.title ?? extractTitleFromHtml(htmlContent, fileName);
          chapters.add(
            ChapterData(
              chapter: chapters.length + 1,
              name: fileName,
              title: title,
              text: cleanedText,
              confidence: 1.0,
              correctedText: cleanedText,
            ),
          );
        }
      }

      for (final sub in chapter.subChapters) {
        processChapter(sub);
      }
    }

    for (final chapter in epubBook.chapters) {
      processChapter(chapter);
    }

    return chapters;
  }

  /// Build the hierarchical TOC tree as `List<BookSection>`.
  ///
  /// Mirrors the original [TocEntry] tree up to depth 1 (legacy
  /// `_flattenToc(maxDepth: 1)` policy): depth-0 entries' [BookSection]s
  /// have their depth-1 children nested as `subsections`. Depth-2+ entries
  /// are not emitted; their text is merged into the depth-1 parent's
  /// section text by `extractSectionText`'s heading-stop logic.
  ///
  /// Each section's [BookSection.location] (an [EpubChapterLocation])
  /// reflects the entry's own href — its `spineIndex` may differ from its
  /// parent's if the depth-1 entry's href points to a different chapter
  /// file (an unusual but legal EPUB structure).
  List<BookSection> _buildTocSections(
    EpubBook epubBook,
    EpubData epubData,
    List<ChapterData> chapters, {
    void Function(int current, int total)? onProgress,
  }) {
    final htmlContentMap = <String, String>{};
    void collectHtml(EpubChapter chapter) {
      if (chapter.contentFileName != null && chapter.htmlContent != null) {
        htmlContentMap[chapter.contentFileName!] = chapter.htmlContent!;
      }
      for (final sub in chapter.subChapters) {
        collectHtml(sub);
      }
    }

    for (final chapter in epubBook.chapters) {
      collectHtml(chapter);
    }

    // Flatten the TOC tree at maxDepth=1 (legacy behavior). Depth-2+
    // entries are silently dropped here; their text is captured by the
    // surrounding depth-1 section's extracted text via heading-stop logic.
    // The flat list preserves DFS pre-order so we can compute next-fragment
    // bounds locally.
    final tocFlat = _flattenToc(epubData.tocEntries);
    if (tocFlat.isNotEmpty) {
      onProgress?.call(0, tocFlat.length);
    }

    // Build a flat parallel list of BookSections in tocFlat order, then
    // reconstruct the depth-0/depth-1 hierarchy from `parentTitle`. We
    // need the flat ordering for next-fragment bound computation, but we
    // emit a hierarchical tree so the adapter can recover legacy
    // `parentTitle` semantics (depth-0 → null, depth-1 → parent's title).
    //
    // Virtual placeholders: depth-0 entries with no href (or whose href
    // points to a missing chapter) still get a [BookSection] with a
    // sentinel location (`spineIndex: -1, href: null`) and empty
    // [content]. The mobile adapter recognises this sentinel and skips
    // emitting a SectionData for the placeholder itself, but still emits
    // its depth-1 children with `parentTitle = placeholder.title` —
    // matching legacy `_extractSectionsFromToc` behavior where the
    // skipped parent's children kept being processed independently.
    final flatBookSections = <BookSection?>[];

    BookSection virtualPlaceholder(String title) => BookSection(
      title: title,
      location: const EpubChapterLocation(spineIndex: -1),
    );

    for (var i = 0; i < tocFlat.length; i++) {
      final tocItem = tocFlat[i];
      onProgress?.call(i + 1, tocFlat.length);

      if (tocItem.href == null) {
        _logger.fine('SKIPPED: "${tocItem.title}" - no href');
        flatBookSections
            .add(tocItem.depth == 0 ? virtualPlaceholder(tocItem.title) : null);
        continue;
      }

      final (file, fragment) = TextParsingUtils.parseHref(tocItem.href!);

      final chapterIndex = chapters.indexWhere((ch) => ch.name == file);
      if (chapterIndex == -1) {
        _logger.fine(
          'SKIPPED: "${tocItem.title}" - chapter not found: $file',
        );
        flatBookSections
            .add(tocItem.depth == 0 ? virtualPlaceholder(tocItem.title) : null);
        continue;
      }

      // Find next fragment in same file (if any) — used as bound.
      String? nextFragment;
      for (var j = i + 1; j < tocFlat.length; j++) {
        final nextItem = tocFlat[j];
        if (nextItem.href == null) continue;

        final (nextFile, nextFrag) = TextParsingUtils.parseHref(nextItem.href!);
        if (nextFile == file && nextFrag != null) {
          nextFragment = nextFrag;
          break;
        } else if (nextFile != file) {
          break;
        }
      }

      // Extract section text.
      String sectionText;
      if (fragment != null || nextFragment != null) {
        final htmlContent = htmlContentMap[file];
        if (htmlContent == null) {
          _logger.fine(
            'SKIPPED: "${tocItem.title}" - HTML content not found for $file',
          );
          flatBookSections.add(null);
          continue;
        }

        sectionText = extractSectionText(
          htmlContent,
          fragment,
          nextFragment,
          logger: _logger.fine,
        );

        if (sectionText.length > 50000) {
          _logger.warning(
            'Section "${tocItem.title}" has ${sectionText.length} chars '
            '(possible boundary issue)',
          );
        } else if (sectionText.isEmpty) {
          _logger.warning('Section "${tocItem.title}" is EMPTY');
        }
      } else {
        sectionText = chapters[chapterIndex].text;
      }

      // Generate structured content annotations (full-chapter HTML →
      // section-text mapping).
      String? structuredJson;
      final sectionHtml = htmlContentMap[file];
      if (sectionText.isNotEmpty && sectionHtml != null) {
        try {
          structuredJson = EpubStructuredContentBuilder.buildFromHtml(
            sectionHtml,
            sectionText,
          );
        } catch (e) {
          _logger.warning('Structured content extraction failed: $e');
        }
      }

      flatBookSections.add(
        BookSection(
          title: tocItem.title,
          location: EpubChapterLocation(
            spineIndex: chapterIndex,
            href: file,
            anchor: fragment,
          ),
          content: [sectionText],
          structuredContentJson: structuredJson,
        ),
      );
    }

    // Reconstruct depth-0/depth-1 hierarchy from tocFlat. tocFlat is
    // pre-order DFS through depth ≤ 1, so depth-1 entries always follow
    // their parent depth-0 entry contiguously.
    final result = <BookSection>[];
    for (var i = 0; i < tocFlat.length; i++) {
      if (tocFlat[i].depth != 0) continue;
      final parentSection = flatBookSections[i];
      if (parentSection == null) continue;

      // Collect this depth-0 entry's depth-1 children: scan forward until
      // the next depth-0 entry.
      final children = <BookSection>[];
      for (var j = i + 1; j < tocFlat.length; j++) {
        if (tocFlat[j].depth == 0) break;
        final child = flatBookSections[j];
        if (child != null) children.add(child);
      }

      if (children.isEmpty) {
        result.add(parentSection);
      } else {
        result.add(parentSection.copyWith(subsections: children));
      }
    }

    return result;
  }

  /// Flatten the TOC tree at [maxDepth]; preserves pre-order DFS order.
  List<TocItemFlat> _flattenToc(List<TocEntry> tocEntries, {int maxDepth = 1}) {
    final flat = <TocItemFlat>[];

    void flatten(TocEntry entry, String? parentTitle) {
      if (entry.depth > maxDepth) return;

      final isSection = entry.hasChildren;
      String? firstChildHref;
      if (isSection && entry.children.isNotEmpty) {
        firstChildHref = entry.children.first.href;
      }

      flat.add(
        TocItemFlat(
          title: entry.title,
          href: entry.href,
          parentTitle: parentTitle,
          depth: entry.depth,
          isSection: isSection,
          firstChildHref: firstChildHref,
        ),
      );

      for (final child in entry.children) {
        flatten(child, entry.title);
      }
    }

    for (final entry in tocEntries) {
      flatten(entry, null);
    }

    return flat;
  }

  bool _isHtmlFile(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.html') ||
        lower.endsWith('.xhtml') ||
        lower.endsWith('.htm');
  }

  int _countChapters(List<EpubChapter> chapters) {
    var count = 0;
    for (final chapter in chapters) {
      count++;
      if (chapter.subChapters.isNotEmpty) {
        count += _countChapters(chapter.subChapters);
      }
    }
    return count;
  }

  int _countTree(List<BookSection> sections) {
    var count = sections.length;
    for (final s in sections) {
      count += _countTree(s.subsections);
    }
    return count;
  }
}
