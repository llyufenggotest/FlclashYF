import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/desktop_profile_drop.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/profiles/clipboard_import_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Imports extends ProfilesAction {
  bool? selected;
  String? label;
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
    String? name,
    bool useGlobalTemplate = false,
  ]) async {
    selected = useGlobalTemplate;
    label = name;
  }
}

void main() {
  testWidgets(
    'desktop drop prompts with an independent default-off template switch',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final directory = Directory.systemTemp.createTempSync('drop_template_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/Desktop.yaml');
      file.writeAsStringSync('proxies: [{name: node, type: direct}]');
      final imports = _Imports();
      final container = ProviderContainer(
        overrides: [profilesActionProvider.overrideWith(() => imports)],
      );
      addTearDown(container.dispose);
      globalState.container = container;
      container
          .read(viewSizeProvider.notifier)
          .update((_) => const Size(1200, 1000));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: globalState.navigatorKey,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            supportedLocales: AppLocalizations.delegate.supportedLocales,
            builder: (_, child) => DesktopProfileDrop(child: child!),
            home: const Scaffold(body: Text('Other page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final drop = tester.widget<DropTarget>(find.byType(DropTarget));
      await tester.runAsync(() async {
        drop.onDragDone!(
          DropDoneDetails(
            files: [DropItemFile(file.path)],
            localPosition: Offset.zero,
            globalPosition: Offset.zero,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.byType(ClipboardImportDialog), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(imports.selected, isNull);
      await tester.tap(find.byKey(const Key('import-use-global-template')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentAppLocalizations.confirm));
      await tester.pumpAndSettle();
      expect(imports.selected, isTrue);
      expect(imports.label, 'Desktop');
      expect(find.text('Other page'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
