// SPDX-License-Identifier: GPL-3.0-only
// C2a: which sign-in the Dashboard screen offers, decided from the public
// /api/status + /api/auth/providers (synthetic fixtures only).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _browser = ValueKey('dashboard-oauth-browser');
const _usePassword = ValueKey('dashboard-use-password-here');
const _submit = ValueKey('dashboard-login-submit');

Map<String, Object?> _provider(
  String name, {
  bool password = false,
  bool? session,
}) => {
  'name': name,
  'supports_password': password,
  'supports_session': ?session,
};

Future<List<Uri>> _pump(
  WidgetTester tester, {
  required List<String> flows,
  required List<Map<String, Object?>> providers,
  String locale = 'en',
}) async {
  final opened = <Uri>[];
  final client = MockClient((r) async {
    if (r.url.path == '/api/status') {
      return http.Response(
        jsonEncode({'auth_required': true, 'auth_flows': flows}),
        200,
      );
    }
    expect(r.url.path, '/api/auth/providers');
    return http.Response(jsonEncode({'providers': providers}), 200);
  });
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: DashboardSetupScreen(
          browserFirst: true,
          connection: SavedConnection(
            id: 'c2a',
            label: 'Fixture',
            host: '127.0.0.1',
            port: 9131,
            apiKey: 'synthetic',
            dashboardUrl: 'http://127.0.0.1:19119',
          ),
          authorityCurrent: () => true,
          openOAuthBrowser: (url) async {
            opened.add(url);
            return false;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }, () => client);
  return opened;
}

void main() {
  testWidgets(
    'basic + native_pkce: password form first, browser is the other',
    (tester) async {
      await _pump(
        tester,
        flows: ['native_pkce'],
        providers: [_provider('basic', password: true)],
      );
      expect(find.byKey(const ValueKey('onb2-user')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('onb2-password-submit')),
        findsOneWidget,
      );
      expect(find.byKey(_browser), findsOneWidget);
      expect(find.text('Sign in with your browser'), findsOneWidget);
      expect(find.byKey(_usePassword), findsNothing);
      expect(find.byKey(_submit), findsNothing);
    },
  );

  testWidgets('Spanish copy', (tester) async {
    await _pump(
      tester,
      locale: 'es',
      flows: ['native_pkce'],
      providers: [_provider('basic', password: true)],
    );
    expect(find.text('Entrar con el navegador'), findsOneWidget);
    expect(
      find.textContaining('el usuario y la contraseña que te mostró'),
      findsOneWidget,
    );
  });

  testWidgets('no native_pkce (older Hermes): form only, as today', (
    tester,
  ) async {
    await _pump(
      tester,
      flows: const [],
      providers: [_provider('basic', password: true)],
    );
    expect(find.byKey(_browser), findsNothing);
    expect(find.byKey(_usePassword), findsNothing);
    expect(find.byKey(_submit), findsOneWidget);
  });

  testWidgets('several providers: one browser button, no provider param', (
    tester,
  ) async {
    final opened = await _pump(
      tester,
      flows: ['native_pkce'],
      providers: [_provider('basic', password: true), _provider('nous')],
    );
    expect(find.byKey(_browser), findsOneWidget);
    await tester.tap(find.byKey(_browser));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(opened, hasLength(1));
    expect(opened.single.path, '/auth/native/authorize');
    expect(opened.single.queryParameters.containsKey('provider'), isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('drain alone: no browser button', (tester) async {
    await _pump(
      tester,
      flows: ['native_pkce'],
      providers: [_provider('drain', session: false)],
    );
    expect(find.byKey(_browser), findsNothing);
  });
}
