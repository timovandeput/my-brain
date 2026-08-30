import 'package:yaml/yaml.dart';

/// Result of splitting a note into YAML frontmatter and body.
class Frontmatter {
  /// Parsed YAML mapping. Empty when the note has no frontmatter, or when the
  /// frontmatter is malformed - a broken header must never lose us the body.
  final Map<String, Object?> data;

  /// Character offset in the source where the body starts (0 when absent).
  final int bodyOffset;

  /// Number of source lines the frontmatter block occupied, so body line
  /// numbers can be reported against the original file.
  final int lineCount;

  /// True when a `---` block was present, even if its YAML failed to parse.
  final bool present;

  /// True when a block was present but could not be parsed as a YAML mapping.
  final bool malformed;

  /// True when the frontmatter block contains `[[`.
  ///
  /// Reported because the link extractor only ever looks at the body: a
  /// wikilink written into frontmatter is not an edge in the link graph, so it
  /// is invisible to `links`, produces no backlink, and survives no `rename`
  /// of its target. `doctor` reports it for exactly that reason. Detected on
  /// the raw block text rather than on parsed values, so it is caught in a
  /// plain scalar, in a list item, and in a block that failed to parse alike.
  final bool hasWikiLink;

  const Frontmatter({
    required this.data,
    required this.bodyOffset,
    required this.lineCount,
    required this.present,
    required this.malformed,
    this.hasWikiLink = false,
  });

  static const Frontmatter none = Frontmatter(
    data: {},
    bodyOffset: 0,
    lineCount: 0,
    present: false,
    malformed: false,
  );

  /// Flattens frontmatter into lowercased `key -> values` pairs suitable for
  /// the attribute index. Scalars become a single value; lists of scalars
  /// become one value each; nested maps and lists of maps are skipped, since
  /// there is no sensible `key=value` filter for them.
  ///
  /// Values are lowercased and trimmed so `--filter Status=Draft` matches
  /// `status: draft`.
  Map<String, List<String>> flatten() {
    final result = <String, List<String>>{};
    for (final entry in data.entries) {
      final key = entry.key.toLowerCase().trim();
      if (key.isEmpty) continue;
      final values = _flattenValue(entry.value);
      if (values.isEmpty) continue;
      result[key] = values;
    }
    return result;
  }
}

/// Converts a scalar frontmatter value to its lowercased, trimmed string
/// form. Returns null for values that are not scalars we handle, or that are
/// empty after trimming.
String? _scalarString(Object? value) {
  if (value is String) {
    final s = value.trim().toLowerCase();
    return s.isEmpty ? null : s;
  }
  if (value is num || value is bool) {
    return value.toString().toLowerCase();
  }
  if (value is DateTime) {
    return value.toString().toLowerCase();
  }
  return null;
}

List<String> _flattenValue(Object? value) {
  if (value is Map) return const [];
  if (value is List) {
    // A list containing a map or another list has no sensible flattening.
    if (value.any((Object? e) => e is Map || e is List)) return const [];
    final out = <String>[];
    for (final e in value) {
      final s = _scalarString(e);
      if (s != null) out.add(s);
    }
    return out;
  }
  final s = _scalarString(value);
  return s == null ? const [] : [s];
}

/// Recursively converts YAML container types into plain Dart `Map`/`List`
/// so callers never see `package:yaml` types.
Object? _convertValue(Object? value) {
  if (value is YamlMap) return _convertMap(value);
  if (value is YamlList) return value.map(_convertValue).toList();
  return value;
}

Map<String, Object?> _convertMap(YamlMap map) => <String, Object?>{
      for (final entry in map.entries) entry.key.toString(): _convertValue(entry.value),
    };

/// One line of source text, with its content (EOL stripped) and the character
/// offset just past its line terminator (or the source length, for a final
/// line with no terminator). Handles both `\n` and `\r\n`.
class _Line {
  final String content;
  final int endOffset;
  const _Line(this.content, this.endOffset);
}

Iterable<_Line> _lines(String source) sync* {
  var start = 0;
  final n = source.length;
  while (start < n) {
    final nl = source.indexOf('\n', start);
    if (nl == -1) {
      yield _Line(source.substring(start), n);
      return;
    }
    var contentEnd = nl;
    if (contentEnd > start && source[contentEnd - 1] == '\r') {
      contentEnd -= 1;
    }
    yield _Line(source.substring(start, contentEnd), nl + 1);
    start = nl + 1;
  }
}

/// Splits [source] at a leading `---` fenced YAML block.
///
/// The block must start on the very first line. A stray `---` later in the
/// document is a horizontal rule, not frontmatter.
Frontmatter parseFrontmatter(String source) {
  if (source.isEmpty) return Frontmatter.none;

  final lines = _lines(source).toList();
  if (lines.isEmpty || lines.first.content != '---') return Frontmatter.none;

  var closeIndex = -1;
  for (var i = 1; i < lines.length; i++) {
    final content = lines[i].content;
    if (content == '---' || content == '...') {
      closeIndex = i;
      break;
    }
  }

  if (closeIndex == -1) {
    // No terminator found before EOF: the header is broken. Treat everything
    // after the opening line as body so a broken header never costs us the
    // rest of the note.
    return Frontmatter(
      data: const {},
      bodyOffset: lines.first.endOffset,
      lineCount: 1,
      present: true,
      malformed: true,
    );
  }

  final yamlSource =
      lines.sublist(1, closeIndex).map((_Line l) => l.content).join('\n');
  final bodyOffset = lines[closeIndex].endOffset;
  final lineCount = closeIndex + 1;

  var malformed = false;
  var data = const <String, Object?>{};
  try {
    final doc = loadYaml(yamlSource);
    if (doc == null) {
      data = const {};
    } else if (doc is YamlMap) {
      data = _convertMap(doc);
    } else {
      malformed = true;
    }
  } on YamlException {
    malformed = true;
  } on FormatException {
    malformed = true;
  }

  return Frontmatter(
    data: malformed ? const {} : data,
    bodyOffset: bodyOffset,
    lineCount: lineCount,
    present: true,
    malformed: malformed,
    hasWikiLink: yamlSource.contains('[['),
  );
}
