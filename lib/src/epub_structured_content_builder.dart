import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';
import 'extracted_text.dart';
import 'html_text_extractor.dart';

/// Builds structured content annotations from EPUB HTML.
///
/// Two entry points:
/// - [buildFromHtml] / [buildFromSectionHtml] — legacy plainText-only API,
///   matches block elements by fuzzy text search. Pre-v1.0 behavior; lacks
///   code-block / figcaption / inline-monospace support. Kept for callers
///   that don't have an [ExtractedText] available.
/// - [build] — v1.0 API. Takes a [SectionExtraction] (text + preserved
///   ranges + element ranges + DOM). Emits code blocks via known offsets,
///   figcaption italic marks, and inline monospace marks via ancestor stack.
class EpubStructuredContentBuilder {
  /// Build structured content from full chapter HTML (legacy API).
  ///
  /// Equivalent to pre-v1.0 behavior — no code-block / figcaption /
  /// monospace emission. Kept for callers that don't have a [SectionExtraction].
  static String? buildFromHtml(String htmlContent, String plainText) {
    if (plainText.trim().length < 50) return null;

    try {
      final document = html_parser.parse(htmlContent);
      document.querySelectorAll('script, style').forEach((e) => e.remove());

      final body = document.body;
      if (body == null) return null;

      final ctx = _WalkContext(plainText, <ContentBlock>[]);
      _walkBlocks(body, ctx);

      if (ctx.blocks.isEmpty) return null;

      final content = StructuredContent.fromBlocks(plainText, ctx.blocks);
      return content?.toJsonString();
    } catch (_) {
      return null;
    }
  }

  /// Build structured content from a section within HTML (legacy API).
  /// Forwards to [buildFromHtml] — fragment IDs are honoured by the caller's
  /// pre-extraction step, not here.
  static String? buildFromSectionHtml(
    String htmlContent,
    String plainText, {
    String? fragmentId,
    String? nextFragmentId,
  }) {
    return buildFromHtml(htmlContent, plainText);
  }

  /// v1.0 API: build structured content from a [SectionExtraction] with
  /// preserved ranges and element ranges populated.
  ///
  /// Emits in this order (plan §5.11):
  /// 1. Code-figure wrappers (`<figure class="code">`, `<div class="highlight">`) — recurse into.
  /// 2. `<figcaption>` inside a code figure — emit italic-marked paragraph.
  /// 3. `<pre>` — emit `paragraph` block with `preserveLineBreaks: true`
  ///    and a `monospace` mark covering the whole block.
  /// 4. Headings, paragraphs (existing behavior, with inline `<code>` /
  ///    `<kbd>` / `<samp>` / `<var>` / `<tt>` adding monospace marks).
  /// 5. Block-container recursion (existing).
  ///
  /// Returns JSON string or null if extraction fails.
  static String? build(SectionExtraction extraction) {
    final extracted = extraction.extracted;
    final plainText = extracted.text;
    if (plainText.trim().length < 50) return null;

    try {
      final document = extracted.document;
      final body = document.body;
      if (body == null) return null;

      // Plan §5.5: precompute a preorder index over every element in the
      // chapter document, then gate emission by
      // `preorderIndex[node] >= startIdx && preorderIndex[node] < endIdx`.
      // Without the gate, an out-of-section element whose text
      // coincidentally appears in plainText could be matched by the fuzzy
      // matcher and produce a false-positive block. The risk grows with
      // v1.1's `<li>` matcher (many more candidates per section).
      //
      // The fragment-ID element is often a deep descendant inside a
      // heading (e.g. `<h2><a id="s1"></a>Section title</h2>`), so we
      // walk up to the smallest block-level ancestor and use its
      // preorder index as the section start. Same for section end.
      // Stopping at the first (smallest) block keeps two markers in the
      // same wrapping block from collapsing to identical bounds.
      final preorderIndex = _buildPreorderIndex(body);
      final startIdx = extraction.sectionStartElement != null
          ? _sectionBoundIndex(
              extraction.sectionStartElement!,
              preorderIndex,
              body,
            )
          : 0;
      final endIdx = extraction.sectionEndElement != null
          ? _sectionBoundIndex(
              extraction.sectionEndElement!,
              preorderIndex,
              body,
            )
          : preorderIndex.length;

      final ctx = _WalkContext(
        plainText,
        <ContentBlock>[],
        elementRanges: extracted.elementRanges,
        preorderIndex: preorderIndex,
        sectionStartIndex: startIdx,
        sectionEndIndex: endIdx,
      );
      _walkBlocks(body, ctx);

      if (ctx.blocks.isEmpty) return null;

      final content = StructuredContent.fromBlocks(plainText, ctx.blocks);
      return content?.toJsonString();
    } catch (_) {
      return null;
    }
  }

  /// Build a `Map<dom.Element, int>` mapping each element to its preorder
  /// position in [root]'s subtree. O(N) where N = element count.
  static Map<dom.Element, int> _buildPreorderIndex(dom.Element root) {
    final index = <dom.Element, int>{};
    var counter = 0;
    void visit(dom.Element e) {
      index[e] = counter++;
      for (final c in e.children) {
        visit(c);
      }
    }

    visit(root);
    return index;
  }

  /// Return the preorder index of the smallest block-level ancestor of
  /// [marker] that contains it. Used to compute section bounds.
  ///
  /// We lift the fragment-ID marker through inline-only ancestors (`<a>`,
  /// `<span>`, `<em>`, `<i>`, `<b>`, `<strong>`, `<u>`) up to the first
  /// block element. The block element is the section anchor we want
  /// (e.g. the `<h2>` enclosing `<a id="s1">`).
  ///
  /// **Critical:** we DON'T lift further through enclosing block parents.
  /// If two fragment markers (one for the section's start, one for the
  /// next section's start) live under the same wrapping block (e.g.
  /// `<div><h2><a id="s1"/></h2>...<h2><a id="s2"/></h2></div>`), lifting
  /// to the wrapping `<div>` would collapse both bounds to the same
  /// preorder index → empty section → no emission. Stopping at the first
  /// block keeps the bounds distinct.
  static int _sectionBoundIndex(
    dom.Element marker,
    Map<dom.Element, int> preorderIndex,
    dom.Element body,
  ) {
    var cur = marker;
    while (cur != body) {
      final tag = cur.localName?.toLowerCase();
      if (tag != null && _isBlockLikeForBound(tag)) {
        // `cur` itself is a block — use it as the section anchor.
        break;
      }
      final parent = cur.parent;
      if (parent is! dom.Element) break;
      if (parent == body) break;
      cur = parent;
    }
    return preorderIndex[cur] ?? preorderIndex[marker] ?? 0;
  }

  static bool _isBlockLikeForBound(String tag) {
    const blockTags = {
      'p', 'div', 'section', 'article', 'aside', 'header', 'footer',
      'nav', 'main', 'figure', 'figcaption', 'blockquote', 'pre',
      'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
      'ul', 'ol', 'li', 'dl', 'dt', 'dd',
      'table', 'tr', 'th', 'td', 'thead', 'tbody', 'tfoot',
      'details', 'summary',
    };
    return blockTags.contains(tag);
  }

  /// Walk DOM tree and dispatch each child node to a per-tag handler.
  ///
  /// Each handler returns `true` if it **claimed the dispatch slot** for the
  /// tag — i.e. "this is a heading / paragraph-like / etc." — independent of
  /// whether a block was actually emitted (the matcher may decline). The
  /// walker advances through children in DOM order. The cursor lives in
  /// [_WalkContext.searchFrom] and is advanced exclusively by
  /// [_WalkContext.recordBlock] when a handler emits a block.
  static void _walkBlocks(dom.Element parent, _WalkContext ctx) {
    for (final node in parent.nodes) {
      if (node is! dom.Element) continue;
      _dispatchNode(node, ctx);
    }
  }

  /// Dispatch a single element node through the per-tag handler chain.
  /// Extracted from [_walkBlocks] so that [_handleLi] can dispatch nested
  /// block children of a `<li>` (e.g. `<pre>`, `<figure class="code">`)
  /// in DOM order without re-walking the parent.
  static void _dispatchNode(dom.Element node, _WalkContext ctx) {
    final tag = node.localName?.toLowerCase();
    if (tag == null) return;

    // Skip script/style.
    if (tag == 'script' || tag == 'style') return;

    // Element-ranges-based dispatches fire regardless of the section
    // gate. They're naturally section-scoped because the emitter only
    // populated ranges for in-section text — out-of-section <ul>/<dl>/<pre>
    // have no ranges and their handlers emit nothing. Allowing the
    // CONTAINER (e.g. <ul>) to be dispatched even when its preorder index
    // is before sectionStartIndex (codex round-3 MEDIUM) is what makes
    // section anchors INSIDE list items still produce listItem blocks
    // for the in-section <li> children.
    if (_emitFigcaptionIfApplicable(node, ctx)) return;
    if (_emitCodeBlockIfApplicable(node, ctx)) return;
    if (_recurseIntoCodeFigureWrapperIfApplicable(node, ctx)) return;
    if (_emitListContainerIfApplicable(node, ctx)) return;
    if (_emitDefinitionListIfApplicable(node, ctx)) return;

    // Fuzzy-match dispatches (heading, paragraph) DO need the section
    // gate — they search plainText for a content match, and out-of-section
    // text could yield false positives.
    final inSection = ctx.preorderIndex == null || _isInSection(node, ctx);
    if (inSection) {
      if (_emitHeadingIfApplicable(node, ctx)) return;
      if (_emitParagraphIfApplicable(node, tag, ctx)) return;
    }
    if (_isBlockContainer(tag)) {
      _recurseIntoBlockContainer(node, ctx);
      return;
    }
    // Inline-element fallthrough: recurse into element children so a block
    // wrapped in inline elements (e.g. `<a><pre>code</pre></a>` inside a
    // <dd> body, or generally `<body><a><div>...</div></a>...</body>`)
    // still reaches its dispatch (codex round-5 MEDIUM). Skip text nodes
    // (no block content there). Top-level inline text without block
    // descendants remains uncovered, same as before.
    for (final c in node.nodes) {
      if (c is dom.Element) {
        _dispatchNode(c, ctx);
      }
    }
  }

  static bool _isInSection(dom.Element node, _WalkContext ctx) {
    final idx = ctx.preorderIndex![node];
    if (idx == null) return false;
    return idx >= ctx.sectionStartIndex && idx < ctx.sectionEndIndex;
  }

  /// Claim the figcaption dispatch slot if [node] is a `<figcaption>`
  /// inside a code-figure wrapper, and an `elementRanges` entry exists.
  ///
  /// Emits a `paragraph` block with an italic emphasis mark covering the
  /// whole range.
  static bool _emitFigcaptionIfApplicable(
    dom.Element node,
    _WalkContext ctx,
  ) {
    if (ctx.elementRanges == null) return false;
    if (node.localName?.toLowerCase() != 'figcaption') return false;
    if (!_isInsideCodeFigure(node)) return false;
    final ranges = ctx.elementRanges![node];
    if (ranges == null || ranges.isEmpty) return false;
    final r = ranges.single;
    if (r.start < ctx.searchFrom) return true; // claim, but skip — shouldn't happen
    ctx.recordBlock(
      ContentBlock(
        type: ContentBlockType.paragraph,
        start: r.start,
        end: r.end,
        marks: [
          InlineMark(
            type: InlineMarkType.emphasis,
            start: r.start,
            end: r.end,
            style: 'italic',
          ),
        ],
      ),
    );
    return true;
  }

  /// Claim the `<pre>` dispatch slot. Emits a `paragraph` block with
  /// `preserveLineBreaks: true` and a single `monospace` mark covering the
  /// entire block.
  static bool _emitCodeBlockIfApplicable(dom.Element node, _WalkContext ctx) {
    if (ctx.elementRanges == null) return false;
    if (node.localName?.toLowerCase() != 'pre') return false;
    final ranges = ctx.elementRanges![node];
    if (ranges == null || ranges.isEmpty) return false;
    final r = ranges.single;
    if (r.start < ctx.searchFrom) return true; // claim, skip overlap
    ctx.recordBlock(
      ContentBlock(
        type: ContentBlockType.paragraph,
        start: r.start,
        end: r.end,
        preserveLineBreaks: true,
        marks: [
          InlineMark(
            type: InlineMarkType.monospace,
            start: r.start,
            end: r.end,
          ),
        ],
      ),
    );
    return true;
  }

  /// Recurse into a code-figure wrapper (`<figure class="code">` /
  /// `<div class="highlight">`) so its `<figcaption>` and `<pre>` children
  /// emit at their own DOM positions in source order.
  static bool _recurseIntoCodeFigureWrapperIfApplicable(
    dom.Element node,
    _WalkContext ctx,
  ) {
    if (ctx.elementRanges == null) return false;
    if (!_isCodeFigureWrapper(node)) return false;
    _walkBlocks(node, ctx);
    if (ctx.blocks.isNotEmpty) {
      ctx.searchFrom = ctx.blocks.last.end;
    }
    return true;
  }

  static bool _isCodeFigureWrapper(dom.Element node) {
    final tag = node.localName?.toLowerCase();
    if (tag == 'figure' && node.classes.contains('code')) {
      return node.querySelector('pre') != null;
    }
    if (tag == 'div' && node.classes.contains('highlight')) {
      return node.querySelector('pre') != null;
    }
    return false;
  }

  static bool _isInsideCodeFigure(dom.Element node) {
    var cur = node.parent;
    while (cur != null) {
      if (_isCodeFigureWrapper(cur)) return true;
      cur = cur.parent;
    }
    return false;
  }

  /// v1.1: claim a `<ul>` / `<ol>` container. Emits one `listItem` block per
  /// direct-text slice of each child `<li>`, in DOM order. Plan §5.8.
  ///
  /// **DOM-order interleaving for nested lists** is the load-bearing detail:
  /// for `<li>outer<ul><li>inner</li></ul>tail</li>` we must emit
  /// `outer → inner → tail`, not `outer → tail → inner`. The walker iterates
  /// each `<li>`'s child nodes (text + elements), maintains a slice
  /// pop-cursor over the `<li>`'s pre-recorded ranges, lazily pops a slice
  /// when entering a contiguous direct-text run, and recurses into nested
  /// `<ul>` / `<ol>` children in place.
  static bool _emitListContainerIfApplicable(
    dom.Element node,
    _WalkContext ctx,
  ) {
    if (ctx.elementRanges == null) return false;
    final tag = node.localName?.toLowerCase();
    if (tag != 'ul' && tag != 'ol') return false;

    final isOrdered = tag == 'ol';
    var counter = 1;
    for (final child in node.children) {
      if (child.localName?.toLowerCase() != 'li') continue;
      _handleLi(child, node, isOrdered, counter, ctx);
      if (isOrdered) counter++;
    }
    // Claim regardless of whether we emitted anything — an empty <ul> is
    // still consumed (no fall-through to block-container recursion or
    // paragraph fallback).
    return true;
  }

  /// Walk a single `<li>`'s children per plan §5.8, emitting listItem
  /// blocks at slice boundaries and recursing into nested lists.
  static void _handleLi(
    dom.Element li,
    dom.Element parentList,
    bool isOrdered,
    int counter,
    _WalkContext ctx,
  ) {
    final ranges = ctx.elementRanges![li] ?? const <TextRange>[];
    final state = _LiWalkState(ranges: ranges);

    // Recursive walker handles arbitrarily-deep inline wrappers around
    // block descendants — codex round-2 MEDIUM:
    // `<li><a>foo<div><pre>code</pre></div>bar</a></li>` must emit
    // listItem(foo), code(pre), listItem(bar). A flat li.nodes iteration
    // misses the nested <div><pre>... because <a> is inline.
    //
    // Walker semantics:
    // - On a block-level child: end any direct-text run and dispatch it
    //   via _dispatchNode (which handles nested-list recursion, code
    //   blocks, figure wrappers, etc.).
    // - On a `<ul>` / `<ol>` child: end run, recurse into list container.
    // - On an inline element: recurse into its children, continuing the
    //   same direct-text run state. Block descendants found there get
    //   dispatched in DOM order, splitting the slice walker.
    // - On a text node: if non-whitespace, pop a slice on entering a new
    //   direct-text run.
    for (final child in li.nodes) {
      _walkLiNode(child, state, parentList, isOrdered, counter, ctx);
    }
  }

  /// Recursive walker for `_handleLi`. Threads slice-pop state through an
  /// arbitrary inline-element subtree so deeply-wrapped block descendants
  /// still split the surrounding listItem slices in DOM order.
  static void _walkLiNode(
    dom.Node n,
    _LiWalkState state,
    dom.Element parentList,
    bool isOrdered,
    int counter,
    _WalkContext ctx,
  ) {
    if (n is dom.Element) {
      final ctag = n.localName?.toLowerCase();
      if (ctag == 'ul' || ctag == 'ol') {
        state.inDirectTextRun = false;
        _emitListContainerIfApplicable(n, ctx);
        return;
      }
      if (isBlockElement(n)) {
        state.inDirectTextRun = false;
        _dispatchNode(n, ctx);
        return;
      }
      // Inline element (e.g. <a>, <span>, <em>, <code>): recurse into
      // its children so any block descendants dispatch and any
      // non-whitespace text triggers a slice pop on the outer <li>.
      for (final c in n.nodes) {
        _walkLiNode(c, state, parentList, isOrdered, counter, ctx);
      }
      return;
    }
    if (n is dom.Text) {
      if (!_hasAsciiNonWs(n.text)) return; // whitespace-only
      if (!state.inDirectTextRun) {
        if (state.sliceIndex < state.ranges.length) {
          final slice = state.ranges[state.sliceIndex];
          if (slice.start >= ctx.searchFrom) {
            final marker = state.isFirstSlice
                ? (isOrdered
                    ? _markerForOrderedList(parentList, counter)
                    : '•')
                : '';
            ctx.recordBlock(
              ContentBlock(
                type: ContentBlockType.listItem,
                start: slice.start,
                end: slice.end,
                listMarker: marker,
              ),
            );
          }
          state.sliceIndex++;
          state.isFirstSlice = false;
        }
        state.inDirectTextRun = true;
      }
    }
  }

  /// Walk a `<dt>`'s subtree in DOM order, dispatching block descendants
  /// at their DOM positions and emitting a single term-only definitionItem
  /// at the position of the first non-whitespace text run. Used by
  /// [_emitDefinitionListIfApplicable] when `<dt>` contains block
  /// descendants and DOM ordering between text and blocks could be
  /// either way (codex round-4 MEDIUM).
  static void _walkDtMixedBlock(
    dom.Element dt,
    TextRange dtRange,
    _WalkContext ctx,
  ) {
    var termEmitted = false;
    void walk(dom.Node n) {
      if (n is dom.Element) {
        if (isBlockElement(n)) {
          _dispatchNode(n, ctx);
          return;
        }
        for (final c in n.nodes) {
          walk(c);
        }
        return;
      }
      if (n is dom.Text && _hasAsciiNonWs(n.text) && !termEmitted) {
        if (dtRange.start >= ctx.searchFrom && dtRange.end > dtRange.start) {
          ctx.recordBlock(
            ContentBlock(
              type: ContentBlockType.definitionItem,
              start: dtRange.start,
              end: dtRange.end,
              definitionTermEnd: dtRange.end,
            ),
          );
        }
        termEmitted = true;
      }
    }

    for (final c in dt.nodes) {
      walk(c);
    }
  }

  static bool _hasAsciiNonWs(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) return true;
    }
    return false;
  }

  /// Compute the marker text for the [counter]-th item of an ordered list.
  /// Supports the `type` attribute values `1` (default), `a`, and `A`.
  /// Roman numerals (`i` / `I`) fall back to numeric. start="N" is out of
  /// scope for v1.1; counter always starts at 1 (plan §5.8).
  static String _markerForOrderedList(dom.Element ol, int counter) {
    final type = ol.attributes['type'];
    return switch (type) {
      'a' => '${_toBase26(counter, lower: true)}.',
      'A' => '${_toBase26(counter, lower: false)}.',
      _ => '$counter.',
    };
  }

  static String _toBase26(int n, {required bool lower}) {
    if (n <= 0) return '';
    final base = lower ? 'a'.codeUnitAt(0) : 'A'.codeUnitAt(0);
    final out = <int>[];
    var v = n;
    while (v > 0) {
      v--; // bijective mapping: 1 → 'a', 26 → 'z', 27 → 'aa'
      out.add(base + v % 26);
      v ~/= 26;
    }
    return String.fromCharCodes(out.reversed);
  }

  /// v1.1: claim a `<dl>` container. Plan §5.9: emit one `definitionItem`
  /// per `<dt>`-led group covering `[dt.start, dd.end)` with
  /// `definitionTermEnd = dt.end`.
  ///
  /// For v1.1 we emit ONE definitionItem per `<dt>`+first-`<dd>` pair (or
  /// per orphan `<dt>` with no following `<dd>`). Block descendants of
  /// `<dd>` (e.g. `<pre>`) are dispatched through [_dispatchNode] so they
  /// emit in DOM order after the definitionItem. Multi-`<dd>` per `<dt>`
  /// degrades to multiple definitionItems sharing the term range —
  /// acceptable for v1.1; deferred refinement to v2.
  static bool _emitDefinitionListIfApplicable(
    dom.Element node,
    _WalkContext ctx,
  ) {
    if (ctx.elementRanges == null) return false;
    if (node.localName?.toLowerCase() != 'dl') return false;

    TextRange? activeDtRange;

    void emitDtDd(TextRange dtRange, TextRange? ddRange) {
      final start = dtRange.start;
      final end = ddRange?.end ?? dtRange.end;
      if (start < ctx.searchFrom || end <= start) return;
      ctx.recordBlock(
        ContentBlock(
          type: ContentBlockType.definitionItem,
          start: start,
          end: end,
          definitionTermEnd: dtRange.end,
        ),
      );
    }

    // Recursively dispatch block descendants in DOM order, walking through
    // inline wrappers (codex round-2 MEDIUM: `<dd><a><div><pre>code</pre>
    // </div></a></dd>` would otherwise miss the deeply-wrapped pre).
    void dispatchBlockDescendants(dom.Element parent) {
      for (final c in parent.nodes) {
        if (c is dom.Element) {
          if (isBlockElement(c)) {
            _dispatchNode(c, ctx);
          } else {
            dispatchBlockDescendants(c);
          }
        }
      }
    }

    bool hasBlockDescendant(dom.Element parent) {
      for (final c in parent.nodes) {
        if (c is dom.Element) {
          if (isBlockElement(c)) return true;
          if (hasBlockDescendant(c)) return true;
        }
      }
      return false;
    }

    for (final child in node.children) {
      final tag = child.localName?.toLowerCase();
      if (tag == 'dt') {
        // A previous orphan `<dt>` (no `<dd>` follows) emits as term-only.
        if (activeDtRange != null) {
          emitDtDd(activeDtRange, null);
          activeDtRange = null;
        }
        final ranges = ctx.elementRanges![child];
        // Codex round-3 MEDIUM: `<dt>` with block descendants (e.g.
        // `<dt>Term<pre>code</pre></dt>`) — without this branch, the
        // following `<dd>` would emit a definitionItem spanning over the
        // pre, suppressing the code block via the searchFrom overlap
        // guard. Mirror the `<dd>` term-only treatment: flush the dt as a
        // standalone definitionItem now, dispatch its block descendants,
        // and orphan any subsequent `<dd>` (acceptable v1.1 degradation —
        // dt-with-blocks is rare in practice).
        if (ranges != null && ranges.isNotEmpty) {
          if (hasBlockDescendant(child)) {
            // Codex round-4 MEDIUM: `<dt><pre>code</pre>Term</dt>` (pre
            // BEFORE term) would lose the code block if we emit
            // definitionItem first (term.start < pre.end after pre
            // dispatches). Walk dt's nodes in DOM order — dispatch blocks
            // at their DOM positions; emit term-only definitionItem when
            // we encounter the first direct-text run. Searches advance
            // monotonically regardless of dt's internal ordering.
            _walkDtMixedBlock(child, ranges.first, ctx);
            activeDtRange = null;
          } else {
            activeDtRange = ranges.first;
          }
        } else {
          // Empty <dt> — still walk for block dispatch (defensive).
          dispatchBlockDescendants(child);
        }
      } else if (tag == 'dd') {
        if (activeDtRange == null) {
          // Orphan <dd>: no preceding term. Skip the definitionItem but
          // still recurse into block descendants so any code blocks emit.
          dispatchBlockDescendants(child);
          continue;
        }
        // Codex round-2 MEDIUM: when <dd> contains block descendants
        // (e.g. <pre>), the dd's recorded range is just one of the
        // direct-text slices — possibly the slice AFTER the block. Using
        // that as the definitionItem's end would create a range that
        // spans backwards over the block, suppressing the block emission
        // (overlap guard). Term-only definitionItem when blocks present
        // sidesteps the issue; the dd's body text becomes orphaned plain
        // text in v1.1 (deferred to v2).
        if (hasBlockDescendant(child)) {
          emitDtDd(activeDtRange, null);
        } else {
          final ranges = ctx.elementRanges![child];
          final ddRange =
              (ranges == null || ranges.isEmpty) ? null : ranges.first;
          emitDtDd(activeDtRange, ddRange);
        }
        // Block descendants of the <dd> dispatch AFTER the definitionItem,
        // preserving DOM order in the emitted block list.
        dispatchBlockDescendants(child);
        activeDtRange = null;
      }
    }
    // Trailing orphan `<dt>` (no `<dd>` followed).
    if (activeDtRange != null) {
      emitDtDd(activeDtRange, null);
    }
    return true;
  }

  /// Claim the heading dispatch slot if [node] is `<h1>`–`<h6>`.
  ///
  /// Returns `true` whenever the tag is a heading — even if `_matchTextBlock`
  /// declines to emit (no plainText match). This mirrors the original
  /// `if (headingLevel != null) { ... } else if (_isParagraphLike) ...` chain,
  /// where the heading branch always consumed the node regardless of emit.
  static bool _emitHeadingIfApplicable(dom.Element node, _WalkContext ctx) {
    final level = getHeadingLevel(node);
    if (level == null) return false;

    final block = _matchTextBlock(
      node,
      ctx.plainText,
      ctx.searchFrom,
      ContentBlockType.heading,
      level: level,
      insideCodeBlock: false,
    );
    if (block != null) ctx.recordBlock(block);
    return true;
  }

  /// Claim the paragraph dispatch slot if [tag] is paragraph-like
  /// (`p`, `li`, `dt`, `dd`, `blockquote`, `pre`, `figcaption`).
  ///
  /// Returns `true` whenever the tag is paragraph-like — even if no block is
  /// emitted (matcher declined). Same dispatch-claim semantics as
  /// [_emitHeadingIfApplicable].
  static bool _emitParagraphIfApplicable(
    dom.Element node,
    String tag,
    _WalkContext ctx,
  ) {
    if (!_isParagraphLike(tag)) return false;

    final block = _matchTextBlock(
      node,
      ctx.plainText,
      ctx.searchFrom,
      ContentBlockType.paragraph,
      insideCodeBlock: false,
    );
    if (block != null) ctx.recordBlock(block);
    return true;
  }

  /// Recurse into a block container (`<div>`, `<section>`, etc.).
  static void _recurseIntoBlockContainer(dom.Element node, _WalkContext ctx) {
    _walkBlocks(node, ctx);
    if (ctx.blocks.isNotEmpty) {
      ctx.searchFrom = ctx.blocks.last.end;
    }
  }

  /// Match an element's text content to a range in the plain text.
  static ContentBlock? _matchTextBlock(
    dom.Element element,
    String plainText,
    int searchFrom,
    ContentBlockType type, {
    int? level,
    required bool insideCodeBlock,
  }) {
    final elementText = element.text.trim();
    if (elementText.isEmpty) return null;

    final normalized = _normalizeForMatch(elementText);
    if (normalized.isEmpty) return null;

    final searchKey =
        normalized.length > 60 ? normalized.substring(0, 60) : normalized;
    var idx = _fuzzyIndexOf(plainText, searchKey, searchFrom);
    if (idx < 0) return null;

    final endNormalized =
        normalized.length > 60 ? normalized.substring(normalized.length - 30) : null;
    int endIdx;
    if (endNormalized != null) {
      final endSearch = _fuzzyIndexOf(plainText, endNormalized, idx + 10);
      endIdx = endSearch >= 0 ? endSearch + endNormalized.length : idx + elementText.length;
    } else {
      endIdx = idx + _findMatchLength(plainText, idx, normalized);
    }

    endIdx = endIdx.clamp(idx + 1, plainText.length);

    final marks = <InlineMark>[];
    _collectInlineMarks(
      element,
      plainText,
      idx,
      marks,
      insideCodeBlock: insideCodeBlock,
    );

    return ContentBlock(
      type: type,
      start: idx,
      end: endIdx,
      level: level,
      marks: marks,
    );
  }

  /// Collect inline marks (emphasis, links, monospace) from element children.
  /// [insideCodeBlock] is the ancestor flag — when true, inline `<code>` /
  /// `<kbd>` etc. do NOT emit monospace marks (already covered by the
  /// block-level monospace).
  static void _collectInlineMarks(
    dom.Element element,
    String plainText,
    int blockStart,
    List<InlineMark> marks, {
    required bool insideCodeBlock,
  }) {
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
        // Recurse into the bold/italic for nested marks.
        _collectInlineMarks(
          node,
          plainText,
          blockStart,
          marks,
          insideCodeBlock: insideCodeBlock,
        );
      } else if (tag == 'em' || tag == 'i') {
        final mark = _matchInlineMark(
          node,
          plainText,
          blockStart,
          InlineMarkType.emphasis,
          style: 'italic',
        );
        if (mark != null) marks.add(mark);
        _collectInlineMarks(
          node,
          plainText,
          blockStart,
          marks,
          insideCodeBlock: insideCodeBlock,
        );
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
        _collectInlineMarks(
          node,
          plainText,
          blockStart,
          marks,
          insideCodeBlock: insideCodeBlock,
        );
      } else if (_isInlineMonospaceTag(tag)) {
        if (!insideCodeBlock) {
          final mark = _matchInlineMark(
            node,
            plainText,
            blockStart,
            InlineMarkType.monospace,
          );
          if (mark != null) marks.add(mark);
        }
        // Recurse with insideCodeBlock=true so nested marks know not to
        // double-emit monospace, but bold/italic inside <code> still emit.
        _collectInlineMarks(
          node,
          plainText,
          blockStart,
          marks,
          insideCodeBlock: true,
        );
      } else {
        _collectInlineMarks(
          node,
          plainText,
          blockStart,
          marks,
          insideCodeBlock: insideCodeBlock,
        );
      }
    }
  }

  static bool _isInlineMonospaceTag(String tag) {
    const tags = {'code', 'kbd', 'samp', 'var', 'tt'};
    return tags.contains(tag);
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

    final exactIdx = plainText.indexOf(needle, from);
    if (exactIdx >= 0) return exactIdx;

    final normalizedPlain = _normalizeForMatch(
      plainText.substring(from, (from + needle.length * 3).clamp(0, plainText.length)),
    );
    final idx = normalizedPlain.indexOf(needle);
    if (idx >= 0) {
      return _mapNormalizedOffset(plainText, from, idx);
    }

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
        origIdx++;
        while (origIdx < original.length && RegExp(r'\s').hasMatch(original[origIdx])) {
          origIdx++;
        }
        normIdx++;
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

/// Mutable walk state threaded through every per-tag handler in
/// [EpubStructuredContentBuilder._walkBlocks]. Single source of truth for
/// cursor advancement.
///
/// **Single-writer invariant:** [searchFrom] should be advanced exclusively
/// via [recordBlock]. The only other writer is the documented redundant
/// post-recursion snap in `_recurseIntoBlockContainer`, kept solely for
/// parity with the pre-refactor implementation. New handlers MUST NOT
/// assign to [searchFrom] directly — emit a [ContentBlock] via [recordBlock]
/// instead, so the cursor and the block list stay in lockstep.
class _WalkContext {
  final String plainText;
  final List<ContentBlock> blocks;
  int searchFrom = 0;

  /// Element-identity ranges from the [SectionExtraction] (v1.0+).
  /// Null when called via the legacy [EpubStructuredContentBuilder.buildFromHtml]
  /// path. Code-block, figcaption, list, table, etc. handlers consult this
  /// for exact offset attribution; absent → handler returns false → falls
  /// through to fuzzy-match dispatches.
  final Map<dom.Element, List<TextRange>>? elementRanges;

  /// Preorder index for the chapter document, computed once at build()
  /// entry. When non-null, [_walkBlocks] gates traversal by
  /// `[sectionStartIndex, sectionEndIndex)` so out-of-section elements
  /// can't produce false-positive blocks via fuzzy match.
  final Map<dom.Element, int>? preorderIndex;
  final int sectionStartIndex;
  final int sectionEndIndex;

  _WalkContext(
    this.plainText,
    this.blocks, {
    this.elementRanges,
    this.preorderIndex,
    this.sectionStartIndex = 0,
    this.sectionEndIndex = 0x7FFFFFFF,
  });

  void recordBlock(ContentBlock b) {
    blocks.add(b);
    searchFrom = b.end;
  }
}

/// Mutable state threaded through [EpubStructuredContentBuilder._walkLiNode]
/// while walking a single `<li>`'s subtree (text + inline elements + nested
/// blocks). Consolidates the slice-pop cursor + run-mode flag so the
/// recursive walker can update them via shared reference.
class _LiWalkState {
  final List<TextRange> ranges;
  int sliceIndex;
  bool isFirstSlice;
  bool inDirectTextRun;

  _LiWalkState({required this.ranges})
      : sliceIndex = 0,
        isFirstSlice = true,
        inDirectTextRun = false;
}
