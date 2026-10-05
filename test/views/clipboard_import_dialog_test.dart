import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/views/profiles/clipboard_import_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

Widget _app(Widget child) => TestApp(
  wrapInProviderScope: true,
  overrides: [
    viewSizeProvider.overrideWithBuild((_, _) => const Size(900, 700)),
  ],
  child: child,
);

void _setViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'uses an explicit file name instead of the inspected suggestion',
    (tester) async {
      _setViewport(tester);
      String? importedName;
      await tester.pumpWidget(
        _app(
          ClipboardImportDialog(
            title: 'Import file',
            initialName: 'friends-config',
            readClipboard: () async =>
                'proxies:\n  - {name: node, type: direct}',
            inspect: (_) async => const ClipboardImportPreview(
              kind: ClipboardImportKind.yaml,
              source: 'YAML',
              nodeCount: 1,
              suggestedName: 'YAML profile',
            ),
            import: (_, name) async => importedName = name,
            onEditTemplate: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Import file'), findsOne);
      expect(find.text('friends-config'), findsOne);
      await tester.tap(find.text(currentAppLocalizations.confirm));
      await tester.pumpAndSettle();
      expect(importedName, 'friends-config');
    },
  );

  testWidgets('previews clipboard input and imports an editable profile name', (
    tester,
  ) async {
    _setViewport(tester);
    String? importedContent;
    String? importedName;

    await tester.pumpWidget(
      _app(
        ClipboardImportDialog(
          readClipboard: () async => 'vless://example',
          inspect: (content) async => const ClipboardImportPreview(
            kind: ClipboardImportKind.uri,
            source: 'VLESS',
            nodeCount: 1,
            suggestedName: 'VLESS 1',
          ),
          import: (content, name) async {
            importedContent = content;
            importedName = name;
          },
          onEditTemplate: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('URI · VLESS'), findsOne);
    expect(find.text('${currentAppLocalizations.nodes}: 1'), findsOne);
    await tester.enterText(find.byType(TextFormField), 'My profile');
    await tester.tap(find.text(currentAppLocalizations.confirm));
    await tester.pumpAndSettle();

    expect(importedContent, 'vless://example');
    expect(importedName, 'My profile');
  });

  testWidgets('keeps the dialog open and shows an import failure', (
    tester,
  ) async {
    _setViewport(tester);
    await tester.pumpWidget(
      _app(
        ClipboardImportDialog(
          readClipboard: () async => 'broken',
          inspect: (content) async => const ClipboardImportPreview(
            kind: ClipboardImportKind.uri,
            source: 'URI',
            nodeCount: 1,
            suggestedName: 'URI 1',
          ),
          import: (_, _) => throw const MessageException('invalid profile'),
          onEditTemplate: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(currentAppLocalizations.confirm));
    await tester.pumpAndSettle();

    expect(find.byType(ClipboardImportDialog), findsOne);
    expect(find.text('invalid profile'), findsOne);
  });

  testWidgets('disables repeated confirmation while import is pending', (
    tester,
  ) async {
    _setViewport(tester);
    final pending = Completer<void>();
    var calls = 0;

    await tester.pumpWidget(
      _app(
        ClipboardImportDialog(
          readClipboard: () async => 'vless://example',
          inspect: (content) async => const ClipboardImportPreview(
            kind: ClipboardImportKind.uri,
            source: 'VLESS',
            nodeCount: 1,
            suggestedName: 'VLESS 1',
          ),
          import: (_, _) {
            calls++;
            return pending.future;
          },
          onEditTemplate: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(currentAppLocalizations.confirm));
    await tester.pump();
    await tester.tap(find.text(currentAppLocalizations.loading));
    expect(calls, 1);

    pending.complete();
    await tester.pumpAndSettle();
  });
}
