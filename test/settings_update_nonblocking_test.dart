import 'dart:async';

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

/// PERF-4: the Hermes update check must not hold the System panel hostage.
/// The server status paints the panel; the update row has its own state
/// (checking / current / available / unavailable) with a 6 s visible cap.
const _status = '{"gateway_running":true,"version":"9.9.9"}';

class _Harness {
  _Harness(this.requests);
  final List<http.Request> requests;
  final updateChecks = <Completer<http.Response>>[];
}

Future<void> _mount(
  WidgetTester tester, {
  required Future<http.Response> Function(http.Request request, _Harness h)
  onUpdateCheck,
  bool autoUpdate = false,
  required Future<void> Function(_Harness h, Strings s) body,
}) async {
  SharedPreferences.setMockInitialValues({'hermes_auto_update': autoUpdate});
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
    apiKey: 'synth...ay',
    dashboardAuthMode: AuthMode.sessionToken,
    dashboardUrl: 'http://127.0.0.1:19119',
  );
  await manager.upsertConnection(conn);
  await manager.setDashboardSecrets(conn.id, sessionToken: 'synthetic');
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = _Harness(<http.Request>[]);
  final client = MockClient((r) async {
    h.requests.add(r);
    if (r.url.path == '/api/status') return http.Response(_status, 200);
    if (r.url.path == '/api/hermes/update/check') {
      return onUpdateCheck(r, h);
    }
    if (r.url.path == '/api/hermes/update' && r.method == 'POST') {
      return http.Response('{"ok":false,"message":"refused"}', 200);
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
    final s = Strings.of(tester.element(find.byType(SettingsScreen)));
    await tester.tap(
      find.byKey(ValueKey('settings-category-${SettingsSection.system.name}')),
    );
    // One frame per step: the panel must not need the update check to paint.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await body(h, s);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    expect(tester.takeException(), isNull);
  }, () => client);
}

Future<http.Response> _never(http.Request r, _Harness h) {
  final c = Completer<http.Response>();
  h.updateChecks.add(c);
  return c.future;
}

http.Response _json(String body) => http.Response(body, 200);

void main() {
  testWidgets(
    'the panel paints on the server status while the update check hangs',
    (tester) async {
      await _mount(
        tester,
        onUpdateCheck: _never,
        body: (h, s) async {
          expect(h.updateChecks, hasLength(1));
          // Status answered: no panel-wide spinner, diagnostics are visible.
          expect(find.text(s.setCheckingStatus), findsNothing);
          expect(find.text('gateway'), findsOneWidget);
          expect(find.text(s.setCheckingUpdate), findsOneWidget);
          // 6 s cap: the row degrades to "unavailable" and offers a retry.
          await tester.pump(const Duration(seconds: 6));
          expect(find.text(s.setCheckingUpdate), findsNothing);
          expect(find.text(s.setUpdateCheckFailed('9.9.9')), findsOneWidget);
          expect(find.byKey(const Key('hermes_update_retry')), findsOneWidget);
        },
      );
    },
  );

  testWidgets('a late answer on the same generation still updates the row', (
    tester,
  ) async {
    await _mount(
      tester,
      onUpdateCheck: _never,
      body: (h, s) async {
        await tester.pump(const Duration(seconds: 6));
        expect(find.text(s.setUpdateCheckFailed('9.9.9')), findsOneWidget);
        h.updateChecks.single.complete(
          _json('{"behind":0,"current_version":"9.9.9","can_apply":true}'),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text(s.setVersionCurrent('9.9.9')), findsOneWidget);
      },
    );
  });

  testWidgets('behind: null reads as unavailable, never as up to date', (
    tester,
  ) async {
    await _mount(
      tester,
      onUpdateCheck: (r, h) async => _json('{"behind":null}'),
      body: (h, s) async {
        await tester.pump();
        expect(find.text(s.setUpdateCheckFailed('9.9.9')), findsOneWidget);
        expect(find.text(s.setVersionCurrent('9.9.9')), findsNothing);
      },
    );
  });

  testWidgets('404 keeps the no-remote-update row and 401 asks for access', (
    tester,
  ) async {
    await _mount(
      tester,
      onUpdateCheck: (r, h) async => http.Response('{}', 404),
      body: (h, s) async {
        await tester.pump();
        expect(find.text(s.setNoRemoteUpdate), findsOneWidget);
      },
    );
  });

  testWidgets('401 on the check keeps the dashboard-access row', (
    tester,
  ) async {
    await _mount(
      tester,
      onUpdateCheck: (r, h) async => http.Response('{}', 401),
      body: (h, s) async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text(s.setUpdateDashboardAccessRequired), findsOneWidget);
      },
    );
  });

  testWidgets('an answer from an older generation is ignored', (tester) async {
    await _mount(
      tester,
      onUpdateCheck: _never,
      body: (h, s) async {
        await tester.pump(const Duration(seconds: 6));
        // Retry = new generation with force=true.
        await tester.tap(find.byKey(const Key('hermes_update_retry')));
        await tester.pump();
        expect(h.updateChecks, hasLength(2));
        expect(
          h.requests.last.url.toString(),
          contains('hermes/update/check?force=true'),
        );
        // The old generation answers "3 behind": must not be shown.
        h.updateChecks.first.complete(
          _json(
            '{"behind":3,"update_available":true,"can_apply":true,"current_version":"9.9.9"}',
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.textContaining('3 commits'), findsNothing);
        expect(find.text(s.setCheckingUpdate), findsOneWidget);
        h.updateChecks.last.complete(
          _json('{"behind":0,"current_version":"9.9.9","can_apply":true}'),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text(s.setVersionCurrent('9.9.9')), findsOneWidget);
      },
    );
  });

  testWidgets('auto-update never fires on a timeout or unknown state', (
    tester,
  ) async {
    await _mount(
      tester,
      autoUpdate: true,
      onUpdateCheck: _never,
      body: (h, s) async {
        await tester.pump(const Duration(seconds: 7));
        expect(find.text(s.setUpdateCheckFailed('9.9.9')), findsOneWidget);
        expect(
          h.requests.where(
            (r) => r.url.path == '/api/hermes/update' && r.method == 'POST',
          ),
          isEmpty,
        );
      },
    );
  });

  testWidgets('auto-update fires once the update is confirmed available', (
    tester,
  ) async {
    await _mount(
      tester,
      autoUpdate: true,
      onUpdateCheck: (r, h) async => _json(
        '{"update_available":true,"behind":2,"can_apply":true,"install_method":"git","current_version":"9.9.9"}',
      ),
      body: (h, s) async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(
          h.requests.where(
            (r) => r.url.path == '/api/hermes/update' && r.method == 'POST',
          ),
          hasLength(1),
        );
      },
    );
  });
}
