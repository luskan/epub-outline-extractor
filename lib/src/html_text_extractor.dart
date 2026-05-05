/// HTML text extraction utilities for EPUB conversion.
///
/// Provides functions for extracting clean text from HTML content,
/// handling fragments, headings, and block elements.
library;

import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

import 'extracted_text.dart';
import 'text_parsing_utils.dart';

/// Default heading level (h2) used when extracting section text
/// and the starting element is not itself a heading.
const _defaultHeadingLevel = 2;

/// Extract text from HTML content, removing scripts and styles.
///
/// [htmlContent] - Raw HTML content.
/// Returns cleaned text content.
String extractTextFromHtml(String htmlContent) {
  final document = html_parser.parse(htmlContent);

  // Remove scripts and styles
  document.querySelectorAll('script, style').forEach((element) {
    element.remove();
  });

  // Get text content
  final text = document.body?.text ?? document.text ?? '';

  // Clean whitespace
  return TextParsingUtils.cleanWhitespace(text);
}

/// Extract title from HTML content.
///
/// Tries h1, h2, h3, title tags in order.
/// Falls back to sanitized filename if no title found.
String extractTitleFromHtml(String htmlContent, String fallbackName) {
  final document = html_parser.parse(htmlContent);

  // Try to find title in order of preference
  for (final tag in ['h1', 'h2', 'h3', 'title']) {
    final element = document.querySelector(tag);
    if (element != null) {
      final title = element.text.trim();
      if (title.isNotEmpty) {
        return title;
      }
    }
  }

  // Fallback to filename
  return fallbackName.split('/').last.split('.').first;
}

/// Extract section text between fragment IDs.
///
/// [htmlContent] - Raw HTML content.
/// [fragmentId] - Starting fragment ID (optional).
/// [nextFragmentId] - Ending fragment ID (optional).
/// [logger] - Optional logging callback for debug output.
/// Returns extracted text between the fragments.
String extractSectionText(
  String htmlContent,
  String? fragmentId,
  String? nextFragmentId, {
  void Function(String)? logger,
}) {
  final document = html_parser.parse(htmlContent);

  // Remove scripts and styles
  document.querySelectorAll('script, style').forEach((element) {
    element.remove();
  });

  // Case 1: No fragment ID - extract from beginning to nextFragmentId
  if (fragmentId == null) {
    if (nextFragmentId != null) {
      logger?.call(
        '    Extracting from beginning until fragment: $nextFragmentId',
      );
      final emitter = _StructuredEmitter();
      _extractUntilElement(document, nextFragmentId, emitter, logger);
      return cleanExtractedText(emitter.text);
    }
    // No fragments at all - this is likely the entire chapter
    logger?.call(
      '    WARNING: No fragment boundaries, using full chapter text',
    );
    return document.body?.text ?? document.text ?? '';
  }

  // Case 2: Find start element by fragment ID
  final startElement =
      document.querySelector('#$fragmentId') ??
      document.querySelector('[name="$fragmentId"]');

  if (startElement == null) {
    logger?.call('    WARNING: Fragment ID "$fragmentId" not found in HTML!');
    return '';
  }

  logger?.call(
    '    Extracting from fragment: $fragmentId (${startElement.localName}) to ${nextFragmentId ?? "next heading"}',
  );

  // Case 3: Extract from fragment to next fragment or heading
  final emitter = _StructuredEmitter();
  _extractFromElement(
    document,
    startElement,
    nextFragmentId,
    emitter,
    logger,
  );
  return cleanExtractedText(emitter.text);
}

/// Structured variant of [extractSectionText]: walks the same way but also
/// tracks preserved ranges and element ranges for the structured-content
/// pipeline.
///
/// Returns a [SectionExtraction] whose [SectionExtraction.extracted] is the
/// **raw, pre-cleaning** [ExtractedText]. Pipe through
/// [TextCleaner.cleanExtractedTextRespectingRanges] to get the cleaned form
/// with ranges remapped.
SectionExtraction extractSectionStructured(
  String htmlContent,
  String? fragmentId,
  String? nextFragmentId, {
  void Function(String)? logger,
}) {
  final document = html_parser.parse(htmlContent);
  document.querySelectorAll('script, style').forEach((e) => e.remove());

  final emitter = _StructuredEmitter();
  dom.Element? startElement;
  dom.Element? endElement;

  if (fragmentId == null) {
    if (nextFragmentId != null) {
      endElement = document.querySelector('#$nextFragmentId') ??
          document.querySelector('[name="$nextFragmentId"]');
      _extractUntilElement(document, nextFragmentId, emitter, logger);
    } else {
      _walkAll(document, emitter);
    }
  } else {
    startElement = document.querySelector('#$fragmentId') ??
        document.querySelector('[name="$fragmentId"]');
    if (startElement != null) {
      if (nextFragmentId != null) {
        endElement = document.querySelector('#$nextFragmentId') ??
            document.querySelector('[name="$nextFragmentId"]');
      }
      _extractFromElement(
        document,
        startElement,
        nextFragmentId,
        emitter,
        logger,
      );
    }
  }

  return SectionExtraction(
    extracted: emitter.toExtractedText(document),
    sectionStartElement: startElement,
    sectionEndElement: endElement,
  );
}

/// Whole-chapter structured variant: walks the whole document body and
/// returns the raw extraction. Used for chapters without fragment-based
/// sections.
ExtractedText extractStructured(String htmlContent) {
  final document = html_parser.parse(htmlContent);
  document.querySelectorAll('script, style').forEach((e) => e.remove());

  final emitter = _StructuredEmitter();
  final body = document.body;
  if (body != null) {
    _walkAll(body, emitter);
  }
  return emitter.toExtractedText(document);
}

/// Walk every node in the subtree rooted at [root] and emit text via
/// [emitter]. Used for both whole-chapter and "until-fragment" extraction
/// variants.
void _walkAll(dom.Node root, _StructuredEmitter emitter) {
  if (root is dom.Text) {
    emitter.writeText(root.text);
    return;
  }
  if (root is dom.Element) {
    _walkElement(root, emitter);
    return;
  }
  // Document or DocumentFragment.
  for (final c in root.nodes) {
    _walkAll(c, emitter);
  }
}

/// Recurse into [element], dispatching on tag for preserve/figcaption/br
/// behavior, then recurse into children.
void _walkElement(dom.Element element, _StructuredEmitter emitter) {
  final tag = element.localName?.toLowerCase();
  if (tag == 'br') {
    emitter.writeLineBreak();
    return;
  }
  final isPre = tag == 'pre';
  final isFigcaption = tag == 'figcaption';

  // Block elements get a `\n\n` separator before their content (matches
  // existing emitter's behavior).
  if (isBlockElement(element)) {
    emitter.writeBlockSeparator();
  }

  if (isPre) {
    emitter.enterPreserve(element);
    for (final c in element.nodes) {
      _walkAll(c, emitter);
    }
    emitter.exitPreserve(element);
  } else if (isFigcaption) {
    emitter.enterFigcaption(element);
    for (final c in element.nodes) {
      _walkAll(c, emitter);
    }
    emitter.exitFigcaption(element);
  } else {
    for (final c in element.nodes) {
      _walkAll(c, emitter);
    }
  }
}

/// Internal: extract text walking document linearly until an element with
/// the given fragment ID is encountered. Mirrors the legacy
/// `_extractTextUntilElement` but writes to a [_StructuredEmitter] for
/// downstream structured tracking.
void _extractUntilElement(
  dom.Document document,
  String elementId,
  _StructuredEmitter emitter,
  void Function(String)? logger,
) {
  final endElement =
      document.querySelector('#$elementId') ??
      document.querySelector('[name="$elementId"]');

  if (endElement == null) {
    logger?.call(
      '    WARNING: End fragment ID "$elementId" not found in HTML!',
    );
    return;
  }

  bool stopped = false;

  void walkNodes(dom.Node node) {
    if (stopped) return;
    if (node == endElement) {
      stopped = true;
      return;
    }

    if (node.nodeType == dom.Node.TEXT_NODE) {
      emitter.writeText(node.text ?? '');
    } else if (node is dom.Element) {
      final tag = node.localName?.toLowerCase();
      if (tag == 'br') {
        emitter.writeLineBreak();
      } else if (isBlockElement(node)) {
        emitter.writeBlockSeparator();
      }

      final isPre = tag == 'pre';
      final isFigcaption = tag == 'figcaption';

      if (isPre) emitter.enterPreserve(node);
      if (isFigcaption) emitter.enterFigcaption(node);

      for (final child in node.nodes) {
        walkNodes(child);
        if (stopped) break;
      }

      if (isPre) emitter.exitPreserve(node);
      if (isFigcaption) emitter.exitFigcaption(node);
    }
  }

  walkNodes(document);
}

/// Internal: extract text walking from a starting element until the next
/// fragment / same-or-higher heading. Mirrors the legacy
/// `_extractTextFromElement` but writes to a [_StructuredEmitter].
void _extractFromElement(
  dom.Document document,
  dom.Element startElement,
  String? nextFragmentId,
  _StructuredEmitter emitter,
  void Function(String)? logger,
) {
  var hasCollectedContent = false;

  // Determine where to actually start traversal and what heading level to use
  dom.Element actualStart = startElement;
  int? startLevel = getHeadingLevel(startElement);

  // If start element is not a heading, look for a heading inside it
  if (startLevel == null) {
    final innerHeading = startElement.querySelector('h1, h2, h3, h4, h5, h6');
    if (innerHeading != null) {
      startLevel = getHeadingLevel(innerHeading);
      actualStart = innerHeading;
    }
  }

  final effectiveStartLevel = startLevel ?? _defaultHeadingLevel;

  var passedStartHeading = (startLevel == null);
  var isFirstIteration = true;

  // Track preserve/figcaption depth via ancestor chains. The linear
  // (`getNextNode`) walk can cross element boundaries silently, so we
  // sample the ancestor chain at each step to know whether we're inside a
  // <pre> or <figcaption>. The emitter's preserve stack is updated at
  // boundary transitions only.
  dom.Element? currentPreserveAncestor;
  dom.Element? currentFigcaptionAncestor;

  dom.Element? findPreserveAncestor(dom.Node? node) {
    var cur = node;
    while (cur != null) {
      if (cur is dom.Element && cur.localName?.toLowerCase() == 'pre') {
        return cur;
      }
      cur = cur.parent;
    }
    return null;
  }

  dom.Element? findFigcaptionAncestor(dom.Node? node) {
    var cur = node;
    while (cur != null) {
      if (cur is dom.Element &&
          cur.localName?.toLowerCase() == 'figcaption') {
        return cur;
      }
      cur = cur.parent;
    }
    return null;
  }

  void syncAncestorState(dom.Node? node) {
    final newPre = findPreserveAncestor(node);
    final priorPre = currentPreserveAncestor;
    if (newPre != priorPre) {
      if (priorPre != null) {
        emitter.exitPreserve(priorPre);
      }
      if (newPre != null) {
        emitter.enterPreserve(newPre);
      }
      currentPreserveAncestor = newPre;
    }
    final newFig = findFigcaptionAncestor(node);
    final priorFig = currentFigcaptionAncestor;
    if (newFig != priorFig) {
      if (priorFig != null) {
        emitter.exitFigcaption(priorFig);
      }
      if (newFig != null) {
        emitter.enterFigcaption(newFig);
      }
      currentFigcaptionAncestor = newFig;
    }
  }

  dom.Node? current = actualStart;

  while (current != null) {
    syncAncestorState(current);

    // Check if we reached next fragment by its ID
    if (nextFragmentId != null && current is dom.Element) {
      if (current.id == nextFragmentId ||
          current.attributes['name'] == nextFragmentId) {
        break;
      }
    }

    // Check if we reached same-or-higher heading level
    if (current is dom.Element) {
      final currentLevel = getHeadingLevel(current);
      if (currentLevel != null) {
        final isInNoteOrSidebar = isInsideNoteOrSidebar(current);

        if (passedStartHeading &&
            currentLevel <= effectiveStartLevel &&
            !isInNoteOrSidebar &&
            hasCollectedContent) {
          break;
        }
        if (!passedStartHeading &&
            currentLevel == effectiveStartLevel &&
            !isInNoteOrSidebar) {
          passedStartHeading = true;
        }
      }
    }

    var shouldCollect = true;
    if (isFirstIteration &&
        current == actualStart &&
        getHeadingLevel(actualStart) != null) {
      shouldCollect = false;
    }
    isFirstIteration = false;

    if (shouldCollect && current.nodeType == dom.Node.TEXT_NODE) {
      final text = current.text ?? '';
      if (text.isNotEmpty) {
        emitter.writeText(text);
        if (text.trim().isNotEmpty) {
          hasCollectedContent = true;
        }
      }
    }

    if (current is dom.Element) {
      if (current.localName?.toLowerCase() == 'br') {
        emitter.writeLineBreak();
      } else if (isBlockElement(current)) {
        emitter.writeBlockSeparator();
      }
    }

    current = getNextNode(current);
  }

  // Close any still-open ancestor span (defensive — a section could end
  // mid-<pre>).
  syncAncestorState(null);
}

/// Get next node in document order (depth-first traversal).
dom.Node? getNextNode(dom.Node node) {
  // If node has children, return first child
  if (node is dom.Element && node.nodes.isNotEmpty) {
    return node.nodes.first;
  }

  // Find next sibling or ancestor's sibling
  final parent = node.parent;
  if (parent != null) {
    final index = parent.nodes.indexOf(node);
    if (index >= 0 && index < parent.nodes.length - 1) {
      return parent.nodes[index + 1];
    }

    // Walk up to find parent's next sibling
    var ancestor = parent;
    while (ancestor.parent != null) {
      final grandParent = ancestor.parent!;
      final ancestorIndex = grandParent.nodes.indexOf(ancestor);
      if (ancestorIndex >= 0 && ancestorIndex < grandParent.nodes.length - 1) {
        return grandParent.nodes[ancestorIndex + 1];
      }
      ancestor = grandParent;
    }
  }

  return null;
}

/// Get heading level (1-6) from element.
int? getHeadingLevel(dom.Element element) {
  final tag = element.localName?.toLowerCase();
  if (tag != null && tag.startsWith('h') && tag.length == 2) {
    return int.tryParse(tag[1]);
  }
  return null;
}

/// Check if element is a block-level element.
bool isBlockElement(dom.Element element) {
  final tag = element.localName?.toLowerCase();
  if (tag == null) return false;

  const blockTags = {
    'p',
    'div',
    'section',
    'article',
    'aside',
    'header',
    'footer',
    'nav',
    'main',
    'figure',
    'figcaption',
    'blockquote',
    'pre',
    'hr',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'ul',
    'ol',
    'li',
    'dl',
    'dt',
    'dd',
    'table',
    'tr',
    'th',
    'td',
    'thead',
    'tbody',
    'tfoot',
    'form',
    'fieldset',
    'legend',
    'address',
    'details',
    'summary',
  };

  return blockTags.contains(tag);
}

/// Clean extracted text by normalizing whitespace.
String cleanExtractedText(String text) {
  var result = text.replaceAll(RegExp(r'[ \t]*\n[ \t]*'), '\n');
  result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  result = result.replaceAll(RegExp(r'[ \t]{2,}'), ' ');

  final lines = result.split('\n').map((line) => line.trim());

  final cleanedLines = <String>[];
  var lastWasEmpty = false;
  for (final line in lines) {
    if (line.isEmpty) {
      if (!lastWasEmpty && cleanedLines.isNotEmpty) {
        cleanedLines.add('');
        lastWasEmpty = true;
      }
    } else {
      cleanedLines.add(line);
      lastWasEmpty = false;
    }
  }

  return cleanedLines.join('\n').trim();
}

/// Check if element is inside a note, tip, warning, or sidebar container.
bool isInsideNoteOrSidebar(dom.Element element) {
  dom.Node? current = element.parent;
  while (current != null) {
    final currentElement = current is dom.Element ? current : null;
    if (currentElement != null) {
      final dataType = currentElement.attributes['data-type']?.toLowerCase();
      if (dataType != null) {
        if (dataType == 'note' ||
            dataType == 'tip' ||
            dataType == 'warning' ||
            dataType == 'caution' ||
            dataType == 'important' ||
            dataType == 'sidebar') {
          return true;
        }
      }
      final epubType = currentElement.attributes['epub:type']?.toLowerCase();
      if (epubType != null) {
        if (epubType == 'note' ||
            epubType == 'tip' ||
            epubType == 'warning' ||
            epubType == 'sidebar') {
          return true;
        }
      }
      final className = currentElement.className.toLowerCase();
      if (className.contains('note') ||
          className.contains('tip') ||
          className.contains('warning') ||
          className.contains('sidebar') ||
          className.contains('callout') ||
          className.contains('admonition')) {
        return true;
      }
      if (currentElement.localName?.toLowerCase() == 'aside') {
        return true;
      }
    }
    current = current.parent;
  }
  return false;
}

/// A scratch span on the emitter's preserve stack — records the buffer
/// position when entering a `<pre>` so the exit handler can close the
/// range cleanly.
class _PreserveSpan {
  final dom.Element element;
  final int startPos;
  const _PreserveSpan(this.element, this.startPos);
}

/// Emits text into a [StringBuffer] while tracking preserved ranges
/// (for `<pre>`) and element ranges (for `<figcaption>` in v1.0; lists,
/// tables, dl items in v1.1/v1.2).
///
/// Tab→4-space normalisation happens during preserve-mode writes so the
/// renderer doesn't have to know about tabs (plan §5.3).
class _StructuredEmitter {
  final StringBuffer _buffer = StringBuffer();
  final List<TextRange> _preservedRanges = [];
  final Map<dom.Element, List<TextRange>> _elementRanges = {};

  // Stack of currently-open preserve spans. A reentrancy stack handles
  // nested <pre> (rare but legal — avoids state corruption).
  final List<_PreserveSpan> _preserveStack = [];
  // Single open figcaption span (figcaptions are not nested in practice).
  _PreserveSpan? _figcaptionSpan;

  bool get _inPreserveMode => _preserveStack.isNotEmpty;

  String get text => _buffer.toString();

  void writeText(String text) {
    if (text.isEmpty) return;
    if (_inPreserveMode) {
      // Preserve verbatim, with tab→4-space normalisation and \r dropped.
      // Plan §5.3.
      final normalised =
          text.replaceAll('\t', '    ').replaceAll('\r', '');
      _buffer.write(normalised);
    } else {
      _buffer.write(text);
    }
  }

  void writeBlockSeparator() {
    if (_inPreserveMode) {
      // Inside a <pre>, block separators are emitted as literal `\n\n` of
      // the source — we don't want to add structural separators to code.
      return;
    }
    _buffer.write('\n\n');
  }

  void writeLineBreak() {
    _buffer.write('\n');
  }

  void enterPreserve(dom.Element element) {
    _preserveStack.add(_PreserveSpan(element, _buffer.length));
  }

  void exitPreserve(dom.Element element) {
    // Walk up the stack to find the matching span. In practice this is
    // always the top of the stack, but defensively scan in case of
    // unexpected nesting.
    for (var i = _preserveStack.length - 1; i >= 0; i--) {
      if (_preserveStack[i].element == element) {
        final span = _preserveStack.removeAt(i);
        final endPos = _buffer.length;
        if (endPos > span.startPos) {
          final range = TextRange(span.startPos, endPos);
          _preservedRanges.add(range);
          _elementRanges[element] = [range];
        }
        return;
      }
    }
  }

  void enterFigcaption(dom.Element element) {
    _figcaptionSpan = _PreserveSpan(element, _buffer.length);
    // Treat figcaption content as a PRESERVED range so the cleaner
    // doesn't collapse internal whitespace and corrupt the figcaption's
    // tracked offsets. Without this, the coarse 3-edit diff in
    // `cleanTextRespectingRanges` could collapse an outside segment
    // containing prose + figcaption + boundary into one Replace, leaving
    // the figcaption's `mapStart`/`mapEnd` pointing at the wrong span.
    // Pushing the figcaption text through verbatim keeps its element
    // range stable across the cleaner.
    _preserveStack.add(_PreserveSpan(element, _buffer.length));
  }

  void exitFigcaption(dom.Element element) {
    final span = _figcaptionSpan;
    if (span == null || span.element != element) return;
    _figcaptionSpan = null;
    // Close the matching preserve-stack entry from enterFigcaption.
    for (var i = _preserveStack.length - 1; i >= 0; i--) {
      if (_preserveStack[i].element == element) {
        final preservedSpan = _preserveStack.removeAt(i);
        final preservedEnd = _buffer.length;
        if (preservedEnd > preservedSpan.startPos) {
          _preservedRanges.add(
            TextRange(preservedSpan.startPos, preservedEnd),
          );
        }
        break;
      }
    }
    final endPos = _buffer.length;
    if (endPos > span.startPos) {
      _elementRanges[element] = [TextRange(span.startPos, endPos)];
    }
  }

  /// Build an [ExtractedText] from the emitter's current state. The caller
  /// must pass the [document] used for parsing — it's the source of truth
  /// for element identity.
  ExtractedText toExtractedText(dom.Document document) {
    // Drop any zero-length preserved ranges defensively (shouldn't happen).
    final preserved = _preservedRanges.where((r) => !r.isEmpty).toList();
    return ExtractedText(
      text: _buffer.toString(),
      preservedRanges: preserved,
      elementRanges: Map.of(_elementRanges),
      document: document,
    );
  }
}
