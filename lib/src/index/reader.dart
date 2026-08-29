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

/// Reads exactly [length] bytes at the file's current position.
///
/// `RandomAccessFile.read` short-reads silently when the file ends before
/// [length] bytes are available - the normal shape of a truncated or
/// otherwise corrupt index - so every fixed-size region read in this file
/// goes through here rather than trusting the returned buffer's length.
Future<Uint8List> _readExact(
  RandomAccessFile raf,
  int length,
  String what,
) async {
  final buf = await raf.read(length);
  if (buf.length != length) {
    throw IndexFormatException(
      'index file is truncated (short read of $what) - run `my-brain index`',
    );
  }
  return buf;
}

/// Runs [decode] and turns a [RangeError] - reading past the end of a
/// buffer that was sized correctly for a well-formed index but whose
/// *content* (a varint length, a doc-id count, ...) is corrupt - into an
/// [IndexFormatException] instead of letting it escape as an [Error].
T _decodeChecked<T>(T Function() decode, String what) {
  try {
    return decode();
  } on RangeError {
    throw IndexFormatException(
      'index file is corrupt (truncated $what) - run `my-brain index`',
    );
  }
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
  final int _fileLength;
  final Uint32List _docLens;
  final Uint64List _docOffs;
  final Uint64List _termOffsets;
  bool _closed = false;

  IndexReader._(
    this._raf,
    this._header,
    this._fileLength,
    this._docLens,
    this._docOffs,
    this._termOffsets,
  );

  /// Opens the index at [path].
  ///
  /// Throws [IndexFormatException] when the file is absent, truncated,
  /// corrupt (region offsets or counts that do not fit the file), or
  /// written by a build with a different [indexFormatVersion]. Never lets a
  /// malformed file escape as a [RangeError] or other [Error].
  static Future<IndexReader> open(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw IndexFormatException(
        'no index at $path - run `my-brain index`',
      );
    }
    final raf = await file.open();
    try {
      final fileLength = await raf.length();
      final headerBytes = await _readExact(raf, indexHeaderSize, 'header');
      final header = IndexHeader.fromBytes(headerBytes);
      header.validate(fileLength);

      await raf.setPosition(header.docLensOffset);
      final docLensBytes =
          await _readExact(raf, 4 * header.docCount, 'doc lengths table');
      final docLens = _readUint32List(docLensBytes, header.docCount);

      await raf.setPosition(header.docOffsOffset);
      final docOffsBytes =
          await _readExact(raf, 8 * header.docCount, 'doc offsets table');
      final docOffs = _readUint64List(docOffsBytes, header.docCount);

      await raf.setPosition(header.termOffsetsOffset);
      final termOffsetsBytes =
          await _readExact(raf, 8 * header.termCount, 'term offsets table');
      final termOffsets = _readUint64List(termOffsetsBytes, header.termCount);

      return IndexReader._(
          raf, header, fileLength, docLens, docOffs, termOffsets);
    } on RangeError {
      await raf.close();
      throw const IndexFormatException(
        'index file is corrupt - run `my-brain index`',
      );
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

  /// Bytes available to read starting at [offset], given the real file
  /// length recorded at [open]. Every growing-chunk read below caps its
  /// request at this, so an offset that is corrupt or points past a
  /// truncated file fails fast with [IndexFormatException] instead of the
  /// chunk size doubling forever - which is what used to surface as an
  /// OS-level "read failed ... errno = 22".
  int _remaining(int offset) {
    final remaining = _fileLength - offset;
    if (remaining <= 0) {
      throw const IndexFormatException(
        'index file is corrupt (entry offset beyond end of file) - '
        'run `my-brain index`',
      );
    }
    return remaining;
  }

  /// Reads just the string field at [offset], growing the read buffer until
  /// it fits, but never past [_remaining]. Used for the binary-search
  /// comparison step on both the term and attribute dictionaries, which
  /// share the "string first" layout.
  Future<String> _readKeyAt(int offset) async {
    final maxChunk = _remaining(offset);
    var chunkSize = 64;
    while (true) {
      final capped = chunkSize < maxChunk ? chunkSize : maxChunk;
      await _raf.setPosition(offset);
      final buf = await _raf.read(capped);
      try {
        return ByteCursor(buf).readString();
      } on RangeError {
        if (capped >= maxChunk) {
          throw const IndexFormatException(
            'index file is corrupt (truncated dictionary entry) - '
            'run `my-brain index`',
          );
        }
        chunkSize *= 2;
      }
    }
  }

  Future<_TermEntry> _readTermEntryAt(int offset) async {
    final maxChunk = _remaining(offset);
    var chunkSize = 64;
    while (true) {
      final capped = chunkSize < maxChunk ? chunkSize : maxChunk;
      await _raf.setPosition(offset);
      final buf = await _raf.read(capped);
      try {
        final cursor = ByteCursor(buf);
        final term = cursor.readString();
        final docFreq = cursor.readVarint();
        final d = ByteData.sublistView(buf, cursor.offset, cursor.offset + 8);
        final postingsOffset = d.getUint64(0, Endian.little);
        cursor.offset += 8;
        final postingsByteLength = cursor.readVarint();
        if (docFreq < 0 || docFreq > _header.docCount) {
          throw const IndexFormatException(
            'index file is corrupt (term docFreq exceeds docCount) - '
            'run `my-brain index`',
          );
        }
        return _TermEntry(term, docFreq, postingsOffset, postingsByteLength);
      } on RangeError {
        if (capped >= maxChunk) {
          throw const IndexFormatException(
            'index file is corrupt (truncated term entry) - '
            'run `my-brain index`',
          );
        }
        chunkSize *= 2;
      }
    }
  }

  Future<_AttrEntry> _readAttrEntryAt(int offset) async {
    final maxChunk = _remaining(offset);
    var chunkSize = 64;
    Uint8List buf;
    String key;
    int docFreq;
    int payloadLen;
    int headerEnd;
    while (true) {
      final capped = chunkSize < maxChunk ? chunkSize : maxChunk;
      await _raf.setPosition(offset);
      buf = await _raf.read(capped);
      try {
        final cursor = ByteCursor(buf);
        key = cursor.readString();
        docFreq = cursor.readVarint();
        payloadLen = cursor.readVarint();
        headerEnd = cursor.offset;
        if (docFreq < 0 || docFreq > _header.docCount) {
          throw const IndexFormatException(
            'index file is corrupt (attribute docFreq exceeds docCount) - '
            'run `my-brain index`',
          );
        }
        break;
      } on RangeError {
        if (capped >= maxChunk) {
          throw const IndexFormatException(
            'index file is corrupt (truncated attribute entry) - '
            'run `my-brain index`',
          );
        }
        chunkSize *= 2;
      }
    }
    final payloadEnd = headerEnd + payloadLen;
    if (buf.length < payloadEnd) {
      if (offset + payloadEnd > _fileLength) {
        throw const IndexFormatException(
          'index file is corrupt (attribute payload extends past end of '
          'file) - run `my-brain index`',
        );
      }
      await _raf.setPosition(offset);
      buf = await _readExact(_raf, payloadEnd, 'attribute entry payload');
    }
    final ids = _decodeChecked(() {
      final cursor = ByteCursor(buf, headerEnd);
      final result = List<int>.filled(docFreq, 0);
      var prev = -1;
      for (var i = 0; i < docFreq; i++) {
        prev += cursor.readVarint();
        result[i] = prev;
      }
      return result;
    }, 'attribute doc-id list');
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
      final probeBytes = await _readExact(_raf, 8, 'attribute offsets table');
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
    if (entry.postingsOffset < 0 ||
        entry.postingsByteLength < 0 ||
        entry.postingsOffset + entry.postingsByteLength > _fileLength) {
      throw const IndexFormatException(
        'index file is corrupt (postings entry out of range) - '
        'run `my-brain index`',
      );
    }
    await _raf.setPosition(entry.postingsOffset);
    final buf =
        await _readExact(_raf, entry.postingsByteLength, 'postings list');
    return _decodeChecked(() {
      final cursor = ByteCursor(buf);
      final result = <Posting>[];
      var prev = -1;
      for (var i = 0; i < entry.docFreq; i++) {
        prev += cursor.readVarint();
        if (prev < 0 || prev >= _header.docCount) {
          throw const IndexFormatException(
            'index file is corrupt (posting docId out of range) - '
            'run `my-brain index`',
          );
        }
        final tf = cursor.readVarint();
        result.add(Posting(prev, tf));
      }
      return result;
    }, 'postings list');
  }

  /// Number of documents containing [term], read from the term dictionary
  /// without touching the postings region. Used for IDF.
  Future<int> docFrequency(String term) async {
    _ensureOpen();
    final entry = await _findTerm(term);
    return entry?.docFreq ?? 0;
  }

  DocRecord _decodeDocRecord(ByteCursor cursor, int docId) {
    return _decodeChecked(() {
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
    }, 'doc record');
  }

  /// Checks that a doc-record byte range fits inside the file before it is
  /// read, so a corrupt entry in the doc-offsets table fails with
  /// [IndexFormatException] rather than a short read or an out-of-range
  /// negative length.
  void _checkDocRange(int start, int end) {
    if (start < 0 || end < start || end > _fileLength) {
      throw const IndexFormatException(
        'index file is corrupt (doc record out of range) - '
        'run `my-brain index`',
      );
    }
  }

  /// The full record for one document; one seek plus one read.
  Future<DocRecord> doc(int docId) async {
    _ensureOpen();
    final start = _docOffs[docId];
    final end =
        docId + 1 < docCount ? _docOffs[docId + 1] : _header.termOffsetsOffset;
    _checkDocRange(start, end);
    await _raf.setPosition(start);
    final buf = await _readExact(_raf, end - start, 'doc record');
    return _decodeDocRecord(ByteCursor(buf), docId);
  }

  /// Every document record. Only for whole-vault work such as `doctor` and
  /// backlink resolution, never on the search path.
  Future<List<DocRecord>> allDocs() async {
    _ensureOpen();
    if (docCount == 0) return const [];
    final start = _docOffs[0];
    final end = _header.termOffsetsOffset;
    _checkDocRange(start, end);
    await _raf.setPosition(start);
    final buf = await _readExact(_raf, end - start, 'doc records');
    final cursor = ByteCursor(buf);
    return List<DocRecord>.generate(
      docCount,
      (i) => _decodeDocRecord(cursor, i),
    );
  }

  /// Document ids carrying frontmatter `key: value`, ascending. Null when the
  /// pair was never indexed, which is different from an empty match.
  ///
  /// Trims and lowercases both [key] and [value] before composing the
  /// dictionary key, mirroring the trim+lowercase the writer applies when
  /// flattening frontmatter - otherwise a query like `--filter "status= draft"`
  /// (a stray space from `key=value` splitting) would never match the
  /// trimmed value actually stored on disk.
  Future<List<int>?> attributeDocs(String key, String value) async {
    _ensureOpen();
    final composite =
        '${key.trim().toLowerCase()}=${value.trim().toLowerCase()}';
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
    final prefix = '${key.trim().toLowerCase()}=';
    final start = _header.attrEntriesOffset;
    final end = _fileLength;
    if (start < 0 || end < start || end > _fileLength) {
      throw const IndexFormatException(
        'index file is corrupt (attribute region out of range) - '
        'run `my-brain index`',
      );
    }
    await _raf.setPosition(start);
    final buf = await _readExact(_raf, end - start, 'attribute entries');
    return _decodeChecked(() {
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
    }, 'attribute entries');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
  }
}
