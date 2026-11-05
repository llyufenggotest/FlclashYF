import 'dart:io';

/// Forward raw build bytes, independent of pipe chunk and locale boundaries.
/// Join both drains before returning so the final output is not truncated.
Future<int> forwardBuildOutput(Process process) async {
  final outputDone = stdout.addStream(process.stdout);
  final errorDone = stderr.addStream(process.stderr);
  final code = await process.exitCode;
  await Future.wait<void>([outputDone, errorDone]);
  return code;
}
