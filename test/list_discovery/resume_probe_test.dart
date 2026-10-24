// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// LIST-DISCOVERY: Android freezes the app in the background; the sockets
/// of the list and Home (pooled observers) can die there without closing,
/// and still read as connected when the app returns. Only the chats' own
/// sockets were probed on resume, so the list waited for the 20 s ping or
/// the 45 s heartbeat before it could learn a running turn. Back in the
/// foreground every live pooled socket is probed at once (Desktop probes on
/// focus and visibility, `use-gateway-boot.ts` `reconnectNow`, 5 s): a dead
/// one fails within the probe deadline and its owner reconnects and reads
/// `session.active_list`. Nothing is redialled and no backoff is reset.
SavedConnection _conn(String id) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://127.0.0.1:1',
  kind: InstanceKind.vps,
);

/// Counts ticket requests; the first [failures] fail in transit.
final class _Tickets extends DashboardClient {
  _Tickets({this.failures = 0})
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  int failures;
  int tickets = 0;

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async {
    tickets++;
    if (failures > 0) {
      failures--;
      throw const DashboardWebSocketAuthException(
        DashboardWebSocketAuthFailureCode.unavailable,
        cause: DashboardWebSocketAuthFailureCause.transport,
      );
    }
    return const DashboardWebSocketAuth(queryName: 'ticket', credential: 't');
  }
}

/// Emits `gateway.ready`, records every method sent and, when [answers],
/// replies to every request. A silent one is a half-open socket: writes go
/// nowhere and nothing comes back.
final class _Channel implements WebSocketChannel {
  _Channel({required this.answers}) {
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final bool answers;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final List<String> methods = [];

  void _sent(dynamic data) {
    final frame = jsonDecode(data as String) as Map<String, dynamic>;
    final method = frame['method'];
    if (method is String) methods.add(method);
    final id = frame['id'];
    if (answers && id != null && !_incoming.isClosed) {
      _incoming.add(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': <String, dynamic>{}}),
      );
    }
  }

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _Sink(this);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Sink implements WebSocketSink {
  _Sink(this.channel);

  final _Channel channel;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) => channel._sent(data);

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    if (!_done.isCompleted) _done.complete();
    if (!channel._incoming.isClosed) unawaited(channel._incoming.close());
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The whole app, with nothing configured: only the test's own pooled
/// socket is live.
Future<void> _mountApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'onboarding_done': true});
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  await tester.pumpWidget(
    HermesApp(
      connManager: manager,
      appLock: AppLockService(prefs),
      approvalPolicy: ApprovalPolicyService(prefs),
      fontSize: FontSizeService(prefs),
      sshManager: SshManager(secure, manager),
      sftpTransfers: SftpTransferService(
        SshManager(secure, manager),
        NotificationService(prefs),
      ),
      sshSessions: SshSessionService(SshManager(secure, manager)),
      notifications: NotificationService(prefs),
      activeChats: ActiveChatService(),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _unmountApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// Background, then foreground again, as Android reports it.
Future<void> _backgroundAndBack(WidgetTester tester) async {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

/// A pooled observer socket (the list's and Home's lane) on [channel].
SharedGatewayLease _observer(
  WidgetTester tester,
  String id,
  _Channel channel, {
  _Tickets? tickets,
}) => SharedGatewayPool.instance.acquire(
  _conn(id),
  factory: (connection) => TuiGatewayClient(
    connection,
    dashboard: tickets ?? _Tickets(),
    heartbeatInterval: Duration.zero,
    now: () => tester.binding.clock.now(),
    channelFactory: (_, _) => channel,
  ),
);

Future<void> _connect(WidgetTester tester, TuiGatewayClient client) async {
  final connecting = client.connect();
  await tester.pump();
  await connecting;
  expect(client.isConnected, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    for (final name in const [
      'plugins.it_nomads.com/flutter_secure_storage',
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/methods',
      'flutter_foreground_task/background',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    final support = Directory.systemTemp.createTempSync('list-discovery-');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pathProvider, (_) async => support.path);
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathProvider, null);
      if (support.existsSync()) support.deleteSync(recursive: true);
    });
  });

  testWidgets('A1: back in the foreground, a half-open observer socket is '
      'probed at once and fails within 5 s', (tester) async {
    await _mountApp(tester);
    final channel = _Channel(answers: false);
    final lease = _observer(tester, 'disc-a1', channel);
    final client = lease.client;
    await _connect(tester, client);
    final errors = <Object>[];
    final subscription = client.events.listen((_) {}, onError: errors.add);
    // Nothing arrived for longer than the probe's "recent traffic" window.
    await tester.pump(const Duration(seconds: 4));
    final sentBefore = channel.methods.length;

    await _backgroundAndBack(tester);
    expect(
      channel.methods.skip(sentBefore),
      ['gateway.ping'],
      reason: 'the foreground probes the observer socket at once',
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(
      client.isConnected,
      isFalse,
      reason: 'a socket that does not answer the probe is dead',
    );
    expect(
      errors,
      isNotEmpty,
      reason: 'its owners (list, Home) hear the loss and reconnect',
    );
    await subscription.cancel();
    lease.release();
    await _unmountApp(tester);
  });

  testWidgets('A2: a healthy observer socket costs one ping on the '
      'foreground and nothing at rest', (tester) async {
    await _mountApp(tester);
    final channel = _Channel(answers: true);
    final tickets = _Tickets();
    final lease = _observer(tester, 'disc-a2', channel, tickets: tickets);
    final client = lease.client;
    await _connect(tester, client);
    await tester.pump(const Duration(seconds: 4));
    final sentBefore = channel.methods.length;

    await _backgroundAndBack(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(channel.methods.skip(sentBefore), ['gateway.ping']);
    expect(client.isConnected, isTrue);
    expect(tickets.tickets, 1, reason: 'no reconnect for a live socket');

    // At rest: nothing more is sent.
    await tester.pump(const Duration(seconds: 60));
    expect(channel.methods.skip(sentBefore), ['gateway.ping']);
    expect(tickets.tickets, 1);
    lease.release();
    await _unmountApp(tester);
  });

  testWidgets('A3: a socket that heard from the server a moment ago is not '
      'probed', (tester) async {
    await _mountApp(tester);
    final channel = _Channel(answers: true);
    final lease = _observer(tester, 'disc-a3', channel);
    await _connect(tester, lease.client);
    final sentBefore = channel.methods.length;

    await _backgroundAndBack(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(channel.methods.skip(sentBefore), isEmpty);
    expect(lease.client.isConnected, isTrue);
    lease.release();
    await _unmountApp(tester);
  });

  testWidgets('A4: the foreground probe does not redial a socket waiting '
      'out its backoff', (tester) async {
    await _mountApp(tester);
    final tickets = _Tickets(failures: 1);
    final lease = SharedGatewayPool.instance.acquire(
      _conn('disc-a4'),
      factory: (connection) => TuiGatewayClient(
        connection,
        dashboard: tickets,
        heartbeatInterval: Duration.zero,
        now: () => tester.binding.clock.now(),
        // A 10 s gap after the first failed dial.
        reconnectBackoff: GatewayReconnectBackoff(
          random: () => 1,
          base: const Duration(seconds: 10),
        ),
        channelFactory: (_, _) => _Channel(answers: true),
      ),
    );
    final client = lease.client;
    client.connect().then<void>((_) {}, onError: (Object _) {});
    await tester.pump();
    expect(tickets.tickets, 1);
    expect(client.isBackingOff, isTrue);
    // An owner waits for the redial at the end of the gap.
    client.connect().then<void>((_) {}, onError: (Object _) {});
    await tester.pump();

    await _backgroundAndBack(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(
      tickets.tickets,
      1,
      reason: 'the gap stands: a probe never redials or resets the backoff',
    );

    await tester.pump(const Duration(seconds: 10));
    expect(tickets.tickets, 2, reason: 'the gap ends with its own redial');
    lease.release();
    await _unmountApp(tester);
  });

  testWidgets('B1: after a network change the same half-open socket fails '
      'within 5 s', (tester) async {
    await _mountApp(tester);
    final channel = _Channel(answers: false);
    final lease = _observer(tester, 'disc-b1', channel);
    await _connect(tester, lease.client);
    await tester.pump(const Duration(seconds: 4));

    // What main.dart runs when Android reports a validated network.
    unawaited(SharedGatewayPool.instance.probeAll());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(lease.client.isConnected, isFalse);
    lease.release();
    await _unmountApp(tester);
  });
}
