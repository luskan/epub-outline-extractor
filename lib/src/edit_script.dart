/// A single offset-translation operation produced by a cleaner pass over
/// `[inputStart, inputEnd)` of the original text → `[outputStart, outputEnd)`
/// of the post-clean text.
///
/// Three kinds:
/// - [Keep]: identity copy. `outputEnd = outputStart + (inputEnd - inputStart)`.
/// - [Replace]: many-to-many substitution with explicit replacement text.
///   `outputEnd = outputStart + replacement.length`.
/// - [Delete]: many-to-zero. `outputEnd = outputStart`.
sealed class Edit {
  final int inputStart;
  final int inputEnd;
  final int outputStart;

  const Edit({
    required this.inputStart,
    required this.inputEnd,
    required this.outputStart,
  });

  int get outputEnd;
  int get inputLength => inputEnd - inputStart;
  int get outputLength => outputEnd - outputStart;
}

class Keep extends Edit {
  const Keep({
    required super.inputStart,
    required super.inputEnd,
    required super.outputStart,
  });

  @override
  int get outputEnd => outputStart + (inputEnd - inputStart);

  @override
  String toString() =>
      'Keep([$inputStart, $inputEnd) → [$outputStart, $outputEnd))';
}

class Replace extends Edit {
  final String replacement;

  const Replace({
    required super.inputStart,
    required super.inputEnd,
    required super.outputStart,
    required this.replacement,
  });

  @override
  int get outputEnd => outputStart + replacement.length;

  @override
  String toString() => 'Replace([$inputStart, $inputEnd) → '
      '[$outputStart, $outputEnd) "$replacement")';
}

class Delete extends Edit {
  const Delete({
    required super.inputStart,
    required super.inputEnd,
    required super.outputStart,
  });

  @override
  int get outputEnd => outputStart;

  @override
  String toString() =>
      'Delete([$inputStart, $inputEnd) → [$outputStart, $outputStart))';
}

/// Sorted, contiguous list of [Edit]s covering `[0, originalLength)`.
/// Provides offset translation from original text to cleaned text.
///
/// Mapping rules (plan §5.4):
/// - [mapStart]: where does `oldOffset` move, treated as inclusive start of
///   a range. Left-anchors at collapse boundaries (Replace).
/// - [mapEnd]: where does `oldOffset` move, treated as exclusive end of a
///   range. Right-anchors at collapse boundaries.
class EditScript {
  final List<Edit> edits;
  final int originalLength;
  final int outputLength;

  EditScript({
    required this.edits,
    required this.originalLength,
    required this.outputLength,
  });

  /// Identity script: every character preserved.
  factory EditScript.identity(int length) {
    return EditScript(
      edits: length == 0
          ? const []
          : [Keep(inputStart: 0, inputEnd: length, outputStart: 0)],
      originalLength: length,
      outputLength: length,
    );
  }

  /// Map an inclusive **start** offset from original to output coordinates.
  ///
  /// Left-anchors at Replace boundaries (returns the start of the
  /// replacement). For Delete edits, scans forward to the next surviving
  /// character.
  int mapStart(int oldOffset) {
    if (oldOffset < 0 || oldOffset > originalLength) {
      throw RangeError(
        'oldOffset $oldOffset out of bounds [0, $originalLength]',
      );
    }
    if (oldOffset == originalLength) {
      return outputLength;
    }
    // Find the edit containing oldOffset.
    final i = _findEditIndex(oldOffset);
    final e = edits[i];
    return switch (e) {
      Keep() => e.outputStart + (oldOffset - e.inputStart),
      Replace() => e.outputStart, // left-anchor
      Delete() => _findNextSurvivingOutputStart(i),
    };
  }

  /// Map an exclusive **end** offset from original to output coordinates.
  ///
  /// Right-anchors at Replace boundaries (returns the end of the
  /// replacement). For Delete edits, scans backward to the previous
  /// surviving character's end.
  int mapEnd(int oldOffset) {
    if (oldOffset < 0 || oldOffset > originalLength) {
      throw RangeError(
        'oldOffset $oldOffset out of bounds [0, $originalLength]',
      );
    }
    if (oldOffset == 0) return 0;
    if (oldOffset == originalLength) return outputLength;
    // Find the edit containing (oldOffset - 1) — the last included char.
    final i = _findEditIndex(oldOffset - 1);
    final e = edits[i];
    return switch (e) {
      Keep() => e.outputStart + (oldOffset - e.inputStart),
      Replace() => e.outputStart + e.replacement.length, // right-anchor
      Delete() => _findPrevSurvivingOutputEnd(i),
    };
  }

  /// Returns the index in [edits] of the edit that contains [inputOffset]
  /// (i.e. `e.inputStart ≤ inputOffset < e.inputEnd`).
  int _findEditIndex(int inputOffset) {
    // Edits are sorted by inputStart and contiguous; binary search.
    var lo = 0;
    var hi = edits.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final e = edits[mid];
      if (inputOffset < e.inputStart) {
        hi = mid - 1;
      } else if (inputOffset >= e.inputEnd) {
        lo = mid + 1;
      } else {
        return mid;
      }
    }
    throw StateError(
      'EditScript not contiguous: no edit contains inputOffset=$inputOffset',
    );
  }

  /// Scan forward from edit [startIndex] for the next non-Delete edit's
  /// outputStart. Falls through to [outputLength] if all subsequent edits
  /// are Deletes (the trailing-deletes case).
  int _findNextSurvivingOutputStart(int startIndex) {
    for (var i = startIndex + 1; i < edits.length; i++) {
      if (edits[i] is! Delete) return edits[i].outputStart;
    }
    return outputLength;
  }

  /// Scan backward from edit [startIndex] for the previous non-Delete
  /// edit's outputEnd. Falls through to 0 if no prior surviving edit.
  int _findPrevSurvivingOutputEnd(int startIndex) {
    for (var i = startIndex - 1; i >= 0; i--) {
      if (edits[i] is! Delete) return edits[i].outputEnd;
    }
    return 0;
  }
}
