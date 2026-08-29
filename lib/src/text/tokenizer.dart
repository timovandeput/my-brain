import '../model.dart';
import '../vault/markdown.dart';

/// Turns note text into the terms that go into the index.
///
/// The same analyzer must run at index time and at query time, otherwise a
/// query term will never match its indexed form. There is exactly one
/// configured instance per process for that reason.
class Analyzer {
  /// Tokens shorter than this are dropped. Two keeps `ai`, `go`, `id`.
  final int minLength;

  /// Apply the Porter stemmer, so `meetings` matches `meeting`.
  final bool stem;

  /// Drop English stopwords.
  final bool dropStopwords;

  const Analyzer({
    this.minLength = 2,
    this.stem = true,
    this.dropStopwords = true,
  });

  /// Splits [text] into normalised, unstemmed tokens: lowercased, Unicode
  /// letters and digits only, with `camelCase` and `snake_case` identifiers
  /// also emitted as their parts so `parseFrontmatter` is findable as
  /// `parse` + `frontmatter` as well as whole.
  Iterable<String> split(String text) => throw UnimplementedError();

  /// Full pipeline: [split], then stopword removal, then stemming.
  ///
  /// Used for both document bodies and user queries.
  List<String> analyze(String text) => throw UnimplementedError();
}

/// Produces the field-tagged term stream for one note, which the index builder
/// collapses into weighted term frequencies.
///
/// Title, aliases, headings and tags are emitted as their own fields so a note
/// *about* a subject outranks one that merely mentions it. Tags come from both
/// frontmatter and inline hashtags.
Iterable<FieldTerm> noteTerms(ParsedNote note, Analyzer analyzer) =>
    throw UnimplementedError();
