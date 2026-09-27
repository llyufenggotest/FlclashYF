import 'package:fl_clash/models/models.dart';

import 'constant.dart';
import 'fixed.dart';

class LogBuffer extends FixedList<Log> {
  final List<Log> _entries;
  @override
  final int revision;

  factory LogBuffer({int revision = 0}) => LogBuffer._([], revision);

  LogBuffer._(this._entries, this.revision)
    : super(maxLogsLength, list: _entries);

  @override
  bool operator ==(Object other) =>
      other is LogBuffer &&
      identical(_entries, other._entries) &&
      revision == other.revision;

  @override
  int get hashCode => Object.hash(identityHashCode(_entries), revision);

  @override
  FixedList<Log> append(Log item) {
    add(item);
    return LogBuffer._(_entries, revision + 1);
  }
}
