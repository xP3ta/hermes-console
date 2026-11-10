// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The Models screen offers the Nous Portal account at the top while it is
// not connected, runs the sign-in against the profile on screen, and shows
// the account as connected only once the server lists it so. A read-only
// connection sends nothing; an older server is told apart from a failure.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'support/models_server.dart';

class _Browser extends UrlLauncherPlatform {
  final opened = <String>[];
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

ModelsServer _withNous({bool connected = false}) => ModelsServer()
  ..accounts = [
    {
      'id': 'nous',
      'name': 'Nous Portal',
      'flow': 'device_code',
      'disconnectable': true,
      'docs_url': 'https://portal.nousresearch.com',
      'status': {
        'logged_in': connected,
        'source_label': 'https://portal.nousresearch.com',
        'account_tier': connected ? 'pro' : null,
      },
    },
  ];

/// Taps and lets the route move, without settling: the link page keeps a
/// countdown timer, so "settled" never comes while it is open.
Future<void> tapAndPump(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late ActiveProfileScope scope;
  late _Browser browser;
  setUp(() async {
    scope = await modelsScope();
    browser = _Browser();
    UrlLauncherPlatform.instance = browser;
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  Finder offer() => find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('models-nous-offer-'),
  );

  testWidgets('the card is offered first while Nous is not connected', (
    tester,
  ) async {
    final server = _withNous();
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    expect(offer(), findsOneWidget);
    final cardTop = tester.getTopLeft(offer()).dy;
    final providersTop = tester
        .getTopLeft(find.text('MAIN MODEL · PROVIDERS'))
        .dy;
    expect(cardTop, lessThan(providersTop));
    expect(key('models-account-nous'), findsNothing);
  });

  testWidgets('a connected account is listed, with its tier, not offered', (
    tester,
  ) async {
    await pumpModels(tester, _withNous(connected: true), scope);
    await tester.pumpAndSettle();
    expect(offer(), findsNothing);
    expect(
      find.descendant(
        of: key('models-account-nous'),
        matching: find.text('Connected · Pro'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('connect: start on the profile, the page, approval, the list', (
    tester,
  ) async {
    final server = _withNous();
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await tapAndPump(tester, key('nac-card-connect'));
    final start = server.of('POST', '/api/providers/oauth/nous/start');
    expect(start.single.profile, 'ana');
    expect(browser.opened, [server.oauthVerificationUrl]);
    expect(find.text('HRMS-2026'), findsOneWidget);

    server.settleOAuth(
      'synthetic-session-1',
      status: 'approved',
      email: 'owner@example.test',
    );
    await tester.tap(key('nac-link-check'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(key('nac-link-done'));
    await tester.pumpAndSettle();
    expect(offer(), findsNothing);
    expect(key('models-account-nous'), findsOneWidget);
    expect(
      server.of('GET', '/api/providers/oauth').length,
      greaterThanOrEqualTo(2),
      reason: 'the list is read again after the approval',
    );
  });

  testWidgets(
    'an approval the server does not list is not shown as connected',
    (tester) async {
      final server = _withNous();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await tapAndPump(tester, key('nac-card-connect'));
      // Settle the session without signing the account in.
      server.oauthSessions['synthetic-session-1']!['status'] = 'approved';
      await tester.tap(key('nac-link-check'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(key('nac-link-done'));
      await tester.pumpAndSettle();
      expect(offer(), findsOneWidget);
      expect(key('models-account-nous'), findsNothing);
    },
  );

  testWidgets('an older server without the route says so and breaks nothing', (
    tester,
  ) async {
    final server = _withNous()..oauthStartStatus = 404;
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await tapAndPump(tester, key('nac-card-connect'));
    expect(find.text('Not available on this server'), findsOneWidget);
    expect(key('nac-link-retry'), findsNothing);
    await tapAndPump(tester, key('nac-link-verdict-close'));
    await tester.pumpAndSettle();
    expect(offer(), findsOneWidget);
    expect(browser.opened, isEmpty);
  });

  testWidgets('a read-only connection offers nothing and sends nothing', (
    tester,
  ) async {
    final server = _withNous();
    await pumpModels(tester, server, scope, readOnly: true);
    await tester.pumpAndSettle();
    expect(offer(), findsOneWidget, reason: 'the state is still shown');
    await tapAndPump(tester, key('nac-card-connect'));
    expect(server.writes, isEmpty);
    expect(find.text('HRMS-2026'), findsNothing);
  });

  testWidgets('disconnect asks, deletes on the profile and re-reads', (
    tester,
  ) async {
    final server = _withNous(connected: true);
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await tapOn(tester, key('models-account-nous'));
    await tapOn(tester, key('models-account-disconnect-nous'));
    expect(server.writes, isEmpty, reason: 'nothing removed unasked');
    expect(find.text('Disconnect Nous Portal?'), findsOneWidget);
    await tapOn(
      tester,
      find.descendant(
        of: find.byKey(const ValueKey('hermes-dialog')),
        matching: find.text('Disconnect'),
      ),
    );
    final delete = server.of('DELETE', '/api/providers/oauth/nous');
    expect(delete.single.profile, 'ana');
    expect(key('models-account-nous'), findsNothing);
    expect(offer(), findsOneWidget);
  });

  testWidgets('closing the page while waiting cancels the session', (
    tester,
  ) async {
    final server = _withNous();
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await tapAndPump(tester, key('nac-card-connect'));
    await tapAndPump(tester, key('nac-link-close'));
    await tester.pumpAndSettle();
    expect(
      server.of('DELETE', '/api/providers/oauth/sessions/synthetic-session-1'),
      hasLength(1),
    );
    expect(offer(), findsOneWidget);
  });
}
