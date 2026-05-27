import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';
import 'package:xml/xml.dart' as xml;

import 'epub_data.dart';
import 'epub_extraction_result.dart';
import 'epub_guards.dart';
import 'epub_html_heading_splitter.dart';
import 'epub_section_split_options.dart';
import 'epub_structured_content_builder.dart';
import 'extracted_text.dart';
import 'html_text_extractor.dart';
import 'text_cleaner.dart';
import 'text_parsing_utils.dart';

const String _loggerName = 'EpubExtractor';

class EpubExtractor {
  final bool fixLineBreaks;
  final bool extractSections;
  final EpubSectionSplitOptions sectionSplitOptions;
  final EpubGuardLimits guardLimits;
  final Logger _logger;

  EpubExtractor({
    this.fixLineBreaks = true,
    this.extractSections = true,
    this.sectionSplitOptions = EpubSectionSplitOptions.tocOnly,
    this.guardLimits = const EpubGuardLimits(),
    Logger? logger,
  }) : _logger = logger ?? Logger(_loggerName);

  Future<EpubExtractionResult> extract(
    Uint8List epubBytes, {
    String? filename,
    EpubSectionSplitOptions? sectionSplitOptions,
    void Function(int current, int total, String stage)? onProgress,
  }) async {
    _logger.fine('Converting EPUB in browser: ${filename ?? "unknown"}');
    enforceArchiveGuards(epubBytes, guardLimits);

    onProgress?.call(0, 100, 'Parsing EPUB');
    final parsed = _ParsedEpub.fromBytes(epubBytes);
    onProgress?.call(100, 100, 'Parsing EPUB');

    onProgress?.call(0, parsed.spine.length, 'Extracting chapters');
    final chapters = <EpubChapterContent>[];
    final rawHtmlByHref = <String, String>{};
    for (var i = 0; i < parsed.spine.length; i++) {
      final item = parsed.spine[i];
      final html = parsed.readManifestText(item);
      rawHtmlByHref[item.href] = html;
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final title = extractTitleFromHtml(html, item.href);
      chapters.add(
        EpubChapterContent(
          spineIndex: i,
          filename: item.href,
          title: title.isEmpty ? 'Chapter ${i + 1}' : title,
          text: cleaned.text,
        ),
      );
      onProgress?.call(i + 1, parsed.spine.length, 'Extracting chapters');
    }

    final effectiveSplitOptions =
        sectionSplitOptions ?? this.sectionSplitOptions;
    onProgress?.call(0, 100, 'Extracting sections');
    final authoredTocEntries = parsed.readTocEntries();
    final tocEntries = effectiveSplitOptions.usesHtmlHeadings
        ? augmentTocWithHtmlHeadings(
            authoredTocEntries,
            rawHtmlByHref,
            effectiveSplitOptions,
          )
        : authoredTocEntries;
    final root = _buildSectionTree(
      parsed: parsed,
      tocEntries: tocEntries,
      chapters: chapters,
      rawHtmlByHref: rawHtmlByHref,
      extractSections: extractSections,
    );
    onProgress?.call(100, 100, 'Extracting sections');

    return EpubExtractionResult(
      root: root,
      chapters: chapters,
      metadata: EpubBookMetadata(
        title: parsed.title,
        author: parsed.authors.isEmpty ? null : parsed.authors.join(', '),
        authors: parsed.authors,
      ),
      rawHtmlByHref: Map.unmodifiable(rawHtmlByHref),
    );
  }

  Future<EpubSectionSplitAnalysis> analyzeSectionSplits(
    Uint8List epubBytes, {
    String? filename,
  }) async {
    _logger.fine(
      'Analyzing EPUB section splits in browser: ${filename ?? "unknown"}',
    );
    enforceArchiveGuards(epubBytes, guardLimits);
    final parsed = _ParsedEpub.fromBytes(epubBytes);
    final rawHtmlByHref = <String, String>{};
    for (final item in parsed.spine) {
      rawHtmlByHref[item.href] = parsed.readManifestText(item);
    }
    return analyzeTocHtmlHeadingSplits(parsed.readTocEntries(), rawHtmlByHref);
  }
}

BookSection _buildSectionTree({
  required _ParsedEpub parsed,
  required List<TocEntry> tocEntries,
  required List<EpubChapterContent> chapters,
  required Map<String, String> rawHtmlByHref,
  required bool extractSections,
}) {
  final title = parsed.title ?? parsed.filenameTitle ?? 'Imported EPUB';
  if (tocEntries.isEmpty || !extractSections) {
    return BookSection(
      title: title,
      location: const EpubChapterLocation(spineIndex: 0),
      subsections: [
        for (final chapter in chapters)
          BookSection(
            title: chapter.title,
            location: EpubChapterLocation(
              spineIndex: chapter.spineIndex,
              href: chapter.filename,
            ),
            content: [chapter.text],
            structuredContentJson: _structuredForWholeChapter(
              rawHtmlByHref[chapter.filename],
            ),
          ),
      ],
    );
  }

  final flatEntries = <TocEntry>[];
  void collect(TocEntry entry) {
    flatEntries.add(entry);
    for (final child in entry.children) {
      collect(child);
    }
  }

  for (final entry in tocEntries) {
    collect(entry);
  }

  final nextAnchorByEntry = <TocEntry, String?>{};
  for (var i = 0; i < flatEntries.length; i++) {
    final entry = flatEntries[i];
    final href = entry.href;
    if (href == null) continue;
    final (file, _) = TextParsingUtils.parseHref(href);
    for (var j = i + 1; j < flatEntries.length; j++) {
      final next = flatEntries[j];
      final nextHref = next.href;
      if (nextHref == null) continue;
      final (nextFile, nextAnchor) = TextParsingUtils.parseHref(nextHref);
      if (nextFile == file && nextAnchor != null) {
        nextAnchorByEntry[entry] = nextAnchor;
        break;
      } else if (nextFile != file) {
        break;
      }
    }
  }

  return BookSection(
    title: title,
    location: const EpubChapterLocation(spineIndex: 0),
    subsections: [
      for (final entry in tocEntries)
        _buildSection(parsed, entry, rawHtmlByHref, nextAnchorByEntry),
    ],
  );
}

BookSection _buildSection(
  _ParsedEpub parsed,
  TocEntry entry,
  Map<String, String> rawHtmlByHref,
  Map<TocEntry, String?> nextAnchorByEntry,
) {
  final href = entry.href;
  final (file, anchor) = href == null
      ? (null, null)
      : TextParsingUtils.parseHref(href);
  final spineIndex = file == null ? -1 : parsed.spineIndexByHref[file] ?? -1;
  final html = file == null ? null : rawHtmlByHref[file];
  final extraction = html == null
      ? null
      : _extractSection(html, anchor, nextAnchorByEntry[entry]);

  return BookSection(
    title: entry.title,
    location: EpubChapterLocation(
      spineIndex: spineIndex,
      href: file,
      anchor: anchor,
    ),
    content: extraction == null ? const [] : [extraction.extracted.text],
    structuredContentJson: extraction == null
        ? null
        : EpubStructuredContentBuilder.build(extraction),
    subsections: [
      for (final child in entry.children)
        _buildSection(parsed, child, rawHtmlByHref, nextAnchorByEntry),
    ],
  );
}

SectionExtraction _extractSection(
  String html,
  String? anchor,
  String? nextAnchor,
) {
  final raw = extractSectionStructured(html, anchor, nextAnchor);
  final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw.extracted);
  return SectionExtraction(
    extracted: cleaned,
    sectionStartElement: raw.sectionStartElement,
    sectionEndElement: raw.sectionEndElement,
  );
}

String? _structuredForWholeChapter(String? html) {
  if (html == null) return null;
  final raw = extractStructured(html);
  final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
  return EpubStructuredContentBuilder.build(
    SectionExtraction(
      extracted: cleaned,
      sectionStartElement: null,
      sectionEndElement: null,
    ),
  );
}

class _ParsedEpub {
  final Archive archive;
  final Map<String, ArchiveFile> filesByPath;
  final String opfPath;
  final String opfDir;
  final String? filenameTitle;
  final String? title;
  final List<String?> authors;
  final List<_ManifestItem> spine;
  final Map<String, _ManifestItem> manifestById;
  final Map<String, String> manifestHrefByFullPath;

  _ParsedEpub({
    required this.archive,
    required this.filesByPath,
    required this.opfPath,
    required this.opfDir,
    required this.filenameTitle,
    required this.title,
    required this.authors,
    required this.spine,
    required this.manifestById,
    required this.manifestHrefByFullPath,
  });

  factory _ParsedEpub.fromBytes(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final filesByPath = {
      for (final file in archive.files) _normalizePath(file.name): file,
    };

    final containerFile = filesByPath['META-INF/container.xml'];
    if (containerFile == null) {
      throw const FormatException('EPUB container.xml not found.');
    }
    final container = xml.XmlDocument.parse(_decodeFile(containerFile));
    final rootfile = _firstXmlElementNamed(container, 'rootfile');
    final opfPath = _normalizePath(rootfile?.getAttribute('full-path') ?? '');
    if (opfPath.isEmpty) {
      throw const FormatException('EPUB rootfile path not found.');
    }

    final opfFile = filesByPath[opfPath];
    if (opfFile == null) {
      throw FormatException('EPUB package file not found: $opfPath');
    }

    final opfDir = _dirname(opfPath);
    final opf = xml.XmlDocument.parse(_decodeFile(opfFile));
    final metadata = _firstXmlElementNamed(opf, 'metadata');
    final title = _textOfFirstXml(metadata ?? opf, 'title')?.trim();
    final authors = [
      for (final creator in _xmlElementsNamed(metadata ?? opf, 'creator'))
        creator.innerText.trim(),
    ].where((value) => value.isNotEmpty).toList(growable: false);

    final manifestById = <String, _ManifestItem>{};
    final manifestHrefByFullPath = <String, String>{};
    for (final item in _xmlElementsNamed(opf, 'item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null || id.isEmpty || href.isEmpty) continue;
      final normalizedHref = _normalizePath(href);
      final fullPath = _normalizePath(p.posix.join(opfDir, normalizedHref));
      final manifestItem = _ManifestItem(
        id: id,
        href: normalizedHref,
        fullPath: fullPath,
        mediaType: item.getAttribute('media-type'),
        properties: item.getAttribute('properties'),
      );
      manifestById[id] = manifestItem;
      manifestHrefByFullPath[fullPath] = normalizedHref;
    }

    final spine = <_ManifestItem>[];
    final spineElement = _firstXmlElementNamed(opf, 'spine');
    if (spineElement != null) {
      for (final itemRef in _xmlChildrenNamed(spineElement, 'itemref')) {
        final idref = itemRef.getAttribute('idref');
        final item = idref == null ? null : manifestById[idref];
        if (item != null) spine.add(item);
      }
    }

    return _ParsedEpub(
      archive: archive,
      filesByPath: filesByPath,
      opfPath: opfPath,
      opfDir: opfDir,
      filenameTitle: null,
      title: title == null || title.isEmpty ? null : title,
      authors: authors,
      spine: spine,
      manifestById: manifestById,
      manifestHrefByFullPath: manifestHrefByFullPath,
    );
  }

  Map<String, int> get spineIndexByHref => {
    for (var i = 0; i < spine.length; i++) spine[i].href: i,
  };

  String readManifestText(_ManifestItem item) {
    final file = filesByPath[item.fullPath];
    if (file == null) {
      throw FormatException('EPUB content file not found: ${item.fullPath}');
    }
    return _decodeFile(file);
  }

  List<TocEntry> readTocEntries() {
    final navItem = manifestById.values.cast<_ManifestItem?>().firstWhere(
      (item) =>
          item != null &&
          (item.properties?.split(RegExp(r'\s+')).contains('nav') ?? false),
      orElse: () => null,
    );
    if (navItem != null) {
      final entries = _readNavToc(navItem);
      if (entries.isNotEmpty) return entries;
    }

    final ncxItem = manifestById.values.cast<_ManifestItem?>().firstWhere(
      (item) => item?.mediaType == 'application/x-dtbncx+xml',
      orElse: () => null,
    );
    if (ncxItem != null) {
      final entries = _readNcxToc(ncxItem);
      if (entries.isNotEmpty) return entries;
    }

    return const [];
  }

  List<TocEntry> _readNcxToc(_ManifestItem tocItem) {
    final tocFile = filesByPath[tocItem.fullPath];
    if (tocFile == null) return const [];
    final doc = xml.XmlDocument.parse(_decodeFile(tocFile));
    final navMap = _firstXmlElementNamed(doc, 'navmap');
    if (navMap == null) return const [];
    return [
      for (final point in _xmlChildrenNamed(navMap, 'navpoint'))
        _tocEntryFromNcxPoint(point, tocItem, null, 0),
    ];
  }

  TocEntry _tocEntryFromNcxPoint(
    xml.XmlElement point,
    _ManifestItem tocItem,
    String? parentTitle,
    int depth,
  ) {
    final label = _textOfFirstXml(
      _firstXmlElementNamed(point, 'navlabel') ?? point,
      'text',
    );
    final content = _firstXmlElementNamed(point, 'content');
    final hrefParts = _resolveTocHref(content?.getAttribute('src'), tocItem);
    final title = _fallbackTitle(label, hrefParts.href, 0);
    final children = [
      for (final child in _xmlChildrenNamed(point, 'navpoint'))
        _tocEntryFromNcxPoint(child, tocItem, title, depth + 1),
    ];
    return TocEntry(
      title: _fallbackTitle(label, hrefParts.href, children.length),
      href: _joinHref(hrefParts.href, hrefParts.anchor),
      parentTitle: parentTitle,
      depth: depth,
      children: children,
    );
  }

  List<TocEntry> _readNavToc(_ManifestItem navItem) {
    final navFile = filesByPath[navItem.fullPath];
    if (navFile == null) return const [];
    final doc = html_parser.parse(_decodeFile(navFile));
    final nav = _elementsNamed(doc, 'nav').cast<dom.Element?>().firstWhere((
      element,
    ) {
      if (element == null) return false;
      final epubType = element.attributes['epub:type'] ?? '';
      final type = element.attributes['type'] ?? '';
      return epubType.split(RegExp(r'\s+')).contains('toc') ||
          type.split(RegExp(r'\s+')).contains('toc');
    }, orElse: () => _firstElementNamed(doc, 'nav'));
    if (nav == null) return const [];
    final list = _firstDirectChildNamed(nav, 'ol') ?? nav;
    return [
      for (final item in _childrenNamed(list, 'li'))
        _tocEntryFromNavLi(item, navItem, null, 0),
    ];
  }

  TocEntry _tocEntryFromNavLi(
    dom.Element li,
    _ManifestItem navItem,
    String? parentTitle,
    int depth,
  ) {
    final labelElement =
        _firstDirectChildNamed(li, 'a') ?? _firstDirectChildNamed(li, 'span');
    final hrefParts = _resolveTocHref(
      labelElement?.attributes['href'],
      navItem,
    );
    final nestedList = _firstDirectChildNamed(li, 'ol');
    final title = _fallbackTitle(labelElement?.text, hrefParts.href, 0);
    final children = nestedList == null
        ? const <TocEntry>[]
        : [
            for (final child in _childrenNamed(nestedList, 'li'))
              _tocEntryFromNavLi(child, navItem, title, depth + 1),
          ];
    return TocEntry(
      title: _fallbackTitle(
        labelElement?.text,
        hrefParts.href,
        children.length,
      ),
      href: _joinHref(hrefParts.href, hrefParts.anchor),
      parentTitle: parentTitle,
      depth: depth,
      children: children,
    );
  }

  ({String? href, String? anchor}) _resolveTocHref(
    String? rawHref,
    _ManifestItem tocItem,
  ) {
    if (rawHref == null || rawHref.trim().isEmpty) {
      return (href: null, anchor: null);
    }
    final hashIndex = rawHref.indexOf('#');
    final rawPathWithQuery = hashIndex < 0
        ? rawHref.trim()
        : rawHref.substring(0, hashIndex).trim();
    final rawAnchor = hashIndex < 0 ? null : rawHref.substring(hashIndex + 1);
    final rawPath = _safeDecode(rawPathWithQuery.split('?').first.trim());
    final anchor = rawAnchor != null && rawAnchor.trim().isNotEmpty
        ? _safeDecode(rawAnchor.trim())
        : null;
    if (rawPath.isEmpty) {
      return (href: tocItem.href, anchor: anchor);
    }

    final tocDir = _dirname(tocItem.fullPath);
    final fullPath = _normalizePath(p.posix.join(tocDir, rawPath));
    final manifestHref = manifestHrefByFullPath[fullPath];
    if (manifestHref != null) {
      return (href: manifestHref, anchor: anchor);
    }

    final opfRelative = _normalizePath(rawPath);
    if (spineIndexByHref.containsKey(opfRelative)) {
      return (href: opfRelative, anchor: anchor);
    }
    return (href: null, anchor: anchor);
  }
}

class _ManifestItem {
  final String id;
  final String href;
  final String fullPath;
  final String? mediaType;
  final String? properties;

  const _ManifestItem({
    required this.id,
    required this.href,
    required this.fullPath,
    this.mediaType,
    this.properties,
  });
}

String _decodeFile(ArchiveFile file) {
  return utf8.decode(file.content as List<int>, allowMalformed: true);
}

String _normalizePath(String value) {
  return p.posix.normalize(value.replaceAll('\\', '/'));
}

String _dirname(String path) {
  final dir = p.posix.dirname(path);
  return dir == '.' ? '' : dir;
}

String _safeDecode(String value) {
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    return value;
  }
}

String? _joinHref(String? href, String? anchor) {
  if (href == null) return null;
  return anchor == null ? href : '$href#$anchor';
}

String _fallbackTitle(String? label, String? href, int childCount) {
  final trimmed = label?.trim();
  if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  if (href != null && href.isNotEmpty) {
    return p.posix.basenameWithoutExtension(href);
  }
  return childCount == 1 ? 'Section' : 'Sections';
}

Iterable<dom.Element> _elementsNamed(dom.Node root, String localName) sync* {
  if (root is dom.Element && _matchesName(root, localName)) {
    yield root;
  }
  for (final child in root.nodes) {
    yield* _elementsNamed(child, localName);
  }
}

dom.Element? _firstElementNamed(dom.Node root, String localName) {
  for (final element in _elementsNamed(root, localName)) {
    return element;
  }
  return null;
}

Iterable<dom.Element> _childrenNamed(dom.Element root, String localName) sync* {
  for (final child in root.children) {
    if (_matchesName(child, localName)) yield child;
  }
}

dom.Element? _firstDirectChildNamed(dom.Element root, String localName) {
  for (final child in root.children) {
    if (_matchesName(child, localName)) return child;
  }
  return null;
}

bool _matchesName(dom.Element element, String localName) {
  final actual = element.localName?.toLowerCase() ?? '';
  final expected = localName.toLowerCase();
  return actual == expected || actual.endsWith(':$expected');
}

Iterable<xml.XmlElement> _xmlElementsNamed(
  xml.XmlNode root,
  String localName,
) sync* {
  if (root is xml.XmlElement && _matchesXmlName(root, localName)) {
    yield root;
  }
  for (final child in root.children) {
    yield* _xmlElementsNamed(child, localName);
  }
}

xml.XmlElement? _firstXmlElementNamed(xml.XmlNode root, String localName) {
  for (final element in _xmlElementsNamed(root, localName)) {
    return element;
  }
  return null;
}

Iterable<xml.XmlElement> _xmlChildrenNamed(
  xml.XmlElement root,
  String localName,
) sync* {
  for (final child in root.children.whereType<xml.XmlElement>()) {
    if (_matchesXmlName(child, localName)) yield child;
  }
}

bool _matchesXmlName(xml.XmlElement element, String localName) {
  return element.name.local.toLowerCase() == localName.toLowerCase();
}

String? _textOfFirstXml(xml.XmlNode root, String localName) {
  final element = _firstXmlElementNamed(root, localName);
  final text = element?.innerText.trim();
  return text == null || text.isEmpty ? null : text;
}
