@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:epub_outline_extractor/epub_outline_extractor.dart';
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';
import 'package:test/test.dart';

/// Corpus baseline for `BookSection.content[0]` text — locks Fix 1's
/// flow change against drift.
///
/// Samples the FIRST 5 sections of each EPUB (deterministic order; matches
/// the TOC pre-order DFS the extractor emits). Across the 3 EPUBs:
/// - cpp20: 4 of 5 entries are no-fragment (title_page, "C++20 - The
///   Complete Guide", "Black Lives Matter", "Table of Contents").
///   `title_page` is a zero-length virtual placeholder (sentinel
///   `EpubChapterLocation(spineIndex: -1)` with empty content) that
///   bypasses Fix 1's pipeline entirely. The other 3 carry non-trivial
///   content (511 / 18 / 17746 bytes) and are the load-bearing Fix 1
///   anchors.
/// - alicesAdventures: 1 of 5 entries is no-fragment (`wrap0000`,
///   zero-length virtual placeholder — also bypasses Fix 1).
/// - frankenstein: 1 of 5 entries is no-fragment (`wrap0000`,
///   zero-length virtual placeholder — also bypasses Fix 1).
///
/// **Net Fix 1 coverage**: 3 of 15 hashes lock non-trivial no-fragment
/// chapter text against drift, all in cpp20. The remaining 12 hashes
/// (3 zero-length placeholders + 9 fragment-having) serve as a
/// "no-regression for unrelated paths" net — they should not change
/// after Fix 1 since the pipeline is unchanged for them.
///
/// alicesAdventures and frankenstein deliberately have shallow
/// no-fragment coverage because their TOCs are fully anchored beyond
/// `wrap0000`. cpp20 carries the load for the no-fragment regression
/// gate; the cpp20 integration test (`cpp20_integration_test.dart`)
/// adds structural assertions on top of the byte-identity hash.
///
/// If a hash drifts, EITHER (a) the change is an intended consequence of
/// some fix and the baseline JSON should be regenerated and the diff
/// explained in the commit body, OR (b) the change is unintended and the
/// fix is wrong.
const _epubs = <String, String>{
  'cpp20': '/Users/marcin/projects/quizpilgrim/book_tools/pdfs/cpp20.epub',
  'alicesAdventures':
      '/Users/marcin/projects/quizpilgrim/epub_pro/assets/alicesAdventuresUnderGround.epub',
  'frankenstein':
      '/Users/marcin/projects/quizpilgrim/epub_pro/assets/frankenstein.epub',
};

const _baselinePath =
    'test/golden/spine_only_chapter_text_baseline.json';

void main() {
  test(
    'corpus baseline: first 5 sections of cpp20 / alicesAdventures / frankenstein',
    () async {
      final allMissing = _epubs.values.every((p) => !File(p).existsSync());
      if (allMissing) {
        print('SKIP: no fixture EPUBs found');
        return;
      }
      final baselineFile = File(_baselinePath);
      expect(baselineFile.existsSync(), isTrue,
          reason: 'baseline JSON missing at $_baselinePath');
      final baseline =
          (jsonDecode(baselineFile.readAsStringSync()) as List).cast<Map>();

      // Build current map { "epub|title|hasAnchor" → sha256 } and compare.
      final actual = <String, Map<String, dynamic>>{};
      for (final entry in _epubs.entries) {
        final f = File(entry.value);
        if (!f.existsSync()) continue;
        final bytes = f.readAsBytesSync();
        final extraction = await EpubExtractor().extract(bytes);
        final sections = <BookSection>[];
        void walk(BookSection s) {
          sections.add(s);
          for (final c in s.subsections) {
            walk(c);
          }
        }

        for (final r in extraction.root.subsections) {
          walk(r);
        }
        for (final s in sections.take(5)) {
          final loc = s.location;
          final hasAnchor = loc is EpubChapterLocation && loc.anchor != null;
          final text = s.content.join('\n');
          final hash = sha256.convert(utf8.encode(text)).toString();
          final key = '${entry.key}|${s.title}|$hasAnchor';
          actual[key] = {
            'epub': entry.key,
            'title': s.title,
            'hasAnchor': hasAnchor,
            'sha256': hash,
            'len': text.length,
          };
        }
      }

      // Validate every baseline entry against actual.
      final mismatches = <String>[];
      for (final b in baseline) {
        final epub = b['epub'] as String;
        if (!File(_epubs[epub]!).existsSync()) {
          // Fixture missing on this machine — skip rather than fail.
          continue;
        }
        final key = '${b['epub']}|${b['title']}|${b['hasAnchor']}';
        final cur = actual[key];
        if (cur == null) {
          mismatches.add('MISSING current: $key');
          continue;
        }
        if (cur['sha256'] != b['sha256']) {
          mismatches.add(
              'HASH DRIFT: $key (len ${b['len']} → ${cur['len']}; '
              'sha256 ${b['sha256']} → ${cur['sha256']})');
        }
      }
      if (mismatches.isNotEmpty) {
        print('Baseline mismatches:');
        for (final m in mismatches) {
          print('  $m');
        }
        print(
            '\nIf changes are intended, regenerate $_baselinePath '
            'and explain the diff in the commit body.');
      }
      expect(mismatches, isEmpty,
          reason: 'corpus baseline drift — see printed mismatches above');
    },
  );
}
