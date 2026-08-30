import 'package:args/command_runner.dart';

import '../cli/output.dart';
import '../cli/vault_context.dart';
import '../model.dart';
import '../vault/linkgraph.dart';

/// Every finding `doctor` can make, as the JSON body the command emits.
///
/// Kept a plain function over [DocRecord]s so the report can be tested without
/// a vault on disk, which leaves the command below as argument handling and
/// rendering.
///
/// [pathPrefix] narrows what is *reported*, never what is *resolved*: the link
/// graph is always the whole vault, because a link into the subtree from
/// outside it still decides whether a note is an orphan, and a title still
/// collides with one filed elsewhere.
Map<String, Object?> buildDoctorReport({
  required List<DocRecord> docs,
  required int splitThresholdWords,
  required bool stale,
  String? pathPrefix,
}) {
  final resolver = LinkResolver(docs);
  bool inScope(String path) =>
      pathPrefix == null || path.startsWith(pathPrefix);

  // Broken links, listed under the notes that carry them: a referrer outside
  // the subtree is somebody else's problem this run.
  final brokenMap = resolver.brokenLinks();
  final brokenTargets = brokenMap.keys.toList()..sort();
  final brokenLinks = <Map<String, Object?>>[];
  for (final target in brokenTargets) {
    final referrers = (brokenMap[target]!.toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
        .map((d) => d.path)
        .where(inScope)
        .toList();
    if (referrers.isEmpty) continue;
    brokenLinks.add({'target': target, 'referrers': referrers});
  }

  // Oversized notes.
  final oversized = docs
      .where((d) => inScope(d.path) && d.wordCount > splitThresholdWords)
      .map((d) => <String, Object?>{
            'path': d.path,
            'wordCount': d.wordCount,
          })
      .toList()
    ..sort(
        (a, b) => (b['wordCount']! as int).compareTo(a['wordCount']! as int));

  // Duplicate/colliding titles and aliases: names that resolve to more than
  // one path, case-insensitively.
  final byName = <String, Set<String>>{};
  for (final d in docs) {
    byName.putIfAbsent(d.title.toLowerCase(), () => <String>{}).add(d.path);
    for (final a in d.aliases) {
      byName.putIfAbsent(a.toLowerCase(), () => <String>{}).add(d.path);
    }
  }
  final duplicateTitles = [
    for (final entry in byName.entries)
      // A collision is reported when one of its notes is in scope, but every
      // colliding path is shown: the note it collides with is the point,
      // wherever that one happens to sit.
      if (entry.value.length > 1 && entry.value.any(inScope))
        <String, Object?>{
          'name': entry.key,
          'paths': entry.value.toList()..sort(),
        },
  ]..sort((a, b) => (a['name']! as String).compareTo(b['name']! as String));

  // Ambiguous link targets: distinct outgoing targets that LinkResolver could
  // have resolved to more than one document.
  final allTargets = <String>{
    for (final d in docs) ...d.outLinks,
  };
  final ambiguousTargets = allTargets.where(resolver.isAmbiguous).toList()
    ..sort();
  final ambiguousLinks = <Map<String, Object?>>[];
  for (final target in ambiguousTargets) {
    final referrers = (docs.where((d) => d.outLinks.contains(target)).toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
        .map((d) => d.path)
        .where(inScope)
        .toList();
    if (referrers.isEmpty) continue;
    ambiguousLinks.add({'target': target, 'referrers': referrers});
  }

  // Frontmatter that opened a `---` block the YAML parser rejected. The note
  // still indexes and still searches; it just silently has no attributes, so
  // every --filter passes it by. Nothing else reports it.
  final malformedFrontmatter = docs
      .where((d) => d.frontmatterMalformed && inScope(d.path))
      .map((d) => d.path)
      .toList()
    ..sort();

  // Wikilinks written into frontmatter. Links are read from the body only, so
  // these are not edges: no backlink, no broken-link check above, and
  // `rename` will not rewrite them when their target moves.
  final frontmatterLinks = docs
      .where((d) => d.frontmatterLinks && inScope(d.path))
      .map((d) => d.path)
      .toList()
    ..sort();

  // Orphans: no inbound and no outbound links.
  final orphans = docs
      .where((d) =>
          inScope(d.path) &&
          d.outLinks.isEmpty &&
          resolver.backlinksTo(d).isEmpty)
      .map((d) => d.path)
      .toList()
    ..sort();

  return {
    'stale': stale,
    if (pathPrefix != null) 'pathPrefix': pathPrefix,
    'brokenLinks': brokenLinks,
    'oversized': oversized,
    'duplicateTitles': duplicateTitles,
    'ambiguousLinks': ambiguousLinks,
    'orphans': orphans,
    'malformedFrontmatter': malformedFrontmatter,
    'frontmatterLinks': frontmatterLinks,
  };
}

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
  final String invocation = 'my-brain doctor [--path-prefix <dir>]';

  DoctorCommand() {
    argParser.addOption('path-prefix',
        help: 'Report only notes under a vault-relative path prefix.');
  }

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
      final prefix = argResults!['path-prefix'] as String?;
      final report = buildDoctorReport(
        docs: await reader.allDocs(),
        splitThresholdWords: ctx.config.splitThresholdWords,
        stale: staleness.stale,
        pathPrefix: prefix,
      );

      List<Map<String, Object?>> entries(String key) =>
          (report[key]! as List).cast<Map<String, Object?>>();
      List<String> paths(String key) => (report[key]! as List).cast<String>();

      output.emit(
        report,
        () {
          final brokenLinks = entries('brokenLinks');
          final oversized = entries('oversized');
          final duplicateTitles = entries('duplicateTitles');
          final ambiguousLinks = entries('ambiguousLinks');
          final orphans = paths('orphans');
          final malformedFrontmatter = paths('malformedFrontmatter');
          final frontmatterLinks = paths('frontmatterLinks');

          output.line(prefix == null
              ? 'doctor report:'
              : 'doctor report for $prefix:');
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
