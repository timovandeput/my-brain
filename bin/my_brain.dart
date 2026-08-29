import 'dart:io';

import 'package:my_brain/src/cli/runner.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
