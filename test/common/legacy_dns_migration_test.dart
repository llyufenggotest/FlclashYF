import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/legacy_dns_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = 'system_dns_record';
  late SharedPreferences store;
  late List<List<String>> calls;
  var writeExit = 0;
  var current = '223.5.5.5';

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode({'service': 'Wi-Fi', 'servers': <String>[]}),
    });
    store = await SharedPreferences.getInstance();
    calls = [];
    writeExit = 0;
    current = '223.5.5.5';
  });

  Future<void> migrate() => restoreLegacySystemDns(
    store: store,
    isMacOS: true,
    runProcess: (executable, args) async {
      expect(executable, 'networksetup');
      calls.add(args);
      if (args.first == '-setdnsservers' && writeExit == 0) {
        current = args.last == 'Empty'
            ? "There aren't any DNS Servers set on Wi-Fi."
            : args.skip(2).join('\n');
      }
      return ProcessResult(
        1,
        args.first == '-getdnsservers' ? 0 : writeExit,
        args.first == '-getdnsservers' ? current : '',
        '',
      );
    },
  );

  test('restores DHCP and removes record only after success', () async {
    await migrate();
    expect(calls[calls.length - 2], ['-setdnsservers', 'Wi-Fi', 'Empty']);
    expect(store.containsKey(key), isFalse);
  });

  test('failed restore retains record and can retry', () async {
    writeExit = 1;
    await migrate();
    expect(store.containsKey(key), isTrue);
    writeExit = 0;
    await migrate();
    expect(store.containsKey(key), isFalse);
  });

  test('later manual DNS edits are never overwritten', () async {
    current = '10.0.0.1';
    await migrate();
    expect(calls.length, 1);
    expect(store.containsKey(key), isTrue);
  });

  test('no record performs no system operation', () async {
    await store.remove(key);
    await migrate();
    expect(calls, isEmpty);
  });

  test('already restored DNS clears stale record without a write', () async {
    current = "There aren't any DNS Servers set on Wi-Fi.";
    await migrate();
    expect(calls.length, 1);
    expect(store.containsKey(key), isFalse);
  });

  test('restores original ordered static servers', () async {
    await store.setString(
      key,
      jsonEncode({
        'service': 'Wi-Fi',
        'servers': ['10.0.0.2'],
      }),
    );
    current = '10.0.0.2\n223.5.5.5';
    await migrate();
    expect(calls[calls.length - 2], ['-setdnsservers', 'Wi-Fi', '10.0.0.2']);
  });
}
