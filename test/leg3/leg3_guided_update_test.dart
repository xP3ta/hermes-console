// SPDX-License-Identifier: GPL-3.0-only
// LEG3: whoever came with only the Gateway follows the same guided path as
// the onboarding, and scanning the Dashboard code replaces that connection.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_setup_page.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/screens/recover_access_page.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/hermes_setup_commands.dart';
import 'package:hermes_android/core/services/official_dashboard_command.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../onb2q/hermes_shaped_server.dart';
import '../support/onboarding_fakes.dart';

SavedConnection _era(String id, String label, {String host = '127.0.0.1'}) =>
    SavedConnection(
      id: id,
      label: label,
      host: host,
      port: 8642,
      apiKey: 'era-key-$id',
      kind: InstanceKind.homelab,
    );

String _link(String url) =>
    'hermes://pair?v=2&url=${Uri.encodeQueryComponent(url)}'
    '&user=${HermesShapedServer.user}'
    '&pass=${Uri.encodeQueryComponent(HermesShapedServer.pass)}';

Future<String?> _storedKey(String id) =>
    const FlutterSecureStorage().read(key: 'api_key_$id');

/// The guided page (or the onboarding) with a fake camera that "reads" [link]
/// once Scan is pressed. Returns the manager seeded with [seed].
Future<ConnectionManager> _scan(
  WidgetTester tester,
  String link,
  List<SavedConnection> seed, {
  bool guided = true,
  String scanKey = 'onboarding-help-scan',
}) async {
  final manager = await onboardingManager();
  await tester.runAsync(() async {
    for (final c in seed) {
      await manager.upsertConnection(c);
    }
    if (seed.isNotEmpty) await manager.setActiveConnection(seed.first.id);
  });
  ValueChanged<String>? detected;
  await tester.pumpWidget(
    onboardingHost(
      OnboardingScreen(
        guided: guided,
        playOpening: false,
        cameraBuilder: (detect, _) {
          detected = detect;
          return const SizedBox();
        },
        connManager: manager,
        onDone: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (!guided) await _tap(tester, 'onboarding-help');
  await _tap(tester, scanKey);
  detected!(link);
  await tester.pump(const Duration(seconds: 3));
  return manager;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final control = find.byKey(ValueKey(key));
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _connect(WidgetTester tester) async {
  await _tap(tester, 'onboarding-confirm');
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(seconds: 2));
}

Future<String> _everythingPersisted(ConnectionManager manager) async {
  final prefs = await SharedPreferences.getInstance();
  final b = StringBuffer();
  for (final k in prefs.getKeys()) {
    b.write('$k=${prefs.get(k)};');
  }
  for (final c in manager.getConnections()) {
    final s = await manager.getDashboardSecrets(c.id);
    b.write('pw=${s.password};user=${s.username};tok=${s.sessionToken};');
  }
  return b.toString();
}

void main() {
  late HermesShapedServer server;
  setUp(() async {
    HttpOverrides.global = null;
    server = await HermesShapedServer.start();
  });
  tearDown(() async => server.close());

  for (final language in ['es', 'en']) {
    testWidgets('$language: the page is the guided setup, no old command', (
      tester,
    ) async {
      final manager = await onboardingManager();
      await tester.pumpWidget(
        onboardingHost(
          ManualSetupPage(connManager: manager, simpleConnectEnabled: true),
          language: language,
        ),
      );
      await tester.pumpAndSettle();
      final s = Strings.of(tester.element(find.byType(ManualSetupPage)));
      expect(find.text(s.leg3SetupTitle), findsOneWidget);
      expect(find.text(s.leg3SetupBody), findsOneWidget);
      expect(find.text(dashboardSetupCommand(_unix)), findsOneWidget);
      expect(find.text(s.onb4HelpSafeTitle), findsOneWidget);
      expect(find.text(s.onb4HelpVps), findsOneWidget);
      expect(find.byKey(const ValueKey('pairing-helper-copy')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('onboarding-help-scan')),
        findsOneWidget,
      );
      expect(find.textContaining('0.0.0.0'), findsNothing);
      expect(find.textContaining('hermes dashboard'), findsNothing);
      expect(
        tester.widget<OnboardingScreen>(find.byType(OnboardingScreen)).guided,
        isTrue,
      );
    });
  }

  for (final guided in [true, false]) {
    testWidgets('the help lays out with motion on (guided: $guided)', (
      tester,
    ) async {
      final manager = await onboardingManager();
      await tester.pumpWidget(
        onboardingHost(
          OnboardingScreen(
            connManager: manager,
            guided: guided,
            playOpening: false,
            onDone: () {},
          ),
          motion: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      if (!guided) {
        await tester.tap(find.byKey(const ValueKey('onboarding-help')));
        await tester.pump(const Duration(milliseconds: 100));
      }
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('onboarding-help-scan')),
        findsOneWidget,
      );
    });
  }

  testWidgets('the copy is the setup line, not the old command', (
    tester,
  ) async {
    final manager = await onboardingManager();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      onboardingHost(ManualSetupPage(connManager: manager)),
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'pairing-helper-copy');
    expect(copied, dashboardSetupCommand(_unix));
    expect(copied, isNot(contains('0.0.0.0')));
  });

  testWidgets('scanning a v2 code of the same host UPDATES that connection', (
    tester,
  ) async {
    final seed = _era('era1', 'Casa');
    final manager = await _scan(tester, _link(server.url), [seed]);
    expect(await _storedKey('era1'), 'era-key-era1');
    final s = onboardingStrings(tester);
    expect(find.text(s.leg3UpdatesExisting('Casa')), findsOneWidget);
    await _connect(tester);
    final all = manager.getConnections();
    expect(all, hasLength(1));
    final saved = all.single;
    expect(saved.id, 'era1');
    expect(saved.label, 'Casa');
    expect(saved.kind, InstanceKind.homelab);
    expect(saved.apiKey, isEmpty);
    expect(saved.effectiveDashboardUrl, server.url);
    expect(saved.port, Uri.parse(server.url).port);
    expect(await _storedKey('era1'), isNull);
    expect(manager.activeConnectionId.value, 'era1');
    final secrets = await manager.getDashboardSecrets('era1');
    expect(secrets.sessionToken, isNotEmpty);
    expect(secrets.password, isNull);
    expect(
      await _everythingPersisted(manager),
      allOf(isNot(contains('CANARY')), isNot(contains('era-key-era1'))),
    );
    expect(server.tokenPosts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the same update works from the onboarding camera', (
    tester,
  ) async {
    final manager = await _scan(tester, _link(server.url), [
      _era('era1', 'Casa'),
    ], guided: false);
    await _connect(tester);
    expect(manager.getConnections().single.id, 'era1');
    expect(manager.getConnections().single.apiKey, isEmpty);
    expect(await _storedKey('era1'), isNull);
  });

  testWidgets('the host matches without caring about case', (tester) async {
    final manager = await _scan(
      tester,
      _link(server.url.replaceFirst('127.0.0.1', 'localhost')),
      [_era('era1', 'Casa', host: 'LocalHost')],
    );
    await _connect(tester);
    expect(manager.getConnections(), hasLength(1));
    expect(manager.getConnections().single.id, 'era1');
  });

  testWidgets('two Gateway-era connections on the host: none is touched, a '
      'new one is made', (tester) async {
    final manager = await _scan(tester, _link(server.url), [
      _era('era1', 'Casa'),
      _era('era2', 'Oficina'),
    ]);
    final s = onboardingStrings(tester);
    expect(find.textContaining('tus chats se quedan.'), findsNothing);
    expect(find.text(s.leg3UpdatesExisting('Casa')), findsNothing);
    await _connect(tester);
    final all = manager.getConnections();
    expect(all, hasLength(3));
    expect(all.where((c) => c.id == 'era1').single.apiKey, 'era-key-era1');
    expect(all.where((c) => c.id == 'era2').single.apiKey, 'era-key-era2');
    expect(await _storedKey('era1'), 'era-key-era1');
    expect(await _storedKey('era2'), 'era-key-era2');
    expect(manager.activeConnectionId.value, isNot(anyOf('era1', 'era2')));
  });

  testWidgets('no connection of that host: a new one, like before', (
    tester,
  ) async {
    final manager = await _scan(tester, _link(server.url), [
      _era('era9', 'Otra', host: '192.0.2.50'),
    ]);
    await _connect(tester);
    expect(manager.getConnections(), hasLength(2));
    expect(await _storedKey('era9'), 'era-key-era9');
  });

  testWidgets('a Dashboard-only connection at the same address is still '
      'a duplicate', (tester) async {
    final port = Uri.parse(server.url).port;
    final only = SavedConnection(
      id: 'dash1',
      label: 'Panel',
      host: '127.0.0.1',
      port: port,
      apiKey: '',
      dashboardUrl: server.url,
    );
    final manager = await _scan(tester, _link(server.url), [only]);
    final s = onboardingStrings(tester);
    expect(find.text(s.o2DuplicateTitle), findsOneWidget);
    expect(manager.getConnections(), hasLength(1));
    expect(server.requests, isNot(contains('POST /auth/password-login')));
  });

  testWidgets('Recover access speaks of user and password', (tester) async {
    for (final language in ['es', 'en']) {
      await tester.pumpWidget(
        onboardingHost(const RecoverAccessPage(), language: language),
      );
      await tester.pumpAndSettle();
      final s = Strings.of(tester.element(find.byType(RecoverAccessPage)));
      expect(find.text(s.leg3RecoverBody), findsOneWidget);
      expect(
        s.leg3RecoverBody,
        contains(
          language == 'es'
              ? 'usuario y la contraseña'
              : 'username and password',
        ),
      );
    }
  });

  test('the old command is only reachable from the password help', () {
    final users = <String>[
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File &&
            f.path.endsWith('.dart') &&
            !f.path.contains('lib/l10n/') &&
            f.readAsStringSync().contains('kOfficialDashboardCommand'))
          f.path,
    ]..sort();
    expect(users, ['lib/core/services/official_dashboard_command.dart']);
  });

  test('no orphan Gateway-era or setup-steps keys are left', () {
    for (final lang in ['es', 'en']) {
      final arb =
          jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
              as Map<String, dynamic>;
      final src = [
        for (final f in Directory('lib').listSync(recursive: true))
          if (f is File &&
              f.path.endsWith('.dart') &&
              !f.path.contains('lib/l10n/'))
            f.readAsStringSync(),
      ].join('\n');
      for (final key in arb.keys.where((k) => k.startsWith('leg3'))) {
        if (key.startsWith('@')) continue;
        expect(src, contains('.$key'), reason: key);
      }
      for (final gone in [
        'gatewayEraBody',
        'gatewayEraBodyNamed',
        'gatewayEraSheetBody',
        'gatewayEraDone',
        'gatewayEraLater',
        'gatewayEraStillDown',
        'gatewayEraFirewallHint',
        'setupStepsDashboardTitle',
        'setupStepsDashboardRun',
        'setupStepsPrivateOnly',
        'o2DashboardExplain',
        'onb2RecoverBody',
      ]) {
        expect(arb.containsKey(gone), isFalse, reason: '$lang $gone');
      }
    }
  });
}

const _unix = SetupHostSystem.unix;
