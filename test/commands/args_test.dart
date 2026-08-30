import 'package:my_brain/src/commands/links_command.dart';
import 'package:my_brain/src/commands/search_command.dart';
import 'package:test/test.dart';

void main() {
  group('parseFilterArgs', () {
    test('rejects an entry with no =', () {
      expect(() => parseFilterArgs(['status']), throwsFormatException);
    });

    test('splits only on the first =, keeping the rest in the value', () {
      final parsed = parseFilterArgs(['a=b=c']);
      expect(parsed, {
        'a': ['b=c'],
      });
    });

    test('collects repeated keys into one list, in order', () {
      final parsed = parseFilterArgs(['status=draft', 'status=review']);
      expect(parsed, {
        'status': ['draft', 'review'],
      });
    });

    test('an empty list of args yields an empty map', () {
      expect(parseFilterArgs([]), isEmpty);
    });
  });

  group('buildSearchQuery', () {
    test('--tag folds into the tags filter', () {
      final query = buildSearchQuery(
        terms: const ['note'],
        filterArgs: const [],
        notArgs: const [],
        tagArgs: const ['work', 'urgent'],
      );
      expect(query.filters, {
        'tags': ['work', 'urgent'],
      });
    });

    test('--tag appends to an existing --filter tags=... entry', () {
      final query = buildSearchQuery(
        terms: const ['note'],
        filterArgs: const ['tags=personal'],
        notArgs: const [],
        tagArgs: const ['work'],
      );
      expect(query.filters, {
        'tags': ['personal', 'work'],
      });
    });

    test('propagates terms, notFilters, pathPrefix and limit', () {
      final query = buildSearchQuery(
        terms: const ['meeting', 'note'],
        filterArgs: const ['status=draft'],
        notArgs: const ['status=archived'],
        tagArgs: const [],
        pathPrefix: 'projects/',
        limit: 5,
      );
      expect(query.terms, ['meeting', 'note']);
      expect(query.filters, {
        'status': ['draft'],
      });
      expect(query.notFilters, {
        'status': ['archived'],
      });
      expect(query.pathPrefix, 'projects/');
      expect(query.limit, 5);
    });

    test('a malformed --filter throws FormatException', () {
      expect(
        () => buildSearchQuery(
          terms: const ['note'],
          filterArgs: const ['nokeyvalue'],
          notArgs: const [],
          tagArgs: const [],
        ),
        throwsFormatException,
      );
    });

    test('a malformed --not throws FormatException', () {
      expect(
        () => buildSearchQuery(
          terms: const ['note'],
          filterArgs: const [],
          notArgs: const ['nokeyvalue'],
          tagArgs: const [],
        ),
        throwsFormatException,
      );
    });
  });

  group('SearchCommand argument parser', () {
    test('-n is the short form of --limit', () {
      final results =
          SearchCommand().argParser.parse(['-n', '5', 'my', 'query']);
      expect(results['limit'], '5');
      expect(results.rest, ['my', 'query']);
    });

    test('--limit defaults to 10', () {
      final results = SearchCommand().argParser.parse(['query']);
      expect(results['limit'], '10');
    });

    test('repeated --filter collects into a list', () {
      final results = SearchCommand()
          .argParser
          .parse(['--filter', 'a=1', '--filter', 'b=2', 'query']);
      expect(results['filter'], ['a=1', 'b=2']);
    });

    test('--no-snippets clears the default snippets flag', () {
      final results =
          SearchCommand().argParser.parse(['--no-snippets', 'query']);
      expect(results['snippets'], isFalse);
    });
  });

  group('validateLinksSelector', () {
    test('throws when none of --to, --from, --broken is given', () {
      expect(
        () => validateLinksSelector(to: null, from: null, broken: false),
        throwsFormatException,
      );
    });

    test('accepts --to alone', () {
      expect(
        () => validateLinksSelector(to: 'Some Note', from: null, broken: false),
        returnsNormally,
      );
    });

    test('accepts --from alone', () {
      expect(
        () => validateLinksSelector(to: null, from: 'Some Note', broken: false),
        returnsNormally,
      );
    });

    test('accepts --broken alone', () {
      expect(
        () => validateLinksSelector(to: null, from: null, broken: true),
        returnsNormally,
      );
    });
  });
}
