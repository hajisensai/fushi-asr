import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:asr_cli/asr_cli.dart';

Future<void> main(List<String> args) async {
  try {
    exitCode = await buildAsrCommandRunner().run(args) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    exitCode = 64; // EX_USAGE
  }
}
