import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/profiles/edit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
}

class _Setup extends SetupAction {
  @override
  void autoApplyProfile() {}
}

class _Action extends ProfilesAction {
  bool materialized = false;
  Profile? updated;

  @override
  Future<Profile> materializeGlobalTemplate(Profile profile) async {
    materialized = true;
    return profile;
  }

  @override
  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
  }) async {
    updated = profile;
  }
}

class _Core extends Fake implements CoreHandlerInterface {
  @override
  Future<String> validateConfig(String content) async => '';
}

void main() {
  testWidgets('subscription edit switch defaults off and saves per profile', (
    tester,
  ) async {
    final original = PathProviderPlatform.instance;
    final dir = Directory.systemTemp.createTempSync('template_switch_');
    PathProviderPlatform.instance = _Paths(dir.path);
    addTearDown(() async {
      PathProviderPlatform.instance = original;
      await dir.delete(recursive: true);
    });
    final profile = Profile.normal(
      label: 'Subscription',
      url: 'https://example.com/profile.yaml',
    ).copyWith(autoUpdate: false);
    final action = _Action();
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
        setupActionProvider.overrideWith(_Setup.new),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(_Core())),
        profilesActionProvider.overrideWith(() => action),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Scaffold(
            body: Builder(
              builder: (context) =>
                  EditProfileView(context: context, profile: profile),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('use-global-template')).first;
    expect(row, findsOneWidget);
    expect(
      tester
          .widget<Switch>(
            find.descendant(of: row, matching: find.byType(Switch)),
          )
          .value,
      isFalse,
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text(currentAppLocalizations.save));
    await tester.pump(const Duration(seconds: 1));
    expect(container.read(profilesProvider).single.useGlobalTemplate, isTrue);
    expect(action.materialized, isTrue);
    expect(
      container.read(profilesProvider).single.overwriteType,
      profile.overwriteType,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('changing URL downloads before materializing the template', (
    tester,
  ) async {
    final original = PathProviderPlatform.instance;
    final dir = Directory.systemTemp.createTempSync('template_url_change_');
    PathProviderPlatform.instance = _Paths(dir.path);
    addTearDown(() async {
      PathProviderPlatform.instance = original;
      await dir.delete(recursive: true);
    });
    final profile = Profile.normal(
      label: 'Subscription',
      url: 'https://old.example/profile.yaml',
    ).copyWith(autoUpdate: false);
    final action = _Action();
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
        setupActionProvider.overrideWith(_Setup.new),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(_Core())),
        profilesActionProvider.overrideWith(() => action),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Scaffold(
            body: Builder(
              builder: (context) =>
                  EditProfileView(context: context, profile: profile),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final urlField = find.byType(TextFormField).at(1);
    await tester.enterText(urlField, 'https://new.example/profile.yaml');
    await tester.tap(find.byKey(const Key('use-global-template')).first);
    await tester.tap(find.text(currentAppLocalizations.save));
    await tester.pump(const Duration(seconds: 1));
    expect(action.updated?.url, 'https://new.example/profile.yaml');
    expect(action.updated?.useGlobalTemplate, isTrue);
    expect(action.materialized, isFalse);
  });
}
