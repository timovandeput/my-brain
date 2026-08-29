import 'package:my_brain/src/model.dart';
import 'package:my_brain/src/vault/linkgraph.dart';
import 'package:test/test.dart';

DocRecord doc({
  required int docId,
  required String path,
  String? title,
  List<String> aliases = const [],
  List<String> outLinks = const [],
}) =>
    DocRecord(
      docId: docId,
      path: path,
      title: title ?? path,
      aliases: aliases,
      headings: const [],
      outLinks: outLinks,
      length: 10,
      wordCount: 10,
      mtimeMs: 0,
      size: 0,
    );

void main() {
  group('LinkResolver.resolve', () {
    test('exact relative path', () {
      final a = doc(docId: 1, path: 'notes/a.md');
      final resolver = LinkResolver([a]);
      expect(resolver.resolve('notes/a.md'), same(a));
    });

    test('exact path is case-insensitive', () {
      final a = doc(docId: 1, path: 'Notes/A.md');
      final resolver = LinkResolver([a]);
      expect(resolver.resolve('notes/a.md'), same(a));
    });

    test('path with .md appended', () {
      final a = doc(docId: 1, path: 'notes/a.md');
      final resolver = LinkResolver([a]);
      expect(resolver.resolve('notes/a'), same(a));
    });

    test('unique filename stem, regardless of directory', () {
      final a = doc(docId: 1, path: 'deep/nested/target.md');
      final resolver = LinkResolver([a]);
      expect(resolver.resolve('target'), same(a));
    });

    test('exact title', () {
      final a = doc(docId: 1, path: 'a.md', title: 'Deep Work');
      final resolver = LinkResolver([a]);
      expect(resolver.resolve('Deep Work'), same(a));
      expect(resolver.resolve('deep work'), same(a));
    });

    test('exact alias', () {
      final a = doc(docId: 1, path: 'a.md', aliases: ['DW']);
      final resolver = LinkResolver([a]);
      expect(resolver.resolve('dw'), same(a));
    });

    test('resolution priority: path beats stem beats title beats alias', () {
      // stem match:
      final byStem = doc(docId: 1, path: 'x/target.md');
      // title match with the same target string:
      final byTitle = doc(docId: 2, path: 'y/other.md', title: 'target');
      final resolver = LinkResolver([byStem, byTitle]);
      expect(resolver.resolve('target'), same(byStem));
    });

    test('an empty target (same-file anchor) resolves to null, not broken',
        () {
      final a = doc(docId: 1, path: 'a.md');
      final resolver = LinkResolver([a]);
      expect(resolver.resolve(''), isNull);
      expect(resolver.resolve('   '), isNull);
      expect(resolver.brokenLinks().containsKey(''), isFalse);
    });

    test('an unresolvable target is null', () {
      final resolver = LinkResolver([doc(docId: 1, path: 'a.md')]);
      expect(resolver.resolve('nope'), isNull);
    });
  });

  group('LinkResolver.isAmbiguous', () {
    test('two docs sharing a filename stem are ambiguous', () {
      final a = doc(docId: 1, path: 'x/target.md');
      final b = doc(docId: 2, path: 'y/target.md');
      final resolver = LinkResolver([a, b]);
      expect(resolver.isAmbiguous('target'), isTrue);
    });

    test('ambiguous resolution picks the lexicographically first path', () {
      final a = doc(docId: 1, path: 'b/target.md');
      final b = doc(docId: 2, path: 'a/target.md');
      final resolver = LinkResolver([a, b]);
      expect(resolver.resolve('target'), same(b)); // 'a/...' < 'b/...'
    });

    test('a unique stem is not ambiguous', () {
      final a = doc(docId: 1, path: 'x/target.md');
      final resolver = LinkResolver([a]);
      expect(resolver.isAmbiguous('target'), isFalse);
    });

    test('isAmbiguous does not depend on resolve having been called first',
        () {
      final a = doc(docId: 1, path: 'x/target.md');
      final b = doc(docId: 2, path: 'y/target.md');
      final resolver = LinkResolver([a, b]);
      // Query isAmbiguous first, with no prior resolve() call.
      expect(resolver.isAmbiguous('target'), isTrue);
    });
  });

  group('LinkResolver.backlinksTo', () {
    test('finds documents whose outlinks resolve to the target', () {
      final target = doc(docId: 1, path: 'target.md');
      final a = doc(docId: 2, path: 'a.md', outLinks: ['target.md']);
      final b = doc(docId: 3, path: 'b.md', outLinks: ['target']);
      final c = doc(docId: 4, path: 'c.md', outLinks: ['unrelated.md']);
      final resolver = LinkResolver([target, a, b, c]);
      final backlinks = resolver.backlinksTo(target);
      expect(backlinks.map((d) => d.path).toList(), ['a.md', 'b.md']);
    });

    test('deduplicates repeated links from the same document', () {
      final target = doc(docId: 1, path: 'target.md');
      final a = doc(
        docId: 2,
        path: 'a.md',
        outLinks: ['target.md', 'target', 'Target.md'],
      );
      final resolver = LinkResolver([target, a]);
      expect(resolver.backlinksTo(target), hasLength(1));
    });

    test('a document with no backlinks has an empty list', () {
      final lonely = doc(docId: 1, path: 'lonely.md');
      final resolver = LinkResolver([lonely]);
      expect(resolver.backlinksTo(lonely), isEmpty);
    });

    test('results are sorted by path', () {
      final target = doc(docId: 1, path: 'target.md');
      final z = doc(docId: 2, path: 'z.md', outLinks: ['target.md']);
      final a = doc(docId: 3, path: 'a.md', outLinks: ['target.md']);
      final resolver = LinkResolver([target, z, a]);
      expect(resolver.backlinksTo(target).map((d) => d.path).toList(),
          ['a.md', 'z.md']);
    });
  });

  group('LinkResolver.brokenLinks', () {
    test('collects targets that resolve to nothing', () {
      final a = doc(
        docId: 1,
        path: 'a.md',
        outLinks: ['Missing Note', 'target.md'],
      );
      final target = doc(docId: 2, path: 'target.md');
      final resolver = LinkResolver([a, target]);
      final broken = resolver.brokenLinks();
      expect(broken.keys, ['Missing Note']);
      expect(broken['Missing Note']!.map((d) => d.path).toList(), ['a.md']);
    });

    test('same-file anchors are never reported as broken', () {
      final a = doc(docId: 1, path: 'a.md', outLinks: ['']);
      final resolver = LinkResolver([a]);
      expect(resolver.brokenLinks(), isEmpty);
    });

    test('multiple documents linking to the same broken target', () {
      final a = doc(docId: 1, path: 'a.md', outLinks: ['Nowhere']);
      final b = doc(docId: 2, path: 'b.md', outLinks: ['Nowhere']);
      final resolver = LinkResolver([a, b]);
      expect(resolver.brokenLinks()['Nowhere']!.map((d) => d.path).toList(),
          ['a.md', 'b.md']);
    });

    test('an empty vault has no broken links', () {
      final resolver = LinkResolver(const []);
      expect(resolver.brokenLinks(), isEmpty);
    });
  });
}
