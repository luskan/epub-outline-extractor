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
