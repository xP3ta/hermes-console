// The floating mascot is shown only on the screens the dock belongs to, and
// "belongs" is declared where the dock is mounted (`DockScreen`), so it holds
// whether the bar is shown, hidden by hand or switched off in settings.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'dock-screen-qa',
  label: 'Dock screen QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-only',
  useHttps: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final prefs = DockPreferencesController.instance;
  final navigator = GlobalKey<NavigatorState>();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DockGeometry.instance.resetForTesting();
  });

  tearDown(() async {
    await prefs.setUseDock(true);
    DockGeometry.instance.resetForTesting();
  });

  Future<ConnectionManager> manager() async =>
      ConnectionManager.create(await SharedPreferences.getInstance());

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
  }

  bool carries(WidgetTester tester, Finder inside) =>
      DockGeometry.instance.carriesDock(ModalRoute.of(tester.element(inside))!);

  group('a route carries the dock', () {
    for (final useDock in [true, false]) {
      testWidgets('through GeneralDockShell, dock ${useDock ? 'on' : 'off'}', (
        tester,
      ) async {
        await prefs.setUseDock(useDock);
        final m = await manager();
        await pump(
          tester,
          Scaffold(
            body: GeneralDockShell(
              connection: _connection,
              connManager: m,
              body: const SizedBox.expand(key: ValueKey('body')),
            ),
          ),
        );
        expect(carries(tester, find.byKey(const ValueKey('body'))), isTrue);
      });

      testWidgets('through the Dock widget, dock ${useDock ? 'on' : 'off'}', (
        tester,
      ) async {
        await prefs.setUseDock(useDock);
        await pump(
          tester,
          Scaffold(
            body: Stack(
              children: [
                const SizedBox.expand(key: ValueKey('body')),
                Dock(
                  profileId: DockProfileId.general,
                  actions: const {
                    DockItemId.home: DockItemAction(selected: true),
                  },
                  showBackContext: false,
                ),
              ],
            ),
          ),
        );
        expect(carries(tester, find.byKey(const ValueKey('body'))), isTrue);
      });
    }

    testWidgets('a page without the dock does not, and a route stops '
        'carrying it when it goes', (tester) async {
      final m = await manager();
      await pump(
        tester,
        Scaffold(
          body: GeneralDockShell(
            connection: _connection,
            connManager: m,
            body: const SizedBox.expand(key: ValueKey('home')),
          ),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: SizedBox.expand(key: ValueKey('form'))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(carries(tester, find.byKey(const ValueKey('form'))), isFalse);
      final homeRoute = ModalRoute.of(
        tester.element(find.byKey(const ValueKey('home'), skipOffstage: false)),
      )!;
      expect(DockGeometry.instance.carriesDock(homeRoute), isTrue);

      // Replacing the screen with one that has no dock unregisters it.
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      expect(DockGeometry.instance.carriesDock(homeRoute), isFalse);
    });
  });

  testWidgets('DockScreen outside a route declares nothing', (tester) async {
    final before = DockGeometry.instance.screensRevision.value;
    await tester.pumpWidget(const DockScreen(child: SizedBox()));
    expect(DockGeometry.instance.screensRevision.value, before);
  });
}
