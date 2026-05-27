/// Browser EPUB image extractor. It mirrors the native extractor's section
/// attribution and path naming, but returns image bytes instead of writing to
/// a filesystem target.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:epub_pro/epub_pro.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';

import 'epub_guards.dart';
import 'epub_image_types.dart';

const String _loggerName = 'EpubImageExtractor';

class EpubImageExtractor {
  final Logger _logger;
  final EpubGuardLimits guardLimits;

  EpubImageExtractor({
    Object? logger,
    this.guardLimits = const EpubGuardLimits(),
  }) : _logger = logger is Logger ? logger : Logger(_loggerName);

  Future<EpubImageExtractionResult> extract({
    required Uint8List epubBytes,
    required BookSection sectionTree,
    required Object targetDir,
    required EpubFigureNamingScheme namingScheme,
  }) async {
    enforceArchiveGuards(epubBytes, guardLimits);

    final epubBook = await EpubReader.readBook(epubBytes);
    final content = epubBook.content;

    final htmlByHref = <String, String>{
      for (final entry in (content?.html ?? const {}).entries)
        entry.key: entry.value.content ?? '',
    };

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

    final chaptersInOrder = _collectAllChapterHrefsInSpineOrder(epubBook);
    final figures = <ExtractedFigure>[];
    final sectionLocalCounter = HashMap<BookSection, int>.identity();
    final dedupBySha = <String, _DedupSlot>{};

    for (final href in chaptersInOrder) {
      final htmlText = _findHtml(htmlByHref, href);
      if (htmlText == null) {
        _logger.fine('No archive entry for chapter href "$href" - skipping');
        continue;
      }

      final dom.Document chapterDoc;
      try {
        chapterDoc = html_parser.parse(htmlText);
      } catch (e) {
        _logger.warning('HTML parse failed for chapter "$href": $e - skipping');
        continue;
      }

      var sectionsForChapter = _sectionsReferencingHref(sectionTree, href);
      if (sectionsForChapter.isEmpty) {
        sectionsForChapter = <BookSection>[sectionTree];
      }

      var domIdx = 0;
      final anchorPositions = <String, int>{};

      void walk(dom.Element root) {
        final stack = <dom.Element>[root];
        while (stack.isNotEmpty) {
          final el = stack.removeLast();

          final id = el.id;
          if (id.isNotEmpty) {
            anchorPositions[id] = domIdx;
          }

          final imageRef = _classifyElement(el);
          if (imageRef != null) {
            final owner = _attributeOwner(sectionsForChapter, anchorPositions);
            final localIdx = sectionLocalCounter[owner] ?? 0;

            final extracted = _materialize(
              ref: imageRef,
              chapterHref: href,
              domIndex: domIdx,
              imageBytesByHref: imageBytesByHref,
              ownerSection: owner,
              sectionLocalIdx: localIdx,
              namingScheme: namingScheme,
              dedupBySha: dedupBySha,
            );
            if (extracted != null) {
              figures.add(extracted);
              sectionLocalCounter[owner] = localIdx + 1;
            }
            domIdx++;
          }

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

  String? _findHtml(Map<String, String> htmlByHref, String href) {
    final stripped = _stripFragment(href);
    return _findStringValue(htmlByHref, stripped);
  }

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

  ExtractedFigure? _materialize({
    required _ImageRef ref,
    required String chapterHref,
    required int domIndex,
    required Map<String, Uint8List> imageBytesByHref,
    required BookSection ownerSection,
    required int sectionLocalIdx,
    required EpubFigureNamingScheme namingScheme,
    required Map<String, _DedupSlot> dedupBySha,
  }) {
    final src = ref.rawSrc;

    if (src.startsWith('data:')) {
      final commaIdx = src.indexOf(',');
      if (commaIdx >= 0) {
        final encodedLen = src.length - commaIdx - 1;
        final maxEncoded = guardLimits.maxDataUriBytes * 2;
        if (encodedLen > maxEncoded) {
          _logger.warning(
            'data: URI in "$chapterHref" at DOM idx $domIndex '
            '(encoded length $encodedLen) exceeds pre-decode bound '
            '$maxEncoded - skipped',
          );
          return null;
        }
      }
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
          'EPUB_MAX_DATA_URI_BYTES=${guardLimits.maxDataUriBytes} - skipped',
        );
        return null;
      }
      final ext = _extensionFromMime(decoded.mimeType) ?? 'png';
      final bytes = ext == 'svg'
          ? _sanitizeSvgBytes(decoded.bytes)
          : decoded.bytes;
      if (bytes == null) {
        _logger.warning(
          'data: URI in "$chapterHref" at DOM idx $domIndex rejected '
          '(SVG sanitization failed)',
        );
        return null;
      }
      return _buildFigure(
        bytes: bytes,
        ext: ext,
        ref: ref,
        chapterHref: chapterHref,
        domIndex: domIndex,
        ownerSection: ownerSection,
        sectionLocalIdx: sectionLocalIdx,
        namingScheme: namingScheme,
        dedupBySha: dedupBySha,
      );
    }

    final parsed = Uri.tryParse(src);
    if (parsed != null && parsed.hasScheme) {
      _logger.fine(
        'Image in "$chapterHref" references non-relative URL "$src" '
        '(scheme "${parsed.scheme}") - skipped',
      );
      return null;
    }

    final chapterDir = p.dirname(chapterHref);
    final cleanedSrc = _stripFragment(src);
    if (cleanedSrc.contains('\\') ||
        RegExp(r'^[a-zA-Z]:').hasMatch(cleanedSrc)) {
      _logger.warning(
        'Image in "$chapterHref" uses Windows-style path '
        'separators or drive marker ("$cleanedSrc") - rejected',
      );
      return null;
    }
    final resolvedRaw = chapterDir.isEmpty || chapterDir == '.'
        ? cleanedSrc
        : p.normalize(p.join(chapterDir, cleanedSrc));
    if (resolvedRaw.startsWith('..') ||
        resolvedRaw.startsWith('/') ||
        resolvedRaw.contains('/../') ||
        resolvedRaw.startsWith('../')) {
      _logger.warning(
        'Image in "$chapterHref" resolves to "$resolvedRaw" '
        '(escapes archive root) - rejected',
      );
      return null;
    }

    final bytes = _findImage(imageBytesByHref, resolvedRaw);
    if (bytes == null) {
      _logger.fine(
        'Image in "$chapterHref" -> "$resolvedRaw" not found in archive - skipped',
      );
      return null;
    }

    final ext = _extensionFromPath(resolvedRaw) ?? 'png';
    final processed = ext == 'svg' ? _sanitizeSvgBytes(bytes) : bytes;
    if (processed == null) {
      _logger.warning(
        'SVG image in "$chapterHref" -> "$resolvedRaw" rejected '
        '(DOCTYPE/ENTITY or unsafe href)',
      );
      return null;
    }

    return _buildFigure(
      bytes: processed,
      ext: ext,
      ref: ref,
      chapterHref: chapterHref,
      domIndex: domIndex,
      ownerSection: ownerSection,
      sectionLocalIdx: sectionLocalIdx,
      namingScheme: namingScheme,
      dedupBySha: dedupBySha,
    );
  }

  ExtractedFigure? _buildFigure({
    required Uint8List bytes,
    required String ext,
    required _ImageRef ref,
    required String chapterHref,
    required int domIndex,
    required BookSection ownerSection,
    required int sectionLocalIdx,
    required EpubFigureNamingScheme namingScheme,
    required Map<String, _DedupSlot> dedupBySha,
  }) {
    final shaHex = sha256.convert(bytes).toString();
    final anchor = '$chapterHref:$domIndex';

    final cached = dedupBySha[shaHex];
    final relPath =
        cached?.relativePath ??
        namingScheme(ownerSection, sectionLocalIdx, ext);
    final normalizedPath = p.normalize(relPath);
    if (relPath.contains('\\') ||
        p.isAbsolute(normalizedPath) ||
        normalizedPath == '..' ||
        normalizedPath.startsWith('../') ||
        normalizedPath.contains('/../')) {
      _logger.warning(
        'namingScheme produced "$relPath" which is not a safe relative path '
        '- figure rejected',
      );
      return null;
    }

    if (cached == null) {
      dedupBySha[shaHex] = _DedupSlot(relativePath: normalizedPath);
    }

    final figurePath = cached?.relativePath ?? normalizedPath;
    final figure = Figure(
      path: figurePath,
      anchor: anchor,
      source: ref.source,
      sourceHref: chapterHref,
      domIndex: domIndex,
    );

    return ExtractedFigure(
      figure: figure,
      absolutePath: figurePath,
      ownerSection: ownerSection,
      sectionLocalIndex: sectionLocalIdx,
      bytes: bytes,
      mimeType: _mimeFromExtension(ext),
      sha256: shaHex,
    );
  }

  Uint8List? _sanitizeSvgBytes(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final lower = text.toLowerCase();
    if (lower.contains('<!doctype') || lower.contains('<!entity')) {
      return null;
    }
    final hrefRe = RegExp(
      r'''(xlink:href|href)\s*=\s*(["'])([^"']*)["']''',
      caseSensitive: false,
    );
    for (final m in hrefRe.allMatches(text)) {
      final raw = (m.group(3) ?? '').trim();
      if (raw.isEmpty) continue;
      final v = _decodeXmlNumericRefs(raw).toLowerCase();
      if (v.isEmpty) continue;
      if (v.startsWith('#')) continue;
      if (v.startsWith('data:')) continue;
      final colonIdx = v.indexOf(':');
      if (colonIdx < 0) continue;
      return null;
    }
    return bytes;
  }

  String _decodeXmlNumericRefs(String s) {
    if (!s.contains('&#')) return s;
    return s.replaceAllMapped(
      RegExp(r'&#(?:([0-9]{1,7})|x([0-9a-fA-F]{1,6}));'),
      (m) {
        final dec = m.group(1);
        final hex = m.group(2);
        try {
          final code = dec != null
              ? int.parse(dec)
              : int.parse(hex!, radix: 16);
          return String.fromCharCode(code);
        } catch (_) {
          return m.group(0)!;
        }
      },
    );
  }

  _DataUriPayload? _decodeDataUri(String src) {
    if (!src.startsWith('data:')) return null;
    final commaIdx = src.indexOf(',');
    if (commaIdx < 0) return null;
    final meta = src.substring(5, commaIdx);
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

  String _mimeFromExtension(String ext) {
    return switch (ext.toLowerCase()) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'svg' => 'image/svg+xml',
      _ => 'image/png',
    };
  }

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
  final String source;
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
  const _DedupSlot({required this.relativePath});
}
