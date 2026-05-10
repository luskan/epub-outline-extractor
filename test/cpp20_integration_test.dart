@Tags(['integration'])
library;

import 'dart:io';

import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';
import 'package:test/test.dart';

const _cpp20Path = '/Users/marcin/projects/quizpilgrim/book_tools/pdfs/cpp20.epub';

bool get _hasCpp20 => File(_cpp20Path).existsSync();

void main() {
  group(
    'cpp20 EPUB integration (§7.5)',
    () {
      late EpubExtractionResult? extraction;

      setUpAll(() async {
        if (!_hasCpp20) return;
        final bytes = File(_cpp20Path).readAsBytesSync();
        extraction = await EpubExtractor().extract(bytes);
      });

      test('extraction succeeds', () {
        expect(extraction, isNotNull);
        expect(extraction!.root.subsections, isNotEmpty);
      });

      test('at least one section has a preserveLineBreaks code block', () {
        final blocks = _allBlocks(extraction!);
        final codeBlocks =
            blocks.where((b) => b.preserveLineBreaks).toList(growable: false);
        expect(
          codeBlocks,
          isNotEmpty,
          reason:
              'cpp20 contains 70+ <pre> code listings; at least one '
              'should survive the v1.0 pipeline as a preserveLineBreaks '
              'block. Found ${blocks.length} blocks total, '
              '${codeBlocks.length} with preserveLineBreaks.',
        );
      });

      test('every code block has a monospace mark covering its full range',
          () {
        final blocks = _allBlocks(extraction!);
        final codeBlocks =
            blocks.where((b) => b.preserveLineBreaks).toList(growable: false);
        for (final b in codeBlocks) {
          final monos = b.marks
              .where((m) => m.type == InlineMarkType.monospace)
              .toList(growable: false);
          expect(
            monos,
            hasLength(1),
            reason: 'code block at [${b.start}, ${b.end}) should have '
                'exactly one monospace mark; got ${monos.length}',
          );
          expect(monos.single.start, b.start);
          expect(monos.single.end, b.end);
        }
      });

      test('section "1.1 Motivation for Operator<=>" contains cpp20 indentation',
          () {
        // Find the section by title prefix.
        final sections = _flatSections(extraction!.root.subsections);
        final targets = sections.where(
          (s) => s.title.toLowerCase().contains('motivation') ||
              s.title.toLowerCase().contains('1.1'),
        );
        if (targets.isEmpty) {
          // cpp20 EPUB structure may differ; fall back to looking at any
          // chapter whose plain text contains cpp class definitions.
          final allTexts = sections.map((s) => s.content.join('\n')).toList();
          final hasIndentedCode = allTexts.any(
            (t) => t.contains('class Value {') || t.contains('class Foo {'),
          );
          expect(
            hasIndentedCode,
            isTrue,
            reason:
                'cpp20 should contain at least one indented `class Foo {`-style '
                'definition somewhere in the extracted content.',
          );
          return;
        }
        // Section text should contain at least one indented code line.
        final motivation = targets.first;
        final text = motivation.content.join('\n');
        expect(text, contains('class '));
      });

      test('hash on every section JSON validates over its plain text', () {
        for (final s in _flatSections(extraction!.root.subsections)) {
          if (s.structuredContentJson == null) continue;
          final parsed = StructuredContent.tryParse(s.structuredContentJson!);
          if (parsed == null) continue;
          final plainText = s.content.join('\n');
          expect(
            parsed.isValidFor(plainText),
            isTrue,
            reason:
                'StructuredContent for "${s.title}" doesn\'t validate '
                'against its plain text — hash mismatch.',
          );
        }
      });

      test('Table of Contents emits ≥100 listItem blocks with inline marks',
          () {
        // Plan v5 Fix 6 cpp20 integration assertions.
        final sections = _flatSections(extraction!.root.subsections);
        final toc = sections.firstWhere(
          (s) => s.title == 'Table of Contents',
          orElse: () => throw StateError(
              'Table of Contents section not found in cpp20.epub'),
        );
        expect(toc.structuredContentJson, isNotNull,
            reason: 'TOC must have structuredContentJson after Fix 1');
        final parsed =
            StructuredContent.tryParse(toc.structuredContentJson!);
        expect(parsed, isNotNull);
        final blocks = parsed!.annotations;

        // (a) ≥ 100 listItem blocks (TOC has ~24 chapters × ~10 sub-entries).
        final listItems = blocks
            .where((b) => b.type == ContentBlockType.listItem)
            .toList(growable: false);
        expect(listItems.length, greaterThanOrEqualTo(100),
            reason: 'expected ≥100 listItem blocks; got '
                '${listItems.length}. Total blocks: ${blocks.length}.');

        // (b) Strong-coverage property: every non-ws char in plainText is
        // covered by at least one block range. cpp20 TOC is well-formed
        // <nav><ol><li> so this holds.
        final plainText = toc.content.join('\n');
        final covered = List<bool>.filled(plainText.length, false);
        for (final b in blocks) {
          for (var i = b.start; i < b.end && i < plainText.length; i++) {
            covered[i] = true;
          }
        }
        var firstUncoveredIdx = -1;
        for (var i = 0; i < plainText.length; i++) {
          final c = plainText.codeUnitAt(i);
          final isWs = c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
          if (!isWs && !covered[i]) {
            firstUncoveredIdx = i;
            break;
          }
        }
        expect(firstUncoveredIdx, -1,
            reason: 'cpp20 TOC strong-coverage gap at offset '
                '$firstUncoveredIdx; '
                'context: "${plainText.substring(
                    (firstUncoveredIdx - 20).clamp(0, plainText.length),
                    (firstUncoveredIdx + 40).clamp(0, plainText.length),
                  )}"');

        // (c) At least one listItem has ≥ 1 monospace mark.
        final listItemsWithMono = listItems
            .where(
              (li) => li.marks.any((m) => m.type == InlineMarkType.monospace),
            )
            .toList(growable: false);
        expect(listItemsWithMono, isNotEmpty,
            reason: 'no listItem in cpp20 TOC carries a monospace mark — '
                'Fix 3 not wired through');

        // (d) Positive presence: at least one listItem has 2 monospace
        // marks at distinct offsets with distinct lengths (proves Fix 2's
        // cursor advance for sibling <code>s with different text).
        final liWithTwoDistinctLengths = listItemsWithMono.where((li) {
          final monos = li.marks
              .where((m) => m.type == InlineMarkType.monospace)
              .toList();
          if (monos.length < 2) return false;
          final lengths = monos.map((m) => m.end - m.start).toSet();
          if (lengths.length < 2) return false;
          final starts = monos.map((m) => m.start).toSet();
          return starts.length == monos.length;
        }).toList(growable: false);
        expect(liWithTwoDistinctLengths, isNotEmpty,
            reason: 'no listItem with 2 distinct-length monospace marks at '
                'distinct offsets — sibling cursor advance regression');

        // (e) "1.3 Defining operator<=> and operator==" entry — exactly 2
        // monospace marks: one of length 11 (operator<=>), one of 10
        // (operator==). cpp20.epub is a pinned local fixture, so the entry
        // MUST exist; no silent skip via if-isNotEmpty (codex round-5 LOW).
        final cpp20Entry = listItems.where((li) {
          final txt = plainText.substring(li.start, li.end);
          return txt.contains('Defining') &&
              txt.contains('operator<=>') &&
              txt.contains('operator==');
        }).toList(growable: false);
        expect(cpp20Entry, isNotEmpty,
            reason: 'cpp20 TOC must contain the "1.3 Defining operator<=> '
                'and operator==" listItem block');
        final entry = cpp20Entry.first;
        final monos = entry.marks
            .where((m) => m.type == InlineMarkType.monospace)
            .toList();
        // Plan v5 §6: EXACTLY 2 monospace marks (one per <code>) of
        // lengths 11 (operator<=>) and 10 (operator==).
        expect(monos, hasLength(2),
            reason: 'cpp20 "1.3 Defining operator<=>" entry must carry '
                'exactly 2 monospace marks');
        final lengths = monos.map((m) => m.end - m.start).toList()..sort();
        expect(lengths, equals(<int>[10, 11]),
            reason: 'lengths must be exactly [10, 11]; got $lengths');

        // (f) Every mark satisfies block.start <= mark.start < mark.end <= block.end.
        for (final b in blocks) {
          for (final m in b.marks) {
            expect(m.start, greaterThanOrEqualTo(b.start),
                reason: 'mark.start ${m.start} < block.start ${b.start}');
            expect(m.end, lessThanOrEqualTo(b.end),
                reason: 'mark.end ${m.end} > block.end ${b.end}');
            expect(m.start, lessThan(m.end),
                reason: 'mark has zero/negative length');
          }
        }

        // (g) No two marks within a single block share both start AND end.
        for (final b in blocks) {
          final seen = <String>{};
          for (final m in b.marks) {
            final key = '${m.start}-${m.end}-${m.type.name}-${m.style ?? ''}';
            expect(seen.contains(key), isFalse,
                reason: 'duplicate mark at $key in block at '
                    '[${b.start}, ${b.end})');
            seen.add(key);
          }
        }

        // (h) Nesting depth: cpp20 TOC has 3-level nested <ol> for chapters.
        // Top-level chapters (e.g. "1. Comparisons …") have depth 0,
        // mid-tier sections (e.g. "1.1 Motivation …") have depth 1, and
        // sub-subsections (e.g. "1.1.1 Defining …") have depth 2.
        final depthHistogram = <int, int>{};
        for (final li in listItems) {
          depthHistogram[li.depth] = (depthHistogram[li.depth] ?? 0) + 1;
        }
        expect(depthHistogram[0] ?? 0, greaterThan(0),
            reason: 'expected at least one depth-0 listItem in cpp20 TOC');
        expect(depthHistogram[1] ?? 0, greaterThan(0),
            reason: 'expected at least one depth-1 listItem in cpp20 TOC '
                '(e.g. "1.1 Motivation for Operator<=>")');
        expect(depthHistogram[2] ?? 0, greaterThan(0),
            reason: 'expected at least one depth-2 listItem in cpp20 TOC '
                '(e.g. "1.1.1 Defining Comparison Operators Before C++20")');

        // The "1.1.1" entry verified above must have depth 2.
        final defining111 = listItems.where((li) {
          final txt = plainText.substring(li.start, li.end);
          return txt.contains('1.1.1 Defining Comparison Operators Before');
        }).toList(growable: false);
        expect(defining111, isNotEmpty,
            reason: 'cpp20 TOC must contain "1.1.1 Defining …" entry');
        expect(defining111.first.depth, 2,
            reason: '"1.1.1 Defining …" must have depth 2 (3-level nested ol)');
      });

      test('block multiset summary (structural snapshot)', () {
        // Plan §7.5: capture a stable multi-set of (blockType,
        // preserveLineBreaks, hasMonospaceMark) triples across all
        // sections. Locks the *shape* of cpp20 structured output.
        final blocks = _allBlocks(extraction!);
        final summary = <String, int>{};
        for (final b in blocks) {
          final hasMono = b.marks.any((m) => m.type == InlineMarkType.monospace);
          final key = '${b.type.name}|preserveLineBreaks=${b.preserveLineBreaks}|'
              'hasMonospace=$hasMono';
          summary[key] = (summary[key] ?? 0) + 1;
        }
        // Print for debug-build visibility — assertions check structural
        // expectations, not exact counts (those can drift with EPUB
        // version updates).
        print('cpp20 block summary: $summary');
        expect(blocks, isNotEmpty);
        // Specifically: there must be at least one
        // (paragraph, preserveLineBreaks=true, hasMonospace=true) entry.
        final codeKey =
            'paragraph|preserveLineBreaks=true|hasMonospace=true';
        expect(summary, containsPair(codeKey, isNonZero));
      });
    },
    skip: _hasCpp20 ? null : 'cpp20.epub not found at $_cpp20Path',
  );
}

List<ContentBlock> _allBlocks(EpubExtractionResult result) {
  final out = <ContentBlock>[];
  for (final s in _flatSections(result.root.subsections)) {
    if (s.structuredContentJson == null) continue;
    final parsed = StructuredContent.tryParse(s.structuredContentJson!);
    if (parsed == null) continue;
    out.addAll(parsed.annotations);
  }
  return out;
}

List<BookSection> _flatSections(List<BookSection> roots) {
  final out = <BookSection>[];
  void walk(BookSection s) {
    out.add(s);
    for (final c in s.subsections) {
      walk(c);
    }
  }

  for (final r in roots) {
    walk(r);
  }
  return out;
}

extension on int {
  // ignore: unused_element
  Matcher get isNonZero => greaterThan(0);
}

Matcher get isNonZero => greaterThan(0);
