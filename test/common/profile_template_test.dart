import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/exception.dart';
import 'package:fl_clash/common/profile_template.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late File overrideFile;
  late ProfileTemplateStore store;
  const defaultContent = 'mode: rule\n';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('profile_template_test_');
    overrideFile = File('${directory.path}/profile_template.yaml');
    store = ProfileTemplateStore(
      path: () async => overrideFile.path,
      loadDefault: () async => defaultContent,
    );
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('load returns the default when no override exists', () async {
    expect(await store.load(), defaultContent);
  });

  test('load returns the saved override', () async {
    await overrideFile.writeAsString('mode: global\n');

    expect(await store.load(), 'mode: global\n');
  });

  test('save validates and atomically replaces the override', () async {
    await overrideFile.writeAsString('mode: direct\n');
    String? validated;

    await store.save('mode: global\n', (content) async {
      validated = content;
      return '';
    });

    expect(validated, 'mode: global\n');
    expect(await overrideFile.readAsString(), 'mode: global\n');
    expect(await store.load(), 'mode: global\n');
    expect(_temporaryFiles(directory), isEmpty);
  });

  test('reset deletes the override and restores the default', () async {
    await overrideFile.writeAsString('mode: global\n');

    await store.reset();

    expect(await overrideFile.exists(), isFalse);
    expect(await store.load(), defaultContent);
  });

  test(
    'invalid YAML preserves the override without calling the core',
    () async {
      await overrideFile.writeAsString('mode: direct\n');
      var validationCalls = 0;

      await expectLater(
        store.save('mode: [\n', (_) async {
          validationCalls++;
          return '';
        }),
        throwsA(isA<FormatException>()),
      );

      expect(validationCalls, 0);
      expect(await overrideFile.readAsString(), 'mode: direct\n');
      expect(_temporaryFiles(directory), isEmpty);
    },
  );

  test('non-mapping YAML preserves the override', () async {
    await overrideFile.writeAsString('mode: direct\n');

    await expectLater(
      store.save('- mode\n- direct\n', (_) async => ''),
      throwsA(isA<FormatException>()),
    );

    expect(await overrideFile.readAsString(), 'mode: direct\n');
    expect(_temporaryFiles(directory), isEmpty);
  });

  test('core validation error preserves the override', () async {
    await overrideFile.writeAsString('mode: direct\n');

    await expectLater(
      store.save('mode: global\n', (_) async => 'core rejected template'),
      throwsA(
        isA<MessageException>().having(
          (error) => error.message,
          'message',
          'core rejected template',
        ),
      ),
    );

    expect(await overrideFile.readAsString(), 'mode: direct\n');
    expect(_temporaryFiles(directory), isEmpty);
  });

  test('failed replacement removes its temporary file', () async {
    await overrideFile.create();
    await overrideFile.delete();
    await Directory(overrideFile.path).create();

    await expectLater(
      store.save('mode: global\n', (_) async => ''),
      throwsA(isA<FileSystemException>()),
    );

    expect(await Directory(overrideFile.path).exists(), isTrue);
    expect(_temporaryFiles(directory), isEmpty);
  });

  test('a failed save does not block the next operation', () async {
    await expectLater(
      store.save('mode: [\n', (_) async => ''),
      throwsA(isA<FormatException>()),
    );

    await store.save('mode: global\n', (_) async => '');

    expect(await overrideFile.readAsString(), 'mode: global\n');
  });

  test('save operations are serialized', () async {
    final firstValidation = Completer<String>();
    final validationOrder = <String>[];

    final first = store.save('mode: first\n', (content) async {
      validationOrder.add(content);
      return firstValidation.future;
    });
    final second = store.save('mode: second\n', (content) async {
      validationOrder.add(content);
      return '';
    });
    await Future<void>.delayed(Duration.zero);

    expect(validationOrder, ['mode: first\n']);
    firstValidation.complete('');
    await Future.wait([first, second]);

    expect(validationOrder, ['mode: first\n', 'mode: second\n']);
    expect(await overrideFile.readAsString(), 'mode: second\n');
    expect(_temporaryFiles(directory), isEmpty);
  });

  test('load waits for an in-progress save', () async {
    final validation = Completer<String>();
    final save = store.save('mode: global\n', (_) => validation.future);
    await Future<void>.delayed(Duration.zero);

    var loaded = false;
    final load = store.load().then((value) {
      loaded = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);

    expect(loaded, isFalse);
    validation.complete('');
    await save;
    expect(await load, 'mode: global\n');
  });
}

List<FileSystemEntity> _temporaryFiles(Directory directory) {
  return directory
      .listSync()
      .where((entity) => entity.path.contains('.tmp-'))
      .toList();
}
