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
        final actual =
            EpubStructuredContentBuilder.buildFromHtml(f.html, f.plainText);
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
      const html = '<html><body>'
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
      const html = '<html><body>'
          '<p>Padding to exceed the fifty char minimum threshold here.</p>'
          '<pre>\tone\n\t\ttwo</pre>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);
      expect(cleaned.text.contains('    one\n        two'), isTrue);
    });

    test('<figure class="code"><figcaption>Listing</figcaption><pre>...</pre>'
        '</figure> emits caption then code, in DOM order', () {
      const html = '<html><body>'
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
      const html = '<html><body>'
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
      const html = '<html><body>'
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
      const html = '<html><body>'
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
      const html = '<html><body>'
          '<p>Padding-here-for-fifty-characters-yes-still-here-thanks.</p>'
          '<pre>first one</pre>'
          '<pre>second one</pre>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final codeBlocks =
          blocks.where((b) => b.preserveLineBreaks).toList(growable: false);
      expect(codeBlocks, hasLength(2));
      expect(codeBlocks[0].end, lessThanOrEqualTo(codeBlocks[1].start));
    });

    test('two adjacent <pre> blocks with IDENTICAL content still distinct', () {
      const html = '<html><body>'
          '<p>Padding-here-for-fifty-characters-yes-still-here-thanks.</p>'
          '<pre>same content</pre>'
          '<pre>same content</pre>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final codeBlocks =
          blocks.where((b) => b.preserveLineBreaks).toList(growable: false);
      expect(codeBlocks, hasLength(2));
      // Element-identity disambiguation: each <pre> has its own range.
      expect(codeBlocks[0].start, isNot(codeBlocks[1].start));
    });

    test('plain <figcaption> outside code figure stays as paragraph (no italic mark)',
        () {
      const html = '<html><body>'
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
    });

    test('hash validates over plain text', () {
      const html = '<html><body>'
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
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>Apples are red.</li><li>Bananas are yellow.</li>'
          '<li>Cherries are dark.</li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items =
          blocks.where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items, hasLength(3));
      for (final i in items) {
        expect(i.listMarker, '•');
      }
    });

    test('<ol> emits listItem blocks with numeric markers 1./2./3.', () {
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ol><li>First step here.</li><li>Second step here.</li>'
          '<li>Third step here.</li></ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items =
          blocks.where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items, hasLength(3));
      expect(items[0].listMarker, '1.');
      expect(items[1].listMarker, '2.');
      expect(items[2].listMarker, '3.');
    });

    test('<ol type="a"> emits a./b./c. markers', () {
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ol type="a"><li>Alpha.</li><li>Beta.</li><li>Gamma.</li></ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items =
          blocks.where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items.map((b) => b.listMarker), ['a.', 'b.', 'c.']);
    });

    test('<ol type="A"> emits A./B. markers', () {
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ol type="A"><li>Alpha.</li><li>Beta.</li></ol>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items =
          blocks.where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items.map((b) => b.listMarker), ['A.', 'B.']);
    });

    test('list item ranges land on the right substring of plain text', () {
      const html = '<html><body>'
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
      expect(
        cleaned.text.substring(items[1].start, items[1].end),
        'Bananas',
      );
    });

    test('nested list flat emit (outer + inner, DOM order)', () {
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>outer<ul><li>inner</li></ul></li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items =
          blocks.where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items, hasLength(2));
      // DOM order: outer before inner; ranges non-overlapping.
      expect(items[0].end, lessThanOrEqualTo(items[1].start));
    });

    test('<li>outer<ul><li>inner</li></ul>tail</li>: 3 items, DOM order',
        () {
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>outer<ul><li>inner</li></ul>tail</li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items =
          blocks.where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items, hasLength(3));
      // DOM order: outer → inner → tail.
      expect(items[0].end, lessThanOrEqualTo(items[1].start));
      expect(items[1].end, lessThanOrEqualTo(items[2].start));
      // First slice has bullet marker, continuation slice has empty marker.
      expect(items[0].listMarker, '•');
      expect(items[1].listMarker, '•');
      expect(items[2].listMarker, '');
    });

    test(
        '<li><ul><li>inner</li></ul>tail</li>: no prefix → 2 items, '
        'tail keeps bullet', () {
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li><ul><li>inner</li></ul>tail</li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items =
          blocks.where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items, hasLength(2));
      // Inner first, then tail — tail is the outer-li's first slice so it
      // keeps the bullet marker (plan §5.8 trace).
      expect(items[1].listMarker, '•');
    });

    test('<dl><dt>Term</dt><dd>def</dd></dl> emits one definitionItem block',
        () {
      const html = '<html><body>'
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
    });

    test('hash validates for v1.1 list+dl JSON', () {
      const html = '<html><body>'
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
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>Prelude text<pre>code body</pre></li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      // One listItem (for "Prelude text") + one code block (for <pre>).
      final items =
          blocks.where((b) => b.type == ContentBlockType.listItem).toList();
      final codes = blocks.where((b) => b.preserveLineBreaks).toList();
      expect(items, hasLength(1));
      expect(codes, hasLength(1));
      expect(items.single.end, lessThanOrEqualTo(codes.single.start));
    });

    test('JSON round-trips listItem + definitionItem through model parser',
        () {
      const html = '<html><body>'
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
        parsed.annotations
            .any((b) => b.type == ContentBlockType.definitionItem),
        isTrue,
      );
    });

    test('plain text contains list item content (sanity check)', () {
      const html = '<html><body>'
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
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>outer\n  <ul><li>inner</li></ul>\n  tail</li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items =
          blocks.where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items, hasLength(3));
      // DOM order: outer < inner < tail.
      expect(items[0].end, lessThanOrEqualTo(items[1].start));
      expect(items[1].end, lessThanOrEqualTo(items[2].start));
      expect(items[0].listMarker, '•');
      expect(items[1].listMarker, '•');
      expect(items[2].listMarker, '');
    });

    test('pretty-printed no-prefix nested li still emits inner→tail', () {
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li>\n  <ul><li>inner</li></ul>\n  tail</li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items =
          blocks.where((b) => b.type == ContentBlockType.listItem).toList();
      expect(items, hasLength(2));
      expect(items[0].end, lessThanOrEqualTo(items[1].start));
      // Tail is the outer-li's first slice → bullet marker.
      expect(items[1].listMarker, '•');
    });

    test(
        '<dd>before<pre>code</pre>after</dd>: dt/dd shadows on <pre>; no '
        'preserved-boundary straddle', () {
      // Codex round-1 MEDIUM: without block shadowing in findDtDdAncestor,
      // dd's recorded range would straddle the pre's preserved range and
      // ExtractedText constructor would throw.
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<dl><dt>Term</dt><dd>before<pre>code body</pre>after</dd></dl>'
          '</body></html>';
      // Should not throw.
      final blocks = buildFromFullPipeline(html);
      // Pre still emits as a code block.
      expect(
        blocks.where((b) => b.preserveLineBreaks).toList(),
        hasLength(1),
      );
    });

    test('<li><a>foo<div><pre>code</pre></div>bar</a></li>: inline-wrapped '
        'block descendants split listItem slices and emit code block', () {
      // Codex round-2 MEDIUM: a flat li.nodes iteration would treat <a>
      // as one inline child and pop one slice, missing the second slice
      // and the nested code block.
      const html = '<html><body>'
          '<p>Padding so the chapter exceeds fifty characters here.</p>'
          '<ul><li><a>foo<div><pre>code body</pre></div>bar</a></li></ul>'
          '</body></html>';
      final blocks = buildFromFullPipeline(html);
      final items =
          blocks.where((b) => b.type == ContentBlockType.listItem).toList();
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
      const html = '<html><body>'
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
      const html = '<html><body>'
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
      const html = '<html><body>'
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
      const html = '<html><body>'
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
      const html = '<html><body>'
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
      const html = '<html><body>'
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

    test('lists emit in beginning-only section (no fragmentId, with '
        'nextFragmentId)', () {
      // Codex round-1 MEDIUM: _extractUntilElement previously skipped
      // li/dtdd sync, so leading sections produced no listItem blocks.
      const html = '<html><body>'
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
}
