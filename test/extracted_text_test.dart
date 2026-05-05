import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:test/test.dart';

void main() {
  group('TextRange', () {
    test('value equality + hashCode', () {
      expect(const TextRange(0, 5), const TextRange(0, 5));
      expect(const TextRange(0, 5).hashCode, const TextRange(0, 5).hashCode);
      expect(const TextRange(0, 5), isNot(const TextRange(0, 6)));
    });

    test('length and isEmpty', () {
      expect(const TextRange(0, 5).length, 5);
      expect(const TextRange(3, 3).isEmpty, isTrue);
      expect(const TextRange(0, 1).isEmpty, isFalse);
    });

    test('contains is half-open', () {
      const r = TextRange(2, 5);
      expect(r.contains(2), isTrue);
      expect(r.contains(4), isTrue);
      expect(r.contains(5), isFalse); // exclusive end
      expect(r.contains(1), isFalse);
    });
  });

  group('ExtractedText invariants (§5.2)', () {
    final document = html_parser.parse('<html><body></body></html>');

    ExtractedText make({
      required String text,
      List<TextRange> preserved = const [],
      Map<String, List<TextRange>> elements = const {},
    }) {
      final elementRanges = <dom.Element, List<TextRange>>{};
      elements.forEach((key, ranges) {
        // Synthetic detached element keyed by [key]; identity is what we
        // need, not DOM membership.
        final el = dom.Element.tag('span')..attributes['data-key'] = key;
        elementRanges[el] = ranges;
      });
      return ExtractedText(
        text: text,
        preservedRanges: preserved,
        elementRanges: elementRanges,
        document: document,
      );
    }

    test('happy path: empty preserved + empty elements', () {
      expect(
        () => make(text: 'hello'),
        returnsNormally,
      );
    });

    test('preserved range out of bounds → ArgumentError', () {
      expect(
        () => make(text: 'abc', preserved: [const TextRange(0, 5)]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('zero-length preserved range → ArgumentError', () {
      expect(
        () => make(text: 'abc', preserved: [const TextRange(1, 1)]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('overlapping preserved ranges → ArgumentError', () {
      expect(
        () => make(
          text: 'abcdef',
          preserved: [const TextRange(0, 4), const TextRange(2, 6)],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('unsorted preserved ranges → ArgumentError', () {
      expect(
        () => make(
          text: 'abcdef',
          preserved: [const TextRange(3, 5), const TextRange(0, 2)],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('adjacent preserved ranges allowed (zero gap)', () {
      expect(
        () => make(
          text: 'abcdef',
          preserved: [const TextRange(0, 3), const TextRange(3, 6)],
        ),
        returnsNormally,
      );
    });

    test('element range out of bounds → ArgumentError', () {
      expect(
        () => make(
          text: 'abc',
          elements: {
            'a': [const TextRange(0, 10)],
          },
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'element range straddles a preserved boundary → ArgumentError (inv 4)',
      () {
        // text:        0123456789
        // preserved:        [3,7)
        // element:       [1,5)  ← starts outside, ends inside → straddle
        expect(
          () => make(
            text: '0123456789',
            preserved: [const TextRange(3, 7)],
            elements: {
              'a': [const TextRange(1, 5)],
            },
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('element range fully inside a preserved range → OK', () {
      expect(
        () => make(
          text: '0123456789',
          preserved: [const TextRange(2, 8)],
          elements: {
            'a': [const TextRange(3, 7)],
          },
        ),
        returnsNormally,
      );
    });

    test('element range fully outside any preserved range → OK', () {
      expect(
        () => make(
          text: '0123456789',
          preserved: [const TextRange(2, 5)],
          elements: {
            'a': [const TextRange(6, 9)],
          },
        ),
        returnsNormally,
      );
    });

    test('equality scoped to text + preservedRanges (§5.2 inv 6)', () {
      // Even though elementRanges and document differ between two
      // ExtractedText instances, equality only looks at text + preserved.
      final docA = html_parser.parse('<html><body><p>x</p></body></html>');
      final docB = html_parser.parse('<html><body><p>x</p></body></html>');
      final pA = docA.querySelector('p')!;
      final pB = docB.querySelector('p')!;

      final a = ExtractedText(
        text: 'hello world',
        preservedRanges: const [TextRange(6, 11)],
        elementRanges: {
          pA: const [TextRange(0, 5)],
        },
        document: docA,
      );
      final b = ExtractedText(
        text: 'hello world',
        preservedRanges: const [TextRange(6, 11)],
        elementRanges: {
          pB: const [TextRange(0, 5)], // same range, different element identity
        },
        document: docB,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('inequality on different text', () {
      final a = ExtractedText(
        text: 'hello',
        preservedRanges: const [],
        elementRanges: const {},
        document: document,
      );
      final b = ExtractedText(
        text: 'world',
        preservedRanges: const [],
        elementRanges: const {},
        document: document,
      );
      expect(a, isNot(equals(b)));
    });

    test('inequality on different preserved ranges', () {
      final a = ExtractedText(
        text: 'hello world',
        preservedRanges: const [TextRange(0, 5)],
        elementRanges: const {},
        document: document,
      );
      final b = ExtractedText(
        text: 'hello world',
        preservedRanges: const [TextRange(6, 11)],
        elementRanges: const {},
        document: document,
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('ElementRangeAccess', () {
    final document = html_parser.parse(
      '<html><body><p>one</p><ul><li>two</li></ul></body></html>',
    );
    final pEl = document.querySelector('p')!;
    final liEl = document.querySelector('li')!;

    test('singleRangeOf returns the lone range', () {
      final map = <dom.Element, List<TextRange>>{
        pEl: const [TextRange(0, 3)],
      };
      expect(map.singleRangeOf(pEl), const TextRange(0, 3));
    });

    test('rangesOf returns the full list', () {
      final map = <dom.Element, List<TextRange>>{
        liEl: const [TextRange(0, 3), TextRange(7, 11)],
      };
      expect(map.rangesOf(liEl), const [TextRange(0, 3), TextRange(7, 11)]);
    });

    test('rangesOf returns empty list for unknown element', () {
      final map = <dom.Element, List<TextRange>>{
        pEl: const [TextRange(0, 3)],
      };
      expect(map.rangesOf(liEl), isEmpty);
    });
  });
}
