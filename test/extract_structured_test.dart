import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:test/test.dart';

void main() {
  group('extractStructured (whole-chapter)', () {
    test('records preserved range for <pre>', () {
      const html = '<html><body>'
          '<p>Before code.</p>'
          '<pre>void foo() {\n  return 0;\n}</pre>'
          '<p>After code.</p>'
          '</body></html>';
      final result = extractStructured(html);
      expect(result.preservedRanges, hasLength(1));
      final r = result.preservedRanges.single;
      expect(
        result.text.substring(r.start, r.end),
        'void foo() {\n  return 0;\n}',
      );
    });

    test('normalises tabs to 4 spaces inside <pre>', () {
      const html = '<html><body>'
          '<pre>\tone\n\t\ttwo</pre>'
          '</body></html>';
      final result = extractStructured(html);
      expect(result.preservedRanges, hasLength(1));
      final r = result.preservedRanges.single;
      expect(
        result.text.substring(r.start, r.end),
        '    one\n        two',
      );
    });

    test('records elementRanges for <pre> and <figcaption>', () {
      const html = '<html><body>'
          '<figure class="code">'
          '<figcaption>Listing 1</figcaption>'
          '<pre>code body</pre>'
          '</figure>'
          '</body></html>';
      final result = extractStructured(html);
      // Figcaption + pre both recorded. Find the elements via selector.
      final figcaption = result.document.querySelector('figcaption')!;
      final pre = result.document.querySelector('pre')!;
      expect(result.elementRanges[figcaption], isNotNull);
      expect(result.elementRanges[pre], isNotNull);
      final figRange = result.elementRanges.singleRangeOf(figcaption);
      final preRange = result.elementRanges.singleRangeOf(pre);
      expect(result.text.substring(figRange.start, figRange.end), 'Listing 1');
      expect(result.text.substring(preRange.start, preRange.end), 'code body');
    });

    test('preserved range and pre element range coincide', () {
      const html = '<html><body><pre>verbatim</pre></body></html>';
      final result = extractStructured(html);
      final pre = result.document.querySelector('pre')!;
      final preRange = result.elementRanges.singleRangeOf(pre);
      final preserved = result.preservedRanges.single;
      expect(preRange.start, preserved.start);
      expect(preRange.end, preserved.end);
    });

    test('multiple <pre> blocks in a chapter', () {
      const html = '<html><body>'
          '<pre>first block</pre>'
          '<p>between</p>'
          '<pre>second block</pre>'
          '</body></html>';
      final result = extractStructured(html);
      expect(result.preservedRanges, hasLength(2));
      final pres = result.document.querySelectorAll('pre');
      expect(pres, hasLength(2));
      expect(result.elementRanges[pres[0]], isNotNull);
      expect(result.elementRanges[pres[1]], isNotNull);
      // Different elements get different ranges.
      final r0 = result.elementRanges.singleRangeOf(pres[0]);
      final r1 = result.elementRanges.singleRangeOf(pres[1]);
      expect(r0, isNot(r1));
      expect(result.text.substring(r0.start, r0.end), 'first block');
      expect(result.text.substring(r1.start, r1.end), 'second block');
    });

    test('no <pre>: preservedRanges empty', () {
      const html =
          '<html><body><p>Just prose here.</p></body></html>';
      final result = extractStructured(html);
      expect(result.preservedRanges, isEmpty);
    });
  });

  group('extractSectionStructured (fragment-bounded)', () {
    test('returns sectionStartElement and sectionEndElement', () {
      const html = '''
<html><body>
<h2 id="s1">Section One</h2>
<p>One.</p>
<h2 id="s2">Section Two</h2>
<p>Two.</p>
</body></html>
''';
      final result = extractSectionStructured(html, 's1', 's2');
      expect(result.sectionStartElement, isNotNull);
      expect(result.sectionStartElement!.id, 's1');
      expect(result.sectionEndElement, isNotNull);
      expect(result.sectionEndElement!.id, 's2');
    });

    test('records <pre> inside section bounds', () {
      const html = '''
<html><body>
<h2 id="s1">Section One</h2>
<p>Intro.</p>
<pre>code in s1</pre>
<h2 id="s2">Section Two</h2>
<pre>code in s2</pre>
</body></html>
''';
      final result = extractSectionStructured(html, 's1', 's2');
      expect(result.extracted.preservedRanges, hasLength(1));
      final r = result.extracted.preservedRanges.single;
      expect(
        result.extracted.text.substring(r.start, r.end),
        'code in s1',
      );
    });

    test('handles missing fragment gracefully', () {
      const html = '<html><body><p>x</p></body></html>';
      final result = extractSectionStructured(html, 'nope', null);
      expect(result.sectionStartElement, isNull);
      expect(result.extracted.text, isEmpty);
    });
  });

  group('cleanExtractedTextRespectingRanges integration', () {
    test('end-to-end: extract → clean → preserved content survives', () {
      const html = '<html><body>'
          '<p>Before.</p>'
          '<pre>def f():\n    return 42</pre>'
          '<p>After.</p>'
          '</body></html>';
      final raw = extractStructured(html);
      final cleaned = TextCleaner.cleanExtractedTextRespectingRanges(raw);

      // Preserved content survives in cleaned text.
      expect(cleaned.text.contains('def f():\n    return 42'), isTrue);
      // ElementRanges remap correctly.
      final pre = cleaned.document.querySelector('pre')!;
      expect(cleaned.elementRanges[pre], isNotNull);
      final preRange = cleaned.elementRanges.singleRangeOf(pre);
      expect(
        cleaned.text.substring(preRange.start, preRange.end),
        'def f():\n    return 42',
      );
    });
  });
}
