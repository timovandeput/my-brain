import 'package:my_brain/src/commands/attrs_command.dart';
import 'package:my_brain/src/model.dart';
import 'package:test/test.dart';

void main() {
  group('summarizeAttributes', () {
    test('groups by key, most-used key first', () {
      final summaries = summarizeAttributes(const [
        AttrCount('status', 'stable', 3),
        AttrCount('type', 'note', 40),
        AttrCount('type', 'project', 2),
      ]);
      expect(summaries.map((AttrKeySummary s) => s.key), ['type', 'status']);
      expect(summaries.first.occurrences, 42);
      expect(summaries.last.occurrences, 3);
    });

    test('orders values by count, then alphabetically', () {
      final summaries = summarizeAttributes(const [
        AttrCount('type', 'zebra', 5),
        AttrCount('type', 'alpha', 5),
        AttrCount('type', 'most', 9),
      ]);
      expect(
        summaries.single.values.map((AttrCount v) => v.value),
        ['most', 'alpha', 'zebra'],
      );
    });

    test('keys with equal totals fall back to alphabetical order', () {
      final summaries = summarizeAttributes(const [
        AttrCount('zeta', 'x', 1),
        AttrCount('alpha', 'x', 1),
      ]);
      expect(summaries.map((AttrKeySummary s) => s.key), ['alpha', 'zeta']);
    });

    test('the drift case: a one-off value is kept, not folded away', () {
      // The whole point of the census. `projects` is a typo for `project`
      // and shows up as a single straggler behind the real value.
      final summaries = summarizeAttributes(const [
        AttrCount('type', 'project', 40),
        AttrCount('type', 'projects', 1),
      ]);
      expect(summaries.single.values.last.value, 'projects');
      expect(summaries.single.values.last.docCount, 1);
    });

    test('an empty census summarizes to nothing', () {
      expect(summarizeAttributes(const []), isEmpty);
    });
  });

  group('shownValues', () {
    final values = [
      for (var i = 0; i < 5; i++) AttrCount('k', 'v$i', 1),
    ];

    test('a limit of zero or less shows everything', () {
      expect(shownValues(values, 0), hasLength(5));
      expect(shownValues(values, -1), hasLength(5));
    });

    test('a limit longer than the list shows everything', () {
      expect(shownValues(values, 99), hasLength(5));
    });

    test('a limit shorter than the list truncates from the front', () {
      final shown = shownValues(values, 2);
      expect(shown.map((AttrCount v) => v.value), ['v0', 'v1']);
    });
  });
}
