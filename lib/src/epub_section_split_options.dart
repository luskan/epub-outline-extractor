/// EPUB section-splitting controls and pre-import analysis.
library;

/// Controls whether EPUB section extraction should stay on the authored
/// NAV/NCX tree or synthesize additional sections from in-chapter HTML
/// headings below TOC leaves.
class EpubSectionSplitOptions {
  /// Keep only EPUB NAV/NCX entries. This preserves historical behavior.
  static const tocOnly = EpubSectionSplitOptions();

  /// Deepen TOC leaves with eligible HTML headings through this heading level.
  ///
  /// `null` means no HTML-heading synthesis. Values are HTML heading levels
  /// 1-6, though callers normally expose h4-h6; h5/h6 candidates are filtered
  /// so listing, figure, table, and footnote headings do not become sections.
  final int? maxHtmlHeadingLevel;

  const EpubSectionSplitOptions({this.maxHtmlHeadingLevel})
    : assert(
        maxHtmlHeadingLevel == null ||
            (maxHtmlHeadingLevel >= 1 && maxHtmlHeadingLevel <= 6),
      );

  bool get usesHtmlHeadings => maxHtmlHeadingLevel != null;

  String get modeKey =>
      maxHtmlHeadingLevel == null ? 'toc' : 'h$maxHtmlHeadingLevel';

  static EpubSectionSplitOptions? tryParse(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'toc' || normalized == 'toc-only') {
      return tocOnly;
    }

    final match = RegExp(r'^h?([1-6])$').firstMatch(normalized);
    if (match == null) return null;
    return EpubSectionSplitOptions(
      maxHtmlHeadingLevel: int.parse(match.group(1)!),
    );
  }

  @override
  String toString() => 'EpubSectionSplitOptions($modeKey)';
}

/// Lightweight analysis for presenting EPUB section-split choices before
/// import.
class EpubSectionSplitAnalysis {
  final int tocOnlySectionCount;
  final Map<int, int> sectionCountByMaxHtmlHeadingLevel;
  final Map<int, int> candidateHeadingCountByLevel;

  const EpubSectionSplitAnalysis({
    required this.tocOnlySectionCount,
    required this.sectionCountByMaxHtmlHeadingLevel,
    required this.candidateHeadingCountByLevel,
  });

  List<int> get availableMaxHtmlHeadingLevels {
    final levels = candidateHeadingCountByLevel.keys.toList()..sort();
    return List.unmodifiable(levels);
  }

  int sectionCountFor(EpubSectionSplitOptions options) {
    final level = options.maxHtmlHeadingLevel;
    if (level == null) return tocOnlySectionCount;
    return sectionCountByMaxHtmlHeadingLevel[level] ?? tocOnlySectionCount;
  }
}
