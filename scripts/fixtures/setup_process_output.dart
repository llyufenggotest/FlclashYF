import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final code = int.parse(args.single);
  final unicode = utf8.encode('中😀\n');
  stdout.add(List<int>.filled(65535, 65));
  stdout.add(unicode.sublist(0, 1));
  await stdout.flush();
  // Force a real pipe delivery boundary inside a UTF-8 sequence.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  stdout.add(unicode.sublist(1));
  await stdout.flush();
  final error = utf8.encode('错误✓\n');
  stderr.add(error.sublist(0, 2));
  await stderr.flush();
  await Future<void>.delayed(const Duration(milliseconds: 250));
  stderr.add(error.sublist(2));
  await stderr.flush();
  exitCode = code;
}
