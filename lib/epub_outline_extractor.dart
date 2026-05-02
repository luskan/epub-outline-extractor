/// Pure-Dart EPUB structure extractor — produces a neutral [BookSection]
/// tree (per `quizpilgrim_book_model`) that mobile and `book_tools` consume
/// uniformly.
///
/// Public API: [EpubExtractor], [EpubExtractionResult], [EpubBookMetadata],
/// plus internal helpers ([ChapterData], [TocEntry], [TocItemFlat],
/// [EpubData], [EpubStructuredContentBuilder], html-extraction utilities,
/// [TextCleaner], [TextParsingUtils]) re-exported for callers/tests that
/// previously reached into the mobile internals.
library;

export 'src/epub_data.dart';
export 'src/epub_extraction_result.dart';
export 'src/epub_extractor.dart';
export 'src/epub_guards.dart';
export 'src/epub_image_extractor.dart';
export 'src/epub_serializer.dart';
export 'src/epub_structured_content_builder.dart';
export 'src/html_text_extractor.dart';
export 'src/text_cleaner.dart';
export 'src/text_parsing_utils.dart';
