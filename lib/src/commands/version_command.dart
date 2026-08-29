import 'package:args/command_runner.dart';

import '../cli/output.dart';
import '../cli/runner.dart' show myBrainVersion;

/// Prints the my-brain version. Works without a vault.
class VersionCommand extends Command<int> {
  @override
  final String name = 'version';
  @override
  final String description = 'Prints the my-brain version.';

  @override
  Future<int> run() async {
    final output = Output(
      json: globalResults?['json'] as bool? ?? false,
      quiet: globalResults?['quiet'] as bool? ?? false,
    );
    output.emit(
      {'version': myBrainVersion},
      () => output.line(myBrainVersion),
    );
    return 0;
  }
}
