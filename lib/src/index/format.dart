/// On-disk layout of `.brain/index.bin`.
///
/// The file is region-based so a query only reads the bytes it needs: a search
/// loads the fixed header, the doc-length and doc-offset tables and the term
/// offset table, then seeks directly to the postings of each query term and to
/// the records of the handful of documents that make the result list. Nothing
/// forces a full deserialisation, which is what keeps cold-start search fast on
/// a vault of many thousands of notes.
///
/// All integers are little-endian. Variable-length integers are unsigned LEB128.
/// Strings are a varint byte length followed by UTF-8 bytes.
///
/// ```
/// offset  size  field
/// 0       8     magic "MYBRAIN\x01"
/// 8       4     u32 formatVersion
/// 12      4     u32 docCount
/// 16      8     f64 avgDocLen          mean document length in tokens
/// 24      8     f64 k1                 BM25 params baked in at build time
/// 32      8     f64 b
/// 40      8     u64 docLensOffset      u32[docCount]
/// 48      8     u64 docOffsOffset      u64[docCount] -> absolute doc record offsets
/// 56      8     u64 docRecsOffset
/// 64      8     u64 termOffsetsOffset  u64[termCount] -> absolute term entry offsets
/// 72      8     u64 termEntriesOffset
/// 80      8     u64 termCount
/// 88      8     u64 postingsOffset
/// 96      8     u64 attrOffsetsOffset  u64[attrCount]
/// 104     8     u64 attrEntriesOffset
/// 112     8     u64 attrCount
/// 120     8     u64 totalPostings
/// 128     32    sha256 manifestHash    identity of the scanned file set
/// 160           end of header
/// ```
///
/// Region payloads:
///
/// * **doc record** — path, title, aliases[], headings[], outLinks[], tags[]
///   (strings), then varints: length, wordCount, mtimeMs, size.
/// * **term entry** — string term, varint docFreq, u64 postingsOffset,
///   varint postingsByteLength. Term entries are sorted by UTF-8 byte order so
///   the offset table can be binary-searched.
/// * **postings** — for each term, `docFreq` pairs of (varint docId delta,
///   varint weightedTf). Deltas are gaps from the previous docId, first gap is
///   from -1 so ids are strictly increasing.
/// * **attr entry** — string `key=value` (both lowercased), varint docFreq,
///   varint payload byte length, then `docFreq` varint docId deltas. Sorted by
///   UTF-8 byte order, same binary search as terms.
library;

import 'dart:convert';
import 'dart:typed_data';

/// File signature. The trailing byte moves with breaking layout changes.
final Uint8List indexMagic = Uint8List.fromList(ascii.encode('MYBRAIN\x01'));

/// Bumped whenever the layout changes in a way that invalidates old files.
const int indexFormatVersion = 2;

/// Size of the fixed header, padded for future fields.
const int indexHeaderSize = 160;

/// Length of the sha256 manifest hash stored in the header.
const int manifestHashBytes = 32;

/// Parsed fixed header of an index file.
class IndexHeader {
  final int formatVersion;
  final int docCount;
  final double avgDocLen;
  final double k1;
  final double b;
  final int docLensOffset;
  final int docOffsOffset;
  final int docRecsOffset;
  final int termOffsetsOffset;
  final int termEntriesOffset;
  final int termCount;
  final int postingsOffset;
  final int attrOffsetsOffset;
  final int attrEntriesOffset;
  final int attrCount;
  final int totalPostings;
  final Uint8List manifestHash;

  const IndexHeader({
    required this.formatVersion,
    required this.docCount,
    required this.avgDocLen,
    required this.k1,
    required this.b,
    required this.docLensOffset,
    required this.docOffsOffset,
    required this.docRecsOffset,
    required this.termOffsetsOffset,
    required this.termEntriesOffset,
    required this.termCount,
    required this.postingsOffset,
    required this.attrOffsetsOffset,
    required this.attrEntriesOffset,
    required this.attrCount,
    required this.totalPostings,
    required this.manifestHash,
  });

  /// Serialises to exactly [indexHeaderSize] bytes.
  Uint8List toBytes() {
    final out = Uint8List(indexHeaderSize);
    out.setRange(0, indexMagic.length, indexMagic);
    final d = ByteData.view(out.buffer);
    d.setUint32(8, formatVersion, Endian.little);
    d.setUint32(12, docCount, Endian.little);
    d.setFloat64(16, avgDocLen, Endian.little);
    d.setFloat64(24, k1, Endian.little);
    d.setFloat64(32, b, Endian.little);
    d.setUint64(40, docLensOffset, Endian.little);
    d.setUint64(48, docOffsOffset, Endian.little);
    d.setUint64(56, docRecsOffset, Endian.little);
    d.setUint64(64, termOffsetsOffset, Endian.little);
    d.setUint64(72, termEntriesOffset, Endian.little);
    d.setUint64(80, termCount, Endian.little);
    d.setUint64(88, postingsOffset, Endian.little);
    d.setUint64(96, attrOffsetsOffset, Endian.little);
    d.setUint64(104, attrEntriesOffset, Endian.little);
    d.setUint64(112, attrCount, Endian.little);
    d.setUint64(120, totalPostings, Endian.little);
    out.setRange(128, 128 + manifestHashBytes, manifestHash);
    return out;
  }

  /// Throws [IndexFormatException] when the bytes are not a readable index.
  static IndexHeader fromBytes(Uint8List bytes) {
    if (bytes.length < indexHeaderSize) {
      throw const IndexFormatException('index file is truncated');
    }
    for (var i = 0; i < indexMagic.length; i++) {
      if (bytes[i] != indexMagic[i]) {
        throw const IndexFormatException('not a my-brain index file');
      }
    }
    final d = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    final version = d.getUint32(8, Endian.little);
    if (version != indexFormatVersion) {
      throw IndexFormatException(
        'index format v$version was written by a different my-brain build '
        '(this build reads v$indexFormatVersion) - run `my-brain index`',
      );
    }
    return IndexHeader(
      formatVersion: version,
      docCount: d.getUint32(12, Endian.little),
      avgDocLen: d.getFloat64(16, Endian.little),
      k1: d.getFloat64(24, Endian.little),
      b: d.getFloat64(32, Endian.little),
      docLensOffset: d.getUint64(40, Endian.little),
      docOffsOffset: d.getUint64(48, Endian.little),
      docRecsOffset: d.getUint64(56, Endian.little),
      termOffsetsOffset: d.getUint64(64, Endian.little),
      termEntriesOffset: d.getUint64(72, Endian.little),
      termCount: d.getUint64(80, Endian.little),
      postingsOffset: d.getUint64(88, Endian.little),
      attrOffsetsOffset: d.getUint64(96, Endian.little),
      attrEntriesOffset: d.getUint64(104, Endian.little),
      attrCount: d.getUint64(112, Endian.little),
      totalPostings: d.getUint64(120, Endian.little),
      manifestHash: Uint8List.sublistView(bytes, 128, 128 + manifestHashBytes),
    );
  }

  /// Checks that every region offset and count is consistent with the
  /// others and fits inside a file of [fileLength] bytes.
  ///
  /// [fromBytes] only ever sees the header's own [indexHeaderSize] bytes, so
  /// it cannot catch a header that describes regions extending past the end
  /// of a truncated file, or a corrupt count so large that computing a
  /// region's byte length would itself misbehave. This is a second pass,
  /// run once the real file length is known, before any region is read.
  ///
  /// Regions are contiguous and ordered exactly as documented in this
  /// library's doc comment: header, docLens, docOffs, docRecs, termOffsets,
  /// termEntries, postings, attrOffsets, attrEntries. The fixed-width
  /// regions (docLens, docOffs, termOffsets, attrOffsets) have offsets that
  /// follow analytically from the counts, so those are checked for exact
  /// equality; the variable-length regions (docRecs, termEntries, postings,
  /// attrEntries) can only be checked for ordering and for fitting in the
  /// file.
  void validate(int fileLength) {
    Never fail(String detail) {
      throw IndexFormatException(
        'index file is corrupt ($detail) - run `my-brain index`',
      );
    }

    // Bound the counts against the file size before they are used in any
    // arithmetic below. Each doc/term/attr needs at least one byte
    // somewhere in the file, so a count larger than the file itself is
    // already proof of corruption - and checking this first means the
    // multiplications below (`4 * docCount`, `8 * termCount`, ...) can
    // never run away with an implausible value from a garbage header.
    if (docCount > fileLength) fail('docCount exceeds file size');
    if (termCount > fileLength) fail('termCount exceeds file size');
    if (attrCount > fileLength) fail('attrCount exceeds file size');

    if (docLensOffset != indexHeaderSize) {
      fail('docLensOffset does not follow the header');
    }
    if (docOffsOffset != docLensOffset + 4 * docCount) {
      fail('docOffsOffset inconsistent with docCount');
    }
    if (docRecsOffset != docOffsOffset + 8 * docCount) {
      fail('docRecsOffset inconsistent with docCount');
    }
    if (termEntriesOffset != termOffsetsOffset + 8 * termCount) {
      fail('termEntriesOffset inconsistent with termCount');
    }
    if (attrEntriesOffset != attrOffsetsOffset + 8 * attrCount) {
      fail('attrEntriesOffset inconsistent with attrCount');
    }

    // The variable-length regions can only be checked for monotonic
    // ordering - their true lengths are only known by decoding them.
    final regionsInOrder = [
      docLensOffset,
      docOffsOffset,
      docRecsOffset,
      termOffsetsOffset,
      termEntriesOffset,
      postingsOffset,
      attrOffsetsOffset,
      attrEntriesOffset,
    ];
    for (var i = 1; i < regionsInOrder.length; i++) {
      if (regionsInOrder[i] < regionsInOrder[i - 1]) {
        fail('region offsets are out of order');
      }
    }
    if (attrEntriesOffset > fileLength) {
      fail('index file is shorter than the header claims');
    }
  }
}

/// Raised when an index file is missing, truncated, or written by another build.
class IndexFormatException implements Exception {
  final String message;
  const IndexFormatException(this.message);
  @override
  String toString() => message;
}

/// Append-only byte buffer with the primitives the index writer needs.
class ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);
  int _length = 0;

  /// Bytes written so far; used to compute region offsets while building.
  int get length => _length;

  void writeByte(int value) {
    _b.addByte(value & 0xff);
    _length += 1;
  }

  void writeBytes(List<int> bytes) {
    _b.add(bytes);
    _length += bytes.length;
  }

  void writeUint32(int value) {
    final b = Uint8List(4);
    ByteData.view(b.buffer).setUint32(0, value, Endian.little);
    writeBytes(b);
  }

  void writeUint64(int value) {
    final b = Uint8List(8);
    ByteData.view(b.buffer).setUint64(0, value, Endian.little);
    writeBytes(b);
  }

  /// Unsigned LEB128.
  void writeVarint(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'varints must be non-negative');
    }
    var v = value;
    while (v >= 0x80) {
      writeByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    writeByte(v);
  }

  /// Varint byte length followed by UTF-8 bytes.
  void writeString(String value) {
    final bytes = utf8.encode(value);
    writeVarint(bytes.length);
    writeBytes(bytes);
  }

  void writeStringList(List<String> values) {
    writeVarint(values.length);
    for (final v in values) {
      writeString(v);
    }
  }

  Uint8List takeBytes() {
    _length = 0;
    return _b.takeBytes();
  }
}

/// Sequential reader over an in-memory slice of the index.
class ByteCursor {
  final Uint8List bytes;
  int offset;

  ByteCursor(this.bytes, [this.offset = 0]);

  bool get atEnd => offset >= bytes.length;

  int readByte() => bytes[offset++];

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = bytes[offset++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift > 63) {
        throw const IndexFormatException('varint overflow: index is corrupt');
      }
    }
  }

  String readString() {
    final len = readVarint();
    final s = utf8.decode(Uint8List.sublistView(bytes, offset, offset + len));
    offset += len;
    return s;
  }

  List<String> readStringList() {
    final n = readVarint();
    return List<String>.generate(n, (_) => readString(), growable: false);
  }
}

/// Compares two terms the way the sorted dictionary orders them: by UTF-8 bytes.
///
/// Both the builder (when sorting) and the reader (when binary searching) must
/// use this, otherwise lookups silently miss on non-ASCII terms.
int compareTermBytes(String a, String b) {
  final ab = utf8.encode(a);
  final bb = utf8.encode(b);
  final n = ab.length < bb.length ? ab.length : bb.length;
  for (var i = 0; i < n; i++) {
    final d = ab[i] - bb[i];
    if (d != 0) return d;
  }
  return ab.length - bb.length;
}
