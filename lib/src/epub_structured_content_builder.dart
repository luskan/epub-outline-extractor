import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';
import 'html_text_extractor.dart';

/// Builds structured content annotations from EPUB HTML.
///
/// Takes the already-extracted plain text and the source HTML, then
/// maps HTML block elements (headings, paragraphs, emphasis, links)
/// to offset-based annotations in the plain text.
class EpubStructuredContentBuilder {
  /// Build structured content from full chapter HTML.
  ///
  /// [htmlContent] - Raw HTML of the chapter.
  /// [plainText] - Already-extracted plain text (from extractTextFromHtml).
  /// Returns JSON string or null if extraction fails.
  static String? buildFromHtml(String htmlContent, String plainText) {
    if (plainText.trim().length < 50) return null;

    try {
      final document = html_parser.parse(htmlContent);
      document.querySelectorAll('script, style').forEach((e) => e.remove());

      final body = document.body;
      if (body == null) return null;

      final blocks = <ContentBlock>[];
      _walkBlocks(body, plainText, 0, blocks);

      if (blocks.isEmpty) return null;

      final content = StructuredContent.fromBlocks(plainText, blocks);
      return content?.toJsonString();
    } catch (_) {
      // Malformed XHTML or DOM walk failure — fall back to plain-text
      // extraction (the import flow tolerates a null structured blob).
      return null;
    }
  }

  /// Build structured content from a section within HTML (fragment-based).
  ///
  /// [htmlContent] - Raw HTML of the chapter.
  /// [plainText] - Already-extracted section text (from extractSectionText).
  /// [fragmentId] - Starting fragment ID.
  /// [nextFragmentId] - Ending fragment ID.
  static String? buildFromSectionHtml(
    String htmlContent,
    String plainText, {
    String? fragmentId,
    String? nextFragmentId,
  }) {
    // For fragment-based sections, we use the same approach:
    // the plainText was already extracted by extractSectionText,
    // so we match HTML blocks against it.
    return buildFromHtml(htmlContent, plainText);
  }

  /// Walk DOM tree and collect block-level annotations.
  static void _walkBlocks(
    dom.Element parent,
    String plainText,
    int searchFrom,
    List<ContentBlock> blocks,
  ) {
    for (final node in parent.nodes) {
      if (node is! dom.Element) continue;

      final tag = node.localName?.toLowerCase();
      if (tag == null) continue;

      // Skip script/style
      if (tag == 'script' || tag == 'style') continue;

      final headingLevel = getHeadingLevel(node);
      if (headingLevel != null) {
        // Heading block
        final block = _matchTextBlock(
          node,
          plainText,
          searchFrom,
          ContentBlockType.heading,
          level: headingLevel,
        );
        if (block != null) {
          blocks.add(block);
          searchFrom = block.end;
        }
      } else if (_isParagraphLike(tag)) {
        // Paragraph / list item
        final block = _matchTextBlock(
          node,
          plainText,
          searchFrom,
          ContentBlockType.paragraph,
        );
        if (block != null) {
          blocks.add(block);
          searchFrom = block.end;
        }
      } else if (_isBlockContainer(tag)) {
        // Recurse into block containers (div, section, article, etc.)
        _walkBlocks(node, plainText, searchFrom, blocks);
        if (blocks.isNotEmpty) {
          searchFrom = blocks.last.end;
        }
      }
    }
  }

  /// Match an element's text content to a range in the plain text.
  static ContentBlock? _matchTextBlock(
    dom.Element element,
    String plainText,
    int searchFrom,
    ContentBlockType type, {
    int? level,
  }) {
    final elementText = element.text.trim();
    if (elementText.isEmpty) return null;

    // Try to find the element's text in the plain text starting from searchFrom.
    final normalized = _normalizeForMatch(elementText);
    if (normalized.isEmpty) return null;

    // Try exact match first (first 60 chars to handle long blocks).
    final searchKey =
        normalized.length > 60 ? normalized.substring(0, 60) : normalized;
    var idx = _fuzzyIndexOf(plainText, searchKey, searchFrom);
    if (idx < 0) return null;

    // Determine end offset: find the end of the matched text.
    final endNormalized =
        normalized.length > 60 ? normalized.substring(normalized.length - 30) : null;
    int endIdx;
    if (endNormalized != null) {
      final endSearch = _fuzzyIndexOf(plainText, endNormalized, idx + 10);
      endIdx = endSearch >= 0 ? endSearch + endNormalized.length : idx + elementText.length;
    } else {
      endIdx = idx + _findMatchLength(plainText, idx, normalized);
    }

    // Clamp to plain text bounds.
    endIdx = endIdx.clamp(idx + 1, plainText.length);

    // Collect inline marks (bold, italic, links).
    final marks = <InlineMark>[];
    _collectInlineMarks(element, plainText, idx, marks);

    return ContentBlock(
      type: type,
      start: idx,
      end: endIdx,
      level: level,
      marks: marks,
    );
  }

  /// Collect inline marks (emphasis, links) from element children.
  static void _collectInlineMarks(
    dom.Element element,
    String plainText,
    int blockStart,
    List<InlineMark> marks,
  ) {
    for (final node in element.nodes) {
      if (node is! dom.Element) continue;

      final tag = node.localName?.toLowerCase();
      if (tag == null) continue;

      if (tag == 'strong' || tag == 'b') {
        final mark = _matchInlineMark(
          node,
          plainText,
          blockStart,
          InlineMarkType.emphasis,
          style: 'bold',
        );
        if (mark != null) marks.add(mark);
      } else if (tag == 'em' || tag == 'i') {
        final mark = _matchInlineMark(
          node,
          plainText,
          blockStart,
          InlineMarkType.emphasis,
          style: 'italic',
        );
        if (mark != null) marks.add(mark);
      } else if (tag == 'a') {
        final href = node.attributes['href'];
        if (href != null && href.startsWith('http')) {
          final mark = _matchInlineMark(
            node,
            plainText,
            blockStart,
            InlineMarkType.link,
            url: href,
          );
          if (mark != null) marks.add(mark);
        }
      } else {
        // Recurse into other inline elements (span, etc.)
        _collectInlineMarks(node, plainText, blockStart, marks);
      }
    }
  }

  /// Match an inline element's text to a range in the plain text.
  static InlineMark? _matchInlineMark(
    dom.Element element,
    String plainText,
    int searchFrom,
    InlineMarkType type, {
    String? style,
    String? url,
  }) {
    final text = element.text.trim();
    if (text.isEmpty) return null;

    final normalized = _normalizeForMatch(text);
    if (normalized.isEmpty) return null;

    final idx = _fuzzyIndexOf(plainText, normalized, searchFrom);
    if (idx < 0) return null;

    final endIdx = (idx + _findMatchLength(plainText, idx, normalized))
        .clamp(idx + 1, plainText.length);

    return InlineMark(
      type: type,
      start: idx,
      end: endIdx,
      style: style,
      url: url,
    );
  }

  /// Normalize text for matching: collapse whitespace.
  static String _normalizeForMatch(String text) {
    return text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Find text in plainText with whitespace-flexible matching.
  static int _fuzzyIndexOf(String plainText, String needle, int from) {
    if (from >= plainText.length || needle.isEmpty) return -1;

    // Try exact match first.
    final exactIdx = plainText.indexOf(needle, from);
    if (exactIdx >= 0) return exactIdx;

    // Try whitespace-normalized match.
    final normalizedPlain = _normalizeForMatch(
      plainText.substring(from, (from + needle.length * 3).clamp(0, plainText.length)),
    );
    final idx = normalizedPlain.indexOf(needle);
    if (idx >= 0) {
      // Map back to original offset.
      return _mapNormalizedOffset(plainText, from, idx);
    }

    // Try prefix match (first 30 chars).
    if (needle.length > 30) {
      final prefix = needle.substring(0, 30);
      return _fuzzyIndexOf(plainText, prefix, from);
    }

    return -1;
  }

  /// Map an offset in normalized text back to the original text.
  static int _mapNormalizedOffset(String original, int baseOffset, int normalizedOffset) {
    var origIdx = baseOffset;
    var normIdx = 0;
    while (origIdx < original.length && normIdx < normalizedOffset) {
      if (RegExp(r'\s').hasMatch(original[origIdx])) {
        // Skip extra whitespace in original.
        origIdx++;
        while (origIdx < original.length && RegExp(r'\s').hasMatch(original[origIdx])) {
          origIdx++;
        }
        normIdx++; // One space in normalized.
      } else {
        origIdx++;
        normIdx++;
      }
    }
    return origIdx;
  }

  /// Find how many characters in plainText match the normalized text.
  static int _findMatchLength(String plainText, int startIdx, String normalized) {
    var origIdx = startIdx;
    var normIdx = 0;
    while (origIdx < plainText.length && normIdx < normalized.length) {
      if (plainText[origIdx] == normalized[normIdx]) {
        origIdx++;
        normIdx++;
      } else if (RegExp(r'\s').hasMatch(plainText[origIdx])) {
        origIdx++;
      } else if (RegExp(r'\s').hasMatch(normalized[normIdx])) {
        normIdx++;
      } else {
        break;
      }
    }
    return origIdx - startIdx;
  }

  static bool _isParagraphLike(String tag) {
    const tags = {'p', 'li', 'dt', 'dd', 'blockquote', 'pre', 'figcaption'};
    return tags.contains(tag);
  }

  static bool _isBlockContainer(String tag) {
    const tags = {
      'div', 'section', 'article', 'main', 'aside', 'header', 'footer',
      'nav', 'figure', 'details', 'summary', 'form', 'fieldset',
      'ul', 'ol', 'dl', 'table', 'tbody', 'thead', 'tfoot', 'tr',
    };
    return tags.contains(tag);
  }
}
