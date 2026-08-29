import 'dart:io';

import 'package:my_brain/src/config.dart';
import 'package:my_brain/src/edit/rewriter.dart';
import 'package:my_brain/src/index/builder.dart';
import 'package:my_brain/src/index/reader.dart';
import 'package:my_brain/src/model.dart';
import 'package:my_brain/src/text/tokenizer.dart';
import 'package:my_brain/src/vault/scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Builds a real vault on disk, indexes it, and hands back the pieces the
/// rewriter needs. Going through the index rather than hand-built [DocRecord]s
/// is deliberate: rename correctness depends on `outLinks` and title/alias
/// resolution matching what the builder actually stored.
Future<({BrainConfig config, List<DocRecord> docs})> _vault(
  Directory dir,
  Map<String, String> files,
) async {
  for (final entry in files.entries) {
    final file = File(p.join(dir.path, p.joinAll(entry.key.split('/'))));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  final config = BrainConfig(vaultRoot: dir.path);
  final manifest = await VaultScanner(config).scan();
  await IndexBuilder(config, const Analyzer()).build(manifest);
  final reader = await IndexReader.open(config.indexPath);
  final docs = await reader.allDocs();
  await reader.close();
  return (config: config, docs: docs);
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('brain_rewrite_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String read(String relative) =>
      File(p.join(dir.path, p.joinAll(relative.split('/')))).readAsStringSync();

  group('planRename', () {
    test('preserves alias and anchor, and keeps bare-name links bare',
        () async {
      final v = await _vault(dir, {
        'notes/target.md': '---\ntitle: Deep Work\n---\n\n# Deep Work\n\nBody.\n',
        'notes/ref.md': '---\ntitle: Ref\n---\n\n'
            'Plain [[Deep Work]], alias [[Deep Work|focused effort]], '
            'anchor [[Deep Work#Claim]], both '
            '[[Deep Work#Claim|the ceiling]].\n',
      });

      final plan = LinkRewriter(v.config, v.docs)
          .planRename('notes/target.md', 'notes/deep-focus.md');

      expect(plan.edits, hasLength(4));
      expect(
        plan.edits.map((LinkEdit e) => e.after),
        containsAll(<String>[
          '[[deep-focus]]',
          '[[deep-focus|focused effort]]',
          '[[deep-focus#Claim]]',
          '[[deep-focus#Claim|the ceiling]]',
        ]),
      );
    });

    test('leaves links inside fenced and inline code alone', () async {
      final v = await _vault(dir, {
        'notes/target.md': '# Deep Work\n\nBody.\n',
        'notes/ref.md': 'Real [[Deep Work]].\n\n'
            '```markdown\nFake [[Deep Work]] in a fence.\n```\n\n'
            'Inline `[[Deep Work]]` too.\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      final plan = rewriter.planRename('notes/target.md', 'notes/renamed.md');
      expect(plan.edits, hasLength(1), reason: 'only the prose link counts');

      await rewriter.apply(plan);
      final after = read('notes/ref.md');
      expect(after, contains('Real [[renamed]].'));
      expect(after, contains('Fake [[Deep Work]] in a fence.'));
      expect(after, contains('Inline `[[Deep Work]]` too.'));
    });

    test('a link written as a path stays a path', () async {
      final v = await _vault(dir, {
        'notes/target.md': '# Target\n',
        'notes/ref.md': 'See [[notes/target]].\n',
      });

      final plan = LinkRewriter(v.config, v.docs)
          .planRename('notes/target.md', 'archive/moved.md');
      expect(plan.edits.single.after, '[[archive/moved]]');
    });

    test('adds a missing .md extension to the destination', () async {
      final v = await _vault(dir, {
        'notes/target.md': '# Target\n',
        'notes/ref.md': 'See [[target]].\n',
      });

      final plan = LinkRewriter(v.config, v.docs)
          .planRename('notes/target.md', 'notes/moved');
      expect(plan.to, 'notes/moved.md');
    });

    test('offsets survive frontmatter of any length', () async {
      // The parser reports offsets relative to the body; the file on disk
      // still has its frontmatter. A missing shift corrupts the splice.
      final longFrontmatter = StringBuffer('---\ntitle: Ref\ntags:\n');
      for (var i = 0; i < 40; i++) {
        longFrontmatter.writeln('  - tag$i');
      }
      longFrontmatter.writeln('---');

      final v = await _vault(dir, {
        'notes/target.md': '# Target\n',
        'notes/ref.md': '$longFrontmatter\nLink to [[target]] here.\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      await rewriter
          .apply(rewriter.planRename('notes/target.md', 'notes/moved.md'));

      final after = read('notes/ref.md');
      expect(after, contains('Link to [[moved]] here.'));
      expect(after, contains('  - tag39'), reason: 'frontmatter intact');
    });

    test('multiple links in one file all get rewritten', () async {
      final v = await _vault(dir, {
        'notes/target.md': '# Target\n',
        'notes/ref.md': 'a [[target]] b [[target|x]] c [[target]] d\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      await rewriter
          .apply(rewriter.planRename('notes/target.md', 'notes/moved.md'));
      expect(read('notes/ref.md'), 'a [[moved]] b [[moved|x]] c [[moved]] d\n');
    });
  });

  group('apply rename', () {
    test('moves the file and leaves no broken links', () async {
      final v = await _vault(dir, {
        'notes/target.md': '---\ntitle: Deep Work\n---\n\n# Deep Work\n',
        'notes/a.md': 'See [[Deep Work]].\n',
        'notes/b.md': 'Also [[Deep Work|it]].\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      await rewriter
          .apply(rewriter.planRename('notes/target.md', 'notes/focus.md'));

      expect(File(p.join(dir.path, 'notes', 'target.md')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'notes', 'focus.md')).existsSync(), isTrue);
      expect(read('notes/a.md'), contains('[[focus]]'));
      expect(read('notes/b.md'), contains('[[focus|it]]'));
    });

    test('creates the destination directory when it does not exist', () async {
      final v = await _vault(dir, {
        'target.md': '# Target\n',
        'ref.md': 'See [[target]].\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      await rewriter.apply(rewriter.planRename('target.md', 'archive/2026/t.md'));
      expect(
        File(p.join(dir.path, 'archive', '2026', 't.md')).existsSync(),
        isTrue,
      );
    });

    test('refuses to overwrite an existing destination', () async {
      final v = await _vault(dir, {
        'a.md': '# A\n',
        'b.md': '# B\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      expect(
        () => rewriter.apply(rewriter.planRename('a.md', 'b.md')),
        throwsArgumentError,
      );
    });
  });

  group('planDelete', () {
    test('replaces each link with the text a reader was meant to see',
        () async {
      final v = await _vault(dir, {
        'notes/target.md': '---\ntitle: Deep Work\n---\n\n# Deep Work\n',
        'notes/ref.md': 'Plain [[Deep Work]] and aliased '
            '[[Deep Work|focused effort]] and anchored '
            '[[Deep Work#Claim|the ceiling]].\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      await rewriter.apply(rewriter.planDelete('notes/target.md'));

      expect(
        read('notes/ref.md'),
        'Plain Deep Work and aliased focused effort and anchored '
        'the ceiling.\n',
      );
      expect(File(p.join(dir.path, 'notes', 'target.md')).existsSync(), isFalse);
    });

    test('deletes a note nothing points at', () async {
      final v = await _vault(dir, {'lonely.md': '# Lonely\n'});
      final rewriter = LinkRewriter(v.config, v.docs);
      final plan = rewriter.planDelete('lonely.md');
      expect(plan.edits, isEmpty);
      await rewriter.apply(plan);
      expect(File(p.join(dir.path, 'lonely.md')).existsSync(), isFalse);
    });
  });

  test('rejects a path that is not an indexed note', () async {
    final v = await _vault(dir, {'a.md': '# A\n'});
    expect(
      () => LinkRewriter(v.config, v.docs).planRename('nope.md', 'x.md'),
      throwsArgumentError,
    );
  });
}
