/// Shared data types used across scanning, indexing, searching and editing.
///
/// These types are the contract between modules; treat them as stable.
library;

/// A markdown file discovered by the vault scanner.
class ScannedFile {
  /// Vault-relative path, always using `/` separators.
  final String path;

  /// Absolute path on disk.
  final String absolutePath;

  /// Last modified time, milliseconds since epoch.
  final int mtimeMs;

  /// Size in bytes.
  final int size;

  const ScannedFile({
    required this.path,
    required this.absolutePath,
    required this.mtimeMs,
    required this.size,
  });
}

/// Which part of a note a token came from. Drives field weighting at index time.
enum Field { title, alias, heading, tag, body }

/// A single occurrence bucket: a term seen in a particular field.
class FieldTerm {
  final String term;
  final Field field;
  const FieldTerm(this.term, this.field);
}

/// A `[[wikilink]]` or `![[embed]]` occurrence in a note body.
class WikiLink {
  /// Target as written, before `#anchor` and `|alias` are split off.
  final String target;

  /// Heading anchor after `#`, or null.
  final String? anchor;

  /// Display alias after `|`, or null.
  final String? alias;

  /// Character offset of the opening `[` (or `!` for embeds) in the source.
  final int start;

  /// Character offset just past the closing `]]`.
  final int end;

  /// True for `![[...]]` transclusions.
  final bool embed;

  const WikiLink({
    required this.target,
    required this.start,
    required this.end,
    this.anchor,
    this.alias,
    this.embed = false,
  });
}

/// The per-document record persisted in the index and returned with search hits.
class DocRecord {
  final int docId;

  /// Vault-relative path with `/` separators.
  final String path;

  /// Display title: frontmatter `title`, else first `# H1`, else filename stem.
  final String title;

  /// Frontmatter `aliases` (or `alias`), as written.
  final List<String> aliases;

  /// All heading texts, in document order, `#` markers stripped.
  final List<String> headings;

  /// Resolved outgoing link targets as written (target only, no anchor/alias).
  final List<String> outLinks;

  /// Frontmatter `tags` plus inline hashtags, lowercased and sorted.
  ///
  /// Stored on the record, not just in the attribute index, so a search hit
  /// carries its own tags. The attribute index answers "which documents have
  /// this tag"; it cannot answer "what are this document's tags" without a
  /// scan, and an agent triaging results needs the latter.
  final List<String> tags;

  /// Token count of the whole document; the BM25 length normaliser.
  final int length;

  /// Approximate word count of the body, used to flag oversized notes.
  final int wordCount;

  final int mtimeMs;
  final int size;

  const DocRecord({
    required this.docId,
    required this.path,
    required this.title,
    required this.aliases,
    required this.headings,
    required this.outLinks,
    required this.tags,
    required this.length,
    required this.wordCount,
    required this.mtimeMs,
    required this.size,
  });
}

/// One entry of a term's postings list.
class Posting {
  final int docId;

  /// Field-weighted term frequency, rounded to an integer at index time.
  final int weightedTf;

  const Posting(this.docId, this.weightedTf);
}

/// A parsed search request.
class SearchQuery {
  /// Analyzed query terms (lowercased, stopped, stemmed).
  final List<String> terms;

  /// Frontmatter filters. Same key => OR of values; different keys => AND.
  final Map<String, List<String>> filters;

  /// Negative filters; a document matching any of these is excluded.
  final Map<String, List<String>> notFilters;

  /// Restrict to documents whose path starts with this vault-relative prefix.
  final String? pathPrefix;

  final int limit;

  const SearchQuery({
    required this.terms,
    this.filters = const {},
    this.notFilters = const {},
    this.pathPrefix,
    this.limit = 10,
  });
}

/// A scored search result.
class SearchHit {
  final DocRecord doc;
  final double score;

  /// Which query terms actually matched, for explainability.
  final List<String> matchedTerms;

  /// Body excerpt around the best match, populated on demand by the command
  /// layer (re-reads the file); null when snippets are disabled.
  final String? snippet;

  const SearchHit({
    required this.doc,
    required this.score,
    required this.matchedTerms,
    this.snippet,
  });

  SearchHit withSnippet(String? s) => SearchHit(
        doc: doc,
        score: score,
        matchedTerms: matchedTerms,
        snippet: s,
      );
}

/// Summary returned by an index build.
class IndexStats {
  final int docCount;
  final int termCount;
  final int postingCount;
  final int indexBytes;
  final Duration elapsed;

  const IndexStats({
    required this.docCount,
    required this.termCount,
    required this.postingCount,
    required this.indexBytes,
    required this.elapsed,
  });
}
