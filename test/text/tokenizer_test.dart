import 'package:my_brain/src/model.dart';
import 'package:my_brain/src/text/tokenizer.dart';
import 'package:my_brain/src/vault/frontmatter.dart';
import 'package:my_brain/src/vault/markdown.dart';
import 'package:test/test.dart';

void main() {
  group('Analyzer.split', () {
    const analyzer = Analyzer();

    test('lowercases and keeps whole run', () {
      expect(analyzer.split('Hello World').toList(), [
        'hello',
        'world',
      ]);
    });

    test('splits camelCase into whole + parts', () {
      expect(analyzer.split('parseFrontmatter').toList(), [
        'parsefrontmatter',
        'parse',
        'frontmatter',
      ]);
    });

    test('splits PascalCase acronyms', () {
      expect(analyzer.split('HTMLParser').toList(), [
        'htmlparser',
        'html',
        'parser',
      ]);
    });

    test('snake_case splits for free since _ breaks the run', () {
      expect(analyzer.split('parse_frontmatter').toList(), [
        'parse',
        'frontmatter',
      ]);
    });

    test('digit/letter boundary splits into whole + parts', () {
      expect(analyzer.split('html5parser').toList(), [
        'html5parser',
        'html',
        '5',
        'parser',
      ]);
    });

    test('plain word with no boundary emits once', () {
      expect(analyzer.split('meeting').toList(), ['meeting']);
    });

    test('unicode letters tokenize as whole words', () {
      expect(analyzer.split('café résumé').toList(), ['café', 'résumé']);
    });

    test('punctuation is not part of any token', () {
      expect(analyzer.split('hello, world!').toList(), ['hello', 'world']);
    });
  });

  group('Analyzer.analyze', () {
    test('drops short tokens', () {
      const analyzer =
          Analyzer(minLength: 3, stem: false, dropStopwords: false);
      expect(analyzer.analyze('a go id ai team'), ['team']);
    });

    test('drops stopwords before stemming (order matters)', () {
      // 'is' is a stopword; if stemming ran first and stopwords were checked
      // against the stemmed form this would behave differently for words
      // that only become stopwords after stemming, so this exercises the
      // documented order directly.
      const analyzer = Analyzer();
      expect(analyzer.analyze('this is a meeting'), ['meet']);
    });

    test('stems when enabled', () {
      const analyzer = Analyzer(dropStopwords: false);
      expect(analyzer.analyze('meetings'), ['meet']);
    });

    test('does not stem when disabled', () {
      const analyzer = Analyzer(stem: false, dropStopwords: false);
      expect(analyzer.analyze('meetings'), ['meetings']);
    });

    test('empty text yields no tokens', () {
      const analyzer = Analyzer();
      expect(analyzer.analyze(''), <String>[]);
    });
  });

  group('noteTerms', () {
    Analyzer analyzer() =>
        const Analyzer(minLength: 2, stem: true, dropStopwords: true);

    test('emits title, alias, heading, tag and body fields', () {
      const source = '''
---
title: Deep Work
aliases: [Focused Work, DW]
tags: [productivity, project/alpha]
---
# Deep Work

## Getting Started

Some #inline-tag content about focus and meetings.
''';
      final note = parseNote(source, filename: 'deep-work.md');
      final terms = noteTerms(note, analyzer()).toList();

      bool has(String term, Field field) =>
          terms.any((FieldTerm t) => t.term == term && t.field == field);

      expect(has('deep', Field.title), isTrue);
      expect(has('work', Field.title), isTrue);
      expect(has('focus', Field.alias), isTrue); // "focused" -> stem "focus"
      expect(has('dw', Field.alias), isTrue);
      expect(has('start', Field.heading), isTrue); // "started" -> "start"
      expect(has('product', Field.tag), isTrue); // "productivity" -> "product"
      expect(has('project/alpha', Field.tag), isTrue); // whole hierarchical
      expect(has('project', Field.tag), isTrue); // hierarchical part
      expect(has('alpha', Field.tag), isTrue); // hierarchical part
      expect(has('inlin', Field.tag), isTrue); // inline "#inline-tag" -> stem
      expect(has('meet', Field.body), isTrue);
      // Heading text also appears in the body field: it earns both weights.
      expect(has('start', Field.body), isTrue);
    });

    test('note with no frontmatter still yields title from filename', () {
      final note =
          parseNote('Just a body, no headings.', filename: 'plain-note.md');
      final terms = noteTerms(note, analyzer()).toList();
      expect(
        terms.any((FieldTerm t) => t.field == Field.title && t.term == 'plain'),
        isTrue,
      );
    });

    test('frontmatter without tags produces no tag terms', () {
      const source = '''
---
title: No Tags Here
---
Body text.
''';
      final note = parseNote(source, filename: 'x.md');
      final terms = noteTerms(note, analyzer());
      expect(terms.where((FieldTerm t) => t.field == Field.tag), isEmpty);
    });
  });

  group('Frontmatter.flatten via tag extraction', () {
    test('scalar tag value flattens to one entry', () {
      final fm = parseFrontmatter('---\ntags: solo\n---\nBody');
      expect(fm.flatten()['tags'], ['solo']);
    });
  });
}
