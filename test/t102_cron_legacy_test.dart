import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

SavedConnection _connection() => SavedConnection(
  id: 't102-cron-legacy',
  label: 'T102 Cron legacy',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'gateway-key',
  useHttps: true,
);

Widget _host(DashboardClient client) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: CronScreen(connection: _connection(), clientOverride: client),
);

void main() {
  testWidgets('payload Cron legacy funciona sin campos opcionales 0.19', (
    tester,
  ) async {
    var reads = 0;
    final legacyJob = <String, dynamic>{
      'id': 'legacy-daily',
      'name': 'Legacy daily',
      'prompt': 'Create the daily report',
      'schedule': '0 7 * * *',
      'enabled': true,
    };
    final client = DashboardClient(
      host: 'hermes.local',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
          reads++;
          return http.Response(jsonEncode([legacyJob]), 200);
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    expect(reads, 1);
    expect(find.text('Legacy daily'), findsOneWidget);
    expect(find.text('Create the daily report'), findsOneWidget);
    // Spec 080: the schedule reads as human text from the real expression.
    expect(find.textContaining('Every day at 7:00'), findsOneWidget);
    expect(find.textContaining('delivery:'), findsNothing);
    expect(find.textContaining('model:'), findsNothing);
    expect(find.textContaining('provider:'), findsNothing);
    expect(find.textContaining('context:'), findsNothing);
    expect(find.textContaining('folder:'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
