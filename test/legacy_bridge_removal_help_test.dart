// A legacy install that already talks to Hermes directly is told once that
// the bridge is no longer needed, and shown how to stop and remove ONLY the
// bridge on the computer: the installer's own one line per system, with the
// steps by hand one tap away. The phone removes nothing and asks nobody to.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/legacy_bridge_notices.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/official_dashboard_command.dart';
import 'package:hermes_android/core/services/legacy_bridge_retirement.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dashboard_password_help.dart';
import 'package:hermes_android/core/widgets/legacy_bridge_removal_help.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  String? copied;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStore.clear();
    copied = null;
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
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
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  final navigatorKey = GlobalKey<NavigatorState>();

  Future<ConnectionManager> pumpApp(WidgetTester tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1200);
    addTearDown(tester.view.reset);
    final manager = (await tester.runAsync(() async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await manager.upsertConnection(
        SavedConnection(
          id: 'c1',
          label: 'Casa',
          host: 'c1.invalid',
          port: 8642,
          apiKey: 'gateway-key',
          useHttps: true,
        ),
      );
      await manager.setActiveConnection('c1');
      return manager;
    }))!;
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('es'),
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

  Future<LegacyBridgeRetirement> legacyAndDirect(
    WidgetTester tester,
    ConnectionManager manager,
  ) async {
    secureStore[LegacyBridgeRetirement.legacyTokenKey('c1')] = 'retired';
    final work = LegacyBridgeRetirement(
      prefs: await SharedPreferences.getInstance(),
      probe: (_) async => DashboardAccess.ready,
    );
    await tester.runAsync(() => work.run(manager.getConnections()));
    return work;
  }

  test(
    'the recommended way is the old assistant taking back its own bridge',
    () {
      const raw = 'https://raw.githubusercontent.com/xP3ta/hermes-setup/main';
      const unix =
          'curl -fsSL $raw/hermes-mobile-setup.sh | sh -s -- --retire-bridge';
      expect(bridgeRetireCommand(BridgeHost.linux), unix);
      expect(bridgeRetireCommand(BridgeHost.macos), unix);
      expect(
        bridgeRetireCommand(BridgeHost.windows),
        '& ([scriptblock]::Create((irm $raw/hermes-mobile-setup.ps1))) '
        '-RetireBridge',
      );
      for (final host in BridgeHost.values) {
        final command = bridgeRetireCommand(host);
        expect(command, isNot(contains('\n')));
        expect(command, isNot(contains('sudo')));
        // The flag is what keeps it from being a plain (re)install.
        expect(command.toLowerCase(), matches(RegExp(r'retire-?bridge$')));
      }
    },
  );

  test('the steps by hand name the bridge and nothing else it created', () {
    expect(bridgeRemovalCommands.keys, BridgeHost.values);
    expect(
      bridgeRemovalCommands[BridgeHost.linux],
      'systemctl --user disable --now hermes-bridge.service\n'
      'rm -f ~/.config/systemd/user/hermes-bridge.service\n'
      'systemctl --user daemon-reload',
    );
    expect(
      bridgeRemovalCommands[BridgeHost.macos],
      'launchctl bootout gui/\$(id -u)/dev.xpetalab.hermes-console.bridge\n'
      'rm -f ~/Library/LaunchAgents/dev.xpetalab.hermes-console.bridge.plist',
    );
    expect(
      bridgeRemovalCommands[BridgeHost.windows],
      'Stop-ScheduledTask -TaskName HermesConsole-MobileBridge\n'
      'Unregister-ScheduledTask -TaskName HermesConsole-MobileBridge '
      '-Confirm:\$false\n'
      'Unregister-ScheduledTask -TaskName HermesConsole-Restart-MobileBridge '
      '-Confirm:\$false',
    );
    for (final command in bridgeRemovalCommands.values) {
      for (final other in [
        'hermes-gateway',
        'hermes-dashboard',
        'console.gateway',
        'console.dashboard',
        'HermesConsole-Gateway',
        'HermesConsole-Dashboard',
        'HermesConsole-Restart-Dashboard',
        'hermes-agent',
        'curl',
        'iex',
        'sudo',
      ]) {
        expect(command, isNot(contains(other)), reason: other);
      }
    }
  });

  testWidgets('said once, with how to remove it per system, to copy', (
    tester,
  ) async {
    final manager = await pumpApp(tester);
    final work = await legacyAndDirect(tester, manager);

    final handle = LegacyBridgeNotices.present(
      navigatorKey.currentState!,
      manager,
      work,
    );
    await settle(tester);
    expect(handle, isNotNull);
    final said = HermesNotice.feedOf(navigatorKey.currentContext!)!.current!;
    expect(said.line, 'Ya no necesitas el bridge');
    expect(said.detail, 'Console habla ahora directamente con Hermes.');
    expect(said.action!.label, 'Ver cómo quitarlo');
    expect(said.dismissLabel, 'Ahora no');
    expect(find.text('home'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('hermes-notice-action')));
    await settle(tester);

    expect(find.byKey(const ValueKey('bridge-removal-help')), findsOneWidget);
    expect(find.text('Quitar el bridge'), findsOneWidget);
    expect(find.text(bridgeRetireCommand(BridgeHost.linux)), findsOneWidget);
    expect(
      find.text(
        'Solo quita el bridge. Hermes y esta app siguen funcionando igual.',
      ),
      findsOneWidget,
    );
    // The steps by hand stay folded until asked for.
    expect(
      find.byKey(const ValueKey('bridge-removal-manual-command')),
      findsNothing,
    );
    // Two things to tap in the sheet: copy, and "do it by hand". Nothing
    // offers to remove it for you.
    final sheet = find.byKey(const ValueKey('bridge-removal-help'));
    expect(
      find.descendant(
        of: sheet,
        matching: find.byWidgetPredicate((w) => w is TextButton),
      ),
      findsNWidgets(2),
    );
    expect(
      find.descendant(
        of: sheet,
        matching: find.byWidgetPredicate(
          (w) => w is FilledButton || w is ElevatedButton,
        ),
      ),
      findsNothing,
    );
    await tester.tap(find.text('Copiar'));
    await settle(tester);
    expect(copied, bridgeRetireCommand(BridgeHost.linux));
    expect(copied, endsWith('| sh -s -- --retire-bridge'));

    await tester.tap(find.byKey(const ValueKey('bridge-removal-macos')));
    await settle(tester);
    expect(find.text(bridgeRetireCommand(BridgeHost.macos)), findsOneWidget);
    expect(
      find.text('Pégalo en la Terminal de ese ordenador.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('bridge-removal-windows')));
    await settle(tester);
    expect(find.text(bridgeRetireCommand(BridgeHost.windows)), findsOneWidget);
    expect(find.text('Pégalo en PowerShell en ese ordenador.'), findsOneWidget);
    await tester.tap(find.text('Copiar'));
    await settle(tester);
    expect(copied, bridgeRetireCommand(BridgeHost.windows));
    expect(copied, endsWith(' -RetireBridge'));

    // By hand: the same system's own steps, as a second block to copy.
    await tester.ensureVisible(
      find.byKey(const ValueKey('bridge-removal-by-hand')),
    );
    await tester.tap(find.byKey(const ValueKey('bridge-removal-by-hand')));
    await settle(tester);
    // The block that just unfolded is brought into view by the sheet itself.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Hacerlo a mano'), findsOneWidget);
    expect(
      find.text(bridgeRemovalCommands[BridgeHost.windows]!),
      findsOneWidget,
    );
    expect(find.text(bridgeRetireCommand(BridgeHost.windows)), findsOneWidget);
    final manualCopy = find.descendant(
      of: find.byKey(const ValueKey('bridge-removal-manual-command')),
      matching: find.text('Copiar'),
    );
    await tester.tap(manualCopy);
    await settle(tester);
    expect(copied, bridgeRemovalCommands[BridgeHost.windows]);

    // Never again.
    expect(work.removalNoticeDone, isTrue);
    expect(
      LegacyBridgeNotices.present(navigatorKey.currentState!, manager, work),
      isNull,
    );
  });

  testWidgets('«Ahora no» is final, and a waiting sign-in goes first', (
    tester,
  ) async {
    final manager = await pumpApp(tester);
    final prefs = await SharedPreferences.getInstance();
    secureStore[LegacyBridgeRetirement.legacyTokenKey('c1')] = 'retired';
    final work = LegacyBridgeRetirement(
      prefs: prefs,
      probe: (_) async => DashboardAccess.needsSignIn,
    );
    await tester.runAsync(() => work.run(manager.getConnections()));

    // While the instance still needs its sign-in, only that is said.
    final step = LegacyBridgeNotices.present(
      navigatorKey.currentState!,
      manager,
      work,
    );
    await settle(tester);
    expect(
      find.byKey(const ValueKey('legacy-bridge-sign-in-notice')),
      findsOneWidget,
    );
    expect(
      HermesNotice.feedOf(navigatorKey.currentContext!)!.current!.line,
      'Falta un paso',
    );
    await tester.runAsync(() => work.markSignInNoticeDone('c1', solved: true));
    step!.dismiss();
    await settle(tester);

    final removal = LegacyBridgeNotices.present(
      navigatorKey.currentState!,
      manager,
      work,
    );
    await settle(tester);
    expect(
      find.byKey(const ValueKey('legacy-bridge-removal-notice')),
      findsOneWidget,
    );
    expect(
      HermesNotice.feedOf(navigatorKey.currentContext!)!.current!.line,
      'Ya no necesitas el bridge',
    );
    removal!.dismiss();
    await settle(tester);

    expect(work.removalNoticeDone, isTrue);
    expect(find.byKey(const ValueKey('bridge-removal-help')), findsNothing);
    expect(
      LegacyBridgeNotices.present(navigatorKey.currentState!, manager, work),
      isNull,
    );
  });

  testWidgets('"I don\'t know the password": Hermes\' own two commands, and '
      'the two lines by hand behind a tap', (tester) async {
    await pumpApp(tester);
    showDashboardPasswordHelp(navigatorKey.currentContext!);
    await settle(tester);

    final sheet = find.byKey(const ValueKey('dashboard-password-help'));
    expect(sheet, findsOneWidget);
    expect(find.text('Poner una contraseña nueva'), findsOneWidget);
    // One recipe, no per-system tabs and no installer line.
    expect(find.text('Mac o Linux'), findsNothing);
    expect(find.text(kOfficialDashboardResetCommand), findsOneWidget);
    expect(kOfficialDashboardResetCommand, endsWith(kOfficialDashboardCommand));
    expect(
      find.text(
        'Pega estas tres líneas en la Terminal de ese ordenador. Te pedirá un '
        'usuario y una contraseña nuevos; después úsalos aquí, en Console.',
      ),
      findsOneWidget,
    );
    // It says the other devices keep their session (D-C3-4).
    expect(
      find.text(
        'Los otros móviles y navegadores siguen con la sesión abierta: '
        'cambiar la contraseña no la cierra.',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    // By hand stays folded: no .env lines until asked for.
    expect(
      find.byKey(const ValueKey('dashboard-password-manual-command')),
      findsNothing,
    );
    await tester.tap(find.text('Copiar'));
    await settle(tester);
    expect(copied, kOfficialDashboardResetCommand);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('dashboard-password-by-hand')),
      200,
      scrollable: find
          .descendant(of: sheet, matching: find.byType(Scrollable))
          .first,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('dashboard-password-by-hand')),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('dashboard-password-by-hand')));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
    final manual = find.byKey(
      const ValueKey('dashboard-password-manual-command'),
      skipOffstage: false,
    );
    expect(manual, findsOneWidget);
    expect(
      find.textContaining(
        'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    final manualCopy = find.descendant(
      of: manual,
      matching: find.text('Copiar'),
    );
    await tester.tap(manualCopy);
    await settle(tester);
    expect(
      copied,
      'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin\n'
      'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=tu-contrasena-nueva',
    );
  });
}
