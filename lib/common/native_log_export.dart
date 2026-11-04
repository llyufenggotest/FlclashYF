import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

class NativeLogExport {
  final File nativeFile;

  final Future<String?> Function()? runnerDiagnosticReader;

  NativeLogExport(this.nativeFile, {this.runnerDiagnosticReader});

  File get _cutoffFile =>
      File('${nativeFile.parent.path}/logs-cleared-at.json');

  Future<DateTime?> _readCutoff() async {
    final file = _cutoffFile;
    if (await FileSystemEntity.type(file.path) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    final metadata = jsonDecode(await file.readAsString());
    if (metadata is! Map || metadata['cutoff'] is! String) {
      throw const FormatException('Invalid native log cutoff metadata');
    }
    return DateTime.parse(metadata['cutoff'] as String);
  }

  Future<void> clear(DateTime cutoff) async {
    final file = _cutoffFile;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'cutoff': cutoff.toUtc().toIso8601String()}),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<String> read() async {
    final buffer = StringBuffer();
    String? runnerDiagnostics;
    // Collect Runner-local proof before touching the suspect shared path, but
    // defer exporting event history until the persisted cutoff is known.
    if (Platform.isIOS || runnerDiagnosticReader != null) {
      try {
        const channel = MethodChannel('cc.llyufeng.flclash.dev/service');
        runnerDiagnostics = runnerDiagnosticReader != null
            ? await runnerDiagnosticReader!()
            : await channel.invokeMethod<String>('exportIPadDiagnostics');
      } on PlatformException {
        buffer.writeln('iPadDiagnostic-v1 native_channel=unavailable');
      } on MissingPluginException {
        buffer.writeln('iPadDiagnostic-v1 native_channel=unavailable');
      }
    }
    DateTime? cutoff;
    var withholdHistory = false;
    try {
      cutoff = await _readCutoff();
    } on FileSystemException {
      withholdHistory = true;
      buffer.writeln('shared_cutoff=unavailable shared_history=withheld');
    } on FormatException {
      if (!Platform.isIOS && runnerDiagnosticReader == null) rethrow;
      withholdHistory = true;
      buffer.writeln('shared_cutoff=invalid shared_history=withheld');
    }
    if (runnerDiagnostics != null) {
      buffer.writeln(
        _runnerAfterCutoff(
          runnerDiagnostics,
          cutoff,
          withholdHistory: withholdHistory,
        ),
      );
    }
    if (withholdHistory) return buffer.toString();
    for (final (file, title) in [
      (nativeFile, 'iOS NECore native diagnostics'),
      for (final name in ['ios-switch-Runner.log', 'ios-switch-NECore.log'])
        (File('${nativeFile.parent.path}/$name'), name),
    ]) {
      buffer
        ..writeln()
        ..writeln('===== $title =====');
      try {
        buffer.writeln(
          await file.exists()
              ? _afterCutoff(await file.readAsString(), cutoff)
              : '(not recorded) source=unavailable_or_absent',
        );
      } on FileSystemException {
        buffer.writeln('(diagnostic file could not be read)');
      }
    }
    return buffer.toString();
  }

  Future<List<String>> readEntries({int maxLines = 200}) async {
    final cutoff = await _readCutoff();
    final entries = <({DateTime timestamp, String line})>[];
    for (final source in [
      nativeFile,
      for (final name in ['ios-switch-Runner.log', 'ios-switch-NECore.log'])
        File('${nativeFile.parent.path}/$name'),
    ]) {
      if (!await source.exists()) continue;
      for (final line in const LineSplitter().convert(
        await source.readAsString(),
      )) {
        final timestamp = _timestamp(line);
        if (timestamp == null ||
            (cutoff != null && !timestamp.isAfter(cutoff))) {
          continue;
        }
        entries.add((timestamp: timestamp, line: line));
      }
    }
    entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final start = entries.length > maxLines ? entries.length - maxLines : 0;
    return entries.skip(start).map((entry) => entry.line).toList();
  }

  String _runnerAfterCutoff(
    String text,
    DateTime? cutoff, {
    required bool withholdHistory,
  }) {
    final buffer = StringBuffer();
    for (final line in const LineSplitter().convert(text)) {
      // Channel output mixes current capability headers with independent JSON
      // rows from local, pinned and NE sources. Never carry row inclusion state
      // across these boundaries or treat an invalid row as a continuation.
      if (_isRunnerHeader(line)) {
        buffer.writeln(line);
      } else if (!withholdHistory && line.trimLeft().startsWith('{')) {
        final timestamp = _timestamp(line.trimLeft());
        if (timestamp != null &&
            (cutoff == null || timestamp.isAfter(cutoff))) {
          buffer.writeln(line);
        }
      }
    }
    return buffer.toString();
  }

  bool _isRunnerHeader(String line) {
    const fixed = {
      'iPadDiagnostic-v1',
      '===== iPadDiagnostic-v1 =====',
      '===== pinned startup window =====',
      '===== NE shared diagnostic (NE private fallback is not app-readable) =====',
      'container_identity=not_proved signing_entitlements=unavailable capability_scope=observed_only',
      'no_provider_evidence=entry_unknown_not_proof_of_no_launch',
    };
    if (fixed.contains(line)) return true;
    if (RegExp(
      r'^runnerLocal=(readable|unavailable|unreadable_or_absent|unreadable) sharedSource=(readable|unavailable|unreadable_or_absent|unreadable) dropped=[0-9]+$',
    ).hasMatch(line)) {
      return true;
    }
    return RegExp(
      r'^schema=iPadDiagnostic-v1 source_base=[a-f0-9]{40} image_uuid=(unavailable|[A-Fa-f0-9-]{36}) os=[0-9]+\.[0-9]+\.[0-9]+ device_class=(ipad|other|mac_gate) bundle_relation=(true|false) embedded_profile=(true|false) signature_resources=(true|false) signing_groups_count=unavailable signing_vpn_entitlement=unavailable$',
    ).hasMatch(line);
  }

  String _afterCutoff(String text, DateTime? cutoff) {
    if (cutoff == null) return text;
    final buffer = StringBuffer();
    var include = false;
    for (final line in const LineSplitter().convert(text)) {
      final isRow = line.trimLeft().startsWith('{');
      final timestamp = _timestamp(line.trimLeft());
      if (isRow) {
        // JSONL has no continuations, including malformed/missing timestamps.
        include = false;
        if (timestamp != null && timestamp.isAfter(cutoff)) {
          buffer.writeln(line);
        }
        continue;
      }
      if (timestamp != null) {
        include = timestamp.isAfter(cutoff);
      }
      if (include) buffer.writeln(line);
    }
    return buffer.toString();
  }

  DateTime? _timestamp(String line) {
    if (line.startsWith('{')) {
      try {
        final entry = jsonDecode(line);
        if (entry is Map && entry['timestamp'] is String) {
          return DateTime.tryParse(entry['timestamp'] as String);
        }
      } on FormatException {
        return null;
      }
      return null;
    }
    return DateTime.tryParse(line.split(' ').first);
  }
}
