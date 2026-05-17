import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';
import 'package:test/test.dart';

void main() {
  group('EpubExtractor', () {
    test('extracts BookSection tree from minimal EPUB', () async {
      final epubBytes = _createMinimalEpub();
      final extractor = EpubExtractor();

      final result = await extractor.extract(epubBytes, filename: 'test.epub');

      expect(result.metadata.title, 'Test EPUB');
      expect(result.root.title, 'Test EPUB');

      // Chapters list (page-level view) — one per spine HTML file.
      expect(result.chapters, hasLength(1));
      expect(result.chapters.first.spineIndex, 0);
      expect(result.chapters.first.filename, 'chapter01.xhtml');
      expect(result.chapters.first.text, contains('introduction'));

      // root.subsections (TOC view) — one depth-0 entry for the only TOC item.
      expect(result.root.subsections, hasLength(1));
      final tocSection = result.root.subsections.first;
      expect(tocSection.title, 'Chapter 1: Introduction');
      expect(tocSection.location, isA<EpubChapterLocation>());
      final loc = tocSection.location as EpubChapterLocation;
      expect(loc.spineIndex, 0);
      expect(loc.href, 'chapter01.xhtml');
      expect(tocSection.subsections, isEmpty);
    });

    test('extractSections=false skips TOC pass but keeps chapters', () async {
      final epubBytes = _createMinimalEpub();
      final extractor = EpubExtractor(extractSections: false);

      final result = await extractor.extract(epubBytes);

      expect(result.chapters, isNotEmpty);
      expect(result.root.subsections, isEmpty);
    });

    test('flattens EPUB3 document-title nav wrapper', () async {
      final epubBytes = _createDocumentTitleWrapperEpub();
      final extractor = EpubExtractor();

      final result = await extractor.extract(epubBytes, filename: 'test.epub');

      expect(result.root.title, 'Test Book');
      expect(result.root.subsections, hasLength(1));
      expect(result.root.subsections.first.title, '1. Activity lifecycle');
      expect(
        result.root.subsections.first.content.single,
        isNot(contains('Test Book')),
      );
    });

    test('uses provided logger instance', () async {
      final logRecords = <String>[];
      final logger = Logger.detached('test-extractor');
      logger.level = Level.ALL;
      logger.onRecord.listen((rec) => logRecords.add(rec.message));

      final extractor = EpubExtractor(logger: logger);
      await extractor.extract(_createMinimalEpub(), filename: 'test.epub');

      // At least one fine-level log went to the injected logger; nothing
      // should have been written to the global root logger from this
      // extraction.
      expect(logRecords, isNotEmpty);
      expect(logRecords.any((m) => m.startsWith('Converting EPUB:')), isTrue);
    });

    test('progress callback reports stages', () async {
      final stages = <String>{};
      final extractor = EpubExtractor();
      await extractor.extract(
        _createMinimalEpub(),
        onProgress: (current, total, stage) => stages.add(stage),
      );

      expect(stages, containsAll(<String>['Parsing EPUB']));
    });
  });
}

Uint8List _createMinimalEpub() {
  final archive = Archive();

  archive.addFile(
    ArchiveFile('mimetype', 20, utf8.encode('application/epub+zip')),
  );

  const containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  archive.addFile(
    ArchiveFile(
      'META-INF/container.xml',
      containerXml.length,
      utf8.encode(containerXml),
    ),
  );

  const contentOpf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Test EPUB</dc:title>
    <dc:identifier id="uid">test-epub-001</dc:identifier>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="chapter1" href="chapter01.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="chapter1"/>
  </spine>
</package>''';
  archive.addFile(
    ArchiveFile(
      'OEBPS/content.opf',
      contentOpf.length,
      utf8.encode(contentOpf),
    ),
  );

  const tocNcx = '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="test-epub-001"/>
  </head>
  <docTitle><text>Test EPUB</text></docTitle>
  <navMap>
    <navPoint id="navPoint-1" playOrder="1">
      <navLabel><text>Chapter 1: Introduction</text></navLabel>
      <content src="chapter01.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''';
  archive.addFile(
    ArchiveFile('OEBPS/toc.ncx', tocNcx.length, utf8.encode(tocNcx)),
  );

  const chapter1 = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter 1</title></head>
<body>
  <h1>Chapter 1: Introduction</h1>
  <p>This is the introduction to the test EPUB.</p>
  <p>It contains multiple paragraphs of text.</p>
</body>
</html>''';
  archive.addFile(
    ArchiveFile(
      'OEBPS/chapter01.xhtml',
      chapter1.length,
      utf8.encode(chapter1),
    ),
  );

  final zipEncoder = ZipEncoder();
  return Uint8List.fromList(zipEncoder.encode(archive));
}

Uint8List _createDocumentTitleWrapperEpub() {
  final archive = Archive();

  archive.addFile(
    ArchiveFile('mimetype', 20, utf8.encode('application/epub+zip')),
  );

  const containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="GoogleDoc/package.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  archive.addFile(
    ArchiveFile(
      'META-INF/container.xml',
      containerXml.length,
      utf8.encode(containerXml),
    ),
  );

  const packageOpf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">test-wrapper-epub</dc:identifier>
    <dc:language>en</dc:language>
    <dc:title>Test Book</dc:title>
  </metadata>
  <manifest>
    <item href="nav.xhtml" id="toc" media-type="application/xhtml+xml" properties="nav"/>
    <item href="chapter.xhtml" id="main" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="main"/>
  </spine>
</package>''';
  archive.addFile(
    ArchiveFile(
      'GoogleDoc/package.opf',
      packageOpf.length,
      utf8.encode(packageOpf),
    ),
  );

  const nav = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><meta charset="utf-8"/></head>
  <body>
    <nav epub:type="toc" id="toc">
      <ol>
        <li>
          <a href="chapter.xhtml">Test Book</a>
          <ol>
            <li><a href="chapter.xhtml#h.first">1. Activity lifecycle</a></li>
          </ol>
        </li>
      </ol>
    </nav>
  </body>
</html>''';
  archive.addFile(
    ArchiveFile('GoogleDoc/nav.xhtml', nav.length, utf8.encode(nav)),
  );

  const chapter = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Test Book</title></head>
  <body>
    <h2 id="h.first">1. Activity lifecycle</h2>
    <p>Activity lifecycle body.</p>
  </body>
</html>''';
  archive.addFile(
    ArchiveFile(
      'GoogleDoc/chapter.xhtml',
      chapter.length,
      utf8.encode(chapter),
    ),
  );

  final zipEncoder = ZipEncoder();
  return Uint8List.fromList(zipEncoder.encode(archive));
}
