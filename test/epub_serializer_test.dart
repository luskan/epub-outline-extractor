import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';
import 'package:test/test.dart';

void main() {
  group('EpubSerializer', () {
    test('emits keys in canonical order at top level', () {
      final section = BookSection(
        title: 'Chapter 1',
        location: const EpubChapterLocation(
          spineIndex: 0,
          href: 'ch1.xhtml',
        ),
        content: const ['hello world'],
        structuredContentJson: '{"x":1}',
      );

      final json = EpubSerializer.toJson(section);

      expect(
        json.keys.toList(),
        ['type', 'title', 'location', 'content', 'structuredContentJson'],
        reason: 'Top-level key order must be stable.',
      );
    });

    test('location key order is stable: type, spine_index, '
        'end_spine_index?, href?, anchor?', () {
      final section = BookSection(
        title: 'Chapter 1',
        location: const EpubChapterLocation(
          spineIndex: 2,
          endSpineIndex: 4,
          href: 'ch2.xhtml',
          anchor: 'sec',
        ),
        content: const ['hello'],
      );

      final json = EpubSerializer.toJson(section);
      final loc = json['location'] as Map<String, dynamic>;
      expect(
        loc.keys.toList(),
        ['type', 'spine_index', 'end_spine_index', 'href', 'anchor'],
      );
    });

    test('omits optional fields when null/empty', () {
      final section = BookSection(
        title: 'Bare',
        location: const EpubChapterLocation(spineIndex: 0),
      );

      final json = EpubSerializer.toJson(section);
      expect(json.keys.toList(), ['type', 'title', 'location']);

      final loc = json['location'] as Map<String, dynamic>;
      expect(loc.keys.toList(), ['type', 'spine_index'],
          reason: 'No null end_spine_index/href/anchor when unset');
    });

    test('emits subsections recursively with stable per-section order', () {
      final root = BookSection(
        title: 'Part I',
        location: const EpubChapterLocation(spineIndex: 0, href: 'p1.xhtml'),
        content: const ['Part text'],
        subsections: [
          BookSection(
            title: 'Chapter A',
            location: const EpubChapterLocation(
              spineIndex: 0,
              href: 'p1.xhtml',
              anchor: 'a',
            ),
            content: const ['A text'],
            subsections: [
              BookSection(
                title: 'A.1',
                location: const EpubChapterLocation(
                  spineIndex: 1,
                  href: 'p1.xhtml',
                  anchor: 'a1',
                ),
              ),
            ],
          ),
        ],
      );

      final json = EpubSerializer.toJson(root);
      expect(
        json.keys.toList(),
        ['type', 'title', 'location', 'content', 'subsections'],
      );

      final ch = (json['subsections'] as List)[0] as Map<String, dynamic>;
      expect(
        ch.keys.toList(),
        ['type', 'title', 'location', 'content', 'subsections'],
      );

      final a1 = (ch['subsections'] as List)[0] as Map<String, dynamic>;
      // No content / no subsections → optional keys omitted.
      expect(a1.keys.toList(), ['type', 'title', 'location']);
    });

    test('throws ArgumentError for non-EpubChapterLocation', () {
      final pdfSection = BookSection(
        title: 'PDF',
        location: const PdfPageLocation(pageNumber: 1),
      );
      expect(() => EpubSerializer.toJson(pdfSection), throwsArgumentError);
    });
  });
}
