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
ParsedNote parseNote(String source, {required String filename}) =>
    throw UnimplementedError();

/// Character ranges of fenced blocks and inline code spans in [body].
///
/// Exposed because the link rewriter needs the same exclusion rule as the
/// parser; the two must never disagree about what counts as code.
List<Span> codeSpans(String body) => throw UnimplementedError();
