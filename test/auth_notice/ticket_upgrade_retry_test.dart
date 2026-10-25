// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io' show WebSocketException;

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'auth_notice_fakes.dart';

/// A ticket is single use and lives 30 s. When the Dashboard refuses it on
/// the upgrade (expired, unknown or already used), `/api/ws` closes before
/// accepting and uvicorn answers HTTP 403: the socket was never opened and
/// the credential that minted the ticket was accepted a moment ago. The dial
/// mints a fresh ticket and tries once more before it counts as a lost link.
/// Only a ticket request the Dashboard refuses is a credential rejection.
SavedConnection _conn() => SavedConnection(
  id: 'auth-retry',
  label: 'auth-retry',
  host: '127.0.0.1',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://127.0.0.1:1',
  kind: InstanceKind.vps,
);

class _Rig {
  _Rig(FakeAsync async, this.dashboard, this.channels) {
    client = TuiGatewayClient(
      _conn(),
      dashboard: dashboard,
      heartbeatInterval: Duration.zero,
      now: () => DateTime(2026).add(async.elapsed),
      reconnectBackoff: GatewayReconnectBackoff(random: () => 1),
      channelFactory: (_, _) {
        final channel = channels[dials]();
        // The refused socket is torn down before the next one is opened.
        closedBeforeDial.add(dials == 0 || opened.last.sinkClosed);
        dials++;
        opened.add(channel);
        return channel;
      },
    );
  }

  final FakeTickets dashboard;

  /// One per dial, built when the dial opens it.
  final List<FakeChannel Function()> channels;
  final List<FakeChannel> opened = [];
  final List<bool> closedBeforeDial = [];
  late final TuiGatewayClient client;
  int dials = 0;

  /// Dials once and lets the dial settle; returns its error, if any.
  Object? connect(FakeAsync async) {
    Object? error;
    var done = false;
    client.connect().then<void>(
      (_) => done = true,
      onError: (Object e) {
        error = e;
        done = true;
      },
    );
    async.elapse(const Duration(seconds: 5));
    expect(done, isTrue, reason: 'the dial settled');
    return error;
  }

  void dispose(FakeAsync async) {
    unawaited(client.close());
    async.elapse(const Duration(seconds: 5));
  }
}

void main() {
  group('a ticket refused on the upgrade', () {
    // The adapter's order (the stream ends before `ready` fails) and the
    // reverse: in the reverse one the catch still owns the socket, so it is
    // the order that shows the retry runs before the loss is noted.
    for (final status in [401, 403]) {
      for (final later in [false, true]) {
        final order = later ? 'stream after ready' : 'adapter order';
        test('T1 ($status, $order): one fresh ticket and one more upgrade, '
            'no lost link, the refused socket torn down first', () {
          fakeAsync((async) {
            final rig = _Rig(async, FakeTickets(), [
              () => RefusedUpgradeChannel(status, streamLater: later),
              ReadyChannel.new,
            ]);
            final error = rig.connect(async);

            expect(error, isNull, reason: 'the second upgrade is accepted');
            expect(rig.client.isConnected, isTrue);
            expect(rig.dashboard.tickets, 2, reason: 'a fresh ticket');
            expect(rig.dials, 2);
            expect(rig.closedBeforeDial, [true, true]);
            expect(
              rig.client.linkReconnectAttempt,
              0,
              reason: 'the retry runs before the loss is noted: no backoff',
            );
            expect(rig.client.linkAuthRejected, isFalse);
            rig.dispose(async);
          });
        });
      }
    }

    test('T2: refused again, the dial fails as transport after exactly one '
        'retry', () {
      fakeAsync((async) {
        final rig = _Rig(async, FakeTickets(), [
          () => RefusedUpgradeChannel(403),
          () => RefusedUpgradeChannel(403),
          ReadyChannel.new,
        ]);
        final error = rig.connect(async);

        expect(error, isA<WebSocketChannelException>());
        expect(rig.dashboard.tickets, 2, reason: 'one retry, not more');
        expect(rig.dials, 2);
        expect(rig.client.isConnected, isFalse);
        expect(
          rig.client.linkAuthRejected,
          isFalse,
          reason: 'a refused upgrade is not a refused credential',
        );

        async.elapse(const Duration(seconds: 60));
        expect(rig.dashboard.tickets, 2, reason: 'no third ticket later');
        expect(rig.dials, 2);
        rig.dispose(async);
      });
    });

    test('R4: a client closed while the upgrade is pending does not '
        'retry', () {
      fakeAsync((async) {
        final refused = RefusedUpgradeChannel(403, hold: true);
        final rig = _Rig(async, FakeTickets(), [
          () => refused,
          ReadyChannel.new,
        ]);
        Object? error;
        rig.client.connect().then<void>(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        );
        async.flushMicrotasks();
        expect(rig.dials, 1);

        unawaited(rig.client.close());
        async.flushMicrotasks();
        refused.answer();
        async.elapse(const Duration(seconds: 10));

        expect(error, isNotNull);
        expect(rig.dashboard.tickets, 1, reason: 'no ticket after close');
        expect(rig.dials, 1);
      });
    });
  });

  group('no retry for anything else', () {
    test('T3: an upgrade answered 500 fails once, without a second ticket', () {
      fakeAsync((async) {
        final rig = _Rig(async, FakeTickets(), [
          () => RefusedUpgradeChannel(500),
          ReadyChannel.new,
        ]);
        final error = rig.connect(async);

        expect(error, isA<WebSocketChannelException>());
        expect(rig.dashboard.tickets, 1);
        expect(rig.dials, 1);
        rig.dispose(async);
      });
    });

    test('T4: a session token (no ticket) refused on the upgrade is not '
        'retried', () {
      fakeAsync((async) {
        final rig = _Rig(async, FakeTickets(queryName: 'token'), [
          () => RefusedUpgradeChannel(403),
          ReadyChannel.new,
        ]);
        final error = rig.connect(async);

        expect(error, isA<WebSocketChannelException>());
        expect(rig.dashboard.tickets, 1);
        expect(rig.dials, 1);
        rig.dispose(async);
      });
    });
  });

  group('T5: only a refused ticket request is a credential rejection', () {
    final refusals = <String, Object>{
      'ticket request 401': const DashboardWebSocketAuthException(
        DashboardWebSocketAuthFailureCode.unavailable,
        statusCode: 401,
      ),
      'ticket request 403': const DashboardWebSocketAuthException(
        DashboardWebSocketAuthFailureCode.unavailable,
        statusCode: 403,
      ),
      'login required': const DashboardAuthException(
        DashboardAuthFailureCode.loginRequired,
      ),
    };
    refusals.forEach((name, refusal) {
      test('$name: auth rejected, nothing is dialled', () {
        fakeAsync((async) {
          final rig = _Rig(async, FakeTickets(answers: [refusal]), [
            ReadyChannel.new,
          ]);
          final error = rig.connect(async);

          expect(error, same(refusal));
          expect(rig.client.linkAuthRejected, isTrue);
          expect(rig.dials, 0);
          rig.dispose(async);
        });
      });
    });

    test('an upgrade refused twice is not auth rejected', () {
      fakeAsync((async) {
        final rig = _Rig(async, FakeTickets(), [
          () => RefusedUpgradeChannel(403),
          () => RefusedUpgradeChannel(403),
        ]);
        rig.connect(async);

        expect(rig.client.linkAuthRejected, isFalse);
        expect(
          TuiGatewayClient.isDashboardAuthRejection(
            WebSocketChannelException.from(
              const WebSocketException('not upgraded', 403),
            ),
          ),
          isFalse,
        );
        rig.dispose(async);
      });
    });
  });
}
