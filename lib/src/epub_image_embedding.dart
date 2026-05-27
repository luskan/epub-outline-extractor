import 'dart:collection';

import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';

import 'epub_image_types.dart';

/// Append image blocks for [figures] to [section]'s structured content.
///
/// Returns a new [BookSection] with the same identity but updated
/// `structuredContentJson`. If the section had no structured content,
/// one is synthesized with only the image blocks.
BookSection embedImagePathsInSection(
  BookSection section,
  List<ExtractedFigure> figures,
) {
  if (figures.isEmpty) return section;
  if (section.content.isEmpty) return section;

  final plainText = section.content.first;
  final endOffset = plainText.length;

  final newImageBlocks = <ContentBlock>[
    for (final f in figures)
      ContentBlock(
        type: ContentBlockType.image,
        start: endOffset,
        end: endOffset,
        imagePath: f.figure.path,
        caption: null,
      ),
  ];

  final existing = StructuredContent.tryParse(section.structuredContentJson);
  final List<ContentBlock> mergedBlocks;
  final String baseHash;
  if (existing != null && existing.isValidFor(plainText)) {
    mergedBlocks = <ContentBlock>[...existing.annotations, ...newImageBlocks];
    baseHash = existing.baseTextHash;
  } else {
    mergedBlocks = newImageBlocks;
    baseHash = StructuredContent.computeHash(plainText);
  }

  final merged = StructuredContent(
    schemaVersion: 1,
    baseTextHash: baseHash,
    annotations: mergedBlocks,
  );

  return section.copyWith(structuredContentJson: merged.toJsonString());
}

/// Walk [root] and embed image paths into every section that has
/// figures attributed to it in [figuresBySection].
BookSection embedImagePathsInTree(
  BookSection root,
  Map<BookSection, List<ExtractedFigure>> figuresBySection,
) {
  final figures = figuresBySection[root] ?? const <ExtractedFigure>[];
  final updatedRoot = embedImagePathsInSection(root, figures);

  if (updatedRoot.subsections.isEmpty) return updatedRoot;

  final updatedChildren = <BookSection>[
    for (final child in updatedRoot.subsections)
      embedImagePathsInTree(child, figuresBySection),
  ];

  var changed = false;
  for (var i = 0; i < updatedChildren.length; i++) {
    if (!identical(updatedChildren[i], updatedRoot.subsections[i])) {
      changed = true;
      break;
    }
  }

  return changed
      ? updatedRoot.copyWith(subsections: updatedChildren)
      : updatedRoot;
}

/// Group an extraction result's figures by owner section.
Map<BookSection, List<ExtractedFigure>> groupFiguresBySection(
  EpubImageExtractionResult result,
) {
  final out = HashMap<BookSection, List<ExtractedFigure>>.identity();
  for (final f in result.figures) {
    final owner = f.ownerSection;
    if (owner == null) continue;
    out.putIfAbsent(owner, () => <ExtractedFigure>[]).add(f);
  }
  return out;
}
