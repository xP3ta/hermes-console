// SPDX-License-Identifier: GPL-3.0-only
// PX5C: the Dashboard process dies and comes back on the same port with an
// empty state and a new replay epoch. The chat's notice offers «Retry»
// (Desktop's foreground reconnect) and pressing it dials a fresh ticket and
// brings the link back. Synthetic fixtures only; a real loopback HttpServer
// and WebSocket shaped like Hermes (/, /api/auth/ws-ticket, /api/ws).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_status.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/widgets/connection_help_action.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/in_memory_compression_restore_storage.dart';

/// Hermes-shaped host that can be stopped (`close(force: true)`) and started
/// again on the same port with no memory of the previous run.
class _RestartableHermes {
  HttpServer? _server;
  int port = 0;
  int tickets = 0;
  int epoch = 0;
  final sockets = <WebSocket>[];

  Future<void> start() async {
    epoch += 1;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    port = _server!.port;
    _server!.listen((request) async {
      final path = request.uri.path;
      if (path == '/api/ws') {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        _serve(socket, epoch);
        return;
      }
      if (path == '/') {
        request.response.write('window.__HERMES_SESSION_TOKEN__="fixture";');
      } else if (path == '/api/auth/ws-ticket') {
        tickets += 1;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ticket': 't$tickets'}));
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  }

  Future<void> stop() async {
    // close(force) leaves upgraded sockets alone; a dead process drops them.
    for (final socket in sockets) {
      unawaited(socket.close(WebSocketStatus.goingAway).catchError((_) {}));
    }
    sockets.clear();
    await _server?.close(force: true);
    _server = null;
  }

  void _serve(WebSocket socket, int epoch) {
    void send(Map<String, dynamic> m) {
      if (socket.readyState != WebSocket.open) return;
      try {
        socket.add(jsonEncode({'jsonrpc': '2.0', ...m}));
      } on StateError {
        // The sink closed under us: the process is gone.
      }
    }

    send({
      'method': 'event',
      'params': {
        'type': 'gateway.ready',
        'payload': {'heartbeat': false, 'replay_epoch': 'epoch-$epoch'},
      },
    });
    socket.listen((raw) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      final method = frame['method'];
      if (method is! String) return;
      final params = (frame['params'] as Map?) ?? const {};
      // A server with a new, empty state knows no stored session: Hermes
      // answers the resume of a missing one with 4007.
      send({
        'id': frame['id'],
        if (method == 'session.resume' && epoch > 1)
          'error': {'code': 4007, 'message': 'session not found'}
        else
          'result': switch (method) {
            'session.resume' => {
              'session_id': 'runtime-a',
              'stored_session_id': params['session_id'],
              'status': 'idle',
              'running': false,
            },
            'session.active_list' => {'sessions': <Object>[]},
            'gateway.capabilities' => {'per_session_exclusive_submit': true},
            'client.capabilities' => {'server_requests': <Object>[]},
            _ => <String, dynamic>{},
          },
      });
    });
  }
}

Future<void> _until(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 8),
  String? reason,
}) async {
  final end = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: reason);
}

Future<Strings> _strings(WidgetTester tester, Locale locale) async {
  late Strings s;
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Builder(
        builder: (context) {
          s = Strings.of(context);
          return const SizedBox();
        },
      ),
    ),
  );
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the notice offers Retry', () {
    testWidgets('reconnecting, starting and unknown: «Retry» redials', (
      tester,
    ) async {
      for (final (locale, label) in [
        (const Locale('es'), 'Reintentar'),
        (const Locale('en'), 'Retry'),
      ]) {
        final str = await _strings(tester, locale);
        for (final kind in [
          ConnectionStatusKind.reconnecting,
          ConnectionStatusKind.starting,
          null,
        ]) {
          var retried = 0;
          final action = connectionIslandAction(
            str: str,
            kind: kind,
            simpleConnect: true,
            onOpenHelp: () => fail('Retry must not open the help page'),
            onRetry: () => retried++,
          );
          expect(action, isNotNull, reason: '$kind');
          expect(action!.label, label);
          expect(action.closes, isFalse);
          action.onPressed!();
          expect(retried, 1);
        }
      }
    });

    testWidgets('«What to do» stays only on no server; no Retry there', (
      tester,
    ) async {
      final str = await _strings(tester, const Locale('en'));
      var opened = 0;
      final action = connectionIslandAction(
        str: str,
        kind: ConnectionStatusKind.noServer,
        simpleConnect: true,
        onOpenHelp: () => opened++,
        onRetry: () => fail('no server offers the command page'),
      );
      expect(action!.label, 'What to do');
      action.onPressed!();
      expect(opened, 1);
    });

    testWidgets('no network and sign-in have nothing to press', (tester) async {
      final str = await _strings(tester, const Locale('en'));
      for (final kind in [
        ConnectionStatusKind.noNetwork,
        ConnectionStatusKind.authRequired,
      ]) {
        expect(
          connectionIslandAction(
            str: str,
            kind: kind,
            simpleConnect: true,
            onOpenHelp: () {},
            onRetry: () {},
          ),
          isNull,
          reason: '$kind',
        );
      }
    });
  });

  Future<void> scenario({required bool backoffStillRunning}) async {
    {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null,
          );
      final hermes = _RestartableHermes();
      await hermes.start();
      addTearDown(hermes.stop);
      final connection = SavedConnection(
        id: 'px5c',
        label: 'PX5C',
        host: '127.0.0.1',
        port: hermes.port,
        apiKey: 'fixture',
        dashboardUrl: 'http://127.0.0.1:${hermes.port}',
        kind: InstanceKind.vps,
      );
      late TuiGatewayClient gateway;
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
        desktopGatewayFactory: (c) => gateway = TuiGatewayClient(
          c,
          // Injected: a short ladder that has lapsed by the time the user
          // looks, or a fixed 3 s one that is still running.
          reconnectBackoff: GatewayReconnectBackoff(
            base: backoffStillRunning
                ? const Duration(seconds: 3)
                : const Duration(milliseconds: 20),
            random: () => 1.0,
          ),
        ),
      );
      addTearDown(service.dispose);
      // A new chat at rest: a draft with no stored session, nothing to reattach.
      final chat = service.attach(
        connection: connection,
        sessionId: 'draft-px5c',
        sessionTitle: 'New',
        sessionProfile: 'default',
        storedMessageLoader: (_, _) async => const [],
        attachDesktopRuntimeOnLoad: true,
        allowUnownedDesktopSnapshotForTesting: true,
        disableForegroundKeepAlive: true,
      );
      chat.markStoredSessionMissing();
      await chat.warmDesktopGateway();
      expect(gateway.isConnected, isTrue);

      // The process dies: no clean close frame, the port is released.
      await hermes.stop();
      await _until(() => !gateway.isConnected, reason: 'socket noticed');
      await hermes.start(); // same port, empty state, new epoch
      // Past the pooled keep-alive socket of the dead process; the lapsed case
      // waits on, until the short backoff is over and nobody is waiting on it.
      await Future<void>.delayed(
        Duration(milliseconds: backoffStillRunning ? 300 : 600),
      );
      expect(gateway.isBackingOff, backoffStillRunning);
      if (!backoffStillRunning) {
        // PX5A: a lapsed gap no longer strands the chat; the socket redialled
        // alone. Retry must then be harmless (no second socket).
        expect(gateway.isConnected, isTrue);
        await chat.retryConnectionNow();
        expect(hermes.sockets.length, 1);
        return;
      }
      final before = hermes.tickets;
      // What the chat did alone (evidence for the transport cut, not asserted
      // here: PX5A changes it).
      debugPrint(
        'PX5C alone: connected=${gateway.isConnected} tickets=$before',
      );

      // «Retry» (the notice's action) dials a fresh ticket and reconnects.
      final pressed = Stopwatch()..start();
      await chat.retryConnectionNow();
      if (backoffStillRunning) {
        expect(
          pressed.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason: 'Retry does not wait out the 3 s backoff',
        );
      }
      expect(
        hermes.tickets,
        greaterThan(before),
        reason: 'Retry mints a new ticket',
      );
      await _until(() => gateway.isConnected, reason: 'socket back');
      expect(chat.transportStatus.isConnected, isTrue);
    }
  }

  test('server dies and returns empty (backoff lapsed): redials alone', () {
    return scenario(backoffStillRunning: false);
  });

  test('server returns while the backoff still runs: Retry skips it', () {
    return scenario(backoffStillRunning: true);
  });
}
