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

  /// Every inline `[text](target)` link that points at a note, with offsets.
  ///
  /// Excludes `http:`/`https:`/other-scheme targets, protocol-relative and
  /// pure-fragment targets, image embeds (`![alt](src)`, never a note edge),
  /// and targets with a non-markdown extension (attachments, e.g. images or
  /// PDFs) - only an extensionless target or one ending in `.md`/`.markdown`
  /// counts as pointing at a note.
  final List<MarkdownLink> markdownLinkSpans;

  /// Targets of [markdownLinkSpans], in document order. Kept for callers that
  /// only need the target strings, not the offsets.
  List<String> get markdownLinks =>
      [for (final l in markdownLinkSpans) l.target];

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
    required this.markdownLinkSpans,
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

/// An inline `[text](target)` occurrence in a note body that points at a note
/// (see [ParsedNote.markdownLinkSpans]).
class MarkdownLink {
  /// Target as resolved: percent-decoded, title/whitespace/angle-brackets
  /// stripped.
  final String target;

  /// Character offset of the opening `[` in the source.
  final int start;

  /// Character offset just past the closing `)`.
  final int end;

  /// Offsets of the link's display text, i.e. the `text` in `[text](...)`,
  /// used to replace the whole link with plain text on delete.
  final int textStart;
  final int textEnd;

  /// Offsets of the raw target substring inside the parens - excludes any
  /// optional title and surrounding `<...>` - used to rewrite just the target
  /// on rename while preserving everything else about the link as written.
  final int targetStart;
  final int targetEnd;

  const MarkdownLink({
    required this.target,
    required this.start,
    required this.end,
    required this.textStart,
    required this.textEnd,
    required this.targetStart,
    required this.targetEnd,
  });
}

/// Parses one note.
///
/// [filename] is used only for the fallback title (its stem). Fenced code
/// blocks, indented code blocks and inline code spans are excluded from
/// link, tag and heading detection: a wikilink inside a code sample is
/// documentation, not a graph edge, and rewriting it during a rename would
/// corrupt the sample.
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
    markdownLinkSpans: _extractMarkdownLinkSpans(body, spans),
    inlineTags: _extractInlineTags(body, spans),
    wordCount: _wordCount(body),
  );
}

/// Character ranges of fenced blocks, indented code blocks and inline code
/// spans in [body].
///
/// An indented block is a line indented 4+ spaces, not a list-item
/// continuation, preceded by a blank line; it runs through further blank and
/// 4+-space-indented lines and ends at the first non-blank line indented
/// less than that (CommonMark's rule, with list-continuation handling
/// simplified to "was a list marker seen since the last dedent").
///
/// Exposed because the link rewriter needs the same exclusion rule as the
/// parser; the two must never disagree about what counts as code.
List<Span> codeSpans(String body) {
  final lines = _mdLines(body).toList();
  final blockSpans = <Span>[];
  final fenceOpen = RegExp(r'^ {0,3}(`{3,}|~{3,})');

  // Tracks whether the most recently *processed* line looked like a list
  // item (or blank content belonging to one), so a 4-space-indented line
  // that is really list-item continuation is not mistaken for an indented
  // code block - only a genuinely dedented block start should count.
  var insideList = false;
  // Whether the most recently processed line was blank: an indented code
  // block may only start right after one (it cannot interrupt a paragraph).
  var prevBlank = true;

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final content = line.content;
    final isBlank = content.trim().isEmpty;

    final fenceMatch = fenceOpen.firstMatch(content);
    if (fenceMatch != null) {
      final fence = fenceMatch.group(1)!;
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
      blockSpans.add(Span(blockStart, blockEnd));
      i = j;
      prevBlank = false;
      continue;
    }

    final indent = _leadingSpaces.firstMatch(content)!.group(0)!.length;
    if (!isBlank && indent >= 4 && prevBlank && !insideList) {
      // An indented code block: runs through blank lines and further
      // 4+-space-indented lines, and ends at the first non-blank line
      // indented less than that.
      final blockStart = line.start;
      var blockEnd = line.end;
      var j = i + 1;
      while (j < lines.length) {
        final l = lines[j];
        final lBlank = l.content.trim().isEmpty;
        final lIndent = _leadingSpaces.firstMatch(l.content)!.group(0)!.length;
        if (lBlank || lIndent >= 4) {
          blockEnd = l.end;
          j++;
          continue;
        }
        break;
      }
      blockSpans.add(Span(blockStart, blockEnd));
      i = j;
      prevBlank = false;
      continue;
    }

    if (_listMarker.hasMatch(content)) {
      insideList = true;
    } else if (!isBlank && indent < 4) {
      insideList = false;
    }
    prevBlank = isBlank;
    i++;
  }

  final spans = <Span>[...blockSpans, ..._inlineCodeSpans(body, blockSpans)];
  spans.sort((Span a, Span b) => a.start.compareTo(b.start));
  return spans;
}

final RegExp _leadingSpaces = RegExp(r'^ *');
final RegExp _listMarker = RegExp(r'^ {0,3}(?:[-*+]|\d{1,9}[.)]) +\S');

bool _isClosingFence(String content, String fenceChar, int fenceLen) {
  final pattern = RegExp(
    '^ {0,3}${RegExp.escape(fenceChar)}{$fenceLen,}\\s*\$',
  );
  return pattern.hasMatch(content);
}

final RegExp _backtickRun = RegExp('`+');

List<Span> _inlineCodeSpans(String body, List<Span> fenced) {
  final sortedFenced = [...fenced]
    ..sort((Span a, Span b) => a.start.compareTo(b.start));
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

// Optional leading `!` marks an image embed: never a note edge.
final RegExp _mdLink = RegExp(r'(!)?\[([^\[\]]*)\]\(([^()]*)\)');
final RegExp _uriScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:');
final RegExp _wsChar = RegExp(r'\s');
const Set<String> _noteExtensions = {'.md', '.markdown'};

List<MarkdownLink> _extractMarkdownLinkSpans(String body, List<Span> spans) {
  final links = <MarkdownLink>[];
  for (final m in _mdLink.allMatches(body)) {
    if (_inAnySpan(spans, m.start)) continue;
    if (m.group(1) != null) continue; // image embed, never a note edge.

    // `Match` only exposes whole-match offsets, not per-group ones, so the
    // group offsets are derived from the fixed literal characters the regex
    // guarantees between them (`[`, `]`, `(`, `)`) plus each group's length.
    final text = m.group(2)!;
    final rawContent = m.group(3)!;
    final textStart = m.start + 1; // just past the opening `[`.
    final textEnd = textStart + text.length;
    final parenStart = textEnd + 2; // past the `](`.
    final parenEnd = parenStart + rawContent.length;

    final target = _parseLinkTarget(body, parenStart, parenEnd);
    if (target == null) continue;

    final raw = body.substring(target.start, target.end);
    if (_uriScheme.hasMatch(raw)) continue;
    if (raw.startsWith('//')) continue;
    if (raw.startsWith('#')) continue;

    var decoded = raw;
    try {
      decoded = Uri.decodeComponent(raw);
    } on FormatException {
      // Leave target as-is when it is not validly percent-encoded.
    }

    final ext = p.extension(decoded).toLowerCase();
    if (ext.isNotEmpty && !_noteExtensions.contains(ext)) {
      continue; // an attachment (image, pdf, ...), not a note edge.
    }

    links.add(MarkdownLink(
      target: decoded,
      start: m.start,
      end: m.end,
      textStart: textStart,
      textEnd: textEnd,
      targetStart: target.start,
      targetEnd: target.end,
    ));
  }
  return links;
}

/// Locates the raw target substring within a markdown link's `(...)` content
/// - `[start, parenEnd)` from the regex - stripping surrounding whitespace,
/// an optional `"title"`/`'title'`, and `<...>` wrapping, without altering
/// the text in between. Returns null when nothing is left once punctuation is
/// stripped (a same-file `()`  or an all-whitespace target).
({int start, int end})? _parseLinkTarget(
    String body, int parenStart, int parenEnd) {
  var start = parenStart;
  var end = parenEnd;
  while (start < end && _wsChar.hasMatch(body[start])) {
    start++;
  }
  while (end > start && _wsChar.hasMatch(body[end - 1])) {
    end--;
  }
  if (start == end) return null;

  var spaceIdx = -1;
  for (var i = start; i < end; i++) {
    if (_wsChar.hasMatch(body[i])) {
      spaceIdx = i;
      break;
    }
  }
  if (spaceIdx > start) {
    var rest = spaceIdx;
    while (rest < end && _wsChar.hasMatch(body[rest])) {
      rest++;
    }
    if (rest < end && (body[rest] == '"' || body[rest] == "'")) {
      end = spaceIdx;
    }
  }
  if (start == end) return null;

  if (end - start >= 2 && body[start] == '<' && body[end - 1] == '>') {
    start += 1;
    end -= 1;
  }
  if (start == end) return null;

  return (start: start, end: end);
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
