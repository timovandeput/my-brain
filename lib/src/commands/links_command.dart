import 'package:args/command_runner.dart';

import '../cli/output.dart';
import '../cli/vault_context.dart';
import '../vault/linkgraph.dart';

/// Validates that exactly one selector mode was requested. Throws
/// [FormatException] when none was given; the command layer turns that into
/// a [UsageException].
void validateLinksSelector({
  required String? to,
  required String? from,
  required bool broken,
}) {
  if (to == null && from == null && !broken) {
    throw const FormatException('specify one of --to, --from, or --broken');
  }
}

/// Reports backlinks, outgoing links, or every broken link in the vault.
class LinksCommand extends Command<int> {
  @override
  final String name = 'links';
  @override
  final String description =
      'Reports backlinks (--to), outgoing links (--from), or broken links (--broken).';

  LinksCommand() {
    argParser
      ..addOption('to', help: 'List notes that link to this note.')
      ..addOption('from', help: 'List outgoing links from this note.')
      ..addFlag('broken',
          negatable: false, help: 'List every broken link in the vault.');
  }

  @override
  Future<int> run() async {
    final output = Output(
      json: globalResults?['json'] as bool? ?? false,
      quiet: globalResults?['quiet'] as bool? ?? false,
    );
    final to = argResults!['to'] as String?;
    final from = argResults!['from'] as String?;
    final broken = argResults!['broken'] as bool;

    try {
      validateLinksSelector(to: to, from: from, broken: broken);
    } on FormatException catch (e) {
      usageException(e.message);
    }

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
      final docs = await reader.allDocs();
      final resolver = LinkResolver(docs);

      if (to != null) {
        return await _runTo(ctx, output, resolver, to, staleness);
      }
      if (from != null) {
        return await _runFrom(ctx, output, resolver, from, staleness);
      }
      return _runBroken(output, resolver, staleness);
    } on CliError catch (e) {
      output.error(e.message);
      return e.exitCode;
    } finally {
      await ctx.close();
    }
  }

  Future<int> _runTo(
    VaultContext ctx,
    Output output,
    LinkResolver resolver,
    String arg,
    StalenessReport staleness,
  ) async {
    final doc = await ctx.resolveNote(arg);
    final backlinks = resolver.backlinksTo(doc)
      ..sort((a, b) => a.path.compareTo(b.path));

    output.emit(
      {
        'to': doc.path,
        'stale': staleness.stale,
        'backlinks': [
          for (final d in backlinks) {'path': d.path, 'title': d.title},
        ],
      },
      () {
        output.line('backlinks to ${doc.path} (${backlinks.length}):');
        for (final d in backlinks) {
          output.line('  ${d.path}  ${d.title}');
        }
      },
    );
    return 0;
  }

  Future<int> _runFrom(
    VaultContext ctx,
    Output output,
    LinkResolver resolver,
    String arg,
    StalenessReport staleness,
  ) async {
    final doc = await ctx.resolveNote(arg);
    final entries = [
      for (final target in doc.outLinks)
        <String, Object?>{
          'target': target,
          'resolvedPath': resolver.resolve(target)?.path,
        },
    ];

    output.emit(
      {
        'from': doc.path,
        'stale': staleness.stale,
        'links': entries,
      },
      () {
        output.line('links from ${doc.path} (${entries.length}):');
        for (final e in entries) {
          output.line('  ${e['target']}  -> ${e['resolvedPath'] ?? 'BROKEN'}');
        }
      },
    );
    return 0;
  }

  int _runBroken(
    Output output,
    LinkResolver resolver,
    StalenessReport staleness,
  ) {
    final brokenMap = resolver.brokenLinks();
    final targets = brokenMap.keys.toList()..sort();
    final entries = [
      for (final t in targets)
        <String, Object?>{
          'target': t,
          'referrers': (brokenMap[t]!..sort((a, b) => a.path.compareTo(b.path)))
              .map((d) => d.path)
              .toList(),
        },
    ];

    output.emit(
      {
        'stale': staleness.stale,
        'broken': entries,
      },
      () {
        output.line('broken links (${entries.length}):');
        for (final e in entries) {
          output.line(
              '  ${e['target']}  <- ${(e['referrers']! as List).join(', ')}');
        }
      },
    );
    return 0;
  }
}
