import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import 'templates.g.dart';

/// Wraps the region of a file that `init` owns. Anything outside these markers
/// is the user's and is carried through untouched on every re-run.
const String managedBegin = '<!-- my-brain:begin -->';
const String managedEnd = '<!-- my-brain:end -->';

/// What `init` proposes to do to one path.
enum ChangeKind {
  /// The file does not exist yet.
  create,

  /// The file exists and its managed content differs.
  update,

  /// The file exists and already matches; nothing to do.
  unchanged,

  /// The file exists and `init` will not touch it (config.yaml, so a tuned
  /// vault never has its settings reset by a re-run).
  keep,
}

/// One proposed file change.
class FileChange {
  /// Vault-relative path, `/` separated.
  final String path;
  final ChangeKind kind;

  /// Current contents, or null when the file does not exist.
  final String? before;

  /// Contents after the change.
  final String after;

  const FileChange({
    required this.path,
    required this.kind,
    required this.before,
    required this.after,
  });

  bool get isNoop => kind == ChangeKind.unchanged || kind == ChangeKind.keep;

  /// A unified-style diff of [before] against [after], for the confirmation
  /// prompt. Whole-file for a creation, hunks with three lines of context
  /// otherwise.
  String renderDiff() {
    if (before == null) {
      final lines = after.split('\n');
      final shown = lines.take(40).toList();
      final body = shown.map((String l) => '+$l').join('\n');
      final more = lines.length > shown.length
          ? '\n... ${lines.length - shown.length} more lines'
          : '';
      return '$body$more';
    }
    return _unifiedDiff(before!.split('\n'), after.split('\n'));
  }
}

/// How the vault-local skills are exposed to Claude Code.
enum SkillLinkKind {
  /// `.claude/skills` created as a relative symlink to `../.agents/skills`.
  symlink,

  /// Symlinks unavailable (Windows without developer mode) or `.claude/skills`
  /// already exists as a real directory holding other skills: the skill files
  /// are copied in, and re-running `init` re-syncs them.
  copy,

  /// Already correct.
  unchanged,
}

/// The full set of changes `init` proposes for one vault.
class InstallPlan {
  final String vaultRoot;
  final List<FileChange> changes;
  final SkillLinkKind skillLink;

  /// Content directories that do not exist yet, vault-relative.
  final List<String> missingDirectories;

  /// Absolute path of the `my-brain` binary recorded in AGENTS.md.
  final String binaryPath;

  const InstallPlan({
    required this.vaultRoot,
    required this.changes,
    required this.skillLink,
    required this.missingDirectories,
    required this.binaryPath,
  });

  List<FileChange> get pending =>
      changes.where((FileChange c) => !c.isNoop).toList();

  bool get isUpToDate =>
      pending.isEmpty &&
      missingDirectories.isEmpty &&
      skillLink != SkillLinkKind.copy;
}

/// Creates and refreshes the my-brain files inside a vault.
///
/// `init` writes the agent's own operating instructions, so it has to be able
/// to update them when the tool gains commands - but the user is expected to
/// add their own vault-specific guidance to AGENTS.md. That is why AGENTS.md
/// is marker-managed (only the region between [managedBegin] and [managedEnd]
/// is rewritten) while the skills and CLAUDE.md are regenerated whole, and
/// config.yaml is never overwritten once it exists.
class VaultInstaller {
  final String vaultRoot;
  final String version;

  const VaultInstaller({required this.vaultRoot, required this.version});

  /// The directories the vault's content lives in, vault-relative.
  ///
  /// The root is the agent's own instructions and the tool's dot-directories;
  /// notes written beside them bury them, which is the whole reason these
  /// exist. They are created empty and carry no placeholder file: git does not
  /// track an empty directory, but a vault stops having empty ones the moment
  /// it has a note.
  static const List<String> contentDirectories = [
    'notes',
    'logs',
    'attachments',
  ];

  /// Where the agent should invoke the tool.
  ///
  /// Prefers the absolute path of the running executable so the instructions
  /// work even when the binary is not on PATH. Falls back to the bare command
  /// name when running from source under `dart run`, where the resolved
  /// executable is the Dart VM rather than my-brain.
  static String resolveBinaryPath() {
    final exe = Platform.resolvedExecutable;
    final stem = p.basenameWithoutExtension(exe).toLowerCase();
    if (stem == 'dart' || stem == 'dartaotruntime') return 'my-brain';
    return exe;
  }

  /// Computes what `init` would do, without touching the filesystem.
  InstallPlan plan() {
    final binaryPath = resolveBinaryPath();
    final vars = <String, String>{
      'BINARY': binaryPath,
      'VERSION': version,
      'VAULT': vaultRoot,
    };

    final changes = <FileChange>[
      _markerManaged('AGENTS.md', _render(agentsMdTemplate, vars)),
      _whole('CLAUDE.md', _render(claudeMdTemplate, vars)),
      _whole(
        '.agents/skills/brain-capture/SKILL.md',
        _render(brainCaptureSkillTemplate, vars),
      ),
      _whole(
        '.agents/skills/brain-maintain/SKILL.md',
        _render(brainMaintainSkillTemplate, vars),
      ),
      _createOnly(
        '$brainDirName/$configFileName',
        BrainConfig(vaultRoot: vaultRoot).toYaml(),
      ),
    ];

    final gitignore = _gitignoreChange();
    if (gitignore != null) changes.add(gitignore);

    return InstallPlan(
      vaultRoot: vaultRoot,
      changes: changes,
      skillLink: _skillLinkState(),
      missingDirectories: [
        for (final dir in contentDirectories)
          if (!Directory(p.join(vaultRoot, dir)).existsSync()) dir,
      ],
      binaryPath: binaryPath,
    );
  }

  /// Creates the content directories named in [relativePaths].
  void applyDirectories(List<String> relativePaths) {
    for (final dir in relativePaths) {
      Directory(p.join(vaultRoot, p.joinAll(dir.split('/'))))
          .createSync(recursive: true);
    }
  }

  /// Writes [change] to disk, creating parent directories as needed.
  void applyChange(FileChange change) {
    final file = File(p.join(vaultRoot, p.joinAll(change.path.split('/'))));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(change.after);
  }

  /// Makes the vault's skills visible to Claude Code at `.claude/skills`.
  ///
  /// Skills live in `.agents/skills/` so that agents following the AGENTS.md
  /// convention and Claude Code both read the same files rather than two
  /// copies that drift apart. A relative symlink is the clean way to do that;
  /// where symlinks are not available the files are copied and re-synced on
  /// every `init`.
  SkillLinkKind applySkillLink() {
    final claudeSkills = p.join(vaultRoot, '.claude', 'skills');
    final agentsSkills = p.join(vaultRoot, '.agents', 'skills');
    final type = FileSystemEntity.typeSync(claudeSkills, followLinks: false);

    if (type == FileSystemEntityType.link) {
      final target = Link(claudeSkills).targetSync();
      final resolved = p.normalize(
        p.isAbsolute(target) ? target : p.join(p.dirname(claudeSkills), target),
      );
      if (resolved == p.normalize(agentsSkills)) return SkillLinkKind.unchanged;
      Link(claudeSkills).deleteSync();
    } else if (type == FileSystemEntityType.directory) {
      // A real directory here means the user has other Claude skills; copying
      // in is the only option that does not delete them.
      _copySkills(agentsSkills, claudeSkills);
      return SkillLinkKind.copy;
    }

    Directory(p.dirname(claudeSkills)).createSync(recursive: true);
    try {
      Link(claudeSkills).createSync(p.join('..', '.agents', 'skills'));
      return SkillLinkKind.symlink;
    } on FileSystemException {
      // Windows refuses symlink creation without developer mode or elevation.
      _copySkills(agentsSkills, claudeSkills);
      return SkillLinkKind.copy;
    }
  }

  /// Mirrors the vault's skills into [to], and removes copies of skills this
  /// version no longer ships.
  ///
  /// Only directories named after a skill my-brain owns are pruned; anything
  /// else under `.claude/skills` belongs to the user and is left alone.
  void _copySkills(String from, String to) {
    final source = Directory(from);
    if (!source.existsSync()) return;

    final owned = source
        .listSync(followLinks: false)
        .whereType<Directory>()
        .map((Directory d) => p.basename(d.path))
        .toSet();

    for (final entity in source.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: from);
      final dest = File(p.join(to, rel));
      dest.parent.createSync(recursive: true);
      entity.copySync(dest.path);
    }

    // A skill dropped in a later version would otherwise linger here forever,
    // and a stale copy of an instruction file is worse than none.
    final destination = Directory(to);
    if (!destination.existsSync()) return;
    for (final entity in destination.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith('brain-')) continue;
      if (owned.contains(name)) continue;
      entity.deleteSync(recursive: true);
    }
  }

  SkillLinkKind _skillLinkState() {
    final claudeSkills = p.join(vaultRoot, '.claude', 'skills');
    final type = FileSystemEntity.typeSync(claudeSkills, followLinks: false);
    if (type == FileSystemEntityType.link) {
      final target = Link(claudeSkills).targetSync();
      final resolved = p.normalize(
        p.isAbsolute(target) ? target : p.join(p.dirname(claudeSkills), target),
      );
      if (resolved == p.normalize(p.join(vaultRoot, '.agents', 'skills'))) {
        return SkillLinkKind.unchanged;
      }
    }
    if (type == FileSystemEntityType.directory) return SkillLinkKind.copy;
    return SkillLinkKind.symlink;
  }

  String _render(String template, Map<String, String> vars) {
    var out = template;
    vars.forEach((String key, String value) {
      out = out.replaceAll('{{$key}}', value);
    });
    return out;
  }

  String? _read(String relativePath) {
    final file = File(p.join(vaultRoot, p.joinAll(relativePath.split('/'))));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  /// A file whose content is entirely owned by my-brain.
  FileChange _whole(String path, String content) {
    final before = _read(path);
    return FileChange(
      path: path,
      kind: before == null
          ? ChangeKind.create
          : (before == content ? ChangeKind.unchanged : ChangeKind.update),
      before: before,
      after: content,
    );
  }

  /// A file written once and then left alone.
  FileChange _createOnly(String path, String content) {
    final before = _read(path);
    return FileChange(
      path: path,
      kind: before == null ? ChangeKind.create : ChangeKind.keep,
      before: before,
      after: before ?? content,
    );
  }

  /// A file where only the marker-delimited region belongs to my-brain.
  ///
  /// When the file exists without markers we keep the user's text and append
  /// the managed block below it, rather than overwriting prose we did not
  /// write.
  FileChange _markerManaged(String path, String content) {
    final before = _read(path);
    final block = '$managedBegin\n$content$managedEnd\n';

    if (before == null) {
      return FileChange(
        path: path,
        kind: ChangeKind.create,
        before: null,
        after: block,
      );
    }

    final start = before.indexOf(managedBegin);
    final end = before.indexOf(managedEnd);
    final String after;
    if (start != -1 && end > start) {
      after = before.substring(0, start) +
          block.trimRight() +
          before.substring(end + managedEnd.length);
    } else {
      final separator = before.endsWith('\n') ? '\n' : '\n\n';
      after = '$before$separator$block';
    }

    return FileChange(
      path: path,
      kind: before == after ? ChangeKind.unchanged : ChangeKind.update,
      before: before,
      after: after,
    );
  }

  /// Keeps the index out of version control, but only in a vault that is
  /// actually a git repository - writing a .gitignore into a plain directory
  /// would be presumptuous.
  FileChange? _gitignoreChange() {
    if (!Directory(p.join(vaultRoot, '.git')).existsSync()) return null;
    const entries = ['.brain/index.bin', '.brain/index.bin.tmp'];
    final before = _read('.gitignore');
    if (before == null) {
      return FileChange(
        path: '.gitignore',
        kind: ChangeKind.create,
        before: null,
        after: '${entries.join('\n')}\n',
      );
    }
    final lines = before.split('\n').map((String l) => l.trim()).toSet();
    final missing = entries.where((String e) => !lines.contains(e)).toList();
    if (missing.isEmpty) {
      return FileChange(
        path: '.gitignore',
        kind: ChangeKind.unchanged,
        before: before,
        after: before,
      );
    }
    final separator = before.endsWith('\n') ? '' : '\n';
    return FileChange(
      path: '.gitignore',
      kind: ChangeKind.update,
      before: before,
      after: '$before$separator${missing.join('\n')}\n',
    );
  }
}

/// Line-level unified diff with three lines of context.
///
/// Files here are a few hundred lines at most, so the quadratic LCS table is
/// cheaper than pulling in a diff dependency.
String _unifiedDiff(List<String> a, List<String> b) {
  final lcs = List<List<int>>.generate(
    a.length + 1,
    (_) => List<int>.filled(b.length + 1, 0),
    growable: false,
  );
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  final ops = <({String sign, String text})>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      ops.add((sign: ' ', text: a[i]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      ops.add((sign: '-', text: a[i]));
      i++;
    } else {
      ops.add((sign: '+', text: b[j]));
      j++;
    }
  }
  while (i < a.length) {
    ops.add((sign: '-', text: a[i++]));
  }
  while (j < b.length) {
    ops.add((sign: '+', text: b[j++]));
  }

  // Keep only changed lines plus three lines of context around them.
  const context = 3;
  final keep = List<bool>.filled(ops.length, false);
  for (var k = 0; k < ops.length; k++) {
    if (ops[k].sign == ' ') continue;
    final from = (k - context).clamp(0, ops.length - 1);
    final to = (k + context).clamp(0, ops.length - 1);
    for (var m = from; m <= to; m++) {
      keep[m] = true;
    }
  }

  final buffer = StringBuffer();
  var skipping = false;
  for (var k = 0; k < ops.length; k++) {
    if (!keep[k]) {
      if (!skipping) {
        buffer.writeln('...');
        skipping = true;
      }
      continue;
    }
    skipping = false;
    buffer.writeln('${ops[k].sign}${ops[k].text}');
  }
  return buffer.toString().trimRight();
}
