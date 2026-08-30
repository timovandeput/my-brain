import 'dart:io';

import 'package:my_brain/src/cli/vault_context.dart' show CliError;
import 'package:my_brain/src/config.dart';
import 'package:my_brain/src/edit/rewriter.dart';
import 'package:my_brain/src/index/builder.dart';
import 'package:my_brain/src/index/reader.dart';
import 'package:my_brain/src/model.dart';
import 'package:my_brain/src/text/tokenizer.dart';
import 'package:my_brain/src/vault/scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Matches a thrown [CliError].
final Matcher _throwsCliError = throwsA(isA<CliError>());

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
        'notes/target.md':
            '---\ntitle: Deep Work\n---\n\n# Deep Work\n\nBody.\n',
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

      expect(
          File(p.join(dir.path, 'notes', 'target.md')).existsSync(), isFalse);
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
      await rewriter
          .apply(rewriter.planRename('target.md', 'archive/2026/t.md'));
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
      expect(() => rewriter.planRename('a.md', 'b.md'), _throwsCliError);
    });
  });

  group('collision safety (bug 1)', () {
    test(
        'planRename throws before any file is touched, so --dry-run '
        'reports the collision too', () async {
      final v = await _vault(dir, {
        'a.md': '# A\n',
        'b.md': '# B\n',
        'ref.md': 'See [[a]].\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      expect(() => rewriter.planRename('a.md', 'b.md'), _throwsCliError);

      // Nothing on disk moved or changed: the referrer was never rewritten,
      // the source was never moved, and the pre-existing destination is
      // untouched.
      expect(read('a.md'), '# A\n');
      expect(read('b.md'), '# B\n');
      expect(read('ref.md'), 'See [[a]].\n');
    });

    test('a genuinely missing note raises CliError, not ArgumentError',
        () async {
      final v = await _vault(dir, {'a.md': '# A\n'});
      expect(
        () => LinkRewriter(v.config, v.docs).planRename('nope.md', 'x.md'),
        _throwsCliError,
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
      expect(
          File(p.join(dir.path, 'notes', 'target.md')).existsSync(), isFalse);
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

  group('markdown links (bug 3)', () {
    test('rename rewrites a markdown link target, keeping the display text',
        () async {
      final v = await _vault(dir, {
        'notes/target.md': '# Target\n',
        'notes/ref.md': 'See [Target](target.md) for more.\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      final plan = rewriter.planRename('notes/target.md', 'notes/moved.md');
      expect(plan.edits, hasLength(1));

      await rewriter.apply(plan);
      expect(read('notes/ref.md'), 'See [Target](moved.md) for more.\n');
    });

    test('a markdown link written as a path keeps the path style', () async {
      final v = await _vault(dir, {
        'notes/target.md': '# Target\n',
        'notes/ref.md': 'See [Target](notes/target.md) for more.\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      await rewriter
          .apply(rewriter.planRename('notes/target.md', 'archive/moved.md'));
      expect(
        read('notes/ref.md'),
        'See [Target](archive/moved.md) for more.\n',
      );
    });

    test('delete replaces a markdown link with its display text', () async {
      final v = await _vault(dir, {
        'notes/target.md': '# Target\n',
        'notes/ref.md': 'See [Target](target.md) for more.\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      await rewriter.apply(rewriter.planDelete('notes/target.md'));
      expect(read('notes/ref.md'), 'See Target for more.\n');
    });

    test('an attachment link is left alone and never lands in unresolved',
        () async {
      final v = await _vault(dir, {
        'notes/target.md': '# Target\n',
        'notes/ref.md': 'See [Target](target.md) and '
            '![diagram](../assets/diagram.png).\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      final plan = rewriter.planRename('notes/target.md', 'notes/moved.md');
      expect(plan.edits, hasLength(1), reason: 'only the note link counts');
      expect(plan.unresolved, isEmpty);

      await rewriter.apply(plan);
      expect(
        read('notes/ref.md'),
        contains('![diagram](../assets/diagram.png)'),
      );
    });
  });

  group('bare-name rename keeps the source directory (bug 6)', () {
    test('renaming to a bare new name keeps the note in its directory',
        () async {
      final v = await _vault(dir, {
        'notes/sub/gamma.md': '# Gamma\n',
        'notes/sub/ref.md': 'See [[Gamma]].\n',
      });

      final rewriter = LinkRewriter(v.config, v.docs);
      final plan = rewriter.planRename('notes/sub/gamma.md', 'Delta');
      expect(plan.to, 'notes/sub/Delta.md');

      await rewriter.apply(plan);
      expect(
        File(p.join(dir.path, 'notes', 'sub', 'Delta.md')).existsSync(),
        isTrue,
      );
      expect(File(p.join(dir.path, 'Delta.md')).existsSync(), isFalse,
          reason: 'must not have relocated to the vault root');
    });

    test('a root-level note with a bare new name stays at the root', () async {
      final v = await _vault(dir, {'gamma.md': '# Gamma\n'});
      final plan =
          LinkRewriter(v.config, v.docs).planRename('gamma.md', 'delta');
      expect(plan.to, 'delta.md');
    });
  });

  group('unresolved lists only actual referrers (bug 7)', () {
    test(
        'a since-deleted file that never linked to the target is not '
        'reported', () async {
      final v = await _vault(dir, {
        'target.md': '# Target\n',
        'unrelated.md': 'Nothing to see here.\n',
      });
      // Simulate a stale index: unrelated.md was deleted from disk after
      // indexing, without ever linking to target.md.
      File(p.join(dir.path, 'unrelated.md')).deleteSync();

      final plan =
          LinkRewriter(v.config, v.docs).planRename('target.md', 'moved.md');
      expect(plan.unresolved, isEmpty);
    });

    test('a since-deleted file that did link to the target is reported',
        () async {
      final v = await _vault(dir, {
        'target.md': '# Target\n',
        'ref.md': 'See [[target]].\n',
      });
      File(p.join(dir.path, 'ref.md')).deleteSync();

      final plan =
          LinkRewriter(v.config, v.docs).planRename('target.md', 'moved.md');
      expect(plan.unresolved, {'ref.md': 'file no longer exists'});
    });
  });
}
