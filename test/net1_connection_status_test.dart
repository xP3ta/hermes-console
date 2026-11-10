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
import 'support/test_api_client.dart';

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

/// A link that never reached `ready` (first dials of a cold start).
final class _NeverUpLink implements ConnectionLinkSource, LinkHistorySource {
  final ConnectionSignal signal = ConnectionSignal();
  @override
  bool isConnected = false;
  @override
  bool isClosed = false;
  @override
  bool linkAuthRejected = false;
  @override
  DateTime? linkReconnectAt;
  @override
  int linkReconnectAttempt = 0;
  @override
  bool linkParked = false;
  @override
  bool get linkHasBeenUp => false;
  @override
  Listenable get linkListenable => signal;

  void change(void Function() edit) {
    edit();
    signal.notify();
  }
}

/// A link whose last ticket said the server is booting.
final class _StartingLinkForQuiet
    implements ConnectionLinkSource, ServerStartingLinkSource {
  final ConnectionSignal signal = ConnectionSignal();
  @override
  bool isConnected = false;
  @override
  bool isClosed = false;
  @override
  bool linkAuthRejected = false;
  @override
  DateTime? linkReconnectAt;
  @override
  int linkReconnectAttempt = 0;
  @override
  bool linkParked = false;
  @override
  bool get linkServerStarting => true;
  @override
  Listenable get linkListenable => signal;

  void change(void Function() edit) {
    edit();
    signal.notify();
  }
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
        // qrc: a first redial is quiet for the screens; the raw status and a
        // second attempt say the truth.
        expect(registry.current('c'), isNull);
        expect(
          registry.currentRaw('c')!.kind,
          ConnectionStatusKind.reconnecting,
        );
        link.change(() => link.linkReconnectAttempt = 2);
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
        final first = timed.currentRaw('t')!.since;
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

  group('quiet window (qrc)', () {
    ConnectionStatusRegistry timed(FakeAsync async) => ConnectionStatusRegistry(
      clock: () => DateTime(2026).add(async.elapsed),
    );

    test(
      'a loss whose redial ends inside the window never changes the word',
      () {
        fakeAsync((async) {
          final registry = timed(async);
          final link = FakeConnectionLink();
          final published = <ConnectionStatusKind?>[];
          registry.changes.addListener(
            () => published.add(registry.current('c')?.kind),
          );
          registry.bind('c', link);
          link.change(() => link.isConnected = true);
          expect(registry.current('c')!.isConnected, isTrue);

          link.change(
            () => link
              ..isConnected = false
              ..linkReconnectAt = DateTime(2026)
              ..linkReconnectAttempt = 1,
          );
          expect(registry.current('c')!.isConnected, isTrue, reason: 'quiet');
          expect(
            registry.currentRaw('c')!.kind,
            ConnectionStatusKind.reconnecting,
            reason: 'the chat still sees the loss at once',
          );
          async.elapse(const Duration(seconds: 2));
          link.change(
            () => link
              ..isConnected = true
              ..linkReconnectAt = null,
          );
          async.elapse(const Duration(seconds: 5));
          expect(
            published.where((kind) => kind != ConnectionStatusKind.connected),
            isEmpty,
            reason: 'Home, the drawer and the list header never said anything',
          );
        });
      },
    );

    test('a redial still running at the end of the window is shown, with '
        'the original since', () {
      fakeAsync((async) {
        final registry = timed(async);
        final link = FakeConnectionLink();
        registry.bind('c', link);
        link.change(() => link.isConnected = true);
        final lostAt = DateTime(2026).add(async.elapsed);
        link.change(
          () => link
            ..isConnected = false
            ..linkReconnectAt = lostAt
            ..linkReconnectAttempt = 1,
        );
        async.elapse(
          ConnectionStatusRegistry.quietWindow -
              const Duration(milliseconds: 1),
        );
        expect(registry.current('c')!.isConnected, isTrue);
        async.elapse(const Duration(milliseconds: 1));
        final shown = registry.current('c')!;
        expect(shown.kind, ConnectionStatusKind.reconnecting);
        expect(
          shown.since,
          lostAt,
          reason: 'since is the detection, not the end of the window',
        );
      });
    });

    test('a second failed attempt, no network, no server, a refused login '
        'and a booting server are shown at once', () {
      fakeAsync((async) {
        final registry = timed(async);
        final link = FakeConnectionLink();
        registry.bind('c', link);
        link.change(() => link.isConnected = true);
        link.change(
          () => link
            ..isConnected = false
            ..linkReconnectAt = DateTime(2026)
            ..linkReconnectAttempt = 2,
        );
        expect(registry.current('c')!.kind, ConnectionStatusKind.reconnecting);

        registry.reset();
        final fresh = FakeConnectionLink();
        registry.bind('d', fresh);
        fresh.change(() => fresh.isConnected = true);
        fresh.change(
          () => fresh
            ..isConnected = false
            ..linkReconnectAt = DateTime(2026)
            ..linkReconnectAttempt = 1,
        );
        expect(registry.current('d')!.isConnected, isTrue, reason: 'quiet');
        registry.setNetworkLost(true);
        expect(registry.current('d')!.kind, ConnectionStatusKind.noNetwork);
        registry.setNetworkLost(false);
        expect(
          registry.current('d')!.kind,
          ConnectionStatusKind.reconnecting,
          reason: 'once shown, a loss stays shown',
        );

        registry.reset();
        final rest = FakeConnectionLink();
        registry.bind('e', rest);
        rest.change(() => rest.isConnected = true);
        rest.change(
          () => rest
            ..isConnected = false
            ..linkReconnectAt = DateTime(2026)
            ..linkReconnectAttempt = 1,
        );
        registry.reportRest('e', reachable: false);
        expect(registry.current('e')!.kind, ConnectionStatusKind.noServer);

        registry.reset();
        final auth = FakeConnectionLink();
        registry.bind('f', auth);
        auth.change(() => auth.isConnected = true);
        auth.change(
          () => auth
            ..isConnected = false
            ..linkAuthRejected = true
            ..linkReconnectAttempt = 1,
        );
        expect(registry.current('f')!.kind, ConnectionStatusKind.authRequired);

        registry.reset();
        final starting = _StartingLinkForQuiet();
        registry.bind('g', starting);
        starting.change(() => starting.isConnected = true);
        starting.change(
          () => starting
            ..isConnected = false
            ..linkReconnectAt = DateTime(2026)
            ..linkReconnectAttempt = 1,
        );
        expect(registry.current('g')!.kind, ConnectionStatusKind.starting);
      });
    });

    test('without a listener the window arms no timer; a read settles it', () {
      fakeAsync((async) {
        final registry = timed(async);
        final link = FakeConnectionLink();
        registry.bind('c', link);
        link.change(() => link.isConnected = true);
        link.change(
          () => link
            ..isConnected = false
            ..linkReconnectAt = DateTime(2026)
            ..linkReconnectAttempt = 1,
        );
        expect(registry.current('c')!.isConnected, isTrue, reason: 'quiet');
        expect(
          async.nonPeriodicTimerCount,
          0,
          reason: 'a disposed screen leaves nothing pending',
        );
        async.elapse(ConnectionStatusRegistry.quietWindow);
        expect(registry.current('c')!.kind, ConnectionStatusKind.reconnecting);

        // A listener arms the timer; the last one leaving cancels it.
        link.change(
          () => link
            ..isConnected = true
            ..linkReconnectAt = null,
        );
        void listener() {}
        registry.changes.addListener(listener);
        link.change(
          () => link
            ..isConnected = false
            ..linkReconnectAt = DateTime(2026)
            ..linkReconnectAttempt = 1,
        );
        expect(async.nonPeriodicTimerCount, 1);
        registry.changes.removeListener(listener);
        expect(async.nonPeriodicTimerCount, 0);
      });
    });

    test('a socket that never was up is «connecting» after the window, and '
        'the word is not «reconnecting»', () {
      fakeAsync((async) {
        final registry = timed(async);
        final link = _NeverUpLink();
        registry.bind('c', link);
        link.change(
          () => link
            ..linkReconnectAt = DateTime(2026)
            ..linkReconnectAttempt = 1,
        );
        expect(registry.current('c'), isNull, reason: 'quiet: nothing known');
        async.elapse(ConnectionStatusRegistry.quietWindow);
        expect(registry.current('c')!.kind, ConnectionStatusKind.connecting);
        expect(
          deriveConnectionStatus(
            socketReady: false,
            authRejected: false,
            networkLost: false,
            linkHasBeenUp: false,
          ).kind,
          ConnectionStatusKind.connecting,
        );
        expect(
          deriveConnectionStatus(
            socketReady: false,
            authRejected: false,
            networkLost: false,
            linkHasBeenUp: false,
            restReachable: false,
          ).kind,
          ConnectionStatusKind.noServer,
          reason: 'a dead server is still a dead server on a cold start',
        );
        for (final language in [
          'es',
          'en',
          'pt',
          'de',
          'fr',
          'it',
          'ja',
          'ko',
          'zh',
        ]) {
          final s = lookupStrings(Locale(language));
          expect(
            connectionStatusWord(s, ConnectionStatusKind.connecting),
            isNot(connectionStatusWord(s, ConnectionStatusKind.reconnecting)),
            reason: language,
          );
        }
      });
    });
  });

  group('real client', () {
    test('socket edges drive the status: ticket transport failure, redial, '
        'credential refusal, close', () {
      fakeAsync((async) {
        final registry = ConnectionStatusRegistry(
          clock: () => DateTime(2026).add(async.elapsed),
        );
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
        // qrc: the first failed dial is quiet for the window, and a socket
        // that never was up is «connecting», not «reconnecting».
        expect(registry.current('n4'), isNull);
        expect(
          registry.currentRaw('n4')!.kind,
          ConnectionStatusKind.connecting,
        );
        async.elapse(ConnectionStatusRegistry.quietWindow);
        expect(registry.current('n4')!.kind, ConnectionStatusKind.connecting);
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
              recentSessionsClientFactory: (saved) => testApiClient(
                baseUrl: saved.baseUrl,
                httpClient: MockClient(
                  // An empty recents list in the Dashboard's shape.
                  (_) async => http.Response('{"sessions":[],"total":0}', 200),
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
      (ConnectionStatusKind.connecting, 'conectando…'),
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
