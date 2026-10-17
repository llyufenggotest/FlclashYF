import 'dart:async';

import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/manager/core_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/core/loaded_provider_recovery.dart';
import 'package:fl_clash/common/fixed.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real CoreController -> CoreHandlerInterface decoding/invoke boundary.
/// No network, native library or user configuration is involved.
class _GateCore extends CoreHandlerInterface {
  int providerReads = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected lifecycle call');

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    if (method == CoreMethod.getExternalProvider ||
        method == CoreMethod.getExternalProviders) {
      providerReads++;
      throw const CoreMethodException(
        code: 'profile_switching',
        message: 'controlled configuration admission gate',
      );
    }
    throw StateError('Unexpected fixture method: ${method.name}');
  }
}

class _ControlledCore extends CoreHandlerInterface {
  final setups = <Completer<String>>[];
  final reads = <Completer<List<ExternalProvider>>>[];
  Object? readError;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected call');

  @override
  Future<String> setupConfig(SetupParams params) {
    final c = Completer<String>();
    setups.add(c);
    return c.future;
  }

  @override
  Future<List<ExternalProvider>> getExternalProviders() {
    final c = Completer<List<ExternalProvider>>();
    reads.add(c);
    if (readError != null) c.completeError(readError!);
    return c.future;
  }

  @override
  Future<ExternalProvider?> getExternalProvider(String name) async {
    throw StateError('Loaded must use the shared full sync');
  }

  Completer<CoreLifecycleResult>? startGate;

  @override
  Future<CoreLifecycleResult> start() async => startGate == null
      ? const CoreLifecycleResult(
          revision: 1,
          outcome: CoreLifecycleOutcome.applied,
        )
      : await startGate!.future;
  @override
  Future<CoreLifecycleResult> restart() => start();
  @override
  Future<CoreLifecycleResult> stop() async => const CoreLifecycleResult(
    revision: 2,
    outcome: CoreLifecycleOutcome.applied,
  );
  @override
  Future<CoreLifecycleResult> close() => stop();
}

ExternalProvider _provider(String name) => ExternalProvider(
  name: name,
  type: 'Proxy',
  count: 1,
  vehicleType: 'HTTP',
  updateAt: DateTime(2026),
);
const _params = SetupParams(selectedMap: {}, testUrl: 'fixture');

Future<ProviderContainer> _mount(
  WidgetTester tester,
  CoreController controller,
) async {
  final container = ProviderContainer(
    overrides: [coreHandlerProvider.overrideWithValue(controller)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: CoreManager(child: SizedBox())),
    ),
  );
  // Establish the same provider owner before configuration begins.
  container.read(providersProvider);
  return container;
}

Future<void> _drain(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

void _storm() {
  for (var i = 0; i < 58; i++) {
    coreEventManager.sendEvent(
      CoreEvent(type: CoreEventType.loaded, data: 'fixture-$i'),
    );
  }
}

void main() {
  final callbackErrors = <Object>[];
  setUpAll(() {
    // Singleton subscription must not capture a previous widget's FakeAsync
    // zone. Its real dispatcher still runs inside this guarded callback zone.
    runZonedGuarded(() {
      coreEventManager.hasListeners;
    }, (error, stack) => callbackErrors.add(error));
  });
  setUp(callbackErrors.clear);
  tearDown(() => expect(callbackErrors, isEmpty));
  testWidgets(
    'configuration barrier merges 58 loaded and onUpdated full sync',
    (tester) async {
      final core = _ControlledCore();
      final controller = CoreController.scoped(core);
      final container = await _mount(tester, controller);
      final setup = controller.setupConfig(params: _params);
      _storm();
      await tester.pump();
      expect(
        core.reads,
        isEmpty,
        reason: 'no reads while real setup is pending',
      );
      core.setups.single.complete('');
      expect(await setup, '');
      await tester.pump();
      expect(core.reads, hasLength(1));
      // This is the existing SetupAction.onUpdated production entrypoint.
      final sync = container.read(providersProvider.notifier).syncProviders();
      core.reads.single.complete([_provider('ready')]);
      await sync;
      await tester.pump();
      expect(core.reads, hasLength(1));
      expect(container.read(providersProvider).single.name, 'ready');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('same-profile apply invalidates a late old read', (tester) async {
    final core = _ControlledCore();
    final controller = CoreController.scoped(core);
    final container = await _mount(tester, controller);
    final old = container.read(providersProvider.notifier).syncProviders();
    await tester.pump();
    final setup = controller.setupConfig(params: _params);
    core.setups.single.complete('');
    await setup;
    await tester.pump();
    expect(core.reads, hasLength(2));
    core.reads.last.complete([_provider('new')]);
    await tester.pump();
    core.reads.first.complete([_provider('old')]);
    await old;
    expect(container.read(providersProvider).single.name, 'new');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'overlap waits for all applies and only latest success publishes',
    (tester) async {
      final core = _ControlledCore();
      final controller = CoreController.scoped(core);
      final container = await _mount(tester, controller);
      final first = controller.setupConfig(params: _params);
      final second = controller.setupConfig(params: _params);
      _storm();
      await tester.pump();
      core.setups.last.complete('');
      await second;
      await tester.pump();
      expect(core.reads, isEmpty);
      core.setups.first.complete('old rejected');
      await first;
      await tester.pump();
      expect(core.reads, hasLength(1));
      core.reads.single.complete([_provider('latest')]);
      await tester.pump();
      expect(container.read(providersProvider).single.name, 'latest');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'nonempty setup result and preload failure retain old providers',
    (tester) async {
      final core = _ControlledCore();
      final controller = CoreController.scoped(core);
      final container = await _mount(tester, controller);
      container.read(providersProvider.notifier).value = [
        _provider('last-good'),
      ];
      final first = controller.setupConfig(params: _params);
      _storm();
      await tester.pump();
      core.setups.single.complete('rejected');
      expect(await first, 'rejected');
      await tester.pump();
      expect(core.reads, isEmpty);
      final preload = Completer<void>();
      final second = controller.setupConfig(
        params: _params,
        preloadInvoke: () => preload.future,
      );
      final failure = expectLater(second, throwsStateError);
      core.setups.last.complete('');
      await tester.pump();
      expect(controller.configuration.applying, isTrue);
      preload.completeError(StateError('private-error-details'));
      await failure;
      await tester.pump();
      expect(core.reads, isEmpty);
      expect(container.read(providersProvider).single.name, 'last-good');
      final refresh = container
          .read(providersProvider.notifier)
          .syncProviders(force: true);
      core.reads.single.complete([_provider('recovered')]);
      await refresh;
      expect(container.read(providersProvider).single.name, 'recovered');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('successful setup waits for asynchronous preload', (
    tester,
  ) async {
    final core = _ControlledCore();
    final controller = CoreController.scoped(core);
    final container = await _mount(tester, controller);
    final preload = Completer<void>();
    final setup = controller.setupConfig(
      params: _params,
      preloadInvoke: () => preload.future,
    );
    core.setups.single.complete('');
    await tester.pump();
    expect(core.reads, isEmpty);
    preload.complete();
    await setup;
    await tester.pump();
    expect(core.reads, hasLength(1));
    core.reads.single.complete([_provider('ready')]);
    await tester.pump();
    expect(container.read(providersProvider).single.name, 'ready');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stop retires held setup; start allows a new loaded read', (
    tester,
  ) async {
    final core = _ControlledCore();
    final controller = CoreController.scoped(core);
    final container = await _mount(tester, controller);
    final setup = controller.setupConfig(params: _params);
    _storm();
    await tester.pump();
    await controller.stop();
    core.setups.single.complete('');
    await setup;
    await tester.pump();
    expect(core.reads, isEmpty);
    await controller.start();
    _storm();
    await tester.pump();
    expect(core.reads, hasLength(1));
    core.reads.single.complete([_provider('new-session')]);
    await _drain(tester);
    expect(container.read(providersProvider).single.name, 'new-session');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dispose rejects late response and queued configuration finish', (
    tester,
  ) async {
    final core = _ControlledCore();
    final controller = CoreController.scoped(core);
    final container = await _mount(tester, controller);
    final sync = container.read(providersProvider.notifier).syncProviders();
    await tester.pump();
    final setup = controller.setupConfig(params: _params);
    await tester.pumpWidget(const SizedBox());
    core.reads.single.complete([_provider('late')]);
    await sync;
    core.setups.single.complete('');
    await setup;
    await tester.pump();
    expect(container.read(providersProvider), isEmpty);
    expect(core.reads, hasLength(1));
  });

  testWidgets('native gate preceding Dart begin recovers on explicit sync', (
    tester,
  ) async {
    final core = _ControlledCore()
      ..readError = const CoreMethodException(
        code: 'profile_switching',
        message: 'private',
      );
    final controller = CoreController.scoped(core);
    final container = await _mount(tester, controller);
    _storm();
    await _drain(tester);
    expect(core.reads, hasLength(1));
    core.readError = null;
    final refresh = container.read(providersProvider.notifier).syncProviders();
    core.reads.last.complete([_provider('active-refresh')]);
    await refresh;
    expect(container.read(providersProvider).single.name, 'active-refresh');
    await tester.pumpWidget(const SizedBox());
  });

  test('pause and resume cannot revive an abandoned read', () async {
    final core = _ControlledCore();
    final published = <List<ExternalProvider>>[];
    final recovery = LoadedProviderRecovery(
      core: CoreController.scoped(core),
      context: () => 1,
      publish: published.add,
      updated: () {},
    );
    addTearDown(recovery.dispose);
    final abandoned = recovery.sync();
    recovery.pause();
    recovery.resume();
    final fresh = recovery.sync();
    core.reads.last.complete([_provider('fresh')]);
    await fresh;
    core.reads.first.complete([_provider('abandoned')]);
    await abandoned;
    expect(published.map((p) => p.single.name), ['fresh']);
  });

  test('unexpected read failure reports safely and refresh recovers', () async {
    final core = _ControlledCore()..readError = StateError('secret URL token');
    final errors = <Object>[];
    final published = <List<ExternalProvider>>[];
    final recovery = LoadedProviderRecovery(
      core: CoreController.scoped(core),
      context: () => 1,
      publish: published.add,
      updated: () {},
      reportError: errors.add,
    );
    addTearDown(recovery.dispose);
    await recovery.sync();
    expect(errors, hasLength(1));
    expect(published, isEmpty);
    core.readError = null;
    final refresh = recovery.sync();
    core.reads.last.complete([_provider('recovered')]);
    await refresh;
    expect(published.single.single.name, 'recovered');
    final logs = <String>[];
    await runZoned(
      () async {
        LoadedProviderRecovery.safeReportError(StateError('secret URL token'));
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => logs.add(line),
      ),
    );
    expect(logs.join(), contains('Provider refresh failed'));
    expect(logs.join(), isNot(contains('secret')));
  });

  testWidgets('restart and close reject held reads from previous session', (
    tester,
  ) async {
    final core = _ControlledCore();
    final controller = CoreController.scoped(core);
    final container = await _mount(tester, controller);
    final old = container.read(providersProvider.notifier).syncProviders();
    await controller.restart();
    core.reads.single.complete([_provider('stale')]);
    await old;
    expect(container.read(providersProvider), isEmpty);
    final current = container.read(providersProvider.notifier).syncProviders();
    await controller.close();
    core.reads.last.complete([_provider('closed')]);
    await current;
    expect(container.read(providersProvider), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  test('late start cannot reactivate a stopped session', () async {
    final core = _ControlledCore()
      ..startGate = Completer<CoreLifecycleResult>();
    final controller = CoreController.scoped(core);
    final start = controller.start();
    await controller.stop();
    core.startGate!.complete(
      const CoreLifecycleResult(
        revision: 1,
        outcome: CoreLifecycleOutcome.applied,
      ),
    );
    await start;
    expect(controller.configuration.sessionActive, isFalse);
  });

  test('scoped controllers keep configuration ownership isolated', () async {
    final a = CoreController.scoped(_ControlledCore());
    final b = CoreController.scoped(_ControlledCore());
    final token = b.configuration.token;
    await a.stop();
    expect(b.configuration.sessionActive, isTrue);
    expect(b.configuration.token, same(token));
  });

  testWidgets('controller provider replacement rejects old owner response', (
    tester,
  ) async {
    final oldCore = _ControlledCore();
    final newCore = _ControlledCore();
    final container = await _mount(tester, CoreController.scoped(oldCore));
    final old = container.read(providersProvider.notifier).syncProviders();
    container.updateOverrides([
      coreHandlerProvider.overrideWithValue(CoreController.scoped(newCore)),
    ]);
    await tester.pump();
    final current = container.read(providersProvider.notifier).syncProviders();
    newCore.reads.single.complete([_provider('new-owner')]);
    await current;
    oldCore.reads.single.complete([_provider('old-owner')]);
    await old;
    expect(container.read(providersProvider).single.name, 'new-owner');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unexpected errors in real manager are logged without escaping', (
    tester,
  ) async {
    final core = _ControlledCore()..readError = StateError('secret URL token');
    final container = await _mount(tester, CoreController.scoped(core));
    _storm();
    await _drain(tester);
    expect(callbackErrors, isEmpty);
    expect(core.reads, hasLength(1));
    expect(container.read(providersProvider), isEmpty);
    core.readError = null;
    final refresh = container.read(providersProvider.notifier).syncProviders();
    core.reads.last.complete([_provider('recovered')]);
    await refresh;
    expect(container.read(providersProvider).single.name, 'recovered');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('setup exception holds barrier until preload finishes', (
    tester,
  ) async {
    final core = _ControlledCore();
    final controller = CoreController.scoped(core);
    final container = await _mount(tester, controller);
    container.read(providersProvider.notifier).value = [_provider('last-good')];
    final preload = Completer<void>();
    final setup = controller.setupConfig(
      params: _params,
      preloadInvoke: () => preload.future,
    );
    final failure = expectLater(setup, throwsStateError);
    core.setups.single.completeError(StateError('private transport'));
    await tester.pump();
    expect(controller.configuration.applying, isTrue);
    _storm();
    await tester.pump();
    expect(core.reads, isEmpty);
    preload.complete();
    await failure;
    expect(controller.configuration.applying, isFalse);
    expect(controller.configuration.succeeded, isFalse);
    expect(core.reads, isEmpty);
    expect(container.read(providersProvider).single.name, 'last-good');
    await tester.pumpWidget(const SizedBox());
  });

  test('configuration begun during start keeps session ownership', () async {
    final core = _ControlledCore()
      ..startGate = Completer<CoreLifecycleResult>();
    final controller = CoreController.scoped(core);
    final start = controller.start();
    final setup = controller.setupConfig(params: _params);
    core.setups.single.complete('');
    await setup;
    expect(controller.configuration.sessionActive, isFalse);
    core.startGate!.complete(
      const CoreLifecycleResult(
        revision: 1,
        outcome: CoreLifecycleOutcome.applied,
      ),
    );
    await start;
    expect(controller.configuration.sessionActive, isTrue);
    expect(controller.configuration.succeeded, isTrue);
  });

  testWidgets(
    'production bootstrap override initializes recovery and keeps restored providers',
    (tester) async {
      final core = _ControlledCore();
      final controller = CoreController.scoped(core);
      final container = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(controller),
          ...buildAppStateOverrides(
            AppState(
              providers: [_provider('restored')],
              viewSize: Size.zero,
              brightness: Brightness.dark,
              requests: FixedList(10),
              version: 1,
              logs: FixedList(10),
              traffics: FixedList(10),
              totalTraffic: const Traffic(),
              systemUiOverlayStyle: SystemUiOverlayStyle.dark,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: CoreManager(child: SizedBox())),
        ),
      );
      expect(container.read(providersProvider).single.name, 'restored');
      final setup = controller.setupConfig(params: _params);
      _storm();
      await tester.pump();
      expect(core.reads, isEmpty);
      core.setups.single.complete('');
      await setup;
      await tester.pump();
      core.reads.single.complete([_provider('ready')]);
      await tester.pump();
      expect(container.read(providersProvider).single.name, 'ready');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('58 loaded events do not escape the production callback zone', (
    tester,
  ) async {
    final uncaught = callbackErrors;
    // The real singleton subscription was constructed in setUpAll's guarded
    // zone, independent of any widget FakeAsync lifetime.
    final core = _GateCore();
    final container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: CoreManager(child: SizedBox())),
      ),
    );
    for (var i = 0; i < 58; i++) {
      coreEventManager.sendEvent(
        CoreEvent(type: CoreEventType.loaded, data: 'fixture-$i'),
      );
    }
    await tester.pump();
    await tester.pump();
    // Retain measured baseline even when the acceptance assertion fails.
    // ignore: avoid_print
    print(
      'loaded baseline: reads=${core.providerReads}, '
      'uncaught=${uncaught.length}',
    );
    await tester.pumpWidget(const SizedBox());
    expect(
      uncaught,
      isEmpty,
      reason: 'expected profile_switching must not escape CoreManager',
    );
    expect(
      core.providerReads,
      lessThanOrEqualTo(1),
      reason: 'loaded callbacks must coalesce before issuing provider RPC',
    );
  });
}
