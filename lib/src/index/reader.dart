import 'dart:io';
import 'dart:typed_data';

import '../model.dart';
import 'format.dart';

/// Decoded term dictionary entry: everything except the postings bytes
/// themselves.
class _TermEntry {
  final String term;
  final int docFreq;
  final int postingsOffset;
  final int postingsByteLength;
  const _TermEntry(
    this.term,
    this.docFreq,
    this.postingsOffset,
    this.postingsByteLength,
  );
}

/// Fully decoded attribute entry, including its docId list.
class _AttrEntry {
  final String key;
  final List<int> docIds;
  const _AttrEntry(this.key, this.docIds);
}

Uint32List _readUint32List(Uint8List bytes, int count) {
  final result = Uint32List(count);
  final d = ByteData.sublistView(bytes);
  for (var i = 0; i < count; i++) {
    result[i] = d.getUint32(i * 4, Endian.little);
  }
  return result;
}

Uint64List _readUint64List(Uint8List bytes, int count) {
  final result = Uint64List(count);
  final d = ByteData.sublistView(bytes);
  for (var i = 0; i < count; i++) {
    result[i] = d.getUint64(i * 8, Endian.little);
  }
  return result;
}

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
  final RandomAccessFile _raf;
  final IndexHeader _header;
  final Uint32List _docLens;
  final Uint64List _docOffs;
  final Uint64List _termOffsets;
  bool _closed = false;

  IndexReader._(
    this._raf,
    this._header,
    this._docLens,
    this._docOffs,
    this._termOffsets,
  );

  /// Opens the index at [path].
  ///
  /// Throws [IndexFormatException] when the file is absent, truncated, or
  /// written by a build with a different [indexFormatVersion].
  static Future<IndexReader> open(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw IndexFormatException(
        'no index at $path - run `my-brain index`',
      );
    }
    final raf = await file.open();
    try {
      final headerBytes = await raf.read(indexHeaderSize);
      final header = IndexHeader.fromBytes(headerBytes);

      await raf.setPosition(header.docLensOffset);
      final docLensBytes = await raf.read(4 * header.docCount);
      final docLens = _readUint32List(docLensBytes, header.docCount);

      await raf.setPosition(header.docOffsOffset);
      final docOffsBytes = await raf.read(8 * header.docCount);
      final docOffs = _readUint64List(docOffsBytes, header.docCount);

      await raf.setPosition(header.termOffsetsOffset);
      final termOffsetsBytes = await raf.read(8 * header.termCount);
      final termOffsets = _readUint64List(termOffsetsBytes, header.termCount);

      return IndexReader._(raf, header, docLens, docOffs, termOffsets);
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  IndexHeader get header => _header;

  int get docCount => _header.docCount;

  double get avgDocLen => _header.avgDocLen;

  /// The scan signature the index was built from. Comparing it with a fresh
  /// scan tells us whether the index is stale.
  Uint8List get manifestHash => _header.manifestHash;

  /// Document length in tokens; the BM25 length normaliser. Served from the
  /// in-memory table, so this is cheap enough to call per candidate.
  int docLength(int docId) => _docLens[docId];

  void _ensureOpen() {
    if (_closed) {
      throw StateError('IndexReader is closed');
    }
  }

  /// Reads just the string field at [offset], growing the read buffer until
  /// it fits. Used for the binary-search comparison step on both the term
  /// and attribute dictionaries, which share the "string first" layout.
  Future<String> _readKeyAt(int offset) async {
    var chunkSize = 64;
    while (true) {
      await _raf.setPosition(offset);
      final buf = await _raf.read(chunkSize);
      try {
        return ByteCursor(buf).readString();
      } on RangeError {
        chunkSize *= 2;
      }
    }
  }

  Future<_TermEntry> _readTermEntryAt(int offset) async {
    var chunkSize = 64;
    while (true) {
      await _raf.setPosition(offset);
      final buf = await _raf.read(chunkSize);
      try {
        final cursor = ByteCursor(buf);
        final term = cursor.readString();
        final docFreq = cursor.readVarint();
        final d = ByteData.sublistView(buf, cursor.offset, cursor.offset + 8);
        final postingsOffset = d.getUint64(0, Endian.little);
        cursor.offset += 8;
        final postingsByteLength = cursor.readVarint();
        return _TermEntry(term, docFreq, postingsOffset, postingsByteLength);
      } on RangeError {
        chunkSize *= 2;
      }
    }
  }

  Future<_AttrEntry> _readAttrEntryAt(int offset) async {
    var chunkSize = 64;
    Uint8List buf;
    String key;
    int docFreq;
    int payloadLen;
    int headerEnd;
    while (true) {
      await _raf.setPosition(offset);
      buf = await _raf.read(chunkSize);
      try {
        final cursor = ByteCursor(buf);
        key = cursor.readString();
        docFreq = cursor.readVarint();
        payloadLen = cursor.readVarint();
        headerEnd = cursor.offset;
        break;
      } on RangeError {
        chunkSize *= 2;
      }
    }
    if (buf.length < headerEnd + payloadLen) {
      await _raf.setPosition(offset);
      buf = await _raf.read(headerEnd + payloadLen);
    }
    final cursor = ByteCursor(buf, headerEnd);
    final ids = List<int>.filled(docFreq, 0);
    var prev = -1;
    for (var i = 0; i < docFreq; i++) {
      prev += cursor.readVarint();
      ids[i] = prev;
    }
    return _AttrEntry(key, ids);
  }

  /// Binary searches the term dictionary, returning the matching entry or
  /// null.
  Future<_TermEntry?> _findTerm(String term) async {
    var lo = 0;
    var hi = _termOffsets.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final entry = await _readTermEntryAt(_termOffsets[mid]);
      final cmp = compareTermBytes(entry.term, term);
      if (cmp == 0) return entry;
      if (cmp < 0) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return null;
  }

  /// Binary searches the attribute dictionary by probing the offsets table
  /// directly on disk (it is never loaded into memory), returning the
  /// absolute offset of the matching entry or null.
  Future<int?> _findAttrOffset(String compositeKey) async {
    var lo = 0;
    var hi = _header.attrCount - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      await _raf.setPosition(_header.attrOffsetsOffset + mid * 8);
      final probeBytes = await _raf.read(8);
      final entryOffset =
          ByteData.sublistView(probeBytes).getUint64(0, Endian.little);
      final key = await _readKeyAt(entryOffset);
      final cmp = compareTermBytes(key, compositeKey);
      if (cmp == 0) return entryOffset;
      if (cmp < 0) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return null;
  }

  /// Postings for [term], ascending by docId. Empty when the term is unknown.
  Future<List<Posting>> postings(String term) async {
    _ensureOpen();
    final entry = await _findTerm(term);
    if (entry == null) return const [];
    await _raf.setPosition(entry.postingsOffset);
    final buf = await _raf.read(entry.postingsByteLength);
    final cursor = ByteCursor(buf);
    final result = <Posting>[];
    var prev = -1;
    for (var i = 0; i < entry.docFreq; i++) {
      prev += cursor.readVarint();
      final tf = cursor.readVarint();
      result.add(Posting(prev, tf));
    }
    return result;
  }

  /// Number of documents containing [term], read from the term dictionary
  /// without touching the postings region. Used for IDF.
  Future<int> docFrequency(String term) async {
    _ensureOpen();
    final entry = await _findTerm(term);
    return entry?.docFreq ?? 0;
  }

  DocRecord _decodeDocRecord(ByteCursor cursor, int docId) {
    final path = cursor.readString();
    final title = cursor.readString();
    final aliases = cursor.readStringList();
    final headings = cursor.readStringList();
    final outLinks = cursor.readStringList();
    final length = cursor.readVarint();
    final wordCount = cursor.readVarint();
    final mtimeMs = cursor.readVarint();
    final size = cursor.readVarint();
    return DocRecord(
      docId: docId,
      path: path,
      title: title,
      aliases: aliases,
      headings: headings,
      outLinks: outLinks,
      length: length,
      wordCount: wordCount,
      mtimeMs: mtimeMs,
      size: size,
    );
  }

  /// The full record for one document; one seek plus one read.
  Future<DocRecord> doc(int docId) async {
    _ensureOpen();
    final start = _docOffs[docId];
    final end =
        docId + 1 < docCount ? _docOffs[docId + 1] : _header.termOffsetsOffset;
    await _raf.setPosition(start);
    final buf = await _raf.read(end - start);
    return _decodeDocRecord(ByteCursor(buf), docId);
  }

  /// Every document record. Only for whole-vault work such as `doctor` and
  /// backlink resolution, never on the search path.
  Future<List<DocRecord>> allDocs() async {
    _ensureOpen();
    if (docCount == 0) return const [];
    final start = _docOffs[0];
    final end = _header.termOffsetsOffset;
    await _raf.setPosition(start);
    final buf = await _raf.read(end - start);
    final cursor = ByteCursor(buf);
    return List<DocRecord>.generate(
      docCount,
      (i) => _decodeDocRecord(cursor, i),
    );
  }

  /// Document ids carrying frontmatter `key: value`, ascending. Null when the
  /// pair was never indexed, which is different from an empty match.
  Future<List<int>?> attributeDocs(String key, String value) async {
    _ensureOpen();
    final composite = '${key.toLowerCase()}=${value.toLowerCase()}';
    final offset = await _findAttrOffset(composite);
    if (offset == null) return null;
    final entry = await _readAttrEntryAt(offset);
    return entry.docIds;
  }

  /// Distinct values indexed for [key], for `--filter` discoverability.
  ///
  /// Linear over the attribute region: only used for discoverability, not on
  /// the search path.
  Future<List<String>> attributeValues(String key) async {
    _ensureOpen();
    if (_header.attrCount == 0) return const [];
    final prefix = '${key.toLowerCase()}=';
    final start = _header.attrEntriesOffset;
    final end = await _raf.length();
    await _raf.setPosition(start);
    final buf = await _raf.read(end - start);
    final cursor = ByteCursor(buf);
    final values = <String>[];
    for (var i = 0; i < _header.attrCount; i++) {
      final composite = cursor.readString();
      cursor.readVarint(); // docFreq: part of the layout, unused here.
      final payloadLen = cursor.readVarint();
      cursor.offset += payloadLen;
      if (composite.startsWith(prefix)) {
        values.add(composite.substring(prefix.length));
      }
    }
    return values;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
  }
}
