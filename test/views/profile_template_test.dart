import 'package:fl_clash/common/exception.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/views/config/profile_template.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  setUpAll(() async {
    await AppLocalizations.load(const Locale('en'));
  });

  testWidgets('keeps invalid template text and displays the error', (
    tester,
  ) async {
    await tester.pumpWidget(
      TestApp(
        child: ProfileTemplateView(
          loadTemplate: () async => 'proxies: []',
          saveTemplate: (_) async {
            throw const MessageException('invalid yaml');
          },
          resetTemplate: () async {},
          confirmReset: (_) async => true,
        ),
      ),
    );
    await tester.pump();

    final field = find.byKey(ProfileTemplateView.editorKey);
    await tester.enterText(field, 'proxies: [');
    await tester.tap(find.byTooltip('Save'));
    await tester.pump();

    expect(find.text('invalid yaml'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'proxies: [');
  });

  testWidgets('reset confirms, restores the default, and reloads the editor', (
    tester,
  ) async {
    var content = 'custom: true';
    var resetCount = 0;
    var confirmCount = 0;
    await tester.pumpWidget(
      TestApp(
        child: ProfileTemplateView(
          loadTemplate: () async => content,
          saveTemplate: (_) async {},
          resetTemplate: () async {
            resetCount++;
            content = 'default: true';
          },
          confirmReset: (_) async {
            confirmCount++;
            return true;
          },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Restore default'));
    await tester.pump();

    expect(confirmCount, 1);
    expect(resetCount, 1);
    expect(
      tester
          .widget<TextField>(find.byKey(ProfileTemplateView.editorKey))
          .controller!
          .text,
      'default: true',
    );
  });
}
