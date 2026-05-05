/// Text cleaning utilities for PDF and EPUB content.
///
/// This is a port of the Python text cleaning functions from
/// `ocr/pdf_text_to_json.py`. v1.0 adds a range-aware variant that returns
/// an [EditScript] mapping original-text offsets to cleaned-text offsets,
/// supporting preserved-content ranges (e.g. `<pre>` blocks in EPUB).
library;

import 'package:html/dom.dart' as dom;

import 'edit_script.dart';
import 'extracted_text.dart';

class TextCleaner {
  /// Legacy entry point — byte-equal to the pre-v1.0 implementation.
  ///
  /// Internally just runs [cleanTextWithScript] and returns the cleaned
  /// text, discarding the script. Kept for callers that don't need offset
  /// translation.
  static String cleanText(String text, {bool fixLineBreaks = true}) {
    return cleanTextWithScript(text, fixLineBreaks: fixLineBreaks).text;
  }

  /// Run the legacy multi-pass cleaner over [text], returning both the
  /// cleaned text and an [EditScript] mapping original offsets → cleaned
  /// offsets.
  ///
  /// Used by [cleanExtractedTextRespectingRanges] for the outside-of-
  /// preserved-range segments. Equivalent to [cleanText] in output text.
  static CleanResult cleanTextWithScript(
    String text, {
    bool fixLineBreaks = true,
    bool trimEdges = true,
  }) {
    if (text.isEmpty) {
      return CleanResult(text: text, script: EditScript.identity(0));
    }

    var current = text;

    // Pass 1: PUA mapping (multi-char → single char).
    _puaMapping.forEach((puaChars, replacement) {
      current = current.replaceAll(puaChars, replacement);
    });

    // Pass 2: PUA stripping (any remaining U+E000-U+F8FF).
    current = current.replaceAll(RegExp(r"[\uE000-\uF8FF]"), "");

    // Pass 3: Control char stripping.
    current = current.replaceAll(
      RegExp(r"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"),
      "",
    );

    // Pass 4: fixPdfLineBreaks (length-changing word-merge rewrites).
    if (fixLineBreaks) {
      current = fixPdfLineBreaks(current);
    }

    // Pass 5: collapse [ \t]+ -> single space.
    current = current.replaceAll(RegExp(r"[ \t]+"), " ");

    // Pass 6: per-line trim.
    current = current.split("\n").map((line) => line.trim()).join("\n");

    // Pass 7: collapse 3+ newlines into 2.
    current = current.replaceAll(RegExp(r"\n{3,}"), "\n\n");

    // Pass 8: final trim of full output.
    if (trimEdges) {
      current = current.trim();
    }

    // Derive a coarse 3-edit EditScript via prefix/suffix diff. Sufficient
    // for offset translation in our use case -- preserved ranges survive
    // verbatim via the split-at-boundaries strategy in
    // cleanTextRespectingRanges, which sidesteps multi-pass composition.
    final script = _diffEditScript(text, current);
    return CleanResult(text: current, script: script);
  }

  /// Range-aware cleaner: split [input] at preserved-range boundaries, run
  /// the legacy cleaner over outside segments, leave preserved segments
  /// verbatim (with tab→4-space normalisation), reassemble, remap all
  /// ranges through the resulting [EditScript].
  ///
  /// Plan §5.3 / §5.4. Used by the EPUB extraction pipeline.
  static RangeAwareResult cleanTextRespectingRanges(ExtractedText input) {
    if (input.preservedRanges.isEmpty) {
      // Hot path: no preserved ranges — equivalent to legacy cleaner with
      // an identity remap of any element ranges (cleaned through script).
      final result = cleanTextWithScript(input.text);
      return RangeAwareResult(
        cleanedText: result.text,
        script: result.script,
      );
    }

    // Split into segments alternating outside/preserved, cleaner per-segment.
    final originalLength = input.text.length;
    final composedEdits = <Edit>[];
    final outputBuffer = StringBuffer();
    var cursor = 0;
    var outputCursor = 0;

    void appendSegmentEdits(EditScript segScript, int segInputStart) {
      // Shift the segment-local script's offsets by segInputStart and
      // outputCursor.
      for (final e in segScript.edits) {
        composedEdits.add(_shiftEdit(e, segInputStart, outputCursor));
      }
    }

    final preservedRanges = input.preservedRanges;
    for (var i = 0; i < preservedRanges.length; i++) {
      final preserved = preservedRanges[i];
      final outsideStart = cursor;
      final outsideEnd = preserved.start;

      // (a) Clean the outside segment, if any.
      if (outsideEnd > outsideStart) {
        final segText = input.text.substring(outsideStart, outsideEnd);
        final isFirstSegment = i == 0 && outsideStart == 0;
        final isLastSegmentBeforeFinalEdge =
            false; // boundary — never trim at preserved-range boundaries
        final segResult = cleanTextWithScript(
          segText,
          // Internal segments adjacent to preserved ranges must NOT have
          // their edges trimmed (plan §5.4: separator newlines around
          // <pre> survive).
          trimEdges: false,
        );
        appendSegmentEdits(segResult.script, outsideStart);
        outputBuffer.write(segResult.text);
        outputCursor += segResult.text.length;
        // Discourage unused-warning future-edit: real boundary trimming
        // applies only to the absolute first/last segments below.
        // ignore: dead_code
        if (isLastSegmentBeforeFinalEdge) {
          /* no-op */
        }
        // ignore: dead_code
        if (isFirstSegment) {
          /* no-op */
        }
      }

      // (b) Emit preserved segment verbatim, with tab→4-space normalisation.
      final preservedText = input.text.substring(preserved.start, preserved.end);
      final normalised = _normalisePreservedText(preservedText);
      // For preserved content, the normalisation may change length (tab → 4
      // spaces) so we emit it as a single Replace edit to capture that, OR
      // a Keep if the length is unchanged. Keep is preferred for cheaper
      // mapStart/mapEnd math.
      if (normalised == preservedText) {
        composedEdits.add(
          Keep(
            inputStart: preserved.start,
            inputEnd: preserved.end,
            outputStart: outputCursor,
          ),
        );
      } else {
        composedEdits.add(
          Replace(
            inputStart: preserved.start,
            inputEnd: preserved.end,
            outputStart: outputCursor,
            replacement: normalised,
          ),
        );
      }
      outputBuffer.write(normalised);
      outputCursor += normalised.length;

      cursor = preserved.end;
    }

    // (c) Final trailing outside segment (after last preserved range).
    if (cursor < originalLength) {
      final segText = input.text.substring(cursor, originalLength);
      // Final segment: still skip edge-trim here — the property test cares
      // about preserving \n separators around the last preserved range.
      // The plan §5.4 says "the full-output `.trim()` only applies to the
      // *very* leading and trailing edges of the entire output (preserving
      // today's behaviour for full-text inputs that don't contain
      // preserved ranges)". Since this branch is only reached when there
      // ARE preserved ranges, we should still NOT trim the trailing edge,
      // because that would erase the post-preserved separator.
      final segResult = cleanTextWithScript(segText, trimEdges: false);
      appendSegmentEdits(segResult.script, cursor);
      outputBuffer.write(segResult.text);
      outputCursor += segResult.text.length;
    }

    final cleanedText = outputBuffer.toString();
    final script = EditScript(
      edits: composedEdits,
      originalLength: originalLength,
      outputLength: cleanedText.length,
    );

    return RangeAwareResult(cleanedText: cleanedText, script: script);
  }

  /// Apply the cleaner to an [ExtractedText], returning a NEW [ExtractedText]
  /// with [text] set to the cleaned output and [preservedRanges] /
  /// [elementRanges] remapped through the [EditScript].
  ///
  /// Convenience wrapper around [cleanTextRespectingRanges].
  static ExtractedText cleanExtractedTextRespectingRanges(ExtractedText input) {
    final result = cleanTextRespectingRanges(input);
    final script = result.script;

    // Remap preservedRanges (each survives in some form — the cleaner never
    // drops them).
    final newPreserved = <TextRange>[];
    for (final r in input.preservedRanges) {
      final newStart = script.mapStart(r.start);
      final newEnd = script.mapEnd(r.end);
      if (newEnd > newStart) {
        newPreserved.add(TextRange(newStart, newEnd));
      }
    }

    // Remap elementRanges. Drop zero-length results (the cleaner collapsed
    // the element's text away).
    final newElementRanges = <dom.Element, List<TextRange>>{};
    input.elementRanges.forEach((el, ranges) {
      final mapped = <TextRange>[];
      for (final r in ranges) {
        final newStart = script.mapStart(r.start);
        final newEnd = script.mapEnd(r.end);
        if (newEnd > newStart) {
          mapped.add(TextRange(newStart, newEnd));
        }
      }
      if (mapped.isNotEmpty) {
        newElementRanges[el] = mapped;
      }
    });

    return ExtractedText(
      text: result.cleanedText,
      preservedRanges: newPreserved,
      elementRanges: newElementRanges,
      document: input.document,
    );
  }

  /// Tab→4-space normalisation for preserved content (plan §5.3).
  /// `\r` is dropped (consistent with renderer behaviour).
  static String _normalisePreservedText(String s) {
    if (!s.contains('\t') && !s.contains('\r')) return s;
    return s.replaceAll('\t', '    ').replaceAll('\r', '');
  }

  /// Greedy diff producing a coarse edit script for two strings. Used by
  /// [_applyFixPdfLineBreaks] only (where precise per-rule tracking would
  /// duplicate the rule logic).
  static EditScript _diffEditScript(String a, String b) {
    // Find longest common prefix and suffix; treat the middle as one
    // Replace edit. This is coarse but sufficient for offset translation
    // outside preserved ranges (plan §5.4 caveat).
    var prefix = 0;
    final maxPrefix = a.length < b.length ? a.length : b.length;
    while (prefix < maxPrefix && a.codeUnitAt(prefix) == b.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffixA = a.length;
    var suffixB = b.length;
    while (suffixA > prefix &&
        suffixB > prefix &&
        a.codeUnitAt(suffixA - 1) == b.codeUnitAt(suffixB - 1)) {
      suffixA--;
      suffixB--;
    }
    final edits = <Edit>[];
    var outCursor = 0;
    if (prefix > 0) {
      edits.add(Keep(inputStart: 0, inputEnd: prefix, outputStart: 0));
      outCursor = prefix;
    }
    final inputMidStart = prefix;
    final inputMidEnd = suffixA;
    final outputMidStart = outCursor;
    final replacementMid = b.substring(prefix, suffixB);
    if (inputMidEnd > inputMidStart || replacementMid.isNotEmpty) {
      if (replacementMid.isEmpty) {
        edits.add(
          Delete(
            inputStart: inputMidStart,
            inputEnd: inputMidEnd,
            outputStart: outputMidStart,
          ),
        );
      } else if (inputMidEnd > inputMidStart) {
        edits.add(
          Replace(
            inputStart: inputMidStart,
            inputEnd: inputMidEnd,
            outputStart: outputMidStart,
            replacement: replacementMid,
          ),
        );
        outCursor += replacementMid.length;
      } else {
        // Pure insertion — the input range is empty. We can't represent
        // this as an Edit over the input alphabet, so skip (downstream
        // offset translation is approximate here).
      }
    }
    if (suffixA < a.length) {
      edits.add(
        Keep(
          inputStart: suffixA,
          inputEnd: a.length,
          outputStart: outCursor,
        ),
      );
      outCursor += a.length - suffixA;
    }
    return EditScript(
      edits: edits,
      originalLength: a.length,
      outputLength: b.length,
    );
  }

  /// Shift edit's [inputStart]/[inputEnd] by [inputDelta] and [outputStart]
  /// by [outputDelta]. Used when reassembling segment-local edits into a
  /// global script.
  static Edit _shiftEdit(Edit e, int inputDelta, int outputDelta) {
    return switch (e) {
      Keep() => Keep(
          inputStart: e.inputStart + inputDelta,
          inputEnd: e.inputEnd + inputDelta,
          outputStart: e.outputStart + outputDelta,
        ),
      Replace() => Replace(
          inputStart: e.inputStart + inputDelta,
          inputEnd: e.inputEnd + inputDelta,
          outputStart: e.outputStart + outputDelta,
          replacement: e.replacement,
        ),
      Delete() => Delete(
          inputStart: e.inputStart + inputDelta,
          inputEnd: e.inputEnd + inputDelta,
          outputStart: e.outputStart + outputDelta,
        ),
    };
  }

  /// Fix line breaks from PDF text extraction.
  ///
  /// Fixes:
  /// 1. Hyphenated word breaks (po-\npokojowo -> pokojowo)
  /// 2. Mid-word breaks without hyphens
  /// 3. Preserves paragraph breaks and intentional formatting
  static String fixPdfLineBreaks(String text) {
    if (text.isEmpty) {
      return text;
    }

    text = text.replaceAllMapped(
      RegExp(r'([a-ząćęłńóśźżA-ZĄĆĘŁŃÓŚŹŻ]+)-\n([a-ząćęłńóśźż])'),
      (match) => '${match.group(1)}${match.group(2)}',
    );

    text = text.replaceAllMapped(
      RegExp(r'\s([a-ząćęłńóśźżA-ZĄĆĘŁŃÓŚŹŻ])\n([a-ząćęłńóśźż]+)'),
      (match) => ' ${match.group(1)}${match.group(2)}',
    );

    final lines = text.split('\n');
    final fixedLines = <String>[];
    var i = 0;

    while (i < lines.length) {
      final currentLine = lines[i].trimRight();

      if (i < lines.length - 1) {
        final nextLine = lines[i + 1].trimLeft();

        if (currentLine.isNotEmpty &&
            nextLine.isNotEmpty &&
            _isLowerCase(currentLine[currentLine.length - 1]) &&
            _isLowerCase(nextLine[0]) &&
            !currentLine.endsWith('-')) {
          fixedLines.add('$currentLine $nextLine');
          i += 2;
          continue;
        }
      }

      fixedLines.add(currentLine);
      i++;
    }

    text = fixedLines.join('\n');

    final replacements = [
      ['historii\ndla', 'historii dla'],
      ['oświaty\ni', 'oświaty i'],
      ['ogólnego\ndo', 'ogólnego do'],
      ['wiedzy\no', 'wiedzy o'],
    ];

    for (final replacement in replacements) {
      text = text.replaceAll(replacement[0], replacement[1]);
    }

    text = text.replaceAllMapped(
      RegExp(r'\b([A-Za-z])\n([a-z])'),
      (match) => '${match.group(1)}${match.group(2)}',
    );

    return text;
  }

  /// Check if a character is lowercase.
  static bool _isLowerCase(String char) {
    if (char.isEmpty) return false;
    final lower = char.toLowerCase();
    final upper = char.toUpperCase();
    return lower == char && upper != char;
  }

  /// Normalize whitespace in text.
  static String normalizeWhitespace(String text) {
    return text
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .split('\n')
        .map((line) => line.trim())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static const Map<String, String> _puaMapping = {
    '\u{E000}\u{E003}': 'C',
    '\u{E015}': 'S',
    '\u{E004}': 'D',
    '\u{E005}': 'E',
    '\u{E006}': 'F',
    '\u{E007}': 'G',
    '\u{E008}': 'H',
    '\u{E009}': 'I',
    '\u{E00A}': 'J',
    '\u{E00B}': 'K',
    '\u{E00C}': 'L',
    '\u{E00D}': 'M',
    '\u{E00E}': 'N',
    '\u{E00F}': 'O',
    '\u{E010}': 'P',
    '\u{E011}': 'Q',
    '\u{E012}': 'R',
    '\u{E013}': 'S',
    '\u{E014}': 'T',
    '\u{E016}': 'U',
    '\u{E017}': 'V',
    '\u{E018}': 'W',
    '\u{E019}': 'X',
    '\u{E01A}': 'Y',
    '\u{E01B}': 'Z',
    '\u{E001}': 'A',
    '\u{E002}': 'B',
  };
}

/// Result of [TextCleaner.cleanTextWithScript].
class CleanResult {
  final String text;
  final EditScript script;
  const CleanResult({required this.text, required this.script});
}

/// Result of [TextCleaner.cleanTextRespectingRanges].
class RangeAwareResult {
  final String cleanedText;
  final EditScript script;
  const RangeAwareResult({required this.cleanedText, required this.script});
}
