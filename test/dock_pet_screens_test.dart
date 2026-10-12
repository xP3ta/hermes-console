// The four pure configuration screens (Ajustes, Perfiles, Voz, the Gateway
// manager) keep the dock but not the floating pet; the content destinations
// keep both. The flag lives on the shell (`GeneralDockShell.pet`) and rides
// the same registration the dock uses (`DockScreen`).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/gateway_manager_screen.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_route_watch.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/bot_roster_fakes.dart' show FakeProfilesServer;

final _conn = SavedConnection(
  id: 'pet-screens',
  label: 'QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final prefs = DockPreferencesController.instance;
  final navigator = GlobalKey<NavigatorState>();
  late MascotRouteWatch watch;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    DockGeometry.instance.resetForTesting();
    watch = MascotRouteWatch();
  });

  tearDown(() async {
    await prefs.setUseDock(true);
    DockGeometry.instance.resetForTesting();
  });

  Future<ConnectionManager> manager() async {
    final m = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await m.upsertConnection(_conn);
    await m.setActiveConnection(_conn.id);
    return m;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester, Widget screen) async {
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
        navigatorObservers: [watch],
        home: const Scaffold(body: Text('home')),
      ),
    );
    await settle(tester);
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    await settle(tester);
  }

  Route<dynamic> routeOf(WidgetTester tester, Finder inside) =>
      ModalRoute.of(tester.element(inside))!;

  Future<void> expectConfigScreen(
    WidgetTester tester,
    Type screen,
    bool dockOn,
  ) async {
    final route = routeOf(tester, find.byType(screen));
    expect(
      DockGeometry.instance.carriesDock(route),
      isTrue,
      reason: 'still a dock route',
    );
    expect(
      DockGeometry.instance.carriesPet(route),
      isFalse,
      reason: 'no pet here',
    );
    expect(watch.covered.value, isTrue, reason: 'the mascot stays out');
    // The dock itself is unaffected.
    expect(find.byType(Dock), dockOn ? findsOneWidget : findsNothing);
    // Let a screen's own 10 s timer run out after it is gone.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  }

  for (final dockOn in [true, false]) {
    final label = dockOn ? 'dock on' : 'dock off';

    testWidgets('Ajustes: no pet, dock untouched ($label)', (tester) async {
      await prefs.setUseDock(dockOn);
      final m = await manager();
      await open(tester, SettingsScreen(connection: _conn, connManager: m));
      await expectConfigScreen(tester, SettingsScreen, dockOn);
    });

    testWidgets('Perfiles: no pet, dock untouched ($label)', (tester) async {
      await prefs.setUseDock(dockOn);
      final m = await manager();
      await open(
        tester,
        ProfilesScreen(
          connection: _conn,
          connManager: m,
          clientOverride: FakeProfilesServer().client,
        ),
      );
      await expectConfigScreen(tester, ProfilesScreen, dockOn);
    });

    testWidgets('Gateway manager: no pet, dock untouched ($label)', (
      tester,
    ) async {
      await prefs.setUseDock(dockOn);
      final m = await manager();
      await open(tester, GatewayManagerScreen(connManager: m));
      await expectConfigScreen(tester, GatewayManagerScreen, dockOn);
    });

    testWidgets('a content screen keeps the pet ($label)', (tester) async {
      await prefs.setUseDock(dockOn);
      final m = await manager();
      await open(
        tester,
        Scaffold(
          body: GeneralDockShell(
            connection: _conn,
            connManager: m,
            body: const SizedBox.expand(key: ValueKey('content')),
          ),
        ),
      );
      final route = routeOf(tester, find.byKey(const ValueKey('content')));
      expect(DockGeometry.instance.carriesPet(route), isTrue);
      expect(watch.covered.value, isFalse);
    });

    testWidgets('the shell flag alone takes the pet out ($label)', (
      tester,
    ) async {
      await prefs.setUseDock(dockOn);
      final m = await manager();
      await open(
        tester,
        Scaffold(
          body: GeneralDockShell(
            connection: _conn,
            connManager: m,
            pet: false,
            body: const SizedBox.expand(key: ValueKey('config')),
          ),
        ),
      );
      final route = routeOf(tester, find.byKey(const ValueKey('config')));
      expect(DockGeometry.instance.carriesDock(route), isTrue);
      expect(DockGeometry.instance.carriesPet(route), isFalse);
      expect(watch.covered.value, isTrue);
    });
  }

  test('exactly Ajustes, Perfiles, Voz and the Gateway manager opt out', () {
    final optedOut = <String>[
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            file.readAsStringSync().contains('pet: false') &&
            file.readAsStringSync().contains('GeneralDockShell('))
          file.uri.pathSegments.last,
    ]..sort();
    expect(optedOut, [
      'gateway_manager_screen.dart',
      'profiles_screen.dart',
      'settings_screen.dart',
      'voice_settings_screen.dart',
    ]);
  });
}
