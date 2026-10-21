// LEG2: someone who updates from the Gateway era is told once, through the
// notice lane, how to turn the Dashboard on. Synthetic fixtures only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/legacy_bridge_notices.dart';
import 'package:hermes_android/core/screens/onboarding/manual_setup_page.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_era_notice.dart';
import 'package:hermes_android/core/services/hermes_setup_commands.dart';
import 'package:hermes_android/core/services/legacy_bridge_retirement.dart';
import 'package:hermes_android/core/services/official_dashboard_command.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final navKey = GlobalKey<NavigatorState>();
  final verdicts = <DashboardAccess>[];
  var probes = 0;
  var signIns = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      LegacyBridgeRetirement.stateKey: '{"legacy":false}',
    });
    verdicts.clear();
    probes = signIns = 0;
    FlutterSecureStorage.setMockInitialValues({});
  });

  SavedConnection conn(String id, String key, [String label = 'Nueva']) =>
      SavedConnection(
        id: id,
        label: label,
        host: '192.0.2.10',
        port: 8642,
        apiKey: key,
        useHttps: true,
      );

  Future<DashboardAccess> probe(SavedConnection _) async {
    probes++;
    return verdicts.isEmpty ? DashboardAccess.unknown : verdicts.removeAt(0);
  }

  Future<ConnectionManager> pump(
    WidgetTester tester, {
    List<String> keys = const ['test-key'],
    Locale locale = const Locale('es'),
  }) async {
    final manager = (await tester.runAsync(() async {
      final m = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      for (var i = 0; i < keys.length; i++) {
        await m.upsertConnection(conn('c${i + 1}', keys[i], 'Casa ${i + 1}'));
      }
      if (keys.isNotEmpty) await m.setActiveConnection('c1');
      return m;
    }))!;
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        locale: locale,
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const Scaffold(body: Center(child: Text('home'))),
      ),
    );
    return manager;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// One app launch: a fresh era object over the same stored state.
  Future<void> start(
    ConnectionManager m, {
    bool Function()? quiet,
    DashboardAccess bridge = DashboardAccess.unknown,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await LegacyBridgeNotices.start(
      connManager: m,
      navigator: () => navKey.currentState,
      quiet: quiet ?? () => false,
      retirement: LegacyBridgeRetirement(
        prefs: prefs,
        probe: (_) async => bridge,
      ),
      gatewayEra: GatewayEraNotice(prefs: prefs, probe: probe),
      signIn: (nav, manager, connection) async => ++signIns > 0,
      retryEvery: const Duration(milliseconds: 10),
      maxWaits: 50,
    );
  }

  Future<void> launch(
    WidgetTester tester,
    ConnectionManager m, {
    DashboardAccess bridge = DashboardAccess.unknown,
  }) async {
    await tester.runAsync(() => start(m, bridge: bridge));
    await settle(tester);
  }

  final notice = find.byKey(const ValueKey('gateway-era-notice'));
  final help = find.byType(ManualSetupPage);
  IslandEvent? said() => HermesNotice.feedOf(navKey.currentContext!)?.current;

  Future<Set<String>> done() async {
    final prefs = await SharedPreferences.getInstance();
    final state = jsonDecode(prefs.getString(GatewayEraNotice.stateKey)!);
    return ((state as Map)['done'] as List? ?? []).cast<String>().toSet();
  }

  Future<void> dismiss(WidgetTester tester) async {
    HermesNotice.feedOf(navKey.currentContext!)!.dismiss(said()!);
    await settle(tester);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }

  /// Nothing said, and the probe has run [n] times in all.
  void silent(int n) {
    expect(notice, findsNothing);
    expect(probes, n);
  }

  testWidgets('1: notice, then the guided page with the setup command', (
    tester,
  ) async {
    final manager = await pump(tester);
    await launch(tester, manager);
    expect(notice, findsOneWidget);
    expect(said()!.line, 'Console ha cambiado');
    expect(
      said()!.detail,
      'Console ahora usa el Dashboard de Hermes. Te guiamos en un paso: '
      'pega una línea en tu ordenador y escanea el código. Tus chats se '
      'quedan.',
    );
    expect(find.text('home'), findsOneWidget);
    await tapKey(tester, 'hermes-notice-action');
    expect(help, findsOneWidget);
    expect(find.text('Conecta tu Hermes'), findsOneWidget);
    expect(
      find.text(dashboardSetupCommand(SetupHostSystem.unix)),
      findsOneWidget,
    );
    expect(find.text(kOfficialDashboardCommand), findsNothing);
    expect(find.textContaining('0.0.0.0'), findsNothing);
  });

  testWidgets('1b: key read from Keystore, not cache', (tester) async {
    final manager = await pump(tester, keys: ['']);
    // The manager cache holds ''; only the Keystore has the key.
    await tester.runAsync(
      () => const FlutterSecureStorage().write(
        key: 'api_key_c1',
        value: 'test-key',
      ),
    );
    await launch(tester, manager);
    expect(notice, findsOneWidget);
  });

  testWidgets('2: ready is closed in silence', (tester) async {
    verdicts.add(DashboardAccess.ready);
    final manager = await pump(tester);
    await launch(tester, manager);
    silent(1);
    expect(await done(), {'c1'});
    await launch(tester, manager);
    silent(1);
  });

  testWidgets('3: needs sign-in: «Falta un paso»', (tester) async {
    verdicts.add(DashboardAccess.needsSignIn);
    final manager = await pump(tester);
    await launch(tester, manager);
    expect(said()!.line, 'Falta un paso');
    expect(said()!.action!.label, 'Entrar');
    await tapKey(tester, 'hermes-notice-action');
    expect(signIns, 1);
    expect(help, findsNothing);
  });

  testWidgets('4: added after the photo: never told', (tester) async {
    final manager = await pump(tester, keys: []);
    await launch(tester, manager);
    await tester.runAsync(() => manager.upsertConnection(conn('c9', 'k')));
    await launch(tester, manager);
    silent(0);
  });

  testWidgets('5: empty key says nothing', (tester) async {
    final manager = await pump(tester, keys: ['']);
    await launch(tester, manager);
    silent(0);
  });

  testWidgets('6: ✕ and opening the page are for good', (tester) async {
    final manager = await pump(tester, keys: ['test-key', 'test-key']);
    await launch(tester, manager);
    await dismiss(tester); // ✕ on c1.
    await launch(tester, manager);
    await tapKey(tester, 'hermes-notice-action'); // c2's guided page.
    expect(help, findsOneWidget);
    navKey.currentState!.pop();
    await settle(tester);
    expect(help, findsNothing);
    await launch(tester, manager);
    silent(2);
    expect(await done(), {'c1', 'c2'});
  });

  testWidgets('8: bridge first; LEG2 never repeats', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      LegacyBridgeRetirement.legacyTokenKey('c1'): 'retired',
    });
    SharedPreferences.setMockInitialValues({});
    final manager = await pump(tester);
    await launch(tester, manager, bridge: DashboardAccess.needsSignIn);
    expect(said()!.line, 'Falta un paso');
    silent(0);
    await dismiss(tester); // The bridge marks c1 in sign_in_done.
    await launch(tester, manager, bridge: DashboardAccess.needsSignIn);
    silent(0);
    expect(await done(), {'c1'});
  });

  testWidgets('9: quiet waits, then appears', (tester) async {
    final manager = await pump(tester);
    var quiet = true;
    late Future<void> started;
    await tester.runAsync(() async {
      started = start(manager, quiet: () => quiet);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(said(), isNull);
      expect(probes, 0);
      quiet = false;
      await started;
    });
    await settle(tester);
    expect(notice, findsOneWidget);
  });

  testWidgets('10: two: one per launch, named', (tester) async {
    final manager = await pump(tester, keys: ['test-key', 'test-key']);
    await launch(tester, manager);
    expect(said()!.id, 'gateway-era-c1');
    await dismiss(tester);
    await launch(tester, manager);
    expect(said()!.id, 'gateway-era-c2');
    expect(probes, 2);
  });

  test('11: no new text mentions Gateway, 8642 or "works"', () {
    // «works» as a word: the firewall hint says «private networks».
    final bad = RegExp(
      r'gateway|8642|funciona|\bworks\b',
      caseSensitive: false,
    );
    for (final lang in ['es', 'en']) {
      final arb = jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync());
      final texts = [
        for (final e in (arb as Map).entries)
          if ((e.key.startsWith('gatewayEra') || e.key.startsWith('leg3')) &&
              e.value is String)
            e.value,
      ];
      // Title and action of the notice, its body, the page and the rest.
      expect(texts.length, 7);
      for (final text in texts) {
        expect(text, isNot(matches(bad)));
      }
    }
  });
}
