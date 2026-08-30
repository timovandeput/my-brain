import 'dart:io';

import 'package:args/command_runner.dart';

import '../commands/attrs_command.dart';
import '../commands/doctor_command.dart';
import '../commands/index_command.dart';
import '../commands/init_command.dart';
import '../commands/links_command.dart';
import '../commands/rename_command.dart';
import '../commands/rm_command.dart';
import '../commands/search_command.dart';
import '../commands/similar_command.dart';
import '../commands/status_command.dart';
import '../commands/version_command.dart';
import 'vault_context.dart' show CliError;

export 'runner_version.dart' show myBrainVersion;

/// Builds the top-level [CommandRunner], wiring the global `--vault`,
/// `--json` and `--quiet` options and every subcommand.
CommandRunner<int> buildRunner() {
  final runner = CommandRunner<int>(
    'my-brain',
    'Indexes a vault of markdown notes with BM25 for fast agent search.',
  );

  runner.argParser
    ..addOption(
      'vault',
      help: 'Vault root directory '
          '(default: search upward from the current directory for .brain/).',
    )
    ..addFlag(
      'json',
      negatable: false,
      help: 'Emit machine-readable JSON to stdout.',
    )
    ..addFlag(
      'quiet',
      negatable: false,
      help: 'Suppress progress output and the staleness warning.',
    );

  runner
    ..addCommand(InitCommand())
    ..addCommand(IndexCommand())
    ..addCommand(StatusCommand())
    ..addCommand(SearchCommand())
    ..addCommand(SimilarCommand())
    ..addCommand(LinksCommand())
    ..addCommand(AttrsCommand())
    ..addCommand(DoctorCommand())
    ..addCommand(RenameCommand())
    ..addCommand(RmCommand())
    ..addCommand(VersionCommand());

  return runner;
}

/// Runs the CLI with [args], returning the process exit code.
Future<int> runCli(List<String> args) async {
  final runner = buildRunner();
  try {
    final result = await runner.run(args);
    return result ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln();
    stderr.writeln(e.usage);
    return 2;
  } on CliError catch (e) {
    // Commands normally catch and translate their own CliErrors; this is a
    // safety net so one can never crash the process with a stack trace.
    stderr.writeln(e.message);
    return e.exitCode;
  }
}
