import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/app_ports.dart';
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
import 'package:fl_clash/state.dart';
import 'package:fl_clash/pages/home.dart';
import 'package:fl_clash/widgets/capsule_navigation.dart';
import 'package:fl_clash/views/navigation.dart';
import 'package:fl_clash/views/proxies/card.dart';
import 'package:fl_clash/views/proxies/proxies.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

import '../helpers/bootstrap_state.dart';

class _Core extends Fake implements CoreHandlerInterface {
  String member = 'Node A';
  int reads = 0;
  @override
  Future<ProxiesData> getProxies() async {
    reads++;
    return ProxiesData(
      all: ['Proxy'],
      proxies: {
        'Proxy': {
          'name': 'Proxy',
          'type': 'Selector',
          'all': [member],
          'now': member,
        },
        member: {'name': member, 'type': 'ss'},
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer c;
  late _Core core;
  setUp(() {
    navigationPort = navigation;
    core = _Core();
    c = ProviderContainer(
      overrides: [
        ...buildAppStateOverrides(bootstrapAppState()),
        ...buildConfigOverrides(bootstrapConfig),
        profilesProvider.overrideWith(
          () => TestProfiles([
            const Profile(
              id: 1,
              autoUpdateDuration: Duration.zero,
              currentGroupName: 'Proxy',
              selectedMap: {'Proxy': 'Node A'},
            ),
          ]),
        ),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    globalState.container = c;
  });
  tearDown(() {
    debouncer.cancel(FunctionTag.updateGroups);
    c.dispose();
    navigationPort = null;
  });

  testWidgets(
    'production bootstrap cold publish restores mobile navigation and real node cards',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Keep the actual production navigation derivation observed before init.
      final nav = c.listen(currentNavigationItemsStateProvider, (_, _) {});
      addTearDown(nav.close);
      expect(
        nav.read().value.map((item) => item.label),
        contains(PageLabel.proxies),
      );
      c.read(initProvider.notifier).value = true;
      expect(
        nav.read().value.map((item) => item.label),
        isNot(contains(PageLabel.proxies)),
      );
      c.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      await tester.runAsync(
        () => c.read(proxiesActionProvider.notifier).updateGroups(),
      );
      expect(
        c.read(loadedGroupsProvider)?.groups.single.all.single.name,
        'Node A',
      );
      c.read(currentPageLabelProvider.notifier).toPage(PageLabel.tools);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const TestApp(includeNavigatorKey: false, child: HomePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(c.read(initProvider), isTrue);
      expect(c.read(coreStatusProvider), CoreStatus.connected);
      final capsule = find.byType(CapsuleNavigation);
      expect(capsule, findsOneWidget);
      expect(
        tester
            .widget<CapsuleNavigation>(capsule)
            .items
            .map((item) => item.pageLabel),
        contains(PageLabel.proxies),
      );
      final button = find.descendant(
        of: capsule,
        matching: find.text('Proxies'),
      );
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(c.read(currentPageLabelProvider), PageLabel.proxies);
      expect(c.read(groupsProvider).single.all.single.name, 'Node A');
      expect(core.reads, 1);
      // Successful empty publication must clear the same production-derived
      // state, while a failed read is handled by the action's retain gate.
      await tester.runAsync(
        () => c.read(proxiesActionProvider.notifier).updateGroups(),
      );
      await tester.pumpAndSettle();
      expect(c.read(groupsProvider), hasLength(1));
      expect(find.byType(ProxiesView), findsOneWidget);
      expect(find.byType(ProxyCard), findsOneWidget);
      expect(find.text('Node A', findRichText: true), findsWidgets);
      expect(
        tester.widget<ProxyCard>(find.byType(ProxyCard)).proxy.name,
        'Node A',
      );
      core.member = 'Node Fresh';
      await tester.runAsync(
        () => c.read(proxiesActionProvider.notifier).updateGroups(),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<ProxyCard>(find.byType(ProxyCard)).proxy.name,
        'Node Fresh',
      );
      expect(find.text('Node A', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
