import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import '../helpers/test_profiles.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    registerFallbackValue(
      const ChangeProxyParams(groupName: 'Proxy', proxyName: 'A'),
    );
    await AppLocalizations.load(const Locale('en'));
  });
  for (final target in ['', compatibleProxyName]) {
    test(
      'rejected reset sentinel "$target" retains original owner selection',
      () async {
        final core = _Core();
        when(
          () => core.changeProxy(
            any(),
            closeConnections: any(named: 'closeConnections'),
          ),
        ).thenThrow(StateError('review fixture rejection'));
        final container = ProviderContainer(
          overrides: [
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            profilesProvider.overrideWith(
              () => TestProfiles([
                const Profile(
                  id: 1,
                  autoUpdateDuration: Duration.zero,
                  selectedMap: {'Proxy': 'A'},
                ),
                const Profile(
                  id: 2,
                  autoUpdateDuration: Duration.zero,
                  selectedMap: {'Proxy': 'B'},
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(currentProfileIdProvider.notifier).value = 1;
        await container
            .read(proxiesActionProvider.notifier)
            .changeProxy(groupName: 'Proxy', proxyName: target);
        verify(
          () => core.changeProxy(
            ChangeProxyParams(groupName: 'Proxy', proxyName: target),
            closeConnections: false,
          ),
        ).called(1);
        expect(container.read(profileProvider(1))?.selectedMap, {'Proxy': 'A'});
        expect(container.read(profileProvider(2))?.selectedMap, {'Proxy': 'B'});
      },
    );
  }
}
