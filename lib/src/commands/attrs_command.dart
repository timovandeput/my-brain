import 'package:args/command_runner.dart';

import '../cli/output.dart';
import '../cli/vault_context.dart';
import '../model.dart';

/// Default number of values shown per key, before the rest are collapsed into
/// a count. Keeps a vault with thousands of distinct `created:` dates readable,
/// and the output bounded in an agent's context.
const int defaultAttrValueLimit = 12;

/// One key's values, ordered for display.
class AttrKeySummary {
  final String key;

  /// Every value for this key, most-used first, then alphabetical.
  final List<AttrCount> values;

  /// Total key/value occurrences. Equal to the number of notes carrying the
  /// key for a single-valued key like `type`; higher for a list-valued one
  /// like `tags`, where one note contributes several.
  final int occurrences;

  const AttrKeySummary({
    required this.key,
    required this.values,
    required this.occurrences,
  });
}

/// Groups a flat census into per-key summaries, most-used key first.
List<AttrKeySummary> summarizeAttributes(List<AttrCount> census) {
  final byKey = <String, List<AttrCount>>{};
  for (final entry in census) {
    byKey.putIfAbsent(entry.key, () => <AttrCount>[]).add(entry);
  }
  final summaries = [
    for (final entry in byKey.entries)
      AttrKeySummary(
        key: entry.key,
        values: entry.value
          ..sort((AttrCount a, AttrCount b) {
            final byCount = b.docCount.compareTo(a.docCount);
            return byCount != 0 ? byCount : a.value.compareTo(b.value);
          }),
        occurrences: entry.value
            .fold<int>(0, (int sum, AttrCount v) => sum + v.docCount),
      ),
  ];
  summaries.sort((AttrKeySummary a, AttrKeySummary b) {
    final byCount = b.occurrences.compareTo(a.occurrences);
    return byCount != 0 ? byCount : a.key.compareTo(b.key);
  });
  return summaries;
}

/// The first [limit] values, or all of them when [limit] is zero or less.
List<AttrCount> shownValues(List<AttrCount> values, int limit) =>
    limit > 0 && values.length > limit ? values.sublist(0, limit) : values;

/// Reports the frontmatter vocabulary the vault actually uses.
///
/// Deliberately descriptive: it counts what is there and has no opinion about
/// what ought to be there. Drift shows up as a long tail (`project` 40 times,
/// `projects` once), and what to do about it is a judgement for the agent and
/// the user, not a rule for this tool. It answers the question the search
/// index otherwise cannot: not "which notes say X" but "what words does this
/// vault use".
class AttrsCommand extends Command<int> {
  @override
  final String name = 'attrs';
  @override
  final String description =
      'Frontmatter keys and values in use, with note counts.';
  @override
  final String invocation =
      'my-brain attrs [--key <key>] [-n <count>] [--path-prefix <dir>]';

  AttrsCommand() {
    argParser
      ..addOption('key',
          help: 'Show every value of one key instead of the overview.')
      ..addOption('limit',
          abbr: 'n',
          defaultsTo: '$defaultAttrValueLimit',
          help: 'Values shown per key (all of them with --key).')
      ..addOption('path-prefix',
          help: 'Count only notes under a vault-relative path prefix.');
  }

  @override
  Future<int> run() async {
    final output = Output(
      json: globalResults?['json'] as bool? ?? false,
      quiet: globalResults?['quiet'] as bool? ?? false,
    );
    final args = argResults!;
    final key = (args['key'] as String?)?.trim().toLowerCase();
    // With --key the caller asked for one key on purpose, so show all of it
    // unless they set a limit themselves.
    final limit = args.wasParsed('limit')
        ? int.tryParse(args['limit'] as String) ?? defaultAttrValueLimit
        : (key == null ? defaultAttrValueLimit : 0);

    VaultContext ctx;
    try {
      ctx = await openVaultContext(globalResults?['vault'] as String?);
    } on CliError catch (e) {
      output.error(e.message);
      return e.exitCode;
    }

    try {
      final staleness = await ctx.checkStaleness();
      if (staleness.stale) {
        output.warn(
            'index is stale (${staleness.summary}); run `my-brain index`');
      }

      final reader = await ctx.openIndex();
      final prefix = args['path-prefix'] as String?;
      final scoped =
          prefix == null ? null : await reader.docIdsUnder(prefix);
      final census = await reader.attributeCensus(restrictTo: scoped);
      final noteCount = scoped?.length ?? reader.docCount;
      final summaries = summarizeAttributes(census)
          .where((AttrKeySummary s) => key == null || s.key == key)
          .toList();

      output.emit(
        {
          'docCount': noteCount,
          if (prefix != null) 'pathPrefix': prefix,
          'stale': staleness.stale,
          'keys': [
            for (final s in summaries)
              <String, Object?>{
                'key': s.key,
                'occurrences': s.occurrences,
                'distinctValues': s.values.length,
                'truncated': limit > 0 && s.values.length > limit,
                'values': [
                  for (final v in shownValues(s.values, limit))
                    {'value': v.value, 'notes': v.docCount},
                ],
              },
          ],
        },
        () {
          if (summaries.isEmpty) {
            output.line(key == null
                ? 'no frontmatter attributes indexed'
                : 'no notes carry "$key"');
            return;
          }
          output.line('$noteCount notes indexed:');
          for (final s in summaries) {
            final shown = shownValues(s.values, limit);
            final hidden = s.values.length - shown.length;
            final label = s.values.length == 1 ? 'value' : 'values';
            output.line('  ${s.key}  (${s.values.length} $label)');
            output.line(
              '    ${shown.map((AttrCount v) => '${v.value} ${v.docCount}').join('  ')}'
              '${hidden > 0 ? '  ... $hidden more: --key ${s.key}' : ''}',
            );
          }
        },
      );
      return 0;
    } on CliError catch (e) {
      output.error(e.message);
      return e.exitCode;
    } finally {
      await ctx.close();
    }
  }
}
