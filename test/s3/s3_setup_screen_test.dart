// SPDX-License-Identifier: GPL-3.0-only
// S3: the sign-in screen waits (bounded) for a Dashboard that answers 502/503/
// 504, then retries the original read ONCE. Synthetic fixtures only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_warmup.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _browser = ValueKey('dashboard-oauth-browser');
const _retry = ValueKey('dashboard-probe-retry');

class _Clock {
  DateTime t = DateTime.utc(2026, 10, 18);
  int calls = 0;
  ServerWarmupClock get clock => ServerWarmupClock(
    now: () => t,
    delay: (d) async {
      // A wait without a limit would spin here forever: fail fast instead.
      if (++calls > 400) throw StateError('runaway wait');
      t = t.add(d);
      await Future<void>.value();
    },
  );
}

class _Server {
  _Server({required this.status, required this.health});
  final int Function(int call) status;
  final int Function(int call) health;
  int statusCalls = 0;
  int healthCalls = 0;
  int otherCalls = 0;
  Future<void>? statusGate;
  Future<void>? healthGate;
  Future<http.Response> handle(http.Request r) async {
    if (statusCalls > 50) throw StateError('runaway retry loop');
    switch (r.url.path) {
      case '/api/status':
        await statusGate;
        final code = status(++statusCalls);
        return code == 200
            ? http.Response(
                jsonEncode({
                  'auth_required': true,
                  'auth_flows': ['native_pkce'],
                }),
                200,
              )
            : http.Response('', code);
      case '/api/health':
        await healthGate;
        final code = health(++healthCalls);
        return http.Response(code == 200 ? '{"status":"ok"}' : '', code);
      case '/api/auth/providers':
        return http.Response(
          jsonEncode({
            'providers': [
              {'name': 'basic', 'supports_password': true},
            ],
          }),
          200,
        );
    }
    otherCalls++;
    return http.Response('', 404);
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Server server,
  _Clock clock, {
  bool browserFirst = true,
  String locale = 'en',
  String url = 'http://127.0.0.1:19119',
}) async {
  final client = MockClient(server.handle);
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: DashboardSetupScreen(
          browserFirst: browserFirst,
          warmupClock: clock.clock,
          connection: SavedConnection(
            id: 's3',
            label: 'Fixture',
            host: '127.0.0.1',
            port: 9131,
            apiKey: '',
            dashboardUrl: url,
          ),
          authorityCurrent: () => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }, () => client);
}

void main() {
  testWidgets('503 on status → starting → 200 → ONE retry and the sign-in', (
    tester,
  ) async {
    final server = _Server(
      status: (n) => n == 1 ? 503 : 200,
      health: (n) => n <= 4 ? 503 : 200,
    );
    await _pump(tester, server, _Clock());
    expect(find.byKey(_browser), findsOneWidget);
    expect(server.healthCalls, 5);
    expect(server.statusCalls, 2, reason: 'original + exactly one retry');
  });

  testWidgets(
    'while waiting: starting copy in EN and ES, cloud hint only on cloud',
    (tester) async {
      for (final (locale, title, wait, hint, url) in [
        (
          'en',
          'Your Hermes is starting…',
          'Waiting up to 3 minutes. You can keep using Console.',
          'If this continues, check the status in the Nous Portal.',
          'http://127.0.0.1:19119',
        ),
        (
          'es',
          'Tu Hermes está arrancando…',
          'Esperando hasta 3 minutos. Puedes seguir usando Console.',
          'Si sigue así, mira el estado en el Portal de Nous.',
          'https://ares-3009.agents.nousresearch.com',
        ),
      ]) {
        final gate = Completer<void>();
        final server = _Server(status: (_) => 503, health: (_) => 503)
          ..healthGate = gate.future;
        await tester.pumpWidget(const SizedBox());
        await _pump(tester, server, _Clock(), locale: locale, url: url);
        await tester.pump();
        expect(find.text(title), findsOneWidget, reason: locale);
        expect(find.text(wait), findsOneWidget, reason: locale);
        expect(
          find.text(hint),
          locale == 'es' ? findsOneWidget : findsNothing,
          reason: locale,
        );
        expect(find.byKey(_retry), findsNothing, reason: 'no manual retry yet');
        gate.complete();
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'permanent 503: gives up at 180 s, then 0 probes; Retry restarts',
    (tester) async {
      final server = _Server(status: (_) => 503, health: (_) => 503);
      final clock = _Clock();
      final start = clock.t;
      await _pump(tester, server, clock);
      expect(
        find.text('The server is not finishing its start-up.'),
        findsOneWidget,
      );
      expect(find.byKey(_retry), findsOneWidget);
      expect(
        clock.t.difference(start),
        greaterThanOrEqualTo(const Duration(seconds: 180)),
      );
      final atGiveUp = server.healthCalls;
      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(server.healthCalls, atGiveUp, reason: '0 probes after giving up');
      await tester.tap(find.byKey(_retry));
      await tester.pumpAndSettle();
      expect(server.healthCalls, greaterThan(atGiveUp));
      expect(
        find.text('The server is not finishing its start-up.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Spanish copy and the cloud hint', (tester) async {
    final server = _Server(status: (_) => 503, health: (_) => 503);
    await _pump(
      tester,
      server,
      _Clock(),
      locale: 'es',
      url: 'https://ares-3009.agents.nousresearch.com',
    );
    expect(find.text('El servidor no termina de arrancar.'), findsOneWidget);
    expect(
      find.text('Si sigue así, mira el estado en el Portal de Nous.'),
      findsOneWidget,
    );
  });

  testWidgets('401 on status is never «starting»: no health probe at all', (
    tester,
  ) async {
    final server = _Server(status: (_) => 401, health: (_) => 200);
    await _pump(tester, server, _Clock());
    expect(server.healthCalls, 0);
    expect(find.text('Your Hermes is starting…'), findsNothing);
    expect(
      find.text('The server is not finishing its start-up.'),
      findsNothing,
    );
    expect(find.byKey(_retry), findsOneWidget);
  });

  testWidgets(
    'status 503 again after the wait: ONE retry only, then the error',
    (tester) async {
      final server = _Server(status: (_) => 503, health: (_) => 200);
      await _pump(tester, server, _Clock());
      expect(server.healthCalls, 1);
      expect(server.statusCalls, 2, reason: 'original + exactly one retry');
      expect(find.byKey(_retry), findsOneWidget);
      expect(find.text('Your Hermes is starting…'), findsNothing);
    },
  );

  testWidgets('403 and 500 are not starting either', (tester) async {
    for (final code in [403, 500]) {
      final server = _Server(status: (_) => code, health: (_) => 200);
      await _pump(tester, server, _Clock());
      expect(server.healthCalls, 0, reason: 'HTTP $code');
    }
  });

  testWidgets('flag off (browserFirst false): today\'s error, no warm-up', (
    tester,
  ) async {
    final server = _Server(status: (_) => 503, health: (_) => 200);
    await _pump(tester, server, _Clock(), browserFirst: false);
    expect(server.healthCalls, 0);
    expect(find.byKey(_retry), findsOneWidget);
  });

  testWidgets('app in the background: 0 probes until it is back', (
    tester,
  ) async {
    final server = _Server(
      status: (n) => n == 1 ? 503 : 200,
      health: (_) => 200,
    );
    final gate = Completer<void>();
    server.statusGate = gate.future;
    await _pump(tester, server, _Clock());
    // The app is hidden while the first status read is still in flight.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    gate.complete();
    await tester.pumpAndSettle();
    expect(server.statusCalls, 1);
    expect(server.healthCalls, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(server.healthCalls, 1);
    expect(find.byKey(_browser), findsOneWidget);
  });

  testWidgets(
    'refused right after a good answer = restarting; first-contact refusal is not',
    (tester) async {
      var health = 0;
      Future<MockClient> clientFor({required bool statusRefused}) async {
        var providers = 0;
        health = 0;
        return MockClient((r) async {
          const refused = SocketException(
            'x',
            osError: OSError('refused', 111),
          );
          if (r.url.path == '/api/health') {
            health++;
            return http.Response('{}', health >= 3 ? 200 : 503);
          }
          if (r.url.path == '/api/status') {
            if (statusRefused) throw refused;
            return http.Response(
              jsonEncode({
                'auth_required': true,
                'auth_flows': ['native_pkce'],
              }),
              200,
            );
          }
          if (++providers == 1) throw refused;
          return http.Response(
            jsonEncode({
              'providers': [
                {'name': 'basic', 'supports_password': true},
              ],
            }),
            200,
          );
        });
      }

      Future<void> run(MockClient client) => http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: DashboardSetupScreen(
              browserFirst: true,
              warmupClock: _Clock().clock,
              connection: SavedConnection(
                id: 's3',
                label: 'Fixture',
                host: '127.0.0.1',
                port: 9131,
                apiKey: '',
                dashboardUrl: 'http://127.0.0.1:19119',
              ),
              authorityCurrent: () => true,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }, () => client);

      await run(await clientFor(statusRefused: false));
      expect(
        find.byKey(_browser),
        findsOneWidget,
        reason: 'waited, retried, in',
      );

      await tester.pumpWidget(const SizedBox());
      await run(await clientFor(statusRefused: true));
      expect(find.byKey(_retry), findsOneWidget);
      expect(find.byKey(_browser), findsNothing);
      expect(health, 0, reason: 'nothing ever answered: not a restart');
    },
  );
}
