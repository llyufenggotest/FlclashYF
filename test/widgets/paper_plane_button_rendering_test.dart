import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/dashboard.dart';
import 'package:fl_clash/views/dashboard/widgets/core_status_button.dart';
import 'package:fl_clash/views/dashboard/widgets/start_button.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final connected in [false, true]) {
      testWidgets('dashboard plane slots $brightness connected=$connected', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final container = ProviderContainer(
          overrides: [
            dashboardStateProvider.overrideWithValue(
              const DashboardState(dashboardWidgets: []),
            ),
            profilesProvider.overrideWithValue([
              const Profile(id: 1, autoUpdateDuration: Duration.zero),
            ]),
            suspendProvider.overrideWithValue(false),
          ],
        );
        addTearDown(container.dispose);
        globalState.container = container;
        container.read(coreStatusProvider.notifier).value = connected
            ? CoreStatus.connected
            : CoreStatus.disconnected;
        container.read(runTimeProvider.notifier).value = connected ? 1 : null;
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TestApp(
              includeNavigatorKey: false,
              homeBuilder: (child) => Theme(
                data: ThemeData(brightness: brightness),
                child: RepaintBoundary(key: boundaryKey, child: child),
              ),
              child: const DashboardView(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final coreIcon = find.descendant(
          of: find.byType(CoreStatusButton),
          matching: find.byType(PaperPlaneStatusIcon),
        );
        final startIcon = find.descendant(
          of: find.byType(StartButton),
          matching: find.byType(PaperPlaneStatusIcon),
        );
        expect(coreIcon, findsOneWidget);
        expect(startIcon, findsOneWidget);
        expect(
          find.ancestor(of: coreIcon, matching: find.byType(AppBar)),
          findsOneWidget,
        );
        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
        expect(
          find.descendant(
            of: find.byWidget(scaffold.floatingActionButton!),
            matching: find.byType(StartButton),
          ),
          findsOneWidget,
        );
        expect(tester.getTopLeft(coreIcon).dy, lessThan(80));
        expect(tester.getTopLeft(startIcon).dy, greaterThan(600));
        for (final icon in [coreIcon, startIcon]) {
          expect(
            tester.widget<PaperPlaneStatusIcon>(icon).disconnected,
            !connected,
          );
        }
        final button = tester.widget<IconButton>(
          find.descendant(
            of: find.byType(CoreStatusButton),
            matching: find.byType(IconButton),
          ),
        );
        final dark = brightness == Brightness.dark;
        expect(
          button.style!.backgroundColor!.resolve({}),
          connected
              ? Color(dark ? 0xFF17382D : 0xFFDFF6EC)
              : Color(dark ? 0xFF2A303A : 0xFFEEF0F6),
        );
        expect(
          button.style!.foregroundColor!.resolve({}),
          connected
              ? Color(dark ? 0xFF74DDB7 : 0xFF2E9E78)
              : Color(dark ? 0xFFBCC4D1 : 0xFF626A7B),
        );
        expect(button.onPressed, isNotNull);
        final localizations = tester.element(coreIcon).appLocalizations;
        expect(
          find.byTooltip(
            connected ? localizations.connected : localizations.disconnected,
          ),
          findsOneWidget,
        );
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 3);
          final bytes = await image.toByteData(format: ImageByteFormat.png);
          if (connected) {
            final rgba = (await image.toByteData())!.buffer.asUint8List();
            final buttonRect = tester.getRect(
              find.descendant(
                of: find.byType(CoreStatusButton),
                matching: find.byType(IconButton),
              ),
            );
            final point =
                buttonRect.center + Offset(buttonRect.shortestSide / 2 - 4, 0);
            final index =
                ((point.dy * 3).toInt() * image.width +
                    (point.dx * 3).toInt()) *
                4;
            expect(
              rgba[index + 1] - rgba[index],
              greaterThan(60),
              reason: 'connected teal outer ring pixel',
            );
          }
          final output = Platform.environment['PLANE_RENDER_OUTPUT_DIR'];
          if (output != null) {
            await Directory(output).create(recursive: true);
            await File(
              '$output/${brightness.name}-${connected ? 'connected' : 'idle'}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          }
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }
  }
}
