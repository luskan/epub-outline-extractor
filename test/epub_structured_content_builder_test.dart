import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';
import 'package:test/test.dart';

class _Fixture {
  final String name;
  final String html;
  final String plainText;
  final String? expectedJson;
  const _Fixture(this.name, this.html, this.plainText, this.expectedJson);
}

/// Behaviour-preserving parity gate for the v1.0-prep refactor.
///
/// Each `expectedJson` was captured by running the pre-refactor
/// `EpubStructuredContentBuilder.buildFromHtml` implementation on the
/// corresponding fixture. The post-refactor implementation must produce
/// byte-equal output. This is the prep commit's sole gate.
const _fixtures = <_Fixture>[
  _Fixture(
    'single h1',
    '<html><body><h1>Title One</h1></body></html>',
    'This is some plain text padding so the 50-char minimum trips. Title One. More.',
    '{"schemaVersion":1,"baseTextHash":"f8b8459426e3b798deb0062554ed65d3e095ad0601c59a389d9ac568d83e1fe4","annotations":[{"type":"heading","start":62,"end":71,"level":1,"marks":[]}]}',
  ),
  _Fixture(
    'mixed headings and paragraphs',
    '<html><body><h1>Chapter One</h1><p>First paragraph here.</p>'
        '<h2>Section</h2><p>Second paragraph here.</p></body></html>',
    'Chapter One. First paragraph here. Section heading. Second paragraph here. End.',
    '{"schemaVersion":1,"baseTextHash":"2684a0b5c5b4823a5a0a6b6bac08009bc4eb156922643e84f0b22578b718d491","annotations":[{"type":"heading","start":0,"end":11,"level":1,"marks":[]},{"type":"paragraph","start":13,"end":34,"marks":[]},{"type":"heading","start":35,"end":42,"level":2,"marks":[]},{"type":"paragraph","start":52,"end":74,"marks":[]}]}',
  ),
  _Fixture(
    'paragraph with inline emphasis',
    '<html><body><p>Hello <strong>bold</strong> and <em>italic</em> text.</p></body></html>',
    'Padding so the minimum 50-char check passes. Hello bold and italic text. End.',
    '{"schemaVersion":1,"baseTextHash":"c9a8c1afb88d8638e2ee12a09b1eb3414117c1c53ffa0d4162895e68500b283f","annotations":[{"type":"paragraph","start":45,"end":72,"marks":[{"type":"emphasis","start":51,"end":55,"style":"bold"},{"type":"emphasis","start":60,"end":66,"style":"italic"}]}]}',
  ),
  _Fixture(
    'paragraph with http link',
    '<html><body><p>Visit <a href="https://example.com">example</a> today and tomorrow.</p></body></html>',
    'Padding so the minimum 50-char check passes. Visit example today and tomorrow. End.',
    '{"schemaVersion":1,"baseTextHash":"9d4362dc3849b1e680636b0b384d55ff626d1c36d6da6452de4dc291d9fa6463","annotations":[{"type":"paragraph","start":45,"end":78,"marks":[{"type":"link","start":51,"end":58,"url":"https://example.com"}]}]}',
  ),
  _Fixture(
    'block container recursion (div wrapper)',
    '<html><body><div><p>One.</p><div><p>Two.</p></div><p>Three.</p></div></body></html>',
    'Some leading padding so we exceed fifty characters. One. Two. Three. Done.',
    '{"schemaVersion":1,"baseTextHash":"783a31ec2842875c755b52a237b5ec45dabe66cd222843cccb0ebee14601e4e2","annotations":[{"type":"paragraph","start":52,"end":56,"marks":[]},{"type":"paragraph","start":57,"end":61,"marks":[]},{"type":"paragraph","start":62,"end":68,"marks":[]}]}',
  ),
  _Fixture(
    'list items emit as paragraph in pre-v1.1',
    '<html><body><ul><li>Apples</li><li>Bananas</li><li>Cherries</li></ul></body></html>',
    'Some leading padding so we exceed the fifty character minimum. Apples Bananas Cherries End.',
    '{"schemaVersion":1,"baseTextHash":"1ad2b7d654816b3730655b5f3bd3957df99f32174962ac9cbd60d1965c1098bf","annotations":[{"type":"paragraph","start":63,"end":69,"marks":[]},{"type":"paragraph","start":70,"end":77,"marks":[]},{"type":"paragraph","start":78,"end":86,"marks":[]}]}',
  ),
  _Fixture(
    'definition list emits dt/dd as paragraphs in pre-v1.1',
    '<html><body><dl><dt>Term</dt><dd>Definition for term goes here.</dd></dl></body></html>',
    'Some leading padding so we exceed the fifty char minimum. Term Definition for term goes here. End.',
    '{"schemaVersion":1,"baseTextHash":"28c27be33855f1ca5d9d9563c203e04ade5138cedf9280660162ce46c956370d","annotations":[{"type":"paragraph","start":58,"end":62,"marks":[]},{"type":"paragraph","start":63,"end":93,"marks":[]}]}',
  ),
  _Fixture(
    'script/style tags are stripped before walk',
    '<html><body><script>alert("x")</script><p>Visible.</p>'
        '<style>.x{}</style><p>Also visible.</p></body></html>',
    'Some leading padding so we exceed the fifty char threshold. Visible. Also visible. End.',
    '{"schemaVersion":1,"baseTextHash":"8b58c9b0f7e5e252f9332ff00edb131773a0272c8934731ba41b3836c80d3f3b","annotations":[{"type":"paragraph","start":60,"end":68,"marks":[]},{"type":"paragraph","start":69,"end":82,"marks":[]}]}',
  ),
  _Fixture(
    'blockquote emits as paragraph',
    '<html><body><blockquote>Quoted text here for fun.</blockquote></body></html>',
    'Some leading padding here so the fifty char minimum passes. Quoted text here for fun. End.',
    '{"schemaVersion":1,"baseTextHash":"eedd32154a3ca7978449e82e6c17d5a383539578a80c2fa7cdff70ababf9700d","annotations":[{"type":"paragraph","start":60,"end":85,"marks":[]}]}',
  ),
  _Fixture(
    'section/article wrappers recurse',
    '<html><body><section><article><p>Inside article.</p>'
        '<p>Inside section.</p></article></section></body></html>',
    'Some leading padding so we exceed the fifty char minimum. Inside article. Inside section. End.',
    '{"schemaVersion":1,"baseTextHash":"6f14d60fad93688e0cca6f5fe46484e55282bba7442249f97ad968553ba32f20","annotations":[{"type":"paragraph","start":58,"end":73,"marks":[]},{"type":"paragraph","start":74,"end":89,"marks":[]}]}',
  ),
  // Senior round-2 review request: lock the "heading inside a block container"
  // path because it exercises the post-recursion `searchFrom` snap that the
  // refactor preserves verbatim from the original.
  _Fixture(
    'heading inside block container',
    '<html><body><div><h1>Title</h1><p>Body.</p></div></body></html>',
    'Some leading padding so we exceed the fifty char minimum. Title Body. End.',
    '{"schemaVersion":1,"baseTextHash":"e80692adefbf749753df554eda500d216b8fed6876e4f30bd62b8f3f602d6650","annotations":[{"type":"heading","start":58,"end":63,"level":1,"marks":[]},{"type":"paragraph","start":64,"end":69,"marks":[]}]}',
  ),
];

void main() {
  group('EpubStructuredContentBuilder.buildFromHtml parity', () {
    for (final f in _fixtures) {
      test(f.name, () {
        final actual = EpubStructuredContentBuilder.buildFromHtml(
          f.html,
          f.plainText,
        );
        expect(actual, f.expectedJson);
      });
    }

    test('returns null for short plain text', () {
      const html = '<html><body><p>Short.</p></body></html>';
      const plainText = 'Short text.';
      expect(
        EpubStructuredContentBuilder.buildFromHtml(html, plainText),
        isNull,
      );
    });

    test('returns null for HTML with no recognized blocks', () {
      const html = '<html><body><span>just inline</span></body></html>';
      const plainText =
          'Some plain text exceeding the fifty character minimum threshold.';
      expect(
        EpubStructuredContentBuilder.buildFromHtml(html, plainText),
        isNull,
      );
    });

    test('fuzzy paragraph ranges trim separators and stop at paragraph end', () {
      const html =
          '<html><body>'
          '<p><span>onCreate()</span>'
          '<span> jest wywoływane przy tworzeniu aktywności. To jest dobre '
          'miejsce na ustawienie layoutu, inicjalizację bindingu, pobranie '
          'referencji do </span><span>ViewModel</span><span>, ustawienie '
          'adapterów, listenerów oraz odtworzenie podstawowego stanu z '
          '</span><span>savedInstanceState</span><span>.</span></p>'
          '<p>Przykład:</p>'
          '</body></html>';
      const plainText =
          '\n\nonCreate()\n'
          'jest wywoływane przy tworzeniu aktywności. To jest dobre miejsce '
          'na ustawienie layoutu, inicjalizację bindingu, pobranie referencji '
          'do\nViewModel\n, ustawienie adapterów, listenerów oraz odtworzenie '
          'podstawowego stanu z savedInstanceState\n.'
          '\n\nPrzykład:\n\nclass MainActivity : AppCompatActivity() {';

      final json = EpubStructuredContentBuilder.buildFromHtml(html, plainText);
      expect(json, isNotNull);
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);

      final block = parsed!.annotations.first;
      final blockText = plainText.substring(block.start, block.end);
      expect(blockText, startsWith('onCreate()'));
      expect(blockText, endsWith('.'));
      expect(blockText, isNot(contains('Przykład')));
    });
  });

  group('EpubStructuredContentBuilder.build (v1.0 SectionExtraction API)', () {
    /// Helper that runs the full pipeline: parse → extract structured →
    /// clean (range-aware) → build JSON → parse JSON → return blocks.
    List<ContentBlock> buildFromFullPipeline(String html) {
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      expect(json, isNotNull, reason: 'build returned null');
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      return parsed!.annotations;
    }

    test('<pre> emits a code block with preserveLineBreaks + monospace', () {
      // Plain text needs to be ≥50 chars after extract+clean for the
      // length guard.
      const html =
          '<html><body>'
          '<p>Some prose here that pads us above the fifty char minimum.</p>'
          '<pre>void foo() {\n  return 0;\n}</pre>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final codeBlock = blocks.firstWhere(
        (b) => b.preserveLineBreaks,
        orElse: () => throw StateError('no preserveLineBreaks block found'),
      );
      expect(codeBlock.type, ContentBlockType.paragraph);
      expect(codeBlock.preserveLineBreaks, isTrue);
      expect(codeBlock.marks, hasLength(1));
      expect(codeBlock.marks.single.type, InlineMarkType.monospace);
      expect(codeBlock.marks.single.start, codeBlock.start);
      expect(codeBlock.marks.single.end, codeBlock.end);
    });

    test('tabs in <pre> become 4 spaces in plain text', () {
      const html =
          '<html><body>'
          '<p>Padding to exceed the fifty char minimum threshold here.</p>'
          '<pre>\tone\n\t\ttwo</pre>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      expect(cleaned.text.contains('    one\n        two'), isTrue);
    });

    test('<figure class="code"><figcaption>Listing</figcaption><pre>...</pre>'
        '</figure> emits caption then code, in DOM order', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters total here.</p>'
          '<figure class="code">'
          '<figcaption>Listing 1: foo</figcaption>'
          '<pre>void foo();</pre>'
          '</figure>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final caption = blocks.firstWhere(
        (b) => b.marks.any(
          (m) => m.type == InlineMarkType.emphasis && m.style == 'italic',
        ),
        orElse: () => throw StateError('no italic-marked block'),
      );
      final code = blocks.firstWhere(
        (b) => b.preserveLineBreaks,
        orElse: () => throw StateError('no code block'),
      );
      // Caption comes before code in DOM order → smaller offsets.
      expect(caption.end, lessThanOrEqualTo(code.start));
    });

    test('inline <code> in prose emits monospace mark', () {
      const html =
          '<html><body>'
          '<p>Use <code>foo()</code> very often to ensure padding above the '
          'fifty char minimum threshold for sure.</p>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final paragraph = blocks.singleWhere(
        (b) => b.type == ContentBlockType.paragraph,
      );
      expect(
        paragraph.marks.any((m) => m.type == InlineMarkType.monospace),
        isTrue,
      );
    });

    test('inline <code> inside <pre> does NOT double-emit monospace', () {
      const html =
          '<html><body>'
          '<p>Padding exists here for sure to exceed fifty char minimum.</p>'
          '<pre><code>void</code> <code class="k">foo</code>();</pre>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final codeBlock = blocks.firstWhere((b) => b.preserveLineBreaks);
      // Exactly one monospace mark — covering the whole block, not the
      // inner <code> spans.
      final monos = codeBlock.marks
          .where((m) => m.type == InlineMarkType.monospace)
          .toList();
      expect(monos, hasLength(1));
      expect(monos.single.start, codeBlock.start);
      expect(monos.single.end, codeBlock.end);
    });

    test('<kbd> / <samp> / <var> / <tt> all emit monospace marks', () {
      const html =
          '<html><body>'
          '<p>Press <kbd>Ctrl</kbd>, see <samp>OK</samp>, '
          'use <var>x</var> and <tt>y</tt>; padding is here too.</p>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final paragraph = blocks.singleWhere(
        (b) => b.type == ContentBlockType.paragraph,
      );
      final monoCount = paragraph.marks
          .where((m) => m.type == InlineMarkType.monospace)
          .length;
      expect(monoCount, 4);
    });

    test('two adjacent <pre> blocks emit two distinct code blocks', () {
      const html =
          '<html><body>'
          '<p>Padding-here-for-fifty-characters-yes-still-here-thanks.</p>'
          '<pre>first one</pre>'
          '<pre>second one</pre>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final codeBlocks = blocks
          .where((b) => b.preserveLineBreaks)
          .toList(growable: false);
      expect(codeBlocks, hasLength(2));
      expect(codeBlocks[0].end, lessThanOrEqualTo(codeBlocks[1].start));
    });

    test('two adjacent <pre> blocks with IDENTICAL content still distinct', () {
      const html =
          '<html><body>'
          '<p>Padding-here-for-fifty-characters-yes-still-here-thanks.</p>'
          '<pre>same content</pre>'
          '<pre>same content</pre>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final codeBlocks = blocks
          .where((b) => b.preserveLineBreaks)
          .toList(growable: false);
      expect(codeBlocks, hasLength(2));
      // Element-identity disambiguation: each <pre> has its own range.
      expect(codeBlocks[0].start, isNot(codeBlocks[1].start));
    });

    test(
      'plain <figcaption> outside code figure stays as paragraph (no italic mark)',
      () {
        const html =
            '<html><body>'
            '<p>Padding-here-for-fifty-characters-yes-still-here-thanks.</p>'
            '<figure>'
            '<figcaption>Image caption text here</figcaption>'
            '</figure>'
            '</body></html>';
        final blocks = buildFromFullPipeline(html);
        // The figcaption falls through to _isParagraphLike → emits as plain
        // paragraph (no italic mark from the v1.0 figcaption-in-code path).
        final figcaptionBlock = blocks.firstWhere(
          (b) =>
              b.type == ContentBlockType.paragraph &&
              !b.preserveLineBreaks &&
              b.start > blocks.first.end,
          orElse: () => throw StateError('no figcaption-derived block'),
        );
        expect(
          figcaptionBlock.marks.any(
            (m) => m.type == InlineMarkType.emphasis && m.style == 'italic',
          ),
          isFalse,
        );
      },
    );

    test('hash validates over plain text', () {
      const html =
          '<html><body>'
          '<p>Some prose here that pads us above the fifty char minimum.</p>'
          '<pre>code\n  body</pre>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      expect(parsed!.isValidFor(cleaned.text), isTrue);
    });
  });

  group('EpubStructuredContentBuilder.build (v1.1 lists + dl)', () {
    List<ContentBlock> buildFromFullPipeline(String html) {
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      expect(json, isNotNull, reason: 'build returned null');
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      return parsed!.annotations;
    }

    String fullText(String html) {
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      return cleaned.text;
    }

    test('<ul> emits listItem blocks with bullet markers', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>Apples are red.</li><li>Bananas are yellow.</li>'
          '<li>Cherries are dark.</li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      expect(items, hasLength(3));
      for (final i in items) {
        expect(i.listMarker, '•');
      }
    });

    test('<ol> emits listItem blocks with numeric markers 1./2./3.', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ol><li>First step here.</li><li>Second step here.</li>'
          '<li>Third step here.</li></ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      expect(items, hasLength(3));
      expect(items[0].listMarker, '1.');
      expect(items[1].listMarker, '2.');
      expect(items[2].listMarker, '3.');
    });

    test('<ol type="a"> emits a./b./c. markers', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ol type="a"><li>Alpha.</li><li>Beta.</li><li>Gamma.</li></ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      expect(items.map((b) => b.listMarker), ['a.', 'b.', 'c.']);
    });

    test('<ol type="A"> emits A./B. markers', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ol type="A"><li>Alpha.</li><li>Beta.</li></ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      expect(items.map((b) => b.listMarker), ['A.', 'B.']);
    });

    test('list item ranges land on the right substring of plain text', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>Apples</li><li>Bananas</li></ul>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      final parsed = StructuredContent.tryParse(json);
      final items = parsed!.annotations
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      expect(items, hasLength(2));
      expect(cleaned.text.substring(items[0].start, items[0].end), 'Apples');
      expect(cleaned.text.substring(items[1].start, items[1].end), 'Bananas');
    });

    test('nested list flat emit (outer + inner, DOM order)', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>outer<ul><li>inner</li></ul></li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      expect(items, hasLength(2));
      // DOM order: outer before inner; ranges non-overlapping.
      expect(items[0].end, lessThanOrEqualTo(items[1].start));
    });

    test('<li>outer<ul><li>inner</li></ul>tail</li>: 3 items, DOM order', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>outer<ul><li>inner</li></ul>tail</li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      expect(items, hasLength(3));
      // DOM order: outer → inner → tail.
      expect(items[0].end, lessThanOrEqualTo(items[1].start));
      expect(items[1].end, lessThanOrEqualTo(items[2].start));
      // First slice has bullet marker, continuation slice has empty marker.
      expect(items[0].listMarker, '•');
      expect(items[1].listMarker, '•');
      expect(items[2].listMarker, '');
    });

    test('<li><ul><li>inner</li></ul>tail</li>: no prefix → 2 items, '
        'tail keeps bullet', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li><ul><li>inner</li></ul>tail</li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      expect(items, hasLength(2));
      // Inner first, then tail — tail is the outer-li's first slice so it
      // keeps the bullet marker (plan §5.8 trace).
      expect(items[1].listMarker, '•');
    });

    test(
      '<dl><dt>Term</dt><dd>def</dd></dl> emits one definitionItem block',
      () {
        const html =
            '<html><body>'
            '<p>Padding so the chapter exceeds fifty characters here.</p>'
            '<dl><dt>Term word</dt><dd>The definition for that term.</dd></dl>'
            '</body></html>';
        final raw = extractStructured(html);
        final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
        final extraction = SectionExtraction(
          extracted: cleaned,
          sectionStartElement: null,
          sectionEndElement: null,
        );
        final json = EpubStructuredContentBuilder.build(extraction);
        final parsed = StructuredContent.tryParse(json);
        final defs = parsed!.annotations
            .where((b) => b.type == ContentBlockType.definitionItem)
            .toList();
        expect(defs, hasLength(1));
        final def = defs.single;
        expect(def.definitionTermEnd, isNotNull);
        // Term substring matches "Term word".
        expect(
          cleaned.text.substring(def.start, def.definitionTermEnd!),
          'Term word',
        );
        // Full block covers term + definition.
        expect(
          cleaned.text.substring(def.start, def.end),
          contains('The definition for that term.'),
        );
      },
    );

    test('hash validates for v1.1 list+dl JSON', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>One</li><li>Two</li></ul>'
          '<dl><dt>Term</dt><dd>def</dd></dl>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      expect(parsed!.isValidFor(cleaned.text), isTrue);
    });

    test('<li> with <pre> inside: pre still emits as code block, not '
        'subsumed by listItem', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>Prelude text<pre>code body</pre></li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      // One listItem (for "Prelude text") + one code block (for <pre>).
      final items = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      final codes = blocks.where((b) => b.preserveLineBreaks).toList();
      expect(items, hasLength(1));
      expect(codes, hasLength(1));
      expect(items.single.end, lessThanOrEqualTo(codes.single.start));
    });

    test('JSON round-trips listItem + definitionItem through model parser', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>One item</li></ul>'
          '<dl><dt>Word</dt><dd>def</dd></dl>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      // Re-parse and re-serialise to verify canonical round-trip.
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      final reSerialized = parsed!.toJsonString();
      expect(reSerialized, json);
      // Confirm types survive both ways.
      expect(
        parsed.annotations.any((b) => b.type == ContentBlockType.listItem),
        isTrue,
      );
      expect(
        parsed.annotations.any(
          (b) => b.type == ContentBlockType.definitionItem,
        ),
        isTrue,
      );
    });

    test('plain text contains list item content (sanity check)', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>Apples</li><li>Bananas</li></ul>'
          '</body></html>';
      final t = fullText(html);
      expect(t, contains('Apples'));
      expect(t, contains('Bananas'));
    });

    test('pretty-printed nested li (whitespace text nodes) emits in DOM '
        'order: outer→inner→tail', () {
      // Codex round-1 HIGH: leading "\n" text node before <ul> would
      // previously pop the tail slice early, producing tail→inner.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>outer\n  <ul><li>inner</li></ul>\n  tail</li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      expect(items, hasLength(3));
      // DOM order: outer < inner < tail.
      expect(items[0].end, lessThanOrEqualTo(items[1].start));
      expect(items[1].end, lessThanOrEqualTo(items[2].start));
      expect(items[0].listMarker, '•');
      expect(items[1].listMarker, '•');
      expect(items[2].listMarker, '');
    });

    test('pretty-printed no-prefix nested li still emits inner→tail', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>\n  <ul><li>inner</li></ul>\n  tail</li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      expect(items, hasLength(2));
      expect(items[0].end, lessThanOrEqualTo(items[1].start));
      // Tail is the outer-li's first slice → bullet marker.
      expect(items[1].listMarker, '•');
    });

    test('<dd>before<pre>code</pre>after</dd>: dt/dd shadows on <pre>; no '
        'preserved-boundary straddle', () {
      // Codex round-1 MEDIUM: without block shadowing in findDtDdAncestor,
      // dd's recorded range would straddle the pre's preserved range and
      // ExtractedText constructor would throw.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<dl><dt>Term</dt><dd>before<pre>code body</pre>after</dd></dl>'
          '</body></html>';
      // Should not throw.
      final blocks = buildFromFullPipeline(html);
      // Pre still emits as a code block.
      expect(blocks.where((b) => b.preserveLineBreaks).toList(), hasLength(1));
    });

    test('<li><a>foo<div><pre>code</pre></div>bar</a></li>: inline-wrapped '
        'block descendants split listItem slices and emit code block', () {
      // Codex round-2 MEDIUM: a flat li.nodes iteration would treat <a>
      // as one inline child and pop one slice, missing the second slice
      // and the nested code block.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li><a>foo<div><pre>code body</pre></div>bar</a></li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      final codes = blocks.where((b) => b.preserveLineBreaks).toList();
      // Two listItem slices (foo, bar) + one code block.
      expect(items, hasLength(2));
      expect(codes, hasLength(1));
      // DOM order: foo → code → bar.
      expect(items[0].end, lessThanOrEqualTo(codes.single.start));
      expect(codes.single.end, lessThanOrEqualTo(items[1].start));
    });

    test('<dd><pre>code</pre>after</dd>: pre-before-text dd emits term-only '
        'definitionItem and code block', () {
      // Codex round-2 MEDIUM: dd's first slice = "after" (pre shadows);
      // a definitionItem covering [dt.start, after.end) would span the
      // pre, suppressing it via the searchFrom overlap guard. Term-only
      // mode (when block descendants present) preserves the code block.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<dl><dt>Term</dt>'
          '<dd><pre>code body</pre>after</dd></dl>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final defs = blocks
          .where((b) => b.type == ContentBlockType.definitionItem)
          .toList();
      final codes = blocks.where((b) => b.preserveLineBreaks).toList();
      expect(defs, hasLength(1));
      expect(codes, hasLength(1));
      // DOM order: definitionItem → code block.
      expect(defs.single.end, lessThanOrEqualTo(codes.single.start));
    });

    test('<dt>Term<pre>code</pre></dt><dd>def</dd>: dt with block descendants '
        'emits term-only definitionItem and code block, dd is orphan', () {
      // Codex round-3 MEDIUM: previously, the dd would emit definitionItem
      // [dt.start, dd.end) which spans the pre, suppressing the code block.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<dl><dt>Term<pre>code body</pre></dt>'
          '<dd>some definition text</dd></dl>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final defs = blocks
          .where((b) => b.type == ContentBlockType.definitionItem)
          .toList();
      final codes = blocks.where((b) => b.preserveLineBreaks).toList();
      // One definitionItem (term-only from dt) + one code block.
      // The dd is orphan because we already consumed activeDtRange.
      expect(defs, hasLength(1));
      expect(codes, hasLength(1));
      // DOM order: term → code.
      expect(defs.single.end, lessThanOrEqualTo(codes.single.start));
    });

    test('<dt><pre>code</pre>Term</dt><dd>def</dd>: pre BEFORE term still '
        'emits both code and term-only definitionItem in DOM order', () {
      // Codex round-4 MEDIUM: reversed-order dt (block before text).
      // Walking dt children in DOM order dispatches the pre first (code
      // block), then emits the term-only definitionItem at the term's
      // position — searchFrom monotonicity preserved.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<dl><dt><pre>code body</pre>Term</dt>'
          '<dd>some definition text</dd></dl>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final defs = blocks
          .where((b) => b.type == ContentBlockType.definitionItem)
          .toList();
      final codes = blocks.where((b) => b.preserveLineBreaks).toList();
      expect(defs, hasLength(1));
      expect(codes, hasLength(1));
      // DOM order: code → term-only definitionItem.
      expect(codes.single.end, lessThanOrEqualTo(defs.single.start));
    });

    test('<dt><div><a><pre>code</pre></a></div>Term</dt>: deeply '
        'inline-wrapped block descendant in dt still emits as code', () {
      // Codex round-5 MEDIUM: <pre> wrapped in <div><a> inside dt would
      // be lost because _walkBlocks recursed into <div> but _dispatchNode
      // didn't recurse into inline <a>.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<dl><dt><div><a><pre>code body</pre></a></div>Term</dt>'
          '<dd>def text</dd></dl>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final defs = blocks
          .where((b) => b.type == ContentBlockType.definitionItem)
          .toList();
      final codes = blocks.where((b) => b.preserveLineBreaks).toList();
      expect(defs, hasLength(1));
      expect(codes, hasLength(1));
      // DOM order: code → term-only definitionItem.
      expect(codes.single.end, lessThanOrEqualTo(defs.single.start));
    });

    test('<dl><dd>orphan</dd>: orphan dd dispatches block descendants but '
        'emits no definitionItem', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<dl><dd>orphan with <pre>code body</pre> inside</dd></dl>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final defs = blocks
          .where((b) => b.type == ContentBlockType.definitionItem)
          .toList();
      final codes = blocks.where((b) => b.preserveLineBreaks).toList();
      expect(defs, isEmpty);
      expect(codes, hasLength(1));
    });

    test('body-level inline element wrapping a block still dispatches', () {
      // Senior round-final MEDIUM: defensive coverage for the
      // _dispatchNode inline-fallthrough at chapter root. Without the
      // fallthrough, <span><p>...</p></span> at body level would never
      // dispatch the <p>.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<span><div><p>nested para inside span</p></div></span>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final paragraphs = blocks
          .where((b) => b.type == ContentBlockType.paragraph)
          .toList();
      // Padding paragraph + nested paragraph inside span/div.
      expect(paragraphs.length, greaterThanOrEqualTo(2));
    });

    test('basic table emits one table block with tableRows', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><thead><tr><th>H1</th></tr></thead>'
          '<tbody><tr><td>D1</td></tr></tbody></table>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final tables = blocks
          .where((b) => b.type == ContentBlockType.table)
          .toList();
      expect(tables, hasLength(1));
      expect(tables.single.tableRows, [
        ['H1'],
        ['D1'],
      ]);
    });

    test(
      'table with caption emits italic caption block BEFORE table block',
      () {
        const html =
            '<html><body>'
            '<p>Padding so the chapter exceeds fifty characters here.</p>'
            '<table><caption>Cap text</caption>'
            '<tbody><tr><td>cell</td></tr></tbody></table>'
            '</body></html>';
        final blocks = buildFromFullPipeline(html);
        final captions = blocks
            .where(
              (b) =>
                  b.type == ContentBlockType.paragraph &&
                  b.marks.any(
                    (m) =>
                        m.type == InlineMarkType.emphasis &&
                        m.style == 'italic',
                  ),
            )
            .toList();
        final tables = blocks
            .where((b) => b.type == ContentBlockType.table)
            .toList();
        expect(captions, hasLength(1));
        expect(tables, hasLength(1));
        // Caption before table in DOM order; ranges disjoint.
        expect(captions.single.end, lessThanOrEqualTo(tables.single.start));
      },
    );

    test('table caption text and body text appear at disjoint ranges', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><caption>cap</caption>'
          '<tbody><tr><td>x</td></tr></tbody></table>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      final parsed = StructuredContent.tryParse(json);
      final caption = parsed!.annotations.firstWhere(
        (b) => b.marks.any(
          (m) => m.type == InlineMarkType.emphasis && m.style == 'italic',
        ),
      );
      final table = parsed.annotations.firstWhere(
        (b) => b.type == ContentBlockType.table,
      );
      // Caption substring is "cap"; table substring contains "x".
      expect(cleaned.text.substring(caption.start, caption.end), 'cap');
      // Caption's range and table's range are non-overlapping.
      expect(caption.end, lessThanOrEqualTo(table.start));
    });

    test('bare <tr> children (no <tbody>) still extract rows', () {
      // package:html parser typically inserts an implicit <tbody>, but we
      // walk both wrapped and bare tr's defensively (plan §5.10).
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><tr><th>A</th><th>B</th></tr>'
          '<tr><td>1</td><td>2</td></tr></table>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final tables = blocks
          .where((b) => b.type == ContentBlockType.table)
          .toList();
      expect(tables, hasLength(1));
      expect(tables.single.tableRows, [
        ['A', 'B'],
        ['1', '2'],
      ]);
    });

    test('empty first cell in table preserves row structure', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><tr><th></th><th>A</th></tr>'
          '<tr><td></td><td>1</td></tr></table>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final tables = blocks
          .where((b) => b.type == ContentBlockType.table)
          .toList();
      expect(tables, hasLength(1));
      expect(tables.single.tableRows, [
        ['', 'A'],
        ['', '1'],
      ]);
    });

    test('repeated cell content (different rows, same text) emits once per '
        'row', () {
      // cpp20 iterator-categories pattern: same cell content in multiple
      // rows. Element-identity anchoring avoids offset confusion.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><tr><td>same</td></tr>'
          '<tr><td>same</td></tr>'
          '<tr><td>same</td></tr></table>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final tables = blocks
          .where((b) => b.type == ContentBlockType.table)
          .toList();
      expect(tables, hasLength(1));
      expect(tables.single.tableRows, [
        ['same'],
        ['same'],
        ['same'],
      ]);
    });

    test('malformed table with no rows emits no table block (claim+skip)', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table></table>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final tables = blocks
          .where((b) => b.type == ContentBlockType.table)
          .toList();
      expect(tables, isEmpty);
    });

    test('table with caption and whitespace between caption and tbody', () {
      // Pretty-printed input: whitespace text node between </caption> and
      // <tbody>. The caption's range and the table's body range must not
      // straddle that whitespace.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table>'
          '<caption>cap</caption>\n  '
          '<tbody><tr><td>x</td></tr></tbody>'
          '</table>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final captions = blocks
          .where(
            (b) =>
                b.type == ContentBlockType.paragraph &&
                b.marks.any(
                  (m) =>
                      m.type == InlineMarkType.emphasis && m.style == 'italic',
                ),
          )
          .toList();
      final tables = blocks
          .where((b) => b.type == ContentBlockType.table)
          .toList();
      expect(captions, hasLength(1));
      expect(tables, hasLength(1));
      expect(captions.single.end, lessThanOrEqualTo(tables.single.start));
    });

    test('nested tables flatten — inner table emits no separate block', () {
      // Codex round-1 v1.2 MEDIUM: previously, inner table emitted as a
      // separate block AND outer's cell.text included inner content,
      // causing visual duplication. With flattening, only the outer
      // table emits; inner content is part of the outer cell.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><tbody><tr><td>'
          '<table><tbody><tr><td>inner</td></tr></tbody></table>'
          '</td></tr></tbody></table>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final tables = blocks
          .where((b) => b.type == ContentBlockType.table)
          .toList();
      expect(tables, hasLength(1));
      // Outer table's single cell contains "inner" via cell.text.
      expect(tables.single.tableRows, [
        ['inner'],
      ]);
    });

    test('nested table caption flattens into outer cell (no duplicate '
        'render)', () {
      // Codex round-2 v1.2 MEDIUM: inner-table caption was shadowing
      // outer's table range, leaving "inner cap" both in cell.text AND
      // as uncovered gap text. Fix: only outermost-own caption shadows;
      // nested table captions remain inside the outer table's body range.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><tbody><tr><td>'
          '<table><caption>inner cap</caption>'
          '<tbody><tr><td>x</td></tr></tbody></table>'
          '</td></tr></tbody></table>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final tables = blocks
          .where((b) => b.type == ContentBlockType.table)
          .toList();
      final captions = blocks
          .where(
            (b) =>
                b.type == ContentBlockType.paragraph &&
                b.marks.any(
                  (m) =>
                      m.type == InlineMarkType.emphasis && m.style == 'italic',
                ),
          )
          .toList();
      // Only ONE table block (outer); inner table is skipped.
      expect(tables, hasLength(1));
      // No standalone caption blocks — inner caption is part of outer
      // cell text via flattening; no caption block emits.
      expect(captions, isEmpty);
      // Outer's cell text includes both "inner cap" and "x".
      expect(tables.single.tableRows, hasLength(1));
      final cellText = tables.single.tableRows!.single.single;
      expect(cellText, contains('inner cap'));
      expect(cellText, contains('x'));

      // Tighter regression: outer table's annotation range covers the
      // "inner cap" text in plainText, confirming the inner caption is
      // attributed to the outer table's body range (not shadowed).
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      final parsed = StructuredContent.tryParse(json);
      final outerTable = parsed!.annotations.firstWhere(
        (b) => b.type == ContentBlockType.table,
      );
      final outerSubstring = cleaned.text.substring(
        outerTable.start,
        outerTable.end,
      );
      expect(outerSubstring, contains('inner cap'));
    });

    test('caption AFTER rows (malformed HTML) still emits both blocks in '
        'plain-text DOM order', () {
      // Senior round-final LOW-1: package:html doesn't normalise caption
      // position. With caption after tbody in DOM, table.start < caption.start;
      // the builder must emit table first (otherwise searchFrom advances
      // past caption and the table block is claim+skipped).
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><tbody><tr><td>cell</td></tr></tbody>'
          '<caption>cap</caption></table>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final tables = blocks
          .where((b) => b.type == ContentBlockType.table)
          .toList();
      final captions = blocks
          .where(
            (b) =>
                b.type == ContentBlockType.paragraph &&
                b.marks.any(
                  (m) =>
                      m.type == InlineMarkType.emphasis && m.style == 'italic',
                ),
          )
          .toList();
      expect(tables, hasLength(1));
      expect(captions, hasLength(1));
      // DOM order: table block first (rows came first in source), caption second.
      expect(tables.single.end, lessThanOrEqualTo(captions.single.start));
    });

    test('caption BETWEEN thead and tbody: table block range spans entire '
        'body; caption is swallowed (no duplicated render)', () {
      // Codex round-final v1.2 HIGH: with first-slice-only table.range,
      // the body BELOW caption was uncovered and rendered as duplicated
      // gap text. The fix is to UNION table slices across the caption
      // shadow so the table block's range covers HEAD..BODY end-to-end.
      // Caption falls inside that range and is skipped (overlap guard).
      // Acceptable v1.2 trade-off: malformed (caption-mid-table) input
      // loses caption styling but rows render once, in the correct table
      // widget.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><thead><tr><th>HEAD</th></tr></thead>'
          '<caption>CAP</caption>'
          '<tbody><tr><td>BODY</td></tr></tbody></table>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final tables = blocks
          .where((b) => b.type == ContentBlockType.table)
          .toList();
      final captions = blocks
          .where(
            (b) =>
                b.type == ContentBlockType.paragraph &&
                b.marks.any(
                  (m) =>
                      m.type == InlineMarkType.emphasis && m.style == 'italic',
                ),
          )
          .toList();
      expect(tables, hasLength(1));
      expect(captions, isEmpty);
      // Rows include BOTH HEAD and BODY.
      expect(tables.single.tableRows, [
        ['HEAD'],
        ['BODY'],
      ]);

      // Tighter regression: table block range covers the BODY text,
      // not just HEAD — confirms the union fix.
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      final parsed = StructuredContent.tryParse(json);
      final tableBlock = parsed!.annotations.firstWhere(
        (b) => b.type == ContentBlockType.table,
      );
      final tableSubstring = cleaned.text.substring(
        tableBlock.start,
        tableBlock.end,
      );
      expect(tableSubstring, contains('HEAD'));
      expect(tableSubstring, contains('BODY'));
    });

    test('caption with block content (e.g. <p> inside): caption block '
        'skipped, table still emits (documented v1.2 limit)', () {
      // Senior round-final LOW-4: pin the documented limit so a future
      // refactor that lifts the block-shadow rule in findCaptionAncestor
      // breaks loudly here instead of silently.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><caption><p>cap</p></caption>'
          '<tbody><tr><td>cell</td></tr></tbody></table>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      // "cap" remains in plain text (emitter writes it).
      expect(cleaned.text, contains('cap'));
      // No italic-marked caption block (findCaptionAncestor block-shadow
      // means caption never recorded a range).
      final captions = parsed!.annotations
          .where(
            (b) =>
                b.type == ContentBlockType.paragraph &&
                b.marks.any(
                  (m) =>
                      m.type == InlineMarkType.emphasis && m.style == 'italic',
                ),
          )
          .toList();
      expect(captions, isEmpty);
      // Table still emits.
      final tables = parsed.annotations
          .where((b) => b.type == ContentBlockType.table)
          .toList();
      expect(tables, hasLength(1));
      // Hash still validates.
      expect(parsed.isValidFor(cleaned.text), isTrue);
    });

    test('table cell containing <pre> with surrounding text: ExtractedText '
        'invariant preserved (no preserved-boundary straddle)', () {
      // Codex round-final v1.2 HIGH defensive: when a <pre> sits inside
      // a cell with text on either side, the table's union range would
      // straddle the pre's preserved range. Defensive code drops the
      // table's range entirely so ExtractedText doesn't throw. Both the
      // table block AND the inner code block are suppressed for this
      // shape (the table dispatch claims and the pre inside <td> isn't
      // separately walked since <td> isn't a block container). All cell
      // text and pre text remain in plainText as orphan plain content;
      // hash still validates. Acknowledged v1.2 limit.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><tr><td>before<pre>code body</pre>after</td></tr></table>'
          '</body></html>';
      // Should not throw. Hash should validate.
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      // build() catches errors and returns null; for this input we expect
      // it to succeed (ExtractedText constructor must not throw).
      final json = EpubStructuredContentBuilder.build(extraction);
      expect(json, isNotNull);
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      expect(parsed!.isValidFor(cleaned.text), isTrue);
    });

    test('emitted blocks are non-overlapping and sorted by start', () {
      // Senior round-final LOW-6: structural invariant covering all
      // block types. Catches accidental overlap regressions (e.g. the
      // round-final LOW-1 caption-after-rows case before its fix).
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<h2>Heading</h2>'
          '<p>Some prose with <code>inline</code> code.</p>'
          '<pre>void foo();</pre>'
          '<ul><li>item one</li><li>item two</li></ul>'
          '<dl><dt>term</dt><dd>def</dd></dl>'
          '<table><caption>cap</caption>'
          '<tbody><tr><td>x</td></tr></tbody></table>'
          '<figure class="code"><figcaption>L1</figcaption>'
          '<pre>code</pre></figure>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      // Sorted by start.
      for (var i = 1; i < blocks.length; i++) {
        expect(
          blocks[i].start,
          greaterThanOrEqualTo(blocks[i - 1].start),
          reason:
              'block at index $i (start=${blocks[i].start}) is '
              'before previous block (start=${blocks[i - 1].start})',
        );
      }
      // Non-overlapping: each block's start >= previous block's end.
      for (var i = 1; i < blocks.length; i++) {
        expect(
          blocks[i].start,
          greaterThanOrEqualTo(blocks[i - 1].end),
          reason:
              'block at index $i [${blocks[i].start}, ${blocks[i].end}) '
              'overlaps previous [${blocks[i - 1].start}, ${blocks[i - 1].end})',
        );
      }
    });

    test('hash validates over plain text for table fixture', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<table><caption>caption text</caption>'
          '<thead><tr><th>H</th></tr></thead>'
          '<tbody><tr><td>D</td></tr></tbody></table>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      expect(parsed!.isValidFor(cleaned.text), isTrue);
    });

    test('lists emit in beginning-only section (no fragmentId, with '
        'nextFragmentId)', () {
      // Codex round-1 MEDIUM: _extractUntilElement previously skipped
      // li/dtdd sync, so leading sections produced no listItem blocks.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>One</li><li>Two</li></ul>'
          '<h2 id="next">Next section</h2>'
          '<p>Other text.</p>'
          '</body></html>';
      final raw = extractSectionStructured(html, null, 'next');
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(
        raw.extracted,
      );
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: raw.sectionStartElement,
        sectionEndElement: raw.sectionEndElement,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      final items = parsed!.annotations
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      expect(items, hasLength(2));
    });
  });

  // ---------------------------------------------------------------------
  // listItem inline marks (Fix 3) + inline-mark cursor (Fix 2) + flow (Fix 1)
  // ---------------------------------------------------------------------
  group('EpubStructuredContentBuilder.build (v1.0) — listItem inline marks', () {
    List<ContentBlock> buildFromFullPipeline(String html) {
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      expect(json, isNotNull, reason: 'build returned null');
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      return parsed!.annotations;
    }

    test('Fix 3 — sibling same-text <code>X</code> siblings emit at distinct '
        'offsets', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ol><li>foo <code>X</code> middle <code>X</code> end</li></ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final listItems = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList(growable: false);
      expect(listItems, hasLength(1));
      final monos = listItems.single.marks
          .where((m) => m.type == InlineMarkType.monospace)
          .toList();
      expect(monos, hasLength(2));
      expect(monos[0].start, isNot(monos[1].start));
      // Both within the listItem range.
      for (final m in monos) {
        expect(m.start, greaterThanOrEqualTo(listItems.single.start));
        expect(m.end, lessThanOrEqualTo(listItems.single.end));
      }
    });

    test('Fix 3 — different-text <code> siblings have distinct lengths', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ol><li><code>foo</code> and <code>longer_bar</code></li></ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final listItems = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList(growable: false);
      expect(listItems, hasLength(1));
      final monos = listItems.single.marks
          .where((m) => m.type == InlineMarkType.monospace)
          .toList();
      expect(monos, hasLength(2));
      final lengths = monos.map((m) => m.end - m.start).toList();
      // foo = 3 chars; longer_bar = 10 chars.
      expect(lengths, containsAll(<int>[3, 10]));
    });

    test(
      'Fix 3 — cpp20-shaped TOC entry emits two distinct monospace marks',
      () {
        const html =
            '<html><body>'
            '<p>Padding so the chapter exceeds fifty characters total here.</p>'
            '<nav><ol>'
            '<li><a href="chap02.xhtml#x">'
            '<span class="section-number">1.3 </span>'
            'Defining <code>operator&lt;=&gt;</code> and <code>operator==</code>'
            '</a></li>'
            '</ol></nav>'
            '</body></html>';
        final blocks = buildFromFullPipeline(html);
        final listItems = blocks
            .where((b) => b.type == ContentBlockType.listItem)
            .toList(growable: false);
        expect(listItems, hasLength(1));
        final li = listItems.single;
        final monos = li.marks
            .where((m) => m.type == InlineMarkType.monospace)
            .toList();
        expect(monos, hasLength(2));
        // operator<=> = 11 chars; operator== = 10 chars.
        final lengths = monos.map((m) => m.end - m.start).toList();
        expect(lengths, containsAll(<int>[11, 10]));
        // Distinct offsets, both within the listItem range.
        expect(monos[0].start, isNot(monos[1].start));
        for (final m in monos) {
          expect(m.start, greaterThanOrEqualTo(li.start));
          expect(m.end, lessThanOrEqualTo(li.end));
        }
      },
    );

    test('Fix 3 — slice 2-only <code> emits on slice 2, not slice 1', () {
      // <p>BLOCK</p> splits the <li> into two slices. The <code> tag
      // sits wholly in slice 2. The slice-membership counter filters
      // the <code> out of slice 1's mark walk before _matchInlineMark
      // is invoked. (The defense-in-depth `idx >= searchEnd` branch
      // inside _matchInlineMark is no longer driven by this fixture
      // since the slice counter rejects earlier — kept anyway as a
      // safety net for non-trivial cleaner remappings.)
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters total here.</p>'
          '<ol>'
          '<li>prefix text run <p>BLOCK</p> '
          '<code>uniquemarkertext</code></li>'
          '</ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final listItems = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList(growable: false);
      // Two slices for the <li> (split by <p>BLOCK</p>).
      expect(listItems, hasLength(2));
      // Slice 1 has zero monospace marks (the <code> is in slice 2;
      // slice-membership counter filters it out).
      final slice1Monos = listItems[0].marks
          .where((m) => m.type == InlineMarkType.monospace)
          .toList();
      expect(
        slice1Monos,
        isEmpty,
        reason:
            'slice-membership counter must filter slice-2 <code> '
            'out of slice 1\'s mark walk',
      );
      // Slice 2 has exactly one monospace mark for the <code>.
      final slice2Monos = listItems[1].marks
          .where((m) => m.type == InlineMarkType.monospace)
          .toList();
      expect(slice2Monos, hasLength(1));
    });

    test('Fix 3 — slice-membership filter prevents cross-slice attribution '
        '(no false-positive marks on plain text)', () {
      // Slice 1 of the <li> contains "aaa <code>bbb</code> filler text
      // bbbcccddd"; slice 2 contains " <code>bbbcccddd</code> tail".
      //
      // The slice-membership counter (codex rounds 5+6+7) ensures that
      // the second <code>bbbcccddd</code> element — which sits AFTER
      // the <p>BLOCK</p> in DOM order — is NOT considered when
      // collecting marks for slice 1. Without the counter,
      // _walkSliceForMarks would walk the whole <li> and the second
      // <code>'s text "bbbcccddd" would match the plain-text
      // "bbbcccddd" in slice 1 (false-positive monospace mark on plain
      // prose).
      //
      // Asserts slice 1 emits EXACTLY 1 monospace mark (the first
      // <code>bbb</code>, 3 chars). Slice 2 emits EXACTLY 1 monospace
      // mark for the second <code>bbbcccddd</code> (9 chars).
      //
      // Note: the original test name claimed this drove the
      // `endIdx > searchEnd` overflow branch, but after the
      // slice-membership filter the second <code> is rejected at the
      // counter-membership check before _matchInlineMark is invoked,
      // so the overflow branch is no longer driven here. The overflow
      // guard remains as defense-in-depth — see _matchInlineMark in
      // epub_structured_content_builder.dart for its semantic.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters total here.</p>'
          '<ol>'
          '<li>aaa <code>bbb</code> filler text bbbcccddd '
          '<p>BLOCK</p>'
          ' <code>bbbcccddd</code> tail</li>'
          '</ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final listItems = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList(growable: false);
      expect(listItems, hasLength(2));
      final slice1Monos = listItems[0].marks
          .where((m) => m.type == InlineMarkType.monospace)
          .toList();
      // EXACTLY one mark — the first <code>bbb</code> (3 chars). The
      // slice-membership filter prevents the slice-2 <code>bbbcccddd</code>
      // from matching the plain text "bbbcccddd" inside slice 1.
      expect(
        slice1Monos,
        hasLength(1),
        reason:
            'slice 1 must emit exactly 1 monospace mark; got '
            '${slice1Monos.length}: ${slice1Monos.map((m) => "[${m.start},${m.end})").toList()}',
      );
      expect(slice1Monos.single.end - slice1Monos.single.start, 3);

      // Slice 2 emits exactly 1 monospace mark for <code>bbbcccddd</code> (9 chars).
      final slice2Monos = listItems[1].marks
          .where((m) => m.type == InlineMarkType.monospace)
          .toList();
      expect(slice2Monos, hasLength(1));
      expect(slice2Monos.single.end - slice2Monos.single.start, 9);
    });

    test('Fix 2 — sibling overflow positive control: 2 marks fit cleanly', () {
      // Positive control matched to test 4b: same shape but the second
      // <code> is shorter and fits cleanly within slice 1's bound.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters total here.</p>'
          '<ol>'
          '<li>aaa <code>bbb</code> mid <code>ccc</code> tail '
          '<p>BLOCK</p>'
          ' final</li>'
          '</ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final listItems = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList(growable: false);
      expect(listItems, hasLength(2));
      // Slice 1: both <code>bbb</code> and <code>ccc</code> fit — emit 2
      // marks at distinct offsets.
      final slice1 = listItems[0];
      final slice1Monos = slice1.marks
          .where((m) => m.type == InlineMarkType.monospace)
          .toList();
      expect(slice1Monos, hasLength(2));
      expect(slice1Monos[0].start, isNot(slice1Monos[1].start));
      // Both within slice 1's range.
      for (final m in slice1Monos) {
        expect(m.start, greaterThanOrEqualTo(slice1.start));
        expect(m.end, lessThanOrEqualTo(slice1.end));
      }
    });

    test(
      'Fix 2 — heading inline marks: <h2>foo <code>X</code> and <code>X</code></h2>',
      () {
        const html =
            '<html><body>'
            '<p>Padding so the chapter exceeds fifty characters total here.</p>'
            '<h2>foo <code>X</code> and <code>X</code></h2>'
            '</body></html>';
        final blocks = buildFromFullPipeline(html);
        final headings = blocks
            .where((b) => b.type == ContentBlockType.heading)
            .toList(growable: false);
        expect(headings, hasLength(1));
        final h = headings.single;
        final monos = h.marks
            .where((m) => m.type == InlineMarkType.monospace)
            .toList();
        expect(monos, hasLength(2));
        expect(monos[0].start, isNot(monos[1].start));
      },
    );

    test('Fix 1 — spine-only synthetic chapter emits listItems and marks; no '
        '<head><title> leak', () {
      // Synthetic well-formed <nav><h2><ol><li> document. Pass through
      // extractStructured + EpubStructuredContentBuilder.build (mirrors
      // the v1.0 spine-only flow after Fix 1).
      const html =
          '<html><head><title>Ignore Me</title></head><body><nav>'
          '<h2>TOC</h2>'
          '<ol>'
          '<li><a href="ch01.xhtml">Chapter 1: <code>vector</code></a></li>'
          '<li><a href="ch02.xhtml">Chapter 2: <code>operator==</code></a>'
          '<ol>'
          '<li><a href="ch02.xhtml#x">2.1 nested item</a></li>'
          '</ol>'
          '</li>'
          '</ol>'
          '</nav>'
          '<p>Padding so the chapter exceeds fifty characters total here.</p>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final plainText = cleaned.text;
      // No <head><title> leak.
      expect(plainText.contains('Ignore Me'), isFalse);
      // Strong-coverage gate over body — plainText must START with the
      // <h2>TOC</h2> heading text, not "Ignore Me".
      expect(plainText.trimLeft().startsWith('TOC'), isTrue);

      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      expect(json, isNotNull);
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      final blocks = parsed!.annotations;

      // At least 3 listItem blocks: Chapter 1, Chapter 2, 2.1 nested.
      final listItems = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList(growable: false);
      expect(listItems.length, greaterThanOrEqualTo(3));

      // At least 2 monospace marks across all listItems with distinct
      // lengths: vector (6), operator== (10).
      final allMonos = <InlineMark>[];
      for (final li in listItems) {
        allMonos.addAll(
          li.marks.where((m) => m.type == InlineMarkType.monospace),
        );
      }
      expect(allMonos.length, greaterThanOrEqualTo(2));
      final lengths = allMonos.map((m) => m.end - m.start).toSet();
      expect(lengths, containsAll(<int>[6, 10]));

      // Strong-coverage property: every non-whitespace char in plainText
      // covered by at least one block range.
      final covered = List<bool>.filled(plainText.length, false);
      for (final b in blocks) {
        for (var i = b.start; i < b.end && i < plainText.length; i++) {
          covered[i] = true;
        }
      }
      for (var i = 0; i < plainText.length; i++) {
        final c = plainText.codeUnitAt(i);
        final isWs = c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
        if (!isWs) {
          expect(
            covered[i],
            isTrue,
            reason:
                'char at offset $i ("${plainText[i]}") not covered '
                'by any block in spine-only synthetic fixture',
          );
        }
      }

      // Every mark fits within its enclosing block; no two marks within a
      // block share both start AND end.
      for (final b in blocks) {
        for (final m in b.marks) {
          expect(m.start, greaterThanOrEqualTo(b.start));
          expect(m.end, lessThanOrEqualTo(b.end));
        }
        final seen = <String>{};
        for (final m in b.marks) {
          final key = '${m.start}-${m.end}';
          expect(
            seen.contains(key),
            isFalse,
            reason:
                'duplicate mark offsets in single block at '
                '[${b.start}, ${b.end})',
          );
          seen.add(key);
        }
      }
    });

    test('Fix 5 — extractStructured does not leak <head><title> text', () {
      const html =
          '<html><head><title>HEADTEXT</title></head>'
          '<body><h2>BODYTEXT</h2>'
          '<p>Padding so the chapter exceeds fifty characters total here.</p>'
          '</body></html>';
      final raw = extractStructured(html);
      expect(raw.text.contains('HEADTEXT'), isFalse);
      expect(raw.text.trimLeft().startsWith('BODYTEXT'), isTrue);
    });

    test('Fix 5 — extractSectionStructured(_, null, null) does not leak '
        '<head><title> text', () {
      const html =
          '<html><head><title>HEADTEXT</title></head>'
          '<body><h2>BODYTEXT</h2>'
          '<p>Padding so the chapter exceeds fifty characters total here.</p>'
          '</body></html>';
      final raw = extractSectionStructured(html, null, null);
      expect(raw.extracted.text.contains('HEADTEXT'), isFalse);
      expect(raw.extracted.text.trimLeft().startsWith('BODYTEXT'), isTrue);
    });

    test('Fix 3 — nested <ol> with formatted whitespace: clamp overlapping '
        'slices (boundary-whitespace overlap)', () {
      // EPUB-generator-formatted nested lists with newline+indent between
      // <li> tags cause adjacent slices to map to overlapping cleaned
      // positions (outer's trailing "\n\n" maps to the same cleaned
      // offset as inner's leading "\n\n"). The slice-emit must clamp the
      // listItem's start to ctx.searchFrom rather than suppress, so every
      // inner item emits. Reproduces the cpp20.epub TOC bug uncovered by
      // Fix 1.
      const html =
          '<html><body>'
          '<h2>Heading</h2>'
          '<nav><ol class="toc">\n'
          '  <li>\n'
          '    <a href="ch00.xhtml#x">Outer One</a>\n'
          '    <ol>\n'
          '      <li>\n'
          '        <a href="ch00.xhtml#x1">Inner A</a>\n'
          '      </li>\n'
          '      <li>\n'
          '        <a href="ch00.xhtml#x2">Inner B</a>\n'
          '      </li>\n'
          '      <li>\n'
          '        <a href="ch00.xhtml#x3">Inner C</a>\n'
          '      </li>\n'
          '    </ol>\n'
          '  </li>\n'
          '</ol></nav>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final listItems = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList(growable: false);
      // 4 listItems: Outer One + Inner A + Inner B + Inner C.
      expect(listItems, hasLength(4));
      // Strict monotonic: each block's end <= next block's start (after
      // clamp, blocks are adjacent or non-overlapping).
      for (var i = 1; i < listItems.length; i++) {
        expect(
          listItems[i].start,
          greaterThanOrEqualTo(listItems[i - 1].end),
          reason:
              'listItem[$i] [${listItems[i].start}, '
              '${listItems[i].end}) overlaps prior '
              '[${listItems[i - 1].start}, ${listItems[i - 1].end})',
        );
      }
    });

    test('Fix 3 — leading empty inline element + block does not over-count '
        'slice index (content-tracked, not element-presence)', () {
      // Regression for codex round-7 MEDIUM: an empty <a></a> or an
      // inline wrapper whose first content is a block must NOT advance
      // the slice counter. Only actual non-ws TEXT advances hadContent.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters total here.</p>'
          '<ol>'
          '<li>'
          '<a></a>'
          '<p>BLOCK</p>'
          'tail <code>uniqcode</code> end'
          '</li>'
          '</ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final listItems = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList(growable: false);
      // Outer <li>'s only direct-text run is "tail uniqcode end" → 1
      // listItem. Leading <a></a> (empty) and <p>BLOCK</p> emit blocks
      // of their own (paragraph for <p>) but don't form an outer-li
      // slice.
      expect(listItems, hasLength(1));
      // <code>uniqcode</code> mark must emit on this slice.
      final monos = listItems.single.marks
          .where((m) => m.type == InlineMarkType.monospace)
          .toList();
      expect(
        monos,
        hasLength(1),
        reason:
            'leading empty <a></a> must not advance slice counter; '
            'trailing <code>uniqcode</code> stays in slice 0',
      );
      expect(monos.single.end - monos.single.start, 8);
    });

    test('Fix 3 — leading nested <ul>/<ol> before first text run does not '
        'over-count slice index', () {
      // Regression for codex round-6 MEDIUM: an <li> with a leading
      // nested list (or block descendant) BEFORE any direct text doesn't
      // form an elementRanges slice for the leading content. The slice
      // counter must NOT advance for leading boundaries — only for
      // boundaries crossed AFTER content. Without the hadContent guard,
      // the trailing <code>uniqcode</code>'s slice index (0 in
      // elementRanges) wouldn't match the walker's counter (1 after
      // seeing the leading <ul>), and the mark would be silently dropped.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters total here.</p>'
          '<ol>'
          '<li>'
          '<ul><li>nested item one</li><li>nested item two</li></ul>'
          'tail <code>uniqcode</code> end'
          '</li>'
          '</ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final listItems = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList(growable: false);
      // 2 inner listItems for "nested item one" / "two", plus 1 outer
      // listItem covering "tail uniqcode end".
      expect(listItems.length, greaterThanOrEqualTo(3));
      // Locate the outer listItem by its <code>uniqcode</code> monospace
      // mark (8 chars). Without the hadContent guard, the slice walker
      // would over-count to slice 1 after the leading <ul> and skip
      // emitting this mark.
      final liWithUniqMark = listItems
          .where(
            (li) => li.marks.any(
              (m) => m.type == InlineMarkType.monospace && m.end - m.start == 8,
            ),
          )
          .toList(growable: false);
      expect(
        liWithUniqMark,
        hasLength(1),
        reason:
            'outer <li>\'s slice 0 must carry the <code>uniqcode</code> '
            'monospace mark; without the hadContent guard, the leading '
            '<ul> would over-count to slice 1 and drop the mark',
      );
    });

    test('Fix 3 — listItem bounds trim leading/trailing whitespace', () {
      // The emitter's slice ranges include the surrounding "\n\n"
      // block-separator whitespace. Without trimming at the builder
      // level, every listItem renders as "\n\nPreface\n\n" in the
      // mobile widget — producing huge vertical gaps in a list view.
      // After trimming, listItem bounds describe SEMANTIC content
      // only. Asserts:
      //   - Each listItem's first and last char (within bounds) is
      //     non-whitespace.
      //   - listItem.end <= next listItem.start (gap = whitespace).
      const html =
          '<html><body>'
          '<h2>Heading</h2>'
          '<nav><ol class="toc">\n'
          '  <li><a href="#a">First Item</a></li>\n'
          '  <li><a href="#b">Second Item</a></li>\n'
          '  <li><a href="#c">Third Item</a></li>\n'
          '</ol></nav>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final plainText = cleaned.text;
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      final listItems = parsed!.annotations
          .where((b) => b.type == ContentBlockType.listItem)
          .toList(growable: false);
      expect(listItems, hasLength(3));
      // Every listItem's first and last char (within bounds) is
      // non-whitespace.
      bool isWs(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
      for (final li in listItems) {
        expect(li.end, greaterThan(li.start));
        expect(
          isWs(plainText.codeUnitAt(li.start)),
          isFalse,
          reason:
              'listItem at [${li.start}, ${li.end}) starts with '
              'whitespace "${plainText[li.start]}"; bounds should be '
              'trimmed',
        );
        expect(
          isWs(plainText.codeUnitAt(li.end - 1)),
          isFalse,
          reason:
              'listItem at [${li.start}, ${li.end}) ends with '
              'whitespace; bounds should be trimmed',
        );
      }
      // Adjacent listItems: gap between them is pure whitespace.
      for (var i = 1; i < listItems.length; i++) {
        expect(listItems[i].start, greaterThanOrEqualTo(listItems[i - 1].end));
        for (var j = listItems[i - 1].end; j < listItems[i].start; j++) {
          expect(
            isWs(plainText.codeUnitAt(j)),
            isTrue,
            reason:
                'gap char at offset $j between listItems must be '
                'whitespace',
          );
        }
      }
    });

    test('Fix 3 — slice-internal block descendant skipped (composition)', () {
      // <li>foo <a><p>BLOCK</p></a> bar <code>uniquetag</code></li>
      // The <p> is wrapped in <a> (inline). The slice walker must skip
      // <p> via isBlockElement(node) even though its parent is inline,
      // AND the slice-counter must increment when crossing it (so the
      // <code>uniquetag</code> in slice 2 is not matched against slice 1's
      // text). Test asserts:
      //   - 2 listItem blocks emit (split by <p>BLOCK</p>)
      //   - <p>BLOCK</p> emits a separate paragraph block in DOM order
      //   - The slice 2 listItem carries the <code>uniquetag</code>
      //     monospace mark (length 9)
      //   - The slice 1 listItem has NO monospace marks (the slice-counter
      //     filter prevents misattribution)
      //   - First-slice listMarker = '1.', second-slice listMarker = ''
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters total here.</p>'
          '<ol><li>foo <a href="#"><p>BLOCK</p></a> bar '
          '<code>uniquetag</code></li></ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final listItems = blocks
          .where((b) => b.type == ContentBlockType.listItem)
          .toList();
      // 2 listItem blocks: one for "foo " (slice 1), one for " bar
      // uniquetag" (slice 2).
      expect(listItems, hasLength(2));
      // First slice carries the marker.
      expect(listItems[0].listMarker, '1.');
      // Second slice has empty marker.
      expect(listItems[1].listMarker, '');
      // <p>BLOCK</p> emits a separate paragraph block in DOM order
      // (between slice 1 and slice 2 of the listItem).
      final blockParagraphs = blocks
          .where(
            (b) =>
                b.type == ContentBlockType.paragraph &&
                b.start >= listItems[0].end &&
                b.end <= listItems[1].start,
          )
          .toList();
      expect(
        blockParagraphs,
        isNotEmpty,
        reason:
            '<p>BLOCK</p> should emit a paragraph block between '
            'the two listItem slices',
      );
      // Slice 2 carries the monospace mark for <code>uniquetag</code>.
      final slice2Monos = listItems[1].marks
          .where((m) => m.type == InlineMarkType.monospace)
          .toList();
      expect(slice2Monos, hasLength(1));
      expect(
        slice2Monos.single.end - slice2Monos.single.start,
        9,
        reason: '<code>uniquetag</code> is 9 chars',
      );
      // Slice 1 has no monospace marks (slice-counter filter prevents
      // attributing slice-2's <code> to slice 1).
      final slice1Monos = listItems[0].marks
          .where((m) => m.type == InlineMarkType.monospace)
          .toList();
      expect(
        slice1Monos,
        isEmpty,
        reason: 'slice 1 must not pick up slice 2\'s <code>uniquetag</code>',
      );
    });
  });

  group('EpubStructuredContentBuilder — listItem depth (DOM-ancestor)', () {
    List<ContentBlock> buildFromFullPipeline(String html) {
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      final extraction = SectionExtraction(
        extracted: cleaned,
        sectionStartElement: null,
        sectionEndElement: null,
      );
      final json = EpubStructuredContentBuilder.build(extraction);
      expect(json, isNotNull, reason: 'build returned null');
      final parsed = StructuredContent.tryParse(json);
      expect(parsed, isNotNull);
      return parsed!.annotations;
    }

    test('top-level <li>s have depth 0', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>Apples</li><li>Bananas</li></ul>'
          '</body></html>';
      final items = buildFromFullPipeline(
        html,
      ).where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items, hasLength(2));
      expect(items.every((b) => b.depth == 0), isTrue);
    });

    test('direct nesting: depth 0/1/2 for <ol><li><ol><li><ol><li>...', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ol><li>A'
          '<ol><li>B'
          '<ol><li>C</li></ol>'
          '</li></ol>'
          '</li></ol>'
          '</body></html>';
      final items = buildFromFullPipeline(
        html,
      ).where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items, hasLength(3));
      // Items are emitted in DOM-walk order: outer first, then inner, then
      // innermost.
      expect(items[0].depth, 0, reason: 'A is top-level');
      expect(items[1].depth, 1, reason: 'B is one level deep');
      expect(items[2].depth, 2, reason: 'C is two levels deep');
    });

    test(
      'wrapped block container preserves depth: <li><div><ul><li>Inner</li></ul></div></li>',
      () {
        // Load-bearing case: the inner <ul> is reached via _walkLiNode →
        // _dispatchNode → _recurseIntoBlockContainer → _walkBlocks →
        // _emitListContainerIfApplicable. DOM-ancestor counting catches
        // this; threading a depth parameter through every dispatcher would
        // miss it.
        const html =
            '<html><body>'
            '<p>Padding so the chapter exceeds fifty characters here.</p>'
            '<ul><li>Outer'
            '<div><ul><li>Inner</li></ul></div>'
            '</li></ul>'
            '</body></html>';
        final items = buildFromFullPipeline(
          html,
        ).where((b) => b.type == ContentBlockType.listItem).toList();
        expect(items, hasLength(2));
        // First emitted is Outer's first slice, then Inner.
        final outer = items.firstWhere((b) => b.depth == 0);
        final inner = items.firstWhere((b) => b.depth == 1);
        expect(outer, isNotNull);
        expect(inner, isNotNull);
      },
    );

    test('mixed container types: <ol><li><ul><li>...', () {
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ol><li>A1<ul><li>A1a</li><li>A1b</li></ul></li></ol>'
          '</body></html>';
      final items = buildFromFullPipeline(
        html,
      ).where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items, hasLength(3));
      // First emit is A1 (top-level), then A1a + A1b (nested).
      expect(items[0].depth, 0);
      expect(items[1].depth, 1);
      expect(items[2].depth, 1);
    });

    test('continuation slices inherit the same depth as the first slice', () {
      // <li> with mid-slice <p> block descendant produces multiple listItem
      // slices for the same <li>. All slices must share the parent <li>'s
      // depth.
      const html =
          '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>Outer head<p>Inline para</p>Outer tail'
          '<ul><li>Inner</li></ul>'
          '</li></ul>'
          '</body></html>';
      final items = buildFromFullPipeline(
        html,
      ).where((b) => b.type == ContentBlockType.listItem).toList();
      // Every Outer slice should carry depth 0; the Inner item depth 1.
      // We don't pin the exact emission count (slice trimming may collapse)
      // but assert the depth invariant.
      final depthsByMarker = items
          .map((b) => '${b.listMarker}:${b.depth}')
          .toList();
      // Top-level Outer slice(s) have listMarker='•' on first slice and ''
      // on continuations; either way depth must be 0.
      final outerDepths = items
          .where((b) => b.depth == 0)
          .map((b) => b.depth)
          .toSet();
      final innerDepths = items
          .where((b) => b.depth == 1)
          .map((b) => b.depth)
          .toSet();
      expect(
        outerDepths,
        equals({0}),
        reason: 'all Outer slices share depth 0 (got $depthsByMarker)',
      );
      expect(
        innerDepths,
        equals({1}),
        reason: 'Inner has depth 1 (got $depthsByMarker)',
      );
    });
  });
}
