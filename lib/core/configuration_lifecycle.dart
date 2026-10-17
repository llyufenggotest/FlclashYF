import 'package:flutter/foundation.dart';

/// Per-controller ownership. Tokens are identities, never profile IDs or hashes:
/// even a forced apply of identical YAML invalidates outstanding reads.
class CoreConfigurationLifecycle extends ChangeNotifier {
  Object token = Object();
  Object _session = Object();
  bool sessionActive = true;
  bool applying = false;
  bool succeeded = false;
  int generation = 0;
  final Set<Object> _pending = {};
  Object? _latest;

  Object begin() {
    final operation = Object();
    _pending.add(operation);
    _latest = operation;
    token = Object();
    generation++;
    applying = true;
    succeeded = false;
    notifyListeners();
    return operation;
  }

  void finish(Object operation, bool success) {
    if (!_pending.remove(operation)) return;
    if (identical(_latest, operation)) succeeded = success;
    applying = _pending.isNotEmpty;
    notifyListeners();
  }

  Object retire() {
    _pending.clear();
    _latest = null;
    token = Object();
    _session = Object();
    sessionActive = false;
    applying = false;
    succeeded = false;
    notifyListeners();
    return _session;
  }

  void started(Object epoch) {
    if (!identical(epoch, _session)) return;
    sessionActive = true;
    notifyListeners();
  }
}
