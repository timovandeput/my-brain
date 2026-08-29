import 'package:path/path.dart' as p;

import '../model.dart';
import 'frontmatter.dart';

/// The structure my-brain extracts from one markdown note.
class ParsedNote {
  final Frontmatter frontmatter;

  /// Body with the frontmatter block removed.
  final String body;

  /// `title` from frontmatter, else the first `# H1`, else the filename stem.
  final String title;

  /// `aliases` / `alias` from frontmatter, as written.
  final List<String> aliases;

  /// Heading texts in document order, leading and trailing hashes stripped.
  final List<String> headings;

  /// Every wikilink and embed outside code spans, in document order.
  final List<WikiLink> wikiLinks;

  /// Targets of inline `[text](target)` links that point at notes: relative
  /// paths only, never `http:`, `https:` or other schemes.
  final List<String> markdownLinks;

  /// Inline hashtags found outside code spans, marker stripped, lowercased.
  final List<String> inlineTags;

  /// Rough body word count, used to flag notes that have grown too large.
  final int wordCount;

  const ParsedNote({
    required this.frontmatter,
    required this.body,
    required this.title,
    required this.aliases,
    required this.headings,
    required this.wikiLinks,
    required this.markdownLinks,
    required this.inlineTags,
    required this.wordCount,
  });
}

/// A character range in a note body.
class Span {
  final int start;
  final int end;
  const Span(this.start, this.end);
  bool contains(int offset) => offset >= start && offset < end;
}

/// Parses one note.
///
/// [filename] is used only for the fallback title (its stem). Fenced code
/// blocks and inline code spans are excluded from link, tag and heading
/// detection: a wikilink inside a code sample is documentation, not a graph
/// edge, and rewriting it during a rename would corrupt the sample.
ParsedNote parseNote(String source, {required String filename}) {
  final frontmatter = parseFrontmatter(source);
  final body = source.substring(frontmatter.bodyOffset);
  final spans = codeSpans(body);

  final headingRecords = _extractHeadings(body, spans);
  final headings =
      headingRecords.map((_Heading h) => h.text).toList(growable: false);
  final firstH1 = headingRecords.where((_Heading h) => h.level == 1);

  final title = _extractTitle(
    frontmatter.data,
    firstH1.isEmpty ? null : firstH1.first.text,
    filename,
  );

  return ParsedNote(
    frontmatter: frontmatter,
    body: body,
    title: title,
    aliases: _extractAliases(frontmatter.data),
    headings: headings,
    wikiLinks: _extractWikiLinks(body, spans),
    markdownLinks: _extractMarkdownLinks(body, spans),
    inlineTags: _extractInlineTags(body, spans),
    wordCount: _wordCount(body),
  );
}

/// Character ranges of fenced blocks and inline code spans in [body].
///
/// Exposed because the link rewriter needs the same exclusion rule as the
/// parser; the two must never disagree about what counts as code.
List<Span> codeSpans(String body) {
  final lines = _mdLines(body).toList();
  final fenced = <Span>[];
  final fenceOpen = RegExp(r'^ {0,3}(`{3,}|~{3,})');

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final m = fenceOpen.firstMatch(line.content);
    if (m == null) {
      i++;
      continue;
    }
    final fence = m.group(1)!;
    final fenceChar = fence[0];
    final fenceLen = fence.length;
    final blockStart = line.start;
    var j = i + 1;
    var blockEnd = body.length;
    var closed = false;
    while (j < lines.length) {
      if (_isClosingFence(lines[j].content, fenceChar, fenceLen)) {
        blockEnd = lines[j].end;
        closed = true;
        j++;
        break;
      }
      j++;
    }
    if (!closed) {
      blockEnd = body.length;
      j = lines.length;
    }
    fenced.add(Span(blockStart, blockEnd));
    i = j;
  }

  final spans = <Span>[...fenced, ..._inlineCodeSpans(body, fenced)];
  spans.sort((Span a, Span b) => a.start.compareTo(b.start));
  return spans;
}

bool _isClosingFence(String content, String fenceChar, int fenceLen) {
  final pattern = RegExp(
    '^ {0,3}${RegExp.escape(fenceChar)}{$fenceLen,}\\s*\$',
  );
  return pattern.hasMatch(content);
}

final RegExp _backtickRun = RegExp('`+');

List<Span> _inlineCodeSpans(String body, List<Span> fenced) {
  final sortedFenced = [...fenced]..sort((Span a, Span b) => a.start.compareTo(b.start));
  final spans = <Span>[];
  var pos = 0;
  for (final f in sortedFenced) {
    spans.addAll(_inlineCodeInRange(body, pos, f.start));
    pos = f.end;
  }
  spans.addAll(_inlineCodeInRange(body, pos, body.length));
  return spans;
}

List<Span> _inlineCodeInRange(String body, int start, int end) {
  final spans = <Span>[];
  var i = start;
  while (i < end) {
    final m = _backtickRun.matchAsPrefix(body, i);
    if (m == null) {
      i++;
      continue;
    }
    final openLen = m.end - m.start;
    var j = m.end;
    int? closeEnd;
    while (j < end) {
      final m2 = _backtickRun.matchAsPrefix(body, j);
      if (m2 == null) {
        j++;
        continue;
      }
      final len2 = m2.end - m2.start;
      if (len2 == openLen) {
        closeEnd = m2.end;
        break;
      }
      j = m2.end;
    }
    if (closeEnd != null) {
      spans.add(Span(m.start, closeEnd));
      i = closeEnd;
    } else {
      i = m.end;
    }
  }
  return spans;
}

bool _inAnySpan(List<Span> spans, int offset) =>
    spans.any((Span s) => s.contains(offset));

class _MdLine {
  final String content;
  final int start;
  final int end;
  const _MdLine(this.content, this.start, this.end);
}

Iterable<_MdLine> _mdLines(String text) sync* {
  var start = 0;
  final n = text.length;
  while (start < n) {
    final nl = text.indexOf('\n', start);
    if (nl == -1) {
      yield _MdLine(text.substring(start), start, n);
      return;
    }
    var contentEnd = nl;
    if (contentEnd > start && text[contentEnd - 1] == '\r') {
      contentEnd -= 1;
    }
    yield _MdLine(text.substring(start, contentEnd), start, nl + 1);
    start = nl + 1;
  }
}

class _Heading {
  final int level;
  final String text;
  const _Heading(this.level, this.text);
}

// ATX headings only (`#` through `######` followed by a space). Setext
// headings (a line of text underlined with `===` or `---`) are not
// supported: they are visually ambiguous with a following horizontal rule
// and rare enough in practice not to be worth the extra parsing surface.
final RegExp _atxHeading = RegExp(r'^ {0,3}(#{1,6})(?:\s+(.*))?$');
final RegExp _trailingHashes = RegExp(r'\s+#+\s*$');

List<_Heading> _extractHeadings(String body, List<Span> spans) {
  final headings = <_Heading>[];
  for (final line in _mdLines(body)) {
    if (_inAnySpan(spans, line.start)) continue;
    final m = _atxHeading.firstMatch(line.content);
    if (m == null) continue;
    final level = m.group(1)!.length;
    var text = (m.group(2) ?? '').trim();
    text = text.replaceFirst(_trailingHashes, '').trim();
    headings.add(_Heading(level, text));
  }
  return headings;
}

final RegExp _wikiLink = RegExp(r'(!)?\[\[([^\[\]]*)\]\]');

List<WikiLink> _extractWikiLinks(String body, List<Span> spans) {
  final links = <WikiLink>[];
  for (final m in _wikiLink.allMatches(body)) {
    if (_inAnySpan(spans, m.start)) continue;
    final raw = m.group(2)!;
    final pipeIdx = raw.indexOf('|');
    final String withoutAlias;
    String? alias;
    if (pipeIdx >= 0) {
      withoutAlias = raw.substring(0, pipeIdx);
      alias = raw.substring(pipeIdx + 1);
    } else {
      withoutAlias = raw;
    }

    var anchorIdx = -1;
    for (var i = 0; i < withoutAlias.length; i++) {
      final c = withoutAlias[i];
      if (c == '#' || c == '^') {
        anchorIdx = i;
        break;
      }
    }
    final String target;
    String? anchor;
    if (anchorIdx >= 0) {
      target = withoutAlias.substring(0, anchorIdx);
      anchor = withoutAlias.substring(anchorIdx + 1);
    } else {
      target = withoutAlias;
    }

    links.add(WikiLink(
      target: target,
      anchor: anchor,
      alias: alias,
      start: m.start,
      end: m.end,
      embed: m.group(1) != null,
    ));
  }
  return links;
}

final RegExp _mdLink = RegExp(r'\[([^\[\]]*)\]\(([^()]*)\)');
final RegExp _uriScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:');

List<String> _extractMarkdownLinks(String body, List<Span> spans) {
  final links = <String>[];
  for (final m in _mdLink.allMatches(body)) {
    if (_inAnySpan(spans, m.start)) continue;
    var raw = m.group(2)!.trim();
    if (raw.isEmpty) continue;

    // Strip an optional "title" or 'title' after the target.
    final spaceIdx = raw.indexOf(RegExp(r'\s'));
    if (spaceIdx > 0) {
      final rest = raw.substring(spaceIdx).trim();
      if (rest.startsWith('"') || rest.startsWith("'")) {
        raw = raw.substring(0, spaceIdx);
      }
    }

    if (raw.length >= 2 && raw.startsWith('<') && raw.endsWith('>')) {
      raw = raw.substring(1, raw.length - 1);
    }
    if (raw.isEmpty) continue;

    if (_uriScheme.hasMatch(raw)) continue;
    if (raw.startsWith('//')) continue;
    if (raw.startsWith('#')) continue;

    var target = raw;
    try {
      target = Uri.decodeComponent(raw);
    } on FormatException {
      // Leave target as-is when it is not validly percent-encoded.
    }
    links.add(target);
  }
  return links;
}

// No leading `^`: used with matchAsPrefix at an arbitrary offset, where `^`
// would only ever match position 0 of the whole string, not the start index.
final RegExp _tagChars = RegExp(r'[A-Za-z0-9_/\-]+');
final RegExp _allDigits = RegExp(r'^[0-9]+$');

List<String> _extractInlineTags(String body, List<Span> spans) {
  final tags = <String>[];
  final n = body.length;
  var i = 0;
  while (i < n) {
    if (body[i] != '#') {
      i++;
      continue;
    }
    if (_inAnySpan(spans, i)) {
      i++;
      continue;
    }
    final prevOk = i == 0 || RegExp(r'\s').hasMatch(body[i - 1]);
    if (!prevOk) {
      i++;
      continue;
    }
    // ATX heading marker (`# `), not a tag.
    if (i + 1 < n && RegExp(r'[ \t]').hasMatch(body[i + 1])) {
      i++;
      continue;
    }
    final m = _tagChars.matchAsPrefix(body, i + 1);
    if (m == null) {
      i++;
      continue;
    }
    final content = m.group(0)!;
    if (!_allDigits.hasMatch(content)) {
      tags.add(content.toLowerCase());
    }
    i = m.end;
  }
  return tags;
}

Object? _lookupCI(Map<String, Object?> data, String key) {
  for (final entry in data.entries) {
    if (entry.key.toLowerCase() == key) return entry.value;
  }
  return null;
}

String? _scalarDisplay(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool || value is DateTime) {
    return value.toString();
  }
  return null;
}

String _extractTitle(
  Map<String, Object?> data,
  String? firstH1,
  String filename,
) {
  final fmTitle = _scalarDisplay(_lookupCI(data, 'title'));
  if (fmTitle != null && fmTitle.trim().isNotEmpty) return fmTitle.trim();
  if (firstH1 != null && firstH1.isNotEmpty) return firstH1;
  return p.basenameWithoutExtension(filename);
}

List<String> _extractAliases(Map<String, Object?> data) {
  final raw = _lookupCI(data, 'aliases') ?? _lookupCI(data, 'alias');
  if (raw == null) return const [];
  if (raw is List) {
    return raw
        .map((Object? e) => e.toString())
        .where((String s) => s.trim().isNotEmpty)
        .toList();
  }
  final s = raw.toString();
  return s.trim().isEmpty ? const [] : [s];
}

int _wordCount(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return 0;
  return trimmed.split(RegExp(r'\s+')).length;
}
