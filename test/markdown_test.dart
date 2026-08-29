import 'package:my_brain/src/vault/markdown.dart';
import 'package:test/test.dart';

void main() {
  group('codeSpans', () {
    test('fenced block with backticks', () {
      const body = 'before\n```\ncode [[not a link]]\n```\nafter';
      final spans = codeSpans(body);
      expect(spans, hasLength(1));
      final text = body.substring(spans.first.start, spans.first.end);
      expect(text, '```\ncode [[not a link]]\n```\n');
    });

    test('fenced block with tildes', () {
      const body = '~~~\ncode\n~~~\n';
      final spans = codeSpans(body);
      expect(spans, hasLength(1));
    });

    test('unterminated fence extends to end of file', () {
      const body = 'before\n```\nno closing fence\nmore code';
      final spans = codeSpans(body);
      expect(spans, hasLength(1));
      expect(spans.first.end, body.length);
    });

    test('closing fence must be at least as long as the opening', () {
      const body = '````\ncode with ``` inside\n````\nafter';
      final spans = codeSpans(body);
      expect(spans, hasLength(1));
      expect(body.substring(spans.first.end), 'after');
    });

    test('nested/adjacent fences: a fence char run shorter than the '
        'opening does not close it', () {
      const body = '```\n``\nstill code\n```\nafter';
      final spans = codeSpans(body);
      expect(spans, hasLength(1));
      expect(body.substring(spans.first.end), 'after');
    });

    test('two adjacent fenced blocks are separate spans', () {
      const body = '```\na\n```\n```\nb\n```\n';
      final spans = codeSpans(body);
      expect(spans, hasLength(2));
    });

    test('inline code span with single backticks', () {
      const body = 'text `code here` more text';
      final spans = codeSpans(body);
      expect(spans, hasLength(1));
      expect(body.substring(spans.first.start, spans.first.end), '`code here`');
    });

    test('inline code span delimited by double backticks can contain a '
        'single backtick', () {
      const body = 'text ``code ` here`` more';
      final spans = codeSpans(body);
      expect(spans, hasLength(1));
      expect(
        body.substring(spans.first.start, spans.first.end),
        '``code ` here``',
      );
    });

    test('unmatched backtick run is not a code span', () {
      const body = 'this ` has no closing backtick';
      final spans = codeSpans(body);
      expect(spans, isEmpty);
    });

    test('spans are sorted and non-overlapping', () {
      const body = '`a` then a fenced block:\n```\ncode\n```\nthen `b`';
      final spans = codeSpans(body);
      for (var i = 1; i < spans.length; i++) {
        expect(spans[i].start >= spans[i - 1].end, isTrue);
      }
      final starts = spans.map((Span s) => s.start).toList();
      final sortedStarts = [...starts]..sort();
      expect(starts, sortedStarts);
    });
  });

  group('parseNote headings', () {
    test('ATX headings, hashes and whitespace stripped', () {
      const source = '# Title\n\n## Sub Heading ##\n\n### Third\n';
      final note = parseNote(source, filename: 'x.md');
      expect(note.headings, ['Title', 'Sub Heading', 'Third']);
    });

    test('a hash without a following space is not a heading', () {
      const source = '#NotAHeading\n\nParagraph.';
      final note = parseNote(source, filename: 'x.md');
      expect(note.headings, isEmpty);
    });

    test('headings inside a fenced code block are ignored', () {
      const source = '```\n# Not a heading\n```\n\n# Real Heading\n';
      final note = parseNote(source, filename: 'x.md');
      expect(note.headings, ['Real Heading']);
    });
  });

  group('parseNote title', () {
    test('frontmatter title wins', () {
      const source = '---\ntitle: From Frontmatter\n---\n# From Body\n';
      final note = parseNote(source, filename: 'file.md');
      expect(note.title, 'From Frontmatter');
    });

    test('falls back to first H1 when no frontmatter title', () {
      const source = '## Not H1\n\n# The Real H1\n\nBody.';
      final note = parseNote(source, filename: 'file.md');
      expect(note.title, 'The Real H1');
    });

    test('falls back to filename stem when nothing else is present', () {
      final note = parseNote('Just a paragraph.', filename: 'my-note.md');
      expect(note.title, 'my-note');
    });

    test('unicode note titles are preserved as-is', () {
      const source = '# Café ☕ Résumé\n\nBody.';
      final note = parseNote(source, filename: 'x.md');
      expect(note.title, 'Café ☕ Résumé');
    });
  });

  group('parseNote wikilinks', () {
    test('plain wikilink', () {
      const source = 'See [[Other Note]] for details.';
      final note = parseNote(source, filename: 'x.md');
      expect(note.wikiLinks, hasLength(1));
      final link = note.wikiLinks.first;
      expect(link.target, 'Other Note');
      expect(link.alias, isNull);
      expect(link.anchor, isNull);
      expect(link.embed, isFalse);
    });

    test('wikilink with alias', () {
      const source = '[[Other Note|display text]]';
      final note = parseNote(source, filename: 'x.md');
      final link = note.wikiLinks.first;
      expect(link.target, 'Other Note');
      expect(link.alias, 'display text');
    });

    test('wikilink with anchor', () {
      const source = '[[Other Note#Some Heading]]';
      final note = parseNote(source, filename: 'x.md');
      final link = note.wikiLinks.first;
      expect(link.target, 'Other Note');
      expect(link.anchor, 'Some Heading');
      expect(link.alias, isNull);
    });

    test('wikilink with anchor and alias', () {
      const source = '[[Other Note#Heading|shown]]';
      final note = parseNote(source, filename: 'x.md');
      final link = note.wikiLinks.first;
      expect(link.target, 'Other Note');
      expect(link.anchor, 'Heading');
      expect(link.alias, 'shown');
    });

    test('wikilink with block id', () {
      const source = '[[Other Note^block-id]]';
      final note = parseNote(source, filename: 'x.md');
      final link = note.wikiLinks.first;
      expect(link.target, 'Other Note');
      expect(link.anchor, 'block-id');
    });

    test('same-file anchor link has an empty target, not a crash', () {
      const source = 'See [[#Some Heading]] above.';
      final note = parseNote(source, filename: 'x.md');
      final link = note.wikiLinks.first;
      expect(link.target, '');
      expect(link.anchor, 'Some Heading');
    });

    test('embed wikilink', () {
      const source = '![[image.png]]';
      final note = parseNote(source, filename: 'x.md');
      final link = note.wikiLinks.first;
      expect(link.target, 'image.png');
      expect(link.embed, isTrue);
      expect(link.start, 0); // offset of the `!`.
    });

    test('offsets are relative to the body, not the source', () {
      const source = '---\ntitle: X\n---\n[[Target]]';
      final note = parseNote(source, filename: 'x.md');
      final link = note.wikiLinks.first;
      expect(note.body.substring(link.start, link.end), '[[Target]]');
    });

    test('wikilink inside a fenced code block is skipped', () {
      const source = '```\n[[Not A Link]]\n```\n[[Real Link]]';
      final note = parseNote(source, filename: 'x.md');
      expect(note.wikiLinks, hasLength(1));
      expect(note.wikiLinks.first.target, 'Real Link');
    });

    test('wikilink inside an inline code span is skipped', () {
      const source = 'Some `[[Not A Link]]` and [[Real Link]].';
      final note = parseNote(source, filename: 'x.md');
      expect(note.wikiLinks, hasLength(1));
      expect(note.wikiLinks.first.target, 'Real Link');
    });
  });

  group('parseNote markdownLinks', () {
    test('relative link is captured', () {
      const source = 'See [Other](other-note.md) for details.';
      final note = parseNote(source, filename: 'x.md');
      expect(note.markdownLinks, ['other-note.md']);
    });

    test('http/https links are excluded', () {
      const source = '[a](http://example.com) [b](https://example.com)';
      final note = parseNote(source, filename: 'x.md');
      expect(note.markdownLinks, isEmpty);
    });

    test('mailto and other schemes are excluded', () {
      const source = '[email](mailto:a@example.com)';
      final note = parseNote(source, filename: 'x.md');
      expect(note.markdownLinks, isEmpty);
    });

    test('protocol-relative links are excluded', () {
      const source = '[cdn](//example.com/lib.js)';
      final note = parseNote(source, filename: 'x.md');
      expect(note.markdownLinks, isEmpty);
    });

    test('pure fragment links are excluded', () {
      const source = '[jump](#section)';
      final note = parseNote(source, filename: 'x.md');
      expect(note.markdownLinks, isEmpty);
    });

    test('an optional title is stripped', () {
      const source = '[a](other.md "A Title")';
      final note = parseNote(source, filename: 'x.md');
      expect(note.markdownLinks, ['other.md']);
    });

    test('percent-encoded targets are decoded', () {
      const source = '[a](my%20note.md)';
      final note = parseNote(source, filename: 'x.md');
      expect(note.markdownLinks, ['my note.md']);
    });

    test('link inside code span is skipped', () {
      const source = 'Some `[a](b.md)` and [c](d.md).';
      final note = parseNote(source, filename: 'x.md');
      expect(note.markdownLinks, ['d.md']);
    });
  });

  group('parseNote inlineTags', () {
    test('simple inline tag', () {
      final note = parseNote('This is #important stuff.', filename: 'x.md');
      expect(note.inlineTags, ['important']);
    });

    test('hierarchical tag kept whole, lowercased', () {
      final note = parseNote('#Project/Alpha work.', filename: 'x.md');
      expect(note.inlineTags, ['project/alpha']);
    });

    test('a tag made entirely of digits is not a tag', () {
      final note = parseNote('room #123 is booked.', filename: 'x.md');
      expect(note.inlineTags, isEmpty);
    });

    test('a heading marker is not a tag', () {
      final note = parseNote('# Heading text\n\nBody.', filename: 'x.md');
      expect(note.inlineTags, isEmpty);
    });

    test('a hash mid-word is not a tag', () {
      final note = parseNote('C#is a language', filename: 'x.md');
      expect(note.inlineTags, isEmpty);
    });

    test('tag inside a fenced code block is skipped', () {
      const source = '```\n#not-a-tag\n```\n#real-tag';
      final note = parseNote(source, filename: 'x.md');
      expect(note.inlineTags, ['real-tag']);
    });

    test('tag at start of string is captured', () {
      final note = parseNote('#first word.', filename: 'x.md');
      expect(note.inlineTags, ['first']);
    });
  });

  group('parseNote aliases', () {
    test('aliases as a list, not lowercased', () {
      const source = '---\naliases: [Foo Bar, BAZ]\n---\nBody.';
      final note = parseNote(source, filename: 'x.md');
      expect(note.aliases, ['Foo Bar', 'BAZ']);
    });

    test('alias (singular key) as a scalar', () {
      const source = '---\nalias: Solo Alias\n---\nBody.';
      final note = parseNote(source, filename: 'x.md');
      expect(note.aliases, ['Solo Alias']);
    });

    test('no aliases key yields an empty list', () {
      final note = parseNote('Body only.', filename: 'x.md');
      expect(note.aliases, isEmpty);
    });
  });

  group('parseNote wordCount', () {
    test('counts whitespace-separated runs', () {
      final note = parseNote('one two   three\nfour', filename: 'x.md');
      expect(note.wordCount, 4);
    });

    test('empty body has zero words', () {
      final note = parseNote('---\ntitle: X\n---\n', filename: 'x.md');
      expect(note.wordCount, 0);
    });
  });

  group('edge cases', () {
    test('note with no frontmatter at all', () {
      final note = parseNote('# Just a heading\n\nAnd text.', filename: 'x.md');
      expect(note.frontmatter.present, isFalse);
      expect(note.title, 'Just a heading');
    });

    test('CRLF source end to end', () {
      const source = '---\r\ntitle: CRLF Note\r\n---\r\n# Heading\r\n\r\n'
          '[[A Link]]\r\n';
      final note = parseNote(source, filename: 'x.md');
      expect(note.title, 'CRLF Note');
      expect(note.headings, ['Heading']);
      expect(note.wikiLinks.first.target, 'A Link');
    });

    test('malformed frontmatter still yields a parsable body', () {
      const source = '---\ntitle: [oops\n---\n# Heading\n\n[[Link]]';
      final note = parseNote(source, filename: 'x.md');
      expect(note.frontmatter.malformed, isTrue);
      expect(note.headings, ['Heading']);
      expect(note.wikiLinks.first.target, 'Link');
      // No frontmatter title survived, so title falls back to the H1.
      expect(note.title, 'Heading');
    });

    test('empty vault-style empty file', () {
      final note = parseNote('', filename: 'empty.md');
      expect(note.title, 'empty');
      expect(note.wordCount, 0);
      expect(note.headings, isEmpty);
      expect(note.wikiLinks, isEmpty);
    });
  });
}
