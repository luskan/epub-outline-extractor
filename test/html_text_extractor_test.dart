import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:test/test.dart';

void main() {
  group('extractTextFromHtml', () {
    test('extracts plain text from HTML', () {
      const html = '<p>Hello, world!</p>';

      final result = extractTextFromHtml(html);

      expect(result, 'Hello, world!');
    });

    test('removes script tags', () {
      const html = '''
<body>
  <p>Text before</p>
  <script>alert("bad");</script>
  <p>Text after</p>
</body>
''';

      final result = extractTextFromHtml(html);

      expect(result, contains('Text before'));
      expect(result, contains('Text after'));
      expect(result, isNot(contains('alert')));
    });

    test('removes style tags', () {
      const html = '''
<body>
  <p>Visible text</p>
  <style>.hidden { display: none; }</style>
</body>
''';

      final result = extractTextFromHtml(html);

      expect(result, contains('Visible text'));
      expect(result, isNot(contains('display')));
    });

    test('handles empty HTML', () {
      const html = '<html><body></body></html>';

      final result = extractTextFromHtml(html);

      expect(result, '');
    });

    test('handles whitespace in text', () {
      const html = '<p>Text content</p>';

      final result = extractTextFromHtml(html);

      expect(result, contains('Text content'));
    });
  });

  group('extractTitleFromHtml', () {
    test('extracts h1 as title', () {
      const html =
          '<html><body><h1>Chapter Title</h1><p>Content</p></body></html>';

      final result = extractTitleFromHtml(html, 'fallback.xhtml');

      expect(result, 'Chapter Title');
    });

    test('extracts h2 when no h1', () {
      const html =
          '<html><body><h2>Section Title</h2><p>Content</p></body></html>';

      final result = extractTitleFromHtml(html, 'fallback.xhtml');

      expect(result, 'Section Title');
    });

    test('extracts h3 when no h1 or h2', () {
      const html =
          '<html><body><h3>Subsection</h3><p>Content</p></body></html>';

      final result = extractTitleFromHtml(html, 'fallback.xhtml');

      expect(result, 'Subsection');
    });

    test('extracts title tag when no headings', () {
      const html =
          '<html><head><title>Document Title</title></head><body><p>Content</p></body></html>';

      final result = extractTitleFromHtml(html, 'fallback.xhtml');

      expect(result, 'Document Title');
    });

    test('uses fallback when no title found', () {
      const html = '<html><body><p>Just paragraphs</p></body></html>';

      final result = extractTitleFromHtml(html, 'chapter01.xhtml');

      expect(result, 'chapter01');
    });

    test('handles nested path in fallback', () {
      const html = '<html><body></body></html>';

      final result = extractTitleFromHtml(html, 'content/chapters/intro.xhtml');

      expect(result, 'intro');
    });

    test('skips empty headings', () {
      const html =
          '<html><body><h1>  </h1><h2>Real Title</h2></body></html>';

      final result = extractTitleFromHtml(html, 'fallback.xhtml');

      expect(result, 'Real Title');
    });
  });

  group('extractSectionText', () {
    test('extracts text between fragments', () {
      const html = '''
<html><body>
<h2 id="intro">Introduction</h2>
<p>This is the intro text.</p>
<h2 id="chapter1">Chapter 1</h2>
<p>This is chapter 1 text.</p>
</body></html>
''';

      final result = extractSectionText(html, 'intro', 'chapter1');

      expect(result, contains('This is the intro text'));
      expect(result, isNot(contains('This is chapter 1')));
    });

    test('returns full content when no fragments specified', () {
      const html = '''
<html><body>
<p>Preface text</p>
<p>More text</p>
</body></html>
''';

      final result = extractSectionText(html, null, null);

      expect(result, contains('Preface text'));
      expect(result, contains('More text'));
    });

    test('returns empty for missing fragment', () {
      const html = '<html><body><p>Some text</p></body></html>';

      final result = extractSectionText(html, 'nonexistent', null);

      expect(result, '');
    });

    test('handles name attribute for fragments', () {
      const html = '''
<html><body>
<a name="section1"></a>
<p>Section 1 content</p>
<a name="section2"></a>
<p>Section 2 content</p>
</body></html>
''';

      final result = extractSectionText(html, 'section1', 'section2');

      expect(result, contains('Section 1 content'));
      expect(result, isNot(contains('Section 2 content')));
    });

    test('stops at same-level heading', () {
      const html = '''
<html><body>
<h2 id="ch1">Chapter 1</h2>
<p>Chapter 1 content</p>
<h2 id="ch2">Chapter 2</h2>
<p>Chapter 2 content</p>
</body></html>
''';

      final result = extractSectionText(html, 'ch1', null);

      expect(result, contains('Chapter 1 content'));
      expect(result, isNot(contains('Chapter 2 content')));
    });

    test('includes sub-sections content', () {
      const html = '''
<html><body>
<h2 id="ch1">Chapter 1</h2>
<p>Intro text</p>
<h3 id="subsec">Subsection</h3>
<p>Subsection content</p>
<h2 id="ch2">Chapter 2</h2>
<p>Chapter 2 content</p>
</body></html>
''';

      final result = extractSectionText(html, 'ch1', null);

      expect(result, contains('Intro text'));
      expect(result, contains('Subsection content'));
      expect(result, isNot(contains('Chapter 2 content')));
    });

    // Regression: Google Docs and other authoring tools emit fragment IDs
    // like `h.9ugsminh1ia2` where the `.` would be interpreted as a CSS
    // class separator and the digit-led tail would fail ident parsing.
    test('extracts section for fragment id containing a dot', () {
      const html = '''
<html><body>
<h2 id="h.9ugsminh1ia2">Intro</h2>
<p>Intro text</p>
<h2 id="h.another1id">Chapter 1</h2>
<p>Chapter 1 text</p>
</body></html>
''';

      final result =
          extractSectionText(html, 'h.9ugsminh1ia2', 'h.another1id');

      expect(result, contains('Intro text'));
      expect(result, isNot(contains('Chapter 1 text')));
    });

    test('extracts section for fragment id starting with a digit', () {
      const html = '''
<html><body>
<h2 id="1stsection">First</h2>
<p>First text</p>
<h2 id="2ndsection">Second</h2>
<p>Second text</p>
</body></html>
''';

      final result = extractSectionText(html, '1stsection', '2ndsection');

      expect(result, contains('First text'));
      expect(result, isNot(contains('Second text')));
    });

    test('handles fragment id with colon (XML-style)', () {
      const html = '''
<html><body>
<h2 id="ns:section1">First</h2>
<p>First text</p>
<h2 id="ns:section2">Second</h2>
<p>Second text</p>
</body></html>
''';

      final result = extractSectionText(html, 'ns:section1', 'ns:section2');

      expect(result, contains('First text'));
      expect(result, isNot(contains('Second text')));
    });
  });

  group('findElementByFragmentId', () {
    test('finds element by id with dot in name', () {
      final doc = html_parser.parse(
        '<html><body><h2 id="h.9ugsminh1ia2">Hi</h2></body></html>',
      );
      final el = findElementByFragmentId(doc, 'h.9ugsminh1ia2');
      expect(el, isNotNull);
      expect(el!.localName, 'h2');
    });

    test('finds element by id starting with a digit', () {
      final doc = html_parser.parse(
        '<html><body><h2 id="9ugsminh1ia2">Hi</h2></body></html>',
      );
      final el = findElementByFragmentId(doc, '9ugsminh1ia2');
      expect(el, isNotNull);
    });

    test('falls back to name attribute when id is absent', () {
      final doc = html_parser.parse(
        '<html><body><a name="legacy.anchor"></a><p>x</p></body></html>',
      );
      final el = findElementByFragmentId(doc, 'legacy.anchor');
      expect(el, isNotNull);
      expect(el!.localName, 'a');
    });

    test('returns null for missing fragment', () {
      final doc = html_parser.parse('<html><body><p>nothing</p></body></html>');
      expect(findElementByFragmentId(doc, 'h.missing'), isNull);
    });

    test('does not throw on ids containing CSS-special characters', () {
      final doc = html_parser.parse(
        '<html><body><span id="weird-:.0id"></span></body></html>',
      );
      expect(
        () => findElementByFragmentId(doc, 'weird-:.0id'),
        returnsNormally,
      );
      expect(findElementByFragmentId(doc, 'weird-:.0id'), isNotNull);
    });

    test('handles ids containing a double-quote', () {
      final doc = html_parser.parse(
        '<html><body><span id=\'has"quote\'></span></body></html>',
      );
      expect(findElementByFragmentId(doc, 'has"quote'), isNotNull);
    });

    test('handles ids containing a backslash', () {
      final doc = html_parser.parse(
        '<html><body><span id="back\\slash"></span></body></html>',
      );
      expect(findElementByFragmentId(doc, r'back\slash'), isNotNull);
    });

    // Locks the trickiest semantic of the helper: even if a matching `name`
    // attribute appears earlier in document order, a later element with a
    // matching `id` must still win — matching the legacy
    // `querySelector('#x') ?? querySelector('[name="x"]')` priority.
    test('prefers id even when name appears earlier in document', () {
      final doc = html_parser.parse(
        '<html><body><a name="x"></a><p id="x">Real</p></body></html>',
      );
      final el = findElementByFragmentId(doc, 'x');
      expect(el, isNotNull);
      expect(el!.localName, 'p');
    });

    test('matches an id placed on the <html> root element', () {
      final doc = html_parser.parse(
        '<html id="h.rooty"><body><p>x</p></body></html>',
      );
      final el = findElementByFragmentId(doc, 'h.rooty');
      expect(el, isNotNull);
      expect(el!.localName, 'html');
    });

    test('first occurrence wins for duplicate ids', () {
      final doc = html_parser.parse(
        '<html><body>'
        '<p id="dup">first</p>'
        '<p id="dup">second</p>'
        '</body></html>',
      );
      final el = findElementByFragmentId(doc, 'dup');
      expect(el, isNotNull);
      expect(el!.text, 'first');
    });
  });

  // Locks the null-fragment + special-char nextFragment path used when the
  // TOC binds a chapter to "from start until this anchor" (codex review).
  group('extractSectionStructured null-fragment + special-char endpoint', () {
    test('respects dot-bearing nextFragmentId boundary', () {
      const html = '''
<html><body>
<p>Leading text.</p>
<h2 id="h.9ugsminh1ia2">Boundary</h2>
<p>Should not be included.</p>
</body></html>
''';
      final result = extractSectionStructured(html, null, 'h.9ugsminh1ia2');
      final text = result.extracted.text;
      expect(text, contains('Leading text'));
      expect(text, isNot(contains('Should not be included')));
      expect(result.sectionEndElement, isNotNull);
      expect(result.sectionEndElement!.localName, 'h2');
    });
  });

  group('getHeadingLevel', () {
    test('returns level for h1-h6', () {
      final doc = html_parser.parse('<h1>H1</h1><h2>H2</h2><h6>H6</h6>');

      expect(getHeadingLevel(doc.querySelector('h1')!), 1);
      expect(getHeadingLevel(doc.querySelector('h2')!), 2);
      expect(getHeadingLevel(doc.querySelector('h6')!), 6);
    });

    test('returns null for non-heading', () {
      final doc = html_parser.parse('<p>Paragraph</p><div>Div</div>');

      expect(getHeadingLevel(doc.querySelector('p')!), isNull);
      expect(getHeadingLevel(doc.querySelector('div')!), isNull);
    });
  });

  group('isBlockElement', () {
    test('returns true for block elements', () {
      final doc = html_parser.parse(
        '<p>P</p><div>Div</div><section>Section</section><h1>H1</h1>',
      );

      expect(isBlockElement(doc.querySelector('p')!), true);
      expect(isBlockElement(doc.querySelector('div')!), true);
      expect(isBlockElement(doc.querySelector('section')!), true);
      expect(isBlockElement(doc.querySelector('h1')!), true);
    });

    test('returns false for inline elements', () {
      final doc = html_parser.parse(
        '<span>Span</span><a>Link</a><strong>Strong</strong>',
      );

      expect(isBlockElement(doc.querySelector('span')!), false);
      expect(isBlockElement(doc.querySelector('a')!), false);
      expect(isBlockElement(doc.querySelector('strong')!), false);
    });
  });

  group('cleanExtractedText', () {
    test('normalizes multiple newlines', () {
      const text = 'Line 1\n\n\n\nLine 2';

      final result = cleanExtractedText(text);

      expect(result, contains('Line 1'));
      expect(result, contains('Line 2'));
      expect(result, isNot(contains('\n\n\n')));
    });

    test('trims lines', () {
      const text = '  Line with spaces  \n  Another line  ';

      final result = cleanExtractedText(text);

      expect(result, contains('Line with spaces'));
      expect(result, contains('Another line'));
    });

    test('removes leading/trailing empty lines', () {
      const text = '\n\nContent\n\n';

      final result = cleanExtractedText(text);

      expect(result, 'Content');
    });
  });

  group('isInsideNoteOrSidebar', () {
    test('detects data-type=note', () {
      final doc = html_parser.parse(
        '<div data-type="note"><p id="test">Content</p></div>',
      );
      final element = doc.querySelector('#test')!;

      expect(isInsideNoteOrSidebar(element), true);
    });

    test('detects epub:type=sidebar', () {
      final doc = html_parser.parse(
        '<aside epub:type="sidebar"><span id="test">Note</span></aside>',
      );
      final element = doc.querySelector('#test')!;

      expect(isInsideNoteOrSidebar(element), true);
    });

    test('detects class with note', () {
      final doc = html_parser.parse(
        '<div class="sidebar-note"><p id="test">Content</p></div>',
      );
      final element = doc.querySelector('#test')!;

      expect(isInsideNoteOrSidebar(element), true);
    });

    test('detects aside element', () {
      final doc = html_parser.parse(
        '<aside><p id="test">Content</p></aside>',
      );
      final element = doc.querySelector('#test')!;

      expect(isInsideNoteOrSidebar(element), true);
    });

    test('returns false for regular content', () {
      final doc = html_parser.parse(
        '<div><p id="test">Regular content</p></div>',
      );
      final element = doc.querySelector('#test')!;

      expect(isInsideNoteOrSidebar(element), false);
    });
  });
}
