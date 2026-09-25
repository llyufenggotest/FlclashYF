import 'package:fl_clash/widgets/capsule_navigation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('reports the tapped destination and updates selection colors', (
    tester,
  ) async {
    var selectedIndex = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        ),
        home: StatefulBuilder(
          builder: (context, setState) {
            return Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: CapsuleNavigation(
                  items: const [
                    CapsuleNavigationItem(
                      icon: Icon(Icons.home_outlined),
                      label: 'Home',
                    ),
                    CapsuleNavigationItem(
                      icon: Icon(Icons.settings_outlined),
                      label: 'Settings',
                    ),
                  ],
                  selectedIndex: selectedIndex,
                  onSelected: (index) {
                    setState(() => selectedIndex = index);
                  },
                ),
              ),
            );
          },
        ),
      ),
    );

    final colorScheme = Theme.of(
      tester.element(find.byType(CapsuleNavigation)),
    ).colorScheme;
    expect(
      IconTheme.of(tester.element(find.byIcon(Icons.home_outlined))).color,
      colorScheme.primary,
    );
    expect(
      IconTheme.of(tester.element(find.byIcon(Icons.settings_outlined))).color,
      colorScheme.onSurfaceVariant,
    );

    await tester.tap(find.text('Settings'));
    await tester.pump();

    expect(selectedIndex, 1);
    expect(
      IconTheme.of(tester.element(find.byIcon(Icons.settings_outlined))).color,
      colorScheme.primary,
    );
  });

  testWidgets('fits a narrow safe viewport at large text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(240, 480);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewPadding);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(240, 480),
            padding: EdgeInsets.only(bottom: 24),
            viewPadding: EdgeInsets.only(bottom: 24),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: CapsuleNavigation(
                items: const [
                  CapsuleNavigationItem(
                    icon: Icon(Icons.home_outlined),
                    label: 'Overview',
                  ),
                  CapsuleNavigationItem(
                    icon: Icon(Icons.route_outlined),
                    label: 'Connections',
                  ),
                  CapsuleNavigationItem(
                    icon: Icon(Icons.settings_outlined),
                    label: 'Settings',
                  ),
                ],
                selectedIndex: 0,
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final capsule = tester.getRect(find.byKey(CapsuleNavigation.surfaceKey));
    expect(capsule.width, closeTo(240 * 0.76, 0.01));
    expect(capsule.bottom, 480 - 24 - 10);
  });
}
