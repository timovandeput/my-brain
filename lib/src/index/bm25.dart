import 'dart:io';
import 'dart:math' as math;

import 'package:collection/collection.dart' show PriorityQueue;
import 'package:path/path.dart' as p;

import '../config.dart';
import '../model.dart';
import '../text/tokenizer.dart';
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
  Future<List<SearchHit>> search(SearchQuery query) async {
    // Positive filters: same key ORs its values (union), different keys AND
    // (intersect). A value that was never indexed contributes nothing to its
    // key's union - if that leaves a key's union empty, the whole filter set
    // is unsatisfiable and we return no results, distinct from "no filter".
    Set<int>? allowed;
    var alwaysEmpty = false;
    for (final entry in query.filters.entries) {
      final keySet = <int>{};
      for (final value in entry.value) {
        final docs = await reader.attributeDocs(entry.key, value);
        if (docs != null) keySet.addAll(docs);
      }
      allowed = allowed == null ? keySet : allowed.intersection(keySet);
    }
    if (query.filters.isNotEmpty && (allowed?.isEmpty ?? false)) {
      alwaysEmpty = true;
    }

    // Negative filters: a document matching any key/value pair is excluded,
    // regardless of which key it came from.
    Set<int>? excluded;
    for (final entry in query.notFilters.entries) {
      for (final value in entry.value) {
        final docs = await reader.attributeDocs(entry.key, value);
        if (docs != null) {
          (excluded ??= <int>{}).addAll(docs);
        }
      }
    }

    // pathPrefix is the one O(N) path in this method - it needs every
    // document's path, so it is opt-in and only paid for when supplied.
    if (!alwaysEmpty && query.pathPrefix != null) {
      final prefix = query.pathPrefix!;
      final all = await reader.allDocs();
      final prefixSet = <int>{
        for (final d in all)
          if (d.path.startsWith(prefix)) d.docId,
      };
      allowed = allowed == null ? prefixSet : allowed.intersection(prefixSet);
      if (allowed.isEmpty) alwaysEmpty = true;
    }

    if (alwaysEmpty) return const [];

    final scores = <int, double>{};
    final matched = <int, List<String>>{};
    final docCount = reader.docCount;
    final avgDocLen = reader.avgDocLen;

    for (final term in query.terms.toSet()) {
      final termPostings = await reader.postings(term);
      if (termPostings.isEmpty) continue;
      final docFreq = termPostings.length;
      for (final posting in termPostings) {
        final docId = posting.docId;
        if (allowed != null && !allowed.contains(docId)) continue;
        if (excluded != null && excluded.contains(docId)) continue;
        final s = bm25TermScore(
          tf: posting.weightedTf,
          docFreq: docFreq,
          docCount: docCount,
          docLength: reader.docLength(docId),
          avgDocLen: avgDocLen,
          k1: config.k1,
          b: config.b,
        );
        scores.update(docId, (v) => v + s, ifAbsent: () => s);
        (matched[docId] ??= <String>[]).add(term);
      }
    }

    if (scores.isEmpty) return const [];

    // Bounded top-limit selection: a min-heap ordered "worst kept first" so
    // that once it holds `limit` candidates, anything worse than the current
    // worst is rejected in O(log limit) instead of sorting every candidate.
    // Ties use docId ascending here only to keep selection deterministic;
    // docId order matches path order because the writer preserves manifest
    // order (itself path-sorted) as docId - but the final output below still
    // re-sorts on the real `doc.path`, so correctness never depends on that
    // assumption.
    int cmpBest(MapEntry<int, double> a, MapEntry<int, double> b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    }

    final heap = PriorityQueue<MapEntry<int, double>>(
      (a, b) => -cmpBest(a, b),
    );
    for (final entry in scores.entries) {
      heap.add(entry);
      if (heap.length > query.limit) heap.removeFirst();
    }
    final top = heap.toList()..sort(cmpBest);

    final hits = <SearchHit>[];
    for (final entry in top) {
      final docRecord = await reader.doc(entry.key);
      hits.add(SearchHit(
        doc: docRecord,
        score: entry.value,
        matchedTerms: List<String>.of(matched[entry.key] ?? const []),
      ));
    }
    hits.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.doc.path.compareTo(b.doc.path);
    });
    return hits;
  }

  /// Notes most similar to [doc], for duplicate detection: the document's own
  /// highest-weight terms are used as the query, with the document itself
  /// removed from the results.
  Future<List<SearchHit>> similarTo(DocRecord doc, {int limit = 10}) async {
    final file = File(p.join(config.vaultRoot, doc.path));
    if (!file.existsSync()) return const [];
    final source = await file.readAsString();

    const analyzer = Analyzer();
    final tokens = analyzer.analyze(source);
    if (tokens.isEmpty) return const [];

    final termFrequency = <String, int>{};
    for (final token in tokens) {
      termFrequency[token] = (termFrequency[token] ?? 0) + 1;
    }

    final docCount = reader.docCount;
    final scored = <MapEntry<String, double>>[];
    for (final entry in termFrequency.entries) {
      final docFreq = await reader.docFrequency(entry.key);
      final idf = math.log(1 + (docCount - docFreq + 0.5) / (docFreq + 0.5));
      scored.add(MapEntry(entry.key, entry.value * idf));
    }
    scored.sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });

    final queryTerms = scored.take(20).map((e) => e.key).toList();
    if (queryTerms.isEmpty) return const [];

    final hits = await search(SearchQuery(terms: queryTerms, limit: limit + 1));
    return hits.where((h) => h.doc.path != doc.path).take(limit).toList();
  }
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
}) {
  final idf = math.log(1 + (docCount - docFreq + 0.5) / (docFreq + 0.5));
  final lengthNorm =
      avgDocLen <= 0 ? 1.0 : (1 - b + b * docLength / avgDocLen);
  return idf * (tf * (k1 + 1)) / (tf + k1 * lengthNorm);
}
