import 'package:args/command_runner.dart';

import '../cli/output.dart';
import '../cli/vault_context.dart';
import '../edit/rewriter.dart';

/// Renames a note and rewrites every wikilink that refers to it.
class RenameCommand extends Command<int> {
  @override
  final String name = 'rename';
  @override
  final String description =
      'Renames a note and rewrites every link that refers to it.';
  @override
  final String invocation = 'my-brain rename <old> <new>';

  RenameCommand() {
    argParser
      ..addFlag('dry-run',
          negatable: false, help: 'Show the plan without applying it.')
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
    if (rest.length != 2) {
      usageException('rename requires <old> and <new> arguments');
    }
    final oldArg = rest[0];
    final newArg = rest[1];
    final dryRun = argResults!['dry-run'] as bool;
    final force = argResults!['force'] as bool;

    VaultContext ctx;
    try {
      ctx = await openVaultContext(globalResults?['vault'] as String?);
    } on CliError catch (e) {
      output.error(e.message);
      return e.exitCode;
    }

    try {
      // rename mutates files: a note missed by a stale index would have its
      // links to the renamed note permanently orphaned rather than merely
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
      final doc = await ctx.resolveNote(oldArg);
      final rewriter = LinkRewriter(ctx.config, docs);
      final plan = rewriter.planRename(doc.path, newArg);

      emitRewritePlan(
        output,
        plan,
        dryRun: dryRun,
        actionLabel: dryRun ? 'would rename' : 'renaming',
      );

      if (!dryRun) {
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

/// Renders a [RewritePlan] as JSON or human-readable text, shared by
/// `rename` and `rm`.
void emitRewritePlan(
  Output output,
  RewritePlan plan, {
  required bool dryRun,
  required String actionLabel,
}) {
  output.emit(
    {
      'from': plan.from,
      'to': plan.to,
      'dryRun': dryRun,
      'fileCount': plan.fileCount,
      'edits': [
        for (final e in plan.edits)
          {
            'path': e.path,
            'line': e.line,
            'before': e.before,
            'after': e.after
          },
      ],
      'unresolved': plan.unresolved,
    },
    () {
      final target = plan.to ?? '(deleted)';
      output.line('$actionLabel ${plan.from} -> $target');
      output.line('  ${plan.fileCount} file(s), ${plan.edits.length} edit(s)');
      for (final e in plan.edits) {
        output.line('  ${e.path}:${e.line}');
        output.line('    - ${e.before}');
        output.line('    + ${e.after}');
      }
      if (plan.unresolved.isNotEmpty) {
        output.line('  unresolved:');
        plan.unresolved.forEach((path, reason) {
          output.line('    $path: $reason');
        });
      }
    },
  );
}
