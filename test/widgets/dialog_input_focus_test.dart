import 'package:fl_clash/common/dialog.dart';
import 'package:fl_clash/manager/back_manager.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/widgets/dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

Future<void> _openDialog(
  WidgetTester tester, {
  bool isTV = true,
  bool slider = false,
}) async {
  await tester.pumpWidget(
    BackManager(
      child: TestApp(
        overrides: [
          viewSizeProvider.overrideWithBuild((_, _) => const Size(800, 600)),
        ],
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => dialogs.showCommonDialog<void>(
              context: context,
              filter: false,
              child: Builder(
                builder: (context) => CommonDialog(
                  isTV: isTV,
                  title: 'Input',
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Submit'),
                    ),
                  ],
                  child: slider
                      ? Slider(autofocus: true, value: 0.5, onChanged: (_) {})
                      : const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextField(autofocus: true),
                            SizedBox(height: 16),
                            TextField(),
                          ],
                        ),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final key in <LogicalKeyboardKey?>[
    null,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.gameButtonB,
  ]) {
    testWidgets('TV back $key releases input before closing the dialog', (
      tester,
    ) async {
      await _openDialog(tester);
      await tester.enterText(find.byType(TextField).first, 'keep this');
      await tester.pumpAndSettle();
      final input = tester.widget<EditableText>(
        find.byType(EditableText).first,
      );
      final scope = input.focusNode.enclosingScope!;

      Future<void> back() async {
        if (key == null) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.sendKeyEvent(key);
        }
        await tester.pumpAndSettle();
      }

      await back();
      expect(find.byType(CommonDialog), findsOneWidget);
      expect(input.focusNode.hasFocus, isFalse);
      expect(scope.hasPrimaryFocus, isTrue);
      expect(scope.focusedChild, same(input.focusNode));
      expect(input.controller.text, 'keep this');
      expect(tester.testTextInput.hasAnyClients, isFalse);

      await back();
      expect(find.byType(CommonDialog), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('TV arrows resume traversal after leaving input', (tester) async {
    await _openDialog(tester);
    final inputs = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .toList();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(inputs.last.focusNode.hasPrimaryFocus, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(inputs.last.focusNode.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(CommonDialog), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('TV back releases a slider before closing', (tester) async {
    await _openDialog(tester, slider: true);
    final sliderFocus = FocusManager.instance.primaryFocus!;
    final scope = sliderFocus.enclosingScope!;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(CommonDialog), findsOneWidget);
    expect(sliderFocus.hasFocus, isFalse);
    expect(scope.hasPrimaryFocus, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(CommonDialog), findsNothing);
  });

  testWidgets('TV submit closes immediately while input is focused', (
    tester,
  ) async {
    await _openDialog(tester);
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(find.byType(CommonDialog), findsNothing);
  });

  testWidgets('non-TV back retains ordinary dialog behavior', (tester) async {
    await _openDialog(tester, isTV: false);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(CommonDialog), findsNothing);
  });

  testWidgets('back only affects the current TV dialog', (tester) async {
    await _openDialog(tester);
    final context = tester.element(find.byType(CommonDialog));
    final result = dialogs.showCommonDialog<void>(
      context: context,
      filter: false,
      child: const CommonDialog(
        isTV: true,
        title: 'Nested',
        child: Text('body'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await result;
    expect(find.text('Nested'), findsNothing);
    expect(find.text('Input'), findsOneWidget);
  });
}
