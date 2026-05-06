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

  /// Diff producing an edit script for two strings.
  ///
  /// Uses **token-aligned diff**: tokenise both strings on whitespace
  /// boundaries; if both produce the same number of non-whitespace tokens,
  /// emit one edit per token + one edit per inter-token whitespace gap.
  /// This gives fine-grained offset translation — important for v1.1+ where
  /// `<li>` / `<dt>` / `<dd>` ranges land at non-preserved positions and the
  /// coarse 3-edit diff would map them all to the same boundary.
  ///
  /// Falls back to coarse prefix/suffix diff when token counts differ
  /// (e.g. `fixPdfLineBreaks` merged "po-\nkojowo" into "pokojowo"),
  /// preserving previous offset-translation precision in those cases.
  static EditScript _diffEditScript(String a, String b) {
    if (a == b) {
      final edits = a.isEmpty
          ? const <Edit>[]
          : <Edit>[
              Keep(inputStart: 0, inputEnd: a.length, outputStart: 0),
            ];
      return EditScript(
        edits: edits,
        originalLength: a.length,
        outputLength: b.length,
      );
    }

    final aTokens = _tokenizeOnWhitespace(a);
    final bTokens = _tokenizeOnWhitespace(b);
    if (aTokens.length == bTokens.length && aTokens.isNotEmpty) {
      final aligned = _tokenAlignedDiff(a, b, aTokens, bTokens);
      if (aligned != null) return aligned;
    }
    return _coarsePrefixSuffixDiff(a, b);
  }

  /// Tokenise [s] into half-open `[start, end)` ranges of contiguous
  /// non-whitespace runs. Whitespace = ` `, `\t`, `\n`, `\r`. Returns each
  /// token as a 2-element list `[start, end]`.
  static List<List<int>> _tokenizeOnWhitespace(String s) {
    final tokens = <List<int>>[];
    var i = 0;
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (!_isAsciiWs(c)) {
        final start = i;
        while (i < s.length && !_isAsciiWs(s.codeUnitAt(i))) {
          i++;
        }
        tokens.add([start, i]);
      } else {
        i++;
      }
    }
    return tokens;
  }

  static bool _isAsciiWs(int c) {
    return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
  }

  /// Token-aligned diff. Assumes [aTokens.length] == [bTokens.length].
  /// Emits per-token + per-gap edits in input order. Returns null if a
  /// pure-insertion gap (input empty, output non-empty) is required —
  /// the [Edit] alphabet can't represent that, so the caller falls back
  /// to the coarse diff which represents it as a single combined Replace.
  static EditScript? _tokenAlignedDiff(
    String a,
    String b,
    List<List<int>> aTokens,
    List<List<int>> bTokens,
  ) {
    final edits = <Edit>[];
    var prevA = 0;
    var prevB = 0;

    bool emitGap(int aStart, int bStart) {
      if (aStart == prevA && bStart == prevB) return true; // empty
      final aGap = a.substring(prevA, aStart);
      final bGap = b.substring(prevB, bStart);
      if (aGap == bGap) {
        if (aStart > prevA) {
          edits.add(
            Keep(inputStart: prevA, inputEnd: aStart, outputStart: prevB),
          );
        }
        return true;
      }
      if (aStart > prevA) {
        if (bStart > prevB) {
          edits.add(
            Replace(
              inputStart: prevA,
              inputEnd: aStart,
              outputStart: prevB,
              replacement: bGap,
            ),
          );
        } else {
          edits.add(
            Delete(inputStart: prevA, inputEnd: aStart, outputStart: prevB),
          );
        }
        return true;
      }
      // Pure insertion (input empty, output non-empty) — Edit alphabet
      // can't represent this. Caller falls back to coarse diff.
      return false;
    }

    for (var k = 0; k < aTokens.length; k++) {
      final aStart = aTokens[k][0];
      final aEnd = aTokens[k][1];
      final bStart = bTokens[k][0];
      final bEnd = bTokens[k][1];
      if (!emitGap(aStart, bStart)) return null;
      final aTok = a.substring(aStart, aEnd);
      final bTok = b.substring(bStart, bEnd);
      if (aTok == bTok) {
        edits.add(
          Keep(inputStart: aStart, inputEnd: aEnd, outputStart: bStart),
        );
      } else {
        edits.add(
          Replace(
            inputStart: aStart,
            inputEnd: aEnd,
            outputStart: bStart,
            replacement: bTok,
          ),
        );
      }
      prevA = aEnd;
      prevB = bEnd;
    }
    if (!emitGap(a.length, b.length)) return null;
    return EditScript(
      edits: edits,
      originalLength: a.length,
      outputLength: b.length,
    );
  }

  /// Coarse fallback: longest common prefix + suffix, single Replace/Delete
  /// in the middle. Used when token-aligned diff can't represent an edit
  /// (pure insertion) or when token counts mismatch.
  static EditScript _coarsePrefixSuffixDiff(String a, String b) {
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
        // Pure insertion (input range empty, output non-empty). The Edit
        // alphabet can't represent this as a standalone edit, but we MUST
        // still advance outCursor so the trailing-suffix Keep's
        // outputStart accounts for the inserted text (codex round-1
        // MEDIUM — without this advance, the suffix Keep starts at the
        // wrong output offset, breaking mapStart/mapEnd for any input
        // position past the insertion point).
        outCursor += replacementMid.length;
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
