import 'dart:async';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/core.dart';
import 'package:flutter/foundation.dart';

import 'desktop/helper_client.dart';
import 'desktop/launcher.dart';
import 'desktop/lifecycle.dart';
import 'desktop/model.dart';
import 'desktop/rpc_client.dart';
import 'desktop/transport.dart';
import 'event.dart';
import 'interface.dart';
import 'method.dart';

class CoreService extends CoreHandlerInterface {
  static CoreService? _instance;

  final DesktopCoreLifecycleController _lifecycle;
  final CoreRpcChannel _rpcClient;
  late final StreamSubscription<DesktopCoreFailure> _crashSubscription;
  Future<CoreLifecycleResult>? _closeOperation;

  factory CoreService() {
    return _instance ??= CoreService._create();
  }

  @visibleForTesting
  static void resetInstance() {
    final instance = _instance;
    _instance = null;
    if (instance != null) {
      unawaited(instance.close());
    }
  }

  factory CoreService._create() {
    final address = system.isWindows ? windowsPipeName : unixSocketPath;
    final directLauncher = DirectCoreLauncher();

    final lifecycle = DesktopCoreLifecycle(
      transportFactory: () => IPCCoreTransport(address: address),
      launcherResolver: HelperLauncherResolver(
        hasHelper: system.hasHelperService,
        directLauncher: directLauncher,
        helperLauncher: HelperLauncher(helperClient),
        helperReady: () => helperClient.readiness(),
      ),
      verifyPeerPid: system.isWindows,
    );
    return CoreService._(
      lifecycle: lifecycle,
      rpcClient: CoreRpcClient(lifecycle.transport),
    );
  }

  @visibleForTesting
  factory CoreService.forTesting({
    required DesktopCoreLifecycleController lifecycle,
    required CoreRpcChannel rpcClient,
  }) {
    final service = CoreService._(lifecycle: lifecycle, rpcClient: rpcClient);
    _instance = service;
    return service;
  }

  CoreService._({
    required DesktopCoreLifecycleController lifecycle,
    required CoreRpcChannel rpcClient,
  }) : _lifecycle = lifecycle,
       _rpcClient = rpcClient {
    _crashSubscription = _lifecycle.crashEvents.listen((failure) {
      coreEventManager.sendEvent(
        CoreEvent(
          type: CoreEventType.crash,
          data: failure.cause?.toString() ?? 'core done',
        ),
      );
    });
  }

  @override
  Future<CoreLifecycleResult> start() => _lifecycle.start();

  @override
  Future<CoreLifecycleResult> restart() => _lifecycle.restart();

  @override
  Future<CoreLifecycleResult> stop() => _lifecycle.stop();

  @override
  Future<CoreLifecycleResult> close() {
    return _closeOperation ??= _close();
  }

  Future<CoreLifecycleResult> _close() async {
    _rpcClient.beginShutdown();
    try {
      return await _lifecycle.close();
    } finally {
      await _rpcClient.close();
      await _crashSubscription.cancel();
    }
  }

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) {
    return _rpcClient.invoke<T>(
      method: method,
      arguments: arguments,
      timeout: timeout,
    );
  }
}

final coreService = system.isDesktop ? CoreService() : null;
