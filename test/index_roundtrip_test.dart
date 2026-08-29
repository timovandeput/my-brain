import 'dart:io';
import 'dart:typed_data';

import 'package:my_brain/src/config.dart';
import 'package:my_brain/src/index/builder.dart';
import 'package:my_brain/src/index/format.dart';
import 'package:my_brain/src/index/reader.dart';
import 'package:my_brain/src/model.dart';
import 'package:my_brain/src/text/tokenizer.dart';
import 'package:my_brain/src/vault/scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late BrainConfig config;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('my_brain_index_test_');
    config = BrainConfig(vaultRoot: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  IndexableDoc makeDoc(int i, {List<FieldTerm>? terms}) => IndexableDoc(
        path: 'notes/note-$i.md',
        title: 'Note $i',
        aliases: ['alias-$i', 'alt-$i'],
        headings: ['Intro', 'Section $i'],
        outLinks: ['notes/note-${(i + 1) % 300}.md'],
        wordCount: 100 + i,
        mtimeMs: 1000000 + i,
        size: 500 + i,
        terms: terms ??
            [
              FieldTerm('note', Field.title),
              FieldTerm('shared', Field.body),
              FieldTerm('unique$i', Field.body),
            ],
        attributes: {
          'status': ['draft'],
          'project': ['brain$i'],
        },
      );

  Future<IndexReader> buildAndOpen(List<IndexableDoc> docs) async {
    final writer = IndexWriter(config, List<int>.filled(32, 7));
    await writer.writeTo(docs);
    return IndexReader.open(config.indexPath);
  }

  test('writes atomically: tmp file gone, real file present', () async {
    final docs = [makeDoc(0)];
    final writer = IndexWriter(config, List<int>.filled(32, 1));
    await writer.writeTo(docs);
    expect(File('${config.indexPath}.tmp').existsSync(), isFalse);
    expect(File(config.indexPath).existsSync(), isTrue);
  });

  test('creates the .brain directory if missing', () async {
    expect(Directory(config.brainDir).existsSync(), isFalse);
    final writer = IndexWriter(config, List<int>.filled(32, 1));
    await writer.writeTo([makeDoc(0)]);
    expect(Directory(config.brainDir).existsSync(), isTrue);
  });

  test('empty index (zero docs) does not crash', () async {
    final reader = await buildAndOpen(<IndexableDoc>[]);
    addTearDown(reader.close);

    expect(reader.docCount, 0);
    expect(reader.avgDocLen, 0.0);
    expect(await reader.allDocs(), isEmpty);
    expect(await reader.postings('anything'), isEmpty);
    expect(await reader.docFrequency('anything'), 0);
    expect(await reader.attributeDocs('status', 'draft'), isNull);
    expect(await reader.attributeValues('status'), isEmpty);
  });

  test('round-trips a single doc with no terms', () async {
    final docs = [makeDoc(0, terms: const [])];
    final reader = await buildAndOpen(docs);
    addTearDown(reader.close);

    expect(reader.docCount, 1);
    expect(reader.docLength(0), 0);
    final rec = await reader.doc(0);
    expect(rec.path, 'notes/note-0.md');
    expect(rec.length, 0);
    expect(await reader.postings('shared'), isEmpty);
  });

  test('round-trips a doc with unicode terms and fields', () async {
    final docs = [
      makeDoc(
        0,
        terms: const [
          FieldTerm('café', Field.title),
          FieldTerm('日本語', Field.body),
          FieldTerm('ångström', Field.heading),
          FieldTerm('café', Field.body), // repeat, different field
        ],
      ),
    ];
    final reader = await buildAndOpen(docs);
    addTearDown(reader.close);

    final cafePostings = await reader.postings('café');
    expect(cafePostings, hasLength(1));
    expect(cafePostings.single.docId, 0);
    // weight = title(3.0) + body(1.0) = 4.0 -> round() = 4
    expect(cafePostings.single.weightedTf, 4);

    final jpPostings = await reader.postings('日本語');
    expect(jpPostings, hasLength(1));
    expect(jpPostings.single.weightedTf, 1); // body weight 1.0

    final headingPostings = await reader.postings('ångström');
    expect(headingPostings.single.weightedTf, 2); // heading weight 2.0

    // Raw doc length is the emitted FieldTerm count, not the weighted sum.
    expect(reader.docLength(0), 4);
  });

  test('round-trips doc records, lengths, postings, docFrequency and '
      'attributes at scale (binary search exercised at depth)', () async {
    const n = 300;
    final docs = List<IndexableDoc>.generate(n, makeDoc);
    final reader = await buildAndOpen(docs);
    addTearDown(reader.close);

    expect(reader.docCount, n);

    // Doc records round-trip exactly, and doc order == docId order.
    for (var i = 0; i < n; i++) {
      final rec = await reader.doc(i);
      expect(rec.docId, i);
      expect(rec.path, 'notes/note-$i.md');
      expect(rec.title, 'Note $i');
      expect(rec.aliases, ['alias-$i', 'alt-$i']);
      expect(rec.headings, ['Intro', 'Section $i']);
      expect(rec.outLinks, ['notes/note-${(i + 1) % 300}.md']);
      expect(rec.length, 3); // three FieldTerms per doc
      expect(rec.wordCount, 100 + i);
      expect(rec.mtimeMs, 1000000 + i);
      expect(rec.size, 500 + i);
      expect(reader.docLength(i), 3);
    }

    final allDocs = await reader.allDocs();
    expect(allDocs, hasLength(n));
    for (var i = 0; i < n; i++) {
      expect(allDocs[i].docId, i);
      expect(allDocs[i].path, 'notes/note-$i.md');
    }

    // A term present in every doc.
    final sharedPostings = await reader.postings('shared');
    expect(sharedPostings, hasLength(n));
    expect(
      sharedPostings.map((p) => p.docId).toList(),
      List<int>.generate(n, (i) => i),
      reason: 'postings must be strictly ascending by docId',
    );
    expect(await reader.docFrequency('shared'), n);

    // Terms present in exactly one doc, spread across the sorted dictionary
    // so binary search probes land at varying depths.
    for (final i in [0, 1, 37, 149, 150, 151, 298, 299]) {
      final postings = await reader.postings('unique$i');
      expect(postings, hasLength(1));
      expect(postings.single.docId, i);
      expect(await reader.docFrequency('unique$i'), 1);
    }

    // Absent terms.
    expect(await reader.postings('nonexistent-term'), isEmpty);
    expect(await reader.docFrequency('nonexistent-term'), 0);

    // Attributes: shared key across all docs (OR/union tested at the
    // Searcher level; here we just check the raw index).
    final draftDocs = await reader.attributeDocs('status', 'draft');
    expect(draftDocs, hasLength(n));
    expect(draftDocs, List<int>.generate(n, (i) => i));

    for (final i in [0, 42, 299]) {
      final projectDocs = await reader.attributeDocs('project', 'brain$i');
      expect(projectDocs, [i]);
    }

    expect(await reader.attributeDocs('status', 'archived'), isNull);
    expect(await reader.attributeDocs('nope', 'nope'), isNull);

    // attributeValues discoverability.
    final statusValues = await reader.attributeValues('status');
    expect(statusValues, ['draft']);
    final projectValues = await reader.attributeValues('project');
    expect(projectValues, hasLength(n));
    expect(projectValues.toSet(), List<String>.generate(n, (i) => 'brain$i').toSet());

    // Attribute keys are case-insensitive on lookup (stored lowercased).
    final draftUpper = await reader.attributeDocs('Status', 'Draft');
    expect(draftUpper, hasLength(n));
  });

  test('manifest hash round-trips', () async {
    final hash = List<int>.generate(32, (i) => (i * 13 + 5) % 256);
    final writer = IndexWriter(config, hash);
    await writer.writeTo([makeDoc(0)]);
    final reader = await IndexReader.open(config.indexPath);
    addTearDown(reader.close);
    expect(reader.manifestHash, hash);
  });

  test('avgDocLen, k1 and b are baked into the header', () async {
    final custom = BrainConfig(vaultRoot: tempDir.path, k1: 1.5, b: 0.5);
    final writer = IndexWriter(custom, List<int>.filled(32, 0));
    final docs = [
      makeDoc(0, terms: List.filled(2, const FieldTerm('x', Field.body))),
      makeDoc(1, terms: List.filled(6, const FieldTerm('y', Field.body))),
    ];
    await writer.writeTo(docs);
    final reader = await IndexReader.open(custom.indexPath);
    addTearDown(reader.close);
    expect(reader.avgDocLen, closeTo(4.0, 1e-9));
    expect(reader.header.k1, 1.5);
    expect(reader.header.b, 0.5);
  });

  test('double close is safe', () async {
    final reader = await buildAndOpen([makeDoc(0)]);
    await reader.close();
    await reader.close(); // must not throw
  });

  test('IndexReader.open throws IndexFormatException for a missing file',
      () async {
    await expectLater(
      IndexReader.open('${tempDir.path}/does-not-exist.bin'),
      throwsA(isA<IndexFormatException>()),
    );
  });

  group('corrupt or truncated index files never escape as an Error', () {
    // Builds a real, valid index for a small multi-doc, multi-attribute
    // corpus (so every region - doc records, term entries, postings, attr
    // entries - is non-empty) and returns its raw bytes without opening a
    // reader, so the test can corrupt them before the first read.
    Future<Uint8List> realIndexBytes() async {
      final docs = List<IndexableDoc>.generate(5, makeDoc);
      final writer = IndexWriter(config, List<int>.filled(32, 9));
      await writer.writeTo(docs);
      return File(config.indexPath).readAsBytesSync();
    }

    Future<void> writeAndExpectFormatException(
      Uint8List bytes, {
      Object? messageContains,
    }) async {
      File(config.indexPath).writeAsBytesSync(bytes);
      var matcher = isA<IndexFormatException>();
      if (messageContains != null) {
        matcher = matcher.having(
          (e) => e.toString(),
          'message',
          contains(messageContains),
        );
      }
      await expectLater(
        IndexReader.open(config.indexPath),
        throwsA(matcher),
      );
    }

    test('truncated mid-header throws IndexFormatException, not RangeError',
        () async {
      final bytes = await realIndexBytes();
      // 170 bytes is past indexHeaderSize (160) but still inside the fixed
      // header-adjacent tables - this is the exact byte count that used to
      // throw a raw `RangeError (byteOffset)` from `_readUint32List`.
      await writeAndExpectFormatException(bytes.sublist(0, 170));
    });

    test('truncated to fewer bytes than the header itself', () async {
      final bytes = await realIndexBytes();
      await writeAndExpectFormatException(bytes.sublist(0, 10));
    });

    test(
        'truncated exactly at a region boundary (postings/attr regions '
        'entirely missing)', () async {
      final bytes = await realIndexBytes();
      final header = IndexHeader.fromBytes(
        Uint8List.sublistView(bytes, 0, indexHeaderSize),
      );
      // Cuts the file off right where the term entries region begins, so
      // postings, attr offsets and attr entries are entirely absent even
      // though the header still claims they exist. This used to send
      // `_readTermEntryAt`'s chunk-doubling retry loop growing until the OS
      // rejected the read with `errno = 22`.
      await writeAndExpectFormatException(
        bytes.sublist(0, header.termEntriesOffset),
      );
    });

    test(
        'truncated a few bytes short of the true end of file: open '
        'succeeds (lazy reader) but reading the truncated tail fails clean',
        () async {
      final bytes = await realIndexBytes();
      // The trailing attr-entries region has no length recorded in the
      // header (only its start offset), so cutting a few bytes off the very
      // end is invisible both to header-level validation and to `open`,
      // which never reads that region eagerly. It can only be caught by the
      // bounds checks in the on-demand reads themselves - so this checks
      // that a later read of the region notices, not `open`.
      File(config.indexPath).writeAsBytesSync(bytes.sublist(0, bytes.length - 3));
      final reader = await IndexReader.open(config.indexPath);
      addTearDown(reader.close);
      // 'status=draft' is the alphabetically last attribute entry in this
      // corpus (all 5 docs), so it sits at the very tail of the file and is
      // exactly what the truncation cut into.
      await expectLater(
        reader.attributeDocs('status', 'draft'),
        throwsA(isA<IndexFormatException>()),
      );
    });

    test('bad magic bytes', () async {
      final bytes = await realIndexBytes();
      final corrupted = Uint8List.fromList(bytes);
      corrupted[0] = 0;
      await writeAndExpectFormatException(
        corrupted,
        messageContains: 'not a my-brain index',
      );
    });

    test(
        'a header with an absurd termCount is rejected before attempting '
        'the implied allocation', () async {
      final bytes = await realIndexBytes();
      final header = IndexHeader.fromBytes(
        Uint8List.sublistView(bytes, 0, indexHeaderSize),
      );
      final patchedHeader = IndexHeader(
        formatVersion: header.formatVersion,
        docCount: header.docCount,
        avgDocLen: header.avgDocLen,
        k1: header.k1,
        b: header.b,
        docLensOffset: header.docLensOffset,
        docOffsOffset: header.docOffsOffset,
        docRecsOffset: header.docRecsOffset,
        termOffsetsOffset: header.termOffsetsOffset,
        termEntriesOffset: header.termEntriesOffset,
        termCount: 0x00FFFFFFFFFFFFFF, // absurd: nowhere near the file size
        postingsOffset: header.postingsOffset,
        attrOffsetsOffset: header.attrOffsetsOffset,
        attrEntriesOffset: header.attrEntriesOffset,
        attrCount: header.attrCount,
        totalPostings: header.totalPostings,
        manifestHash: header.manifestHash,
      );
      final corrupted = Uint8List.fromList(bytes);
      corrupted.setRange(0, indexHeaderSize, patchedHeader.toBytes());
      await writeAndExpectFormatException(corrupted);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('a header with an absurd docCount is rejected the same way',
        () async {
      final bytes = await realIndexBytes();
      final header = IndexHeader.fromBytes(
        Uint8List.sublistView(bytes, 0, indexHeaderSize),
      );
      final patchedHeader = IndexHeader(
        formatVersion: header.formatVersion,
        docCount: 0x7FFFFFFF, // absurd: max u32-ish, nowhere near file size
        avgDocLen: header.avgDocLen,
        k1: header.k1,
        b: header.b,
        docLensOffset: header.docLensOffset,
        docOffsOffset: header.docOffsOffset,
        docRecsOffset: header.docRecsOffset,
        termOffsetsOffset: header.termOffsetsOffset,
        termEntriesOffset: header.termEntriesOffset,
        termCount: header.termCount,
        postingsOffset: header.postingsOffset,
        attrOffsetsOffset: header.attrOffsetsOffset,
        attrEntriesOffset: header.attrEntriesOffset,
        attrCount: header.attrCount,
        totalPostings: header.totalPostings,
        manifestHash: header.manifestHash,
      );
      final corrupted = Uint8List.fromList(bytes);
      corrupted.setRange(0, indexHeaderSize, patchedHeader.toBytes());
      await writeAndExpectFormatException(corrupted);
    });

    test('VaultContext.openIndex-style Error widening: a directly '
        'constructed reader never throws a bare Error for a truncated file',
        () async {
      final bytes = await realIndexBytes();
      File(config.indexPath).writeAsBytesSync(bytes.sublist(0, 170));
      try {
        await IndexReader.open(config.indexPath);
        fail('expected IndexFormatException');
      } on IndexFormatException {
        // expected
      } catch (e) {
        fail('expected IndexFormatException, got ${e.runtimeType}: $e');
      }
    });
  });

  group('IndexBuilder.build skips unreadable files instead of aborting',
      () {
    test('a non-UTF-8 file is skipped and reported, the rest still index',
        () async {
      File(p.join(tempDir.path, 'good.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('---\nstatus: draft\n---\n\n# Good\n\nfine body.\n');
      // Invalid UTF-8 byte sequence - not decodable as text.
      File(p.join(tempDir.path, 'bad.md'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(const [0xff, 0xfe, 0x00, 0x41, 0x80, 0x81]);

      final manifest = await VaultScanner(config).scan();
      expect(manifest.files, hasLength(2));

      final result =
          await IndexBuilder(config, const Analyzer()).build(manifest);

      expect(result.skipped, hasLength(1));
      expect(result.skipped.single.path, 'bad.md');
      expect(result.skipped.single.reason, isNotEmpty);
      expect(result.docCount, 1);

      final reader = await IndexReader.open(config.indexPath);
      addTearDown(reader.close);
      final docs = await reader.allDocs();
      expect(docs.map((d) => d.path), ['good.md']);
    });

    test('no files skipped means an empty skipped list', () async {
      File(p.join(tempDir.path, 'good.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# Good\n\nfine body.\n');
      final manifest = await VaultScanner(config).scan();
      final result =
          await IndexBuilder(config, const Analyzer()).build(manifest);
      expect(result.skipped, isEmpty);
      expect(result.docCount, 1);
    });
  });

  group('filterableFrontmatter restricts the attribute index', () {
    Future<void> writeNote() async {
      File(p.join(tempDir.path, 'note.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '---\nstatus: draft\nproject: brain\nsecret: shhh\n---\n\n'
          '# Note\n\nbody text.\n',
        );
    }

    test('a non-null list only indexes the listed keys', () async {
      await writeNote();
      final restricted = BrainConfig(
        vaultRoot: tempDir.path,
        filterableFrontmatter: const ['status'],
      );
      final manifest = await VaultScanner(restricted).scan();
      await IndexBuilder(restricted, const Analyzer()).build(manifest);

      final reader = await IndexReader.open(restricted.indexPath);
      addTearDown(reader.close);
      expect(await reader.attributeDocs('status', 'draft'), [0]);
      expect(await reader.attributeDocs('project', 'brain'), isNull);
      expect(await reader.attributeDocs('secret', 'shhh'), isNull);
      expect(await reader.attributeValues('project'), isEmpty);
    });

    test('null (the default) indexes every scalar/list key', () async {
      await writeNote();
      final manifest = await VaultScanner(config).scan();
      await IndexBuilder(config, const Analyzer()).build(manifest);

      final reader = await IndexReader.open(config.indexPath);
      addTearDown(reader.close);
      expect(await reader.attributeDocs('status', 'draft'), [0]);
      expect(await reader.attributeDocs('project', 'brain'), [0]);
      expect(await reader.attributeDocs('secret', 'shhh'), [0]);
    });
  });

  group('attributeDocs trims key and value like the write-side flatten does',
      () {
    test('a query with stray whitespace still matches', () async {
      final docs = [makeDoc(0)]; // attributes: status=draft, project=brain0
      final reader = await buildAndOpen(docs);
      addTearDown(reader.close);

      // Regression: "--filter \"status= draft\"" splits into key "status"
      // and value " draft" (leading space from the split), which the write
      // side's Frontmatter.flatten() would never have stored - it trims.
      expect(await reader.attributeDocs('status', '  draft  '), [0]);
      expect(await reader.attributeDocs('  status  ', 'draft'), [0]);
      expect(await reader.attributeDocs(' Status ', ' Draft '), [0]);
    });
  });
}
