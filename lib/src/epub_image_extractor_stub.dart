import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';

import 'epub_guards.dart';

@immutable
class ExtractedFigure {
  final Figure figure;
  final String absolutePath;
  final BookSection? ownerSection;
  final int sectionLocalIndex;

  const ExtractedFigure({
    required this.figure,
    required this.absolutePath,
    required this.ownerSection,
    required this.sectionLocalIndex,
  });
}

@immutable
class EpubImageExtractionResult {
  final List<ExtractedFigure> figures;
  final Map<String, String> anchorToPath;

  EpubImageExtractionResult({required this.figures})
    : anchorToPath = Map.unmodifiable({
        for (final f in figures) f.figure.anchor: f.figure.path,
      });
}

typedef EpubFigureNamingScheme =
    String Function(BookSection section, int sectionLocalIdx, String extension);

class EpubImageExtractor {
  final EpubGuardLimits guardLimits;

  EpubImageExtractor({
    Object? logger,
    this.guardLimits = const EpubGuardLimits(),
  });

  Future<EpubImageExtractionResult> extract({
    required Uint8List epubBytes,
    required BookSection sectionTree,
    required Object targetDir,
    required EpubFigureNamingScheme namingScheme,
  }) {
    throw UnsupportedError('EPUB image extraction is not available on web.');
  }
}
