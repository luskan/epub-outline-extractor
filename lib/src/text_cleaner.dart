/// Text cleaning utilities for PDF and EPUB content.
///
/// This is a port of the Python text cleaning functions from ocr/pdf_text_to_json.py
library;

class TextCleaner {
  /// Clean text by removing special Unicode characters, normalizing whitespace,
  /// and optionally fixing PDF line breaks.
  static String cleanText(String text, {bool fixLineBreaks = true}) {
    // Map known PUA (Private Use Area) characters to their intended letters
    // These are decorative capitals used in PDFs
    final puaMapping = {
      '\u{E000}\u{E003}': 'C', // Decorative C
      '\u{E015}': 'S', // Decorative S
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

    // Replace known PUA character combinations
    puaMapping.forEach((puaChars, replacement) {
      text = text.replaceAll(puaChars, replacement);
    });

    // Remove remaining Private Use Area Unicode characters (U+E000 to U+F8FF)
    text = text.replaceAll(RegExp(r'[\uE000-\uF8FF]'), '');

    // Remove other control characters but keep newlines and tabs
    text = text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');

    // Fix PDF line breaks if requested
    if (fixLineBreaks) {
      text = fixPdfLineBreaks(text);
    }

    // Normalize multiple spaces to single space (but keep newlines)
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');

    // Remove spaces at the beginning and end of lines
    text = text.split('\n').map((line) => line.trim()).join('\n');

    // Remove multiple consecutive newlines (keep max 2)
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return text.trim();
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

    // Fix hyphenated line breaks (remove hyphen and join)
    // Pattern: word-hyphen-newline-lowercase word continuation
    // Support Polish characters: ą, ć, ę, ł, ń, ó, ś, ź, ż
    text = text.replaceAllMapped(
      RegExp(r'([a-ząćęłńóśźżA-ZĄĆĘŁŃÓŚŹŻ]+)-\n([a-ząćęłńóśźż])'),
      (match) => '${match.group(1)}${match.group(2)}',
    );

    // Fix obvious mid-word breaks (single letter before newline)
    // Pattern: space + single letter + newline + lowercase letters
    text = text.replaceAllMapped(
      RegExp(r'\s([a-ząćęłńóśźżA-ZĄĆĘŁŃÓŚŹŻ])\n([a-ząćęłńóśźż]+)'),
      (match) => ' ${match.group(1)}${match.group(2)}',
    );

    // Fix line breaks that split obvious words
    final lines = text.split('\n');
    final fixedLines = <String>[];
    var i = 0;

    while (i < lines.length) {
      final currentLine = lines[i].trimRight();

      if (i < lines.length - 1) {
        final nextLine = lines[i + 1].trimLeft();

        // Check if current line ends with lowercase and next starts with lowercase
        if (currentLine.isNotEmpty &&
            nextLine.isNotEmpty &&
            _isLowerCase(currentLine[currentLine.length - 1]) &&
            _isLowerCase(nextLine[0]) &&
            !currentLine.endsWith('-')) {
          // This is likely a mid-sentence break, join with space
          fixedLines.add('$currentLine $nextLine');
          i += 2; // Skip next line as we've merged it
          continue;
        }
      }

      fixedLines.add(currentLine);
      i++;
    }

    text = fixedLines.join('\n');

    // Fix specific common issues in Polish PDFs
    final replacements = [
      ['historii\ndla', 'historii dla'],
      ['oświaty\ni', 'oświaty i'],
      ['ogólnego\ndo', 'ogólnego do'],
      ['wiedzy\no', 'wiedzy o'],
    ];

    for (final replacement in replacements) {
      text = text.replaceAll(replacement[0], replacement[1]);
    }

    // Fix single letters on separate lines (common in tables/maps)
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
}
