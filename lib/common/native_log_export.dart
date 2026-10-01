import 'dart:convert';
import 'dart:io';

class NativeLogExport {
  final File nativeFile;

  NativeLogExport(this.nativeFile);

  File get _cutoffFile =>
      File('${nativeFile.parent.path}/logs-cleared-at.json');

  Future<DateTime?> _readCutoff() async {
    final file = _cutoffFile;
    if (!await file.exists()) return null;
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
    final cutoff = await _readCutoff();
    final buffer = StringBuffer();
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
              : '(not recorded)',
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

  String _afterCutoff(String text, DateTime? cutoff) {
    if (cutoff == null) return text;
    final buffer = StringBuffer();
    var include = false;
    for (final line in const LineSplitter().convert(text)) {
      final timestamp = _timestamp(line);
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
