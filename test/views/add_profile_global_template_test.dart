import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/profiles/add.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

class _Imports extends ProfilesAction {
  final selections = <bool>[];

  @override
  Future<void> addProfileFormURL(
    String url, {
    String? ageSecretKey,
    String? label,
    bool useGlobalTemplate = false,
  }) async {
    selections.add(useGlobalTemplate);
  }

  @override
  Future<ClipboardImportPreview> inspectClipboardContent(
    String content,
  ) async => const ClipboardImportPreview(
    kind: ClipboardImportKind.yaml,
    source: 'YAML',
    suggestedName: 'Nodes',
  );

  @override
  Future<void> addProfileFromClipboardContent(
    String content, [
    String? label,
    bool useGlobalTemplate = false,
  ]) async {
    selections.add(useGlobalTemplate);
  }

  @override
  Future<void> addProfileFormFile({bool useGlobalTemplate = false}) async {
    selections.add(useGlobalTemplate);
  }

  @override
  Future<void> addProfileFormQrCode({bool useGlobalTemplate = false}) async {
    selections.add(useGlobalTemplate);
  }
}

void main() {
  testWidgets(
    'URL dialog exposes a default-off template selection before submit',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Object? result;
      await tester.pumpWidget(
        TestApp(
          wrapInProviderScope: true,
          overrides: [
            viewSizeProvider.overrideWithBuild(
              (_, _) => const Size(1400, 1400),
            ),
          ],
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<Object>(
                    context: context,
                    builder: (_) => const URLFormDialog(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('url-use-global-template'));
      expect(toggle, findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tester.tap(toggle);
      await tester.enterText(
        find.byType(TextFormField).first,
        'https://example.com/profile.yaml',
      );
      await tester.tap(find.text(currentAppLocalizations.submit));
      await tester.pumpAndSettle();
      expect(result, (
        url: 'https://example.com/profile.yaml',
        ageSecretKey: null,
        useGlobalTemplate: true,
      ));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'add switch is local, defaults off, and reaches file and QR imports',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final imports = _Imports();
      final container = ProviderContainer(
        overrides: [profilesActionProvider.overrideWith(() => imports)],
      );
      addTearDown(container.dispose);
      globalState.container = container;
      container
          .read(viewSizeProvider.notifier)
          .update((_) => const Size(1400, 1400));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? {'text': 'proxies: [{name: node, type: direct}]'}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      Widget app({Key? key}) => UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Scaffold(
            body: Builder(
              builder: (context) => AddProfileView(key: key, context: context),
            ),
          ),
        ),
      );

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('add-use-global-template'));
      expect(toggle, findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tester.tap(find.text(currentAppLocalizations.file));
      await tester.pumpAndSettle();
      expect(imports.selections, [false]);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentAppLocalizations.file));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentAppLocalizations.qrcode));
      await tester.pumpAndSettle();
      expect(imports.selections, [false, true, true]);
      await tester.tap(find.text(currentAppLocalizations.url));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch).last).value, isTrue);
      await tester.enterText(
        find.byType(TextFormField).first,
        'https://example.com/profile.yaml',
      );
      await tester.tap(find.text(currentAppLocalizations.submit));
      await tester.pumpAndSettle();
      expect(imports.selections.last, isTrue);
      await tester.tap(find.text(currentAppLocalizations.clipboardImport));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch).last).value, isTrue);
      await tester.tap(find.text(currentAppLocalizations.confirm));
      await tester.pumpAndSettle();
      expect(imports.selections, [false, true, true, true, true]);
      await tester.pumpWidget(app(key: const Key('fresh-add')));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
