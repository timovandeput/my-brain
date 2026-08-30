// Regression coverage for bug 2: `rename` and `rm` mutate files, so a stale
// index (one missing a note added or changed since the last `my-brain
// index`) must be refused outright rather than merely warned about - the
// missed note's links to the target would otherwise be silently orphaned.
//
// This drives the commands through `runCli` end to end rather than calling
// `RenameCommand`/`RmCommand` directly, because the staleness check lives at
// the command layer (`VaultContext.checkStaleness`), not in `LinkRewriter`.
import 'dart:io';

import 'package:my_brain/my_brain.dart';
import 'package:my_brain/src/text/tokenizer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Builds a vault on disk with a `.brain/index.bin` built from exactly
/// [indexed]; [indexed] and any files added afterwards via [addAfterIndex]
/// let a test control precisely what the index does and doesn't know about.
Future<BrainConfig> _vault(
  Directory dir,
  Map<String, String> indexed,
) async {
  for (final entry in indexed.entries) {
    final file = File(p.join(dir.path, p.joinAll(entry.key.split('/'))));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  final config = BrainConfig(vaultRoot: dir.path);
  Directory(config.brainDir).createSync(recursive: true);
  final manifest = await VaultScanner(config).scan();
  await IndexBuilder(config, const Analyzer()).build(manifest);
  return config;
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('brain_stale_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String read(String relative) =>
      File(p.join(dir.path, p.joinAll(relative.split('/')))).readAsStringSync();

  group('rename refuses on a stale index (bug 2)', () {
    test(
        'a note added after indexing keeps its link, and the target is '
        'not moved', () async {
      await _vault(dir, {
        'target.md': '# Target\n',
        'ref.md': 'See [[target]].\n',
      });
      // Added after the index was built: the index has no idea it links to
      // target.md.
      File(p.join(dir.path, 'new-ref.md'))
          .writeAsStringSync('Also see [[target]].\n');

      final code =
          await runCli(['rename', 'target', 'moved', '--vault', dir.path]);

      expect(code, isNot(0));
      expect(File(p.join(dir.path, 'target.md')).existsSync(), isTrue,
          reason: 'source must not have moved');
      expect(File(p.join(dir.path, 'moved.md')).existsSync(), isFalse);
      expect(read('ref.md'), 'See [[target]].\n');
      expect(read('new-ref.md'), 'Also see [[target]].\n');
    });

    test('--force proceeds despite the stale index', () async {
      await _vault(dir, {
        'target.md': '# Target\n',
        'ref.md': 'See [[target]].\n',
      });
      File(p.join(dir.path, 'new-ref.md'))
          .writeAsStringSync('Also see [[target]].\n');

      final code = await runCli(
          ['rename', 'target', 'moved', '--force', '--vault', dir.path]);

      expect(code, 0);
      expect(File(p.join(dir.path, 'target.md')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'moved.md')).existsSync(), isTrue);
      expect(read('ref.md'), contains('[[moved]]'));
    });

    test('a clean index proceeds without --force', () async {
      await _vault(dir, {
        'target.md': '# Target\n',
        'ref.md': 'See [[target]].\n',
      });

      final code =
          await runCli(['rename', 'target', 'moved', '--vault', dir.path]);

      expect(code, 0);
      expect(File(p.join(dir.path, 'moved.md')).existsSync(), isTrue);
      expect(read('ref.md'), contains('[[moved]]'));
    });
  });

  group('rm refuses on a stale index (bug 2)', () {
    test(
        'a note added after indexing keeps its link, and the target is '
        'not deleted', () async {
      await _vault(dir, {
        'target.md': '# Target\n',
        'ref.md': 'See [[target]].\n',
      });
      File(p.join(dir.path, 'new-ref.md'))
          .writeAsStringSync('Also see [[target]].\n');

      final code = await runCli(['rm', 'target', '--yes', '--vault', dir.path]);

      expect(code, isNot(0));
      expect(File(p.join(dir.path, 'target.md')).existsSync(), isTrue,
          reason: 'target must not have been deleted');
      expect(read('ref.md'), 'See [[target]].\n');
      expect(read('new-ref.md'), 'Also see [[target]].\n');
    });

    test('--force proceeds despite the stale index', () async {
      await _vault(dir, {
        'target.md': '# Target\n',
        'ref.md': 'See [[target]].\n',
      });
      File(p.join(dir.path, 'new-ref.md'))
          .writeAsStringSync('Also see [[target]].\n');

      final code = await runCli(
          ['rm', 'target', '--yes', '--force', '--vault', dir.path]);

      expect(code, 0);
      expect(File(p.join(dir.path, 'target.md')).existsSync(), isFalse);
      expect(read('ref.md'), 'See target.\n');
    });
  });
}
