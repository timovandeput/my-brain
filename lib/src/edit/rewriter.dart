import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../model.dart';
import '../vault/linkgraph.dart';
import '../vault/markdown.dart';

/// One file edit produced by a rename or delete.
class LinkEdit {
  /// Vault-relative path of the file that contains the link.
  final String path;

  /// 1-based line number of the edited link.
  final int line;

  final String before;
  final String after;

  const LinkEdit({
    required this.path,
    required this.line,
    required this.before,
    required this.after,
  });
}

/// What a rename or delete would do, or did.
class RewritePlan {
  /// Vault-relative source path, or null for a delete of a missing note.
  final String? from;

  /// Vault-relative destination path; null for a delete.
  final String? to;

  /// Every link occurrence that needs rewriting.
  final List<LinkEdit> edits;

  /// Files that link to the target and could not be rewritten automatically,
  /// with the reason - reported so the agent can fix them by hand rather than
  /// silently leaving a dangling link.
  final Map<String, String> unresolved;

  const RewritePlan({
    required this.from,
    required this.to,
    required this.edits,
    this.unresolved = const {},
  });

  int get fileCount => edits.map((LinkEdit e) => e.path).toSet().length;
}

/// A single replacement, located by absolute character offsets in the file as
/// it sits on disk (frontmatter included).
class _Replacement {
  final int start;
  final int end;
  final String text;
  const _Replacement(this.start, this.end, this.text);
}

/// Renames and deletes notes while keeping the link graph intact.
///
/// This lives in the executable rather than in agent instructions because it is
/// purely mechanical and has to be exhaustive: one missed referrer is a
/// permanently orphaned link, and an agent editing dozens of files by hand will
/// eventually miss one. The rewriter preserves each link's `|alias` and
/// `#anchor`, and skips occurrences inside code spans.
class LinkRewriter {
  final BrainConfig config;
  final List<DocRecord> docs;

  const LinkRewriter(this.config, this.docs);

  /// Computes the edits for moving [from] to [to] without applying them.
  ///
  /// [to] may be a bare name or a path; a missing `.md` extension is added.
  RewritePlan planRename(String from, String to) {
    final target = _normalizeDestination(to);
    return _plan(from: from, to: target);
  }

  /// Computes the edits for removing [path]: every referring wikilink is
  /// replaced by its display text, so prose still reads correctly.
  RewritePlan planDelete(String path) => _plan(from: path, to: null);

  RewritePlan _plan({required String from, required String? to}) {
    final resolver = LinkResolver(docs);
    if (!docs.any((DocRecord d) => d.path == from)) {
      throw ArgumentError('not an indexed note: $from');
    }

    final edits = <LinkEdit>[];
    final unresolved = <String, String>{};

    for (final doc in docs) {
      if (doc.path == from && to == null) continue;
      final file = File(p.join(config.vaultRoot, p.joinAll(doc.path.split('/'))));
      if (!file.existsSync()) {
        unresolved[doc.path] = 'file no longer exists';
        continue;
      }
      // Only re-read files that actually point at the target. On a large
      // vault this is the difference between reading three files and reading
      // all of them.
      final pointsHere =
          doc.outLinks.any((String t) => resolver.resolve(t)?.path == from);
      if (!pointsHere) continue;

      final text = file.readAsStringSync();
      final note = parseNote(text, filename: p.basename(doc.path));
      // Wikilink offsets are relative to the body, but we edit the file, which
      // still carries its frontmatter.
      final shift = note.frontmatter.bodyOffset;

      for (final link in note.wikiLinks) {
        if (link.target.isEmpty) continue;
        if (resolver.resolve(link.target)?.path != from) continue;

        final start = link.start + shift;
        final end = link.end + shift;
        final before = text.substring(start, end);
        final after = to == null
            ? _displayText(link)
            : _rewrittenLink(link, to);
        if (before == after) continue;
        edits.add(LinkEdit(
          path: doc.path,
          line: _lineOf(text, start),
          before: before,
          after: after,
        ));
      }
    }

    return RewritePlan(
      from: from,
      to: to,
      edits: edits,
      unresolved: unresolved,
    );
  }

  /// Applies a plan: rewrites referring files first, then moves or deletes the
  /// target. Referrers go first so an interrupted run leaves links pointing at
  /// a note that still exists, rather than at one that no longer does.
  Future<void> apply(RewritePlan plan) async {
    final from = plan.from;
    if (from == null) return;

    final byFile = <String, List<LinkEdit>>{};
    for (final edit in plan.edits) {
      (byFile[edit.path] ??= <LinkEdit>[]).add(edit);
    }

    final resolver = LinkResolver(docs);
    for (final entry in byFile.entries) {
      final file =
          File(p.join(config.vaultRoot, p.joinAll(entry.key.split('/'))));
      if (!file.existsSync()) continue;
      final text = await file.readAsString();
      final note = parseNote(text, filename: p.basename(entry.key));
      final shift = note.frontmatter.bodyOffset;

      // Recompute offsets from the file as it is right now rather than trusting
      // the ones captured at plan time: the plan may have been made before an
      // earlier command in the same session touched this file.
      final replacements = <_Replacement>[];
      for (final link in note.wikiLinks) {
        if (link.target.isEmpty) continue;
        if (resolver.resolve(link.target)?.path != from) continue;
        final after = plan.to == null
            ? _displayText(link)
            : _rewrittenLink(link, plan.to!);
        replacements.add(
          _Replacement(link.start + shift, link.end + shift, after),
        );
      }
      if (replacements.isEmpty) continue;

      // Rebuild the file in one forward pass, copying the text between
      // replacements. Splicing in place would invalidate every offset after
      // the first edit.
      replacements
          .sort((_Replacement a, _Replacement b) => a.start.compareTo(b.start));
      final buffer = StringBuffer();
      var cursor = 0;
      for (final r in replacements) {
        buffer
          ..write(text.substring(cursor, r.start))
          ..write(r.text);
        cursor = r.end;
      }
      buffer.write(text.substring(cursor));
      await file.writeAsString(buffer.toString());
    }

    final sourceFile =
        File(p.join(config.vaultRoot, p.joinAll(from.split('/'))));
    final to = plan.to;
    if (to == null) {
      if (sourceFile.existsSync()) await sourceFile.delete();
      return;
    }
    final destination =
        File(p.join(config.vaultRoot, p.joinAll(to.split('/'))));
    if (destination.path == sourceFile.path) return;
    if (destination.existsSync()) {
      throw ArgumentError('destination already exists: $to');
    }
    await destination.parent.create(recursive: true);
    await sourceFile.rename(destination.path);
  }

  /// Adds a `.md` extension when the destination omits it, and normalises
  /// separators to the vault-relative `/` form.
  String _normalizeDestination(String to) {
    final normalized = p.split(to).join('/');
    return normalized.toLowerCase().endsWith('.md')
        ? normalized
        : '$normalized.md';
  }

  /// Rebuilds a wikilink pointing at [newPath], keeping the original's alias
  /// and anchor, and keeping its style: a link written as a bare name stays a
  /// bare name, a link written as a path stays a path. Rewriting `[[Deep Work]]`
  /// into `[[notes/deep-focus]]` would be correct and also ugly, and the user
  /// has to read these notes.
  String _rewrittenLink(WikiLink link, String newPath) {
    final withoutExtension = newPath.endsWith('.md')
        ? newPath.substring(0, newPath.length - 3)
        : newPath;
    final target = link.target.contains('/')
        ? withoutExtension
        : p.basename(withoutExtension);

    final buffer = StringBuffer(link.embed ? '![[' : '[[')..write(target);
    if (link.anchor != null) buffer.write('#${link.anchor}');
    if (link.alias != null) buffer.write('|${link.alias}');
    buffer.write(']]');
    return buffer.toString();
  }

  /// What a link should become once its target is gone: the text a reader was
  /// meant to see, so the sentence around it still reads.
  String _displayText(WikiLink link) => link.alias ?? link.target;

  int _lineOf(String text, int offset) {
    var line = 1;
    for (var i = 0; i < offset && i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0a) line++;
    }
    return line;
  }
}
