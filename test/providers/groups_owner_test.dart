
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/test_profiles.dart';

ProxiesData data(String member, {String group = 'Proxy'}) => ProxiesData(
  all: [group],
  proxies: {
    group: {
      'name': group,
      'type': 'Selector',
      'all': [member],
      'now': member,
    },
    member: {'name': member, 'type': 'ss'},
  },
);

class OwnerCore extends Fake implements CoreHandlerInterface {
  Future<ProxiesData> Function() read = () async => data('A');
  Future<String> Function() change = () async => '';
  Future<Delay?> Function(String, String)? probe;
  final probes = <String>[];
  int changes = 0;
  @override
  Future<ProxiesData> getProxies() => read();
  @override
  Future<String> changeProxy(
    ChangeProxyParams params, {
    bool closeConnections = false,
  }) {
    changes++;
    return change();
  }

  @override
  Future<Delay?> asyncTestDelay(String url, String name) async {
    probes.add(name);
    if (probe != null) return probe!(url, name);
    return Delay(url: url, name: name, value: 10);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer c;
  late OwnerCore core;
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
  setUp(() {
    core = OwnerCore();
    c = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([a, b])),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    c.read(currentProfileIdProvider.notifier).value = 1;
  });
  tearDown(() {
    debouncer.cancel((FunctionTag.changeProxy, 'Proxy'));
    debouncer.cancel(FunctionTag.updateGroups);
    c.dispose();
  });
  ProxiesAction action() => c.read(proxiesActionProvider.notifier);

  test('published A selection remains A while UI intent becomes B', () async {
    await action().updateGroups();
    c.read(currentProfileIdProvider.notifier).value = 2;
    expect(c.read(groupsProvider).single.all.single.name, 'A');
    expect(c.read(selectedMapProvider), {'Proxy': 'A'});
    expect(c.read(realSelectedProxyStateProvider('Proxy')).proxyName, 'A');
  });

  test('retired initial hydration cannot silently rebind an old owner', () async {
    await action().updateGroups();
    final controller = c.read(coreHandlerProvider);
    final prior = c.read(loadedGroupsProvider);
    final epoch = controller.configuration.retire();
    controller.configuration.started(epoch);
    core.read = () async => data('A', group: 'WrongSession');
    await action().updateGroups();
    expect(c.read(loadedGroupsProvider), same(prior));
  });

  test('successful empty read clears the prior groups', () async {
    await action().updateGroups();
    core.read = () async => const ProxiesData(all: [], proxies: {});
    await action().updateGroups();
    expect(c.read(groupsProvider), isEmpty);
  });

  test('switch-window tap cannot mutate B or send an old A group', () async {
    await action().updateGroups();
    c.read(currentProfileIdProvider.notifier).value = 2;
    action().changeProxyDebounce('Proxy', 'A');
    await action().changeProxy(groupName: 'Proxy', proxyName: 'A');
    expect(c.read(currentProfileProvider)?.selectedMap, {'Proxy': 'B'});
    expect(core.changes, 0);
  });

  test(
    'recursive nested groups never resolve current B selection against A members',
    () async {
      core.read = () async => const ProxiesData(
        all: ['Proxy', 'Nested'],
        proxies: {
          'Proxy': {
            'name': 'Proxy',
            'type': 'Selector',
            'all': ['Nested'],
            'now': 'Nested',
          },
          'Nested': {
            'name': 'Nested',
            'type': 'Selector',
            'all': ['A'],
            'now': 'A',
          },
          'A': {'name': 'A', 'type': 'ss'},
        },
      );
      c
          .read(profilesProvider.notifier)
          .put(a.copyWith(selectedMap: {'Proxy': 'Nested', 'Nested': 'A'}));
      await action().updateGroups();
      c.read(currentProfileIdProvider.notifier).value = 2;
      await action().proxyDelayTest(
        const Proxy(name: 'Proxy', type: 'Selector'),
      );
      expect(c.read(realSelectedProxyStateProvider('Proxy')).proxyName, 'A');
      expect(core.probes, ['A']);
    },
  );

  test(
    'recursive delay resolution uses displayed owner not current B',
    () async {
      await action().updateGroups();
      c.read(currentProfileIdProvider.notifier).value = 2;
      await action().proxyDelayTest(
        const Proxy(name: 'Proxy', type: 'Selector'),
      );
      expect(core.probes, ['A']);
    },
  );
}
