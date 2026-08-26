import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
    BridgeClientFactory? bridgeClientFactory,
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
          bridgeClientFactory: bridgeClientFactory,
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
    await tester.pump();

    expect(find.text('Autoconfigurar esta instancia'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('hermes.example.test'),
      ),
      findsOneWidget,
    );
    expect(find.text('Solo revisar'), findsOneWidget);
    expect(find.text('Continuar automáticamente'), findsOneWidget);

    await tester.tap(find.text('Solo revisar'));
    await tester.pump();
    expect(find.text('Autoconfigurar esta instancia'), findsNothing);
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
    await tester.pump();
    await tester.pump();

    expect(find.text('Esta instancia ya está configurada'), findsOneWidget);
    expect(find.textContaining('Server'), findsOneWidget);
    expect(find.textContaining('hermes.example.test:443'), findsOneWidget);
    expect(find.text('Abrir existente'), findsOneWidget);
    expect(find.text('Actualizar datos'), findsOneWidget);
    expect(manager.getConnections(), hasLength(1));

    await tester.tap(find.text('Actualizar datos'));
    await tester.pumpAndSettle();

    expect(find.text('Esta instancia ya está configurada'), findsNothing);
    expect(find.text('Editar instancia'), findsOneWidget);
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
    await tester.pump();

    expect(find.text('Automatically configure this instance'), findsOneWidget);
    expect(find.text('Review only'), findsOneWidget);
    expect(find.text('Autoconfigurar esta instancia'), findsNothing);

    await tester.tap(find.text('Review only'));
    await tester.pump();

    expect(find.text('New instance'), findsOneWidget);
    expect(
      find.textContaining('Details pre-filled from an external link'),
      findsOneWidget,
    );
    expect(find.textContaining('Datos rellenados'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QR guarda API key y token del Bridge en Keystore', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    const link = PairingLink(
      host: '100.90.80.70',
      port: 8642,
      token: 'shared-setup-token',
      bridgeUrl: 'http://100.90.80.70:19131',
      bridgeToken: 'dedicated-bridge-token',
    );

    // El deep link y el escáner convergen en el mismo _applyLink. Usamos el
    // consentimiento "solo revisar" para mantener esta prueba 100 % sin red.
    await pumpEditor(tester, manager, initialLink: link, fromDeepLink: true);
    await tester.pump();
    await tester.tap(find.text('Solo revisar'));
    await tester.pump();

    await tester.ensureVisible(
      find.byKey(const ValueKey('instance-bridge-token')),
    );
    final bridgeField = tester.widget<TextField>(
      find.byKey(const ValueKey('instance-bridge-token')),
    );
    expect(bridgeField.controller?.text, 'dedicated-bridge-token');

    await revealAndTapSave(tester);

    final saved = manager.getConnections().single;
    final bridge = await manager.getBridgeConfig(saved.id);
    expect(saved.apiKey, 'shared-setup-token');
    expect(bridge.token, 'dedicated-bridge-token');
    expect(bridge.url, 'http://100.90.80.70:19131');
    expect(secureStore['api_key_${saved.id}'], 'shared-setup-token');
    expect(secureStore['bridge_token_${saved.id}'], 'dedicated-bridge-token');
    expect(secureStore['bridge_url_${saved.id}'], 'http://100.90.80.70:19131');
  });

  testWidgets(
    'QR y reapertura no cambian credenciales Dashboard automáticamente',
    (tester) async {
      var dashboardCredentialWrites = 0;
      Future<http.Response> bridgeResponder(http.Request request) async {
        switch ((request.method, request.url.path)) {
          case ('GET', '/bridge/health'):
            return http.Response(
              jsonEncode(<String, Object?>{
                'status': 'ok',
                'version': '1.18.0',
              }),
              200,
            );
          case ('GET', '/bridge/capabilities'):
            return http.Response(
              jsonEncode(<String, Object?>{
                'object': 'hermes.bridge.capabilities',
                'version': '1.18.0',
                'scopes': <String>['read', 'config'],
                'operations': <String, Object?>{'self_update': true},
              }),
              200,
            );
          case ('GET', '/bridge/dashboard/credentials'):
            return http.Response(
              jsonEncode(<String, Object?>{
                'ok': true,
                'username': 'admin',
                'password_set': true,
                'public_url': '',
              }),
              200,
            );
          case ('POST', '/bridge/dashboard/credentials'):
            dashboardCredentialWrites++;
            return http.Response(
              jsonEncode(<String, Object?>{'ok': true, 'username': 'admin'}),
              200,
            );
          default:
            return http.Response('{}', 404);
        }
      }

      final diagnostics = ConnectionDiagnostics(
        httpClient: MockClient((request) async {
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
      const base = 'http://127.0.0.1:19131';
      const link = PairingLink(
        host: '127.0.0.1',
        port: 18642,
        token: 'gateway-token',
        bridgeUrl: base,
        bridgeToken: 'bridge-token',
      );

      await pumpEditor(
        tester,
        manager,
        initialLink: link,
        diagnostics: diagnostics,
        bridgeClientFactory: ({required baseUrl, required token}) =>
            BridgeClient(
              baseUrl: baseUrl,
              token: token,
              httpClient: MockClient(bridgeResponder),
            ),
      );
      await tester.pumpAndSettle();

      expect(dashboardCredentialWrites, 0);
      expect(
        find.text('Autoconfigurar dashboard (vía bridge)'),
        findsOneWidget,
      );

      await pumpEditor(
        tester,
        manager,
        initialLink: link,
        diagnostics: diagnostics,
        bridgeClientFactory: ({required baseUrl, required token}) =>
            BridgeClient(
              baseUrl: baseUrl,
              token: token,
              httpClient: MockClient(bridgeResponder),
            ),
      );
      await tester.pumpAndSettle();

      expect(dashboardCredentialWrites, 0);
    },
  );

  testWidgets('Instancias permite guardar token y URL manuales del Bridge', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    await pumpEditor(tester, manager);

    await tester.enterText(
      find.byKey(const ValueKey('instance-gateway-url')),
      'http://100.90.80.70:8642',
    );
    await tester.enterText(
      find.byKey(const ValueKey('instance-gateway-token')),
      'gateway-key',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('instance-bridge-token')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('instance-bridge-token')),
      'manual-bridge-token',
    );
    await tester.enterText(
      find.byKey(const ValueKey('instance-bridge-url')),
      'http://100.90.80.70:19131',
    );

    await revealAndTapSave(tester);

    final saved = manager.getConnections().single;
    final bridge = await manager.getBridgeConfig(saved.id);
    expect(bridge.token, 'manual-bridge-token');
    expect(bridge.url, 'http://100.90.80.70:19131');
  });

  testWidgets('editar con token Bridge vacío conserva el secreto anterior', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    await manager.upsertConnection(
      SavedConnection(
        id: 'existing',
        label: 'Existing',
        host: '100.90.80.70',
        port: 8642,
        apiKey: 'gateway-key',
      ),
    );
    await manager.setBridgeConfig(
      'existing',
      token: 'keep-this-token',
      url: 'http://100.90.80.70:19131',
    );

    await pumpEditor(tester, manager, initial: manager.getConnections().single);
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('instance-bridge-token')),
    );

    final tokenField = tester.widget<TextField>(
      find.byKey(const ValueKey('instance-bridge-token')),
    );
    final urlField = tester.widget<TextField>(
      find.byKey(const ValueKey('instance-bridge-url')),
    );
    expect(tokenField.controller?.text, isEmpty);
    expect(urlField.controller?.text, 'http://100.90.80.70:19131');

    await revealAndTapSave(tester);

    final bridge = await manager.getBridgeConfig('existing');
    expect(bridge.token, 'keep-this-token');
    expect(bridge.url, 'http://100.90.80.70:19131');
  });

  testWidgets('QR repetido rota Gateway y Bridge sin duplicar instancia', (
    tester,
  ) async {
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
    await manager.setBridgeConfig('existing', token: 'old-token');
    const link = PairingLink(
      host: '100.90.80.70',
      port: 8642,
      token: 'rotated-token',
    );

    await pumpEditor(tester, manager, initialLink: link, fromDeepLink: true);
    await tester.pump();
    await tester.tap(find.text('Actualizar datos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Solo revisar'));
    await tester.pumpAndSettle();

    await revealAndTapSave(tester);

    expect(manager.getConnections(), hasLength(1));
    expect(manager.getConnections().single.apiKey, 'rotated-token');
    expect((await manager.getBridgeConfig('existing')).token, 'rotated-token');
  });
}
