// `doctor --path-prefix` narrows what is reported without narrowing what is
// resolved: the link graph stays the whole vault, so a note linked to only
// from outside the subtree is still not an orphan.
import 'package:my_brain/src/commands/doctor_command.dart';
import 'package:my_brain/src/model.dart';
import 'package:test/test.dart';

DocRecord _doc(
  int id,
  String path, {
  String? title,
  List<String> outLinks = const [],
  int wordCount = 10,
  bool frontmatterMalformed = false,
}) =>
    DocRecord(
      docId: id,
      path: path,
      title: title ?? path.split('/').last.replaceAll('.md', ''),
      aliases: const [],
      headings: const [],
      outLinks: outLinks,
      tags: const [],
      length: wordCount,
      wordCount: wordCount,
      mtimeMs: 1,
      size: 1,
      frontmatterMalformed: frontmatterMalformed,
    );

List<String> _paths(Map<String, Object?> report, String key) =>
    (report[key]! as List).cast<String>();

List<Map<String, Object?>> _entries(Map<String, Object?> report, String key) =>
    (report[key]! as List).cast<Map<String, Object?>>();

void main() {
  group('doctor --path-prefix', () {
    test('reports only notes in the subtree', () {
      final docs = [
        _doc(0, 'notes/kept.md', frontmatterMalformed: true),
        _doc(1, 'logs/dump.md', frontmatterMalformed: true),
        _doc(2, 'notes/long.md', wordCount: 5000),
        _doc(3, 'logs/longer.md', wordCount: 9000),
      ];

      final report = buildDoctorReport(
        docs: docs,
        splitThresholdWords: 1200,
        stale: false,
        pathPrefix: 'notes/',
      );

      expect(report['pathPrefix'], 'notes/');
      expect(_paths(report, 'malformedFrontmatter'), ['notes/kept.md']);
      expect(
        _entries(report, 'oversized').map((e) => e['path']),
        ['notes/long.md'],
      );
    });

    test('a broken link is listed under the note that carries it', () {
      final docs = [
        _doc(0, 'notes/a.md', outLinks: ['Nowhere']),
        _doc(1, 'logs/b.md', outLinks: ['Nowhere']),
      ];

      final scoped = buildDoctorReport(
        docs: docs,
        splitThresholdWords: 1200,
        stale: false,
        pathPrefix: 'notes/',
      );
      expect(_entries(scoped, 'brokenLinks').single['referrers'],
          ['notes/a.md']);

      final all = buildDoctorReport(
        docs: docs,
        splitThresholdWords: 1200,
        stale: false,
      );
      expect(_entries(all, 'brokenLinks').single['referrers'],
          ['logs/b.md', 'notes/a.md']);
      expect(all.containsKey('pathPrefix'), isFalse);
    });

    test('resolution still sees the whole vault: a note linked only from '
        'outside the subtree is not an orphan', () {
      final docs = [
        _doc(0, 'notes/linked.md', title: 'Linked'),
        _doc(1, 'notes/alone.md', title: 'Alone'),
        _doc(2, 'logs/dump.md', outLinks: ['Linked']),
      ];

      final report = buildDoctorReport(
        docs: docs,
        splitThresholdWords: 1200,
        stale: false,
        pathPrefix: 'notes/',
      );

      expect(_paths(report, 'orphans'), ['notes/alone.md']);
    });

    test('a title collision shows the colliding path even when it sits '
        'outside the subtree', () {
      final docs = [
        _doc(0, 'notes/postgres.md', title: 'Postgres'),
        _doc(1, 'logs/postgres.md', title: 'Postgres'),
      ];

      final report = buildDoctorReport(
        docs: docs,
        splitThresholdWords: 1200,
        stale: false,
        pathPrefix: 'notes/',
      );

      expect(_entries(report, 'duplicateTitles').single['paths'],
          ['logs/postgres.md', 'notes/postgres.md']);
    });
  });
}
