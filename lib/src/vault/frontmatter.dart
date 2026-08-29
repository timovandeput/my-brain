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

  const Frontmatter({
    required this.data,
    required this.bodyOffset,
    required this.lineCount,
    required this.present,
    required this.malformed,
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
  Map<String, List<String>> flatten() => throw UnimplementedError();
}

/// Splits [source] at a leading `---` fenced YAML block.
///
/// The block must start on the very first line. A stray `---` later in the
/// document is a horizontal rule, not frontmatter.
Frontmatter parseFrontmatter(String source) => throw UnimplementedError();
