// SPDX-License-Identifier: GPL-3.0-only
//
// Dashboard sign-in failures: typed causes (HTTP status, auth codes, timeout)
// are told apart with the shared localized presenter, never with a server
// body or exception text; untyped failures, OAuth refusal/cancel and an
// expired authority keep their own specific copy.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _canary = 'synthetic-secret-canary';
const _en = Locale('en');
const _es = Locale('es');

SavedConnection _conn({String url = 'http://127.0.0.1:19119'}) =>
    SavedConnection(
      id: 'localized-owner',
      label: 'Existing',
      host: '127.0.0.1',
      port: 9131,
      apiKey: 'synthetic-gateway',
      dashboardUrl: url,
    );

Widget _host(
  Locale locale, {
  SavedConnection? connection,
  bool Function()? authorityCurrent,
  Future<bool> Function(Uri)? openOAuthBrowser,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: DashboardSetupScreen(
    browserFirst: false,
    connection: connection ?? _conn(),
    authorityCurrent: authorityCurrent ?? () => true,
    openOAuthBrowser: openOAuthBrowser,
  ),
);

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(DashboardSetupScreen)));

String _errorText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('dashboard-login-error')))
    .data!;

const _probePrefix = {
  'en': 'Dashboard authentication could not be verified.',
  'es': 'No se pudo verificar la autenticación del Dashboard.',
};
const _notChanged = {
  'en': 'Server credentials were not changed.',
  'es': 'No se cambiaron credenciales del servidor.',
};
const _loginFallback = {
  'en': 'Login refused or unavailable.',
  'es': 'Inicio de sesión rechazado o no disponible.',
};
const _oauthCopy = {
  'en': 'OAuth refused, cancelled or expired.',
  'es': 'OAuth rechazado, cancelado o caducado.',
};
const _authorityCopy = {
  'en': 'Connection or profile changed.',
  'es': 'La conexión o el perfil cambió.',
};

/// Raw internals that must never reach the user.
const _rawFragments = [
  _canary,
  'HTTP 401',
  'HTTP 403',
  'HTTP 404',
  'HTTP 503',
  'Dashboard status',
  'provider discovery',
  'token authority',
  'password-login unsupported',
  'Native sign-in',
  'Exception',
  'Bad state',
];

void _expectNoRaw(String text) {
  for (final raw in _rawFragments) {
    expect(text, isNot(contains(raw)), reason: text);
  }
}

http.Response _status({bool required = false, List<String>? flows}) =>
    http.Response(
      '{"auth_required":$required'
      '${flows == null ? '' : ',"auth_flows":["${flows.join('","')}"]'}}',
      200,
    );

http.Response _basicProviders() => http.Response(
  '{"providers":[{"name":"basic","supports_password":true}]}',
  200,
);

void main() {
  setUp(DashboardClient.resetSharedPasswordSessionsForTesting);

  group('discovery', () {
    for (final locale in const [_en, _es]) {
      final lang = locale.languageCode;
      for (final c
          in <({String path, int status, String Function(Strings) cause})>[
            (path: '/api/status', status: 503, cause: (s) => s.apiErrorServer),
            (path: '/api/status', status: 403, cause: (s) => s.apiErrorAuth),
            (
              path: '/api/auth/providers',
              status: 404,
              cause: (s) => s.apiErrorNotFound,
            ),
          ]) {
        testWidgets(
          '[$lang] ${c.path} HTTP ${c.status} names its cause without the body',
          (tester) async {
            final client = MockClient((r) async {
              if (r.url.path == c.path) {
                return http.Response(_canary, c.status);
              }
              return _status(required: true);
            });
            await http.runWithClient(() async {
              await tester.pumpWidget(_host(locale));
              await tester.pumpAndSettle();
              final text = _errorText(tester);
              expect(text, startsWith(_probePrefix[lang]!));
              expect(text, contains(c.cause(_strings(tester))));
              _expectNoRaw(text);
              expect(find.text(_strings(tester).commonRetry), findsOneWidget);
              await tester.pumpWidget(const SizedBox.shrink());
            }, () => client);
          },
        );
      }
    }

    testWidgets('a status that never answers is reported as a timeout', (
      tester,
    ) async {
      final held = Completer<http.Response>();
      final client = MockClient((r) => held.future);
      await http.runWithClient(() async {
        await tester.pumpWidget(_host(_en));
        await tester.pump();
        await tester.pump(const Duration(seconds: 9));
        await tester.pump();
        final text = _errorText(tester);
        expect(text, startsWith(_probePrefix['en']!));
        expect(text, contains(_strings(tester).apiErrorTimeout));
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    });

    testWidgets('a malformed answer keeps the fixed discovery copy', (
      tester,
    ) async {
      final client = MockClient(
        (r) async => http.Response('{"auth_required":"$_canary"}', 200),
      );
      await http.runWithClient(() async {
        await tester.pumpWidget(_host(_en));
        await tester.pumpAndSettle();
        final text = _errorText(tester);
        expect(text, 'Dashboard authentication could not be verified. Retry.');
        _expectNoRaw(text);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    });

    testWidgets('waiting for discovery shows the Console loader', (
      tester,
    ) async {
      final held = Completer<http.Response>();
      final client = MockClient((r) => held.future);
      await http.runWithClient(() async {
        await tester.pumpWidget(_host(_en));
        await tester.pump();
        expect(find.byType(ConsoleLoader), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        held.complete(_status());
        await tester.pumpAndSettle();
        expect(find.byType(ConsoleLoader), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    });

    for (final locale in const [_en, _es]) {
      testWidgets(
        '[${locale.languageCode}] public cleartext is refused locally with the '
        'shared cleartext warning',
        (tester) async {
          final requests = <Uri>[];
          final client = MockClient((r) async {
            requests.add(r.url);
            return _status();
          });
          await http.runWithClient(() async {
            await tester.pumpWidget(
              _host(locale, connection: _conn(url: 'http://203.0.113.10:9119')),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(requests, isEmpty);
            expect(_errorText(tester), _strings(tester).commonCleartextPublic);
            expect(
              find.byKey(const ValueKey('dashboard-login-submit')),
              findsNothing,
            );
            await tester.pumpWidget(const SizedBox.shrink());
          }, () => client);
        },
      );
    }
  });

  group('session token sign-in', () {
    for (final locale in const [_en, _es]) {
      final lang = locale.languageCode;
      testWidgets(
        '[$lang] a rejected token names credentials or permissions and keeps '
        'the draft',
        (tester) async {
          final client = MockClient((r) async {
            if (r.url.path == '/api/status') return _status();
            return http.Response('{"detail":"$_canary"}', 401);
          });
          await http.runWithClient(() async {
            await tester.pumpWidget(_host(locale));
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextField), 'synthetic-token');
            await tester.tap(
              find.byKey(const ValueKey('dashboard-login-submit')),
            );
            await tester.pumpAndSettle();
            final text = _errorText(tester);
            expect(text, contains(_strings(tester).apiErrorAuth));
            expect(text, endsWith(_notChanged[lang]!));
            _expectNoRaw(text);
            final field = tester.widget<TextField>(find.byType(TextField));
            expect(field.controller!.text, 'synthetic-token');
            await tester.pumpWidget(const SizedBox.shrink());
          }, () => client);
        },
      );
    }

    testWidgets('an unconfirmed token keeps the fixed sign-in copy', (
      tester,
    ) async {
      final client = MockClient((r) async {
        if (r.url.path == '/api/status') return _status();
        return http.Response('{"profiles":"$_canary"}', 200);
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(_host(_en));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'synthetic-token');
        await tester.tap(find.byKey(const ValueKey('dashboard-login-submit')));
        await tester.pumpAndSettle();
        final text = _errorText(tester);
        expect(text, startsWith(_loginFallback['en']!));
        _expectNoRaw(text);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    });
  });

  group('password sign-in', () {
    for (final c in <({int status, String Function(Strings) cause})>[
      (status: 401, cause: (s) => s.dashboardAuthInvalidCredentials),
      (status: 429, cause: (s) => s.dashboardAuthRateLimited),
    ]) {
      for (final locale in const [_en, _es]) {
        final lang = locale.languageCode;
        testWidgets(
          '[$lang] password-login HTTP ${c.status} keeps its specific auth copy',
          (tester) async {
            final client = MockClient((r) async {
              if (r.url.path == '/api/status') return _status(required: true);
              if (r.url.path == '/api/auth/providers') return _basicProviders();
              expect(r.url.path, '/auth/password-login');
              return http.Response('{"detail":"$_canary"}', c.status);
            });
            await http.runWithClient(() async {
              await tester.pumpWidget(_host(locale));
              await tester.pumpAndSettle();
              final fields = find.byType(TextField);
              await tester.enterText(fields.at(0), 'synthetic-user');
              await tester.enterText(fields.at(1), 'synthetic-password');
              await tester.tap(
                find.byKey(const ValueKey('dashboard-login-submit')),
              );
              await tester.pumpAndSettle();
              final text = _errorText(tester);
              expect(text, startsWith(c.cause(_strings(tester))));
              expect(text, endsWith(_notChanged[lang]!));
              _expectNoRaw(text);
              expect(
                tester.widget<TextField>(fields.at(0)).controller!.text,
                'synthetic-user',
              );
              await tester.pumpWidget(const SizedBox.shrink());
            }, () => client);
          },
        );
      }
    }

    testWidgets('an unsupported password route keeps the fixed copy', (
      tester,
    ) async {
      final client = MockClient((r) async {
        if (r.url.path == '/api/status') return _status(required: true);
        if (r.url.path == '/api/auth/providers') return _basicProviders();
        return http.Response(_canary, 404);
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(_host(_en));
        await tester.pumpAndSettle();
        final fields = find.byType(TextField);
        await tester.enterText(fields.at(0), 'synthetic-user');
        await tester.enterText(fields.at(1), 'synthetic-password');
        await tester.tap(find.byKey(const ValueKey('dashboard-login-submit')));
        await tester.pumpAndSettle();
        final text = _errorText(tester);
        expect(text, startsWith(_loginFallback['en']!));
        _expectNoRaw(text);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    });
  });

  group('specific outcomes are not replaced by the generic presenter', () {
    for (final locale in const [_en, _es]) {
      final lang = locale.languageCode;
      testWidgets('[$lang] OAuth cancelled by the user keeps the OAuth copy', (
        tester,
      ) async {
        final browser = Completer<bool>();
        var launched = false;
        final client = MockClient((r) async {
          if (r.url.path == '/api/status') {
            return _status(required: true, flows: ['native_pkce']);
          }
          return http.Response(
            '{"providers":[{"name":"portal","supports_password":false}]}',
            200,
          );
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            _host(
              locale,
              openOAuthBrowser: (_) {
                launched = true;
                return browser.future;
              },
            ),
          );
          await tester.pumpAndSettle();
          final s = _strings(tester);
          await tester.runAsync(() async {
            await tester.tap(
              find.byKey(const ValueKey('dashboard-oauth-browser')),
            );
            for (var i = 0; i < 100 && !launched; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
          expect(launched, isTrue);
          await tester.pump();
          await tester.tap(find.text(s.commonCancel));
          for (
            var i = 0;
            i < 50 &&
                find
                    .byKey(const ValueKey('dashboard-login-error'))
                    .evaluate()
                    .isEmpty;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          final text = _errorText(tester);
          expect(text, startsWith(_oauthCopy[lang]!));
          for (final generic in [
            s.apiErrorAuth,
            s.apiErrorNetwork,
            s.apiErrorUnknown,
          ]) {
            expect(text, isNot(contains(generic)));
          }
          _expectNoRaw(text);
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      });

      testWidgets(
        '[$lang] a typed failure after the authority changed reports the '
        'authority, not the failure',
        (tester) async {
          var epoch = 0;
          final held = Completer<http.Response>();
          final client = MockClient((r) => held.future);
          await http.runWithClient(() async {
            await tester.pumpWidget(
              _host(locale, authorityCurrent: () => epoch == 0),
            );
            await tester.pump();
            epoch++;
            held.complete(http.Response(_canary, 503));
            await tester.pumpAndSettle();
            final text = _errorText(tester);
            expect(text, startsWith(_authorityCopy[lang]!));
            expect(text, isNot(contains(_strings(tester).apiErrorServer)));
            _expectNoRaw(text);
            await tester.pumpWidget(const SizedBox.shrink());
          }, () => client);
        },
      );
    }
  });

  testWidgets('every visible label follows the app language', (tester) async {
    const englishOnly = [
      'Sign in with system browser',
      'I consent to send',
      'Dashboard session token',
      'This account cannot sign in from the phone',
    ];
    const spanishOnly = [
      'Acceder con navegador del sistema',
      'Acepto enviar',
      'Token de sesión del Dashboard',
      'Esta cuenta no permite entrar desde el móvil',
    ];
    Future<void> render(Locale locale, http.Response status) async {
      final client = MockClient((r) async {
        if (r.url.path == '/api/status') return status;
        return http.Response(
          '{"providers":[{"name":"portal","supports_password":false}]}',
          200,
        );
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          _host(locale, connection: _conn(url: 'http://192.168.1.20:9119')),
        );
        await tester.pumpAndSettle();
      }, () => client);
    }

    String visible() => find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .join('\n');

    for (final status in [
      _status(),
      _status(required: true, flows: ['native_pkce']),
      _status(required: true),
    ]) {
      await render(_es, status);
      final es = visible();
      for (final english in englishOnly) {
        expect(es, isNot(contains(english)), reason: es);
      }
      await render(_en, status);
      final en = visible();
      for (final spanish in spanishOnly) {
        expect(en, isNot(contains(spanish)), reason: en);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
