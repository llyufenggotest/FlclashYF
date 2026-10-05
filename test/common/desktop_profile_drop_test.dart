import 'dart:io';

import 'package:fl_clash/common/desktop_profile_drop.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AppLocalizations.delegate.load(const Locale('en'));
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('profile_drop_test');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('reads a single UTF-8 profile file', () async {
    final file = File('${directory.path}/My profile.YAML');
    await file.writeAsString('proxies: []\n');
    expect(await readDroppedProfile([file.path]), 'proxies: []\n');
    expect(droppedProfileName([file.path]), 'My profile');
  });

  test('rejects no files and multiple files', () async {
    expect(() => readDroppedProfile([]), throwsA(isA<DropImportException>()));
    expect(
      () => readDroppedProfile(['one.yaml', 'two.yaml']),
      throwsA(isA<DropImportException>()),
    );
  });

  test('rejects unsupported extensions and directories', () async {
    final jsonFile = File('${directory.path}/profile.json');
    await jsonFile.writeAsString('{}');
    expect(
      () => readDroppedProfile([jsonFile.path]),
      throwsA(isA<DropImportException>()),
    );
    expect(
      () => readDroppedProfile([directory.path]),
      throwsA(isA<DropImportException>()),
    );
  });

  test('accepts yaml yml txt and conf extensions case-insensitively', () async {
    for (final extension in ['yaml', 'YML', 'txt', 'CONF']) {
      final file = File('${directory.path}/profile.$extension');
      await file.writeAsString('content');
      expect(await readDroppedProfile([file.path]), 'content');
    }
  });

  test(
    'rejects files larger than 2 MiB without reading their content',
    () async {
      final file = File('${directory.path}/large.yaml');
      await file.writeAsBytes(List.filled(maxDroppedProfileBytes + 1, 0));
      expect(
        () => readDroppedProfile([file.path]),
        throwsA(isA<DropImportException>()),
      );
    },
  );

  test('accepts a file exactly 2 MiB', () async {
    final file = File('${directory.path}/limit.conf');
    await file.writeAsBytes(List.filled(maxDroppedProfileBytes, 97));
    expect(
      (await readDroppedProfile([file.path])).length,
      maxDroppedProfileBytes,
    );
  });

  test('rejects malformed UTF-8', () async {
    final file = File('${directory.path}/invalid.txt');
    await file.writeAsBytes([0xc3, 0x28]);
    expect(
      () => readDroppedProfile([file.path]),
      throwsA(isA<DropImportException>()),
    );
  });
}
