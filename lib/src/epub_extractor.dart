/// Public EPUB extractor API.
///
/// Migrated from `quizpilgrim-app/.../core/converters/epub_converter.dart` in
/// EPUB-plan Phase 2. Replaces mobile-private `AppLogger` with injected
/// `package:logging` `Logger`. Returns a neutral [BookSection] tree (rooted
/// at the book) plus minimal OPF metadata; the mobile-internal adapter
/// (`book_import/epub_processor.dart`) re-projects this onto
/// `ConversionResult` for the existing import pipeline.
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

  /// Convert EPUB bytes into a [BookSection] tree + book metadata.
  ///
  /// [epubBytes] — Raw EPUB bytes.
  /// [filename] — Original filename, surfaced in error messages and useful
  ///   when the EPUB OPF lacks a title.
  /// [onProgress] — Optional progress callback. Stage strings are
  ///   `'Parsing EPUB'`, `'Extracting chapters'`, `'Extracting sections'`.
  ///
  /// The returned [EpubExtractionResult.root] is the book itself. Its
  /// subsections are chapters in spine order; each chapter's subsections
  /// hierarchically mirror the EPUB TOC tree (when `extractSections` is
  /// `true` and the book has a navigable TOC).
  Future<EpubExtractionResult> extract(
    Uint8List epubBytes, {
    String? filename,
    void Function(int current, int total, String stage)? onProgress,
  }) async {
    _logger.info('Converting EPUB: ${filename ?? "unknown"}');

    // Parse EPUB.
    onProgress?.call(0, 100, 'Parsing EPUB');
    final epubBook = await EpubReader.readBook(epubBytes);
    onProgress?.call(100, 100, 'Parsing EPUB');
    _logger.info('Parsed EPUB: "${epubBook.title}"');

    // Internal data: spine order, TOC tree, OPF metadata.
    final epubData = _buildEpubDataFromEpubPro(epubBook);

    // Step 1: per-spine-file chapter texts.
    final chapters = _extractChapters(
      epubBook,
      onProgress: (current, total) =>
          onProgress?.call(current, total, 'Extracting chapters'),
    );
    _logger.info('Extracted ${chapters.length} chapters');

    // Step 2: per-TOC-entry section texts (hierarchical).
    final sectionsByChapter = <String, List<BookSection>>{};
    if (extractSections && epubData.tocEntries.isNotEmpty) {
      _buildSectionsFromTocTree(
        epubBook,
        epubData,
        chapters,
        sectionsByChapter,
        onProgress: (current, total) =>
            onProgress?.call(current, total, 'Extracting sections'),
      );
    }

    // Step 3: assemble chapter [BookSection]s and the root.
    final chapterSections = <BookSection>[];
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      final chapterSubsections =
          sectionsByChapter[chapter.name] ?? const <BookSection>[];
      chapterSections.add(
        BookSection(
          title: chapter.title,
          location: EpubChapterLocation(
            spineIndex: i,
            href: chapter.name,
          ),
          content: [chapter.text],
          subsections: chapterSubsections,
        ),
      );
    }

    final root = BookSection(
      title: epubBook.title ?? '',
      location: const EpubChapterLocation(spineIndex: 0),
      subsections: chapterSections,
    );

    final metadata = EpubBookMetadata(
      title: epubBook.title,
      author: epubBook.author,
      authors: List<String?>.unmodifiable(epubBook.authors),
    );

    _logger.info(
      'EPUB extraction complete — chapters=${chapters.length}, '
      'sections=${sectionsByChapter.values.fold<int>(0, (s, l) => s + _countTree(l))}',
    );

    return EpubExtractionResult(root: root, metadata: metadata);
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
      // use the child's title for parent (e.g., "Data Structures" -> "I. Data Structures")
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

      final fileName = chapter.contentFileName;
      if (fileName == null || seenFiles.contains(fileName)) return;
      if (!_isHtmlFile(fileName)) return;

      final htmlContent = chapter.htmlContent;
      if (htmlContent == null || htmlContent.isEmpty) return;

      final text = extractTextFromHtml(htmlContent);
      if (text.trim().isEmpty) return;

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

      for (final sub in chapter.subChapters) {
        processChapter(sub);
      }
    }

    for (final chapter in epubBook.chapters) {
      processChapter(chapter);
    }

    return chapters;
  }

  /// Build hierarchical [BookSection] trees per chapter from the TOC tree.
  ///
  /// Section text is extracted between fragment anchors (or full chapter
  /// text when no fragments are present). Output is grouped by chapter
  /// filename, mirroring the original TOC hierarchy under each chapter.
  void _buildSectionsFromTocTree(
    EpubBook epubBook,
    EpubData epubData,
    List<ChapterData> chapters,
    Map<String, List<BookSection>> sectionsByChapter, {
    void Function(int current, int total)? onProgress,
  }) {
    // Build HTML content map for fragment-based extraction.
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

    // Flatten TOC at maxDepth=1 (matches legacy mobile behavior — depth-2+
    // entries get merged into their parent's section text via heading-stop
    // detection during extractSectionText).
    final tocFlat = _flattenToc(epubData.tocEntries);
    if (tocFlat.isNotEmpty) {
      onProgress?.call(0, tocFlat.length);
    }

    // Process each TOC item, grouping under its chapter.
    for (var i = 0; i < tocFlat.length; i++) {
      final tocItem = tocFlat[i];
      onProgress?.call(i + 1, tocFlat.length);

      if (tocItem.href == null) {
        _logger.fine('SKIPPED: "${tocItem.title}" - no href');
        continue;
      }

      final (file, fragment) = TextParsingUtils.parseHref(tocItem.href!);

      // Find corresponding chapter index.
      final chapterIndex = chapters.indexWhere((ch) => ch.name == file);
      if (chapterIndex == -1) {
        _logger.fine(
          'SKIPPED: "${tocItem.title}" - chapter not found: $file',
        );
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

      // Generate structured content annotations.
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

      final section = BookSection(
        title: tocItem.title,
        location: EpubChapterLocation(
          spineIndex: chapterIndex,
          href: file,
          anchor: fragment,
        ),
        content: [sectionText],
        structuredContentJson: structuredJson,
      );

      sectionsByChapter.putIfAbsent(file, () => <BookSection>[]).add(section);
    }
  }

  /// Flatten the TOC tree, keeping entries up to [maxDepth].
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
