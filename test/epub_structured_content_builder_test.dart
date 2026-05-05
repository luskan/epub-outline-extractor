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
}
