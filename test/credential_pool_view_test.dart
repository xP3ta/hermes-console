import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/credential_pool_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/credential_pool_api.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const secretPreview = 'sk-never-render-this';

  DashboardClient client(List<http.Request> calls, {int status = 200}) =>
      DashboardClient(
        host: 'hermes.example.test',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          calls.add(request);
          return http.Response(
            status == 200
                ? jsonEncode({
                    'providers': [
                      {
                        'provider': 'nous',
                        'entries': [
                          {
                            'index': 1,
                            'id': 'primary',
                            'label': 'Primary',
                            'auth_type': 'api_key',
                            'source': 'profile',
                            'priority': 10,
                            'last_status': 'ok',
                            'request_count': 7,
                            'token_preview': secretPreview,
                            'has_refresh': false,
                          },
                        ],
                      },
                    ],
                  })
                : '',
            status,
          );
        }),
      );

  test('parser drops token_preview', () {
    final pool = CredentialPool.fromJson({
      'providers': [
        {
          'provider': 'nous',
          'entries': [
            {'index': 1, 'token_preview': secretPreview},
          ],
        },
      ],
    });

    expect(
      pool.providers.single.entries.single.toString(),
      isNot(contains(secretPreview)),
    );
  });

  testWidgets('loads once and never renders a token preview', (tester) async {
    final calls = <http.Request>[];
    final dashboard = client(calls);
    addTearDown(dashboard.close);
    final connection = SavedConnection(
      id: 'server-a',
      label: 'Server',
      host: 'hermes.example.test',
      port: 5000,
      apiKey: 'test-token',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: CredentialPoolScreen(
          connection: connection,
          profile: 'team one',
          clientForTesting: dashboard,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.url.queryParameters, {'profile': 'team one'});
    expect(find.text('Primary'), findsOneWidget);
    expect(find.textContaining(secretPreview), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(PopupMenuButton), findsNothing);
  });

  test('404 hides the capability', () async {
    final calls = <http.Request>[];
    final dashboard = client(calls, status: 404);
    addTearDown(dashboard.close);

    expect(await dashboard.getCredentialPool(), isNull);
  });
}
