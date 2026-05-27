import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'epub_data.dart';
import 'epub_section_split_options.dart';
import 'html_text_extractor.dart';
import 'text_parsing_utils.dart';

EpubSectionSplitAnalysis analyzeTocHtmlHeadingSplits(
  List<TocEntry> tocEntries,
  Map<String, String> htmlContentMap,
) {
  final tocOnlyCount = countTocEntries(tocEntries);
  final sectionCountByLevel = <int, int>{};
  var previousCount = tocOnlyCount;
  final candidateCountByLevel = <int, int>{};

  for (var level = 1; level <= 6; level++) {
    final augmented = augmentTocWithHtmlHeadings(
      tocEntries,
      htmlContentMap,
      EpubSectionSplitOptions(maxHtmlHeadingLevel: level),
    );
    final count = countTocEntries(augmented);
    sectionCountByLevel[level] = count;
    if (count > previousCount) {
      candidateCountByLevel[level] = count - previousCount;
    }
    previousCount = count;
  }

  return EpubSectionSplitAnalysis(
    tocOnlySectionCount: tocOnlyCount,
    sectionCountByMaxHtmlHeadingLevel: Map.unmodifiable(sectionCountByLevel),
    candidateHeadingCountByLevel: Map.unmodifiable(candidateCountByLevel),
  );
}

List<TocEntry> augmentTocWithHtmlHeadings(
  List<TocEntry> tocEntries,
  Map<String, String> htmlContentMap,
  EpubSectionSplitOptions options,
) {
  final maxLevel = options.maxHtmlHeadingLevel;
  if (maxLevel == null) return tocEntries;

  final originalFlat = flattenTocEntries(tocEntries);
  final existingHrefs = {
    for (final item in originalFlat)
      if (item.href != null) item.href!,
  };
  final htmlIndexes = {
    for (final entry in htmlContentMap.entries)
      entry.key: _buildHtmlHeadingIndex(entry.key, entry.value, existingHrefs),
  };
  final rangesByHref = _buildOriginalTocRanges(originalFlat, htmlIndexes);

  TocEntry augment(TocEntry entry, String? parentTitle) {
    final children = [
      for (final child in entry.children) augment(child, entry.title),
    ];

    // Only deepen authored TOC leaves. If the EPUB already supplied
    // children, keep that authorial structure as the source of truth.
    if (children.isNotEmpty || entry.href == null) {
      return TocEntry(
        title: entry.title,
        href: entry.href,
        parentTitle: parentTitle,
        depth: entry.depth,
        children: children,
      );
    }

    final range = rangesByHref[entry.href!];
    final index = range == null ? null : htmlIndexes[range.file];
    if (range == null || index == null) {
      return TocEntry(
        title: entry.title,
        href: entry.href,
        parentTitle: parentTitle,
        depth: entry.depth,
      );
    }

    final candidates = index.candidates
        .where(
          (candidate) =>
              candidate.order > range.startOrder &&
              candidate.order < range.endOrder &&
              candidate.level > range.parentHeadingLevel &&
              candidate.level <= maxLevel &&
              _normalizeTitle(candidate.title) != _normalizeTitle(entry.title),
        )
        .toList();
    if (candidates.isEmpty) {
      return TocEntry(
        title: entry.title,
        href: entry.href,
        parentTitle: parentTitle,
        depth: entry.depth,
      );
    }

    var candidateIndex = 0;
    List<TocEntry> buildChildren(
      int parentHeadingLevel,
      String? childParentTitle,
      int depth,
    ) {
      final result = <TocEntry>[];
      while (candidateIndex < candidates.length) {
        final candidate = candidates[candidateIndex];
        if (candidate.level <= parentHeadingLevel) break;
        candidateIndex++;
        final childChildren = buildChildren(
          candidate.level,
          candidate.title,
          depth + 1,
        );
        result.add(
          TocEntry(
            title: candidate.title,
            href: '${candidate.file}#${candidate.fragment}',
            parentTitle: childParentTitle,
            depth: depth,
            children: childChildren,
          ),
        );
      }
      return result;
    }

    return TocEntry(
      title: entry.title,
      href: entry.href,
      parentTitle: parentTitle,
      depth: entry.depth,
      children: buildChildren(
        range.parentHeadingLevel,
        entry.title,
        entry.depth + 1,
      ),
    );
  }

  return [for (final entry in tocEntries) augment(entry, null)];
}

List<TocItemFlat> flattenTocEntries(List<TocEntry> tocEntries) {
  final flat = <TocItemFlat>[];

  void flatten(TocEntry entry, String? parentTitle) {
    final isSection = entry.hasChildren;
    String? firstChildHref;
    if (isSection && entry.children.isNotEmpty) {
      firstChildHref = entry.children.first.href;
    }

    flat.add(
      TocItemFlat(
        title: entry.title,
        href: entry.href,
        parentTitle: parentTitle,
        depth: entry.depth,
        isSection: isSection,
        firstChildHref: firstChildHref,
      ),
    );

    for (final child in entry.children) {
      flatten(child, entry.title);
    }
  }

  for (final entry in tocEntries) {
    flatten(entry, null);
  }

  return flat;
}

int countTocEntries(List<TocEntry> entries) {
  var count = entries.length;
  for (final entry in entries) {
    count += countTocEntries(entry.children);
  }
  return count;
}

Map<String, _OriginalTocRange> _buildOriginalTocRanges(
  List<TocItemFlat> originalFlat,
  Map<String, _HtmlHeadingIndex> htmlIndexes,
) {
  final ranges = <String, _OriginalTocRange>{};

  for (var i = 0; i < originalFlat.length; i++) {
    final item = originalFlat[i];
    if (item.href == null || ranges.containsKey(item.href)) continue;

    final (file, fragment) = TextParsingUtils.parseHref(item.href!);
    final index = htmlIndexes[file];
    if (index == null) continue;

    final startOrder = fragment == null
        ? -1
        : index.headingOrderByFragment[fragment] ?? -1;
    final parentHeadingLevel = fragment == null
        ? 0
        : index.headingLevelByFragment[fragment] ?? 0;

    var endOrder = 1 << 30;
    for (var j = i + 1; j < originalFlat.length; j++) {
      final nextHref = originalFlat[j].href;
      if (nextHref == null) continue;
      final (nextFile, nextFragment) = TextParsingUtils.parseHref(nextHref);
      if (nextFile != file) break;
      if (nextFragment == null) continue;
      final nextOrder = index.headingOrderByFragment[nextFragment];
      if (nextOrder != null) {
        endOrder = nextOrder;
        break;
      }
    }

    ranges[item.href!] = _OriginalTocRange(
      file: file,
      startOrder: startOrder,
      endOrder: endOrder,
      parentHeadingLevel: parentHeadingLevel,
    );
  }

  return ranges;
}

_HtmlHeadingIndex _buildHtmlHeadingIndex(
  String file,
  String htmlContent,
  Set<String> existingHrefs,
) {
  final document = html_parser.parse(htmlContent);
  document.querySelectorAll('script, style').forEach((element) {
    element.remove();
  });
  final body = document.body;
  if (body == null) {
    return const _HtmlHeadingIndex(
      candidates: [],
      headingOrderByFragment: {},
      headingLevelByFragment: {},
    );
  }

  final preorderIndex = <dom.Element, int>{};
  var order = 0;
  void visit(dom.Element element) {
    preorderIndex[element] = order++;
    for (final child in element.children) {
      visit(child);
    }
  }

  visit(body);

  final candidates = <_HtmlHeadingCandidate>[];
  final orderByFragment = <String, int>{};
  final levelByFragment = <String, int>{};

  for (final heading in body.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
    final level = getHeadingLevel(heading);
    if (level == null) continue;
    final headingOrder = preorderIndex[heading] ?? 0;
    final fragments = _fragmentsForElement(heading);
    for (final fragment in fragments) {
      orderByFragment[fragment] = headingOrder;
      levelByFragment[fragment] = level;
    }

    final fragment = _primaryFragmentForHeading(heading);
    if (fragment == null) continue;
    final href = '$file#$fragment';
    if (existingHrefs.contains(href)) continue;

    final title = TextParsingUtils.cleanWhitespace(heading.text);
    if (title.isEmpty) continue;
    final candidate = _HtmlHeadingCandidate(
      file: file,
      fragment: fragment,
      title: title,
      level: level,
      order: headingOrder,
    );
    if (_isEligibleHtmlHeadingCandidate(candidate)) {
      candidates.add(candidate);
    }
  }

  candidates.sort((a, b) => a.order.compareTo(b.order));
  return _HtmlHeadingIndex(
    candidates: List.unmodifiable(candidates),
    headingOrderByFragment: Map.unmodifiable(orderByFragment),
    headingLevelByFragment: Map.unmodifiable(levelByFragment),
  );
}

List<String> _fragmentsForElement(dom.Element element) {
  final result = <String>[];
  void collect(dom.Element current) {
    final id = current.id.trim();
    if (id.isNotEmpty) result.add(id);
    final name = current.attributes['name']?.trim();
    if (name != null && name.isNotEmpty) result.add(name);
    for (final child in current.children) {
      collect(child);
    }
  }

  collect(element);
  return result;
}

String? _primaryFragmentForHeading(dom.Element heading) {
  final headingId = heading.id.trim();
  if (headingId.isNotEmpty && !_isAuxiliaryTitleAnchor(headingId)) {
    return headingId;
  }
  for (final fragment in _fragmentsForElement(heading)) {
    if (!_isAuxiliaryTitleAnchor(fragment)) return fragment;
  }
  return null;
}

bool _isAuxiliaryTitleAnchor(String fragment) {
  return fragment.endsWith('__title');
}

bool _isEligibleHtmlHeadingCandidate(_HtmlHeadingCandidate candidate) {
  final id = candidate.fragment.toLowerCase();
  final title = candidate.title.trim().toLowerCase();

  if (RegExp(
    r'(?:^|[._-])(ex|fig|figure|table|fn|footnote)\d*$',
  ).hasMatch(id)) {
    return false;
  }
  if (RegExp(r'^(listing|figure|fig\.|table|footnote)\b').hasMatch(title)) {
    return false;
  }

  if (candidate.level <= 4) return true;
  if (RegExp(r'lev\d+sec\d+').hasMatch(id)) return true;
  if (RegExp(r'^\d+(?:\.\d+){2,}\.?\s+').hasMatch(candidate.title)) {
    return true;
  }
  if (RegExp(r'^[A-Z]\.\d+(?:\.\d+)*\.?\s+').hasMatch(candidate.title)) {
    return true;
  }
  return false;
}

String _normalizeTitle(String? value) {
  return (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}

class _HtmlHeadingCandidate {
  final String file;
  final String fragment;
  final String title;
  final int level;
  final int order;

  const _HtmlHeadingCandidate({
    required this.file,
    required this.fragment,
    required this.title,
    required this.level,
    required this.order,
  });
}

class _HtmlHeadingIndex {
  final List<_HtmlHeadingCandidate> candidates;
  final Map<String, int> headingOrderByFragment;
  final Map<String, int> headingLevelByFragment;

  const _HtmlHeadingIndex({
    required this.candidates,
    required this.headingOrderByFragment,
    required this.headingLevelByFragment,
  });
}

class _OriginalTocRange {
  final String file;
  final int startOrder;
  final int endOrder;
  final int parentHeadingLevel;

  const _OriginalTocRange({
    required this.file,
    required this.startOrder,
    required this.endOrder,
    required this.parentHeadingLevel,
  });
}
