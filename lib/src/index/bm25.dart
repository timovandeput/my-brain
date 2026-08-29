import '../config.dart';
import '../model.dart';
import 'reader.dart';

/// Ranked retrieval over an [IndexReader].
///
/// Scoring is Okapi BM25 with the field weights already folded into the stored
/// term frequencies at build time, so a query is one pass over the postings of
/// its terms - no per-hit field arithmetic.
///
/// IDF uses the standard `ln(1 + (N - df + 0.5) / (df + 0.5))` form, which
/// stays positive for terms appearing in more than half the corpus; the raw
/// Robertson-Sparck Jones form goes negative there and lets a common term
/// actively push a document down the list.
class Searcher {
  final IndexReader reader;
  final BrainConfig config;

  const Searcher(this.reader, this.config);

  /// Runs [query] and returns hits ordered by descending score.
  ///
  /// Filters are applied as a document-id set before scoring, so a filtered
  /// search costs no more than an unfiltered one. Ties break on path, so
  /// repeated identical queries return identical ordering.
  Future<List<SearchHit>> search(SearchQuery query) => throw UnimplementedError();

  /// Notes most similar to [doc], for duplicate detection: the document's own
  /// highest-weight terms are used as the query, with the document itself
  /// removed from the results.
  Future<List<SearchHit>> similarTo(DocRecord doc, {int limit = 10}) =>
      throw UnimplementedError();
}

/// One BM25 term contribution, exposed for testing against hand-computed
/// values.
double bm25TermScore({
  required int tf,
  required int docFreq,
  required int docCount,
  required int docLength,
  required double avgDocLen,
  required double k1,
  required double b,
}) =>
    throw UnimplementedError();
