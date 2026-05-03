/// Prepare per-chapter sanitized HTML for downstream rendering.
///
/// Walks the chapter DOM in the same pre-order [EpubImageExtractor]
/// uses (qualifying-element index — `<img>` with non-empty `src` and
/// SVG `<image>` with `xlink:href`/`href`), stamps `data-figure-idx`
/// on each qualifying `<img>`, then runs the parse-tree
/// [HtmlSanitizer] over the result.
///
/// The stamping order matches the figure indexing produced by the
/// image extractor — when downstream consumers look up a figure by
/// chapter pre-order index N, the corresponding `<img>` carries
/// `data-figure-idx="N"`.
library;

import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';

/// Result of preparing a chapter for HTML rendering.
class PreparedChapterHtml {
  /// Sanitized HTML — body's inner HTML, no DOCTYPE/wrapping.
  final String htmlContent;

  /// Sanitizer policy version that produced [htmlContent].
  final int sanitizerVersion;

  const PreparedChapterHtml({
    required this.htmlContent,
    required this.sanitizerVersion,
  });
}

/// Prepare raw chapter HTML for storage. Always emits a
/// [PreparedChapterHtml] (possibly empty) — never throws on malformed
/// inputs; the sanitizer's allowlist drops what it cannot interpret.
PreparedChapterHtml prepareChapterHtml(String rawHtml) {
  if (rawHtml.trim().isEmpty) {
    return const PreparedChapterHtml(
      htmlContent: '',
      sanitizerVersion: kHtmlSanitizerVersion,
    );
  }

  final document = html_parser.parse(rawHtml);
  final root = document.body ?? document.documentElement;
  if (root != null) {
    _stampFigureIndices(root);
  }

  final stamped = root?.outerHtml ?? rawHtml;
  final sanitized = HtmlSanitizer.sanitize(stamped);
  return PreparedChapterHtml(
    htmlContent: sanitized,
    sanitizerVersion: kHtmlSanitizerVersion,
  );
}

/// Slice an `anchorToPath` map (as produced by
/// [EpubImageExtractor]) down to a single chapter, rekeyed by the
/// chapter-pre-order figure index. Anchors are formatted as
/// `<chapterHref>:<idx>`.
Map<int, String> figureIdxMapForChapter(
  Map<String, String> anchorToPath,
  String chapterHref,
) {
  final result = <int, String>{};
  final prefix = '$chapterHref:';
  for (final entry in anchorToPath.entries) {
    if (!entry.key.startsWith(prefix)) continue;
    final idxStr = entry.key.substring(prefix.length);
    final idx = int.tryParse(idxStr);
    if (idx == null) continue;
    result[idx] = entry.value;
  }
  return result;
}

/// Rewrite `<img>` `src` attributes on a previously-prepared chapter
/// HTML using a chapter-pre-order-index → relative path map produced
/// by [EpubImageExtractor]. Returns the rewritten HTML.
///
/// Imgs whose `data-figure-idx` is missing from the map keep their
/// existing `src` (which the sanitizer may already have stripped if
/// it pointed at a disallowed scheme). The data-figure-idx attribute
/// is preserved so downstream renderers can continue to resolve it
/// dynamically if needed.
String rewriteChapterImageSrcs(
  String chapterHtml,
  Map<int, String> figureIdxToPath,
) {
  if (chapterHtml.isEmpty || figureIdxToPath.isEmpty) return chapterHtml;
  final fragmentDoc = html_parser.parseFragment(chapterHtml);
  final imgs = fragmentDoc.querySelectorAll('img');
  for (final img in imgs) {
    final idxAttr = img.attributes['data-figure-idx'];
    if (idxAttr == null) continue;
    final idx = int.tryParse(idxAttr);
    if (idx == null) continue;
    final path = figureIdxToPath[idx];
    if (path == null || path.isEmpty) continue;
    img.attributes['src'] = path;
  }
  return _serializeNodes(fragmentDoc);
}

String _serializeNodes(dom.DocumentFragment fragment) {
  final buffer = StringBuffer();
  for (final node in fragment.nodes) {
    if (node is dom.Element) {
      buffer.write(node.outerHtml);
    } else if (node is dom.Text) {
      buffer.write(node.text);
    }
  }
  return buffer.toString();
}

/// Walk Element children in pre-order, mirroring
/// `EpubImageExtractor`'s qualifying-element counter so the stamped
/// indices match `Figure.anchor` `<chapter>:<idx>` slots.
void _stampFigureIndices(dom.Element root) {
  var domIdx = 0;
  void walk(dom.Element el) {
    final tag = el.localName?.toLowerCase();
    if (tag == 'img') {
      final src = el.attributes['src']?.trim();
      if (src != null && src.isNotEmpty) {
        el.attributes['data-figure-idx'] = domIdx.toString();
        domIdx++;
      }
    } else if (tag == 'image') {
      final xlink = el.attributes['xlink:href']?.trim();
      final href = el.attributes['href']?.trim();
      final hasHref = (xlink != null && xlink.isNotEmpty) ||
          (href != null && href.isNotEmpty);
      if (hasHref) {
        domIdx++;
      }
    }
    for (final child in el.children) {
      walk(child);
    }
  }

  walk(root);
}
