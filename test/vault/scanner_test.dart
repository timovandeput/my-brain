import 'dart:io';

import 'package:my_brain/src/config.dart';
import 'package:my_brain/src/vault/scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('matchesGlob', () {
    test('star matches within one segment only', () {
      expect(matchesGlob('*.md', 'note.md'), isTrue);
      expect(matchesGlob('*.md', 'sub/note.md'), isFalse);
    });

    test('question mark matches exactly one character', () {
      expect(matchesGlob('a?c.md', 'abc.md'), isTrue);
      expect(matchesGlob('a?c.md', 'ac.md'), isFalse);
      expect(matchesGlob('a?c.md', 'abbc.md'), isFalse);
    });

    test('double star matches any depth', () {
      expect(matchesGlob('.git/**', '.git/objects/abc'), isTrue);
      expect(matchesGlob('.git/**', '.git/HEAD'), isTrue);
    });

    test('a pattern ending in /** also matches the directory itself', () {
      expect(matchesGlob('.git/**', '.git'), isTrue);
      expect(matchesGlob('node_modules/**', 'node_modules'), isTrue);
    });

    test('/** does not match a sibling directory with a shared prefix', () {
      expect(matchesGlob('.git/**', '.github'), isFalse);
      expect(matchesGlob('.git/**', '.github/workflows/ci.yml'), isFalse);
    });

    test('leading **/ matches any depth including zero', () {
      expect(matchesGlob('**/*.tmp', 'a.tmp'), isTrue);
      expect(matchesGlob('**/*.tmp', 'a/b/c.tmp'), isTrue);
    });

    test('regex metacharacters in the pattern are escaped', () {
      expect(matchesGlob('a.b', 'a.b'), isTrue);
      expect(matchesGlob('a.b', 'aXb'), isFalse);
      expect(matchesGlob('a+b.md', 'a+b.md'), isTrue);
    });

    test('full match required, not substring', () {
      expect(matchesGlob('note.md', 'sub/note.md'), isFalse);
      expect(matchesGlob('note.md', 'note.md.bak'), isFalse);
    });
  });

  group('VaultScanner', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('brain_scanner_test_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    BrainConfig config({List<String>? exclude, List<String>? extensions}) =>
        BrainConfig(
          vaultRoot: tmp.path,
          exclude: exclude ?? BrainConfig.defaultExclude,
          extensions: extensions ?? const ['.md', '.markdown'],
        );

    void writeFile(String relPath, String contents) {
      final file = File(p.join(tmp.path, relPath));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(contents);
    }

    test('empty vault yields an empty manifest with a stable hash', () async {
      final manifest = await VaultScanner(config()).scan();
      expect(manifest.files, isEmpty);
      final again = await VaultScanner(config()).scan();
      expect(manifest.hash, again.hash);
    });

    test('finds markdown files and sorts by path', () async {
      writeFile('b.md', '# B');
      writeFile('a.md', '# A');
      writeFile('sub/c.md', '# C');
      final manifest = await VaultScanner(config()).scan();
      expect(manifest.files.map((f) => f.path).toList(),
          ['a.md', 'b.md', 'sub/c.md']);
    });

    test('paths use forward slashes', () async {
      writeFile('sub/dir/note.md', 'x');
      final manifest = await VaultScanner(config()).scan();
      expect(manifest.files.single.path, 'sub/dir/note.md');
      expect(manifest.files.single.path.contains('\\'), isFalse);
    });

    test('filters by extension, case-insensitively', () async {
      writeFile('upper.MD', 'x'); // uppercase extension must still match.
      writeFile('note.txt', 'x');
      writeFile('note.markdown', 'x');
      final manifest = await VaultScanner(config()).scan();
      final paths = manifest.files.map((f) => f.path).toSet();
      expect(paths.contains('upper.MD'), isTrue);
      expect(paths.contains('note.txt'), isFalse);
      expect(paths.contains('note.markdown'), isTrue);
    });

    test('excluded directory is skipped entirely', () async {
      writeFile('.git/HEAD', 'ref');
      writeFile('.git/objects/abc.md', 'not a note');
      writeFile('real-note.md', 'x');
      final manifest = await VaultScanner(config()).scan();
      expect(manifest.files.map((f) => f.path).toList(), ['real-note.md']);
    });

    test('custom exclude pattern is honoured', () async {
      writeFile('drafts/a.md', 'x');
      writeFile('published/b.md', 'x');
      final manifest =
          await VaultScanner(config(exclude: ['drafts/**'])).scan();
      expect(manifest.files.map((f) => f.path).toList(), ['published/b.md']);
    });

    test('a symlinked directory is not followed (no hang on a loop)', () async {
      writeFile('real/note.md', 'x');
      final link = Link(p.join(tmp.path, 'real', 'loop'));
      try {
        link.createSync(tmp.path); // points back at the vault root.
      } on FileSystemException {
        return; // symlinks unsupported in this environment; skip.
      }
      final manifest = await VaultScanner(config()).scan().timeout(
            const Duration(seconds: 10),
          );
      expect(manifest.files.map((f) => f.path).toList(), ['real/note.md']);
    });

    test('a symlinked file is not indexed', () async {
      writeFile('real/note.md', 'x');
      final link = Link(p.join(tmp.path, 'linked.md'));
      try {
        link.createSync(p.join(tmp.path, 'real', 'note.md'));
      } on FileSystemException {
        return;
      }
      final manifest = await VaultScanner(config()).scan();
      expect(manifest.files.map((f) => f.path).toList(), ['real/note.md']);
    });

    test('manifest hash changes when a file changes size', () async {
      writeFile('a.md', 'short');
      final before = await VaultScanner(config()).scan();
      writeFile('a.md', 'a much longer piece of content than before');
      final after = await VaultScanner(config()).scan();
      expect(before.hash, isNot(after.hash));
    });

    test('isExcluded matches the same patterns scan() applies', () {
      final scanner = VaultScanner(config());
      expect(scanner.isExcluded('.git/objects/x'), isTrue);
      expect(scanner.isExcluded('notes/x.md'), isFalse);
    });
  });
}
