import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';
import 'package:test/test.dart';

void main() {
  group('prepareChapterHtml', () {
    test('returns empty result for empty input', () {
      final result = prepareChapterHtml('');
      expect(result.htmlContent, '');
      expect(result.sanitizerVersion, kHtmlSanitizerVersion);
    });

    test('stamps data-figure-idx on imgs in pre-order', () {
      final result = prepareChapterHtml('''
<html><body>
  <p>Intro</p>
  <img src="a.png" alt="first">
  <div>
    <img src="b.png" alt="second">
    <img src="c.png" alt="third">
  </div>
  <img src="d.png" alt="fourth">
</body></html>
      ''');
      final doc = html_parser.parse(result.htmlContent);
      final imgs = doc.getElementsByTagName('img');
      expect(imgs.length, 4);
      expect(imgs[0].attributes['alt'], 'first');
      expect(imgs[0].attributes['data-figure-idx'], '0');
      expect(imgs[1].attributes['alt'], 'second');
      expect(imgs[1].attributes['data-figure-idx'], '1');
      expect(imgs[2].attributes['alt'], 'third');
      expect(imgs[2].attributes['data-figure-idx'], '2');
      expect(imgs[3].attributes['alt'], 'fourth');
      expect(imgs[3].attributes['data-figure-idx'], '3');
    });

    test('skips imgs with empty src (matches image extractor)', () {
      final result = prepareChapterHtml('''
<html><body>
  <img src="a.png" alt="kept">
  <img src="" alt="skipped">
  <img src="c.png" alt="kept">
</body></html>
      ''');
      final doc = html_parser.parse(result.htmlContent);
      final imgs = doc.getElementsByTagName('img');
      // Sanitizer strips the empty-src img? Actually no — img is allowed,
      // and src="" is technically valid. Check stamp behavior:
      final stamped = imgs.where((i) => i.attributes.containsKey('data-figure-idx')).toList();
      expect(stamped.length, 2);
      expect(stamped[0].attributes['alt'], 'kept');
      expect(stamped[0].attributes['data-figure-idx'], '0');
      expect(stamped[1].attributes['alt'], 'kept');
      expect(stamped[1].attributes['data-figure-idx'], '1');
    });

    test('SVG is fully dropped from sanitized output', () {
      // The <svg> subtree is in the sanitizer's banned list — verified
      // explicitly so chapter HTML never carries SVG content into the
      // renderer (XSS surface). Note: img/SVG-image index alignment
      // with EpubImageExtractor is exercised by integration tests with
      // real EPUBs, where HTML5 foreign-content parsing kicks in.
      final result = prepareChapterHtml('''
<html><body>
  <p>Before</p>
  <svg><image xlink:href="svg-img.png"/></svg>
  <p>After</p>
</body></html>
      ''');
      expect(result.htmlContent.toLowerCase(), isNot(contains('<svg')));
      expect(result.htmlContent.toLowerCase(), isNot(contains('<image')));
      expect(result.htmlContent, contains('Before'));
      expect(result.htmlContent, contains('After'));
    });

    test('strips dangerous content', () {
      final result = prepareChapterHtml('''
<html><body>
  <p>Safe</p>
  <script>alert(1)</script>
  <iframe src="https://evil"></iframe>
  <p onclick="alert(2)">Also safe</p>
</body></html>
      ''');
      expect(result.htmlContent.toLowerCase(), isNot(contains('<script')));
      expect(result.htmlContent.toLowerCase(), isNot(contains('<iframe')));
      expect(result.htmlContent.toLowerCase(), isNot(contains('onclick')));
      expect(result.htmlContent.toLowerCase(), isNot(contains('alert')));
      expect(result.htmlContent, contains('Safe'));
    });
  });

  group('rewriteChapterImageSrcs', () {
    test('rewrites <img src> by data-figure-idx', () {
      const html =
          '<p>x</p>'
          '<img data-figure-idx="0" alt="a" src="">'
          '<img data-figure-idx="1" alt="b" src="">';
      final out = rewriteChapterImageSrcs(html, {
        0: 'figures/chap1/0.png',
        1: 'figures/chap1/1.png',
      });
      expect(out, contains('src="figures/chap1/0.png"'));
      expect(out, contains('src="figures/chap1/1.png"'));
    });

    test('imgs missing from map keep their src', () {
      const html =
          '<img data-figure-idx="0" src="orig0.png">'
          '<img data-figure-idx="5" src="orig5.png">';
      final out = rewriteChapterImageSrcs(html, {0: 'new0.png'});
      expect(out, contains('src="new0.png"'));
      expect(out, contains('src="orig5.png"'));
    });

    test('returns input verbatim when map is empty', () {
      const html = '<img src="x.png">';
      final out = rewriteChapterImageSrcs(html, const {});
      expect(out, html);
    });
  });

  group('figureIdxMapForChapter', () {
    test('slices anchorToPath for one chapter and rekeys by index', () {
      final map = figureIdxMapForChapter({
        'chap1.xhtml:0': 'figures/chap1/0.png',
        'chap1.xhtml:1': 'figures/chap1/1.png',
        'chap2.xhtml:0': 'figures/chap2/0.png',
      }, 'chap1.xhtml');
      expect(map, {
        0: 'figures/chap1/0.png',
        1: 'figures/chap1/1.png',
      });
    });

    test('returns empty when chapter not in map', () {
      final map = figureIdxMapForChapter({
        'chap1.xhtml:0': 'figures/chap1/0.png',
      }, 'chap2.xhtml');
      expect(map, isEmpty);
    });
  });
}
