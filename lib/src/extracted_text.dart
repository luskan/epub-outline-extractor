import 'package:html/dom.dart' as dom;

/// Half-open range `[start, end)` over a string, in code-unit offsets.
///
/// Equality is value-based on `(start, end)`. Used by [ExtractedText] for
/// both preserved-content ranges and per-element offset attribution.
class TextRange {
  final int start;
  final int end;
  const TextRange(this.start, this.end);

  int get length => end - start;
  bool get isEmpty => start == end;

  bool contains(int offset) => offset >= start && offset < end;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TextRange && other.start == start && other.end == end);

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TextRange[$start, $end)';
}

/// Plain text + preserved-content ranges + per-element offset attribution +
/// the parsed DOM, threaded through the extractor → cleaner → builder pipeline.
///
/// **Ownership / lifetime contract** (plan §5.2 inv 5): an [ExtractedText] is
/// consumed within a single chapter pipeline pass. The [document] reference
/// MUST be the same instance the emitter walked — cloning or re-parsing
/// breaks [elementRanges] keys (which are identity-based on `dom.Element`).
class ExtractedText {
  /// Plain text. Annotations and hashes index into this string.
  final String text;

  /// Sorted, non-overlapping, non-empty `[start, end)` ranges into [text]
  /// whose contents must NOT be modified by the cleaner.
  final List<TextRange> preservedRanges;

  /// Identity-keyed map from a parsed `dom.Element` to the list of ranges it
  /// emitted into [text]. Most elements have a single range; `<li>` may have
  /// multiple ranges (one per direct-text slice — plan §5.8). Populated for
  /// elements where exact offset attribution beats fuzzy matching: `<pre>`,
  /// `<table>`, `<li>`, `<dt>`, `<dd>`, `<figcaption>`, `<caption>`.
  final Map<dom.Element, List<TextRange>> elementRanges;

  /// The parsed DOM the emitter walked. Threaded forward so element identity
  /// stays valid across the pipeline. Use [Map.identity] semantics implicitly
  /// — `dom.Element` doesn't override `==`, so identity is structural here.
  final dom.Document document;

  ExtractedText({
    required this.text,
    required this.preservedRanges,
    required this.elementRanges,
    required this.document,
  }) {
    _validate();
  }

  /// Validates the §5.2 invariants. Throws [ArgumentError] on violation.
  /// Cheap per-chapter validation — runs once at construction.
  void _validate() {
    final n = text.length;

    // Inv 2 (preserved): sorted, non-overlapping, non-zero-length, in bounds.
    int prevEnd = -1;
    for (final r in preservedRanges) {
      if (r.start < 0 || r.end > n) {
        throw ArgumentError(
          'preservedRange $r escapes text bounds [0, $n]',
        );
      }
      if (r.start >= r.end) {
        throw ArgumentError('preservedRange $r is empty (zero-length)');
      }
      if (r.start < prevEnd) {
        throw ArgumentError(
          'preservedRanges not sorted/disjoint near $r '
          '(previous range ended at $prevEnd)',
        );
      }
      prevEnd = r.end;
    }

    // Inv 3 + 4: every elementRange is in bounds AND does not straddle
    // any preserved-range boundary (must be entirely inside one or
    // entirely outside all).
    for (final entry in elementRanges.entries) {
      for (final r in entry.value) {
        if (r.start < 0 || r.end > n || r.start > r.end) {
          throw ArgumentError(
            'elementRange $r out of bounds [0, $n]',
          );
        }
        if (_straddlesPreservedBoundary(r)) {
          throw ArgumentError(
            'elementRange $r straddles a preservedRange boundary',
          );
        }
      }
    }
  }

  /// True iff `[r.start, r.end)` overlaps a preserved range without being
  /// fully contained within it. Empty `r` is treated as non-straddling.
  bool _straddlesPreservedBoundary(TextRange r) {
    if (r.isEmpty) return false;
    for (final p in preservedRanges) {
      if (p.end <= r.start) continue; // p ends before r — keep scanning
      if (p.start >= r.end) return false; // past r entirely
      // p overlaps r in some way. Allowed iff r ⊆ p.
      final fullyInside = r.start >= p.start && r.end <= p.end;
      if (!fullyInside) return true;
      return false;
    }
    return false;
  }

  /// Equality is **scoped to `text + preservedRanges`** (plan §5.2 inv 6).
  ///
  /// `elementRanges` and `document` are deliberately excluded — their
  /// identity differs by parse instance even for byte-equal HTML, which
  /// would defeat the §7.2 parity test that compares two `ExtractedText`
  /// values produced by the cleaner.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ExtractedText) return false;
    if (other.text != text) return false;
    if (other.preservedRanges.length != preservedRanges.length) return false;
    for (var i = 0; i < preservedRanges.length; i++) {
      if (other.preservedRanges[i] != preservedRanges[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(text, Object.hashAll(preservedRanges));
}

/// Convenience accessors for the common element-range shapes.
extension ElementRangeAccess on Map<dom.Element, List<TextRange>> {
  /// Returns the single range associated with [e]. Asserts that [e] has
  /// exactly one entry. Use [rangesOf] for `<li>` and other multi-range
  /// elements.
  TextRange singleRangeOf(dom.Element e) {
    final list = this[e];
    assert(
      list != null && list.length == 1,
      'Expected exactly one range for ${e.localName}, got ${list?.length}',
    );
    return list![0];
  }

  /// Returns all ranges associated with [e], or an empty list if [e] is not
  /// recorded.
  List<TextRange> rangesOf(dom.Element e) => this[e] ?? const [];
}

/// A single section's extraction result: plain text + preserved/element
/// ranges + the DOM bounds within the chapter document the section spans.
///
/// `sectionStartElement` is the DOM element where the section begins
/// (matches the fragment-id element in the chapter). `sectionEndElement` is
/// the next fragment's element — exclusive bound. Either may be null:
/// - `sectionStartElement == null`: section starts at the chapter root.
/// - `sectionEndElement == null`: section runs to end-of-document.
class SectionExtraction {
  final ExtractedText extracted;
  final dom.Element? sectionStartElement;
  final dom.Element? sectionEndElement;

  const SectionExtraction({
    required this.extracted,
    required this.sectionStartElement,
    required this.sectionEndElement,
  });
}
