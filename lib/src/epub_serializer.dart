import 'package:quizpilgrim_book_model/quizpilgrim_book_model.dart';

/// Serializes a [BookSection] whose `location` is [EpubChapterLocation] to
/// the EPUB document envelope's per-section JSON shape.
///
/// Output key set and order are **stable** and assert-tested:
///
///   `type, title, location, content?, structuredContentJson?, subsections?`
///
/// `location` is itself an ordered map:
///
///   `type, spine_index, end_spine_index?, href?, anchor?`
///
/// Optional keys are emitted only when their corresponding source field is
/// non-null / non-empty. Unlike the PDF legacy serializer, the per-section
/// shape carries no top-level `page` shorthand — format dispatch happens at
/// the document envelope's `format` field.
class EpubSerializer {
  static Map<String, dynamic> toJson(BookSection section) {
    final loc = section.location;
    if (loc is! EpubChapterLocation) {
      throw ArgumentError(
        'EpubSerializer requires a section with EpubChapterLocation '
        '(got ${loc.runtimeType}). Use a format-specific serializer instead.',
      );
    }

    final locJson = <String, dynamic>{
      'type': 'epub_chapter',
      'spine_index': loc.spineIndex,
    };
    if (loc.endSpineIndex != null) {
      locJson['end_spine_index'] = loc.endSpineIndex;
    }
    if (loc.href != null) {
      locJson['href'] = loc.href;
    }
    if (loc.anchor != null) {
      locJson['anchor'] = loc.anchor;
    }

    final json = <String, dynamic>{
      'type': 'section',
      'title': section.title,
      'location': locJson,
    };
    if (section.content.isNotEmpty) {
      json['content'] = section.content;
    }
    if (section.structuredContentJson != null) {
      json['structuredContentJson'] = section.structuredContentJson;
    }
    if (section.subsections.isNotEmpty) {
      json['subsections'] =
          section.subsections.map(EpubSerializer.toJson).toList();
    }
    return json;
  }
}
