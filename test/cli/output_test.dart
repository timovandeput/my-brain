import 'dart:convert';

import 'package:my_brain/src/cli/output.dart';
import 'package:test/test.dart';

void main() {
  group('Output json mode', () {
    test('emits parseable JSON and never runs the human renderer', () {
      final out = StringBuffer();
      final output = Output(json: true, out: out);
      var humanCalled = false;

      output.emit({'a': 1, 'b': 'two'}, () => humanCalled = true);

      expect(humanCalled, isFalse);
      expect(jsonDecode(out.toString()), {'a': 1, 'b': 'two'});
    });

    test('stdout carries exactly one JSON document, nothing else', () {
      final out = StringBuffer();
      final output = Output(json: true, out: out);

      output.emit({'hits': <Object?>[]}, () {});

      // The whole buffer must be one parseable JSON value with no stray text
      // before or after it.
      expect(() => jsonDecode(out.toString().trim()), returnsNormally);
    });
  });

  group('Output human mode', () {
    test('renders lines written by the humanRenderer', () {
      final out = StringBuffer();
      final output = Output(out: out);

      output.emit({'ignored': true}, () {
        output.line('first');
        output.line('second');
      });

      expect(out.toString(), 'first\nsecond\n');
    });

    test('does not serialize the JSON body', () {
      final out = StringBuffer();
      final output = Output(out: out);

      output.emit({'should': 'not appear'}, () => output.line('ok'));

      expect(out.toString(), isNot(contains('should')));
    });
  });

  group('Output warn/progress/error', () {
    test('--quiet suppresses warn and progress', () {
      final err = StringBuffer();
      final output = Output(quiet: true, err: err);

      output.warn('be careful');
      output.progress('working...');

      expect(err.toString(), isEmpty);
    });

    test('warn and progress reach stderr when not quiet', () {
      final err = StringBuffer();
      final output = Output(err: err);

      output.warn('be careful');
      output.progress('working...');

      expect(err.toString(), contains('be careful'));
      expect(err.toString(), contains('working...'));
    });

    test('error is never suppressed by --quiet', () {
      final err = StringBuffer();
      final output = Output(quiet: true, err: err);

      output.error('boom');

      expect(err.toString(), contains('boom'));
    });
  });

  group('extractSnippet', () {
    test('returns null when no matched term occurs in the text', () {
      expect(extractSnippet('the quick brown fox jumps', ['zebra']), isNull);
    });

    test('returns null for an empty term list', () {
      expect(extractSnippet('the quick brown fox jumps', []), isNull);
    });

    test('handles a match at the very start with no leading ellipsis', () {
      final text = 'Alpha begins this fairly long sentence which keeps '
          'going on and on and on for quite a while so that the window is '
          'forced to cut somewhere before the sentence actually ends here.';
      final snippet = extractSnippet(text, ['alpha'], window: 40);

      expect(snippet, isNotNull);
      expect(snippet, isNot(startsWith('…')));
      expect(snippet, endsWith('…'));
      expect(snippet, contains('Alpha'));
    });

    test('handles a match at the very end with no trailing ellipsis', () {
      final text = 'This fairly long introductory sentence keeps going on '
          'for quite a while before it finally arrives at omega';
      final snippet = extractSnippet(text, ['omega'], window: 40);

      expect(snippet, isNotNull);
      expect(snippet, startsWith('…'));
      expect(snippet, isNot(endsWith('…')));
      expect(snippet, contains('omega'));
    });

    test('collapses newlines, tabs and repeated spaces', () {
      final text = 'word1   word2\n\nword3\ttarget\tword4    word5';
      final snippet = extractSnippet(text, ['target']);

      expect(snippet, isNotNull);
      expect(snippet, isNot(contains('  ')));
      expect(snippet, isNot(contains('\n')));
      expect(snippet, isNot(contains('\t')));
    });

    test('returns the whole (trimmed) string when shorter than the window',
        () {
      const text = 'short text with a match inside it';
      final snippet = extractSnippet(text, ['match'], window: 200);

      expect(snippet, text);
    });

    test('matches case-insensitively but preserves original casing', () {
      final snippet = extractSnippet('Some TARGET word here', ['target']);

      expect(snippet, isNotNull);
      expect(snippet, contains('TARGET'));
    });
  });
}
