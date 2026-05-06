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
  // Symmetry with the linear walkers: explicitly close any open li/dt/dd
  // state. toExtractedText also defensively cleans up, but doing it here
  // keeps the emitter's lifecycle consistent across all extraction paths.
  emitter.syncDirectLi(null);
  emitter.syncDtDd(null);
  return emitter.toExtractedText(document);
}

/// Walk every node in the subtree rooted at [root] and emit text via
/// [emitter]. Used for both whole-chapter and "until-fragment" extraction
/// variants.
void _walkAll(dom.Node root, _StructuredEmitter emitter) {
  // Sync ancestor-derived state (closest <li>, closest <dt>/<dd>) so the
  // emitter can attribute text to the right element. Done at the start of
  // every node visit — that timing puts close-slice transitions BEFORE any
  // block separator is written for the new node, keeping slice ranges off
  // of inter-block whitespace.
  emitter.syncDirectLi(findDirectLi(root));
  emitter.syncDtDd(findDtDdAncestor(root));

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

    // Sync li/dtdd ancestor state so v1.1 list/dl tracking fires for
    // sections extracted via the no-fragment-id-but-end-fragment path
    // (codex round-1 MEDIUM: previously this walker skipped sync, leaving
    // leading sections without listItem / definitionItem blocks).
    emitter.syncDirectLi(findDirectLi(node));
    emitter.syncDtDd(findDtDdAncestor(node));

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
    } else {
      // Document / DocumentFragment — recurse into children. (Without
      // this branch, `walkNodes(document)` did nothing because Document
      // is neither a Text nor an Element node, so the no-fragmentId
      // beginning-only-section extraction path produced empty output.)
      for (final child in node.nodes) {
        walkNodes(child);
        if (stopped) break;
      }
    }
  }

  walkNodes(document);
  // Close any still-open li / dt-dd state at end of walk.
  emitter.syncDirectLi(null);
  emitter.syncDtDd(null);
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
    emitter.syncDirectLi(findDirectLi(node));
    emitter.syncDtDd(findDtDdAncestor(node));
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

/// Walking up from [node], return the closest `<li>` ancestor whose direct
/// text [node] contributes to. Returns null if [node] is shadowed by an
/// intervening block-level element — in that case the text belongs to a
/// nested block (another list, a code block, a figure, a table, etc.),
/// not directly to the enclosing `<li>`. Plan §5.8 specifies `<ul>` / `<ol>`
/// shadowing for nested lists; we generalise to all block tags so that a
/// `<li>` whose only "content" is `<figure class="code"><pre>...</pre></figure>`
/// produces an empty direct-text slice (correct: the code block emits at
/// its own range, not as part of the list item).
dom.Element? findDirectLi(dom.Node? node) {
  var cur = node;
  while (cur != null) {
    if (cur is dom.Element) {
      final tag = cur.localName?.toLowerCase();
      if (tag == 'li') return cur;
      if (isBlockElement(cur)) return null;
    }
    cur = cur.parent;
  }
  return null;
}

/// Walking up from [node], return the closest `<dt>` or `<dd>` ancestor.
/// Used by the structured emitter to record per-term/per-definition ranges.
///
/// Mirrors [findDirectLi]'s shadowing rule: an intervening block-level
/// element (e.g. `<pre>` inside a `<dd>`) returns null, so the dt/dd's
/// recorded range never straddles a preserved-content boundary (codex
/// round-1 MEDIUM — `<dd>before<pre>code</pre>after</dd>` would otherwise
/// span [before_start, after_end) and violate invariant 4).
dom.Element? findDtDdAncestor(dom.Node? node) {
  var cur = node;
  while (cur != null) {
    if (cur is dom.Element) {
      final tag = cur.localName?.toLowerCase();
      if (tag == 'dt' || tag == 'dd') return cur;
      if (isBlockElement(cur)) return null;
    }
    cur = cur.parent;
  }
  return null;
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

/// Frame for a single `<li>` element. Tracks an in-progress slice (for the
/// current direct-text run) and the list of completed slices already
/// closed for this `<li>`. Plan §5.8: an `<li>` may have multiple slices
/// when nested `<ul>` / `<ol>` children break up its direct text.
class _ListItemFrame {
  /// Buffer position where the currently-open slice started, or null if
  /// no slice is currently open. A slice opens lazily on the first
  /// [_StructuredEmitter.writeText] call after [_StructuredEmitter.syncDirectLi]
  /// transitions into this `<li>` — that defers slice-start past any
  /// intermediate block-separator writes.
  int? openStart;

  /// True iff the slice should open at the next [_StructuredEmitter.writeText].
  /// Set on entering or re-entering this `<li>`; cleared once the slice opens.
  bool pendingOpen = false;

  /// True iff any non-whitespace character has been written into the
  /// currently-open slice. Whitespace-only slices are NOT recorded — they
  /// would otherwise mislead the builder's slice-pop walker on
  /// pretty-printed input like `<li>\n<ul>...</ul>\ntail</li>` (codex
  /// round-1 HIGH: leading-newline text node would steal the tail slice).
  bool sliceHasNonWs = false;

  final List<TextRange> ranges = [];
}

/// Frame for a single `<dt>` or `<dd>` element. Records at most one range
/// (the FIRST contiguous direct-text slice). Subsequent slices — created
/// when a block descendant like `<pre>` shadows the dt/dd — are dropped to
/// keep the recorded range from straddling a preserved boundary (codex
/// round-1 MEDIUM). The trailing text becomes orphan plain text in v1.1;
/// supporting multi-range definitionItem bodies is deferred to v2.
class _DtDdFrame {
  int? openStart;
  bool pendingOpen = false;
  bool sliceHasNonWs = false;
  TextRange? range;
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

  // <li> slice tracking (plan §5.8). Lazy frame allocation per <li> on first
  // [syncDirectLi]. Only one <li>'s slice can be in "pending open" state at
  // a time (sync transitions enforce this — entering a new li always closes
  // the prior one's pending state via close-slice).
  final Map<dom.Element, _ListItemFrame> _liFrames = {};
  dom.Element? _currentDirectLi;
  // Element whose frame should open a slice at the next text write.
  dom.Element? _pendingOpenLi;

  // <dt>/<dd> single-range tracking. Same lazy / pending semantics as <li>.
  final Map<dom.Element, _DtDdFrame> _dtDdFrames = {};
  dom.Element? _currentDtDd;
  dom.Element? _pendingOpenDtDd;

  bool get _inPreserveMode => _preserveStack.isNotEmpty;

  String get text => _buffer.toString();

  void writeText(String text) {
    if (text.isEmpty) return;
    // Open any pending slice BEFORE the text is appended, so the slice
    // start lands exactly on the first character of this text run.
    if (_pendingOpenLi != null) {
      final frame = _liFrames.putIfAbsent(
        _pendingOpenLi!,
        () => _ListItemFrame(),
      );
      frame.openStart = _buffer.length;
      frame.sliceHasNonWs = false;
      frame.pendingOpen = false;
      _pendingOpenLi = null;
    }
    if (_pendingOpenDtDd != null) {
      final frame = _dtDdFrames.putIfAbsent(
        _pendingOpenDtDd!,
        () => _DtDdFrame(),
      );
      // Only set openStart once — the very first writeText after enter.
      // Subsequent writes leave it untouched so the range covers all text.
      frame.openStart ??= _buffer.length;
      frame.pendingOpen = false;
      _pendingOpenDtDd = null;
    }

    // Track whether this text run has any non-whitespace characters. Used
    // by [_closeLiSlice] / [_closeDtDdSlice] to drop whitespace-only
    // slices (codex round-1 HIGH).
    final textHasNonWs = _hasAsciiNonWs(text);
    if (textHasNonWs) {
      if (_currentDirectLi != null) {
        final frame = _liFrames[_currentDirectLi];
        if (frame != null && frame.openStart != null) {
          frame.sliceHasNonWs = true;
        }
      }
      if (_currentDtDd != null) {
        final frame = _dtDdFrames[_currentDtDd];
        if (frame != null && frame.openStart != null) {
          frame.sliceHasNonWs = true;
        }
      }
    }

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

  static bool _hasAsciiNonWs(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) return true;
    }
    return false;
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

  /// Update the closest-`<li>` ancestor tracker. Called by both walkers
  /// before processing each node. On transition: close the previous `<li>`'s
  /// open slice (if any), and queue a "pending open" on the new `<li>` so
  /// its slice opens precisely at the next [writeText] (skipping any
  /// intermediate block separators).
  void syncDirectLi(dom.Element? newLi) {
    if (identical(newLi, _currentDirectLi)) return;
    final prev = _currentDirectLi;
    if (prev != null) {
      final frame = _liFrames[prev];
      if (frame != null) _closeLiSlice(frame);
    }
    // Cancel any prior pending-open that hasn't fired yet — the slice never
    // got real text, so there's nothing to record.
    _pendingOpenLi = newLi;
    _currentDirectLi = newLi;
    if (newLi != null) {
      final frame = _liFrames.putIfAbsent(newLi, () => _ListItemFrame());
      frame.pendingOpen = true;
    }
  }

  /// Update the closest-`<dt>`/`<dd>` ancestor tracker. Same semantics as
  /// [syncDirectLi] but records a single (start, end) per element.
  void syncDtDd(dom.Element? newDtDd) {
    if (identical(newDtDd, _currentDtDd)) return;
    final prev = _currentDtDd;
    if (prev != null) {
      final frame = _dtDdFrames[prev];
      if (frame != null) _closeDtDdSlice(frame);
    }
    _pendingOpenDtDd = newDtDd;
    _currentDtDd = newDtDd;
    if (newDtDd != null) {
      final frame = _dtDdFrames.putIfAbsent(newDtDd, () => _DtDdFrame());
      frame.pendingOpen = true;
    }
  }

  void _closeLiSlice(_ListItemFrame frame) {
    if (frame.openStart != null) {
      if (_buffer.length > frame.openStart! && frame.sliceHasNonWs) {
        frame.ranges.add(TextRange(frame.openStart!, _buffer.length));
      }
      frame.openStart = null;
      frame.sliceHasNonWs = false;
    }
    frame.pendingOpen = false;
  }

  void _closeDtDdSlice(_DtDdFrame frame) {
    if (frame.openStart != null) {
      if (_buffer.length > frame.openStart! && frame.sliceHasNonWs) {
        // Record the FIRST contiguous direct-text slice only. Subsequent
        // slices (created when a block descendant like <pre> shadows the
        // dt/dd) are dropped — combining them would produce a range that
        // straddles the preserved boundary, violating the ExtractedText
        // invariant 4 (codex round-1 MEDIUM). Multi-range definitionItem
        // bodies are deferred to v2.
        frame.range ??= TextRange(frame.openStart!, _buffer.length);
      }
      frame.openStart = null;
      frame.sliceHasNonWs = false;
    }
    frame.pendingOpen = false;
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
    // Finalise any still-open <li> / <dt> / <dd> slices. Defensive: the
    // walker's last sync(null) at end-of-section normally closes everything,
    // but in pathological mid-element termination we still need to cap.
    if (_currentDirectLi != null) {
      final frame = _liFrames[_currentDirectLi];
      if (frame != null) _closeLiSlice(frame);
      _currentDirectLi = null;
      _pendingOpenLi = null;
    }
    if (_currentDtDd != null) {
      final frame = _dtDdFrames[_currentDtDd];
      if (frame != null) _closeDtDdSlice(frame);
      _currentDtDd = null;
      _pendingOpenDtDd = null;
    }

    // Populate elementRanges for tracked <li>s and dt/dds. Skip empty
    // frames so we don't pollute the map with no-op entries.
    for (final entry in _liFrames.entries) {
      if (entry.value.ranges.isNotEmpty) {
        _elementRanges[entry.key] = List.of(entry.value.ranges);
      }
    }
    for (final entry in _dtDdFrames.entries) {
      final r = entry.value.range;
      if (r != null && !r.isEmpty) {
        _elementRanges[entry.key] = [r];
      }
    }

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
