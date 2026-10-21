// Someone who updates from a bridge-era install and has no working Dashboard
// sign-in is told once, through the notice lane, with one action. Never a
// screen, never again once dismissed or solved.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/legacy_bridge_notices.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/legacy_bridge_retirement.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};

  setUp(() {
    // Not about the Gateway era: its photo is already taken, and empty.
    SharedPreferences.setMockInitialValues({
      'gateway_era_notice_v1': '{"snapshot":[]}',
    });
    secureStore.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
  });

  final navigatorKey = GlobalKey<NavigatorState>();

  Future<ConnectionManager> pumpApp(
    WidgetTester tester, {
    Locale locale = const Locale('es'),
    int connections = 1,
  }) async {
    final manager = (await tester.runAsync(() async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      for (var i = 1; i <= connections; i++) {
        await manager.upsertConnection(
          SavedConnection(
            id: 'c$i',
            label: 'Casa $i',
            host: 'c$i.invalid',
            port: 8642,
            apiKey: 'gateway-key',
            useHttps: true,
          ),
        );
      }
      await manager.setActiveConnection('c1');
      return manager;
    }))!;
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        locale: locale,
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        builder: (context, page) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: page!,
        ),
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

  IslandEvent? said() =>
      HermesNotice.feedOf(navigatorKey.currentContext!)?.current;
  final signInNotice = find.byKey(
    const ValueKey('legacy-bridge-sign-in-notice'),
  );

  LegacyBridgeRetirement legacy(
    SharedPreferences prefs,
    DashboardAccess verdict,
  ) => LegacyBridgeRetirement(prefs: prefs, probe: (_) async => verdict);

  testWidgets('one calm notice, one action, and solving it ends it', (
    tester,
  ) async {
    secureStore[LegacyBridgeRetirement.legacyTokenKey('c1')] = 'retired';
    final manager = await pumpApp(tester);
    final prefs = await SharedPreferences.getInstance();
    final work = legacy(prefs, DashboardAccess.needsSignIn);
    final signedIn = <String>[];

    await tester.runAsync(
      () => LegacyBridgeNotices.start(
        connManager: manager,
        navigator: () => navigatorKey.currentState,
        quiet: () => false,
        retirement: work,
        signIn: (navigator, manager, connection) async {
          signedIn.add(connection.id);
          return true;
        },
      ),
    );
    await settle(tester);

    // The leftovers are gone before anything is said.
    expect(secureStore.keys.where((k) => k.startsWith('bridge_')), isEmpty);
    expect(signInNotice, findsOneWidget);
    expect(said()!.line, 'Falta un paso');
    expect(said()!.action!.label, 'Entrar');
    expect(
      said()!.detail,
      'Entra en el Dashboard de Hermes para usar tareas, perfiles y memoria.',
    );
    // A notice, not a screen: what was on screen is still there.
    expect(find.text('home'), findsOneWidget);
    expect(navigatorKey.currentState!.canPop(), isFalse);

    await tester.tap(find.byKey(const ValueKey('hermes-notice-action')));
    await settle(tester);

    expect(signedIn, ['c1']);
    expect(work.access['c1'], DashboardAccess.ready);
    expect(signInNotice, findsNothing);

    // Never again: not in this launch, not in the next one.
    LegacyBridgeNotices.present(navigatorKey.currentState!, manager, work);
    await settle(tester);
    expect(signInNotice, findsNothing);
    await tester.runAsync(
      () => LegacyBridgeNotices.start(
        connManager: manager,
        navigator: () => navigatorKey.currentState,
        quiet: () => false,
        retirement: legacy(prefs, DashboardAccess.needsSignIn),
      ),
    );
    await settle(tester);
    expect(signInNotice, findsNothing);
  });

  testWidgets('dismissed is dismissed for good; it names the instance when '
      'there are several', (tester) async {
    secureStore[LegacyBridgeRetirement.legacyTokenKey('c2')] = 'retired';
    final manager = await pumpApp(tester, connections: 2);
    final prefs = await SharedPreferences.getInstance();
    final work = legacy(prefs, DashboardAccess.needsSignIn);
    await tester.runAsync(() => work.run(manager.getConnections()));

    final first = LegacyBridgeNotices.present(
      navigatorKey.currentState!,
      manager,
      work,
    );
    await settle(tester);
    expect(signInNotice, findsOneWidget);
    expect(first, isNotNull);
    // The active instance is the one named, in the notice's second line.
    expect(said()!.line, 'Falta un paso');
    expect(said()!.detail, contains('«Casa 1»'));
    expect(said()!.action!.label, 'Entrar');

    first!.dismiss();
    await settle(tester);
    expect(signInNotice, findsNothing);
    expect(work.signInNoticeDone, {'c1'});
    expect(work.access['c1'], DashboardAccess.needsSignIn);

    // The other instance gets its turn on a later launch; c1 never again.
    final second = LegacyBridgeNotices.present(
      navigatorKey.currentState!,
      manager,
      work,
    );
    await settle(tester);
    expect(second, isNotNull);
    expect(said()!.detail, contains('«Casa 2»'));
    second!.dismiss();
    await settle(tester);
    expect(
      LegacyBridgeNotices.present(navigatorKey.currentState!, manager, work),
      isNull,
    );
  });

  testWidgets('nothing is said while the app is locked or in first-run, and '
      'nothing to someone who never had the bridge', (tester) async {
    final manager = await pumpApp(tester, locale: const Locale('en'));
    final prefs = await SharedPreferences.getInstance();

    // Never had the bridge: no probe, no notice.
    var probes = 0;
    await tester.runAsync(
      () => LegacyBridgeNotices.start(
        connManager: manager,
        navigator: () => navigatorKey.currentState,
        quiet: () => false,
        retirement: LegacyBridgeRetirement(
          prefs: prefs,
          probe: (_) async {
            probes++;
            return DashboardAccess.needsSignIn;
          },
        ),
      ),
    );
    await settle(tester);
    expect(probes, 0);
    expect(said(), isNull);

    // A legacy install, but the app is not on screen yet: it waits.
    await prefs.remove(LegacyBridgeRetirement.stateKey);
    secureStore[LegacyBridgeRetirement.legacyTokenKey('c1')] = 'retired';
    var quiet = true;
    var asked = 0;
    final work = legacy(prefs, DashboardAccess.needsSignIn);
    await tester.runAsync(() async {
      final started = LegacyBridgeNotices.start(
        connManager: manager,
        navigator: () => navigatorKey.currentState,
        quiet: () {
          asked++;
          return quiet;
        },
        retirement: work,
        retryEvery: const Duration(milliseconds: 20),
        maxWaits: 200,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(asked, greaterThan(1), reason: 'it kept waiting');
      expect(said(), isNull, reason: 'nothing said while not on screen');
      quiet = false;
      await started;
    });
    await settle(tester);
    expect(signInNotice, findsOneWidget);
    expect(said()!.line, 'One step left');
    expect(said()!.action!.label, 'Sign in');
    expect(
      said()!.detail,
      'Sign in to the Hermes Dashboard to use tasks, profiles and memory.',
    );
  });
}
