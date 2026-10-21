import 'dart:async';
import 'dart:convert';

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_status.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_connection_recovery_row.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_connection_link.dart';

/// N4: one source of the connection state. The chat-lane socket decides what
/// every screen says (connected, reconnecting, no network, sign-in required,
/// no server); REST is auxiliary and never says «connected» over a down socket.

SavedConnection _conn(String id) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'unused',
  dashboardUrl: 'http://127.0.0.1:1',
  kind: InstanceKind.vps,
);

final class _Tickets extends DashboardClient {
  _Tickets() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  Object? failWith;

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async {
    final error = failWith;
    if (error != null) throw error;
    return const DashboardWebSocketAuth(queryName: 'ticket', credential: 't');
  }
}

final class _ReadyChannel implements WebSocketChannel {
  _ReadyChannel() {
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final StreamController<dynamic> _incoming = StreamController<dynamic>();

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

  final _ReadyChannel channel;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) {}

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

void main() {
  group('derivation', () {
    test('a ready socket is connected whatever REST and the network say', () {
      final status = deriveConnectionStatus(
        socketReady: true,
        authRejected: true,
        networkLost: true,
        restReachable: false,
      );
      expect(status.kind, ConnectionStatusKind.connected);
    });

    test(
      'a down socket: auth, then network, then server, else reconnecting',
      () {
        ConnectionStatusKind kind({
          bool auth = false,
          bool network = false,
          bool? rest,
        }) => deriveConnectionStatus(
          socketReady: false,
          authRejected: auth,
          networkLost: network,
          restReachable: rest,
        ).kind;

        expect(
          kind(auth: true, network: true, rest: false),
          ConnectionStatusKind.authRequired,
        );
        expect(
          kind(network: true, rest: false),
          ConnectionStatusKind.noNetwork,
        );
        expect(kind(rest: false), ConnectionStatusKind.noServer);
        // REST answering while the socket is down is a reconnect, not «up».
        expect(kind(rest: true), ConnectionStatusKind.reconnecting);
        expect(kind(), ConnectionStatusKind.reconnecting);
      },
    );

    test('failingLong turns true only after 5 minutes down', () {
      final since = DateTime(2026);
      final status = ConnectionStatus(
        ConnectionStatusKind.reconnecting,
        since: since,
      );
      expect(
        status.failingLong(since.add(const Duration(minutes: 4, seconds: 59))),
        isFalse,
      );
      expect(status.failingLong(since.add(const Duration(minutes: 5))), isTrue);
      expect(
        const ConnectionStatus(
          ConnectionStatusKind.connected,
        ).failingLong(since),
        isFalse,
      );
    });
  });

  group('registry', () {
    test(
      'REST healthy but the chat socket down: reconnecting, never connected',
      () {
        final registry = ConnectionStatusRegistry();
        final link = FakeConnectionLink();
        registry.bind('c', link);
        // Nothing dialled yet: no proof either way, screens use their REST.
        expect(registry.current('c'), isNull);

        registry.reportRest('c', reachable: true);
        link.change(() => link.linkReconnectAt = DateTime(2026));
        expect(registry.current('c')!.kind, ConnectionStatusKind.reconnecting);

        link.change(
          () => link
            ..isConnected = true
            ..linkReconnectAt = null,
        );
        expect(registry.current('c')!.isConnected, isTrue);
      },
    );

    test('network lost, REST dead and a rejected login name their state', () {
      final registry = ConnectionStatusRegistry();
      final link = FakeConnectionLink();
      registry.bind('c', link);
      link.change(() => link.linkReconnectAt = DateTime(2026));

      registry.setNetworkLost(true);
      expect(registry.current('c')!.kind, ConnectionStatusKind.noNetwork);
      registry.setNetworkLost(false);
      registry.reportRest('c', reachable: false);
      expect(registry.current('c')!.kind, ConnectionStatusKind.noServer);
      link.change(() => link.linkAuthRejected = true);
      expect(registry.current('c')!.kind, ConnectionStatusKind.authRequired);
    });

    test(
      'a parked or closed socket is not an outage; the outage start is kept',
      () {
        final registry = ConnectionStatusRegistry();
        final link = FakeConnectionLink();
        registry.bind('c', link);
        var now = DateTime(2026);
        final timed = ConnectionStatusRegistry(clock: () => now);
        final other = FakeConnectionLink();
        timed.bind('t', other);
        other.change(() => other.linkReconnectAt = now);
        final first = timed.current('t')!.since;
        now = now.add(const Duration(minutes: 2));
        other.change(() => other.linkReconnectAttempt = 3);
        expect(
          timed.current('t')!.since,
          first,
          reason: 'since survives attempts',
        );

        link.change(
          () => link
            ..linkReconnectAt = DateTime(2026)
            ..linkParked = true,
        );
        expect(registry.current('c'), isNull);
        link.change(
          () => link
            ..linkParked = false
            ..isClosed = true,
        );
        expect(registry.current('c'), isNull);
      },
    );
  });

  group('real client', () {
    test('socket edges drive the status: ticket transport failure, redial, '
        'credential refusal, close', () {
      fakeAsync((async) {
        final registry = ConnectionStatusRegistry();
        final tickets = _Tickets()
          ..failWith = const DashboardWebSocketAuthException(
            DashboardWebSocketAuthFailureCode.unavailable,
            cause: DashboardWebSocketAuthFailureCause.transport,
          );
        final client = TuiGatewayClient(
          _conn('n4'),
          dashboard: tickets,
          heartbeatInterval: Duration.zero,
          now: () => DateTime(2026).add(async.elapsed),
          reconnectBackoff: GatewayReconnectBackoff(random: () => 1),
          channelFactory: (_, _) => _ReadyChannel(),
        );
        registry.bind('n4', client);
        expect(registry.current('n4'), isNull);

        client.connect().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        expect(registry.current('n4')!.kind, ConnectionStatusKind.reconnecting);
        expect(registry.current('n4')!.nextAt, isNotNull);
        expect(registry.current('n4')!.attempt, 1);

        tickets.failWith = null;
        client.connectForeground().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        expect(registry.current('n4')!.isConnected, isTrue);

        // The idle park is deliberate, not an outage.
        unawaited(client.disconnectIdle());
        async.flushMicrotasks();
        expect(registry.current('n4'), isNull);

        tickets.failWith = const DashboardAuthException(
          DashboardAuthFailureCode.loginRequired,
          statusCode: 401,
        );
        client.connectForeground().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        expect(registry.current('n4')!.kind, ConnectionStatusKind.authRequired);

        unawaited(client.close());
        async.flushMicrotasks();
        expect(registry.current('n4'), isNull);
      });
    });
  });

  group('chat visibility', () {
    const chatSaysConnected = ChatTransportStatus(ChatTransportState.connected);

    test(
      'an idle chat whose socket is down shows the loss at 3 s, not 5 min',
      () {
        fakeAsync((async) {
          var now = DateTime(2026);
          final visibility = ChatTransportVisibility(clock: () => now);
          final link = ConnectionStatus(
            ConnectionStatusKind.reconnecting,
            since: now,
          );
          visibility.update(
            link: link,
            status: chatTransportWithLink(chatSaysConnected, link),
            activeTurn: false,
            authRequired: false,
            appForeground: true,
          );
          async.elapse(const Duration(seconds: 2));
          now = now.add(const Duration(seconds: 2));
          expect(visibility.visible, isFalse);
          async.elapse(const Duration(seconds: 1, milliseconds: 100));
          expect(visibility.visible, isTrue);
          expect(visibility.linkKind, ConnectionStatusKind.reconnecting);
          visibility.dispose();
        });
      },
    );

    test('without the supervisor an idle loss still waits the 5 min grace', () {
      fakeAsync((async) {
        final now = DateTime(2026);
        final visibility = ChatTransportVisibility(clock: () => now);
        visibility.update(
          status: ChatTransportStatus(
            ChatTransportState.reconnecting,
            disconnectedSince: now,
          ),
          activeTurn: false,
          authRequired: false,
          appForeground: true,
        );
        async.elapse(const Duration(seconds: 10));
        expect(visibility.visible, isFalse);
        visibility.dispose();
      });
    });

    test(
      'chatTransportWithLink never reports connected over a down socket',
      () {
        final since = DateTime(2026);
        final merged = chatTransportWithLink(
          chatSaysConnected,
          ConnectionStatus(ConnectionStatusKind.noNetwork, since: since),
        );
        expect(merged.isConnected, isFalse);
        expect(merged.state, ChatTransportState.offline);
        expect(merged.disconnectedSince, since);
        expect(
          chatTransportWithLink(chatSaysConnected, null),
          same(chatSaysConnected),
        );
      },
    );

    test('five flaps in a minute say «Reconnected» once', () {
      fakeAsync((async) {
        final start = DateTime(2026);
        DateTime now() => start.add(async.elapsed);
        final visibility = ChatTransportVisibility(clock: now);
        for (var flap = 0; flap < 5; flap++) {
          visibility.update(
            status: ChatTransportStatus(
              ChatTransportState.reconnecting,
              disconnectedSince: now(),
            ),
            activeTurn: true,
            authRequired: false,
            appForeground: true,
          );
          async.elapse(const Duration(seconds: 4)); // shown after 3 s
          expect(visibility.visible, isTrue);
          visibility.update(
            status: const ChatTransportStatus(ChatTransportState.connected),
            activeTurn: true,
            authRequired: false,
            appForeground: true,
          );
          async.elapse(const Duration(seconds: 3)); // hysteresis 2 s
          expect(visibility.visible, isFalse);
        }
        expect(async.elapsed, lessThan(const Duration(seconds: 60)));
        expect(visibility.recoveries, 1, reason: 'one notice per minute');
        expect(visibility.lossEpoch, 5, reason: 'each loss still ends');

        // A new loss a minute later may say it again.
        async.elapse(const Duration(seconds: 60));
        visibility.update(
          status: ChatTransportStatus(
            ChatTransportState.reconnecting,
            disconnectedSince: now(),
          ),
          activeTurn: true,
          authRequired: false,
          appForeground: true,
        );
        async.elapse(const Duration(seconds: 4));
        visibility.update(
          status: const ChatTransportStatus(ChatTransportState.connected),
          activeTurn: true,
          authRequired: false,
          appForeground: true,
        );
        async.elapse(const Duration(seconds: 3));
        expect(visibility.recoveries, 2);
        visibility.dispose();
      });
    });

    test('the persistent notice appears only after 5 minutes failing', () {
      fakeAsync((async) {
        final start = DateTime(2026);
        DateTime now() => start.add(async.elapsed);
        final visibility = ChatTransportVisibility(clock: now);
        visibility.update(
          status: ChatTransportStatus(
            ChatTransportState.reconnecting,
            disconnectedSince: now(),
          ),
          activeTurn: true,
          authRequired: false,
          appForeground: true,
        );
        async.elapse(const Duration(minutes: 4, seconds: 59));
        expect(visibility.visible, isTrue);
        expect(visibility.persistent, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(visibility.persistent, isTrue);
        visibility.update(
          status: const ChatTransportStatus(ChatTransportState.connected),
          activeTurn: true,
          authRequired: false,
          appForeground: true,
        );
        async.elapse(const Duration(seconds: 3));
        expect(visibility.persistent, isFalse);
        visibility.dispose();
      });
    });
  });

  group('drawer', () {
    Future<void> pump(
      WidgetTester tester, {
      required bool connected,
      ConnectionStatusKind? link,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final connection = SavedConnection(
        id: 'demo',
        label: 'demo',
        host: '127.0.0.1',
        port: 8642,
        apiKey: '',
      );
      await manager.upsertConnection(connection);
      await manager.setActiveConnection(connection.id);
      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            key: scaffoldKey,
            body: const SizedBox.shrink(),
            drawer: HermesDrawer(
              connection: connection,
              connManager: manager,
              current: DrawerSection.home,
              connected: connected,
              link: link,
              recentSessionsClientFactory: (saved) => ApiClient(
                baseUrl: saved.baseUrl,
                apiKey: 'unused',
                httpClient: MockClient(
                  (_) async =>
                      http.Response('{"object":"list","data":[]}', 200),
                ),
              ),
            ),
          ),
        ),
      );
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();
    }

    testWidgets('REST ok with the socket reconnecting says reconectando', (
      tester,
    ) async {
      await pump(
        tester,
        connected: true,
        link: ConnectionStatusKind.reconnecting,
      );
      expect(find.text('demo · reconectando…'), findsOneWidget);
      expect(find.textContaining('en línea'), findsNothing);
    });

    for (final (kind, word) in [
      (ConnectionStatusKind.noNetwork, 'sin red'),
      (ConnectionStatusKind.noServer, 'sin servidor'),
      (ConnectionStatusKind.authRequired, 'requiere iniciar sesión'),
    ]) {
      testWidgets('$kind has its own word', (tester) async {
        await pump(tester, connected: false, link: kind);
        expect(find.text('demo · $word'), findsOneWidget);
      });
    }
  });
}
