import 'package:args/command_runner.dart';

import '../cli/output.dart';
import '../cli/vault_context.dart';
import '../index/bm25.dart';
import 'search_command.dart' show attachSnippets, hitToJson, renderHitHuman;

/// Finds notes most similar to a given note, for duplicate detection.
class SimilarCommand extends Command<int> {
  @override
  final String name = 'similar';
  @override
  final String description = 'Finds notes similar to a given note.';
  @override
  final String invocation = 'my-brain similar <note> [--path-prefix <dir>]';

  SimilarCommand() {
    argParser
      ..addOption('limit',
          abbr: 'n', defaultsTo: '10', help: 'Maximum number of hits.')
      ..addOption('path-prefix',
          help: 'Restrict results to a vault-relative path prefix.');
  }

  @override
  Future<int> run() async {
    final output = Output(
      json: globalResults?['json'] as bool? ?? false,
      quiet: globalResults?['quiet'] as bool? ?? false,
    );
    final rest = argResults!.rest;
    if (rest.length != 1) {
      usageException('similar requires exactly one note argument');
    }
    final noteArg = rest.single;
    final limit = int.tryParse(argResults!['limit'] as String) ?? 10;

    VaultContext ctx;
    try {
      ctx = await openVaultContext(globalResults?['vault'] as String?);
    } on CliError catch (e) {
      output.error(e.message);
      return e.exitCode;
    }

    try {
      final staleness = await ctx.checkStaleness();
      final doc = await ctx.resolveNote(noteArg);
      if (staleness.stale) {
        output.warn(
            'index is stale (${staleness.summary}); run `my-brain index`');
      }

      final reader = await ctx.openIndex();
      final searcher = Searcher(reader, ctx.config);
      final rawHits = await searcher.similarTo(
        doc,
        limit: limit,
        pathPrefix: argResults!['path-prefix'] as String?,
      );
      final hits = await attachSnippets(ctx, rawHits, enabled: true);

      output.emit(
        {
          'note': doc.path,
          'stale': staleness.stale,
          if (staleness.stale) ...staleness.toJson(),
          'hits': [
            for (var i = 0; i < hits.length; i++) hitToJson(hits[i], i + 1),
          ],
        },
        () {
          if (hits.isEmpty) {
            output.line('no similar notes');
            return;
          }
          for (var i = 0; i < hits.length; i++) {
            renderHitHuman(output, i + 1, hits[i]);
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
