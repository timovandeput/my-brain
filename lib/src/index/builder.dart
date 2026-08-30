import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../config.dart';
import '../model.dart';
import '../text/tokenizer.dart';
import '../vault/markdown.dart';
import '../vault/scanner.dart';
import 'format.dart';

/// A document ready to be written into the index, independent of how it was
/// produced.
///
/// This is the seam between parsing and the on-disk format: [IndexWriter]
/// only ever sees [IndexableDoc]s, so the writer (and its tests) never need
/// `parseNote` or the markdown/frontmatter machinery. [IndexBuilder] is the
/// only piece that bridges the two.
class IndexableDoc {
  /// Vault-relative path with `/` separators.
  final String path;

  final String title;
  final List<String> aliases;
  final List<String> headings;
  final List<String> outLinks;

  /// Approximate body word count, used to flag oversized notes.
  final int wordCount;

  /// Bitfield of the `docFlag*` constants in `format.dart`: findings about the
  /// note that only the parser can see, carried into the index so `doctor` can
  /// report them without re-reading every file.
  final int flags;

  final int mtimeMs;
  final int size;

  /// Field-tagged term occurrences. The raw count of this list is the BM25
  /// length normaliser; per-field weights are folded into term frequency at
  /// write time, not here.
  final List<FieldTerm> terms;

  /// Flattened frontmatter (plus inline tags folded into `tags`), lowercased
  /// keys and values, ready for the attribute index.
  final Map<String, List<String>> attributes;

  const IndexableDoc({
    required this.path,
    required this.title,
    required this.aliases,
    required this.headings,
    required this.outLinks,
    required this.wordCount,
    required this.mtimeMs,
    required this.size,
    required this.terms,
    required this.attributes,
    this.flags = 0,
  });
}

/// Result of laying out a term's postings: where they start within the
/// postings region and how many bytes they occupy.
class _PostingsSpan {
  final int relativeOffset;
  final int byteLength;
  final int docFreq;
  const _PostingsSpan(this.relativeOffset, this.byteLength, this.docFreq);
}

/// Number of bytes an unsigned LEB128 varint encoding of [value] occupies.
int _varintByteLength(int value) {
  var v = value;
  var n = 1;
  while (v >= 0x80) {
    v >>= 7;
    n++;
  }
  return n;
}

/// Writes deltas from `docId` in ascending order, first delta is `docId + 1`
/// (the gap from -1).
void _writeDocIdDeltas(ByteWriter writer, List<int> docIdsAscending) {
  var prev = -1;
  for (final id in docIdsAscending) {
    writer.writeVarint(id - prev);
    prev = id;
  }
}

/// Pure writer for the on-disk index format.
///
/// Takes [IndexableDoc]s plus the config and manifest hash and produces
/// `.brain/index.bin` bytes. No I/O happens except the final atomic write in
/// [writeTo] - [buildBytes] is a plain function of its inputs, which is what
/// makes the format testable with synthetic documents.
class IndexWriter {
  final BrainConfig config;
  final List<int> manifestHash;

  const IndexWriter(this.config, this.manifestHash);

  /// Builds the full index file contents in memory, alongside the term and
  /// posting counts needed for [IndexStats] - derived from the same
  /// [_PostingsSpan] data used to write the file, so they can never drift
  /// from what was actually written.
  ({Uint8List bytes, int termCount, int postingCount}) buildBytes(
    List<IndexableDoc> docs,
  ) {
    final n = docs.length;
    final docLens = List<int>.generate(n, (i) => docs[i].terms.length);
    final avgDocLen = n == 0 ? 0.0 : docLens.fold<int>(0, (a, b) => a + b) / n;

    // Accumulate weighted term frequency per doc, and per-term postings in
    // docId-ascending order (guaranteed since we iterate docs in order).
    final termPostings = <String, List<Posting>>{};
    final attrDocIds = <String, List<int>>{};
    for (var docId = 0; docId < n; docId++) {
      final doc = docs[docId];
      final weighted = <String, double>{};
      for (final t in doc.terms) {
        weighted[t.term] =
            (weighted[t.term] ?? 0) + config.weightFor(t.field.name);
      }
      weighted.forEach((term, w) {
        final tf = math.max(1, w.round());
        (termPostings[term] ??= <Posting>[]).add(Posting(docId, tf));
      });

      final seenAttr = <String>{};
      doc.attributes.forEach((key, values) {
        for (final v in values) {
          final composite = '$key=$v';
          if (seenAttr.add(composite)) {
            (attrDocIds[composite] ??= <int>[]).add(docId);
          }
        }
      });
    }

    final sortedTerms = termPostings.keys.toList()..sort(compareTermBytes);
    final sortedAttrKeys = attrDocIds.keys.toList()..sort(compareTermBytes);

    // --- doc records (no forward references) ---
    final docRecsWriter = ByteWriter();
    final docRecRelativeOffsets = List<int>.filled(n, 0);
    for (var docId = 0; docId < n; docId++) {
      final doc = docs[docId];
      docRecRelativeOffsets[docId] = docRecsWriter.length;
      docRecsWriter.writeString(doc.path);
      docRecsWriter.writeString(doc.title);
      docRecsWriter.writeStringList(doc.aliases);
      docRecsWriter.writeStringList(doc.headings);
      docRecsWriter.writeStringList(doc.outLinks);
      // Tags already live in the attribute index for filtering; this copy is
      // what lets a search hit report its own tags without a scan.
      docRecsWriter.writeStringList(doc.attributes['tags'] ?? const []);
      docRecsWriter.writeVarint(docLens[docId]);
      docRecsWriter.writeVarint(doc.wordCount);
      docRecsWriter.writeVarint(doc.mtimeMs);
      docRecsWriter.writeVarint(doc.size);
      docRecsWriter.writeVarint(doc.flags);
    }
    final docRecsBytes = docRecsWriter.takeBytes();

    // --- postings (self-contained, no forward references) ---
    final postingsWriter = ByteWriter();
    final postingsSpans = <String, _PostingsSpan>{};
    for (final term in sortedTerms) {
      final list = termPostings[term]!;
      final start = postingsWriter.length;
      // Postings interleave docId delta and weightedTf, unlike attr entries
      // (delta-only), so this doesn't reuse _writeDocIdDeltas.
      var prev = -1;
      for (final posting in list) {
        postingsWriter.writeVarint(posting.docId - prev);
        postingsWriter.writeVarint(posting.weightedTf);
        prev = posting.docId;
      }
      final byteLength = postingsWriter.length - start;
      postingsSpans[term] = _PostingsSpan(start, byteLength, list.length);
    }
    final postingsBytes = postingsWriter.takeBytes();

    // --- attr entries (self-contained, no forward references) ---
    final attrEntriesWriter = ByteWriter();
    final attrEntryRelativeOffsets = <String, int>{};
    for (final key in sortedAttrKeys) {
      final ids = attrDocIds[key]!;
      attrEntryRelativeOffsets[key] = attrEntriesWriter.length;
      final payloadWriter = ByteWriter();
      _writeDocIdDeltas(payloadWriter, ids);
      final payloadBytes = payloadWriter.takeBytes();
      attrEntriesWriter.writeString(key);
      attrEntriesWriter.writeVarint(ids.length);
      attrEntriesWriter.writeVarint(payloadBytes.length);
      attrEntriesWriter.writeBytes(payloadBytes);
    }
    final attrEntriesBytes = attrEntriesWriter.takeBytes();

    // --- term entries: length is independent of the absolute postings
    // offset value (the offset field is a fixed-width u64), so compute the
    // region length and each entry's relative offset analytically first,
    // then do a single writing pass once postingsOffset is known.
    final termEntryRelativeOffsets = <String, int>{};
    var termEntriesLength = 0;
    for (final term in sortedTerms) {
      termEntryRelativeOffsets[term] = termEntriesLength;
      final span = postingsSpans[term]!;
      final utf8Len = _utf8Length(term);
      termEntriesLength += _varintByteLength(utf8Len) +
          utf8Len +
          _varintByteLength(span.docFreq) +
          8 +
          _varintByteLength(span.byteLength);
    }

    // --- region offsets, per format.dart ---
    const docLensOffset = indexHeaderSize;
    final docOffsOffset = docLensOffset + 4 * n;
    final docRecsOffset = docOffsOffset + 8 * n;
    final termOffsetsOffset = docRecsOffset + docRecsBytes.length;
    final termEntriesOffset = termOffsetsOffset + 8 * sortedTerms.length;
    final postingsOffset = termEntriesOffset + termEntriesLength;
    final attrOffsetsOffset = postingsOffset + postingsBytes.length;
    final attrEntriesOffset = attrOffsetsOffset + 8 * sortedAttrKeys.length;

    // --- term entries: real writing pass with absolute postings offsets ---
    final termEntriesWriter = ByteWriter();
    var totalPostings = 0;
    for (final term in sortedTerms) {
      final span = postingsSpans[term]!;
      totalPostings += span.docFreq;
      termEntriesWriter.writeString(term);
      termEntriesWriter.writeVarint(span.docFreq);
      termEntriesWriter.writeUint64(postingsOffset + span.relativeOffset);
      termEntriesWriter.writeVarint(span.byteLength);
    }
    final termEntriesBytes = termEntriesWriter.takeBytes();
    assert(termEntriesBytes.length == termEntriesLength);

    // --- doc lens / doc offsets / term offsets / attr offsets tables ---
    final docLensWriter = ByteWriter();
    for (final len in docLens) {
      docLensWriter.writeUint32(len);
    }
    final docLensBytes = docLensWriter.takeBytes();

    final docOffsWriter = ByteWriter();
    for (var docId = 0; docId < n; docId++) {
      docOffsWriter.writeUint64(docRecsOffset + docRecRelativeOffsets[docId]);
    }
    final docOffsBytes = docOffsWriter.takeBytes();

    final termOffsetsWriter = ByteWriter();
    for (final term in sortedTerms) {
      termOffsetsWriter
          .writeUint64(termEntriesOffset + termEntryRelativeOffsets[term]!);
    }
    final termOffsetsBytes = termOffsetsWriter.takeBytes();

    final attrOffsetsWriter = ByteWriter();
    for (final key in sortedAttrKeys) {
      attrOffsetsWriter
          .writeUint64(attrEntriesOffset + attrEntryRelativeOffsets[key]!);
    }
    final attrOffsetsBytes = attrOffsetsWriter.takeBytes();

    final header = IndexHeader(
      formatVersion: indexFormatVersion,
      docCount: n,
      avgDocLen: avgDocLen,
      k1: config.k1,
      b: config.b,
      docLensOffset: docLensOffset,
      docOffsOffset: docOffsOffset,
      docRecsOffset: docRecsOffset,
      termOffsetsOffset: termOffsetsOffset,
      termEntriesOffset: termEntriesOffset,
      termCount: sortedTerms.length,
      postingsOffset: postingsOffset,
      attrOffsetsOffset: attrOffsetsOffset,
      attrEntriesOffset: attrEntriesOffset,
      attrCount: sortedAttrKeys.length,
      totalPostings: totalPostings,
      manifestHash: Uint8List.fromList(manifestHash),
    );

    final out = BytesBuilder(copy: false);
    out.add(header.toBytes());
    out.add(docLensBytes);
    out.add(docOffsBytes);
    out.add(docRecsBytes);
    out.add(termOffsetsBytes);
    out.add(termEntriesBytes);
    out.add(postingsBytes);
    out.add(attrOffsetsBytes);
    out.add(attrEntriesBytes);
    return (
      bytes: out.takeBytes(),
      termCount: sortedTerms.length,
      postingCount: totalPostings,
    );
  }

  /// Writes the index for [docs] to `<config.indexPath>` atomically: builds
  /// into `<indexPath>.tmp` then renames into place, so a crash mid-build
  /// leaves the previous index readable.
  Future<IndexStats> writeTo(List<IndexableDoc> docs) async {
    final stopwatch = Stopwatch()..start();
    final built = buildBytes(docs);
    final bytes = built.bytes;

    final dir = Directory(config.brainDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final tmpPath = '${config.indexPath}.tmp';
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsBytes(bytes, flush: true);
    await tmpFile.rename(config.indexPath);

    stopwatch.stop();
    return IndexStats(
      docCount: docs.length,
      termCount: built.termCount,
      postingCount: built.postingCount,
      indexBytes: bytes.length,
      elapsed: stopwatch.elapsed,
    );
  }
}

/// A human-readable reason from a [FileSystemException], folding in the OS
/// error message when there is one (permission denied, ...) since the
/// exception's own [FileSystemException.message] alone is often generic
/// ("Cannot open file").
String _fileSystemErrorReason(FileSystemException e) {
  final osMessage = e.osError?.message;
  if (osMessage != null && osMessage.isNotEmpty) {
    return '${e.message}: $osMessage';
  }
  return e.message;
}

int _utf8Length(String s) {
  // Matches dart:convert utf8.encode's byte count without allocating twice;
  // codeUnits are UTF-16, so surrogate pairs count as one 4-byte sequence.
  var len = 0;
  for (var i = 0; i < s.length; i++) {
    final unit = s.codeUnitAt(i);
    if (unit < 0x80) {
      len += 1;
    } else if (unit < 0x800) {
      len += 2;
    } else if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < s.length) {
      final next = s.codeUnitAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        len += 4;
        i++;
      } else {
        len += 3;
      }
    } else {
      len += 3;
    }
  }
  return len;
}

/// One file the builder could not turn into an [IndexableDoc].
///
/// Covers both an unreadable file (permission denied, disappeared mid-scan)
/// and one that could be read but not decoded as UTF-8 (stray latin-1 or
/// binary content) - either way the file is left out of the index rather
/// than aborting the whole build.
class SkippedFile {
  /// Vault-relative path, as in [ScannedFile.path].
  final String path;

  /// Human-readable reason it was skipped.
  final String reason;

  const SkippedFile(this.path, this.reason);
}

/// Result of a full index build: the persisted [stats], plus any files that
/// were skipped rather than indexed.
///
/// Exposes the [IndexStats] fields directly as well, so existing call sites
/// that only cared about stats keep working unchanged against the new
/// return type.
class BuildResult {
  final IndexStats stats;
  final List<SkippedFile> skipped;

  const BuildResult(this.stats, this.skipped);

  int get docCount => stats.docCount;
  int get termCount => stats.termCount;
  int get postingCount => stats.postingCount;
  int get indexBytes => stats.indexBytes;
  Duration get elapsed => stats.elapsed;
}

/// Builds `.brain/index.bin` from a scanned file set.
///
/// Indexing is a full rebuild rather than an incremental merge. Rebuilding a
/// few thousand notes costs seconds and is triggered explicitly by the agent,
/// whereas incremental merging into a seek-optimised file is a large amount of
/// machinery whose failure mode is a silently wrong index.
///
/// The output is written to `<indexPath>.tmp` and renamed into place, so a
/// crash mid-build leaves the previous index intact and a reader never sees a
/// half-written file.
class IndexBuilder {
  final BrainConfig config;
  final Analyzer analyzer;

  const IndexBuilder(this.config, this.analyzer);

  /// Reads every file in [manifest], analyses it, and writes the index.
  ///
  /// A file that cannot be read (permission denied, disappeared mid-scan) or
  /// decoded as UTF-8 (stray latin-1 or binary content) is skipped rather
  /// than aborting the whole build - one bad note should never leave the
  /// user with no index at all. Skipped files are reported in the returned
  /// [BuildResult.skipped].
  ///
  /// [onProgress] is called with the number of documents processed so far, for
  /// the CLI progress line; it may be called on any interval.
  Future<BuildResult> build(
    VaultManifest manifest, {
    void Function(int done, int total)? onProgress,
  }) async {
    final total = manifest.files.length;
    final docs = <IndexableDoc>[];
    final skipped = <SkippedFile>[];
    final allowedAttrs = config.filterableFrontmatter
        ?.map((e) => e.toLowerCase().trim())
        .toSet();
    var done = 0;
    for (final file in manifest.files) {
      String source;
      try {
        source = await File(file.absolutePath).readAsString();
      } on FileSystemException catch (e) {
        // Covers both an unreadable file (permission denied, disappeared
        // mid-scan - surfaces as PathAccessException, a FileSystemException
        // subtype) and one that reads fine but is not valid UTF-8 (stray
        // latin-1 or binary content - readAsString throws a
        // FileSystemException for that too, not a FormatException).
        skipped.add(SkippedFile(file.path, _fileSystemErrorReason(e)));
        done++;
        onProgress?.call(done, total);
        continue;
      } on FormatException catch (e) {
        skipped.add(SkippedFile(file.path, 'not valid UTF-8 (${e.message})'));
        done++;
        onProgress?.call(done, total);
        continue;
      }
      final slash = file.path.lastIndexOf('/');
      final filename = slash < 0 ? file.path : file.path.substring(slash + 1);

      final note = parseNote(source, filename: filename);
      final terms = noteTerms(note, analyzer).toList(growable: false);

      final attributes = <String, List<String>>{
        for (final entry in note.frontmatter.flatten().entries)
          entry.key: List<String>.of(entry.value),
      };
      final tags = <String>{
        ...?attributes['tags'],
        for (final tag in note.inlineTags) tag.toLowerCase(),
      };
      if (tags.isNotEmpty) {
        attributes['tags'] = tags.toList()..sort();
      }
      // A non-null filterableFrontmatter restricts the attribute index to
      // just these keys, so a vault with large frontmatter can keep its
      // attribute region small; a null list (the default) indexes every
      // scalar/list key.
      if (allowedAttrs != null) {
        attributes.removeWhere((key, _) => !allowedAttrs.contains(key));
      }

      final outLinks = <String>[
        for (final link in note.wikiLinks) link.target,
        ...note.markdownLinks,
      ];

      final flags =
          (note.frontmatter.malformed ? docFlagFrontmatterMalformed : 0) |
              (note.frontmatter.hasWikiLink ? docFlagFrontmatterLinks : 0);

      docs.add(IndexableDoc(
        path: file.path,
        title: note.title,
        aliases: note.aliases,
        headings: note.headings,
        outLinks: outLinks,
        wordCount: note.wordCount,
        mtimeMs: file.mtimeMs,
        size: file.size,
        terms: terms,
        attributes: attributes,
        flags: flags,
      ));

      done++;
      onProgress?.call(done, total);
    }

    final writer = IndexWriter(config, manifest.hash);
    final stats = await writer.writeTo(docs);
    return BuildResult(stats, skipped);
  }
}
