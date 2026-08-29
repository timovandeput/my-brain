import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../cli/output.dart';
import '../cli/runner_version.dart';
import '../setup/installer.dart';

/// Sets up a vault: writes the config, the agent instructions and the skills,
/// and links the skills into `.claude/skills`.
///
/// This is the one command that edits files the user owns, so it always shows
/// what it is about to do and asks first, unless `--yes` is given.
class InitCommand extends Command<int> {
  InitCommand() {
    argParser
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Apply every change without asking.',
      )
      ..addFlag(
        'check',
        negatable: false,
        help: 'Report what is out of date and exit non-zero; change nothing.',
      );
  }

  @override
  String get name => 'init';

  @override
  String get description =>
      'Create or refresh the my-brain files in a vault (config, AGENTS.md, skills).';

  @override
  String get invocation => 'my-brain init [--vault <dir>] [--yes] [--check]';

  @override
  Future<int> run() async {
    final global = globalResults!;
    final out = Output(
      json: global['json'] as bool,
      quiet: global['quiet'] as bool,
    );

    // Unlike every other command, init does not require an existing vault -
    // creating one is the point. The target is --vault, or the cwd.
    final vaultRoot = p.absolute(
      (global['vault'] as String?) ?? Directory.current.path,
    );
    if (!Directory(vaultRoot).existsSync()) {
      out.error('no such directory: $vaultRoot');
      return 1;
    }

    final installer = VaultInstaller(
      vaultRoot: vaultRoot,
      version: myBrainVersion,
    );
    final plan = installer.plan();
    final check = argResults!['check'] as bool;
    final assumeYes = argResults!['yes'] as bool;

    if (global['json'] as bool) {
      out.emit({
        'vault': vaultRoot,
        'binary': plan.binaryPath,
        'upToDate': plan.isUpToDate,
        'skillLink': plan.skillLink.name,
        'changes': [
          for (final c in plan.changes)
            {'path': c.path, 'kind': c.kind.name},
        ],
      }, () {});
      if (check) return plan.isUpToDate ? 0 : 1;
      if (!assumeYes) {
        out.error(
          'refusing to modify files unattended: re-run with --yes to apply.',
        );
        return 1;
      }
      _applyAll(installer, plan, out);
      return 0;
    }

    if (plan.isUpToDate) {
      out.line('$vaultRoot is up to date.');
      return 0;
    }

    out.line(
      plan.changes.any((FileChange c) => c.kind == ChangeKind.create)
          ? 'Setting up a my-brain vault in $vaultRoot'
          : 'Refreshing the my-brain files in $vaultRoot',
    );
    out.line('');

    if (check) {
      for (final change in plan.pending) {
        out.line('  ${change.kind.name.padRight(9)} ${change.path}');
      }
      if (plan.skillLink == SkillLinkKind.copy) {
        out.line('  copy      .claude/skills (re-sync from .agents/skills)');
      }
      out.line('');
      out.line('Run `my-brain init` to apply.');
      return 1;
    }

    var applied = 0;
    var declined = 0;
    for (final change in plan.pending) {
      final verb = change.kind == ChangeKind.create ? 'Create' : 'Update';
      out.line('$verb ${change.path}:');
      out.line('');
      out.line(_indent(change.renderDiff()));
      out.line('');

      if (!assumeYes && !out.confirm('  Write ${change.path}?')) {
        declined++;
        out.line('  skipped.');
        out.line('');
        continue;
      }
      installer.applyChange(change);
      applied++;
      out.line('  written.');
      out.line('');
    }

    // The skill link is only useful once the skill files exist, so it goes
    // last and is skipped when the user declined to write them.
    final linkResult = Directory(p.join(vaultRoot, '.agents', 'skills'))
            .existsSync()
        ? installer.applySkillLink()
        : SkillLinkKind.unchanged;

    switch (linkResult) {
      case SkillLinkKind.symlink:
        out.line('Linked .claude/skills -> ../.agents/skills');
      case SkillLinkKind.copy:
        out.line(
          'Copied skills into .claude/skills '
          '(symlink unavailable; re-run init after changing a skill).',
        );
      case SkillLinkKind.unchanged:
        break;
    }

    out.line('');
    if (declined > 0) {
      out.line('$applied file(s) written, $declined skipped.');
    }
    _printNextSteps(out, plan, vaultRoot);
    return 0;
  }

  void _applyAll(VaultInstaller installer, InstallPlan plan, Output out) {
    for (final change in plan.pending) {
      installer.applyChange(change);
    }
    if (Directory(p.join(plan.vaultRoot, '.agents', 'skills')).existsSync()) {
      installer.applySkillLink();
    }
  }

  void _printNextSteps(Output out, InstallPlan plan, String vaultRoot) {
    final indexed = File(p.join(vaultRoot, '.brain', 'index.bin')).existsSync();
    out.line('Next:');
    if (!indexed) {
      out.line('  1. ${plan.binaryPath} index      build the search index');
      out.line('  2. start your agent in $vaultRoot');
      out.line('  3. say "/brain-capture" to add your first note');
    } else {
      out.line('  ${plan.binaryPath} index        refresh the search index');
    }
  }

  String _indent(String text) =>
      text.split('\n').map((String l) => '    $l').join('\n');
}
