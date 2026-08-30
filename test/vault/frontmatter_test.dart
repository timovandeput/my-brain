import 'package:my_brain/src/vault/frontmatter.dart';
import 'package:test/test.dart';

void main() {
  group('parseFrontmatter', () {
    test('no frontmatter at all', () {
      final fm = parseFrontmatter('Just a plain note.\n\nWith a paragraph.');
      expect(fm.present, isFalse);
      expect(fm.malformed, isFalse);
      expect(fm.data, isEmpty);
      expect(fm.bodyOffset, 0);
      expect(fm.lineCount, 0);
    });

    test('empty source', () {
      final fm = parseFrontmatter('');
      expect(fm.present, isFalse);
      expect(fm, same(Frontmatter.none));
    });

    test(
        'a stray --- later in the document is a horizontal rule, not '
        'frontmatter', () {
      const source = 'Some intro text.\n\n---\n\nMore text after the rule.';
      final fm = parseFrontmatter(source);
      expect(fm.present, isFalse);
      expect(fm.bodyOffset, 0);
    });

    test('simple valid frontmatter', () {
      const source = '---\ntitle: Hello\nstatus: draft\n---\nBody text here.';
      final fm = parseFrontmatter(source);
      expect(fm.present, isTrue);
      expect(fm.malformed, isFalse);
      expect(fm.data['title'], 'Hello');
      expect(fm.data['status'], 'draft');
      expect(source.substring(fm.bodyOffset), 'Body text here.');
      expect(fm.lineCount, 4);
    });

    test('terminator can be ... instead of ---', () {
      const source = '---\ntitle: Hello\n...\nBody.';
      final fm = parseFrontmatter(source);
      expect(fm.present, isTrue);
      expect(fm.malformed, isFalse);
      expect(fm.data['title'], 'Hello');
      expect(source.substring(fm.bodyOffset), 'Body.');
    });

    test('CRLF line endings', () {
      const source = '---\r\ntitle: Hello\r\n---\r\nBody text.';
      final fm = parseFrontmatter(source);
      expect(fm.present, isTrue);
      expect(fm.malformed, isFalse);
      expect(fm.data['title'], 'Hello');
      expect(source.substring(fm.bodyOffset), 'Body text.');
    });

    test('hasWikiLink catches a link in a scalar value', () {
      const source = '---\ntitle: X\nproject: "[[Project Foo]]"\n---\nBody.';
      expect(parseFrontmatter(source).hasWikiLink, isTrue);
    });

    test('hasWikiLink catches a link in a list item', () {
      const source = '---\nrelated:\n  - "[[Project Foo]]"\n---\nBody.';
      expect(parseFrontmatter(source).hasWikiLink, isTrue);
    });

    test('hasWikiLink catches a link in a block that failed to parse', () {
      const source = '---\ntitle: [unterminated\nup: "[[Foo]]"\n---\nBody.';
      final fm = parseFrontmatter(source);
      expect(fm.malformed, isTrue);
      expect(fm.hasWikiLink, isTrue);
    });

    test('a link in the body is not a frontmatter link', () {
      const source = '---\ntitle: X\n---\nBody linking to [[Project Foo]].';
      expect(parseFrontmatter(source).hasWikiLink, isFalse);
    });

    test('no frontmatter means no frontmatter link', () {
      expect(parseFrontmatter('Body with [[Foo]].').hasWikiLink, isFalse);
    });

    test('malformed YAML never costs us the body', () {
      const source = '---\ntitle: [unterminated\n---\nThe body must survive.';
      final fm = parseFrontmatter(source);
      expect(fm.present, isTrue);
      expect(fm.malformed, isTrue);
      expect(fm.data, isEmpty);
      expect(source.substring(fm.bodyOffset), 'The body must survive.');
    });

    test('frontmatter that parses but is not a mapping is malformed', () {
      const source = '---\n- one\n- two\n---\nBody.';
      final fm = parseFrontmatter(source);
      expect(fm.present, isTrue);
      expect(fm.malformed, isTrue);
      expect(fm.data, isEmpty);
      expect(source.substring(fm.bodyOffset), 'Body.');
    });

    test('unterminated frontmatter block preserves everything as body', () {
      const source = '---\ntitle: Hello\nno closing fence here';
      final fm = parseFrontmatter(source);
      expect(fm.present, isTrue);
      expect(fm.malformed, isTrue);
      expect(fm.data, isEmpty);
      expect(
        source.substring(fm.bodyOffset),
        'title: Hello\nno closing fence here',
      );
    });

    test('empty frontmatter block is present but not malformed', () {
      const source = '---\n---\nBody.';
      final fm = parseFrontmatter(source);
      expect(fm.present, isTrue);
      expect(fm.malformed, isFalse);
      expect(fm.data, isEmpty);
      expect(source.substring(fm.bodyOffset), 'Body.');
    });

    test('nested maps and lists survive as plain Dart types', () {
      const source = '---\n'
          'meta:\n'
          '  owner: alice\n'
          '  count: 3\n'
          'items:\n'
          '  - a\n'
          '  - b\n'
          '---\n'
          'Body.';
      final fm = parseFrontmatter(source);
      expect(fm.data['meta'], isA<Map<String, Object?>>());
      expect((fm.data['meta']! as Map<String, Object?>)['owner'], 'alice');
      expect(fm.data['items'], isA<List<Object?>>());
      expect(fm.data['items'], ['a', 'b']);
    });
  });

  group('Frontmatter.flatten', () {
    test('scalars lowercase and trim', () {
      const source = '---\nstatus: "  Draft  "\ncount: 3\ndone: false\n---\nB';
      final fm = parseFrontmatter(source);
      final flat = fm.flatten();
      expect(flat['status'], ['draft']);
      expect(flat['count'], ['3']);
      expect(flat['done'], ['false']);
    });

    test('a list of scalars becomes one value per element', () {
      const source = '---\ntags: [Alpha, Beta, alpha]\n---\nB';
      final fm = parseFrontmatter(source);
      expect(fm.flatten()['tags'], ['alpha', 'beta', 'alpha']);
    });

    test('nested maps are skipped entirely', () {
      const source = '---\nmeta:\n  owner: alice\n---\nB';
      final fm = parseFrontmatter(source);
      expect(fm.flatten().containsKey('meta'), isFalse);
    });

    test('a list containing a map is skipped entirely', () {
      const source = '---\nitems:\n  - name: a\n  - name: b\n---\nB';
      final fm = parseFrontmatter(source);
      expect(fm.flatten().containsKey('items'), isFalse);
    });

    test('empty strings are dropped', () {
      const source = '---\ntitle: ""\ntags: ["", "real"]\n---\nB';
      final fm = parseFrontmatter(source);
      final flat = fm.flatten();
      expect(flat.containsKey('title'), isFalse);
      expect(flat['tags'], ['real']);
    });

    test('keys are lowercased and trimmed, insertion order preserved', () {
      const source = '---\nStatus: Draft\nType: Note\n---\nB';
      final fm = parseFrontmatter(source);
      expect(fm.flatten().keys.toList(), ['status', 'type']);
    });
  });
}
