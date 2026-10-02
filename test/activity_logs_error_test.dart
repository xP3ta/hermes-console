import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/activity_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Dashboard client whose log read always fails with [error].
class _FailingLogsClient extends DashboardClient {
  _FailingLogsClient(this.error)
    : super(
        host: 'hermes.local',
        manualToken: 'token',
        httpClientOverride: MockClient((_) async => http.Response('{}', 500)),
      );

  final Object error;

  @override
  Future<List<String>> getLogs({
    String file = 'agent',
    int lines = 200,
    String? level,
    String? search,
  }) async => throw error;
}

Future<void> _pump(WidgetTester tester, Object error) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: ActivityScreen(
        connection: SavedConnection(
          id: 'activity-logs',
          label: 'QA',
          host: 'hermes.local',
          port: 8642,
          apiKey: '',
          useHttps: true,
        ),
        clientOverride: _FailingLogsClient(error),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a rejected Dashboard login shows the localized reason', (
    tester,
  ) async {
    await _pump(
      tester,
      const DashboardAuthException(
        DashboardAuthFailureCode.invalidCredentials,
        statusCode: 401,
      ),
    );
    final s = await Strings.delegate.load(const Locale('es'));

    expect(find.text(s.actLogsReadError), findsOneWidget);
    expect(find.text(s.dashboardAuthInvalidCredentials), findsOneWidget);
    expect(find.textContaining('invalid_credentials'), findsNothing);
    expect(find.textContaining('HTTP 401'), findsNothing);
  });
}
