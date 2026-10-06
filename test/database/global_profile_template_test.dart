import 'dart:convert';

import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() {
  test('old JSON profiles default template off', () {
    final json = Profile.normal().toJson()..remove('useGlobalTemplate');
    expect(Profile.fromJson(json).useGlobalTemplate, isFalse);
  });

  test(
    'template preference persists independently of overwrite settings',
    () async {
      final database = Database(NativeDatabase.memory());
      addTearDown(database.close);
      final profile = Profile.normal().copyWith(
        useGlobalTemplate: true,
        scriptId: 123,
      );
      await database.profilesDao.putAll([profile.toCompanion()]);
      final restored = (await database.profilesDao.query().get()).single;
      expect(restored.useGlobalTemplate, isTrue);
      expect(restored.scriptId, 123);
      expect(restored.overwriteType, profile.overwriteType);
      expect(
        Profile.fromJson(jsonDecode(jsonEncode(restored))).useGlobalTemplate,
        isTrue,
      );
    },
  );

  test('schema 5 records migrate with the template disabled', () async {
    final raw = sql.sqlite3.openInMemory();
    addTearDown(raw.close);
    final seed = Database(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    await seed.profilesDao.putAll([Profile.normal().toCompanion()]);
    await seed.close();
    raw.execute('ALTER TABLE profiles DROP COLUMN use_global_template');
    raw.execute('PRAGMA user_version = 5');
    final database = Database(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    addTearDown(database.close);
    expect(
      (await database.profilesDao.query().get()).single.useGlobalTemplate,
      isFalse,
    );
    final columns = await database
        .customSelect('PRAGMA table_info(profiles)')
        .get();
    final column = columns.singleWhere(
      (row) => row.read<String>('name') == 'use_global_template',
    );
    expect(column.read<String>('dflt_value'), '0');
  });
}
