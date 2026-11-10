// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The link of a provider account against a Dashboard that answers like
// hermes_cli/web_routers/oauth.py: routes, bodies, verdicts, expiry,
// cancellation, an older server without the routes, and a read-only
// connection that sends nothing.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/provider_account_link.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/models_server.dart';

ModelsServer _server() => ModelsServer()
  ..accounts = [
    {
      'id': 'nous',
      'name': 'Nous Portal',
      'flow': 'device_code',
      'disconnectable': true,
      'docs_url': 'https://portal.nousresearch.com',
      'status': {'logged_in': false},
    },
    {
      'id': 'qwen-oauth',
      'name': 'Qwen',
      'flow': 'external',
      'disconnectable': false,
      'status': {'logged_in': false},
    },
  ];

ProviderAccountLink _link(
  ModelsServer server, {
  DashboardClient? client,
  String? profile = 'ana',
  bool readOnly = false,
  String providerId = 'nous',
}) => ProviderAccountLink.forClient(
  client ?? server.client(),
  providerId: providerId,
  profile: profile,
  readOnly: readOnly,
  policy: AccountLinkUrlPolicy.forProvider(
    providerId,
    dashboardBaseUrl: 'http://127.0.0.1:9119',
  ),
  minInterval: const Duration(milliseconds: 40),
  maxInterval: const Duration(milliseconds: 60),
  tick: const Duration(milliseconds: 10),
);

Future<void> _settle([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Future<void> _until(bool Function() done, {int ms = 1500}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: ms));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await _settle(10);
  }
  expect(done(), isTrue, reason: 'condition within $ms ms');
}

void main() {
  group('start', () {
    test('posts to the profile and keeps what the page needs', () async {
      final server = _server();
      final link = _link(server);
      await link.start();
      final start = server.of('POST', '/api/providers/oauth/nous/start');
      expect(start.single.profile, 'ana');
      expect(link.phase, AccountLinkPhase.waiting);
      final code = link.code!;
      expect(code.sessionId, 'synthetic-session-1');
      expect(code.userCode, 'HRMS-2026');
      expect(code.verificationUrl.toString(), server.oauthVerificationUrl);
      expect(code.pollInterval, const Duration(milliseconds: 60));
      expect(link.remaining.inSeconds, inInclusiveRange(890, 900));
      expect(link.hasTimer, isTrue);
      link.dispose();
      expect(link.hasTimer, isFalse);
    });

    test('a page outside the provider\'s hosts is not opened', () async {
      final server = _server()
        ..oauthVerificationUrl = 'https://evil.example.test/device';
      final link = _link(server);
      await link.start();
      expect(link.phase, AccountLinkPhase.waiting);
      expect(link.code!.verificationUrl, isNull);
      expect(
        link.code!.unvettedUrl,
        'https://evil.example.test/device',
        reason: 'shown as text to copy, never launched',
      );
      expect(link.code!.userCode, 'HRMS-2026', reason: 'the code still shows');
      link.dispose();
    });

    test('Nous: https on nousresearch.com and its subdomains only', () {
      const policy = AccountLinkUrlPolicy.nous;
      expect(
        policy.allow('https://portal.nousresearch.com/device?x=1'),
        isNotNull,
      );
      expect(policy.allow('https://auth.nousresearch.com/sign-in'), isNotNull);
      expect(policy.allow('https://nousresearch.com/device'), isNotNull);
      expect(policy.allow('http://portal.nousresearch.com/device'), isNull);
      expect(policy.allow('https://nousresearch.com.evil.test/'), isNull);
      expect(policy.allow('https://evilnousresearch.com/'), isNull);
      expect(policy.allow('https://user@portal.nousresearch.com/'), isNull);
      expect(policy.allow('javascript:alert(1)'), isNull);
      expect(policy.allow(''), isNull);
    });

    test(
      'other providers: their own https page; http only on the Dashboard',
      () {
        final policy = AccountLinkUrlPolicy.forProvider(
          'xai-oauth',
          dashboardBaseUrl: 'http://192.168.1.20:9119',
        );
        // The real verification hosts of the device-code providers.
        for (final url in [
          'https://auth.openai.com/codex/device',
          'https://accounts.x.ai/oauth2/device?user_code=ABCD',
          'https://www.minimax.io/oauth/device?user_code=ABCD',
        ]) {
          expect(policy.allow(url), isNotNull, reason: url);
        }
        expect(policy.allow('http://192.168.1.20:9119/callback'), isNotNull);
        expect(policy.allow('http://192.168.1.20:8080/callback'), isNull);
        expect(policy.allow('http://evil.example.test/device'), isNull);
        expect(policy.allow('https://user:pw@auth.openai.com/'), isNull);
        expect(policy.allow('file:///etc/hosts'), isNull);
      },
    );

    test('a non-Nous provider opens its own sign-in page', () async {
      final server = _server()
        ..accounts.add({
          'id': 'xai-oauth',
          'name': 'xAI Grok OAuth',
          'flow': 'device_code',
          'disconnectable': true,
          'docs_url':
              'https://hermes-agent.nousresearch.com/docs/guides/xai-grok-oauth',
          'status': {'logged_in': false},
        })
        ..oauthVerificationUrl =
            'https://accounts.x.ai/oauth2/device?user_code=HRMS-2026';
      final link = _link(server, providerId: 'xai-oauth');
      await link.start();
      expect(link.phase, AccountLinkPhase.waiting);
      expect(link.code!.verificationUrl?.host, 'accounts.x.ai');
      expect(link.code!.unvettedUrl, isEmpty);
      link.dispose();
    });

    test(
      'an older server without the route is unsupported, not broken',
      () async {
        for (final status in [404, 405]) {
          final server = _server()..oauthStartStatus = status;
          final link = _link(server);
          await link.start();
          expect(link.phase, AccountLinkPhase.unsupported, reason: '$status');
          expect(link.canRetry, isFalse);
          expect(link.hasTimer, isFalse);
          link.dispose();
        }
      },
    );

    test('a provider the server refuses fails without a timer', () async {
      final server = _server()..oauthStartStatus = 400;
      final link = _link(server);
      await link.start();
      expect(link.phase, AccountLinkPhase.failed);
      expect(link.hasTimer, isFalse);
      link.dispose();
    });

    test('a Dashboard out of reach is offline and can be retried', () async {
      final server = _server();
      final client = DashboardClient(
        host: '127.0.0.1',
        manualToken: 'synthetic-fixture-token',
        httpClientOverride: MockClient(
          (_) async => throw const SocketException('down'),
        ),
      );
      final link = _link(server, client: client);
      await link.start();
      expect(link.phase, AccountLinkPhase.offline);
      expect(link.canRetry, isTrue);
      link.dispose();
    });

    test('a read-only connection sends nothing', () async {
      final server = _server();
      final link = _link(server, readOnly: true);
      await link.start();
      expect(link.phase, AccountLinkPhase.readOnly);
      expect(await link.disconnect(), isFalse);
      await link.cancel();
      link.dispose();
      expect(server.writes, isEmpty);
    });
  });

  group('poll', () {
    test('pending until approved, then who signed in', () async {
      final server = _server();
      final link = _link(server);
      await link.start();
      await _until(
        () => server
            .of('GET', '/api/providers/oauth/nous/poll/synthetic-session-1')
            .isNotEmpty,
      );
      expect(link.phase, AccountLinkPhase.waiting);
      server.settleOAuth(
        'synthetic-session-1',
        status: 'approved',
        email: 'owner@example.test',
      );
      await _until(() => link.phase == AccountLinkPhase.approved);
      expect(link.accountEmail, 'owner@example.test');
      expect(link.hasTimer, isFalse);
      expect(
        server
            .of('GET', '/api/providers/oauth/nous/poll/synthetic-session-1')
            .map((r) => r.profile),
        everyElement('ana'),
      );
      link.dispose();
      expect(
        server.of(
          'DELETE',
          '/api/providers/oauth/sessions/synthetic-session-1',
        ),
        isEmpty,
        reason: 'a finished session is not cancelled',
      );
    });

    test('each verdict of the server has its phase', () async {
      final cases =
          <
            ({
              String status,
              String? reason,
              bool? retryable,
              AccountLinkPhase phase,
              bool retry,
            })
          >[
            (
              status: 'denied',
              reason: null,
              retryable: null,
              phase: AccountLinkPhase.denied,
              retry: true,
            ),
            (
              status: 'expired',
              reason: null,
              retryable: null,
              phase: AccountLinkPhase.expired,
              retry: true,
            ),
            (
              status: 'cancelled',
              reason: null,
              retryable: null,
              phase: AccountLinkPhase.cancelled,
              retry: true,
            ),
            (
              status: 'error',
              reason: 'timeout',
              retryable: null,
              phase: AccountLinkPhase.expired,
              retry: true,
            ),
            (
              status: 'error',
              reason: 'anon_rate_limited',
              retryable: true,
              phase: AccountLinkPhase.failed,
              retry: true,
            ),
            // A failure the server calls final (a refusal in the browser
            // looks the same) still offers a fresh code.
            (
              status: 'error',
              reason: 'anon_gate_closed',
              retryable: false,
              phase: AccountLinkPhase.failed,
              retry: true,
            ),
            (
              status: 'error',
              reason: 'failed',
              retryable: false,
              phase: AccountLinkPhase.failed,
              retry: true,
            ),
          ];
      for (final c in cases) {
        final server = _server();
        final link = _link(server);
        await link.start();
        server.settleOAuth(
          'synthetic-session-1',
          status: c.status,
          reason: c.reason,
          retryable: c.retryable,
          retryAfter: c.retryable == true ? 90 : null,
        );
        await _until(() => link.phase == c.phase);
        expect(link.canRetry, c.retry, reason: c.status);
        expect(link.hasTimer, isFalse, reason: c.status);
        if (c.retryable == true) {
          expect(link.retryAfter, const Duration(seconds: 90));
        }
        link.dispose();
      }
    });

    test('a session the server forgot has expired', () async {
      final server = _server();
      final link = _link(server);
      await link.start();
      server.oauthSessions.clear();
      await _until(() => link.phase == AccountLinkPhase.expired);
      expect(link.hasTimer, isFalse);
      link.dispose();
    });

    test('the local deadline ends the wait without a server verdict', () async {
      final server = _server()..oauthExpiresIn = 1;
      var now = DateTime(2026, 1, 1, 12);
      final link = ProviderAccountLink.forClient(
        server.client(),
        providerId: 'nous',
        profile: 'ana',
        now: () => now,
        minInterval: const Duration(milliseconds: 40),
        maxInterval: const Duration(milliseconds: 60),
        tick: const Duration(milliseconds: 10),
      );
      await link.start();
      expect(link.phase, AccountLinkPhase.waiting);
      // The deadline is never shorter than 30 s; the clock moves past it.
      now = now.add(const Duration(seconds: 31));
      await _until(() => link.phase == AccountLinkPhase.expired);
      expect(link.remaining, Duration.zero);
      expect(link.hasTimer, isFalse);
      link.dispose();
    });

    test('no polling from the background; one check on return', () async {
      final server = _server();
      final link = _link(server);
      await link.start();
      link.setForeground(false);
      expect(link.hasTimer, isFalse);
      final before = server
          .of('GET', '/api/providers/oauth/nous/poll/synthetic-session-1')
          .length;
      await _settle(150);
      expect(
        server
            .of('GET', '/api/providers/oauth/nous/poll/synthetic-session-1')
            .length,
        before,
        reason: 'nothing asked while hidden',
      );
      server.settleOAuth('synthetic-session-1', status: 'approved');
      link.setForeground(true);
      await _until(() => link.phase == AccountLinkPhase.approved);
      link.dispose();
    });

    test('a network blip while waiting is not a verdict', () async {
      var down = false;
      var polls = 0;
      final link = ProviderAccountLink(
        providerId: 'nous',
        start: () async => {
          'session_id': 'synthetic-session-1',
          'user_code': 'HRMS-2026',
          'verification_url': 'https://portal.nousresearch.com/device',
          'expires_in': 900,
          'poll_interval': 1,
        },
        poll: (_) async {
          polls++;
          if (down) throw const SocketException('blip');
          return {'status': polls >= 4 ? 'approved' : 'pending'};
        },
        cancelSession: (_) async {},
        disconnect: () async {},
        minInterval: const Duration(milliseconds: 40),
        maxInterval: const Duration(milliseconds: 60),
        tick: const Duration(milliseconds: 10),
      );
      await link.start();
      down = true;
      await _until(() => polls >= 2);
      expect(link.phase, AccountLinkPhase.waiting);
      expect(link.hasTimer, isTrue, reason: 'the deadline still bounds it');
      down = false;
      await _until(() => link.phase == AccountLinkPhase.approved);
      link.dispose();
    });
  });

  group('cancel and dispose', () {
    test('cancelling tells the server and ends the wait', () async {
      final server = _server();
      final link = _link(server);
      await link.start();
      await link.cancel();
      expect(link.phase, AccountLinkPhase.cancelled);
      expect(link.hasTimer, isFalse);
      final cancel = server.of(
        'DELETE',
        '/api/providers/oauth/sessions/synthetic-session-1',
      );
      expect(cancel.single.profile, 'ana');
      expect(server.oauthSessions, isEmpty);
      link.dispose();
    });

    test('disposing while waiting cancels on the server too', () async {
      final server = _server();
      final link = _link(server);
      await link.start();
      link.dispose();
      expect(link.hasTimer, isFalse);
      await _until(
        () => server
            .of('DELETE', '/api/providers/oauth/sessions/synthetic-session-1')
            .isNotEmpty,
      );
    });

    test('a retry after a verdict starts a new session', () async {
      final server = _server();
      final link = _link(server);
      await link.start();
      server.settleOAuth('synthetic-session-1', status: 'denied');
      await _until(() => link.phase == AccountLinkPhase.denied);
      await link.start();
      expect(link.phase, AccountLinkPhase.waiting);
      expect(link.code!.sessionId, 'synthetic-session-2');
      expect(link.hasTimer, isTrue);
      link.dispose();
    });
  });

  group('disconnect', () {
    test('removes the credential of the profile', () async {
      final server = _server();
      server.accounts.first['status'] = {'logged_in': true};
      final link = _link(server);
      expect(await link.disconnect(), isTrue);
      final delete = server.of('DELETE', '/api/providers/oauth/nous');
      expect(delete.single.profile, 'ana');
      expect(server.accounts.first['status'], {'logged_in': false});
      link.dispose();
    });

    test('an older server is unsupported; a refusal is a failure', () async {
      final server = _server();
      for (final (status, phase) in [
        (404, AccountLinkPhase.unsupported),
        (409, AccountLinkPhase.failed),
      ]) {
        final client = DashboardClient(
          host: '127.0.0.1',
          manualToken: 'synthetic-fixture-token',
          httpClientOverride: MockClient(
            (_) async => http.Response('{"detail":"no"}', status),
          ),
        );
        final link = _link(server, client: client);
        expect(await link.disconnect(), isFalse);
        expect(link.phase, phase, reason: '$status');
        link.dispose();
      }
    });
  });

  test('timers never outlive the flow', () async {
    final server = _server();
    final link = _link(server);
    await link.start();
    expect(link.hasTimer, isTrue);
    server.settleOAuth('synthetic-session-1', status: 'approved');
    await _until(() => link.phase == AccountLinkPhase.approved);
    expect(link.hasTimer, isFalse);
    link.dispose();
    expect(link.hasTimer, isFalse);
  });
}
