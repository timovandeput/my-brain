import 'dart:typed_data';

import '../model.dart';
import 'format.dart';

/// Random-access reader over `.brain/index.bin`.
///
/// [open] loads only the header and the three small fixed tables (doc lengths,
/// doc offsets, term offsets); postings, document records and attribute lists
/// are seeked to on demand. That is what keeps a cold search on a vault of
/// thousands of notes in the tens of milliseconds: the process never pays to
/// deserialise the whole index.
///
/// Not safe for concurrent use: one [RandomAccessFile] cursor is shared.
class IndexReader {
  /// Opens the index at [path].
  ///
  /// Throws [IndexFormatException] when the file is absent, truncated, or
  /// written by a build with a different [indexFormatVersion].
  static Future<IndexReader> open(String path) => throw UnimplementedError();

  IndexHeader get header => throw UnimplementedError();

  int get docCount => throw UnimplementedError();

  double get avgDocLen => throw UnimplementedError();

  /// The scan signature the index was built from. Comparing it with a fresh
  /// scan tells us whether the index is stale.
  Uint8List get manifestHash => throw UnimplementedError();

  /// Document length in tokens; the BM25 length normaliser. Served from the
  /// in-memory table, so this is cheap enough to call per candidate.
  int docLength(int docId) => throw UnimplementedError();

  /// Postings for [term], ascending by docId. Empty when the term is unknown.
  Future<List<Posting>> postings(String term) => throw UnimplementedError();

  /// Number of documents containing [term], read from the term dictionary
  /// without touching the postings region. Used for IDF.
  Future<int> docFrequency(String term) => throw UnimplementedError();

  /// The full record for one document; one seek plus one read.
  Future<DocRecord> doc(int docId) => throw UnimplementedError();

  /// Every document record. Only for whole-vault work such as `doctor` and
  /// backlink resolution, never on the search path.
  Future<List<DocRecord>> allDocs() => throw UnimplementedError();

  /// Document ids carrying frontmatter `key: value`, ascending. Null when the
  /// pair was never indexed, which is different from an empty match.
  Future<List<int>?> attributeDocs(String key, String value) =>
      throw UnimplementedError();

  /// Distinct values indexed for [key], for `--filter` discoverability.
  Future<List<String>> attributeValues(String key) => throw UnimplementedError();

  Future<void> close() => throw UnimplementedError();
}
