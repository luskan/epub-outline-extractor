import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:test/test.dart';

void main() {
  group('stripNumericPrefix', () {
    test('strips numeric prefix', () {
      expect(TextParsingUtils.stripNumericPrefix('1.2 Title'), 'Title');
      expect(TextParsingUtils.stripNumericPrefix('5 Foo'), 'Foo');
    });

    test('passes through plain title', () {
      expect(TextParsingUtils.stripNumericPrefix('Title'), 'Title');
    });
  });

  group('parseMajorMinor', () {
    test('parses M.m', () {
      expect(TextParsingUtils.parseMajorMinor('1.2 Title'), (1, 2));
    });

    test('parses major only', () {
      expect(TextParsingUtils.parseMajorMinor('5 Title'), (5, null));
    });

    test('returns null pair for non-numeric', () {
      expect(TextParsingUtils.parseMajorMinor('Title'), (null, null));
    });
  });

  group('toRoman / fromRoman', () {
    test('round-trips representative values', () {
      for (final n in [1, 4, 9, 40, 90, 400, 900, 1994, 3999]) {
        final roman = TextParsingUtils.toRoman(n);
        expect(TextParsingUtils.fromRoman(roman), n,
            reason: '$n -> $roman -> ?');
      }
    });

    test('rejects out-of-range', () {
      expect(() => TextParsingUtils.toRoman(0), throwsArgumentError);
      expect(() => TextParsingUtils.toRoman(4000), throwsArgumentError);
    });

    test('fromRoman handles invalid', () {
      expect(TextParsingUtils.fromRoman('ABC'), isNull);
      expect(TextParsingUtils.fromRoman(''), isNull);
    });
  });

  group('parseHref', () {
    test('splits file and fragment', () {
      expect(TextParsingUtils.parseHref('chapter1.xhtml#sec2'),
          ('chapter1.xhtml', 'sec2'));
    });

    test('returns null fragment', () {
      expect(TextParsingUtils.parseHref('chapter1.xhtml'),
          ('chapter1.xhtml', null));
    });
  });

  group('cleanWhitespace', () {
    test('trims and joins', () {
      expect(
        TextParsingUtils.cleanWhitespace('  Line 1  \n  Line 2  '),
        'Line 1\nLine 2',
      );
    });

    test('drops empty chunks from double-space splits', () {
      expect(TextParsingUtils.cleanWhitespace('A   B'), 'A\nB');
    });
  });

  group('extractPartNumber', () {
    test('matches "Part X"', () {
      expect(TextParsingUtils.extractPartNumber('Part I: Intro'), 'I');
    });

    test('matches Roman dot', () {
      expect(TextParsingUtils.extractPartNumber('I. Data'), 'I');
    });

    test('matches Arabic dot+space', () {
      expect(TextParsingUtils.extractPartNumber('1. The Model'), '1');
    });

    test('matches Arabic space-only', () {
      expect(TextParsingUtils.extractPartNumber('12 Overview'), '12');
    });

    test('returns null for plain title', () {
      expect(TextParsingUtils.extractPartNumber('Just a Title'), isNull);
    });

    test('returns null for null/empty', () {
      expect(TextParsingUtils.extractPartNumber(null), isNull);
      expect(TextParsingUtils.extractPartNumber(''), isNull);
    });
  });

  group('stripPartPrefix', () {
    test('strips "Part X:"', () {
      expect(TextParsingUtils.stripPartPrefix('Part I: Intro'), 'Intro');
    });

    test('strips Roman dot', () {
      expect(TextParsingUtils.stripPartPrefix('I. Data'), 'Data');
    });

    test('strips Arabic dot+space', () {
      expect(TextParsingUtils.stripPartPrefix('1. Model'), 'Model');
    });

    test('strips Arabic space-only', () {
      expect(TextParsingUtils.stripPartPrefix('12 Overview'), 'Overview');
    });

    test('passes through plain title', () {
      expect(TextParsingUtils.stripPartPrefix('Just a Title'),
          'Just a Title');
    });
  });
}
