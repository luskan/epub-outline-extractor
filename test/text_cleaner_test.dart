import 'dart:math';

import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:test/test.dart';

void main() {
  group('TextCleaner.cleanText (legacy) — byte-equality with cleanTextWithScript', () {
    // §7.2: this corpus locks the legacy cleaner's output. The
    // cleanTextWithScript path must produce the same output as the legacy
    // cleanText for every input here.
    final corpus = <String>[
      // Existing fixtures from html_text_extractor_test.dart equivalents.
      '   leading spaces',
      'trailing spaces   ',
      'mixed   spaces   here',
      // cpp20-style slices.
      'class Value {\n  long id;\n  int n;\n};',
      '<pre>void foo() { return 0; }</pre>',
      '\nfunction one()\n\n\nfunction two()\n',
      // DDIA-style slices.
      'a paragraph that wraps\nover several\nlines\n\nnext paragraph',
      'sequence of words separated  by  multiple  spaces',
      'tab\tcharacters\there',
      'data\tin\ta\ttable',
      // Edge cases.
      '',
      ' ',
      '\n',
      '\t',
      // PUA character (U+E000 → mapped to nothing after unmapped strip).
      'beforeafter',
      // Round-3 additions.
      '﻿leading BOM',
      'CRLF\r\nendings\r\nhere',
      'rust 🦀 emoji',
      // Adversarial whitespace patterns.
      '   ',
      '\n\n\n\n',
      '\n \n \n',
      'a\n  \n  \nb',
    ];

    for (final input in corpus) {
      test('parity for ${_escape(input)}', () {
        final legacy = TextCleaner.cleanText(input);
        final viaScript =
            TextCleaner.cleanTextWithScript(input).text;
        expect(viaScript, legacy);
      });
    }
  });

  group('EditScript mapStart/mapEnd semantics (§5.4)', () {
    test('Replace([0,3), " ") on "   "', () {
      final result = TextCleaner.cleanTextWithScript('   ');
      expect(result.text, '');
      // Hmm: input "   " runs through:
      //   pass5 ([ \t]+ → " ") yields " "
      //   pass6 per-line trim → ""
      //   pass8 final trim → ""
      // So mapStart/mapEnd of any offset converges to 0.
      expect(result.script.mapStart(0), 0);
      expect(result.script.mapEnd(3), 0);
    });

    test('Replace on "\\n\\n\\n" → "\\n\\n"', () {
      // Plan §5.4 worked example 2.
      // Input "\n\n\n" goes through:
      //   pass6 per-line trim: 3 newlines + 2 empty lines, joined = "\n\n\n"
      //   pass7 \n{3,} → "\n\n"
      //   pass8 final .trim() → ""
      // The script must collapse the three newlines into ONE atomic edit
      // (Replace then Delete).
      final result = TextCleaner.cleanTextWithScript('\n\n\n');
      expect(result.text, ''); // .trim() removes the surviving "\n\n"
      // Mapping any start within [0,3) → 0 (after collapse + trim).
      expect(result.script.mapStart(0), 0);
      expect(result.script.mapEnd(3), 0);
    });

    test('Keep on "abc"', () {
      final result = TextCleaner.cleanTextWithScript('abc');
      expect(result.text, 'abc');
      expect(result.script.mapStart(0), 0);
      expect(result.script.mapEnd(3), 3);
      expect(result.script.mapStart(1), 1);
      expect(result.script.mapEnd(2), 2);
    });

    test('Delete on "  abc"', () {
      // Plan §5.4 worked example 1.
      final result = TextCleaner.cleanTextWithScript('  abc');
      expect(result.text, 'abc');
      // mapStart(0) skips through Delete to first surviving Keep.
      expect(result.script.mapStart(0), 0);
      // mapEnd(5) is the post-clean end → 3.
      expect(result.script.mapEnd(5), 3);
      // Mid-input offset 2 (the 'a') maps to 0 (start of "abc").
      expect(result.script.mapStart(2), 0);
    });
  });

  group('cleanTextRespectingRanges — preserves <pre> content verbatim', () {
    final document = html_parser.parse('<html><body></body></html>');

    ExtractedText make(
      String text,
      List<TextRange> preserved,
    ) =>
        ExtractedText(
          text: text,
          preservedRanges: preserved,
          elementRanges: const {},
          document: document,
        );

    test('no preserved ranges: byte-equal to legacy cleanText', () {
      const input = 'a   b   c';
      final out = TextCleaner.cleanTextRespectingRanges(make(input, const []));
      expect(out.cleanedText, TextCleaner.cleanText(input));
    });

    test('full-input preserved: text passes through verbatim', () {
      const input = 'preserved   content   here';
      final out = TextCleaner.cleanTextRespectingRanges(
        make(input, [TextRange(0, input.length)]),
      );
      expect(out.cleanedText, input);
    });

    test('preserved <pre>-style range survives whitespace collapse', () {
      const input = 'before  \n[code\n  body  ]\nafter   here';
      // Mark "[code\n  body  ]" preserved.
      final start = input.indexOf('[');
      final end = input.indexOf(']') + 1;
      final out = TextCleaner.cleanTextRespectingRanges(
        make(input, [TextRange(start, end)]),
      );
      expect(out.cleanedText.contains('[code\n  body  ]'), isTrue);
      // Outside-of-preserved gets cleaner treatment: spaces collapse,
      // newlines kept.
      expect(out.cleanedText.contains('before'), isTrue);
      expect(out.cleanedText.contains('after'), isTrue);
    });

    test('preserved range with tabs is normalised to 4 spaces', () {
      const input = 'leading\n\tone\n\t\ttwo\ntrailing';
      final start = input.indexOf('\n') + 1;
      final end = input.lastIndexOf('\n');
      final out = TextCleaner.cleanTextRespectingRanges(
        make(input, [TextRange(start, end)]),
      );
      expect(out.cleanedText.contains('    one'), isTrue);
      expect(out.cleanedText.contains('        two'), isTrue);
      expect(out.cleanedText.contains('\t'), isFalse);
    });

    test('boundary newlines around preserved survive', () {
      const input = 'aa\n\n\n[X]\n\n\nbb';
      final start = input.indexOf('[');
      final end = input.indexOf(']') + 1;
      final out = TextCleaner.cleanTextRespectingRanges(
        make(input, [TextRange(start, end)]),
      );
      // Outside segments collapse \n{3,} → \n\n; preserved is verbatim.
      // Expected: "aa\n\n[X]\n\nbb"
      expect(out.cleanedText, 'aa\n\n[X]\n\nbb');
    });
  });

  group('§7.3 property test: random (text, preservedRanges, elementRanges)', () {
    final document = html_parser.parse('<html><body></body></html>');

    ExtractedText make(
      String text,
      List<TextRange> preserved,
      Map<dom.Element, List<TextRange>> elements,
    ) =>
        ExtractedText(
          text: text,
          preservedRanges: preserved,
          elementRanges: elements,
          document: document,
        );

    test('200 random triples + 8 boundary cases', () {
      final rng = Random(0xC0FFEE);
      const alphabet = 'abc 0123 \t\n';
      for (var iter = 0; iter < 200; iter++) {
        final length = rng.nextInt(64); // keep small for speed
        final buf = StringBuffer();
        for (var i = 0; i < length; i++) {
          buf.write(alphabet[rng.nextInt(alphabet.length)]);
        }
        final text = buf.toString();
        // Generate 0–2 preserved ranges, sorted, non-overlapping, non-empty.
        final preserved = <TextRange>[];
        var cursor = 0;
        final numPreserved = rng.nextInt(3);
        for (var p = 0; p < numPreserved && cursor < length; p++) {
          final maxStart = length - cursor;
          if (maxStart <= 0) break;
          final start = cursor + rng.nextInt(maxStart);
          final maxLen = length - start;
          if (maxLen <= 0) break;
          final len = 1 + rng.nextInt(min(maxLen, 6));
          preserved.add(TextRange(start, start + len));
          cursor = start + len;
        }
        // Run through the cleaner.
        final out = TextCleaner.cleanTextRespectingRanges(
          make(text, preserved, const {}),
        );

        // Inside-preserved invariant: cleaned text contains the verbatim
        // preserved content (with tabs normalised).
        for (final r in preserved) {
          final raw = text.substring(r.start, r.end);
          final expected = raw.replaceAll('\t', '    ').replaceAll('\r', '');
          expect(
            out.cleanedText.contains(expected),
            isTrue,
            reason:
                'iter=$iter preserved $r expected to survive verbatim: '
                'text=${_escape(text)} preserved=${_escape(raw)} '
                'expected=${_escape(expected)} got=${_escape(out.cleanedText)}',
          );
        }
      }
    });

    test('boundary: full-input preserved range', () {
      final out = TextCleaner.cleanTextRespectingRanges(
        make('verbatim', [const TextRange(0, 8)], const {}),
      );
      expect(out.cleanedText, 'verbatim');
    });

    test('boundary: preserved range at offset 0', () {
      final out = TextCleaner.cleanTextRespectingRanges(
        make('[X] tail', [const TextRange(0, 3)], const {}),
      );
      expect(out.cleanedText.startsWith('[X]'), isTrue);
    });

    test('boundary: preserved range at end of input', () {
      final out = TextCleaner.cleanTextRespectingRanges(
        make('head [X]', [const TextRange(5, 8)], const {}),
      );
      expect(out.cleanedText.endsWith('[X]'), isTrue);
    });

    test('boundary: empty preserved range rejected at construction', () {
      expect(
        () => make('hello', [const TextRange(2, 2)], const {}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('boundary: two adjacent preserved ranges (zero outside between)', () {
      final out = TextCleaner.cleanTextRespectingRanges(
        make(
          '[A][B]',
          [const TextRange(0, 3), const TextRange(3, 6)],
          const {},
        ),
      );
      expect(out.cleanedText, '[A][B]');
    });

    test('boundary: single-char preserved range', () {
      final out = TextCleaner.cleanTextRespectingRanges(
        make('aXb', [const TextRange(1, 2)], const {}),
      );
      expect(out.cleanedText.contains('X'), isTrue);
    });

    test('boundary: preserved over whitespace-only content', () {
      final out = TextCleaner.cleanTextRespectingRanges(
        make('a   b', [const TextRange(1, 4)], const {}),
      );
      // Preserved range survives verbatim ("   "), even though the cleaner
      // would have collapsed it.
      expect(out.cleanedText.contains('a   b'), isTrue);
    });

    test('boundary: preserved over PUA-only content', () {
      final out = TextCleaner.cleanTextRespectingRanges(
        make(
          'beforeafter',
          [const TextRange(6, 9)],
          const {},
        ),
      );
      // Preserved PUA survives; outside-preserved PUA should be stripped.
      expect(out.cleanedText.contains(''), isTrue);
    });
  });

  group('cleanExtractedTextRespectingRanges remaps elementRanges', () {
    final document = html_parser.parse('<html><body><p></p></body></html>');
    final pEl = document.querySelector('p')!;

    test('element range fully inside preserved survives unchanged', () {
      final input = ExtractedText(
        text: '012[abc]345',
        preservedRanges: const [TextRange(3, 8)],
        elementRanges: {
          pEl: const [TextRange(4, 7)], // "abc"
        },
        document: document,
      );
      final out = TextCleaner.cleanExtractedTextRespectingRanges(input);
      // Element range maps to the same offsets in cleaned text (Keep edit).
      expect(out.elementRanges[pEl], isNotNull);
      final mapped = out.elementRanges[pEl]!.single;
      expect(out.text.substring(mapped.start, mapped.end), 'abc');
    });

    test('element range outside preserved gets remapped through cleaner', () {
      final input = ExtractedText(
        text: 'aa  bb  [X]',
        preservedRanges: const [TextRange(8, 11)],
        elementRanges: {
          pEl: const [TextRange(0, 6)], // "aa  bb"
        },
        document: document,
      );
      final out = TextCleaner.cleanExtractedTextRespectingRanges(input);
      final mapped = out.elementRanges[pEl]!.single;
      // The "  " runs collapsed; element range still bounds the
      // post-cleaning span containing "aa bb".
      expect(out.text.substring(mapped.start, mapped.end), 'aa bb');
    });
  });
}

String _escape(String s) =>
    s.replaceAll('\n', r'\n').replaceAll('\t', r'\t').replaceAll('\r', r'\r');
