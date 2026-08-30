import '../model.dart';
import '../vault/markdown.dart';
import 'stemmer.dart';
import 'stopwords.dart';

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
  ///
  /// `snake_case` splits for free: `_` is not a letter or digit, so it never
  /// joins two runs together. `camelCase` and digit/letter boundaries within
  /// one run are detected explicitly; when found, both the whole run and its
  /// parts are emitted.
  Iterable<String> split(String text) sync* {
    for (final match in _wordRun.allMatches(text)) {
      final run = match.group(0)!;
      final parts = _splitRun(run);
      yield run.toLowerCase();
      if (parts.length > 1) {
        for (final part in parts) {
          yield part.toLowerCase();
        }
      }
    }
  }

  /// Full pipeline: [split], then stopword removal, then stemming.
  ///
  /// Used for both document bodies and user queries.
  List<String> analyze(String text) {
    final result = <String>[];
    for (final token in split(text)) {
      if (token.length < minLength) continue;
      if (dropStopwords && englishStopwords.contains(token)) continue;
      result.add(stem ? porterStem(token) : token);
    }
    return result;
  }
}

final RegExp _wordRun = RegExp(r'[\p{L}\p{N}]+', unicode: true);

bool _isUpper(String ch) => ch != ch.toLowerCase() && ch == ch.toUpperCase();
bool _isLower(String ch) => ch != ch.toUpperCase() && ch == ch.toLowerCase();
bool _isDigit(String ch) => RegExp(r'\p{N}', unicode: true).hasMatch(ch);

/// Splits one letter/digit run into camelCase / PascalCase / digit-letter
/// parts. Returns `[run]` unchanged when there is no internal boundary.
List<String> _splitRun(String run) {
  final chars = run.split('');
  final n = chars.length;
  final boundaries = <int>[];
  for (var i = 1; i < n; i++) {
    final prev = chars[i - 1];
    final curr = chars[i];
    final prevUpper = _isUpper(prev);
    final currUpper = _isUpper(curr);
    final prevDigit = _isDigit(prev);
    final currDigit = _isDigit(curr);
    var boundary = false;
    if (!prevUpper && !prevDigit && currUpper) {
      // lower -> upper: camelCase / PascalCase boundary.
      boundary = true;
    } else if (prevDigit != currDigit) {
      // letter <-> digit boundary.
      boundary = true;
    } else if (prevUpper && currUpper && i + 1 < n && _isLower(chars[i + 1])) {
      // acronym followed by a capitalised word, e.g. HTMLParser -> HTML|Parser.
      boundary = true;
    }
    if (boundary) boundaries.add(i);
  }
  if (boundaries.isEmpty) return [run];
  final parts = <String>[];
  var start = 0;
  for (final b in boundaries) {
    parts.add(run.substring(start, b));
    start = b;
  }
  parts.add(run.substring(start));
  return parts;
}

/// Produces the field-tagged term stream for one note, which the index builder
/// collapses into weighted term frequencies.
///
/// Title, aliases, headings and tags are emitted as their own fields so a note
/// *about* a subject outranks one that merely mentions it. Tags come from both
/// frontmatter and inline hashtags.
Iterable<FieldTerm> noteTerms(ParsedNote note, Analyzer analyzer) sync* {
  for (final term in analyzer.analyze(note.title)) {
    yield FieldTerm(term, Field.title);
  }
  for (final alias in note.aliases) {
    for (final term in analyzer.analyze(alias)) {
      yield FieldTerm(term, Field.alias);
    }
  }
  for (final heading in note.headings) {
    for (final term in analyzer.analyze(heading)) {
      yield FieldTerm(term, Field.heading);
    }
  }

  final flat = note.frontmatter.flatten();
  final tags = <String>{
    ...?flat['tags'],
    ...?flat['tag'],
    ...note.inlineTags,
  };
  for (final tag in tags) {
    final whole = tag.trim().toLowerCase();
    if (whole.isEmpty) continue;
    if (whole.contains('/')) {
      // Keep the whole hierarchical tag as one literal term, in addition to
      // its analyzed parts, so `tag:project/alpha` can match exactly.
      yield FieldTerm(whole, Field.tag);
      for (final part in whole.split('/')) {
        for (final term in analyzer.analyze(part)) {
          yield FieldTerm(term, Field.tag);
        }
      }
    } else {
      for (final term in analyzer.analyze(whole)) {
        yield FieldTerm(term, Field.tag);
      }
    }
  }

  for (final term in analyzer.analyze(note.body)) {
    yield FieldTerm(term, Field.body);
  }
}
