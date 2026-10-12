import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  final capturedLogs = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStore.clear();
    capturedLogs.clear();
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
              case 'deleteAll':
                secureStore.clear();
                return null;
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
  });

  Future<void> pumpEditor(
    WidgetTester tester,
    ConnectionManager manager, {
    SavedConnection? initial,
    PairingLink? initialLink,
    bool fromDeepLink = false,
    ConnectionDiagnostics? diagnostics,
  }) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: InstanceEditScreen(
          connManager: manager,
          initial: initial,
          initialLink: initialLink,
          fromDeepLink: fromDeepLink,
          diagnostics: diagnostics,
        ),
      ),
    );
  }

  Future<void> revealAndTapSave(WidgetTester tester) async {
    final save = find.byKey(const ValueKey('instance-save')).last;
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'blank secret fields preserve rotations made while editor is open',
    (tester) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      await manager.upsertConnection(
        SavedConnection(
          id: 'edit-rotation',
          label: 'Example',
          host: 'example.invalid',
          port: 443,
          useHttps: true,
          apiKey: 'original-test-key',
        ),
      );
      await manager.setDashboardSecrets(
        'edit-rotation',
        username: 'old-user',
        password: 'old-test-pass',
      );
      await pumpEditor(
        tester,
        manager,
        initial: manager.getConnections().single,
      );
      await tester.pumpAndSettle();
      await manager.updateApiKey('edit-rotation', 'rotated-test-key');
      await manager.setDashboardSecrets(
        'edit-rotation',
        username: 'new-user',
        password: 'new-test-pass',
      );
      await revealAndTapSave(tester);
      expect(manager.getConnections().single.apiKey, 'rotated-test-key');
      final secrets = await manager.getDashboardSecrets('edit-rotation');
      expect(secrets.username, 'new-user');
      expect(secrets.password, 'new-test-pass');
    },
  );

  testWidgets('deep link externo pide permiso antes de automatizar', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    const link = PairingLink(
      host: 'hermes.example.test',
      port: 8642,
      token: 'test-token',
      useHttps: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: InstanceEditScreen(
          connManager: manager,
          initialLink: link,
          fromDeepLink: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Revisar este enlace'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('hermes-dialog')),
        matching: find.textContaining('hermes.example.test'),
      ),
      findsOneWidget,
    );
    expect(find.text('Solo revisar'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('hermes-dialog')),
        matching: find.text('Probar conexión'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Solo revisar'));
    await tester.pumpAndSettle();
    expect(find.text('Revisar este enlace'), findsNothing);
    expect(find.text('https://hermes.example.test:8642'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('un QR repetido avisa y permite actualizar sin duplicar', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    await manager.upsertConnection(
      SavedConnection(
        id: 'demo',
        label: 'Server',
        host: 'hermes.example.test',
        port: 443,
        apiKey: 'old-token',
        useHttps: true,
      ),
    );
    const link = PairingLink(
      host: 'HERMES.EXAMPLE.TEST',
      port: 443,
      token: 'rotated-token',
      useHttps: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: InstanceEditScreen(connManager: manager, initialLink: link),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    expect(find.text('Esta instancia ya está configurada'), findsOneWidget);
    expect(find.textContaining('Server'), findsOneWidget);
    expect(find.textContaining('hermes.example.test'), findsOneWidget);
    expect(find.text('Abrir existente'), findsOneWidget);
    expect(find.text('Actualizar datos'), findsOneWidget);
    expect(manager.getConnections(), hasLength(1));

    await tester.tap(find.text('Actualizar datos'));
    await tester.pumpAndSettle();

    expect(find.text('Esta instancia ya está configurada'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(HermesAppBar),
        matching: find.text('Server'),
      ),
      findsOneWidget,
    );
    expect(manager.getConnections(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('deep link externo mantiene todo el flujo en inglés', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    const link = PairingLink(
      host: 'hermes.example.test',
      port: 8642,
      token: 'test-token',
      useHttps: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: InstanceEditScreen(
          connManager: manager,
          initialLink: link,
          fromDeepLink: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Review this link'), findsOneWidget);
    expect(find.text('Review only'), findsOneWidget);
    expect(find.text('Revisar este enlace'), findsNothing);

    await tester.tap(find.text('Review only'));
    await tester.pumpAndSettle();

    expect(find.text('Connect manually'), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-link-summary')), findsOneWidget);
    expect(find.textContaining('Datos rellenados'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy QR saves only official Gateway credentials', (
    tester,
  ) async {
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) capturedLogs.add(message);
    };
    try {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final link = PairingLink.tryParse(
        'hermes://pair?host=fixture.invalid&port=8642&token=synthetic-gateway-canary&https=1&bridge=https%3A%2F%2Fretired.invalid&bridge_token=synthetic-retired-canary',
      )!;
      await pumpEditor(tester, manager, initialLink: link, fromDeepLink: true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Solo revisar'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('instance-bridge-token')), findsNothing);
      expect(find.byKey(const ValueKey('instance-bridge-url')), findsNothing);
      await revealAndTapSave(tester);
      final saved = manager.getConnections().single;
      expect(saved.apiKey, 'synthetic-gateway-canary');
      expect(saved.gatewayUrl, 'https://fixture.invalid:8642');
      expect(secureStore['api_key_${saved.id}'], 'synthetic-gateway-canary');
      expect(
        secureStore.keys.where((key) => key.startsWith('bridge_')),
        isEmpty,
      );
      // Raw legacy canary never enters storage, prefs, or visible editor text.
      final retired = ['synthetic', 'retired', 'canary'].join('-');
      expect(
        secureStore.values.any((value) => value.contains(retired)),
        isFalse,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().any(
          (key) => prefs.get(key).toString().contains(retired),
        ),
        isFalse,
      );
      expect(find.textContaining(retired), findsNothing);
      expect(capturedLogs.any((value) => value.contains(retired)), isFalse);
    } finally {
      debugPrint = originalDebugPrint;
    }
  });

  group('a pairing link can carry the Dashboard sign-in', () {
    final secret = ['dashboard', 'login', 'canary'].join('-');
    String linkWithLogin() =>
        'hermes://pair?host=fixture.invalid&port=8642'
        '&token=synthetic-gateway-canary&https=1'
        '&dashboard=https%3A%2F%2Ffixture.invalid%3A9119'
        '&dash_user=owner&dash_pass=$secret';

    void expectSecretNeverShown(WidgetTester tester) {
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').contains(secret),
        ),
        findsNothing,
      );
      expect(
        tester
            .widgetList<EditableText>(find.byType(EditableText))
            .where((field) => field.controller.text.contains(secret))
            .every((field) => field.obscureText),
        isTrue,
      );
    }

    testWidgets('the confirmation names it and saving fills the sign-in '
        'slots, nothing else', (tester) async {
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) capturedLogs.add(message);
      };
      try {
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        final link = PairingLink.tryParse(linkWithLogin())!;
        await pumpEditor(
          tester,
          manager,
          initialLink: link,
          fromDeepLink: true,
        );
        await tester.pumpAndSettle();
        // Before anything is accepted, the dialog says what gets set up.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('hermes-dialog')),
            matching: find.textContaining(
              'y el usuario y la contraseña de su Dashboard',
            ),
          ),
          findsOneWidget,
        );
        expectSecretNeverShown(tester);
        await tester.tap(find.text('Solo revisar'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('pairing-link-summary')),
          findsOneWidget,
        );
        expectSecretNeverShown(tester);

        await revealAndTapSave(tester);
        final saved = manager.getConnections().single;
        expect(saved.dashboardAuthMode, AuthMode.basicAuth);
        expect(saved.dashboardUrl, 'https://fixture.invalid:9119');
        // The same Keystore slots the Dashboard sign-in screen writes.
        expect(secureStore['dash_user_${saved.id}'], 'owner');
        expect(secureStore['dash_pass_${saved.id}'], secret);
        final stored = await manager.getDashboardSecrets(saved.id);
        expect(stored.username, 'owner');
        expect(stored.password, secret);
        expect(
          secureStore.entries
              .where((e) => e.value.contains(secret))
              .map((e) => e.key),
          ['dash_pass_${saved.id}'],
        );
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getKeys().any(
            (key) => prefs.get(key).toString().contains(secret),
          ),
          isFalse,
        );
        expect(capturedLogs.any((line) => line.contains(secret)), isFalse);
      } finally {
        debugPrint = originalDebugPrint;
      }
    });

    testWidgets('a scanned code is confirmed in the editor and probes only '
        'the server it names', (tester) async {
      final hosts = <String>{};
      final diagnostics = ConnectionDiagnostics(
        httpClient: MockClient((request) async {
          hosts.add(request.url.host);
          expect(request.url.path.startsWith('/bridge/'), isFalse);
          return http.Response('{}', 404);
        }),
      );
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await pumpEditor(
        tester,
        manager,
        initialLink: PairingLink.tryParse(linkWithLogin())!,
        diagnostics: diagnostics,
      );
      await tester.pumpAndSettle();
      // No dialog for a code the user scanned or pasted: the editor itself
      // is the confirmation, and it says the same sentence.
      expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
      expect(
        find.textContaining('y el usuario y la contraseña de su Dashboard'),
        findsOneWidget,
      );
      expectSecretNeverShown(tester);
      expect(hosts.difference({'fixture.invalid'}), isEmpty);

      await revealAndTapSave(tester);
      final saved = manager.getConnections().single;
      expect(saved.dashboardAuthMode, AuthMode.basicAuth);
      expect(secureStore['dash_pass_${saved.id}'], secret);
    });

    testWidgets('pointing the form at another server drops it unsaved', (
      tester,
    ) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await pumpEditor(
        tester,
        manager,
        initialLink: PairingLink.tryParse(linkWithLogin())!,
        fromDeepLink: true,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Solo revisar'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('instance-gateway-url')),
        'https://elsewhere.invalid:8642',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pairing-link-summary')), findsNothing);

      await revealAndTapSave(tester);
      final saved = manager.getConnections().single;
      expect(saved.host, 'elsewhere.invalid');
      expect(saved.dashboardAuthMode, isNot(AuthMode.basicAuth));
      expect(secureStore.keys.where((k) => k.startsWith('dash_')), isEmpty);
      expect(secureStore.values.any((v) => v.contains(secret)), isFalse);
    });

    testWidgets('a link without it sets up the Gateway only, as before', (
      tester,
    ) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await pumpEditor(
        tester,
        manager,
        initialLink: PairingLink.tryParse(
          'hermes://pair?host=fixture.invalid&port=8642'
          '&token=synthetic-gateway-canary&https=1',
        )!,
        fromDeepLink: true,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('hermes-dialog')),
          matching: find.textContaining('la dirección y la clave del chat'),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('usuario y la contraseña de su Dashboard'),
        findsNothing,
      );
      await tester.tap(find.text('Solo revisar'));
      await tester.pumpAndSettle();

      await revealAndTapSave(tester);
      final saved = manager.getConnections().single;
      expect(saved.apiKey, 'synthetic-gateway-canary');
      expect(saved.dashboardAuthMode, isNot(AuthMode.basicAuth));
      expect(secureStore.keys.where((k) => k.startsWith('dash_')), isEmpty);
    });
  });

  testWidgets(
    'QR y reapertura no cambian credenciales Dashboard automáticamente',
    (tester) async {
      final forbiddenRequests = <String>[];
      final diagnostics = ConnectionDiagnostics(
        httpClient: MockClient((request) async {
          if (request.url.path.startsWith('/bridge/')) {
            forbiddenRequests.add(request.url.path);
          }
          if (request.url.path == '/v1/chat/completions') {
            return http.Response('{"error":"empty messages"}', 400);
          }
          if (request.url.path == '/v1/capabilities') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'object': 'hermes.api_server.capabilities',
                'features': <String, Object?>{},
                'endpoints': <String, Object?>{},
              }),
              200,
            );
          }
          if (request.url.path == '/health') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'status': 'ok',
                'platform': 'hermes-agent',
                'version': '0.9.0',
              }),
              200,
            );
          }
          return http.Response('{"ok":true}', 200);
        }),
      );

      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      const link = PairingLink(
        host: '127.0.0.1',
        port: 18642,
        token: 'gateway-token',
      );

      await pumpEditor(
        tester,
        manager,
        initialLink: link,
        diagnostics: diagnostics,
      );
      await tester.pumpAndSettle();

      expect(forbiddenRequests, isEmpty);
      expect(find.text('Entrar en el Dashboard'), findsOneWidget);

      await pumpEditor(
        tester,
        manager,
        initialLink: link,
        diagnostics: diagnostics,
      );
      await tester.pumpAndSettle();

      expect(forbiddenRequests, isEmpty);
    },
  );

  for (final port in [8643, 9131]) {
    testWidgets('manual official localhost port $port is preserved', (
      tester,
    ) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await pumpEditor(tester, manager);
      await tester.enterText(
        find.byKey(const ValueKey('instance-gateway-url')),
        'http://127.0.0.1:$port',
      );
      // The private-network note appears under the address and moves the rows
      // below it: let that frame pass before typing into the next field.
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('instance-gateway-token')),
        'synthetic-local-canary',
      );
      await revealAndTapSave(tester);
      final saved = manager.getConnections().single;
      expect(saved.gatewayUrl, 'http://127.0.0.1:$port');
      expect(saved.apiKey, 'synthetic-local-canary');
      expect(
        secureStore.keys.where((key) => key.startsWith('bridge_')),
        isEmpty,
      );
    });
  }

  testWidgets(
    'repeated legacy QR rotates Gateway without touching retired credentials',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      await manager.upsertConnection(
        SavedConnection(
          id: 'existing',
          label: 'Existing',
          host: '100.90.80.70',
          port: 8642,
          apiKey: 'old-token',
        ),
      );
      secureStore['bridge_token_existing'] = 'synthetic-retired-canary';
      const link = PairingLink(
        host: '100.90.80.70',
        port: 8642,
        token: 'rotated-token',
      );

      await pumpEditor(tester, manager, initialLink: link, fromDeepLink: true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actualizar datos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Solo revisar'));
      await tester.pumpAndSettle();

      await revealAndTapSave(tester);

      expect(manager.getConnections(), hasLength(1));
      expect(manager.getConnections().single.apiKey, 'rotated-token');
      expect(secureStore['bridge_token_existing'], 'synthetic-retired-canary');
    },
  );
}
