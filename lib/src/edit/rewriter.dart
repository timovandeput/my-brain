import '../config.dart';
import '../model.dart';

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
  RewritePlan planRename(String from, String to) => throw UnimplementedError();

  /// Computes the edits for removing [path]: every referring wikilink is
  /// replaced by its display text, so prose still reads correctly.
  RewritePlan planDelete(String path) => throw UnimplementedError();

  /// Applies a plan: rewrites referring files first, then moves or deletes the
  /// target. Referrers go first so an interrupted run leaves links pointing at
  /// a note that still exists, rather than at one that no longer does.
  Future<void> apply(RewritePlan plan) => throw UnimplementedError();
}
