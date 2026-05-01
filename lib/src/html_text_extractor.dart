/// HTML text extraction utilities for EPUB conversion.
///
/// Provides functions for extracting clean text from HTML content,
/// handling fragments, headings, and block elements.
library;

import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'text_parsing_utils.dart';

/// Default heading level (h2) used when extracting section text
/// and the starting element is not itself a heading.
const _defaultHeadingLevel = 2;

/// Extract text from HTML content, removing scripts and styles.
///
/// [htmlContent] - Raw HTML content.
/// Returns cleaned text content.
String extractTextFromHtml(String htmlContent) {
  final document = html_parser.parse(htmlContent);

  // Remove scripts and styles
  document.querySelectorAll('script, style').forEach((element) {
    element.remove();
  });

  // Get text content
  final text = document.body?.text ?? document.text ?? '';

  // Clean whitespace
  return TextParsingUtils.cleanWhitespace(text);
}

/// Extract title from HTML content.
///
/// Tries h1, h2, h3, title tags in order.
/// Falls back to sanitized filename if no title found.
String extractTitleFromHtml(String htmlContent, String fallbackName) {
  final document = html_parser.parse(htmlContent);

  // Try to find title in order of preference
  for (final tag in ['h1', 'h2', 'h3', 'title']) {
    final element = document.querySelector(tag);
    if (element != null) {
      final title = element.text.trim();
      if (title.isNotEmpty) {
        return title;
      }
    }
  }

  // Fallback to filename
  return fallbackName.split('/').last.split('.').first;
}

/// Extract section text between fragment IDs.
///
/// [htmlContent] - Raw HTML content.
/// [fragmentId] - Starting fragment ID (optional).
/// [nextFragmentId] - Ending fragment ID (optional).
/// [logger] - Optional logging callback for debug output.
/// Returns extracted text between the fragments.
String extractSectionText(
  String htmlContent,
  String? fragmentId,
  String? nextFragmentId, {
  void Function(String)? logger,
}) {
  final document = html_parser.parse(htmlContent);

  // Remove scripts and styles
  document.querySelectorAll('script, style').forEach((element) {
    element.remove();
  });

  // Case 1: No fragment ID - extract from beginning to nextFragmentId
  if (fragmentId == null) {
    if (nextFragmentId != null) {
      logger?.call(
        '    Extracting from beginning until fragment: $nextFragmentId',
      );
      return _extractTextUntilElement(document, nextFragmentId, logger);
    }
    // No fragments at all - this is likely the entire chapter
    logger?.call(
      '    WARNING: No fragment boundaries, using full chapter text',
    );
    return document.body?.text ?? document.text ?? '';
  }

  // Case 2: Find start element by fragment ID
  final startElement =
      document.querySelector('#$fragmentId') ??
      document.querySelector('[name="$fragmentId"]');

  if (startElement == null) {
    logger?.call('    WARNING: Fragment ID "$fragmentId" not found in HTML!');
    return '';
  }

  logger?.call(
    '    Extracting from fragment: $fragmentId (${startElement.localName}) to ${nextFragmentId ?? "next heading"}',
  );

  // Case 3: Extract from fragment to next fragment or heading
  return _extractTextFromElement(
    document,
    startElement,
    nextFragmentId,
    logger,
  );
}

/// Extract text until a specific element ID.
String _extractTextUntilElement(
  dom.Document document,
  String elementId,
  void Function(String)? logger,
) {
  final endElement =
      document.querySelector('#$elementId') ??
      document.querySelector('[name="$elementId"]');

  if (endElement == null) {
    logger?.call(
      '    WARNING: End fragment ID "$elementId" not found in HTML!',
    );
    return '';
  }

  final textParts = <String>[];

  void walkNodes(dom.Node node, {bool stopAtEnd = true}) {
    if (stopAtEnd && node == endElement) {
      return;
    }

    if (node.nodeType == dom.Node.TEXT_NODE) {
      final text = node.text ?? '';
      if (text.isNotEmpty) {
        textParts.add(text);
      }
    } else if (node is dom.Element) {
      if (node.localName?.toLowerCase() == 'br') {
        textParts.add('\n');
      } else if (isBlockElement(node)) {
        textParts.add('\n\n');
      }
      for (final child in node.nodes) {
        walkNodes(child);
        if (stopAtEnd && child == endElement) break;
      }
    }
  }

  walkNodes(document);

  return cleanExtractedText(textParts.join());
}

/// Extract text from element until next section.
String _extractTextFromElement(
  dom.Document document,
  dom.Element startElement,
  String? nextFragmentId,
  void Function(String)? logger,
) {
  final textParts = <String>[];
  var hasCollectedContent = false;

  // Determine where to actually start traversal and what heading level to use
  dom.Element actualStart = startElement;
  int? startLevel = getHeadingLevel(startElement);

  // If start element is not a heading, look for a heading inside it
  if (startLevel == null) {
    final innerHeading = startElement.querySelector('h1, h2, h3, h4, h5, h6');
    if (innerHeading != null) {
      startLevel = getHeadingLevel(innerHeading);
      actualStart = innerHeading;
    }
  }

  final effectiveStartLevel = startLevel ?? _defaultHeadingLevel;

  var passedStartHeading = (startLevel == null);
  var isFirstIteration = true;

  dom.Node? current = actualStart;

  while (current != null) {
    // Check if we reached next fragment by its ID
    if (nextFragmentId != null && current is dom.Element) {
      if (current.id == nextFragmentId ||
          current.attributes['name'] == nextFragmentId) {
        break;
      }
    }

    // Check if we reached same-or-higher heading level
    if (current is dom.Element) {
      final currentLevel = getHeadingLevel(current);
      if (currentLevel != null) {
        final isInNoteOrSidebar = isInsideNoteOrSidebar(current);

        if (passedStartHeading &&
            currentLevel <= effectiveStartLevel &&
            !isInNoteOrSidebar &&
            hasCollectedContent) {
          break;
        }
        if (!passedStartHeading &&
            currentLevel == effectiveStartLevel &&
            !isInNoteOrSidebar) {
          passedStartHeading = true;
        }
      }
    }

    var shouldCollect = true;
    if (isFirstIteration &&
        current == actualStart &&
        getHeadingLevel(actualStart) != null) {
      shouldCollect = false;
    }
    isFirstIteration = false;

    if (shouldCollect && current.nodeType == dom.Node.TEXT_NODE) {
      final text = current.text ?? '';
      if (text.isNotEmpty) {
        textParts.add(text);
        if (text.trim().isNotEmpty) {
          hasCollectedContent = true;
        }
      }
    }

    if (current is dom.Element) {
      if (current.localName?.toLowerCase() == 'br') {
        textParts.add('\n');
      } else if (isBlockElement(current)) {
        textParts.add('\n\n');
      }
    }

    current = getNextNode(current);
  }

  return cleanExtractedText(textParts.join());
}

/// Get next node in document order (depth-first traversal).
dom.Node? getNextNode(dom.Node node) {
  // If node has children, return first child
  if (node is dom.Element && node.nodes.isNotEmpty) {
    return node.nodes.first;
  }

  // Find next sibling or ancestor's sibling
  final parent = node.parent;
  if (parent != null) {
    final index = parent.nodes.indexOf(node);
    if (index >= 0 && index < parent.nodes.length - 1) {
      return parent.nodes[index + 1];
    }

    // Walk up to find parent's next sibling
    var ancestor = parent;
    while (ancestor.parent != null) {
      final grandParent = ancestor.parent!;
      final ancestorIndex = grandParent.nodes.indexOf(ancestor);
      if (ancestorIndex >= 0 && ancestorIndex < grandParent.nodes.length - 1) {
        return grandParent.nodes[ancestorIndex + 1];
      }
      ancestor = grandParent;
    }
  }

  return null;
}

/// Get heading level (1-6) from element.
int? getHeadingLevel(dom.Element element) {
  final tag = element.localName?.toLowerCase();
  if (tag != null && tag.startsWith('h') && tag.length == 2) {
    return int.tryParse(tag[1]);
  }
  return null;
}

/// Check if element is a block-level element.
bool isBlockElement(dom.Element element) {
  final tag = element.localName?.toLowerCase();
  if (tag == null) return false;

  const blockTags = {
    'p',
    'div',
    'section',
    'article',
    'aside',
    'header',
    'footer',
    'nav',
    'main',
    'figure',
    'figcaption',
    'blockquote',
    'pre',
    'hr',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'ul',
    'ol',
    'li',
    'dl',
    'dt',
    'dd',
    'table',
    'tr',
    'th',
    'td',
    'thead',
    'tbody',
    'tfoot',
    'form',
    'fieldset',
    'legend',
    'address',
    'details',
    'summary',
  };

  return blockTags.contains(tag);
}

/// Clean extracted text by normalizing whitespace.
String cleanExtractedText(String text) {
  var result = text.replaceAll(RegExp(r'[ \t]*\n[ \t]*'), '\n');
  result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  result = result.replaceAll(RegExp(r'[ \t]{2,}'), ' ');

  final lines = result.split('\n').map((line) => line.trim());

  final cleanedLines = <String>[];
  var lastWasEmpty = false;
  for (final line in lines) {
    if (line.isEmpty) {
      if (!lastWasEmpty && cleanedLines.isNotEmpty) {
        cleanedLines.add('');
        lastWasEmpty = true;
      }
    } else {
      cleanedLines.add(line);
      lastWasEmpty = false;
    }
  }

  return cleanedLines.join('\n').trim();
}

/// Check if element is inside a note, tip, warning, or sidebar container.
bool isInsideNoteOrSidebar(dom.Element element) {
  dom.Node? current = element.parent;
  while (current != null) {
    final currentElement = current is dom.Element ? current : null;
    if (currentElement != null) {
      final dataType = currentElement.attributes['data-type']?.toLowerCase();
      if (dataType != null) {
        if (dataType == 'note' ||
            dataType == 'tip' ||
            dataType == 'warning' ||
            dataType == 'caution' ||
            dataType == 'important' ||
            dataType == 'sidebar') {
          return true;
        }
      }
      final epubType = currentElement.attributes['epub:type']?.toLowerCase();
      if (epubType != null) {
        if (epubType == 'note' ||
            epubType == 'tip' ||
            epubType == 'warning' ||
            epubType == 'sidebar') {
          return true;
        }
      }
      final className = currentElement.className.toLowerCase();
      if (className.contains('note') ||
          className.contains('tip') ||
          className.contains('warning') ||
          className.contains('sidebar') ||
          className.contains('callout') ||
          className.contains('admonition')) {
        return true;
      }
      if (currentElement.localName?.toLowerCase() == 'aside') {
        return true;
      }
    }
    current = current.parent;
  }
  return false;
}
