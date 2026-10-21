// SPDX-License-Identifier: GPL-3.0-only
// WA (CUT-A): the sign-in screen offers the official command page when the
// Dashboard start-up gave up or its check failed. Synthetic fixtures only.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/onboarding/manual_setup_page.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_warmup.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/onboarding_fakes.dart';

const _help = ValueKey('dashboard-setup-help');
const _retry = ValueKey('dashboard-probe-retry');

class _Clock {
  DateTime t = DateTime.utc(2026, 10, 19);
  ServerWarmupClock get clock => ServerWarmupClock(
    now: () => t,
    delay: (d) async {
      t = t.add(d);
      await Future<void>.value();
    },
  );
}

Future<void> _pumpSetup(
  WidgetTester tester, {
  required int status,
  required int health,
  bool browserFirst = true,
  String locale = 'en',
}) async {
  ManualSetupPage.managerForTest = await onboardingManager();
  final client = MockClient((r) async {
    switch (r.url.path) {
      case '/api/status':
        if (status == 0) throw StateError('synthetic');
        return http.Response('', status);
      case '/api/health':
        return http.Response(health == 200 ? '{"status":"ok"}' : '', health);
      case '/api/auth/providers':
        return http.Response(jsonEncode({'providers': []}), 200);
    }
    return http.Response('', 404);
  });
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: DashboardSetupScreen(
          browserFirst: browserFirst,
          warmupClock: _Clock().clock,
          connection: SavedConnection(
            id: 'wa',
            label: 'Fixture',
            host: '127.0.0.1',
            port: 9131,
            apiKey: 'synthetic',
            dashboardUrl: 'http://127.0.0.1:19119',
          ),
          authorityCurrent: () => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }, () => client);
}

void main() {
  group('sign-in screen: start-up gave up', () {
    testWidgets('offers the Dashboard command page and says what to do', (
      tester,
    ) async {
      await _pumpSetup(tester, status: 503, health: 503);
      expect(
        find.text('The server is not finishing its start-up.'),
        findsOneWidget,
      );
      expect(
        find.text(
          "If it doesn't start, close it on your computer and start it again with this line.",
        ),
        findsOneWidget,
      );
      expect(find.byKey(_help), findsOneWidget);
      expect(find.text('Turn on the Dashboard'), findsOneWidget);
      expect(find.byKey(_retry), findsOneWidget, reason: 'Retry stays');
      await tester.ensureVisible(find.byKey(_help));
      await tester.tap(find.byKey(_help));
      await tester.pumpAndSettle();
      expect(find.byType(ManualSetupPage), findsOneWidget);
    });

    testWidgets('Spanish copy', (tester) async {
      await _pumpSetup(tester, status: 503, health: 503, locale: 'es');
      expect(
        find.text(
          'Si no arranca, ciérralo en tu ordenador y vuelve a abrirlo con esta línea.',
        ),
        findsOneWidget,
      );
      expect(find.text('Encender el Dashboard'), findsOneWidget);
    });

    testWidgets('while it is still starting there is no extra button', (
      tester,
    ) async {
      final client = MockClient((r) async => http.Response('', 503));
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: DashboardSetupScreen(
              browserFirst: true,
              warmupClock: ServerWarmupClock(
                now: () => DateTime.utc(2026, 10, 19),
                // Parked mid-wait: the screen stays in «starting».
                delay: (_) => Completer<void>().future,
              ),
              connection: SavedConnection(
                id: 'wa',
                label: 'Fixture',
                host: '127.0.0.1',
                port: 9131,
                apiKey: 'synthetic',
                dashboardUrl: 'http://127.0.0.1:19119',
              ),
              authorityCurrent: () => true,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Your Hermes is starting…'), findsOneWidget);
        expect(find.byKey(_help), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    });
  });

  group('sign-in screen: the check failed', () {
    testWidgets('a rejected check keeps its reason and gains the page', (
      tester,
    ) async {
      await _pumpSetup(tester, status: 401, health: 200);
      expect(find.byKey(_help), findsOneWidget);
      expect(find.byKey(_retry), findsOneWidget);
    });

    testWidgets('plain words and the command page, flag on', (tester) async {
      await _pumpSetup(tester, status: 0, health: 200);
      expect(
        find.text("I can't reach your Hermes. Check that it is turned on."),
        findsOneWidget,
      );
      expect(find.byKey(_help), findsOneWidget);
      expect(find.byKey(_retry), findsOneWidget);
      await tester.ensureVisible(find.byKey(_help));
      await tester.tap(find.byKey(_help));
      await tester.pumpAndSettle();
      expect(find.byType(ManualSetupPage), findsOneWidget);
    });

    testWidgets('flag off: today\'s text, no new button', (tester) async {
      await _pumpSetup(tester, status: 0, health: 200, browserFirst: false);
      expect(
        find.text('Dashboard authentication could not be verified. Retry.'),
        findsOneWidget,
      );
      expect(find.byKey(_help), findsNothing);
      expect(find.byKey(_retry), findsOneWidget);
    });
  });
}
