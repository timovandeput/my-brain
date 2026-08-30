@Tags(['scale'])
library;

import 'dart:io';

import 'package:my_brain/src/config.dart';
import 'package:my_brain/src/index/bm25.dart';
import 'package:my_brain/src/index/builder.dart';
import 'package:my_brain/src/index/reader.dart';
import 'package:my_brain/src/model.dart';
import 'package:my_brain/src/text/tokenizer.dart';
import 'package:my_brain/src/vault/scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The whole point of the index is that retrieval stays fast when the vault
/// gets big enough that an agent could not read it. These bounds are generous
/// against measured numbers (a 5,000-note build indexes in ~2.5s and searches
/// in well under 50ms in-process) so the test catches an algorithmic
/// regression - a full-index deserialisation on the search path, an O(N) scan
/// per query - rather than machine-to-machine noise.
const int noteCount = 5000;

void main() {
  late Directory dir;
  late BrainConfig config;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('brain_scale_');
    config = BrainConfig(vaultRoot: dir.path);

    const topics = [
      'postgres',
      'kubernetes',
      'attention',
      'dart',
      'retrieval',
      'habits',
      'pricing',
      'testing',
      'latency',
      'caching',
      'onboarding',
      'refactoring',
    ];
    const nouns = [
      'throughput',
      'tail latency',
      'cognitive load',
      'index size',
      'write amplification',
      'churn',
      'recall',
      'cycle time',
    ];

    for (var i = 0; i < noteCount; i++) {
      final topic = topics[i % topics.length];
      final other = topics[(i * 7) % topics.length];
      final body = StringBuffer();
      for (var line = 0; line < 12; line++) {
        body.writeln(
          'The $topic affects ${nouns[(i + line) % nouns.length]} '
          'when $other is under load.',
        );
      }
      final file = File(
        p.join(dir.path, 'notes', '${i ~/ 200}', 'note-$i.md'),
      );
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '---\ntitle: Note $i on $topic\n'
        'tags: [$topic, $other]\ntype: note\nproject: p${i % 17}\n---\n\n'
        '# Note $i on $topic\n\n$body\n'
        'See also [[note-${(i + 1) % noteCount}]].\n',
      );
    }

    // One note nothing else resembles, to prove a needle is findable.
    File(p.join(dir.path, 'notes', 'needle.md')).writeAsStringSync(
      '---\ntitle: Sourdough Hydration\ntags: [baking]\n---\n\n'
      '# Sourdough Hydration\n\n'
      'A 78 percent hydration dough is slack and needs coil folds.\n',
    );
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  test('indexes $noteCount notes in reasonable time', () async {
    final manifest = await VaultScanner(config).scan();
    expect(manifest.files, hasLength(noteCount + 1));

    final watch = Stopwatch()..start();
    final stats = await IndexBuilder(config, const Analyzer()).build(manifest);
    watch.stop();

    expect(stats.docCount, noteCount + 1);
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 60)),
      reason: 'indexing got dramatically slower',
    );
  });

  test('search stays fast and finds the needle', () async {
    final reader = await IndexReader.open(config.indexPath);
    addTearDown(reader.close);
    final searcher = Searcher(reader, config);
    const analyzer = Analyzer();

    // Warm the file handle so the measurement is the query, not the open.
    await searcher.search(SearchQuery(terms: analyzer.analyze('postgres')));

    final watch = Stopwatch()..start();
    final hits = await searcher.search(
      SearchQuery(terms: analyzer.analyze('sourdough hydration coil folds')),
    );
    watch.stop();

    expect(hits.first.doc.path, 'notes/needle.md');
    expect(
      watch.elapsedMilliseconds,
      lessThan(500),
      reason: 'search should not scale with vault size',
    );
  });

  test('a query on the most common term does not degrade', () async {
    final reader = await IndexReader.open(config.indexPath);
    addTearDown(reader.close);
    final searcher = Searcher(reader, config);

    // 'postgres' appears in roughly a twelfth of the vault, so this walks a
    // long postings list - the case where a naive full sort of candidates
    // would show up.
    final watch = Stopwatch()..start();
    final hits = await searcher.search(
      SearchQuery(
          terms: const Analyzer().analyze('postgres under load'), limit: 10),
    );
    watch.stop();

    expect(hits, hasLength(10));
    expect(watch.elapsedMilliseconds, lessThan(1000));
  });

  test('filtering narrows results without a full scan', () async {
    final reader = await IndexReader.open(config.indexPath);
    addTearDown(reader.close);
    final searcher = Searcher(reader, config);

    final hits = await searcher.search(SearchQuery(
      terms: const Analyzer().analyze('latency'),
      filters: const {
        'project': ['p3']
      },
      limit: 20,
    ));

    expect(hits, isNotEmpty);
    for (final hit in hits) {
      final index = int.parse(
        RegExp(r'note-(\d+)').firstMatch(hit.doc.path)!.group(1)!,
      );
      expect(index % 17, 3, reason: 'filter must not leak other projects');
    }
  });
}
