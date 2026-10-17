import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

/// One provider-list owner. All reads (loaded + SetupAction + explicit refresh)
/// share this lane; late responses never publish into another configuration.
class LoadedProviderRecovery {
  final CoreController core;
  final Object? Function() context;
  final void Function(List<ExternalProvider>) publish;
  void Function() updated;
  final void Function(Object) reportError;
  final Set<String> _names = {};
  bool _disposed = false;
  bool _listening = true;
  bool _unavailable = false;
  Object? _flightToken;
  Object? _flightContext;
  Future<void>? _flight;
  Object? _setupSyncCredit;
  Object? _setupSyncContext;
  Future<void>? _setupSync;

  LoadedProviderRecovery({
    required this.core,
    required this.context,
    required this.publish,
    required this.updated,
    void Function(Object)? reportError,
  }) : reportError = reportError ?? safeReportError {
    core.configuration.addListener(_configurationChanged);
  }

  static void safeReportError(Object error) {
    // Never print provider names, transport messages, URLs or exception details.
    commonPrint.log(
      'Provider refresh failed (${error.runtimeType})',
      logLevel: LogLevel.error,
    );
  }

  void _configurationChanged() {
    final state = core.configuration;
    if (!state.sessionActive || state.applying) {
      _unavailable = false;
      _flight = null;
      _setupSyncCredit = null;
      _setupSync = null;
      return;
    }
    if (state.succeeded && _listening) {
      _unavailable = false;
      // Finish is authoritative even if native loaded preceded Dart begin or
      // arrived without any names. A failed apply never starts a full sync.
      _setupSyncCredit = state.token;
      _setupSyncContext = context();
      _setupSync = _read();
    }
  }

  void resume() => _listening = true;

  void pause() {
    _listening = false;
    _names.clear();
    _flight = null;
    _flightToken = null;
    _setupSyncCredit = null;
    _setupSync = null;
  }

  void loaded(String name) {
    if (_disposed || !_listening || !core.configuration.sessionActive) return;
    _names.add(name);
    if (core.configuration.applying || _unavailable) return;
    unawaited(_read());
  }

  Future<void> sync({bool force = false}) {
    if (_disposed || !core.configuration.sessionActive) return Future.value();
    if (core.configuration.applying) {
      _names.add('');
      return Future.value();
    }
    if (!force &&
        identical(_setupSyncCredit, core.configuration.token) &&
        _setupSyncContext == context()) {
      _setupSyncCredit = null;
      return _setupSync ?? Future.value();
    }
    // Explicit sync/refresh is a recovery trigger when native gate timing did
    // not match Dart begin. No hidden infinite retry or readiness timer.
    _unavailable = false;
    return _read();
  }

  Future<void> _read() {
    final token = core.configuration.token;
    final ownerContext = context();
    if (_flight != null &&
        identical(token, _flightToken) &&
        ownerContext == _flightContext) {
      return _flight!;
    }
    _flightToken = token;
    _flightContext = ownerContext;
    final completion = Completer<void>();
    _flight = completion.future;
    // Install the in-flight identity before starting an async or sync handler.
    unawaited(() async {
      try {
        final providers = await core.getExternalProviders();
        if (_owns(token, ownerContext) &&
            identical(_flight, completion.future)) {
          _names.clear();
          publish(providers);
          updated();
        }
      } catch (error) {
        if (_owns(token, ownerContext) &&
            identical(_flight, completion.future)) {
          _names.clear();
          _setupSyncCredit = null;
          if (isCoreUnavailableError(error)) {
            _unavailable = true;
          } else {
            reportError(error);
          }
        }
      } finally {
        if (identical(_flight, completion.future)) _flight = null;
        completion.complete();
      }
    }());
    return completion.future;
  }

  bool _owns(Object token, Object? ownerContext) =>
      !_disposed &&
      identical(token, _flightToken) &&
      identical(token, core.configuration.token) &&
      !core.configuration.applying &&
      core.configuration.sessionActive &&
      context() == ownerContext;

  void dispose() {
    _disposed = true;
    pause();
    core.configuration.removeListener(_configurationChanged);
  }
}
