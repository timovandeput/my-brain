import 'dart:io';
import 'dart:math' as math;

import 'package:my_brain/src/config.dart';
import 'package:my_brain/src/index/bm25.dart';
import 'package:my_brain/src/index/builder.dart';
import 'package:my_brain/src/index/reader.dart';
import 'package:my_brain/src/model.dart';
import 'package:my_brain/src/text/tokenizer.dart';
import 'package:my_brain/src/vault/scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('bm25TermScore against hand-computed values', () {
    test('matches manual arithmetic for a typical case', () {
      // N=10, df=2, tf=3, docLength=50, avgDocLen=40, k1=1.2, b=0.75.
      // idf = ln(1 + (10 - 2 + 0.5) / (2 + 0.5)) = ln(1 + 8.5/2.5) = ln(4.4)
      final idf = math.log(1 + 8.5 / 2.5);
      // norm = 1 - 0.75 + 0.75 * 50/40 = 0.25 + 0.9375 = 1.1875
      const norm = 0.25 + 0.75 * 50 / 40;
      // score = idf * (3 * 2.2) / (3 + 1.2 * 1.1875)
      final expected = idf * (3 * 2.2) / (3 + 1.2 * norm);

      final actual = bm25TermScore(
        tf: 3,
        docFreq: 2,
        docCount: 10,
        docLength: 50,
        avgDocLen: 40,
        k1: 1.2,
        b: 0.75,
      );
      expect(actual, closeTo(expected, 1e-12));
    });

    test('matches manual arithmetic when docLength == avgDocLen (norm=1)', () {
      // norm collapses to 1 - b + b = 1, independent of b.
      final idf = math.log(1 + (100 - 5 + 0.5) / (5 + 0.5));
      final expected = idf * (4 * (1.2 + 1)) / (4 + 1.2 * 1);
      final actual = bm25TermScore(
        tf: 4,
        docFreq: 5,
        docCount: 100,
        docLength: 30,
        avgDocLen: 30,
        k1: 1.2,
        b: 0.75,
      );
      expect(actual, closeTo(expected, 1e-12));
    });

    test('guards avgDocLen <= 0 by skipping length normalisation', () {
      // With avgDocLen <= 0 the norm term must behave as if norm == 1,
      // regardless of docLength or b.
      final withGuard = bm25TermScore(
        tf: 2,
        docFreq: 3,
        docCount: 20,
        docLength: 999,
        avgDocLen: 0,
        k1: 1.2,
        b: 0.75,
      );
      final normOne = bm25TermScore(
        tf: 2,
        docFreq: 3,
        docCount: 20,
        docLength: 30,
        avgDocLen: 30,
        k1: 1.2,
        b: 0.75,
      );
      expect(withGuard, closeTo(normOne, 1e-12));

      final withNegative = bm25TermScore(
        tf: 2,
        docFreq: 3,
        docCount: 20,
        docLength: 999,
        avgDocLen: -5,
        k1: 1.2,
        b: 0.75,
      );
      expect(withNegative, closeTo(normOne, 1e-12));
    });

    test('a rarer term outscores a common term at equal tf', () {
      final rare = bm25TermScore(
        tf: 5,
        docFreq: 1,
        docCount: 1000,
        docLength: 100,
        avgDocLen: 100,
        k1: 1.2,
        b: 0.75,
      );
      final common = bm25TermScore(
        tf: 5,
        docFreq: 900,
        docCount: 1000,
        docLength: 100,
        avgDocLen: 100,
        k1: 1.2,
        b: 0.75,
      );
      expect(rare, greaterThan(common));
    });

    test('a shorter document outscores a longer one at equal tf', () {
      final shorter = bm25TermScore(
        tf: 3,
        docFreq: 10,
        docCount: 500,
        docLength: 20,
        avgDocLen: 100,
        k1: 1.2,
        b: 0.75,
      );
      final longer = bm25TermScore(
        tf: 3,
        docFreq: 10,
        docCount: 500,
        docLength: 400,
        avgDocLen: 100,
        k1: 1.2,
        b: 0.75,
      );
      expect(shorter, greaterThan(longer));
    });
  });

  group('Searcher end-to-end', () {
    late Directory tempDir;
    late BrainConfig config;
    late IndexReader reader;
    late Searcher searcher;

    // A small corpus:
    //  0: "alpha beta"     status=draft   project=apollo
    //  1: "alpha"          status=draft   project=zeta
    //  2: "alpha alpha"    status=final   project=apollo
    //  3: "beta gamma"     status=final   project=zeta
    //  4: "gamma"          status=draft   project=apollo
    IndexableDoc doc(
            int i, List<String> bodyTerms, String status, String project) =>
        IndexableDoc(
          path: 'notes/doc-$i.md',
          title: 'Doc $i',
          aliases: const [],
          headings: const [],
          outLinks: const [],
          wordCount: bodyTerms.length,
          mtimeMs: 1000 + i,
          size: 100 + i,
          terms: [for (final t in bodyTerms) FieldTerm(t, Field.body)],
          attributes: {
            'status': [status],
            'project': [project],
          },
        );

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('my_brain_bm25_test_');
      config = BrainConfig(vaultRoot: tempDir.path);
      final docs = [
        doc(0, ['alpha', 'beta'], 'draft', 'apollo'),
        doc(1, ['alpha'], 'draft', 'zeta'),
        doc(2, ['alpha', 'alpha'], 'final', 'apollo'),
        doc(3, ['beta', 'gamma'], 'final', 'zeta'),
        doc(4, ['gamma'], 'draft', 'apollo'),
      ];
      final writer = IndexWriter(config, List<int>.filled(32, 0));
      await writer.writeTo(docs);
      reader = await IndexReader.open(config.indexPath);
      searcher = Searcher(reader, config);
    });

    tearDown(() async {
      await reader.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'ranks docs containing the query term above those without it, '
        'tying exactly and breaking the tie on path ascending', () async {
      final hits = await searcher.search(const SearchQuery(terms: ['beta']));
      // doc-0 ("alpha beta", length 2) and doc-3 ("beta gamma", length 2)
      // have identical tf, docFreq and docLength for "beta", so their BM25
      // scores are exactly equal - the only thing that can order them is
      // the path tie-break.
      expect(hits.map((h) => h.doc.path).toList(),
          ['notes/doc-0.md', 'notes/doc-3.md']);
      expect(hits[0].score, closeTo(hits[1].score, 1e-12));
      for (final h in hits) {
        expect(h.matchedTerms, ['beta']);
        expect(h.score, greaterThan(0));
      }
    });

    test('scores rank higher term frequency and shorter docs above lower',
        () async {
      // All three docs contain "alpha"; avgDocLen = (2+1+2+2+1)/5 = 1.6.
      //  doc-2: "alpha alpha" -> tf 2, length 2 -> highest score
      //  doc-1: "alpha"       -> tf 1, length 1 (shorter than doc-0)
      //  doc-0: "alpha beta"  -> tf 1, length 2
      final hits = await searcher.search(const SearchQuery(terms: ['alpha']));
      expect(hits.map((h) => h.doc.path).toList(), [
        'notes/doc-2.md',
        'notes/doc-1.md',
        'notes/doc-0.md',
      ]);
    });

    test('deterministic tie-breaking on path ascending', () async {
      // "gamma" appears once in doc-3 (2 terms) and doc-4 (1 term); doc-4 is
      // shorter so should rank first on score, not path - but with a limit
      // of 1 the top result must be reproducible across repeated runs.
      final first = await searcher.search(const SearchQuery(terms: ['gamma']));
      final second = await searcher.search(const SearchQuery(terms: ['gamma']));
      expect(first.map((h) => h.doc.path).toList(),
          second.map((h) => h.doc.path).toList());
    });

    test('filters: same key ORs its values', () async {
      final hits = await searcher.search(const SearchQuery(
        terms: ['alpha', 'beta', 'gamma'],
        filters: {
          'project': ['zeta'],
        },
      ));
      expect(hits.map((h) => h.doc.path).toSet(),
          {'notes/doc-1.md', 'notes/doc-3.md'});
    });

    test('filters: different keys AND (intersection)', () async {
      final hits = await searcher.search(const SearchQuery(
        terms: ['alpha', 'beta', 'gamma'],
        filters: {
          'status': ['draft'],
          'project': ['apollo'],
        },
      ));
      // status=draft -> {0,1,4}; project=apollo -> {0,2,4}; AND -> {0,4}
      expect(hits.map((h) => h.doc.path).toSet(),
          {'notes/doc-0.md', 'notes/doc-4.md'});
    });

    test('filters: OR within a key combined with AND across keys', () async {
      final hits = await searcher.search(const SearchQuery(
        terms: ['alpha', 'beta', 'gamma'],
        filters: {
          'project': ['apollo', 'zeta'], // OR -> all docs
          'status': ['final'], // AND -> {2,3}
        },
      ));
      expect(hits.map((h) => h.doc.path).toSet(),
          {'notes/doc-2.md', 'notes/doc-3.md'});
    });

    test('a never-indexed filter value yields zero results', () async {
      final hits = await searcher.search(const SearchQuery(
        terms: ['alpha'],
        filters: {
          'status': ['archived'],
        },
      ));
      expect(hits, isEmpty);
    });

    test('notFilters exclude matching documents', () async {
      final hits = await searcher.search(const SearchQuery(
        terms: ['alpha', 'beta', 'gamma'],
        notFilters: {
          'status': ['draft'],
        },
      ));
      expect(hits.map((h) => h.doc.path).toSet(),
          {'notes/doc-2.md', 'notes/doc-3.md'});
    });

    test('pathPrefix restricts to matching paths (opt-in O(N) path)', () async {
      final hits = await searcher.search(const SearchQuery(
        terms: ['alpha', 'beta', 'gamma'],
        pathPrefix: 'notes/doc-0',
      ));
      expect(hits.map((h) => h.doc.path).toSet(), {'notes/doc-0.md'});
    });

    test('limit bounds the number of hits', () async {
      final hits = await searcher.search(const SearchQuery(
        terms: ['alpha', 'beta', 'gamma'],
        limit: 2,
      ));
      expect(hits, hasLength(2));
    });

    test('unknown query terms contribute nothing but do not error', () async {
      final hits = await searcher.search(
        const SearchQuery(terms: ['alpha', 'zzz-nonexistent']),
      );
      expect(hits, isNotEmpty);
      for (final h in hits) {
        expect(h.matchedTerms, ['alpha']);
      }
    });

    test('similarTo returns empty when the source file no longer exists',
        () async {
      // The synthetic docs in this suite were never written under
      // vaultRoot, so the file genuinely does not exist; this exercises
      // similarTo's missing-file short-circuit without needing real files
      // on disk.
      final rec = await reader.doc(0);
      final hits = await searcher.similarTo(rec);
      expect(hits, isEmpty);
    });
  });

  group('Searcher.similarTo on real files', () {
    late Directory tempDir;
    late BrainConfig config;
    late IndexReader reader;
    late Searcher searcher;

    // Shared body content so notes/a.md, notes/b.md and notes/c.md are
    // genuine near-duplicates: the same distinctive, indexed body terms.
    const sharedBody = '''
# Quarterly Roadmap

The widget platform roadmap covers timeline milestones, budget approval,
stakeholder signoff and deliverable tracking for the upcoming quarter.
Engineering, design and product all review the roadmap before it ships.
''';

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('my_brain_similar_test_');
      config = BrainConfig(vaultRoot: tempDir.path);

      // note-a.md carries a large frontmatter block - twenty keys whose
      // values are nonsense words that appear nowhere else in the vault.
      // Before the fix, analyzing the raw file source (frontmatter
      // included) fed these zero-docFreq terms into similarTo's query
      // budget; being unmatchable anywhere, they crowded out the shared
      // body terms and the note showed up as having no similar notes.
      final frontmatterLines = StringBuffer('---\n');
      for (var i = 0; i < 20; i++) {
        frontmatterLines.writeln('customfield$i: nonsenseval$i');
      }
      frontmatterLines.writeln('---');
      File(p.join(tempDir.path, 'notes', 'note-a.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('$frontmatterLines\n$sharedBody');

      File(p.join(tempDir.path, 'notes', 'note-b.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('---\nstatus: draft\n---\n\n$sharedBody');

      File(p.join(tempDir.path, 'notes', 'note-c.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('---\nstatus: draft\n---\n\n$sharedBody');

      File(p.join(tempDir.path, 'notes', 'unrelated.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '---\nstatus: draft\n---\n\n# Sourdough\n\nHydration and coil folds for sourdough bread baking.\n',
        );

      final manifest = await VaultScanner(config).scan();
      await IndexBuilder(config, const Analyzer()).build(manifest);
      reader = await IndexReader.open(config.indexPath);
      searcher = Searcher(reader, config);
    });

    tearDown(() async {
      await reader.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'finds near-duplicate peers for a note with heavy frontmatter '
        '(regression: frontmatter terms used to crowd out the query budget)',
        () async {
      final docs = await reader.allDocs();
      final noteA = docs.firstWhere((d) => d.path == 'notes/note-a.md');

      final hits = await searcher.similarTo(noteA);

      expect(hits, isNotEmpty,
          reason: 'a note with a shared body must find its near-duplicate '
              'peers even when its frontmatter is large');
      expect(
        hits.map((h) => h.doc.path).toSet(),
        {'notes/note-b.md', 'notes/note-c.md'},
      );
      expect(hits.map((h) => h.doc.path), isNot(contains('notes/note-a.md')));
    });

    test('a sparse-frontmatter peer also finds its duplicates', () async {
      final docs = await reader.allDocs();
      final noteB = docs.firstWhere((d) => d.path == 'notes/note-b.md');

      final hits = await searcher.similarTo(noteB);

      expect(
        hits.map((h) => h.doc.path).toSet(),
        {'notes/note-a.md', 'notes/note-c.md'},
      );
    });
  });
}
