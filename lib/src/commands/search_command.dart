import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../cli/output.dart';
import '../cli/vault_context.dart';
import '../index/bm25.dart';
import '../model.dart';
import '../text/tokenizer.dart';
import '../vault/frontmatter.dart';

/// Full-text BM25 search over the vault.
class SearchCommand extends Command<int> {
  @override
  final String name = 'search';
  @override
  final String description = 'Full-text BM25 search over the vault.';
  @override
  final String invocation = 'my-brain search <query words...>';

  SearchCommand() {
    argParser
      ..addOption('limit',
          abbr: 'n', defaultsTo: '10', help: 'Maximum number of hits.')
      ..addMultiOption('filter',
          help: 'Frontmatter filter key=value (repeatable).')
      ..addMultiOption('not',
          help: 'Negative frontmatter filter key=value (repeatable).')
      ..addMultiOption('tag',
          help: 'Shorthand for --filter tags=value (repeatable).')
      ..addOption('path-prefix',
          help: 'Restrict results to a vault-relative path prefix.')
      ..addFlag('snippets',
          defaultsTo: true, help: 'Include a body snippet per hit.');
  }

  @override
  Future<int> run() async {
    final output = Output(
      json: globalResults?['json'] as bool? ?? false,
      quiet: globalResults?['quiet'] as bool? ?? false,
    );
    final args = argResults!;
    final queryWords = args.rest;
    if (queryWords.isEmpty) {
      usageException('search requires at least one query word');
    }
    final rawQuery = queryWords.join(' ');
    final limit = int.tryParse(args['limit'] as String) ?? 10;

    SearchQuery query;
    try {
      final terms = const Analyzer().analyze(rawQuery);
      query = buildSearchQuery(
        terms: terms,
        filterArgs: args['filter'] as List<String>,
        notArgs: args['not'] as List<String>,
        tagArgs: args['tag'] as List<String>,
        pathPrefix: args['path-prefix'] as String?,
        limit: limit,
      );
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
            'index is stale (${staleness.total} changed); run `my-brain index`');
      }

      final reader = await ctx.openIndex();
      final searcher = Searcher(reader, ctx.config);
      final rawHits = await searcher.search(query);
      final hits = await attachSnippets(
        ctx,
        rawHits,
        enabled: args['snippets'] as bool,
      );

      output.emit(
        {
          'query': rawQuery,
          'terms': query.terms,
          'stale': staleness.stale,
          if (staleness.stale) ...staleness.toJson(),
          'hits': [
            for (var i = 0; i < hits.length; i++) hitToJson(hits[i], i + 1),
          ],
        },
        () {
          if (hits.isEmpty) {
            output.line('no results');
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

/// Parses repeated `key=value` arguments (as from `--filter`/`--not`) into a
/// `key -> values` map, folding repeats on the same key into one list.
///
/// Splits each entry on its first `=`. An entry with no `=` throws
/// [FormatException]; the command layer turns that into a [UsageException].
Map<String, List<String>> parseFilterArgs(List<String> args) {
  final result = <String, List<String>>{};
  for (final arg in args) {
    final eq = arg.indexOf('=');
    if (eq < 0) {
      throw FormatException('filter "$arg" is not in key=value form');
    }
    final key = arg.substring(0, eq);
    final value = arg.substring(eq + 1);
    result.putIfAbsent(key, () => <String>[]).add(value);
  }
  return result;
}

/// Builds a [SearchQuery] from already-analyzed [terms] and the raw CLI
/// filter arguments. `--tag` is sugar that folds into the `tags` filter key.
SearchQuery buildSearchQuery({
  required List<String> terms,
  required List<String> filterArgs,
  required List<String> notArgs,
  required List<String> tagArgs,
  String? pathPrefix,
  int limit = 10,
}) {
  final filters = parseFilterArgs(filterArgs);
  if (tagArgs.isNotEmpty) {
    filters.putIfAbsent('tags', () => <String>[]).addAll(tagArgs);
  }
  return SearchQuery(
    terms: terms,
    filters: filters,
    notFilters: parseFilterArgs(notArgs),
    pathPrefix: pathPrefix,
    limit: limit,
  );
}

/// Reads each hit's source file and attaches a body snippet around the first
/// matched term. Only reads the files for the returned hits, so this costs
/// `limit` file reads - never a full-vault scan.
///
/// The frontmatter is stripped before the window is cut. A snippet is there to
/// show the reader why a note matched, and a window that opens mid-YAML shows
/// them `status: developing ---` instead of the sentence that matched.
Future<List<SearchHit>> attachSnippets(
  VaultContext ctx,
  List<SearchHit> hits, {
  required bool enabled,
}) async {
  if (!enabled) return hits;
  final result = <SearchHit>[];
  for (final hit in hits) {
    final file = File(p.join(ctx.vaultRoot, hit.doc.path));
    String? snippet;
    if (file.existsSync()) {
      final text = await file.readAsString();
      final body = text.substring(parseFrontmatter(text).bodyOffset);
      snippet = extractSnippet(body, hit.matchedTerms);
    }
    result.add(hit.withSnippet(snippet));
  }
  return result;
}

/// JSON shape for one ranked hit, shared by `search` and `similar`.
Map<String, Object?> hitToJson(SearchHit hit, int rank) => {
      'rank': rank,
      'score': hit.score,
      'path': hit.doc.path,
      'title': hit.doc.title,
      'aliases': hit.doc.aliases,
      'matchedTerms': hit.matchedTerms,
      'snippet': hit.snippet,
    };

/// Human-readable rendering for one ranked hit, shared by `search` and
/// `similar`: a summary line, then an indented snippet line when present.
void renderHitHuman(Output output, int rank, SearchHit hit) {
  output.line(
    '  $rank. ${hit.score.toStringAsFixed(2)}  ${hit.doc.path}  ${hit.doc.title}',
  );
  final snippet = hit.snippet;
  if (snippet != null) {
    output.line('     $snippet');
  }
}
