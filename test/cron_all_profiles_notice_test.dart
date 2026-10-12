import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

DashboardClient _client() => DashboardClient(
  host: 'hermes.local',
  manualToken: 'token',
  httpClientOverride: MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
      final all = request.url.queryParameters['profile'] == 'all';
      return http.Response(
        jsonEncode([
          {
            'id': all ? 'all-job' : 'active-job',
            'name': all ? 'Other profile job' : 'Active job',
            'profile': all ? 'research' : 'default',
            'enabled': true,
          },
        ]),
        200,
      );
    }
    return http.Response('{}', 404);
  }),
);

Future<void> _pump(WidgetTester tester, {required bool readOnly}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  await DockPreferencesController.instance.setUseDock(true);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: CronScreen(
        connection: SavedConnection(
          id: 'cron-all-scope',
          label: 'QA',
          host: 'hermes.local',
          port: 8642,
          apiKey: '',
          useHttps: true,
          readOnly: readOnly,
        ),
        connManager: manager,
        clientOverride: _client(),
        profileOverride: 'research',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapDockCreate(WidgetTester tester) async {
  final create = find.byKey(const ValueKey('general-mode-dock-create'));
  expect(create, findsOneWidget);
  await tester.tap(create);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'dock + in the All profiles view does not call a writable instance '
    'read-only',
    (tester) async {
      await _pump(tester, readOnly: false);
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(find.text('Other profile job'), findsOneWidget);

      await _tapDockCreate(tester);

      expect(find.text('Read-only instance — action disabled'), findsNothing);
      expect(
        find.text(
          'All profiles is a read-only view. Switch to “This profile” to '
          'create or edit tasks.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('cron-prompt-field')), findsNothing);
      await tester.pumpAndSettle(const Duration(seconds: 10));
    },
  );

  testWidgets('a read-only instance still reports itself as read-only', (
    tester,
  ) async {
    await _pump(tester, readOnly: true);

    await _tapDockCreate(tester);

    expect(find.text('Read-only instance — action disabled'), findsOneWidget);
    expect(find.byKey(const ValueKey('cron-prompt-field')), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });
}
