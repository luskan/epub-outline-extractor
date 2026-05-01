import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:logging/logging.dart';
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
      expect(result.root.subsections, hasLength(1));

      final chapter = result.root.subsections.first;
      expect(chapter.title, 'Chapter 1: Introduction');
      expect(chapter.location, isA<EpubChapterLocation>());
      final loc = chapter.location as EpubChapterLocation;
      expect(loc.spineIndex, 0);
      expect(loc.href, 'chapter01.xhtml');
      expect(chapter.content.first, contains('Chapter 1: Introduction'));
    });

    test('extractSections=false skips TOC pass', () async {
      final epubBytes = _createMinimalEpub();
      final extractor = EpubExtractor(extractSections: false);

      final result = await extractor.extract(epubBytes);

      // Chapters still emitted; TOC sub-sections skipped.
      expect(result.root.subsections, isNotEmpty);
      for (final ch in result.root.subsections) {
        expect(ch.subsections, isEmpty);
      }
    });

    test('uses provided logger instance', () async {
      final logRecords = <String>[];
      final logger = Logger.detached('test-extractor');
      logger.level = Level.ALL;
      logger.onRecord.listen((rec) => logRecords.add(rec.message));

      final extractor = EpubExtractor(logger: logger);
      await extractor.extract(_createMinimalEpub(), filename: 'test.epub');

      // At least one info log went to the injected logger; nothing should
      // have been written to the global root logger from this extraction.
      expect(logRecords, isNotEmpty);
      expect(
        logRecords.any((m) => m.startsWith('Converting EPUB:')),
        isTrue,
      );
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
