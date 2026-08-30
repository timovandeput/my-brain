import 'package:args/command_runner.dart';

import '../cli/output.dart';
import '../cli/vault_context.dart';
import '../index/builder.dart';
import '../text/tokenizer.dart';
import '../vault/scanner.dart';

/// Scans the vault and rebuilds `.brain/index.bin` from scratch.
class IndexCommand extends Command<int> {
  @override
  final String name = 'index';
  @override
  final String description = 'Scans the vault and rebuilds the search index.';

  IndexCommand() {
    argParser.addFlag('stats',
        negatable: false, help: 'Print a detailed statistics breakdown.');
  }

  @override
  Future<int> run() async {
    final output = Output(
      json: globalResults?['json'] as bool? ?? false,
      quiet: globalResults?['quiet'] as bool? ?? false,
    );
    final showStats = argResults!['stats'] as bool;

    VaultContext ctx;
    try {
      ctx = await openVaultContext(globalResults?['vault'] as String?);
    } on CliError catch (e) {
      output.error(e.message);
      return e.exitCode;
    }

    output.progress('scanning vault...');
    final manifest = await VaultScanner(ctx.config).scan();
    output.progress('indexing ${manifest.files.length} files...');

    final builder = IndexBuilder(ctx.config, const Analyzer());
    final result = await builder.build(
      manifest,
      onProgress: (done, total) => output.progress('indexed $done/$total'),
    );
    final stats = result.stats;
    final skipped = result.skipped;

    output.emit(
      {
        'docCount': stats.docCount,
        'termCount': stats.termCount,
        'postingCount': stats.postingCount,
        'indexBytes': stats.indexBytes,
        'elapsedMs': stats.elapsed.inMilliseconds,
        'skipped': [
          for (final s in skipped) {'path': s.path, 'reason': s.reason},
        ],
      },
      () {
        if (showStats) {
          output.line('docCount: ${stats.docCount}');
          output.line('termCount: ${stats.termCount}');
          output.line('postingCount: ${stats.postingCount}');
          output.line('indexBytes: ${stats.indexBytes}');
          output.line('elapsedMs: ${stats.elapsed.inMilliseconds}');
        } else {
          output.line(
              'indexed ${stats.docCount} docs in ${stats.elapsed.inMilliseconds}ms');
        }
        if (skipped.isNotEmpty) {
          output.line('skipped ${skipped.length} unreadable file(s):');
          for (final s in skipped) {
            output.line('  ${s.path}: ${s.reason}');
          }
        }
      },
    );
    return 0;
  }
}
