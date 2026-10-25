import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/test_profiles.dart';
import 'groups_owner_test.dart' show OwnerCore, data;
import '../helpers/bootstrap_state.dart';

class _Core extends OwnerCore {
  final setups = <SetupParams>[];
  Future<String> Function()? setupGate;
  String member = 'A';
  _Core() {
    read = () async => data(member);
  }
  @override
  Future<String> setupConfig(SetupParams params) async {
    setups.add(params);
    final result = await (setupGate?.call() ?? Future.value(''));
    if (result.isEmpty) member = params.selectedMap['Proxy'] ?? 'A';
    return result;
  }

  @override
  Future<List<ExternalProvider>> getExternalProviders() async => [];
}

class _Setup extends SetupAction {
  bool restore = false;
  @override
  bool get shouldRestoreRunningService => restore;
  @override
  Future<DateTime?> readServiceRunTime() async =>
      DateTime.now().subtract(const Duration(minutes: 1));
  // Only YAML construction is faked; applyProfile, serialization, file write,
  // controller begin/finish, group publication and all guards stay production.
  @override
  Future<({String yaml, String md5})> getProfile({
    required SetupState setupState,
    required PatchClashConfig patchConfig,
  }) async => (yaml: 'proxies: []', md5: 'same-yaml');
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

const _state = SetupState(
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

void main({bool productionBootstrap = false}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform paths;
  late ProviderContainer c;
  late _Core core;
  late _Setup setup;
  late CoreController controller;
  String? md5;
  const a = Profile(
    id: 1,
    autoUpdateDuration: Duration.zero,
    selectedMap: {'Proxy': 'A'},
  );
  const b = Profile(
    id: 2,
    autoUpdateDuration: Duration.zero,
    selectedMap: {'Proxy': 'B'},
  );
  setUpAll(() async {
    paths = PathProviderPlatform.instance;
    directory = Directory.systemTemp.createTempSync('groups_owner');
    PathProviderPlatform.instance = _Paths(directory.path);
    await AppLocalizations.load(const Locale('en'));
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = paths;
    await directory.delete(recursive: true);
  });
  setUp(() {
    md5 = globalState.lastConfigMd5;
    globalState.lastConfigMd5 = null;
    core = _Core();
    setup = _Setup();
    controller = CoreController.scoped(core);
    c = ProviderContainer(
      overrides: [
        if (productionBootstrap) ...[
          ...buildAppStateOverrides(bootstrapAppState()),
          ...buildConfigOverrides(bootstrapConfig),
        ],
        profilesProvider.overrideWith(() => TestProfiles([a, b])),
        setupStateProvider.overrideWith(
          (_, id) => _state.copyWith(profileId: id),
        ),
        coreHandlerProvider.overrideWithValue(controller),
        setupActionProvider.overrideWith(() => setup),
        commonActionProvider.overrideWith(_Common.new),
      ],
    );
    globalState.container = c;
    c.listen(currentProfileIdProvider, (_, _) {});
    c.read(currentProfileIdProvider.notifier).value = 1;
    c.read(setupActionProvider.notifier);
  });
  tearDown(() {
    debouncer.cancel((FunctionTag.changeProxy, 'Proxy'));
    debouncer.cancel(FunctionTag.updateGroups);
    c.dispose();
    globalState.lastConfigMd5 = md5;
  });
  ProxiesAction action() => c.read(proxiesActionProvider.notifier);
  void select(int id) => c.read(currentProfileIdProvider.notifier).value = id;

  test(
    'same YAML MD5 across profiles applies target selection and owner atomically',
    () async {
      expect(await setup.applyProfile(force: true), isTrue);
      final publications = <({int? owner, String member, String? selection})>[];
      c.listen(groupsProvider, (_, groups) {
        publications.add((
          owner: c.read(loadedGroupsProvider)?.profileId,
          member: groups.single.all.single.name,
          selection: c.read(selectedMapProvider)['Proxy'],
        ));
      });
      select(2);
      expect(c.read(selectedMapProvider)['Proxy'], 'A');
      expect(await setup.applyProfile(), isTrue);
      await c.pump();
      expect(core.setups.map((p) => p.selectedMap['Proxy']), ['A', 'B']);
      expect(publications, [(owner: 2, member: 'B', selection: 'B')]);
      expect(c.read(profileProvider(1))?.selectedMap['Proxy'], 'A');
    },
  );

  test('same owner unchanged MD5 retains skip and hydrates once', () async {
    await setup.applyProfile(force: true);
    final token = controller.configuration.token;
    expect(await setup.applyProfile(), isTrue);
    expect(core.setups, hasLength(1));
    expect(controller.configuration.token, same(token));
    expect(c.read(loadedGroupsProvider)?.profileId, 1);
  });

  test(
    'forced same-ID reload invalidates old read even when YAML matches',
    () async {
      await setup.applyProfile(force: true);
      final gate = Completer<ProxiesData>();
      core.read = () => gate.future;
      final stale = action().updateGroups();
      core.read = () async => data('A', group: 'Fresh');
      final oldToken = controller.configuration.token;
      expect(await setup.applyProfile(force: true), isTrue);
      gate.complete(data('A', group: 'Stale'));
      await stale;
      expect(controller.configuration.token, isNot(same(oldToken)));
      expect(c.read(groupsProvider).single.name, 'Fresh');
    },
  );

  test('A to B to A reverse-order responses retain latest A', () async {
    await setup.applyProfile(force: true);
    final aGate = Completer<ProxiesData>();
    core.read = () => aGate.future;
    final aOld = action().updateGroups();
    select(2);
    final bGate = Completer<ProxiesData>();
    final bEntered = Completer<void>();
    core.read = () {
      if (!bEntered.isCompleted) bEntered.complete();
      return bGate.future;
    };
    final bApply = setup.applyProfile(force: true);
    await bEntered.future;
    select(1);
    core.read = () async => data('A', group: 'Latest');
    final aApply = setup.applyProfile(force: true);
    bGate.complete(data('B'));
    await bApply;
    await aApply;
    aGate.complete(data('A', group: 'Obsolete'));
    await aOld;
    expect(c.read(groupsProvider).single.name, 'Latest');
    expect(c.read(loadedGroupsProvider)?.profileId, 1);
    expect(c.read(selectedMapProvider)['Proxy'], isNot('B'));
  });

  test('failed read retains snapshot and successful empty clears it', () async {
    await setup.applyProfile(force: true);
    final prior = c.read(loadedGroupsProvider);
    core.read = () async => throw StateError('fixture read failed');
    await action().updateGroups();
    expect(c.read(loadedGroupsProvider), same(prior));
    core.read = () async => const ProxiesData(all: [], proxies: {});
    await action().updateGroups();
    expect(c.read(groupsProvider), isEmpty);
    expect(c.read(loadedGroupsProvider)?.profileId, 1);
  });

  test(
    'A refresh during pending B intent does not prune same-name B members',
    () async {
      await setup.applyProfile(force: true);
      select(2);
      await action().updateGroups();
      expect(c.read(loadedGroupsProvider)?.profileId, 1);
      expect(c.read(groupsProvider).single.all.single.name, 'A');
      expect(c.read(profileProvider(2))?.selectedMap, {'Proxy': 'B'});
    },
  );

  test('late change failure rolls back A only, never current B', () async {
    await setup.applyProfile(force: true);
    final gate = Completer<String>();
    core.change = () => gate.future;
    final change = action().changeProxy(groupName: 'Proxy', proxyName: 'A2');
    select(2);
    gate.completeError(StateError('fixture rejected'));
    await change;
    expect(c.read(profileProvider(1))?.selectedMap, {'Proxy': 'A'});
    expect(c.read(profileProvider(2))?.selectedMap, {'Proxy': 'B'});
  });

  test(
    'queued tap is cancelled on profile switch and optimistic A rolls back',
    () async {
      await setup.applyProfile(force: true);
      action().changeProxyDebounce('Proxy', 'A2');
      select(2);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(core.changes, 0);
      expect(c.read(profileProvider(1))?.selectedMap, {'Proxy': 'A'});
      expect(c.read(profileProvider(2))?.selectedMap, {'Proxy': 'B'});
    },
  );

  test(
    'failed apply retains display but denies reads and writes until recovery',
    () async {
      await setup.applyProfile(force: true);
      final prior = c.read(loadedGroupsProvider);
      select(2);
      core.setupGate = () async => 'rejected';
      expect(await setup.applyProfile(force: true), isFalse);
      expect(c.read(loadedGroupsProvider), same(prior));
      await action().changeProxy(groupName: 'Proxy', proxyName: 'A');
      await action().updateGroups();
      expect(c.read(loadedGroupsProvider), same(prior));
      expect(core.changes, 0);
      expect(c.read(profileProvider(2))?.selectedMap, {'Proxy': 'B'});
      core.setupGate = null;
      expect(await setup.applyProfile(force: true), isTrue);
      expect(c.read(loadedGroupsProvider)?.profileId, 2);
    },
  );

  test(
    'session retirement rejects outstanding groups and explicit apply recovers',
    () async {
      await setup.applyProfile(force: true);
      final gate = Completer<ProxiesData>();
      core.read = () => gate.future;
      final stale = action().updateGroups();
      final prior = c.read(loadedGroupsProvider);
      final epoch = controller.configuration.retire();
      gate.complete(data('A', group: 'Retired'));
      await stale;
      expect(c.read(loadedGroupsProvider), same(prior));
      controller.configuration.started(epoch);
      core.read = () async => data('A');
      await action().updateGroups();
      expect(c.read(loadedGroupsProvider), same(prior));
      expect(await setup.applyProfile(force: true), isTrue);
      expect(
        c.read(loadedGroupsProvider)?.token,
        same(controller.configuration.token),
      );
    },
  );

  test(
    'stale delay completion after force reload cannot publish or continue an old group batch',
    () async {
      await setup.applyProfile(force: true);
      final gate = Completer<Delay?>();
      final entered = Completer<void>();
      core.probe = (url, name) {
        if (!entered.isCompleted) entered.complete();
        return gate.future;
      };
      final oldGroup = c.read(groupsProvider).single;
      final run = action().delayTestGroups([oldGroup, oldGroup]);
      await entered.future;
      final url = c.read(realTestUrlProvider(null));
      expect(await setup.applyProfile(force: true), isTrue);
      gate.complete(Delay(url: url, name: 'A', value: 999));
      await run;
      expect(core.probes, ['A']);
      expect(c.read(delayDataSourceProvider)[url]?['A'], isNot(999));
      expect(c.read(pendingDelayTestsProvider), isEmpty);
    },
  );

  test(
    'delay cannot bypass applying gate and failed configuration gate',
    () async {
      await setup.applyProfile(force: true);
      final op = controller.configuration.begin();
      await action().proxyDelayTest(
        const Proxy(name: 'Proxy', type: 'Selector'),
      );
      expect(core.probes, isEmpty);
      controller.configuration.finish(op, false);
      await action().proxyDelayTest(
        const Proxy(name: 'Proxy', type: 'Selector'),
      );
      expect(core.probes, isEmpty);
      expect(await setup.applyProfile(force: true), isTrue);
      await action().proxyDelayTest(
        const Proxy(name: 'Proxy', type: 'Selector'),
      );
      expect(core.probes, ['A']);
    },
  );

  test(
    'same-ID force reload invalidates a queued click and preserves selection',
    () async {
      await setup.applyProfile(force: true);
      action().changeProxyDebounce('Proxy', 'A2');
      expect(await setup.applyProfile(force: true), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(core.changes, 0);
      expect(c.read(profileProvider(1))?.selectedMap, {'Proxy': 'A'});
      expect(core.setups.last.selectedMap, {'Proxy': 'A'});
    },
  );

  test(
    'newer refresh beats earlier refresh within the same owner and token',
    () async {
      await setup.applyProfile(force: true);
      final gate = Completer<ProxiesData>();
      core.read = () => gate.future;
      final stale = action().updateGroups();
      core.read = () async => data('A', group: 'Newest');
      await action().updateGroups();
      gate.complete(data('A', group: 'Older'));
      await stale;
      expect(c.read(groupsProvider).single.name, 'Newest');
      expect(c.read(loadedGroupsProvider)?.profileId, 1);
    },
  );

  test(
    'running-service restore binds owner without replacing lifecycle token',
    () async {
      setup.restore = true;
      final token = controller.configuration.token;
      await setup.restoreForegroundState();
      expect(core.setups, isEmpty);
      expect(c.read(loadedGroupsProvider)?.profileId, 1);
      expect(controller.configuration.token, same(token));
      select(2);
      await action().updateGroups();
      expect(c.read(loadedGroupsProvider)?.profileId, 1);
      expect(c.read(profileProvider(2))?.selectedMap, {'Proxy': 'B'});
    },
  );
}
