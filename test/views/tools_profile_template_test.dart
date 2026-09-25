import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/views/config/profile_template.dart';
import 'package:fl_clash/views/tools.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  late Database testDatabase;

  setUpAll(() async {
    testDatabase = Database(NativeDatabase.memory());
    database = testDatabase;
    await AppLocalizations.load(const Locale('en'));
  });

  tearDownAll(() async {
    await testDatabase.close();
  });

  testWidgets('settings lists the profile template next to basic config', (
    tester,
  ) async {
    await tester.pumpWidget(
      const TestApp(
        wrapInProviderScope: true,
        child: SizedBox(width: 800, height: 1200, child: ToolsView()),
      ),
    );
    await tester.pump();

    final basic = find.text('Basic configuration');
    final template = find.text('Profile template');
    expect(basic, findsOneWidget);
    expect(template, findsOneWidget);

    final basicY = tester.getTopLeft(basic).dy;
    final templateY = tester.getTopLeft(template).dy;
    expect(templateY, greaterThan(basicY));

    await tester.tap(template);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ProfileTemplateView), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  });
}
