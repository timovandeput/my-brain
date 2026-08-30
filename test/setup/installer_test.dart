import 'dart:io';

import 'package:my_brain/src/setup/installer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late VaultInstaller installer;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('brain_init_');
    installer = VaultInstaller(vaultRoot: dir.path, version: '0.1.0');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void applyAll() {
    final plan = installer.plan();
    installer.applyDirectories(plan.missingDirectories);
    for (final change in plan.pending) {
      installer.applyChange(change);
    }
    installer.applySkillLink();
  }

  String read(String relative) =>
      File(p.join(dir.path, p.joinAll(relative.split('/')))).readAsStringSync();

  bool exists(String relative) =>
      File(p.join(dir.path, p.joinAll(relative.split('/')))).existsSync();

  test('a fresh vault gets config, instructions and both skills', () {
    applyAll();

    expect(exists('.brain/config.yaml'), isTrue);
    expect(exists('AGENTS.md'), isTrue);
    expect(exists('CLAUDE.md'), isTrue);
    expect(exists('.agents/skills/brain-capture/SKILL.md'), isTrue);
    expect(exists('.agents/skills/brain-maintain/SKILL.md'), isTrue);
    expect(read('CLAUDE.md').trim(), '@AGENTS.md');
  });

  test('a fresh vault gets the content directories', () {
    expect(
        installer.plan().missingDirectories, VaultInstaller.contentDirectories);
    applyAll();

    for (final name in VaultInstaller.contentDirectories) {
      expect(Directory(p.join(dir.path, name)).existsSync(), isTrue,
          reason: '$name/ must exist so notes never land in the root');
    }
  });

  test('a directory the user already has is not proposed again', () {
    Directory(p.join(dir.path, 'notes')).createSync();
    expect(installer.plan().missingDirectories, isNot(contains('notes')));
  });

  test('is idempotent: a second run has nothing to do', () {
    applyAll();
    expect(installer.plan().isUpToDate, isTrue);
    expect(installer.plan().pending, isEmpty);
  });

  test('the skills are reachable at .claude/skills', () {
    applyAll();
    final linked = File(
      p.join(dir.path, '.claude', 'skills', 'brain-capture', 'SKILL.md'),
    );
    expect(linked.existsSync(), isTrue, reason: 'symlink must resolve');
    expect(linked.readAsStringSync(), contains('name: brain-capture'));
  });

  test('both skills are marked manual-invocation-only', () {
    applyAll();
    for (final skill in ['brain-capture', 'brain-maintain']) {
      final text = read('.agents/skills/$skill/SKILL.md');
      expect(text, contains('ONLY when the user explicitly asks'));
      expect(text, contains('NEVER trigger'));
    }
  });

  group('AGENTS.md marker management', () {
    test('preserves user prose above and below the managed region', () {
      applyAll();
      final original = read('AGENTS.md');
      final start = original.indexOf(managedBegin);
      final end = original.indexOf(managedEnd) + managedEnd.length;

      File(p.join(dir.path, 'AGENTS.md')).writeAsStringSync(
        '# My own notes\n\nKeep this.\n\n'
        '${original.substring(start, end)}\n\n'
        '## Also mine\n\nAnd this.\n',
      );

      for (final change in installer.plan().pending) {
        installer.applyChange(change);
      }

      final after = read('AGENTS.md');
      expect(after, contains('# My own notes'));
      expect(after, contains('Keep this.'));
      expect(after, contains('## Also mine'));
      expect(after, contains('And this.'));
      expect(after, contains('Search first, always.'));
    });

    test('restores a managed region the user damaged', () {
      applyAll();
      final original = read('AGENTS.md');
      final start = original.indexOf(managedBegin);
      final end = original.indexOf(managedEnd) + managedEnd.length;
      File(p.join(dir.path, 'AGENTS.md')).writeAsStringSync(
        '${original.substring(0, start)}$managedBegin\nwiped\n$managedEnd'
        '${original.substring(end)}',
      );

      final plan = installer.plan();
      expect(plan.pending.map((FileChange c) => c.path), contains('AGENTS.md'));
      for (final change in plan.pending) {
        installer.applyChange(change);
      }
      expect(read('AGENTS.md'), original);
      expect(installer.plan().isUpToDate, isTrue);
    });

    test('appends the block below prose in a file that has no markers', () {
      File(p.join(dir.path, 'AGENTS.md'))
          .writeAsStringSync('# Pre-existing\n\nMine.\n');
      applyAll();

      final after = read('AGENTS.md');
      expect(after, startsWith('# Pre-existing'));
      expect(after, contains('Mine.'));
      expect(after, contains(managedBegin));
      expect(installer.plan().isUpToDate, isTrue, reason: 'must settle');
    });
  });

  test('config.yaml is written once and never overwritten', () {
    applyAll();
    final path = p.join(dir.path, '.brain', 'config.yaml');
    File(path).writeAsStringSync('split_threshold_words: 400\n');

    final change = installer
        .plan()
        .changes
        .firstWhere((FileChange c) => c.path.endsWith('config.yaml'));
    expect(change.kind, ChangeKind.keep);
    expect(File(path).readAsStringSync(), 'split_threshold_words: 400\n');
  });

  group('.claude/skills already exists as a real directory', () {
    test("copies alongside the user's own skills instead of deleting them", () {
      final mine = File(
        p.join(dir.path, '.claude', 'skills', 'my-own-skill', 'SKILL.md'),
      );
      mine.parent.createSync(recursive: true);
      mine.writeAsStringSync('mine\n');

      applyAll();

      expect(mine.existsSync(), isTrue, reason: 'user skill must survive');
      expect(
        File(p.join(dir.path, '.claude', 'skills', 'brain-capture', 'SKILL.md'))
            .existsSync(),
        isTrue,
      );
    });

    test('prunes a copied brain skill this version no longer ships', () {
      final stale = File(
        p.join(dir.path, '.claude', 'skills', 'brain-obsolete', 'SKILL.md'),
      );
      stale.parent.createSync(recursive: true);
      stale.writeAsStringSync('old\n');

      applyAll();

      expect(stale.existsSync(), isFalse);
      expect(
        Directory(p.join(dir.path, '.claude', 'skills', 'brain-capture'))
            .existsSync(),
        isTrue,
      );
    });
  });

  group('.gitignore', () {
    test('is left alone in a directory that is not a git repository', () {
      applyAll();
      expect(exists('.gitignore'), isFalse);
    });

    test('gets the index entries in a git repository', () {
      Directory(p.join(dir.path, '.git')).createSync();
      applyAll();
      expect(read('.gitignore'), contains('.brain/index.bin'));
    });

    test('appends to an existing .gitignore without duplicating', () {
      Directory(p.join(dir.path, '.git')).createSync();
      File(p.join(dir.path, '.gitignore')).writeAsStringSync('*.tmp\n');
      applyAll();

      final after = read('.gitignore');
      expect(after, startsWith('*.tmp'));
      expect(after, contains('.brain/index.bin'));
      expect(installer.plan().isUpToDate, isTrue);
    });
  });

  test('records where the agent should invoke the binary', () {
    applyAll();
    expect(read('AGENTS.md'), contains(installer.plan().binaryPath));
  });
}
