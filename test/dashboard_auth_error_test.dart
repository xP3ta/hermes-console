import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/utils/api_error.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<DashboardAuthException> passwordLoginFailure(
  http.Response response,
) async {
  DashboardClient.resetSharedPasswordSessionsForTesting();
  final client = DashboardClient(
    host: 'hermes.local',
    port: 9119,
    basicUser: 'admin',
    basicPass: 'secret',
    httpClientOverride: MockClient((request) async {
      expect(request.url.path, '/auth/password-login');
      return response;
    }),
  );
  addTearDown(client.close);
  try {
    await client.authHeadersForDiagnostics();
  } on DashboardAuthException catch (error) {
    return error;
  }
  throw TestFailure('Expected DashboardAuthException');
}

Widget localizedFailureHost(Locale locale, List<Object> errors) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => Column(
          children: [
            for (final error in errors)
              Text(localizedApiError(Strings.of(context), error)),
          ],
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dashboard WebSocket ticket fallback', () {
    test('falls back to a legacy token only for 404 and 405', () async {
      for (final status in const [404, 405]) {
        var ticketRequests = 0;
        final client = DashboardClient(
          host: 'hermes.local',
          manualToken: 'legacy-test-token',
          httpClientOverride: MockClient((request) async {
            expect(request.url.path, '/api/auth/ws-ticket');
            ticketRequests++;
            return http.Response('unsupported', status);
          }),
        );
        addTearDown(client.close);

        final auth = await client.webSocketAuth();

        expect(auth.queryName, 'token');
        expect(auth.credential, 'legacy-test-token');
        expect(ticketRequests, 1);
      }
    });

    test('401 and 403 become unavailable and never token-fallback', () async {
      for (final status in const [401, 403]) {
        final client = DashboardClient(
          host: 'hermes.local',
          manualToken: 'legacy-test-token',
          httpClientOverride: MockClient(
            (_) async => http.Response('credentials rejected', status),
          ),
        );
        addTearDown(client.close);

        await expectLater(
          client.webSocketAuth(),
          throwsA(
            isA<DashboardWebSocketAuthException>()
                .having(
                  (error) => error.code,
                  'code',
                  DashboardWebSocketAuthFailureCode.unavailable,
                )
                .having((error) => error.statusCode, 'statusCode', status),
          ),
        );
      }
    });

    test('429 and 5xx become the same safe unavailable failure', () async {
      final limited = DashboardClient(
        host: 'hermes.local',
        manualToken: 'legacy-test-token',
        httpClientOverride: MockClient(
          (_) async => http.Response('rate-limited detail', 429),
        ),
      );
      final unavailable = DashboardClient(
        host: 'hermes.local',
        manualToken: 'legacy-test-token',
        httpClientOverride: MockClient(
          (_) async => http.Response('internal detail', 503),
        ),
      );
      addTearDown(limited.close);
      addTearDown(unavailable.close);

      await expectLater(
        limited.webSocketAuth(),
        throwsA(
          isA<DashboardWebSocketAuthException>().having(
            (error) => error.code,
            'code',
            DashboardWebSocketAuthFailureCode.unavailable,
          ),
        ),
      );
      await expectLater(
        unavailable.webSocketAuth(),
        throwsA(
          isA<DashboardWebSocketAuthException>()
              .having(
                (error) => error.code,
                'code',
                DashboardWebSocketAuthFailureCode.unavailable,
              )
              .having((error) => error.statusCode, 'statusCode', 503),
        ),
      );
    });

    test(
      'client exceptions become unavailable without leaking details',
      () async {
        const secret = 'ws-client-secret';
        final client = DashboardClient(
          host: 'hermes.local',
          manualToken: 'legacy-test-token',
          httpClientOverride: MockClient((request) async {
            throw http.ClientException(
              'transport leaked $secret and a raw response body',
              request.url,
            );
          }),
        );
        addTearDown(client.close);

        await expectLater(
          client.webSocketAuth(),
          throwsA(
            isA<DashboardWebSocketAuthException>()
                .having(
                  (error) => error.code,
                  'code',
                  DashboardWebSocketAuthFailureCode.unavailable,
                )
                .having(
                  (error) => error.toString(),
                  'safe message',
                  DashboardWebSocketAuthFailureCode.unavailable.stableCode,
                )
                .having(
                  (error) => error.toString(),
                  'no secret',
                  isNot(contains(secret)),
                )
                .having(
                  (error) => error.toString(),
                  'no base URL',
                  isNot(contains('hermes.local')),
                ),
          ),
        );
      },
    );

    test('token discovery failures become unavailable without leaks', () async {
      const secret = 'legacy-token-discovery-secret';
      final client = DashboardClient(
        host: 'hermes.local',
        basicUser: 'admin',
        basicPass: 'password',
        httpClientOverride: MockClient((request) async {
          if (request.url.path == '/auth/password-login') {
            return http.Response(
              '{"ok":true}',
              200,
              headers: {
                'set-cookie': 'hermes_session_at=session-cookie; Path=/',
              },
            );
          }
          if (request.url.path == '/api/auth/ws-ticket') {
            return http.Response('unsupported body', 404);
          }
          expect(request.url.path, '/');
          throw http.ClientException(
            'token discovery leaked $secret and raw body',
            request.url,
          );
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.webSocketAuth(),
        throwsA(
          isA<DashboardWebSocketAuthException>()
              .having(
                (error) => error.code,
                'code',
                DashboardWebSocketAuthFailureCode.unavailable,
              )
              .having(
                (error) => error.toString(),
                'safe message',
                DashboardWebSocketAuthFailureCode.unavailable.stableCode,
              )
              .having(
                (error) => error.toString(),
                'no secret',
                isNot(contains(secret)),
              )
              .having(
                (error) => error.toString(),
                'no base URL',
                isNot(contains('hermes.local')),
              ),
        ),
      );
    });

    test(
      'programmer StateError is not reclassified as transport failure',
      () async {
        final client = DashboardClient(
          host: 'hermes.local',
          manualToken: 'legacy-test-token',
          httpClientOverride: MockClient((_) async {
            throw StateError('programmer invariant');
          }),
        );
        addTearDown(client.close);

        await expectLater(client.webSocketAuth(), throwsA(isA<StateError>()));
      },
    );

    test(
      'timeouts and malformed responses become unavailable without fallback',
      () async {
        final timedOut = DashboardClient(
          host: 'hermes.local',
          manualToken: 'legacy-test-token',
          httpClientOverride: MockClient(
            (_) async => throw TimeoutException('synthetic timeout detail'),
          ),
        );
        final malformed = DashboardClient(
          host: 'hermes.local',
          manualToken: 'legacy-test-token',
          httpClientOverride: MockClient((_) async => http.Response('{}', 200)),
        );
        addTearDown(timedOut.close);
        addTearDown(malformed.close);

        await expectLater(
          timedOut.webSocketAuth(),
          throwsA(
            isA<DashboardWebSocketAuthException>().having(
              (error) => error.code,
              'code',
              DashboardWebSocketAuthFailureCode.unavailable,
            ),
          ),
        );
        await expectLater(
          malformed.webSocketAuth(),
          throwsA(
            isA<DashboardWebSocketAuthException>().having(
              (error) => error.code,
              'code',
              DashboardWebSocketAuthFailureCode.unavailable,
            ),
          ),
        );
      },
    );
    test('typed ticket failures use the closed transport cause', () async {
      final failures = <Object>[
        TimeoutException('timeout detail'),
        const SocketException('socket detail'),
        const HandshakeException('handshake detail'),
        http.ClientException('client detail'),
      ];
      for (final failure in failures) {
        final client = DashboardClient(
          host: 'hermes.local',
          manualToken: 'legacy-test-token',
          httpClientOverride: MockClient((_) async => throw failure),
        );
        addTearDown(client.close);

        await expectLater(
          client.mintWsTicket(),
          throwsA(
            isA<DashboardWebSocketAuthException>()
                .having((error) => error.statusCode, 'statusCode', isNull)
                .having(
                  (error) => error.cause,
                  'cause',
                  DashboardWebSocketAuthFailureCause.transport,
                ),
          ),
        );
      }
    });

    test(
      'missing ticket uses malformed while legacy construction is unknown',
      () async {
        final client = DashboardClient(
          host: 'hermes.local',
          manualToken: 'legacy-test-token',
          httpClientOverride: MockClient((_) async => http.Response('{}', 200)),
        );
        addTearDown(client.close);

        await expectLater(
          client.mintWsTicket(),
          throwsA(
            isA<DashboardWebSocketAuthException>()
                .having((error) => error.statusCode, 'statusCode', isNull)
                .having(
                  (error) => error.cause,
                  'cause',
                  DashboardWebSocketAuthFailureCause.malformed,
                ),
          ),
        );
        expect(
          const DashboardWebSocketAuthException(
            DashboardWebSocketAuthFailureCode.unavailable,
          ).cause,
          DashboardWebSocketAuthFailureCause.unknown,
        );
      },
    );
  });

  test('loginRequired se produce por señal real del Dashboard', () async {
    final client = DashboardClient(
      host: 'hermes.local',
      port: 9119,
      httpClientOverride: MockClient((request) async {
        expect(request.url.path, '/');
        return http.Response('<form id="provider-form"></form>', 200);
      }),
    );
    addTearDown(client.close);

    await expectLater(
      client.authHeadersForDiagnostics(),
      throwsA(
        isA<DashboardAuthException>().having(
          (error) => error.code,
          'code',
          DashboardAuthFailureCode.loginRequired,
        ),
      ),
    );
  });

  test(
    '401, 429, fallo HTTP y cookie ausente tienen códigos estables',
    () async {
      final invalid = await passwordLoginFailure(http.Response('', 401));
      final limited = await passwordLoginFailure(http.Response('', 429));
      final failed = await passwordLoginFailure(http.Response('', 503));
      final noCookie = await passwordLoginFailure(
        http.Response('{"ok":true}', 200),
      );

      expect(invalid.code, DashboardAuthFailureCode.invalidCredentials);
      expect(invalid.statusCode, 401);
      expect(limited.code, DashboardAuthFailureCode.rateLimited);
      expect(limited.statusCode, 429);
      expect(failed.code, DashboardAuthFailureCode.loginFailed);
      expect(failed.statusCode, 503);
      expect(noCookie.code, DashboardAuthFailureCode.sessionCookieMissing);
      expect(noCookie.statusCode, 200);
    },
  );

  testWidgets('los fallos se presentan mediante ARB en español e inglés', (
    tester,
  ) async {
    const errors = [
      DashboardAuthException(DashboardAuthFailureCode.loginRequired),
      DashboardAuthException(
        DashboardAuthFailureCode.invalidCredentials,
        statusCode: 401,
      ),
      DashboardAuthException(
        DashboardAuthFailureCode.rateLimited,
        statusCode: 429,
      ),
      DashboardAuthException(
        DashboardAuthFailureCode.loginFailed,
        statusCode: 503,
      ),
      DashboardAuthException(
        DashboardAuthFailureCode.sessionCookieMissing,
        statusCode: 200,
      ),
    ];

    await tester.pumpWidget(localizedFailureHost(const Locale('es'), errors));
    await tester.pumpAndSettle();
    expect(find.textContaining('requiere iniciar sesión'), findsOneWidget);
    expect(find.textContaining('usuario o la contraseña'), findsOneWidget);
    expect(find.textContaining('temporalmente bloqueado'), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsOneWidget);
    expect(find.textContaining('no creó una sesión'), findsOneWidget);
    expect(find.textContaining('DashboardAuthException'), findsNothing);

    await tester.pumpWidget(localizedFailureHost(const Locale('en'), errors));
    await tester.pumpAndSettle();
    expect(find.textContaining('requires sign-in'), findsOneWidget);
    expect(find.textContaining('username or password'), findsOneWidget);
    expect(find.textContaining('temporarily blocked'), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsOneWidget);
    expect(find.textContaining('did not create a session'), findsOneWidget);
    expect(find.textContaining('DashboardAuthException'), findsNothing);
  });

  testWidgets('el aviso de auth del chat está localizado en ES y EN', (
    tester,
  ) async {
    Widget host(Locale locale) => MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Builder(
        builder: (context) =>
            Text(Strings.of(context).chaDesktopAuthRequiredBanner),
      ),
    );

    await tester.pumpWidget(host(const Locale('es')));
    expect(
      find.textContaining('Tu historial sigue disponible'),
      findsOneWidget,
    );

    await tester.pumpWidget(host(const Locale('en')));
    expect(
      find.textContaining('Your transcript remains available'),
      findsOneWidget,
    );
  });

  testWidgets(
    'Bridge y validación cron no filtran literales españoles en inglés',
    (tester) async {
      final errors = <Object>[
        const BridgeException(
          'cron_remove_unconfirmed',
          'El bridge no confirmó la eliminación del cron.',
        ),
        const BridgeException(
          'attachment_too_large',
          'El adjunto está vacío o supera el límite permitido.',
        ),
        const BridgeException(
          'image_invalid_type',
          'El servidor no devolvió una imagen.',
        ),
        const BridgeException(
          'remote_auth_copy',
          'Token inválido',
          kind: BridgeErrorKind.auth,
        ),
        ArgumentError.value('../job', 'jobId'),
        ArgumentError.value('../profile', 'profile'),
      ];

      await tester.pumpWidget(localizedFailureHost(const Locale('en'), errors));
      await tester.pumpAndSettle();

      expect(find.textContaining('did not confirm'), findsOneWidget);
      expect(
        find.textContaining('attachment is empty or too large'),
        findsOneWidget,
      );
      expect(find.textContaining('did not return an image'), findsOneWidget);
      expect(find.textContaining('token or permissions'), findsOneWidget);
      expect(
        find.textContaining('scheduled task identifier is invalid'),
        findsOneWidget,
      );
      expect(
        find.textContaining('scheduled-task profile is invalid'),
        findsOneWidget,
      );
      for (final spanish in const [
        'El bridge',
        'adjunto está',
        'El servidor',
        'Token inválido',
        'ID de cron',
        'Perfil de cron',
      ]) {
        expect(find.textContaining(spanish), findsNothing);
      }
    },
  );

  test('las superficies auditadas usan el presentador localizado', () {
    for (final path in const [
      'lib/core/screens/cron_screen.dart',
      'lib/core/screens/soul_screen.dart',
      'lib/core/screens/models_screen.dart',
      'lib/core/screens/dashboard_setup_screen.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('localizedApiError('),
        reason: path,
      );
    }
  });
}
