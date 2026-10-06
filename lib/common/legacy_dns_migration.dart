import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/common/system.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> restoreLegacySystemDns({
  SharedPreferences? store,
  ProcessRunner? runProcess,
  bool? isMacOS,
}) async {
  if (!(isMacOS ?? Platform.isMacOS)) return;
  try {
    final prefs = store ?? await preferences.sharedPreferencesCompleter.future;
    const key = 'system_dns_record';
    final raw = prefs?.getString(key);
    if (raw == null) return;
    final record = jsonDecode(raw);
    if (record is! Map) return;
    final service = record['service'];
    final servers = record['servers'];
    if (service is! String ||
        service.isEmpty ||
        servers is! List ||
        servers.any((value) => value is! String)) {
      return;
    }
    final original = servers.cast<String>();
    final run = runProcess ?? Process.run;
    final current = await run('networksetup', ['-getdnsservers', service]);
    if (current.exitCode != 0) return;
    final output = current.stdout.toString().trim();
    final actual = output.startsWith("There aren't any DNS Servers set on")
        ? <String>[]
        : output.split('\n').map((value) => value.trim()).toList();
    final patched = [
      ...original,
      if (!original.contains('223.5.5.5')) '223.5.5.5',
    ];
    bool same(List<String> a, List<String> b) =>
        a.length == b.length &&
        List.generate(
          a.length,
          (index) => a[index] == b[index],
        ).every((v) => v);
    if (same(actual, original)) {
      await prefs?.remove(key);
      return;
    }
    // Restore only the exact legacy patch, preserving later user DNS edits.
    if (!same(actual, patched)) return;
    final result = await run('networksetup', [
      '-setdnsservers',
      service,
      if (original.isEmpty) 'Empty' else ...original,
    ]);
    if (result.exitCode != 0) return;
    final verified = await run('networksetup', ['-getdnsservers', service]);
    if (verified.exitCode != 0) return;
    final value = verified.stdout.toString().trim();
    final restored = value.startsWith("There aren't any DNS Servers set on")
        ? <String>[]
        : value.split('\n').map((entry) => entry.trim()).toList();
    if (same(restored, original)) await prefs?.remove(key);
  } catch (_) {
    // Retain the record so a later launch can retry without blocking startup.
  }
}
