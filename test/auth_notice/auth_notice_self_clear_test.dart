// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/in_memory_compression_restore_storage.dart';
import 'auth_notice_fakes.dart';

/// The chat's «Session expired · Sign in» notice says the Dashboard refused
/// the credential. A socket that reaches `ready` again (by its own redial, or
/// by a send or Retry) proves the credential was just accepted, so the notice
/// goes away by itself; an attempt that started before that and fails late
/// cannot bring it back. A refused upgrade never raises it.
SavedConnection _conn(String id) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://127.0.0.1:1',
  kind: InstanceKind.vps,
);

const _loginRequired = DashboardAuthException(
  DashboardAuthFailureCode.loginRequired,
);

/// The real client, whose [connect] a test can hold and fail later.
class _HeldClient extends TuiGatewayClient {
  _HeldClient(
    super.connection, {
    super.dashboard,
    super.channelFactory,
    super.heartbeatInterval,
    super.reconnectBackoff,
  });

  Completer<void>? held;

  @override
  Future<void> connect() => held?.future ?? super.connect();
}

class _Rig {
  _Rig(this.dashboard, this.channels);

  final FakeTickets dashboard;

  /// One per dial, built when the dial opens it; tickets after the list.
  final List<FakeChannel Function()> channels;
  final List<FakeChannel> opened = [];
  late final _HeldClient client;
  late final ActiveChat chat;

  Future<void> open(String id) async {
    var draws = 0;
    client = _HeldClient(
      _conn(id),
      dashboard: dashboard,
      heartbeatInterval: Duration.zero,
      // A first gap of a full second, so the test always acts inside it;
      // then 100 ms, 200 ms, 400 ms...
      reconnectBackoff: GatewayReconnectBackoff(
        random: () => draws++ == 0 ? 1.0 : 0.05,
        base: const Duration(seconds: 1),
      ),
      channelFactory: (_, _) {
        final channel = opened.length < channels.length
            ? channels[opened.length]()
            : ReadyChannel();
        opened.add(channel);
        return channel;
      },
    )..redialWhenIdle = true;
    addTearDown(client.close);
    chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: _conn(id),
      sessionId: 'sess-$id',
      sessionTitle: id,
      notifications: null,
      onTerminal: () {},
      desktopGateway: client,
    );
    addTearDown(chat.dispose);
  }

  /// The chat's socket came up once and the server then went away.
  Future<void> upThenDropped() async {
    await client.connect();
    expect(client.isConnected, isTrue);
    (opened.last as ReadyChannel).drop();
    await _until(() => !client.isConnected);
  }
}

Future<void> _until(
  bool Function() condition, {
  Duration max = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(max);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not reached in $max');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the sign-in notice goes away when the socket is back', () {
    test('T6: the own redial reaches ready after a refused ticket request: '
        'the notice clears by itself', () async {
      // Ticket 1: the first socket. Ticket 2 (the warm-up's redial): refused.
      // Ticket 3 (the next own redial): accepted.
      final rig = _Rig(
        FakeTickets(answers: [null, _loginRequired], simpleConnect: false),
        [],
      );
      await rig.open('t6');
      await rig.upThenDropped();

      await rig.chat.warmDesktopGateway();
      expect(rig.chat.dashboardAuthRequired, isTrue);
      expect(rig.chat.dashboardAuthNoticeVisible, isTrue);

      await _until(() => rig.client.isConnected);
      expect(rig.dashboard.tickets, 3);
      expect(
        rig.chat.dashboardAuthRequired,
        isFalse,
        reason: 'a ready socket proves the credential was just accepted',
      );
      expect(rig.chat.dashboardAuthNoticeVisible, isFalse);
    });

    test('T6b: latched on the refusal, a send or Retry that reaches ready '
        'clears the notice', () async {
      final rig = _Rig(
        FakeTickets(answers: [null, _loginRequired], simpleConnect: true),
        [],
      );
      await rig.open('t6b');
      await rig.upThenDropped();

      await rig.chat.warmDesktopGateway();
      expect(rig.chat.dashboardAuthRequired, isTrue);
      expect(rig.client.linkAuthRejected, isTrue);

      await rig.client.connectForeground();
      expect(rig.client.isConnected, isTrue);
      expect(rig.chat.dashboardAuthRequired, isFalse);
      expect(rig.chat.dashboardAuthNoticeVisible, isFalse);
    });

    test('T7: while the Dashboard keeps refusing, link changes leave the '
        'notice up', () async {
      final rig = _Rig(
        FakeTickets(
          answers: [null, for (var i = 0; i < 50; i++) _loginRequired],
          simpleConnect: false,
        ),
        [],
      );
      await rig.open('t7');
      await rig.upThenDropped();

      await rig.chat.warmDesktopGateway();
      expect(rig.chat.dashboardAuthRequired, isTrue);
      final ticketsAtNotice = rig.dashboard.tickets;

      // Two more own redials, each refused, each a link change.
      await _until(() => rig.dashboard.tickets >= ticketsAtNotice + 2);
      expect(rig.client.isConnected, isFalse);
      expect(rig.chat.dashboardAuthRequired, isTrue);
      expect(rig.chat.dashboardAuthNoticeVisible, isTrue);
    });

    test('T7b: a notice raised while the socket is up stays when that '
        'socket is lost', () async {
      final rig = _Rig(FakeTickets(simpleConnect: false), []);
      await rig.open('t7b');
      await rig.client.connect();
      expect(rig.client.isConnected, isTrue);

      // A refusal that reaches the chat while its socket is still up.
      final held = rig.client.held = Completer<void>();
      final warm = rig.chat.warmDesktopGateway();
      await Future<void>.delayed(Duration.zero);
      held.completeError(_loginRequired);
      await warm;
      rig.client.held = null;
      expect(rig.chat.dashboardAuthRequired, isTrue);

      // The loss is announced while the client still reads as connected.
      (rig.opened.last as ReadyChannel).drop();
      await _until(() => !rig.client.isConnected);
      expect(
        rig.chat.dashboardAuthRequired,
        isTrue,
        reason: 'a lost socket proves nothing about the credential',
      );
    });

    test('T8: an attempt that began before the socket came back and fails '
        'late does not raise the notice again', () async {
      final rig = _Rig(FakeTickets(simpleConnect: false), []);
      await rig.open('t8');
      await rig.upThenDropped();

      // A warm-up whose connect is still out when the socket returns.
      final held = rig.client.held = Completer<void>();
      final warm = rig.chat.warmDesktopGateway();
      await Future<void>.delayed(Duration.zero);
      rig.client.held = null;
      await rig.client.connectForeground();
      expect(rig.client.isConnected, isTrue);

      held.completeError(_loginRequired);
      await warm;
      expect(
        rig.chat.dashboardAuthRequired,
        isFalse,
        reason: 'the ready socket is newer than the late refusal',
      );
    });
  });

  group('piece 2: only a refused credential raises the notice', () {
    test('an upgrade refused twice (a stale ticket) does not', () async {
      final rig = _Rig(FakeTickets(simpleConnect: false), [
        ReadyChannel.new,
        () => RefusedUpgradeChannel(403),
        () => RefusedUpgradeChannel(403),
      ]);
      await rig.open('p2-upgrade');
      await rig.upThenDropped();

      // Inside the gap the warm-up rides the own redial, whose upgrade is
      // refused (and, with the ticket retry, refused again).
      await rig.chat.warmDesktopGateway();
      expect(rig.opened.length, greaterThanOrEqualTo(2));
      expect(rig.opened[1], isA<RefusedUpgradeChannel>());
      expect(rig.client.linkAuthRejected, isFalse);
      expect(rig.chat.dashboardAuthRequired, isFalse);
    });

    test('a ticket request answered 403 does', () async {
      final rig = _Rig(
        FakeTickets(
          answers: [
            null,
            const DashboardWebSocketAuthException(
              DashboardWebSocketAuthFailureCode.unavailable,
              statusCode: 403,
            ),
          ],
          simpleConnect: false,
        ),
        [],
      );
      await rig.open('p2-mint');
      await rig.upThenDropped();

      await rig.chat.warmDesktopGateway();
      expect(rig.chat.dashboardAuthRequired, isTrue);
    });
  });
}
