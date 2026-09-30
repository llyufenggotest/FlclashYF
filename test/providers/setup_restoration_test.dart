import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:riverpod/riverpod.dart';

class _Core extends Fake implements CoreHandlerInterface {
  final calls = <String>[];
  bool failProviders = false;

  @override
  Future<String> setupConfig(SetupParams params) async {
    calls.add('setup');
    return '';
  }

  @override
  Future<bool> startListener() async {
    calls.add('start');
    return true;
  }

  @override
  Future<bool> stopListener() async {
    calls.add('stop');
    return true;
  }

  @override
  Future<void> resetTraffic() async {}

  @override
  Future<ProxiesData> getProxies() async {
    calls.add('groups');
    return const ProxiesData(
      all: ['Proxy'],
      proxies: {
        'Proxy': {
          'name': 'Proxy',
          'type': 'Selector',
          'all': ['DIRECT'],
        },
        'DIRECT': {'name': 'DIRECT', 'type': 'Direct'},
      },
    );
  }

  @override
  Future<List<ExternalProvider>> getExternalProviders() async {
    calls.add('providers');
    if (failProviders) throw StateError('temporarily unavailable');
    return [
      ExternalProvider(
        name: 'subscription',
        type: 'Proxy',
        count: 1,
        vehicleType: 'HTTP',
        updateAt: DateTime.utc(2026),
      ),
    ];
  }
}

class _Setup extends SetupAction {
  bool restoreRunningService = true;
  DateTime? runtime = DateTime.now().subtract(const Duration(minutes: 2));
  Completer<DateTime?>? runtimeGate;

  @override
  bool get shouldRestoreServiceRunTime => true;

  @override
  bool get shouldRestoreRunningService => restoreRunningService;

  @override
  Future<DateTime?> readServiceRunTime() async =>
      runtimeGate == null ? runtime : await runtimeGate!.future;
}

class _Common extends CommonAction {
  @override
  Future<void> updateTraffic() async {}
}

class _Paths extends PathProviderPlatform {
  final String root;
  _Paths(this.root);

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;
}

const _setupState = SetupState(
  profileId: null,
  profileLastUpdateDate: null,
  overwriteType: OverwriteType.standard,
  rules: [],
  proxyGroups: [],
  addedRules: [],
  script: null,
  overrideDns: false,
  dns: Dns(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;
  late ProviderContainer container;
  late _Core core;
  late _Setup action;
  late String? originalMd5;

  setUpAll(() async {
    originalPaths = PathProviderPlatform.instance;
    directory = Directory.systemTemp.createTempSync('setup_restoration');
    PathProviderPlatform.instance = _Paths(directory.path);
    await AppLocalizations.load(const Locale('en'));
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  setUp(() {
    originalMd5 = globalState.lastConfigMd5;
    globalState.lastConfigMd5 = null;
    globalState.needInitStatus = true;
    core = _Core();
    action = _Setup();
    container = ProviderContainer(
      overrides: [
        currentProfileProvider.overrideWithValue(null),
        currentProfileIdProvider.overrideWithBuild((_, _) => null),
        setupStateProvider.overrideWith((_, _) => _setupState),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        setupActionProvider.overrideWith(() => action),
        commonActionProvider.overrideWith(_Common.new),
      ],
    );
    globalState.container = container;
    container.read(setupActionProvider.notifier);
  });

  tearDown(() {
    debouncer.cancel(FunctionTag.applyProfile);
    container.dispose();
    globalState.lastConfigMd5 = originalMd5;
    globalState.needInitStatus = true;
  });

  test(
    'hydration failure does not fail bootstrap or stop the live tunnel',
    () async {
      core.failProviders = true;

      await expectLater(action.initStatus(), completes);

      expect(core.calls, ['groups', 'providers']);
      expect(container.read(runTimeProvider), isNotNull);
      expect(globalState.needInitStatus, isFalse);
    },
  );

  test('unchanged config still hydrates groups and providers', () async {
    globalState.lastConfigMd5 = '';

    expect(await action.applyProfile(), isTrue);

    expect(core.calls, ['groups', 'providers']);
    expect(container.read(groupsProvider).single.name, 'Proxy');
    expect(container.read(providersProvider).single.name, 'subscription');
  });

  test(
    'cold iOS autoRun still applies config and starts the listener',
    () async {
      action.runtime = null;
      container.read(appSettingProvider.notifier).value = const AppSettingProps(
        autoRun: true,
      );

      await action.initStatus();

      expect(core.calls, ['setup', 'start', 'groups', 'providers']);
      expect(container.read(runTimeProvider), isNotNull);
    },
  );

  test('stopped iOS without autoRun applies config without starting', () async {
    action.runtime = null;

    await action.initStatus();

    expect(core.calls, ['setup', 'groups', 'providers']);
    expect(container.read(runTimeProvider), isNull);
  });

  test('Android restoration keeps its existing full initialization', () async {
    action.restoreRunningService = false;

    await action.initStatus();

    expect(core.calls, ['setup', 'start', 'groups', 'providers']);
  });

  test('future service timestamp is not treated as a live tunnel', () async {
    action.runtime = DateTime.now().add(const Duration(days: 1));

    await action.initStatus();

    expect(core.calls, ['setup', 'groups', 'providers']);
    expect(container.read(runTimeProvider), isNull);
  });

  test('waits for the native running-state query before hydration', () async {
    action.runtimeGate = Completer<DateTime?>();
    final restoration = action.initStatus();
    await Future<void>.delayed(Duration.zero);

    expect(core.calls, isEmpty);
    expect(container.read(runTimeProvider), isNull);
    action.runtimeGate!.complete(action.runtime);
    await restoration;

    expect(core.calls, ['groups', 'providers']);
  });

  test(
    'foreground resume rehydrates a live tunnel without applying config',
    () async {
      container.read(groupsProvider.notifier).value = [];
      container.read(providersProvider.notifier).value = [];

      await action.restoreForegroundState();

      expect(core.calls, ['groups', 'providers']);
      expect(container.read(groupsProvider).single.name, 'Proxy');
      expect(container.read(providersProvider).single.name, 'subscription');
      expect(container.read(runTimeProvider), isNotNull);
    },
  );

  test('foreground resume does nothing when the tunnel is stopped', () async {
    action.runtime = null;

    await action.restoreForegroundState();

    expect(core.calls, isEmpty);
    expect(container.read(runTimeProvider), isNull);
  });

  test('foreground resume keeps an already hydrated proxy page', () async {
    container.read(groupsProvider.notifier).value = const [
      Group(name: 'Existing', type: GroupType.Selector),
    ];

    await action.restoreForegroundState();

    expect(core.calls, isEmpty);
    expect(container.read(groupsProvider).single.name, 'Existing');
  });

  test('completed restoration is not repeated', () async {
    await action.initStatus();
    core.calls.clear();

    await action.initStatus();

    expect(core.calls, isEmpty);
  });

  test('explicit forced apply still pushes config after restoration', () async {
    await action.initStatus();
    core.calls.clear();
    globalState.lastConfigMd5 = '';

    expect(await action.applyProfile(force: true), isTrue);

    expect(core.calls, ['setup', 'groups', 'providers']);
  });

  test('unchanged config hydration failure does not reapply or stop', () async {
    globalState.lastConfigMd5 = '';
    core.failProviders = true;

    expect(await action.applyProfile(), isTrue);

    expect(core.calls, ['groups', 'providers']);
  });

  test('live iOS restoration takes precedence over autoRun', () async {
    container.read(appSettingProvider.notifier).value = const AppSettingProps(
      autoRun: true,
    );

    await action.initStatus();

    expect(core.calls, ['groups', 'providers']);
  });

  test(
    'changed config still applies without force after restoration',
    () async {
      await action.initStatus();
      core.calls.clear();
      globalState.lastConfigMd5 = 'previous-profile';

      expect(await action.applyProfile(), isTrue);

      expect(core.calls, ['setup', 'groups', 'providers']);
      expect(globalState.lastConfigMd5, '');
    },
  );

  test('restores live iOS state without setup or listener mutation', () async {
    await action.initStatus();

    expect(core.calls, ['groups', 'providers']);
    expect(container.read(groupsProvider).single.name, 'Proxy');
    expect(container.read(providersProvider).single.name, 'subscription');
    expect(container.read(runTimeProvider), greaterThanOrEqualTo(120000));
    expect(globalState.needInitStatus, isFalse);
    expect(globalState.lastConfigMd5, isNull);
  });
}
