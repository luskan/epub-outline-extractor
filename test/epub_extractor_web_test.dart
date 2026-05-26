import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_outline_extractor/src/epub_extractor_web.dart';
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';
import 'package:test/test.dart';

void main() {
  group('browser EPUB extractor', () {
    test('extracts chapters and TOC sections from EPUB bytes', () async {
      final result = await EpubExtractor().extract(
        _createMinimalEpub(),
        filename: 'web.epub',
      );

      expect(result.metadata.title, 'Browser EPUB');
      expect(result.chapters, hasLength(2));
      expect(result.chapters.first.text, contains('browser importer'));
      expect(result.chapters.last.text, contains('second browser chapter'));
      expect(result.root.subsections, hasLength(2));
      expect(result.root.subsections.first.title, 'Chapter 1');
      expect(
        result.root.subsections.first.content.single,
        contains('browser importer'),
      );
      expect(result.root.subsections.first.subsections, hasLength(1));
      expect(
        result.root.subsections.first.subsections.single.content.single,
        contains('anchored browser section'),
      );
      expect(result.root.subsections.last.title, 'Chapter 2');
      expect(
        result.root.subsections.last.content.single,
        contains('second browser chapter'),
      );
    });

    test('extracts non-empty sections from C++ Concurrency fixture', () async {
      final fixture = File(
        '/Users/marcin/projects/quizpilgrim/book_tools/pdfs/C++_Concurrency_in_Action_Second_Editio.epub',
      );
      if (!fixture.existsSync()) {
        markTestSkipped('Local C++ Concurrency EPUB fixture is not available.');
        return;
      }

      final result = await EpubExtractor().extract(
        await fixture.readAsBytes(),
        filename: fixture.uri.pathSegments.last,
      );
      final sections = _flattenSections(result.root);
      final nonEmptySections = sections
          .where((section) => section.content.join('\n').trim().isNotEmpty)
          .toList();
      final chapter1 = sections.firstWhere(
        (section) => section.title.startsWith('Chapter 1.'),
      );
      final section11 = sections.firstWhere(
        (section) => section.title.startsWith('1.1. What is concurrency?'),
      );

      expect(result.chapters.length, greaterThan(30));
      expect(sections.length, greaterThan(90));
      expect(nonEmptySections.length, greaterThan(80));
      expect(chapter1.content.single, contains('This chapter covers'));
      expect(section11.content.single, contains('At the simplest'));
    });
  });
}

List<BookSection> _flattenSections(BookSection root) {
  final sections = <BookSection>[];
  void collect(BookSection section) {
    sections.add(section);
    for (final child in section.subsections) {
      collect(child);
    }
  }

  for (final section in root.subsections) {
    collect(section);
  }
  return sections;
}

Uint8List _createMinimalEpub() {
  final archive = Archive()
    ..addFile(
      ArchiveFile.noCompress(
        'mimetype',
        20,
        utf8.encode('application/epub+zip'),
      ),
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
    <dc:title>Browser EPUB</dc:title>
    <dc:identifier id="uid">browser-epub-001</dc:identifier>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="ch1" href="chap01.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="chap02.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
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
  <head><meta name="dtb:uid" content="browser-epub-001"/></head>
  <docTitle><text>Browser EPUB</text></docTitle>
  <navMap>
    <navPoint id="np1" playOrder="1">
      <navLabel><text>Chapter 1</text></navLabel>
      <content src="chap01.xhtml"/>
      <navPoint id="np1-1" playOrder="2">
        <navLabel><text>Section 1.1</text></navLabel>
        <content src="chap01.xhtml#section-1-1"/>
      </navPoint>
    </navPoint>
    <navPoint id="np2" playOrder="3">
      <navLabel><text>Chapter 2</text></navLabel>
      <content src="chap02.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''';
  archive.addFile(
    ArchiveFile('OEBPS/toc.ncx', tocNcx.length, utf8.encode(tocNcx)),
  );

  const chapter = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter 1</title></head>
<body>
  <h1>Chapter 1</h1>
  <p>Some chapter text converted by the browser importer.</p>
  <h2 id="section-1-1">Section 1.1</h2>
  <p>Some anchored browser section text.</p>
</body>
</html>''';
  archive.addFile(
    ArchiveFile('OEBPS/chap01.xhtml', chapter.length, utf8.encode(chapter)),
  );

  const chapter2 = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter 2</title></head>
<body>
  <h1>Chapter 2</h1>
  <p>Some second browser chapter text.</p>
</body>
</html>''';
  archive.addFile(
    ArchiveFile('OEBPS/chap02.xhtml', chapter2.length, utf8.encode(chapter2)),
  );

  return Uint8List.fromList(ZipEncoder().encode(archive));
}
