/// Text parsing utilities for EPUB processing.
///
/// Provides utilities for:
/// - Stripping numeric prefixes from strings
/// - Parsing major/minor numbers
/// - Converting integers to Roman numerals
/// - Parsing href components
library;

class TextParsingUtils {
  /// Strip numeric prefix from string (e.g., "1.2 Title" -> "Title")
  ///
  /// Example:
  /// ```dart
  /// TextParsingUtils.stripNumericPrefix('1.2 Chapter Title') // 'Chapter Title'
  /// TextParsingUtils.stripNumericPrefix('Title')           // 'Title'
  /// ```
  static String stripNumericPrefix(String text) {
    final match = RegExp(r'^\s*\d+(?:\.\d+)*\s+(.*)$').firstMatch(text);
    return match?.group(1)?.trim() ?? text.trim();
  }

  /// Parse major and minor numbers from string (e.g., "1.2" -> (1, 2))
  ///
  /// Returns a record with (major, minor) where either can be null.
  ///
  /// Example:
  /// ```dart
  /// TextParsingUtils.parseMajorMinor('1.2 Title')  // (1, 2)
  /// TextParsingUtils.parseMajorMinor('5 Title')    // (5, null)
  /// TextParsingUtils.parseMajorMinor('Title')      // (null, null)
  /// ```
  static (int?, int?) parseMajorMinor(String text) {
    final match = RegExp(r'^\s*(\d+)(?:\.(\d+))?').firstMatch(text);
    if (match == null) {
      return (null, null);
    }

    final major = int.tryParse(match.group(1) ?? '');
    final minor = match.group(2) != null ? int.tryParse(match.group(2)!) : null;

    return (major, minor);
  }

  /// Convert integer to Roman numeral (1-3999)
  ///
  /// Throws [ArgumentError] if number is out of range.
  ///
  /// Example:
  /// ```dart
  /// TextParsingUtils.toRoman(1)    // 'I'
  /// TextParsingUtils.toRoman(4)    // 'IV'
  /// TextParsingUtils.toRoman(9)    // 'IX'
  /// TextParsingUtils.toRoman(58)   // 'LVIII'
  /// TextParsingUtils.toRoman(1994) // 'MCMXCIV'
  /// ```
  static String toRoman(int number) {
    if (number < 1 || number > 3999) {
      throw ArgumentError('Number must be between 1 and 3999, got: $number');
    }

    const values = [
      (1000, 'M'),
      (900, 'CM'),
      (500, 'D'),
      (400, 'CD'),
      (100, 'C'),
      (90, 'XC'),
      (50, 'L'),
      (40, 'XL'),
      (10, 'X'),
      (9, 'IX'),
      (5, 'V'),
      (4, 'IV'),
      (1, 'I'),
    ];

    final result = StringBuffer();
    var remaining = number;

    for (final (value, symbol) in values) {
      while (remaining >= value) {
        result.write(symbol);
        remaining -= value;
      }
    }

    return result.toString();
  }

  /// Extract href parts (file and fragment)
  ///
  /// Returns a record with (file, fragment) where fragment can be null.
  ///
  /// Example:
  /// ```dart
  /// TextParsingUtils.parseHref('chapter1.xhtml#section2') // ('chapter1.xhtml', 'section2')
  /// TextParsingUtils.parseHref('chapter1.xhtml')          // ('chapter1.xhtml', null)
  /// ```
  static (String file, String? fragment) parseHref(String href) {
    if (href.contains('#')) {
      final parts = href.split('#');
      return (parts[0], parts.length > 1 ? parts[1] : null);
    }
    return (href, null);
  }

  /// Clean and normalize whitespace in text
  ///
  /// - Trims each line
  /// - Splits on double spaces
  /// - Removes empty chunks
  /// - Joins with newlines
  static String cleanWhitespace(String text) {
    final lines = text.split('\n').map((line) => line.trim());
    final chunks = lines
        .expand((line) => line.split('  '))
        .map((chunk) => chunk.trim());
    return chunks.where((chunk) => chunk.isNotEmpty).join('\n');
  }

  /// Extract part number/identifier from title
  ///
  /// Handles multiple formats:
  /// - "Part I", "Chapter 5", "Section III" (with keyword prefix)
  /// - "I. Title", "IV. Title" (Roman numeral with dot)
  /// - "1. Title", "12. Title" (Arabic numeral with dot)
  /// - "1 Title", "12 Title" (Arabic numeral with space, no dot)
  ///
  /// Returns the part identifier as-is (Roman or Arabic string)
  ///
  /// Example:
  /// ```dart
  /// TextParsingUtils.extractPartNumber('Part I: Introduction')  // 'I'
  /// TextParsingUtils.extractPartNumber('I. Data Structures')    // 'I'
  /// TextParsingUtils.extractPartNumber('1. The Python Data Model') // '1'
  /// TextParsingUtils.extractPartNumber('12 Overview')           // '12'
  /// TextParsingUtils.extractPartNumber('Just a Title')          // null
  /// ```
  static String? extractPartNumber(String? title) {
    if (title == null || title.isEmpty) return null;

    // Pattern 1: "Part/Chapter/Section/Guideline X" at START of title (anchored)
    // Requires boundary after number (whitespace, colon, dash, dot+space, or end)
    // to avoid matching "Part 1.2 Title" as part "1"
    var match = RegExp(
      r'^(?:Part|Część|Rozdział|Guideline|Chapter|Section)\s+([IVXLCDM]+|\d+)(?:[:\-–—]|\.\s|\s|$)',
      caseSensitive: false,
    ).firstMatch(title);
    if (match != null) return match.group(1)?.toUpperCase();

    // Pattern 2: Roman numeral at start "I." or "IV." etc (with dot AND space/end)
    match = RegExp(
      r'^([IVXLCDM]+)\.\s',
      caseSensitive: false,
    ).firstMatch(title);
    if (match != null) return match.group(1)?.toUpperCase();

    // Pattern 3: Arabic numeral at start "1. " or "12. " (with dot AND space)
    // Requires space after dot to avoid matching "1.2 Title"
    match = RegExp(r'^(\d+)\.\s+').firstMatch(title);
    if (match != null) return match.group(1);

    // Pattern 4: Arabic numeral at start "1 " or "12 " (with space, no dot)
    match = RegExp(r'^(\d+)\s+').firstMatch(title);
    if (match != null) return match.group(1);

    return null;
  }

  /// Convert Roman numeral string to integer
  ///
  /// Supports I, V, X, L, C, D, M and their subtractive combinations.
  /// Returns null if invalid Roman numeral.
  ///
  /// Example:
  /// ```dart
  /// TextParsingUtils.fromRoman('I')     // 1
  /// TextParsingUtils.fromRoman('IV')    // 4
  /// TextParsingUtils.fromRoman('IX')    // 9
  /// TextParsingUtils.fromRoman('XLII')  // 42
  /// TextParsingUtils.fromRoman('MCMXCIV') // 1994
  /// TextParsingUtils.fromRoman('ABC')   // null
  /// ```
  static int? fromRoman(String roman) {
    if (roman.isEmpty) return null;

    const values = {
      'I': 1,
      'V': 5,
      'X': 10,
      'L': 50,
      'C': 100,
      'D': 500,
      'M': 1000,
    };

    int result = 0;
    int prev = 0;
    final upperRoman = roman.toUpperCase();

    for (var i = upperRoman.length - 1; i >= 0; i--) {
      final value = values[upperRoman[i]];
      if (value == null) return null; // Invalid character

      if (value < prev) {
        result -= value;
      } else {
        result += value;
      }
      prev = value;
    }

    return result > 0 ? result : null;
  }

  /// Strip part prefix from title
  ///
  /// Handles multiple formats:
  /// - "Part I: Title" → "Title"
  /// - "Part I - Title" → "Title"
  /// - "I. Title" → "Title"
  /// - "1. Title" → "Title"
  /// - "1 Title" → "Title"
  ///
  /// Example:
  /// ```dart
  /// TextParsingUtils.stripPartPrefix('Part I: Introduction') // 'Introduction'
  /// TextParsingUtils.stripPartPrefix('I. Data Structures')   // 'Data Structures'
  /// TextParsingUtils.stripPartPrefix('1. Python Data Model') // 'Python Data Model'
  /// TextParsingUtils.stripPartPrefix('12 Overview')          // 'Overview'
  /// TextParsingUtils.stripPartPrefix('Just a Title')         // 'Just a Title'
  /// ```
  static String stripPartPrefix(String text) {
    // Pattern 1: "Part/Chapter/etc X" followed by separator (: - – — . or space)
    // Handles: "Part I: Title", "Part I - Title", "Part I. Title", "Chapter 1 Title"
    var match = RegExp(
      r'^(?:Part|Część|Rozdział|Guideline|Chapter|Section)\s+[IVXLCDM\d]+[:\-–—\.]?\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null && match.group(1)?.isNotEmpty == true) {
      return match.group(1)!.trim();
    }

    // Pattern 2: Roman numeral at start "I. Title" or "IV. Title"
    match = RegExp(
      r'^[IVXLCDM]+\.\s+(.*)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null && match.group(1)?.isNotEmpty == true) {
      return match.group(1)!.trim();
    }

    // Pattern 3: Arabic numeral at start "1. Title" or "12. Title" (requires space)
    match = RegExp(r'^\d+\.\s+(.*)$').firstMatch(text);
    if (match != null && match.group(1)?.isNotEmpty == true) {
      return match.group(1)!.trim();
    }

    // Pattern 4: Arabic numeral at start "1 Title" or "12 Title" (no dot)
    match = RegExp(r'^\d+\s+(.*)$').firstMatch(text);
    if (match != null && match.group(1)?.isNotEmpty == true) {
      return match.group(1)!.trim();
    }

    return text.trim();
  }
}
