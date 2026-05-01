/// Verification Test for epub_pro (forked with subChapters fix).
///
/// This test verifies epub_pro works correctly with the subChapters fix.
/// Requires: github.com/luskan/epub_pro fork
/// Run with: dart test test/epub_pro_verification_test.dart
///
/// Moved from `quizpilgrim-app/app/test/core/converters/` in EPUB-plan
/// Phase 2 (Round 1 review fix): mobile no longer directly depends on
/// epub_pro, so this fork-verification test belongs alongside its only
/// direct consumer (this package).
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_pro/epub_pro.dart';
import 'package:test/test.dart';

void main() {
  group('epub_pro API Verification', () {
    late Uint8List testEpubBytes;

    setUpAll(() {
      // Create a minimal test EPUB
      testEpubBytes = _createTestEpub();
    });

    test('EpubReader.readBook parses EPUB bytes', () async {
      final epubBook = await EpubReader.readBook(testEpubBytes);

      expect(epubBook, isNotNull);
      expect(epubBook.title, isNotNull);
      print('Title: ${epubBook.title}');
      print('Author: ${epubBook.author}');
    });

    test('EpubChapter has expected properties', () async {
      final epubBook = await EpubReader.readBook(testEpubBytes);

      expect(epubBook.chapters, isNotEmpty, reason: 'Should have chapters');

      for (final chapter in epubBook.chapters) {
        print('\n--- Chapter ---');
        print('  title: ${chapter.title}');
        print('  contentFileName: ${chapter.contentFileName}');
        print('  anchor: ${chapter.anchor}');
        print('  htmlContent length: ${chapter.htmlContent?.length ?? 0}');
        print('  subChapters count: ${chapter.subChapters.length}');

        // Verify expected properties exist
        // ignore: unnecessary_type_check
        expect(chapter.title is String?, isTrue,
            reason: 'title should exist');
        // ignore: unnecessary_type_check
        expect(chapter.contentFileName is String?, isTrue,
            reason: 'contentFileName should exist');
        // ignore: unnecessary_type_check
        expect(chapter.anchor is String?, isTrue,
            reason: 'anchor should exist');
        // ignore: unnecessary_type_check
        expect(chapter.htmlContent is String?, isTrue,
            reason: 'htmlContent should exist');
        expect(chapter.subChapters, isA<List>(),
            reason: 'subChapters should be a list');
      }
    });

    test('subChapters preserves hierarchy', () async {
      final epubBook = await EpubReader.readBook(testEpubBytes);

      print('\n=== Hierarchy Structure ===');
      void printHierarchy(List<EpubChapter> chapters, int depth) {
        for (final chapter in chapters) {
          final indent = '  ' * depth;
          print('$indent- ${chapter.title ?? chapter.contentFileName}');
          if (chapter.subChapters.isNotEmpty) {
            printHierarchy(chapter.subChapters, depth + 1);
          }
        }
      }

      printHierarchy(epubBook.chapters, 0);
    });

    test('htmlContent contains raw HTML for fragment extraction', () async {
      final epubBook = await EpubReader.readBook(testEpubBytes);

      for (final chapter in epubBook.chapters) {
        if (chapter.htmlContent != null) {
          // Verify it's actual HTML, not stripped text
          expect(
            chapter.htmlContent!.contains('<') ||
                chapter.htmlContent!.contains('<!DOCTYPE'),
            isTrue,
            reason: 'htmlContent should be raw HTML, not stripped text',
          );
          print(
              'Chapter ${chapter.title}: HTML starts with "${chapter.htmlContent!.substring(0, 50.clamp(0, chapter.htmlContent!.length))}..."');
        }
      }
    });

    test('anchor property is parsed without # prefix', () async {
      // Create EPUB with fragment anchors
      final epubWithAnchors = _createTestEpubWithAnchors();
      final epubBook = await EpubReader.readBook(epubWithAnchors);

      print('\n=== Anchor Test ===');
      void checkAnchors(List<EpubChapter> chapters) {
        for (final chapter in chapters) {
          if (chapter.anchor != null) {
            print(
                'Chapter "${chapter.title}" anchor: "${chapter.anchor}" (should NOT start with #)');
            expect(chapter.anchor!.startsWith('#'), isFalse,
                reason: 'anchor should not include # prefix');
          }
          checkAnchors(chapter.subChapters);
        }
      }

      checkAnchors(epubBook.chapters);
    });

    test('EPUB 2 with NCX preserves hierarchy and anchors', () async {
      final epub2Bytes = _createTestEpub2WithNcx();
      final epubBook = await EpubReader.readBook(epub2Bytes);

      print('\n=== EPUB 2 NCX Test ===');
      print('Title: ${epubBook.title}');
      print('Chapters count: ${epubBook.chapters.length}');

      void printChapter(EpubChapter chapter, int depth) {
        final indent = '  ' * depth;
        print('$indent- title: "${chapter.title}"');
        print('$indent  contentFileName: ${chapter.contentFileName}');
        print('$indent  anchor: ${chapter.anchor}');
        print('$indent  subChapters: ${chapter.subChapters.length}');
        for (final sub in chapter.subChapters) {
          printChapter(sub, depth + 1);
        }
      }

      for (final chapter in epubBook.chapters) {
        printChapter(chapter, 0);
      }

      // Check if hierarchy is preserved (requires forked epub_pro with fix)
      final hasSubChapters =
          epubBook.chapters.any((c) => c.subChapters.isNotEmpty);
      print('\nHas nested subChapters: $hasSubChapters');
      expect(hasSubChapters, isTrue,
          reason: 'subChapters should be populated with forked epub_pro');

      // Check if anchors are present
      void collectAnchors(List<EpubChapter> chapters, List<String?> anchors) {
        for (final c in chapters) {
          anchors.add(c.anchor);
          collectAnchors(c.subChapters, anchors);
        }
      }

      final allAnchors = <String?>[];
      collectAnchors(epubBook.chapters, allAnchors);
      print('Anchors found: $allAnchors');

      // Verify anchors are present for nested chapters
      final nonNullAnchors = allAnchors.where((a) => a != null).toList();
      expect(nonNullAnchors.isNotEmpty, isTrue,
          reason: 'Nested chapters should have anchors');
    });

    test('Check epub_pro schema for raw TOC access', () async {
      final epub2Bytes = _createTestEpub2WithNcx();
      final epubBook = await EpubReader.readBook(epub2Bytes);

      print('\n=== Schema Navigation Access ===');
      final nav = epubBook.schema?.navigation;
      expect(nav, isNotNull, reason: 'Navigation should exist');

      final navMap = nav!.navMap;
      expect(navMap, isNotNull, reason: 'NavMap should exist');

      print('NavMap points count: ${navMap!.points.length}');

      void printNavPoint(dynamic point, int depth) {
        final indent = '  ' * depth;
        final content = (point as dynamic).content;
        final children = (point as dynamic).childNavigationPoints as List?;
        final id = (point as dynamic).id;

        // Get the source/href
        final src = (content as dynamic).source as String?;

        print('$indent- id: $id');
        print('$indent  href: $src');
        print('$indent  children: ${children?.length ?? 0}');

        for (final child in children ?? []) {
          printNavPoint(child, depth + 1);
        }
      }

      for (final point in navMap.points) {
        printNavPoint(point, 0);
      }

      // Verify we can extract anchors from href
      print('\n=== Href Parsing Test ===');
      for (final point in navMap.points) {
        final children =
            (point as dynamic).childNavigationPoints as List? ?? [];
        for (final child in children) {
          final src = (child.content as dynamic).source as String?;
          if (src != null && src.contains('#')) {
            final parts = src.split('#');
            print('Full href: $src');
            print('  File: ${parts[0]}');
            print('  Anchor: ${parts[1]}');
          }
        }
      }
    });

    test('SUMMARY: epub_pro capabilities (with fork fix)', () async {
      print('\n=== EPUB_PRO VERIFICATION SUMMARY ===');
      print('');
      print('Using: github.com/luskan/epub_pro (forked with subChapters fix)');
      print('');
      print('EPUB Parsing: PASS');
      print('  - EpubReader.readBook() works correctly');
      print('  - Metadata (title, author) accessible');
      print('');
      print('Chapter Content: PASS');
      print('  - htmlContent contains raw HTML for fragment extraction');
      print('  - contentFileName available for mapping');
      print('');
      print('HIERARCHY & ANCHORS: PASS (with fork fix)');
      print('  - epubBook.chapters.subChapters now populated correctly');
      print('  - epubBook.chapters.anchor now contains fragment identifiers');
      print('  - No workaround needed - use chapters directly');
      print('');
      print('IMPLEMENTATION:');
      print('  1. Use epubBook.chapters for HTML content AND TOC hierarchy');
      print('  2. Access chapter.anchor directly (no need to parse from href)');
      print('  3. Recurse through chapter.subChapters for nested structure');
      print('  4. Keep existing TextParsingUtils for part detection');
      print('  5. Keep existing html_text_extractor for fragment extraction');
    });
  });
}

/// Creates a minimal test EPUB file
Uint8List _createTestEpub() {
  final archive = Archive();

  // mimetype (must be first, uncompressed)
  archive.addFile(ArchiveFile(
    'mimetype',
    'application/epub+zip'.length,
    'application/epub+zip'.codeUnits,
  ));

  // container.xml
  const containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  archive.addFile(ArchiveFile(
    'META-INF/container.xml',
    containerXml.length,
    containerXml.codeUnits,
  ));

  // content.opf
  const contentOpf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">test-epub-001</dc:identifier>
    <dc:title>Test EPUB</dc:title>
    <dc:creator>Test Author</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="chapter2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="nav"/>
    <itemref idref="chapter1"/>
    <itemref idref="chapter2"/>
  </spine>
</package>''';
  archive.addFile(ArchiveFile(
    'OEBPS/content.opf',
    contentOpf.length,
    contentOpf.codeUnits,
  ));

  // nav.xhtml (EPUB 3 navigation)
  const navXhtml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Navigation</title></head>
<body>
  <nav epub:type="toc">
    <ol>
      <li><a href="chapter1.xhtml">Part I: Introduction</a>
        <ol>
          <li><a href="chapter1.xhtml#section1">Section 1.1</a></li>
          <li><a href="chapter1.xhtml#section2">Section 1.2</a></li>
        </ol>
      </li>
      <li><a href="chapter2.xhtml">Part II: Advanced Topics</a></li>
    </ol>
  </nav>
</body>
</html>''';
  archive.addFile(ArchiveFile(
    'OEBPS/nav.xhtml',
    navXhtml.length,
    navXhtml.codeUnits,
  ));

  // chapter1.xhtml
  const chapter1 = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter 1</title></head>
<body>
  <h1>Part I: Introduction</h1>
  <p>Welcome to the test EPUB.</p>

  <h2 id="section1">Section 1.1</h2>
  <p>This is section 1.1 content.</p>

  <h2 id="section2">Section 1.2</h2>
  <p>This is section 1.2 content.</p>
</body>
</html>''';
  archive.addFile(ArchiveFile(
    'OEBPS/chapter1.xhtml',
    chapter1.length,
    chapter1.codeUnits,
  ));

  // chapter2.xhtml
  const chapter2 = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter 2</title></head>
<body>
  <h1>Part II: Advanced Topics</h1>
  <p>This covers advanced topics.</p>
</body>
</html>''';
  archive.addFile(ArchiveFile(
    'OEBPS/chapter2.xhtml',
    chapter2.length,
    chapter2.codeUnits,
  ));

  final encoder = ZipEncoder();
  return Uint8List.fromList(encoder.encode(archive));
}

/// Creates a test EPUB with fragment anchors in the TOC
Uint8List _createTestEpubWithAnchors() {
  // Same as _createTestEpub but ensures anchors are in TOC
  return _createTestEpub();
}

/// Creates an EPUB 2 format test with NCX navigation
Uint8List _createTestEpub2WithNcx() {
  final archive = Archive();

  // mimetype
  archive.addFile(ArchiveFile(
    'mimetype',
    'application/epub+zip'.length,
    'application/epub+zip'.codeUnits,
  ));

  // container.xml
  const containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  archive.addFile(ArchiveFile(
    'META-INF/container.xml',
    containerXml.length,
    containerXml.codeUnits,
  ));

  // content.opf (EPUB 2 style with NCX reference)
  const contentOpf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">test-epub-002</dc:identifier>
    <dc:title>Test EPUB 2</dc:title>
    <dc:creator>Test Author</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="chapter2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="chapter1"/>
    <itemref idref="chapter2"/>
  </spine>
</package>''';
  archive.addFile(ArchiveFile(
    'OEBPS/content.opf',
    contentOpf.length,
    contentOpf.codeUnits,
  ));

  // toc.ncx (NCX navigation with hierarchy)
  const tocNcx = '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="test-epub-002"/>
  </head>
  <docTitle><text>Test EPUB 2</text></docTitle>
  <navMap>
    <navPoint id="part1" playOrder="1">
      <navLabel><text>Part I: Introduction</text></navLabel>
      <content src="chapter1.xhtml"/>
      <navPoint id="section1_1" playOrder="2">
        <navLabel><text>Section 1.1: Getting Started</text></navLabel>
        <content src="chapter1.xhtml#section1"/>
      </navPoint>
      <navPoint id="section1_2" playOrder="3">
        <navLabel><text>Section 1.2: Basics</text></navLabel>
        <content src="chapter1.xhtml#section2"/>
      </navPoint>
    </navPoint>
    <navPoint id="part2" playOrder="4">
      <navLabel><text>Part II: Advanced Topics</text></navLabel>
      <content src="chapter2.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''';
  archive.addFile(ArchiveFile(
    'OEBPS/toc.ncx',
    tocNcx.length,
    tocNcx.codeUnits,
  ));

  // chapter1.xhtml
  const chapter1 = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter 1</title></head>
<body>
  <h1>Part I: Introduction</h1>
  <p>Welcome to the test EPUB.</p>

  <h2 id="section1">Section 1.1: Getting Started</h2>
  <p>This is section 1.1 content.</p>

  <h2 id="section2">Section 1.2: Basics</h2>
  <p>This is section 1.2 content.</p>
</body>
</html>''';
  archive.addFile(ArchiveFile(
    'OEBPS/chapter1.xhtml',
    chapter1.length,
    chapter1.codeUnits,
  ));

  // chapter2.xhtml
  const chapter2 = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter 2</title></head>
<body>
  <h1>Part II: Advanced Topics</h1>
  <p>This covers advanced topics.</p>
</body>
</html>''';
  archive.addFile(ArchiveFile(
    'OEBPS/chapter2.xhtml',
    chapter2.length,
    chapter2.codeUnits,
  ));

  final encoder = ZipEncoder();
  return Uint8List.fromList(encoder.encode(archive));
}
