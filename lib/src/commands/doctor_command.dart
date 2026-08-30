import 'package:args/command_runner.dart';

import '../cli/output.dart';
import '../cli/vault_context.dart';
import '../vault/linkgraph.dart';

/// Reports vault health in one pass: broken links, oversized notes,
/// duplicate/colliding titles or aliases, ambiguous link targets, orphans,
/// and two frontmatter findings that only the parser can see. Always exits
/// 0 - this is a report, not a gate.
///
/// Everything here is a fact about what this tool can and cannot do with a
/// note: a link it cannot resolve, a header it could not parse, a note too
/// long to retrieve precisely. It deliberately says nothing about which keys
/// or values a note ought to carry; that belongs to the vault's own
/// conventions in AGENTS.md, not to the binary.
class DoctorCommand extends Command<int> {
  @override
  final String name = 'doctor';
  @override
  final String description =
      'Reports vault health: broken links, oversized notes, duplicate '
      'titles, ambiguous links, orphans, and unreadable frontmatter.';

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

    try {
      final staleness = await ctx.checkStaleness();
      if (staleness.stale) {
        output.warn(
            'index is stale (${staleness.summary}); run `my-brain index`');
      }

      final reader = await ctx.openIndex();
      final docs = await reader.allDocs();
      final resolver = LinkResolver(docs);

      // Broken links.
      final brokenMap = resolver.brokenLinks();
      final brokenTargets = brokenMap.keys.toList()..sort();
      final brokenLinks = [
        for (final t in brokenTargets)
          <String, Object?>{
            'target': t,
            'referrers': (brokenMap[t]!
                  ..sort((a, b) => a.path.compareTo(b.path)))
                .map((d) => d.path)
                .toList(),
          },
      ];

      // Oversized notes.
      final oversized = docs
          .where((d) => d.wordCount > ctx.config.splitThresholdWords)
          .map((d) => <String, Object?>{
                'path': d.path,
                'wordCount': d.wordCount,
              })
          .toList()
        ..sort((a, b) =>
            (b['wordCount']! as int).compareTo(a['wordCount']! as int));

      // Duplicate/colliding titles and aliases: names that resolve to more
      // than one path, case-insensitively.
      final byName = <String, Set<String>>{};
      for (final d in docs) {
        byName.putIfAbsent(d.title.toLowerCase(), () => <String>{}).add(d.path);
        for (final a in d.aliases) {
          byName.putIfAbsent(a.toLowerCase(), () => <String>{}).add(d.path);
        }
      }
      final duplicateTitles = [
        for (final entry in byName.entries)
          if (entry.value.length > 1)
            <String, Object?>{
              'name': entry.key,
              'paths': entry.value.toList()..sort(),
            },
      ]..sort((a, b) => (a['name']! as String).compareTo(b['name']! as String));

      // Ambiguous link targets: distinct outgoing targets that LinkResolver
      // could have resolved to more than one document.
      final allTargets = <String>{
        for (final d in docs) ...d.outLinks,
      };
      final ambiguousTargets = allTargets.where(resolver.isAmbiguous).toList()
        ..sort();
      final ambiguousLinks = [
        for (final t in ambiguousTargets)
          <String, Object?>{
            'target': t,
            'referrers': (docs.where((d) => d.outLinks.contains(t)).toList()
                  ..sort((a, b) => a.path.compareTo(b.path)))
                .map((d) => d.path)
                .toList(),
          },
      ];

      // Frontmatter that opened a `---` block the YAML parser rejected. The
      // note still indexes and still searches; it just silently has no
      // attributes, so every --filter passes it by. Nothing else reports it.
      final malformedFrontmatter =
          docs.where((d) => d.frontmatterMalformed).map((d) => d.path).toList()
            ..sort();

      // Wikilinks written into frontmatter. Links are read from the body
      // only, so these are not edges: no backlink, no broken-link check
      // above, and `rename` will not rewrite them when their target moves.
      final frontmatterLinks =
          docs.where((d) => d.frontmatterLinks).map((d) => d.path).toList()
            ..sort();

      // Orphans: no inbound and no outbound links.
      final orphans = docs
          .where((d) => d.outLinks.isEmpty && resolver.backlinksTo(d).isEmpty)
          .map((d) => d.path)
          .toList()
        ..sort();

      output.emit(
        {
          'stale': staleness.stale,
          'brokenLinks': brokenLinks,
          'oversized': oversized,
          'duplicateTitles': duplicateTitles,
          'ambiguousLinks': ambiguousLinks,
          'orphans': orphans,
          'malformedFrontmatter': malformedFrontmatter,
          'frontmatterLinks': frontmatterLinks,
        },
        () {
          output.line('doctor report:');
          output.line('  broken links: ${brokenLinks.length}');
          for (final b in brokenLinks) {
            output.line(
                '    ${b['target']}  <- ${(b['referrers']! as List).join(', ')}');
          }
          output.line('  oversized notes: ${oversized.length}');
          for (final o in oversized) {
            output.line('    ${o['path']}  (${o['wordCount']} words)');
          }
          output.line('  duplicate titles/aliases: ${duplicateTitles.length}');
          for (final dup in duplicateTitles) {
            output.line(
                '    ${dup['name']}  -> ${(dup['paths']! as List).join(', ')}');
          }
          output.line('  ambiguous links: ${ambiguousLinks.length}');
          for (final a in ambiguousLinks) {
            output.line(
                '    ${a['target']}  <- ${(a['referrers']! as List).join(', ')}');
          }
          output.line('  orphans: ${orphans.length}');
          for (final path in orphans) {
            output.line('    $path');
          }
          output.line(
              '  unreadable frontmatter: ${malformedFrontmatter.length}');
          for (final path in malformedFrontmatter) {
            output.line('    $path  (no attributes: --filter cannot see it)');
          }
          output.line('  links in frontmatter: ${frontmatterLinks.length}');
          for (final path in frontmatterLinks) {
            output.line('    $path  (not in the link graph, not renamed)');
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
