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
      'details',
      'summary',
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
    if (_emitTableBlockIfApplicable(node, ctx)) return;

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
  static bool _emitFigcaptionIfApplicable(dom.Element node, _WalkContext ctx) {
    if (ctx.elementRanges == null) return false;
    if (node.localName?.toLowerCase() != 'figcaption') return false;
    if (!_isInsideCodeFigure(node)) return false;
    final ranges = ctx.elementRanges![node];
    if (ranges == null || ranges.isEmpty) return false;
    final r = ranges.single;
    if (r.start < ctx.searchFrom) {
      return true; // claim, but skip — shouldn't happen
    }
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
    final state = _LiWalkState(li: li, depth: _liDepth(li), ranges: ranges);

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
          // The cleaner can map adjacent <li>'s leading-and-trailing
          // formatting whitespace to OVERLAPPING cleaned positions
          // (e.g. nested <ol> formatted with newline+indent: outer-li
          // ends at the cleaned "\n\n", and inner-li-1 starts at the
          // SAME cleaned "\n\n"). Suppressing on slice.start <
          // ctx.searchFrom would drop every inner-li whose slice shares
          // boundary whitespace with its predecessor — the bug exposed
          // by Fix 1 in cpp20.epub TOC. Instead, clamp the block's
          // start to ctx.searchFrom: the previous block "owned" the
          // overlapping whitespace, but the new slice still has unique
          // content past it.
          //
          // Edge case (acknowledged limit): if an inline element's
          // text actually starts in the clamped-out region [slice.start,
          // ctx.searchFrom) and that text re-appears past blockStart,
          // _fuzzyIndexOf would find the LATER occurrence and emit a
          // mark at the wrong location. Real-world EPUBs (cpp20,
          // alicesAdventures, frankenstein) have only boundary
          // whitespace in the overlap region — no inline elements live
          // there — so this is not exercised in practice. Pathological
          // constructed input could trigger it; document and revisit if
          // a real EPUB surfaces the case.
          final blockStart = slice.start < ctx.searchFrom
              ? ctx.searchFrom
              : slice.start;
          final blockEnd = slice.end;
          if (blockEnd > blockStart) {
            // Trim leading/trailing whitespace from the block range. The
            // emitter's slice ranges include the surrounding "\n\n"
            // block-separator whitespace (cleaner-mapped from the
            // formatted source HTML). If those bounds reach the renderer
            // unmodified, every listItem renders as "\n\nPreface\n\n" —
            // producing huge vertical gaps in a list view because the
            // container widget ALSO provides item-spacing margin
            // (compounding effect). Trim so blocks describe SEMANTIC
            // content only; the renderer's container handles spacing.
            final (trimmedStart, trimmedEnd) = _trimRangeWhitespace(
              ctx.plainText,
              blockStart,
              blockEnd,
            );
            if (trimmedEnd > trimmedStart) {
              final marker = state.isFirstSlice
                  ? (isOrdered
                        ? _markerForOrderedList(parentList, counter)
                        : '•')
                  : '';
              // Slice-bounded fuzzy match for inline marks within this <li>.
              // Walks the whole <li> subtree but bounds matches to the
              // TRIMMED slice — marks can't escape into the previous
              // block's range OR into the trimmed-out boundary
              // whitespace; marks for siblings in other slices (split
              // off by block descendants like <p>BLOCK</p>) are
              // rejected by Fix 2's reject-not-clamp guard. The walker
              // skips nested <ul>/<ol> and block descendants so it only
              // attempts matches for true inline children of this <li>.
              final inlineMarks = _collectInlineMarksForSlice(
                state.li,
                TextRange(trimmedStart, trimmedEnd),
                ctx.plainText,
                state.sliceIndex,
              );
              ctx.recordBlock(
                ContentBlock(
                  type: ContentBlockType.listItem,
                  start: trimmedStart,
                  end: trimmedEnd,
                  listMarker: marker,
                  depth: state.depth,
                  marks: inlineMarks,
                ),
              );
              // Only flip isFirstSlice on a SUCCESSFUL emit. If the first
              // slice is degenerate (fully overlapping with the previous
              // block) and gets suppressed, we still want the next
              // emitted slice to receive the list marker.
              state.isFirstSlice = false;
            }
          }
          // Always advance the slice cursor — even on suppressed slice —
          // so subsequent text runs pop the next slice.
          state.sliceIndex++;
        }
        state.inDirectTextRun = true;
      }
    }
  }

  /// Collect inline marks for a single `<li>` slice. Walks [li]'s subtree
  /// in DOM order, but only emits marks for inline elements that belong to
  /// the [targetSliceIndex]-th slice — i.e. the inline elements that sit
  /// in the contiguous direct-text run between the (targetSliceIndex)-th
  /// and (targetSliceIndex+1)-th block-level descendant of [li].
  ///
  /// Walking the WHOLE `<li>` (rather than scoping to a per-slice DOM
  /// subtree) is intentional — block descendants don't form a clean DOM
  /// partition (a `<pre>` can sit anywhere in the subtree, including deep
  /// inside `<a>`/`<span>` wrappers). A shared mutable counter
  /// ([_SliceWalkCounter]) tracks the current slice index across the
  /// whole walk; matches only fire when `counter.current == targetSliceIndex`.
  /// Without this, codex round-5 found that a later-slice `<code>X</code>`
  /// element could match its text against PLAIN TEXT in the current slice
  /// (false-positive monospace mark on plain prose).
  ///
  /// Marks that overflow the slice's `end` are still rejected by
  /// [_matchInlineMark]'s reject-not-clamp guard — defense in depth even
  /// after the slice-membership filter.
  static List<InlineMark> _collectInlineMarksForSlice(
    dom.Element li,
    TextRange slice,
    String plainText,
    int targetSliceIndex,
  ) {
    final marks = <InlineMark>[];
    _walkSliceForMarks(
      li,
      plainText,
      _MarkCursor(slice.start, slice.end),
      marks,
      insideCodeBlock: false,
      isRoot: true,
      targetSliceIndex: targetSliceIndex,
      counter: _SliceWalkCounter(),
    );
    return marks;
  }

  /// Recursive walker for [_collectInlineMarksForSlice]. Mirrors
  /// [_collectInlineMarks]'s cursor semantics but additionally:
  /// - Skips nested `<ul>` / `<ol>` (each inner `<li>` emits its own
  ///   listItem block elsewhere).
  /// - Skips block descendants (except the root `<li>` itself) — they
  ///   emit their own blocks via [_dispatchNode].
  /// - Increments [counter.current] each time it crosses a block-level
  ///   descendant or nested list, to track which slice the next inline
  ///   element belongs to.
  /// - Only attempts a match when `counter.current == targetSliceIndex`.
  ///
  /// `cursor` is mutated for sibling-cursor advance. Nested matched
  /// elements get a FRESH inner cursor bounded to `(mark.start, mark.end)`,
  /// so `<strong><code>X</code></strong>` emits both parent and nested
  /// marks at correct offsets.
  static void _walkSliceForMarks(
    dom.Element e,
    String plainText,
    _MarkCursor cursor,
    List<InlineMark> marks, {
    required bool insideCodeBlock,
    required bool isRoot,
    required int targetSliceIndex,
    required _SliceWalkCounter counter,
  }) {
    final tag = e.localName?.toLowerCase();
    if (tag == null) return;
    // Stop at nested lists — inner <li>s emit separate listItem blocks.
    if (tag == 'ul' || tag == 'ol') return;
    // Stop at block descendants (except the root <li> itself).
    if (!isRoot && isBlockElement(e)) return;

    for (final node in e.nodes) {
      // Track text content so the slice counter advances correctly:
      // leading blocks/nested-lists BEFORE any text don't form a slice
      // in elementRanges, so they shouldn't advance the counter either.
      if (node is dom.Text) {
        if (_hasAsciiNonWs(node.text)) counter.hadContent = true;
        continue;
      }
      if (node is! dom.Element) continue;
      final ctag = node.localName?.toLowerCase();
      if (ctag == null) continue;

      // Block descendants and nested lists mark a slice boundary. Skip
      // them in iteration (they emit elsewhere). Advance the slice
      // counter ONLY if some content has been seen — leading blocks
      // before any text don't form a slice in elementRanges.
      if (ctag == 'ul' || ctag == 'ol') {
        if (counter.hadContent) {
          counter.current++;
          counter.hadContent = false;
        }
        continue;
      }
      if (isBlockElement(node)) {
        if (counter.hadContent) {
          counter.current++;
          counter.hadContent = false;
        }
        continue;
      }

      // Inline element. Don't preemptively mark content seen — an empty
      // <a> or an inline wrapper whose first content is a block doesn't
      // form a slice in elementRanges, so it shouldn't advance the
      // counter. Instead, [counter.hadContent] is set only when actual
      // non-whitespace TEXT is encountered during recursion (the
      // dom.Text branch above). This mirrors the emitter's slice-record
      // semantics (codex round-7 MEDIUM: presence of inline element is
      // not equivalent to content; only text writes form a slice).
      //
      // Only attempt a match if we're currently in the target slice;
      // otherwise still recurse so nested block descendants (e.g. inside
      // <a>/<span> wrappers) advance the counter.
      InlineMark? mark;
      bool nestedInsideCodeBlock = insideCodeBlock;

      if (counter.current == targetSliceIndex) {
        if (ctag == 'strong' || ctag == 'b') {
          mark = _matchInlineMark(
            node,
            plainText,
            cursor.searchFrom,
            cursor.searchEnd,
            InlineMarkType.emphasis,
            style: 'bold',
          );
        } else if (ctag == 'em' || ctag == 'i') {
          mark = _matchInlineMark(
            node,
            plainText,
            cursor.searchFrom,
            cursor.searchEnd,
            InlineMarkType.emphasis,
            style: 'italic',
          );
        } else if (ctag == 'a') {
          final href = node.attributes['href'];
          if (href != null && href.startsWith('http')) {
            mark = _matchInlineMark(
              node,
              plainText,
              cursor.searchFrom,
              cursor.searchEnd,
              InlineMarkType.link,
              url: href,
            );
          }
        } else if (_isInlineMonospaceTag(ctag)) {
          if (!insideCodeBlock) {
            mark = _matchInlineMark(
              node,
              plainText,
              cursor.searchFrom,
              cursor.searchEnd,
              InlineMarkType.monospace,
            );
          }
          nestedInsideCodeBlock = true;
        }
      } else {
        // Out of target slice: still suppress monospace inside code
        // wrappers (semantic correctness for the recursion's
        // insideCodeBlock flag).
        if (_isInlineMonospaceTag(ctag)) {
          nestedInsideCodeBlock = true;
        }
      }

      if (mark != null) {
        marks.add(mark);
        // Recurse with inner cursor bounded to parent mark's range.
        // Sibling cursor advances past parent after recursion returns.
        final inner = _MarkCursor(mark.start, mark.end);
        _walkSliceForMarks(
          node,
          plainText,
          inner,
          marks,
          insideCodeBlock: nestedInsideCodeBlock,
          isRoot: false,
          targetSliceIndex: targetSliceIndex,
          counter: counter,
        );
        cursor.searchFrom = mark.end;
      } else {
        // Always recurse — non-mark inline wrappers (<a> with relative
        // href, <span>) carry mark-eligible descendants we must visit,
        // AND any block descendants under inline wrappers must advance
        // the slice counter even when we're out of the target slice.
        _walkSliceForMarks(
          node,
          plainText,
          cursor,
          marks,
          insideCodeBlock: nestedInsideCodeBlock,
          isRoot: false,
          targetSliceIndex: targetSliceIndex,
          counter: counter,
        );
      }
    }
  }

  /// v1.2: claim a `<table>` container. Emits an italic-marked caption
  /// paragraph block AND a table block (with `tableRows` from `<tr>`/
  /// `<th>`/`<td>` descendants). Both blocks are emitted in **plain-text
  /// DOM order**: whichever range starts earlier emits first, so
  /// out-of-spec source like `<table><tbody>...</tbody><caption>...
  /// </caption></table>` (caption AFTER body, which package:html does
  /// NOT normalise) still produces both blocks without one stealing the
  /// other's offset via the searchFrom cursor.
  ///
  /// The emitter records `<table>`'s range over BODY content (excluding
  /// outermost-own-direct-child `<caption>`). When caption sits between
  /// row groups, the union of body slices may swallow the caption's
  /// offset; in that case the caption block is suppressed (overlap
  /// guard) — acceptable v1.2 trade-off for malformed input that
  /// preserves all row data in the table widget.
  ///
  /// Acknowledged limits (plan §5.10):
  /// - No rowspan/colspan handling. Cells taken as-is; renderer pads
  ///   short rows.
  /// - Inline `<code>` inside cells gets no monospace mark (the table
  ///   handler doesn't recurse into cell children for inline-mark
  ///   collection — would conflict with the row-level extraction).
  /// - Nested `<table>`s flattened (inner table cells emit text, outer
  ///   table block range covers them).
  /// - `<caption>` containing block-level content (e.g. `<p>` inside)
  ///   records no caption range (findCaptionAncestor shadows on blocks).
  ///   The table still emits; caption text becomes orphan plain text.
  /// - `<pre>` inside a table cell is **not separately dispatched** as a
  ///   code block (the table claims dispatch and the walker doesn't
  ///   recurse through `<td>` since `<td>` isn't a block container).
  ///   Pre text appears flattened into the cell text. The table block's
  ///   recorded range is whichever non-straddling body slice the emitter
  ///   captured first; if no body slice is non-straddling (e.g. a single
  ///   slice covers text-pre-text in one cell), no table block emits at
  ///   all. Cell text remains in plainText regardless.
  static bool _emitTableBlockIfApplicable(dom.Element node, _WalkContext ctx) {
    if (ctx.elementRanges == null) return false;
    if (node.localName?.toLowerCase() != 'table') return false;

    // Codex round-1 v1.2 MEDIUM: nested tables are flattened into the
    // outer table's cell text. Skip dispatch for nested `<table>`s so
    // they don't emit separate table blocks (which would visually
    // duplicate the inner-cell content already shown inside the outer
    // cell). Returning false here lets the walker fall through to
    // _isBlockContainer recursion, which doesn't emit either since
    // <td>/<th> aren't paragraph-like.
    if (_hasTableAncestor(node)) return false;

    // Find the first `<caption>` child (if any). HTML5 specifies caption
    // must be the first child of table; we don't enforce position.
    dom.Element? caption;
    for (final c in node.children) {
      if (c.localName?.toLowerCase() == 'caption') {
        caption = c;
        break;
      }
    }

    // Resolve caption and table ranges up front, then emit in plain-text
    // order (smaller start first). HTML5 says caption must be the first
    // child of `<table>` so the natural order is caption-then-table — but
    // package:html doesn't normalise position, so malformed input like
    // `<table><tbody>...</tbody><caption>cap</caption></table>` parses
    // with caption AFTER the body content. Without the order check, the
    // searchFrom cursor would advance past the (later) caption and the
    // (earlier) table block would be claim+skipped (senior round-final
    // LOW-1).
    TextRange? captionRange;
    if (caption != null) {
      final capRanges = ctx.elementRanges![caption];
      if (capRanges != null && capRanges.isNotEmpty) {
        final r = capRanges.first;
        if (r.end > r.start) captionRange = r;
      }
    }

    // Build tableRows by walking thead/tbody/tfoot containers and
    // collecting <tr> children's <th>/<td> cells.
    final rows = _collectTableRows(node);
    final tableRanges = ctx.elementRanges![node];
    final tableRange =
        (rows.isNotEmpty &&
            tableRanges != null &&
            tableRanges.isNotEmpty &&
            tableRanges.first.end > tableRanges.first.start)
        ? tableRanges.first
        : null;

    void emitCaption() {
      final r = captionRange;
      if (r == null) return;
      if (r.start < ctx.searchFrom) return;
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
    }

    void emitTable() {
      final r = tableRange;
      if (r == null) return;
      if (r.start < ctx.searchFrom) return;
      ctx.recordBlock(
        ContentBlock(
          type: ContentBlockType.table,
          start: r.start,
          end: r.end,
          tableRows: rows,
        ),
      );
    }

    // Emit in plain-text DOM order: whichever range starts first.
    if (captionRange != null &&
        tableRange != null &&
        tableRange.start < captionRange.start) {
      emitTable();
      emitCaption();
    } else {
      emitCaption();
      emitTable();
    }
    return true;
  }

  /// Walk a `<table>` subtree and collect its rows. Handles direct `<tr>`
  /// children (HTML5 parser inserts implicit `<tbody>`, but be defensive)
  /// as well as `<thead>`/`<tbody>`/`<tfoot>` row-group containers.
  /// Cells are collected as plain text with whitespace collapsed.
  static List<List<String>> _collectTableRows(dom.Element table) {
    final rows = <List<String>>[];
    void walkRowContainer(dom.Element node) {
      for (final c in node.children) {
        final tag = c.localName?.toLowerCase();
        if (tag == 'tr') {
          final cells = <String>[];
          for (final cell in c.children) {
            final ctag = cell.localName?.toLowerCase();
            if (ctag == 'th' || ctag == 'td') {
              cells.add(_collapseCellWhitespace(cell.text));
            }
          }
          rows.add(cells);
        } else if (tag == 'thead' || tag == 'tbody' || tag == 'tfoot') {
          walkRowContainer(c);
        }
      }
    }

    walkRowContainer(table);
    return rows;
  }

  static String _collapseCellWhitespace(String s) {
    return s.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  /// True iff [node] has a `<table>` ancestor (i.e. it's a nested table).
  static bool _hasTableAncestor(dom.Element node) {
    var cur = node.parent;
    while (cur is dom.Element) {
      if (cur.localName?.toLowerCase() == 'table') return true;
      cur = cur.parent;
    }
    return false;
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

  /// Trim leading and trailing ASCII whitespace from `[start, end)` over
  /// [plainText]. Returns the inner non-whitespace range. Used to strip
  /// the surrounding "\n\n" block-separator whitespace from listItem
  /// block bounds — the emitter's slices include them, but the renderer
  /// doesn't want them (its container provides item spacing already).
  /// If the entire range is whitespace, returns `(end, end)` (caller
  /// should check for empty trimmed range).
  static (int, int) _trimRangeWhitespace(String plainText, int start, int end) {
    var s = start;
    var e = end;
    while (s < e) {
      final c = plainText.codeUnitAt(s);
      if (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) break;
      s++;
    }
    while (e > s) {
      final c = plainText.codeUnitAt(e - 1);
      if (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) break;
      e--;
    }
    return (s, e);
  }

  /// Trim blank-line separators around a matched block without stripping
  /// leading indentation on the content line itself. This is intentionally
  /// narrower than [_trimRangeWhitespace]: a paragraph match may begin at the
  /// block separator before an indented Google Docs code-like line, and that
  /// indentation is semantic content.
  static (int, int) _trimRangeBlockSeparators(
    String plainText,
    int start,
    int end,
  ) {
    var s = start;
    var e = end;

    while (s < e) {
      var cursor = s;
      while (cursor < e && _isHorizontalAsciiWhitespace(plainText, cursor)) {
        cursor++;
      }
      if (cursor < e && _isAsciiNewline(plainText, cursor)) {
        s = cursor + 1;
        continue;
      }
      break;
    }

    while (e > s) {
      var cursor = e;
      while (cursor > s &&
          _isHorizontalAsciiWhitespace(plainText, cursor - 1)) {
        cursor--;
      }
      if (cursor > s && _isAsciiNewline(plainText, cursor - 1)) {
        e = cursor - 1;
        continue;
      }
      break;
    }

    while (e > s && _isHorizontalAsciiWhitespace(plainText, e - 1)) {
      e--;
    }
    return (s, e);
  }

  static bool _isHorizontalAsciiWhitespace(String text, int index) {
    final c = text.codeUnitAt(index);
    return c == 0x20 || c == 0x09;
  }

  static bool _isAsciiNewline(String text, int index) {
    final c = text.codeUnitAt(index);
    return c == 0x0A || c == 0x0D;
  }

  static int _expandToLineIndentation(String plainText, int idx, int minStart) {
    var expanded = idx;
    while (expanded > minStart &&
        _isHorizontalAsciiWhitespace(plainText, expanded - 1)) {
      expanded--;
    }
    if (expanded == idx) return idx;
    if (expanded == 0 || _isAsciiNewline(plainText, expanded - 1)) {
      return expanded;
    }
    return idx;
  }

  /// Count `<li>` ancestors of [li] in its DOM tree. The emitting `<li>` is
  /// not counted, so a top-level `<li>` returns 0, the first nested `<li>`
  /// returns 1, etc.
  ///
  /// This is the depth value carried on `ContentBlock.depth` for the
  /// renderer's visual indent. Computing depth from DOM ancestry at the
  /// emission site (rather than threading a parameter through every
  /// dispatcher) is robust to nested lists wrapped in non-list block
  /// containers (e.g. `<li><div><ul><li>Inner</li></ul></div></li>`),
  /// which reach `_handleLi` via `_dispatchNode` →
  /// `_recurseIntoBlockContainer` → `_walkBlocks`.
  static int _liDepth(dom.Element li) {
    var n = 0;
    for (var p = li.parent; p != null; p = p.parent) {
      if (p.localName?.toLowerCase() == 'li') n++;
    }
    return n;
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
          final ddRange = (ranges == null || ranges.isEmpty)
              ? null
              : ranges.first;
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

    final searchKey = normalized.length > 60
        ? normalized.substring(0, 60)
        : normalized;
    var idx = _fuzzyIndexOf(plainText, searchKey, searchFrom);
    if (idx < 0) return null;
    idx = _expandToLineIndentation(plainText, idx, searchFrom);

    final (matchLength, completeMatch) = _findMatchLengthWithCompleteness(
      plainText,
      idx,
      normalized,
    );
    if (matchLength <= 0) return null;

    var endIdx = idx + matchLength;
    if (!completeMatch && normalized.length > 60) {
      final endNormalized = normalized.substring(normalized.length - 30);
      final suffixSearchFrom = (endIdx - endNormalized.length * 3).clamp(
        idx + 1,
        plainText.length,
      );
      final endSearch = _fuzzyIndexOf(
        plainText,
        endNormalized,
        suffixSearchFrom,
      );
      if (endSearch >= 0) {
        final (suffixLength, _) = _findMatchLengthWithCompleteness(
          plainText,
          endSearch,
          endNormalized,
        );
        if (suffixLength > 0) endIdx = endSearch + suffixLength;
      }
    }

    endIdx = endIdx.clamp(idx + 1, plainText.length);
    final (trimmedStart, trimmedEnd) = _trimRangeBlockSeparators(
      plainText,
      idx,
      endIdx,
    );
    if (trimmedEnd <= trimmedStart) return null;

    final marks = <InlineMark>[];
    _collectInlineMarks(
      element,
      plainText,
      _MarkCursor(trimmedStart, trimmedEnd),
      marks,
      insideCodeBlock: insideCodeBlock,
    );

    return ContentBlock(
      type: type,
      start: trimmedStart,
      end: trimmedEnd,
      level: level,
      marks: marks,
    );
  }

  /// Collect inline marks (emphasis, links, monospace) from element children.
  ///
  /// [cursor] threads `searchFrom` (mutable; advances per emitted sibling
  /// mark) and `searchEnd` (immutable hard bound — block range or parent
  /// mark's range). [insideCodeBlock] is the ancestor flag — when true,
  /// inline `<code>` / `<kbd>` etc. do NOT emit monospace marks (already
  /// covered by the block-level monospace).
  ///
  /// Marks that would overflow `searchEnd` are REJECTED (return null), not
  /// clamped — a 1-char monospace for a 30-char `<code>` would mis-render.
  /// The cursor stays put on reject; subsequent siblings re-search from the
  /// same start position.
  static void _collectInlineMarks(
    dom.Element element,
    String plainText,
    _MarkCursor cursor,
    List<InlineMark> marks, {
    required bool insideCodeBlock,
  }) {
    for (final node in element.nodes) {
      if (node is! dom.Element) continue;

      final tag = node.localName?.toLowerCase();
      if (tag == null) continue;

      InlineMark? mark;
      bool nestedInsideCodeBlock = insideCodeBlock;

      if (tag == 'strong' || tag == 'b') {
        mark = _matchInlineMark(
          node,
          plainText,
          cursor.searchFrom,
          cursor.searchEnd,
          InlineMarkType.emphasis,
          style: 'bold',
        );
      } else if (tag == 'em' || tag == 'i') {
        mark = _matchInlineMark(
          node,
          plainText,
          cursor.searchFrom,
          cursor.searchEnd,
          InlineMarkType.emphasis,
          style: 'italic',
        );
      } else if (tag == 'a') {
        final href = node.attributes['href'];
        if (href != null && href.startsWith('http')) {
          mark = _matchInlineMark(
            node,
            plainText,
            cursor.searchFrom,
            cursor.searchEnd,
            InlineMarkType.link,
            url: href,
          );
        }
      } else if (_isInlineMonospaceTag(tag)) {
        if (!insideCodeBlock) {
          mark = _matchInlineMark(
            node,
            plainText,
            cursor.searchFrom,
            cursor.searchEnd,
            InlineMarkType.monospace,
          );
        }
        // Suppress nested monospace either way — even if the outer
        // <code> didn't emit a mark (out of bounds, etc.), nested
        // <code>s shouldn't double-emit.
        nestedInsideCodeBlock = true;
      }

      if (mark != null) {
        marks.add(mark);
        // Children of a matched element search inside its range.
        // Degenerate truly-nested same-text (`<strong>foo<strong>foo
        // </strong></strong>`) emits inner mark at outer mark.start —
        // accepted limit of fuzzy-match path; pathological in practice.
        final inner = _MarkCursor(mark.start, mark.end);
        _collectInlineMarks(
          node,
          plainText,
          inner,
          marks,
          insideCodeBlock: nestedInsideCodeBlock,
        );
        cursor.searchFrom = mark.end;
      } else {
        // Unmatched / non-mark wrapper: recurse with parent cursor
        // unchanged so descendants can still emit. Cursor stays put on
        // reject — if a sibling has the same text, it re-searches from
        // the same start; if duplicates exist in the bound, they emit
        // at their actual occurrence (cursor advances as marks accumulate).
        _collectInlineMarks(
          node,
          plainText,
          cursor,
          marks,
          insideCodeBlock: nestedInsideCodeBlock,
        );
      }
    }
  }

  static bool _isInlineMonospaceTag(String tag) {
    const tags = {'code', 'kbd', 'samp', 'var', 'tt'};
    return tags.contains(tag);
  }

  /// Match an inline element's text to a range in the plain text.
  ///
  /// Returns null when:
  /// - element text is empty after trim/normalize, or
  /// - `searchFrom >= searchEnd` (cursor exhausted), or
  /// - no fuzzy match found within `[searchFrom, searchEnd)`, or
  /// - `_findMatchLength` extends past `searchEnd` (overflow rejection —
  ///   "no mark > wrong-length mark"), or
  /// - the matched length is zero.
  static InlineMark? _matchInlineMark(
    dom.Element element,
    String plainText,
    int searchFrom,
    int searchEnd,
    InlineMarkType type, {
    String? style,
    String? url,
  }) {
    final text = element.text.trim();
    if (text.isEmpty) return null;

    final normalized = _normalizeForMatch(text);
    if (normalized.isEmpty) return null;
    if (searchFrom >= searchEnd) return null;

    final idx = _fuzzyIndexOf(plainText, normalized, searchFrom);
    if (idx < 0 || idx >= searchEnd) return null;

    final matchLen = _findMatchLength(plainText, idx, normalized);
    final endIdx = idx + matchLen;

    // REJECT (don't clamp) marks that overflow the bound. A truncated mark
    // would mis-render. Acceptable trade-off: "no mark" > "wrong-length mark".
    if (endIdx > searchEnd) return null;
    if (endIdx <= idx) return null;

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
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Find text in plainText with whitespace-flexible matching.
  static int _fuzzyIndexOf(String plainText, String needle, int from) {
    if (from >= plainText.length || needle.isEmpty) return -1;

    final exactIdx = plainText.indexOf(needle, from);
    if (exactIdx >= 0) return exactIdx;

    final normalizedPlain = _normalizeForMatch(
      plainText.substring(
        from,
        (from + needle.length * 3).clamp(0, plainText.length),
      ),
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
  static int _mapNormalizedOffset(
    String original,
    int baseOffset,
    int normalizedOffset,
  ) {
    var origIdx = baseOffset;
    var normIdx = 0;
    while (origIdx < original.length && normIdx < normalizedOffset) {
      if (RegExp(r'\s').hasMatch(original[origIdx])) {
        origIdx++;
        while (origIdx < original.length &&
            RegExp(r'\s').hasMatch(original[origIdx])) {
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
  static int _findMatchLength(
    String plainText,
    int startIdx,
    String normalized,
  ) {
    return _findMatchLengthWithCompleteness(plainText, startIdx, normalized).$1;
  }

  /// Find how many source characters match [normalized] and whether the
  /// normalized text was consumed fully. The length is measured in
  /// [plainText] characters from [startIdx], including any leading whitespace
  /// skipped before the first semantic character.
  static (int, bool) _findMatchLengthWithCompleteness(
    String plainText,
    int startIdx,
    String normalized,
  ) {
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
    return (origIdx - startIdx, normIdx >= normalized.length);
  }

  static bool _isParagraphLike(String tag) {
    const tags = {'p', 'li', 'dt', 'dd', 'blockquote', 'pre', 'figcaption'};
    return tags.contains(tag);
  }

  static bool _isBlockContainer(String tag) {
    const tags = {
      'div',
      'section',
      'article',
      'main',
      'aside',
      'header',
      'footer',
      'nav',
      'figure',
      'details',
      'summary',
      'form',
      'fieldset',
      'ul',
      'ol',
      'dl',
      'table',
      'tbody',
      'thead',
      'tfoot',
      'tr',
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
///
/// `li` is captured so the slice-emit site can pass it to the inline-mark
/// helper without re-threading it through every recursive call.
///
/// `depth` is the count of `<li>` ancestors of [li] in the source DOM,
/// computed once at `_handleLi` entry. It feeds `ContentBlock.depth` so
/// the renderer can visually indent nested list items. The DOM-ancestor
/// approach (vs. threading a parameter through every dispatcher) is robust
/// to nested lists wrapped in non-list block containers (e.g.
/// `<li><div><ul>...</ul></div></li>`), which reach `_handleLi` via
/// `_dispatchNode` → `_recurseIntoBlockContainer` → `_walkBlocks`.
class _LiWalkState {
  final dom.Element li;
  final int depth;
  final List<TextRange> ranges;
  int sliceIndex;
  bool isFirstSlice;
  bool inDirectTextRun;

  _LiWalkState({required this.li, required this.depth, required this.ranges})
    : sliceIndex = 0,
      isFirstSlice = true,
      inDirectTextRun = false;
}

/// Mutable cursor threaded through [EpubStructuredContentBuilder._collectInlineMarks]
/// and [EpubStructuredContentBuilder._walkSliceForMarks]. `searchFrom`
/// advances per emitted sibling mark; `searchEnd` is an immutable hard bound
/// (the enclosing block or parent mark's range). Marks whose match would
/// overflow `searchEnd` are rejected, not clamped.
class _MarkCursor {
  int searchFrom;
  final int searchEnd;
  _MarkCursor(this.searchFrom, this.searchEnd);
}

/// Mutable counter shared across an [EpubStructuredContentBuilder._walkSliceForMarks]
/// invocation. Tracks which slice index of the enclosing `<li>` the walker
/// is currently in.
///
/// Slice indexing must mirror the emitter's `elementRanges[li]`: a slice
/// is only RECORDED when its direct-text run has non-whitespace content
/// (whitespace-only slices are dropped). So [current] must only advance
/// when a block-level descendant or nested `<ul>`/`<ol>` is crossed AFTER
/// non-whitespace TEXT has been seen in the current slice. Leading
/// blocks before any text don't form a slice; an empty `<a>` or an inline
/// wrapper whose first content is a block also doesn't form a slice
/// (codex rounds 6+7).
///
/// [hadContent] is set ONLY by encountering a `dom.Text` node with
/// non-whitespace content (mirrors the emitter's `writeText` →
/// `sliceHasNonWs` flag). Inline element presence alone does NOT
/// imply content — the recursion's text descendants do.
class _SliceWalkCounter {
  int current = 0;
  bool hadContent = false;
}
