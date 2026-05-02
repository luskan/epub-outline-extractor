/// Shared EPUB image extractor — produces [ExtractedFigure]s for all
/// `<img>` / SVG `<image>` / `data:` URIs found across the book's
/// chapters, mapped onto the neutral [BookSection] tree.
///
/// Single source of truth for both mobile and `book_tools`; replaces the
/// pre-Phase-4 PDF-only `FigureRenderer` for EPUB inputs.
///
/// Security contract (plan §4 Phase 4):
///   - Zip-slip: paths resolved via `package:path`, `..` segments and
///     absolute markers rejected; written paths must remain inside
///     `targetDir.absolute.path`.
///   - SVG XXE: `<!DOCTYPE>` and `<!ENTITY>` blocks stripped before
///     parse; non-relative `xlink:href` schemes rejected (defends
///     against SSRF / local-file leakage).
///   - `data:` URI cap: each individual `data:` payload, after base64
///     decode, must be ≤ `EpubGuardLimits.maxDataUriBytes` (default
///     10 MB). Over-cap URIs are skipped with a logged warning.
///   - Archive-level guards (zip-bomb, OOM, ZIP64) are enforced via
///     `enforceArchiveGuards` at entry, before `epub_pro` decoding.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:epub_pro/epub_pro.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';

import 'epub_guards.dart';

const String _loggerName = 'EpubImageExtractor';

/// Per-figure result returned by [EpubImageExtractor.extract].
///
/// Combines the format-neutral [Figure] (which goes into structured
/// content) with the absolute filesystem path the bytes were written to
/// (which the GUI / preview / persistence layers may need to load the
/// bytes back).
@immutable
class ExtractedFigure {
  /// Format-neutral figure descriptor. `figure.path` is the
  /// **relative** path supplied by the caller's `namingScheme`; it is
  /// what gets embedded into structured content for downstream rendering.
  final Figure figure;

  /// Absolute filesystem path of the written image inside `targetDir`.
  /// Combine with `figure.path` to reconstruct: `<targetDir>/<figure.path>`.
  final String absolutePath;

  /// The [BookSection] this figure was attributed to. Determined by
  /// fragment position in the chapter DOM — see `_attributeOwner`.
  /// `null` only when the chapter has no [BookSection] referencing it
  /// (rare; can happen if image extraction is run on a section tree
  /// that omits some chapters).
  final BookSection? ownerSection;

  /// Section-local index used by the caller's `namingScheme`.
  final int sectionLocalIndex;

  const ExtractedFigure({
    required this.figure,
    required this.absolutePath,
    required this.ownerSection,
    required this.sectionLocalIndex,
  });
}

/// Aggregate result of [EpubImageExtractor.extract] — the per-figure
/// list plus a precomputed map for embedding `imagePath` references
/// into structured content (anchor → relative path).
@immutable
class EpubImageExtractionResult {
  /// All extracted figures in deterministic chapter-pre-order order.
  final List<ExtractedFigure> figures;

  /// Anchor → relative path map, where anchor =
  /// `<chapter_href>:<dom_pre_order_index>`. Used by structured-content
  /// rewriting; identical to `Figure.anchor → Figure.path` extracted
  /// from `figures`.
  final Map<String, String> anchorToPath;

  EpubImageExtractionResult({
    required this.figures,
  }) : anchorToPath = Map.unmodifiable({
          for (final f in figures) f.figure.anchor: f.figure.path,
        });
}

/// Naming-scheme callback signature.
///
/// Returns the **relative** path (joined under `targetDir`) the image
/// should be written to. Caller picks the convention; mobile uses
/// `section_figures/{guid}/{idx}.{ext}`, `book_tools` uses
/// `figures/{safe_href}/{idx}.{ext}`.
///
/// `extension` is the file extension chosen by the extractor (`png`,
/// `jpg`, `gif`, `webp`, or `svg`) inferred from the source's MIME type
/// or file extension; the caller MUST honor it so figures aren't
/// misnamed for their actual byte content.
typedef EpubFigureNamingScheme = String Function(
  BookSection section,
  int sectionLocalIdx,
  String extension,
);

/// Public extractor surface.
class EpubImageExtractor {
  final Logger _logger;
  final EpubGuardLimits guardLimits;

  EpubImageExtractor({
    Logger? logger,
    this.guardLimits = const EpubGuardLimits(),
  }) : _logger = logger ?? Logger(_loggerName);

  /// Walk the EPUB chapters' HTML and extract every `<img>`, SVG
  /// `<image>`, and inline `data:` URI as an [ExtractedFigure].
  ///
  /// [epubBytes] — raw EPUB archive bytes. Validated against
  /// [guardLimits] before any unzip happens.
  ///
  /// [sectionTree] — neutral TOC tree (per `EpubExtractor.extract`).
  /// Used to attribute each figure to a section (the section whose
  /// fragment-anchored region of the chapter contains the image).
  ///
  /// [targetDir] — directory where images are written. Created if
  /// absent. Must be writable. All written files are kept under
  /// `targetDir.absolute.path` (zip-slip defense).
  ///
  /// [namingScheme] — caller-provided callback that maps
  /// `(BookSection, sectionLocalIdx, extension) → relative path`.
  Future<EpubImageExtractionResult> extract({
    required Uint8List epubBytes,
    required BookSection sectionTree,
    required Directory targetDir,
    required EpubFigureNamingScheme namingScheme,
  }) async {
    enforceArchiveGuards(epubBytes, guardLimits);

    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    final targetAbs = targetDir.absolute.path;

    // Use epub_pro so href semantics align with EpubExtractor: chapter
    // contentFileName + manifest hrefs are both OPF-relative, and
    // images map keys are OPF-relative too. No need to know the OPF
    // directory ourselves.
    final epubBook = await EpubReader.readBook(epubBytes);
    final content = epubBook.content;

    // OPF-relative href → HTML string.
    final htmlByHref = <String, String>{
      for (final entry in (content?.html ?? const {}).entries)
        entry.key: entry.value.content ?? '',
    };

    // OPF-relative href → image bytes.
    //
    // Prefer `content.images` (epub_pro classifies GIF/JPEG/PNG/SVG/BMP
    // there) but fall back to `allFiles` for `image/webp` and other
    // mime types epub_pro lumps under `EpubContentType.other`.
    final imageBytesByHref = <String, Uint8List>{};
    for (final entry in (content?.images ?? const {}).entries) {
      final bytes = entry.value.content;
      if (bytes != null) {
        imageBytesByHref[entry.key] = Uint8List.fromList(bytes);
      }
    }
    for (final entry in (content?.allFiles ?? const {}).entries) {
      if (imageBytesByHref.containsKey(entry.key)) continue;
      final byteFile = entry.value;
      if (byteFile is EpubByteContentFile && byteFile.content != null) {
        final mime = (byteFile.contentMimeType ?? '').toLowerCase();
        if (mime.startsWith('image/')) {
          imageBytesByHref[entry.key] = Uint8List.fromList(byteFile.content!);
        }
      }
    }

    // Walk every HTML chapter in spine order — not just chapters that
    // have a TOC section. Figure-heavy EPUBs sometimes carry chapters
    // whose body is essentially "<img>+caption" with no text; those
    // chapters fall out of the section tree (because EpubExtractor
    // skips empty-text chapters in `_extractChapters`) but their
    // images still need to be extracted and attributed to *some*
    // section. We use spine order for determinism and to match
    // EpubExtractor's chapter ordering.
    final chaptersInOrder = _collectAllChapterHrefsInSpineOrder(epubBook);

    final figures = <ExtractedFigure>[];
    final sectionLocalCounter = <int, int>{}; // identityHash → counter
    final dedupBySha = <String, _DedupSlot>{}; // sha256 → slot

    for (final href in chaptersInOrder) {
      // Look up the chapter HTML by OPF-relative href. The href stored
      // on sections matches the keys in `epub_book.content.html`.
      final htmlText = _findHtml(htmlByHref, href);
      if (htmlText == null) {
        _logger.fine('No archive entry for chapter href "$href" — skipping');
        continue;
      }

      final dom.Document chapterDoc;
      try {
        chapterDoc = html_parser.parse(htmlText);
      } catch (e) {
        _logger.warning('HTML parse failed for chapter "$href": $e — skipping');
        continue;
      }

      // Sections referencing this chapter, in section-tree order.
      // If the chapter has no section coverage (figure-only chapters
      // or chapters omitted from the TOC), attribute its images to the
      // root section so they still get extracted.
      var sectionsForChapter = _sectionsReferencingHref(sectionTree, href);
      if (sectionsForChapter.isEmpty) {
        sectionsForChapter = <BookSection>[sectionTree];
      }

      // Pre-order DOM walk. Track which qualifying-element index each
      // anchor was last seen at, for owner attribution.
      var domIdx = 0;
      final anchorPositions = <String, int>{}; // id attr → domIdx

      void walk(dom.Element root) {
        final stack = <dom.Element>[root];
        // Use explicit DFS stack to keep deterministic pre-order with a
        // bounded recursion depth (defensive against deeply nested
        // EPUBs that could blow the Dart call stack).
        while (stack.isNotEmpty) {
          final el = stack.removeLast();

          // Record anchor positions before processing children.
          final id = el.id;
          if (id.isNotEmpty) {
            anchorPositions[id] = domIdx;
          }

          // Process the element if it qualifies.
          final imageRef = _classifyElement(el);
          if (imageRef != null) {
            // Determine owner section (last anchor seen, falling back
            // to the chapter-level first section).
            final owner = _attributeOwner(
              sectionsForChapter,
              anchorPositions,
            );
            final ownerKey = identityHashCode(owner);
            final localIdx = sectionLocalCounter[ownerKey] ?? 0;

            final extracted = _materialize(
              ref: imageRef,
              chapterHref: href,
              domIndex: domIdx,
              imageBytesByHref: imageBytesByHref,
              targetDir: targetDir,
              targetAbs: targetAbs,
              ownerSection: owner,
              sectionLocalIdx: localIdx,
              namingScheme: namingScheme,
              dedupBySha: dedupBySha,
            );
            if (extracted != null) {
              figures.add(extracted);
              sectionLocalCounter[ownerKey] = localIdx + 1;
            }

            // Qualifying elements always increment the DOM index, even
            // if extraction failed/skipped — keeps anchors stable.
            domIdx++;
          }

          // Push children in reverse so leftmost is popped first.
          for (var i = el.children.length - 1; i >= 0; i--) {
            stack.add(el.children[i]);
          }
        }
      }

      final body = chapterDoc.body;
      if (body != null) {
        walk(body);
      } else {
        for (final child in chapterDoc.children) {
          walk(child);
        }
      }
    }

    return EpubImageExtractionResult(figures: figures);
  }

  // ----- Helpers ------------------------------------------------------

  /// Look up a chapter HTML body by href, accommodating leading-slash
  /// and percent-encoded variants the way EPUB readers typically do.
  String? _findHtml(Map<String, String> htmlByHref, String href) {
    final stripped = _stripFragment(href);
    final v = _findStringValue(htmlByHref, stripped);
    return v;
  }

  /// Look up image bytes by href, accommodating common URL-decoding
  /// and leading-slash variants.
  Uint8List? _findImage(Map<String, Uint8List> map, String href) =>
      _findValue(map, href);

  T? _findValue<T>(Map<String, T> entries, String href) {
    final stripped = _stripFragment(href);
    if (entries.containsKey(stripped)) return entries[stripped];
    final decoded = Uri.decodeComponent(stripped);
    if (entries.containsKey(decoded)) return entries[decoded];
    final noLead = stripped.startsWith('/') ? stripped.substring(1) : stripped;
    if (entries.containsKey(noLead)) return entries[noLead];
    return null;
  }

  String? _findStringValue(Map<String, String> entries, String href) =>
      _findValue<String>(entries, href);

  String _stripFragment(String href) {
    final idx = href.indexOf('#');
    return idx < 0 ? href : href.substring(0, idx);
  }

  /// Inspect a DOM element and return an `_ImageRef` if it's a
  /// figure-bearing element we should extract; null otherwise.
  _ImageRef? _classifyElement(dom.Element el) {
    final tag = el.localName?.toLowerCase();
    if (tag == 'img') {
      final src = el.attributes['src']?.trim();
      if (src == null || src.isEmpty) return null;
      return _ImageRef(
        element: el,
        rawSrc: src,
        source: src.startsWith('data:') ? 'epub_data_uri' : 'epub_img_tag',
      );
    }
    if (tag == 'image') {
      // SVG <image> — accept either xlink:href or href.
      final xlink = el.attributes['xlink:href']?.trim();
      final href = el.attributes['href']?.trim();
      final src = (xlink != null && xlink.isNotEmpty)
          ? xlink
          : (href != null && href.isNotEmpty ? href : null);
      if (src == null || src.isEmpty) return null;
      return _ImageRef(
        element: el,
        rawSrc: src,
        source: src.startsWith('data:') ? 'epub_data_uri' : 'epub_svg_image',
      );
    }
    return null;
  }

  /// Resolve the section that owns an image at the current DOM index,
  /// based on which section's anchor (if any) most recently preceded
  /// the image. Falls back to the first section that references the
  /// chapter if no anchored section qualifies.
  BookSection _attributeOwner(
    List<BookSection> sectionsForChapter,
    Map<String, int> anchorPositions,
  ) {
    BookSection? best;
    var bestPos = -1;
    BookSection? noAnchor;
    for (final s in sectionsForChapter) {
      final loc = s.location as EpubChapterLocation;
      if (loc.anchor == null) {
        noAnchor ??= s;
        continue;
      }
      final pos = anchorPositions[loc.anchor];
      if (pos != null && pos >= bestPos) {
        bestPos = pos;
        best = s;
      }
    }
    return best ?? noAnchor ?? sectionsForChapter.first;
  }

  /// Decode + write the image referenced by [ref], dedup by SHA256,
  /// build a [Figure] and [ExtractedFigure]. Returns null if the
  /// reference is rejected (zip-slip / oversized data URI / missing
  /// archive entry / unsupported scheme).
  ExtractedFigure? _materialize({
    required _ImageRef ref,
    required String chapterHref,
    required int domIndex,
    required Map<String, Uint8List> imageBytesByHref,
    required Directory targetDir,
    required String targetAbs,
    required BookSection ownerSection,
    required int sectionLocalIdx,
    required EpubFigureNamingScheme namingScheme,
    required Map<String, _DedupSlot> dedupBySha,
  }) {
    final src = ref.rawSrc;

    // ----- data: URI -----
    if (src.startsWith('data:')) {
      final decoded = _decodeDataUri(src);
      if (decoded == null) {
        _logger.fine(
          'data: URI in "$chapterHref" rejected (malformed or non-base64)',
        );
        return null;
      }
      if (decoded.bytes.length > guardLimits.maxDataUriBytes) {
        _logger.warning(
          'data: URI in "$chapterHref" at DOM idx $domIndex '
          '(${decoded.bytes.length} bytes) exceeds '
          'EPUB_MAX_DATA_URI_BYTES=${guardLimits.maxDataUriBytes} — skipped',
        );
        return null;
      }
      final ext = _extensionFromMime(decoded.mimeType) ?? 'png';
      final bytes = ext == 'svg' ? _sanitizeSvgBytes(decoded.bytes) : decoded.bytes;
      if (bytes == null) {
        _logger.warning(
          'data: URI in "$chapterHref" at DOM idx $domIndex rejected '
          '(SVG sanitization failed — DOCTYPE/ENTITY or unsafe href)',
        );
        return null;
      }
      return _writeAndBuild(
        bytes: bytes,
        ext: ext,
        ref: ref,
        chapterHref: chapterHref,
        domIndex: domIndex,
        targetDir: targetDir,
        targetAbs: targetAbs,
        ownerSection: ownerSection,
        sectionLocalIdx: sectionLocalIdx,
        namingScheme: namingScheme,
        dedupBySha: dedupBySha,
      );
    }

    // ----- Same-archive ref -----
    // Reject anything with an explicit scheme (http:, https:, file:,
    // etc.) — defends against SSRF / local-file leakage and matches
    // the "same-archive only" plan contract.
    final parsed = Uri.tryParse(src);
    if (parsed != null && parsed.hasScheme) {
      _logger.fine(
        'Image in "$chapterHref" references non-relative URL "$src" '
        '(scheme "${parsed.scheme}") — skipped',
      );
      return null;
    }

    // Resolve OPF-relatively. Chapter href is `OEBPS/chap01.xhtml`
    // (or similar); image src may be `images/x.png` or `../img/x.png`.
    final chapterDir = p.dirname(chapterHref);
    final cleanedSrc = _stripFragment(src);
    final resolvedRaw = chapterDir.isEmpty || chapterDir == '.'
        ? cleanedSrc
        : p.normalize(p.join(chapterDir, cleanedSrc));
    // Zip-slip defense: reject any normalized path that escapes the
    // archive root via `..` segments. After normalization there should
    // be no leading `..` and no absolute-path markers.
    if (resolvedRaw.startsWith('..') ||
        resolvedRaw.startsWith('/') ||
        resolvedRaw.contains('/../') ||
        resolvedRaw.startsWith('../')) {
      _logger.warning(
        'Image in "$chapterHref" resolves to "$resolvedRaw" '
        '(escapes archive root) — rejected',
      );
      return null;
    }

    final bytes = _findImage(imageBytesByHref, resolvedRaw);
    if (bytes == null) {
      _logger.fine(
        'Image in "$chapterHref" → "$resolvedRaw" not found in archive — skipped',
      );
      return null;
    }

    final ext = _extensionFromPath(resolvedRaw) ?? 'png';
    final processed = ext == 'svg' ? _sanitizeSvgBytes(bytes) : bytes;
    if (processed == null) {
      _logger.warning(
        'SVG image in "$chapterHref" → "$resolvedRaw" rejected '
        '(DOCTYPE/ENTITY or unsafe href)',
      );
      return null;
    }

    return _writeAndBuild(
      bytes: processed,
      ext: ext,
      ref: ref,
      chapterHref: chapterHref,
      domIndex: domIndex,
      targetDir: targetDir,
      targetAbs: targetAbs,
      ownerSection: ownerSection,
      sectionLocalIdx: sectionLocalIdx,
      namingScheme: namingScheme,
      dedupBySha: dedupBySha,
    );
  }

  ExtractedFigure? _writeAndBuild({
    required Uint8List bytes,
    required String ext,
    required _ImageRef ref,
    required String chapterHref,
    required int domIndex,
    required Directory targetDir,
    required String targetAbs,
    required BookSection ownerSection,
    required int sectionLocalIdx,
    required EpubFigureNamingScheme namingScheme,
    required Map<String, _DedupSlot> dedupBySha,
  }) {
    final shaHex = sha256.convert(bytes).toString();
    final anchor = '$chapterHref:$domIndex';

    // Dedup: if these bytes already live somewhere in targetDir, reuse
    // the existing path rather than writing a new file. Each anchor
    // still gets its own Figure entry — N references to one path.
    final cached = dedupBySha[shaHex];
    final relPath = cached?.relativePath ??
        namingScheme(ownerSection, sectionLocalIdx, ext);
    final fullPath = p.normalize(p.join(targetAbs, relPath));

    // Zip-slip defense on the *output* path too.
    if (!p.isWithin(targetAbs, fullPath) && fullPath != targetAbs) {
      _logger.warning(
        'namingScheme produced "$relPath" which escapes targetDir '
        '($targetAbs) — figure rejected',
      );
      return null;
    }

    if (cached == null) {
      try {
        final file = File(fullPath);
        // Create parent dirs.
        final parent = file.parent;
        if (!parent.existsSync()) {
          parent.createSync(recursive: true);
        }
        file.writeAsBytesSync(bytes);
      } catch (e) {
        _logger.warning(
          'Failed to write image for anchor "$anchor" → "$fullPath": $e',
        );
        return null;
      }
      dedupBySha[shaHex] = _DedupSlot(relativePath: relPath, absolutePath: fullPath);
    }

    final figure = Figure(
      path: cached?.relativePath ?? relPath,
      anchor: anchor,
      source: ref.source,
      sourceHref: chapterHref,
      domIndex: domIndex,
    );

    return ExtractedFigure(
      figure: figure,
      absolutePath: cached?.absolutePath ?? fullPath,
      ownerSection: ownerSection,
      sectionLocalIndex: sectionLocalIdx,
    );
  }

  /// Sanitize SVG bytes:
  ///   - reject if content contains `<!DOCTYPE` or `<!ENTITY` (XXE).
  ///   - reject if any `xlink:href` / `href` attribute uses a
  ///     non-relative scheme (`http:`, `https:`, `file:`, etc.).
  /// On rejection returns null. On success returns the (unmodified)
  /// bytes — sanitization is reject-on-violation, not silent rewrite,
  /// so the caller can log a clear "rejected" reason.
  Uint8List? _sanitizeSvgBytes(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final lower = text.toLowerCase();
    if (lower.contains('<!doctype') || lower.contains('<!entity')) {
      return null;
    }
    // Reject non-relative href / xlink:href schemes inside SVG content.
    // Done as a textual scan rather than a parse to keep this fast and
    // independent of XML parser availability.
    final hrefRe = RegExp(
      r'''(xlink:href|href)\s*=\s*(["'])([^"']*)["']''',
      caseSensitive: false,
    );
    for (final m in hrefRe.allMatches(text)) {
      final v = (m.group(3) ?? '').trim().toLowerCase();
      if (v.isEmpty) continue;
      if (v.startsWith('#')) continue; // intra-doc anchor
      if (v.startsWith('data:')) continue; // inline data URI
      final colonIdx = v.indexOf(':');
      if (colonIdx < 0) continue; // relative, no scheme
      // It has a scheme. Reject any non-relative scheme.
      return null;
    }
    return bytes;
  }

  /// Decode a `data:[<mime>][;base64],<data>` URI into bytes + mime.
  _DataUriPayload? _decodeDataUri(String src) {
    if (!src.startsWith('data:')) return null;
    final commaIdx = src.indexOf(',');
    if (commaIdx < 0) return null;
    final meta = src.substring(5, commaIdx); // after 'data:'
    final payload = src.substring(commaIdx + 1);
    final isBase64 = meta.toLowerCase().contains(';base64');
    final mime = meta.split(';').first.trim();
    try {
      final bytes = isBase64
          ? base64.decode(payload)
          : Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
      return _DataUriPayload(mimeType: mime, bytes: Uint8List.fromList(bytes));
    } catch (_) {
      return null;
    }
  }

  String? _extensionFromMime(String mime) {
    final m = mime.toLowerCase();
    if (m.startsWith('image/png')) return 'png';
    if (m.startsWith('image/jpeg') || m.startsWith('image/jpg')) return 'jpg';
    if (m.startsWith('image/gif')) return 'gif';
    if (m.startsWith('image/webp')) return 'webp';
    if (m.startsWith('image/svg')) return 'svg';
    return null;
  }

  String? _extensionFromPath(String path) {
    final ext = p.extension(path).toLowerCase();
    if (ext == '.png') return 'png';
    if (ext == '.jpg' || ext == '.jpeg') return 'jpg';
    if (ext == '.gif') return 'gif';
    if (ext == '.webp') return 'webp';
    if (ext == '.svg') return 'svg';
    return null;
  }

  /// Collect every HTML chapter href in spine order. Walks
  /// `epub_book.chapters` recursively (which mirrors the spine via
  /// `epub_pro.SchemaReader`'s NCX/spine reconciliation) and skips
  /// duplicates by content filename.
  List<String> _collectAllChapterHrefsInSpineOrder(EpubBook epubBook) {
    final seen = <String>{};
    final order = <String>[];
    void recurse(EpubChapter chapter) {
      final href = chapter.contentFileName;
      if (href != null && href.isNotEmpty && seen.add(href)) {
        order.add(href);
      }
      for (final sub in chapter.subChapters) {
        recurse(sub);
      }
    }

    for (final chapter in epubBook.chapters) {
      recurse(chapter);
    }
    return order;
  }

  /// Pre-order list of all sections whose `EpubChapterLocation.href`
  /// matches [chapterHref].
  List<BookSection> _sectionsReferencingHref(
    BookSection root,
    String chapterHref,
  ) {
    final out = <BookSection>[];
    void recurse(BookSection node) {
      final loc = node.location;
      if (loc is EpubChapterLocation && loc.href == chapterHref) {
        out.add(node);
      }
      for (final child in node.subsections) {
        recurse(child);
      }
    }

    recurse(root);
    return out;
  }
}

@immutable
class _ImageRef {
  final dom.Element element;
  final String rawSrc;
  final String source; // 'epub_img_tag' | 'epub_svg_image' | 'epub_data_uri'
  const _ImageRef({
    required this.element,
    required this.rawSrc,
    required this.source,
  });
}

@immutable
class _DataUriPayload {
  final String mimeType;
  final Uint8List bytes;
  const _DataUriPayload({required this.mimeType, required this.bytes});
}

@immutable
class _DedupSlot {
  final String relativePath;
  final String absolutePath;
  const _DedupSlot({required this.relativePath, required this.absolutePath});
}
