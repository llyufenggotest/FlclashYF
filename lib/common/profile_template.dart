import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/common/exception.dart';
import 'package:fl_clash/common/path.dart';
import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';

class ProfileTemplateStore {
  ProfileTemplateStore({
    required Future<String> Function() path,
    required Future<String> Function() loadDefault,
  }) : _path = path,
       _loadDefault = loadDefault;

  final Future<String> Function() _path;
  final Future<String> Function() _loadDefault;
  Future<void> _tail = Future<void>.value();

  Future<String> load() {
    return _serializeValue(() async {
      final file = File(await _path());
      if (!await file.exists()) {
        return _loadDefault();
      }
      return file.readAsString();
    });
  }

  Future<void> save(
    String content,
    Future<String> Function(String content) validate,
  ) {
    return _serialize(() async {
      _validateYaml(content);
      final error = await validate(content);
      if (error.isNotEmpty) {
        throw MessageException(error);
      }
      final file = File(await _path());
      await file.parent.create(recursive: true);
      final temporary = await _temporaryFile(file);
      try {
        await temporary.writeAsString(content, flush: true);
        await temporary.rename(file.path);
      } catch (_) {
        if (await temporary.exists()) {
          await temporary.delete();
        }
        rethrow;
      }
    });
  }

  Future<void> reset() {
    return _serialize(() async {
      final file = File(await _path());
      if (await file.exists()) {
        await file.delete();
      }
    });
  }

  Future<void> _serialize(Future<void> Function() operation) {
    return _serializeValue(operation);
  }

  Future<T> _serializeValue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  static void _validateYaml(String content) {
    final document = loadYaml(content);
    if (document is! YamlMap) {
      throw const FormatException('Profile template must be a YAML mapping.');
    }
  }

  static Future<File> _temporaryFile(File target) async {
    final random = Random.secure();
    for (;;) {
      final candidate = File(
        '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 32)}',
      );
      try {
        await candidate.create(exclusive: true);
        return candidate;
      } on PathExistsException {
        continue;
      }
    }
  }
}

final profileTemplateStore = ProfileTemplateStore(
  path: () => appPath.profileTemplatePath,
  loadDefault: () => rootBundle.loadString('assets/data/profile_template.yaml'),
);
