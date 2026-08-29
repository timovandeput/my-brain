import 'package:args/command_runner.dart';

import '../cli/output.dart';
import '../cli/vault_context.dart';
import '../edit/rewriter.dart';
import 'rename_command.dart' show emitRewritePlan;

/// Deletes a note and rewrites every wikilink that refers to it, replacing
/// each occurrence with its display text so prose still reads correctly.
class RmCommand extends Command<int> {
  @override
  final String name = 'rm';
  @override
  final String description =
      'Deletes a note and rewrites every link that refers to it.';
  @override
  final String invocation = 'my-brain rm <note>';

  RmCommand() {
    argParser
      ..addFlag('dry-run',
          negatable: false, help: 'Show the plan without applying it.')
      ..addFlag('yes',
          negatable: false, help: 'Skip the interactive confirmation.')
      ..addFlag('force',
          negatable: false,
          help: 'Proceed even if the index is stale. A note added or '
              'changed since the last `my-brain index` will not have its '
              'links rewritten.');
  }

  @override
  Future<int> run() async {
    final output = Output(
      json: globalResults?['json'] as bool? ?? false,
      quiet: globalResults?['quiet'] as bool? ?? false,
    );
    final rest = argResults!.rest;
    if (rest.length != 1) {
      usageException('rm requires exactly one note argument');
    }
    final noteArg = rest.single;
    final dryRun = argResults!['dry-run'] as bool;
    final yes = argResults!['yes'] as bool;
    final force = argResults!['force'] as bool;

    VaultContext ctx;
    try {
      ctx = await openVaultContext(globalResults?['vault'] as String?);
    } on CliError catch (e) {
      output.error(e.message);
      return e.exitCode;
    }

    try {
      // rm mutates files: a note missed by a stale index would have its
      // links to the deleted note permanently orphaned rather than merely
      // reported, so refuse outright instead of only warning.
      final staleness = await ctx.checkStaleness();
      if (staleness.stale && !force) {
        output.error(
          'index is stale (${staleness.summary}); run `my-brain index` '
          'first, or pass --force to proceed anyway',
        );
        return 3;
      }

      final reader = await ctx.openIndex();
      final docs = await reader.allDocs();
      final doc = await ctx.resolveNote(noteArg);
      final rewriter = LinkRewriter(ctx.config, docs);
      final plan = rewriter.planDelete(doc.path);

      emitRewritePlan(
        output,
        plan,
        dryRun: dryRun,
        actionLabel: dryRun ? 'would delete' : 'deleting',
      );

      if (!dryRun) {
        if (!yes &&
            !output
                .confirm('delete ${doc.path} and rewrite referring links?')) {
          output.error('aborted');
          return 1;
        }
        await rewriter.apply(plan);
        output.warn('index is now stale; run `my-brain index`');
      }
      return 0;
    } on CliError catch (e) {
      output.error(e.message);
      return e.exitCode;
    } finally {
      await ctx.close();
    }
  }
}
