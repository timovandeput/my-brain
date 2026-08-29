import 'dart:io';

import 'package:args/command_runner.dart';

import '../cli/output.dart';
import '../cli/vault_context.dart';
import '../config.dart';

/// Reports vault and index status: doc count, index size and mtime,
/// staleness counts, and a config summary. Always exits 0 - a missing or
/// stale index is a normal condition to report, not a failure.
class StatusCommand extends Command<int> {
  @override
  final String name = 'status';
  @override
  final String description = 'Reports vault and index status.';

  @override
  Future<int> run() async {
    final output = Output(
      json: globalResults?['json'] as bool? ?? false,
      quiet: globalResults?['quiet'] as bool? ?? false,
    );

    VaultContext ctx;
    try {
      ctx = await openVaultContext(globalResults?['vault'] as String?);
    } on CliError catch (e) {
      output.error(e.message);
      return e.exitCode;
    }

    final indexFile = File(ctx.config.indexPath);
    if (!indexFile.existsSync()) {
      output.emit(
        {
          'vaultRoot': ctx.vaultRoot,
          'indexPresent': false,
          'config': _configSummary(ctx.config),
        },
        () {
          output.line('vault: ${ctx.vaultRoot}');
          output.line('index: not built (run `my-brain index`)');
        },
      );
      return 0;
    }

    final stat = indexFile.statSync();
    int docCount;
    StalenessReport? staleness;
    try {
      final reader = await ctx.openIndex();
      docCount = reader.docCount;
      staleness = await ctx.checkStaleness();
    } on Object {
      // Status is a report, not a gate: a corrupt or unreadable index is
      // still reported, not a crash.
      docCount = 0;
      staleness = null;
    } finally {
      await ctx.close();
    }

    output.emit(
      {
        'vaultRoot': ctx.vaultRoot,
        'indexPresent': true,
        'docCount': docCount,
        'indexBytes': stat.size,
        'indexMtime': stat.modified.toIso8601String(),
        if (staleness != null) ...staleness.toJson(),
        'config': _configSummary(ctx.config),
      },
      () {
        output.line('vault: ${ctx.vaultRoot}');
        output.line('index: $docCount docs, ${stat.size} bytes, '
            'built ${stat.modified}');
        if (staleness != null) {
          output.line(staleness.stale
              ? 'staleness: stale (${staleness.added} added, '
                  '${staleness.changed} changed, ${staleness.removed} removed)'
              : 'staleness: up to date');
        }
        output.line('config: k1=${ctx.config.k1} b=${ctx.config.b} '
            'splitThresholdWords=${ctx.config.splitThresholdWords}');
      },
    );
    return 0;
  }
}

Map<String, Object?> _configSummary(BrainConfig config) => {
      'k1': config.k1,
      'b': config.b,
      'splitThresholdWords': config.splitThresholdWords,
      'exclude': config.exclude,
      'extensions': config.extensions,
    };
