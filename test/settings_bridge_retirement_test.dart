import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/settings/settings_sections.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'Bridge maintenance retired while official Hermes update stays executable',
    (tester) async {
      SharedPreferences.setMockInitialValues({'hermes_auto_update': false});
      final secure = <String, String>{};
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args = (call.arguments as Map?) ?? {};
              if (call.method == 'write') secure[args['key']] = args['value'];
              if (call.method == 'read') return secure[args['key']];
              if (call.method == 'readAll') return secure;
              if (call.method == 'delete') secure.remove(args['key']);
              return null;
            },
          );
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      addTearDown(manager.dispose);
      final conn = SavedConnection(
        id: 'maintenance',
        label: 'Existing',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'synthetic-gateway',
        dashboardAuthMode: AuthMode.sessionToken,
        dashboardUrl: 'http://127.0.0.1:19119',
      );
      await manager.upsertConnection(conn);
      await manager.setDashboardSecrets(
        conn.id,
        sessionToken: 'synthetic-dashboard',
      );
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <http.Request>[];
      final client = MockClient((r) async {
        requests.add(r);
        if (r.url.path == '/api/status') {
          return http.Response('{"gateway_running":true,"version":"old"}', 200);
        }
        if (r.url.path == '/api/hermes/update/check') {
          return http.Response(
            '{"update_available":true,"behind":1,"can_apply":true,"install_method":"git","current_version":"old"}',
            200,
          );
        }
        // The action really crosses the official mutation boundary; this fixture
        // rejects it, so no monitor or backend restart is fabricated.
        if (r.url.path == '/api/hermes/update' && r.method == 'POST') {
          return http.Response(
            '{"ok":false,"message":"Synthetic update refused"}',
            200,
          );
        }
        return http.Response('{}', 404);
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            theme: AppTheme.hermesRedDark,
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: SettingsScreen(connection: conn, connManager: manager),
          ),
        );
        await tester.pumpAndSettle();
        final system = find.byKey(
          ValueKey('settings-category-${SettingsSection.system.name}'),
        );
        await tester.tap(system);
        await tester.pumpAndSettle();
        final strings = Strings.of(tester.element(find.byType(SettingsScreen)));
        final apply = find.text(strings.setApply);
        expect(apply, findsOneWidget);
        await tester.ensureVisible(apply);
        await tester.tap(apply);
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.setUpdate).last);
        await tester.pumpAndSettle();
        expect(
          requests.where(
            (r) => r.url.path == '/api/hermes/update' && r.method == 'POST',
          ),
          hasLength(1),
        );
        expect(
          requests.where((r) => r.url.path.startsWith('/bridge/')),
          isEmpty,
        );
        expect(
          find.byKey(const ValueKey('settings-category-bridge')),
          findsNothing,
        );
        expect(
          prefs.getKeys().any(
            (k) => '${prefs.get(k)}'.contains('synthetic-dashboard'),
          ),
          isFalse,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }, () => client);
    },
  );
}
