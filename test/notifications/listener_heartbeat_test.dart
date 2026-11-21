// SPDX-License-Identifier: GPL-3.0-only
// The listener's gateway socket sent a `gateway.ping` every 15 s, the
// cadence of a Desktop window on screen, although it is never on screen: a
// hidden Desktop window's timers fire 60 s apart
// (apps/shared/src/json-rpc-channel.ts `startHeartbeat`). It now pings once a
// minute and still gives up on a silent peer after two unanswered pings.
import 'dart:async';
import 'dart:convert';

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/bot_mode_background.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'listener_idle_support.dart';

/// A transport that announces the heartbeat and answers every request,
/// `gateway.ping` included, until it goes [silent].
final class _PingChannel implements WebSocketChannel {
  _PingChannel() {
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'gateway.ready',
          'payload': {'heartbeat': true},
        },
      }),
    );
  }

  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  int pings = 0;
  bool silent = false;

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _PingSink(this);

  void onFrame(Map<String, dynamic> frame) {
    if (_incoming.isClosed) return;
    if (frame['method'] == 'gateway.ping') {
      pings++;
      if (silent) return;
    }
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': frame['id'],
        'result': <String, dynamic>{},
      }),
    );
  }

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _PingSink implements WebSocketSink {
  _PingSink(this.channel);

  final _PingChannel channel;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) =>
      channel.onFrame(Map<String, dynamic>.from(jsonDecode(data as String)));

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
  test('the listener socket pings once a minute and still drops a silent '
      'peer after two unanswered pings', () {
    fakeAsync((async) {
      final channels = <_PingChannel>[];
      final client = BotModeBackgroundMonitor.listenerGatewayClient(
        SavedConnection(
          id: 'ping-node',
          label: 'Ping node',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'k',
          dashboardUrl: 'http://127.0.0.1:1',
        ),
        dashboard: IdleTicket(),
        now: () => DateTime(2026).add(async.elapsed),
        channelFactory: (_, _) {
          final channel = _PingChannel();
          channels.add(channel);
          return channel;
        },
      );
      unawaited(client.connect().catchError((Object _) {}));
      async.elapse(const Duration(milliseconds: 10));
      expect(client.isConnected, isTrue);

      async.elapse(const Duration(minutes: 10));
      expect(channels.single.pings, 10, reason: 'one a minute, not 40');
      expect(client.isConnected, isTrue);

      channels.single.silent = true;
      async.elapse(const Duration(minutes: 2));
      expect(client.isConnected, isTrue, reason: 'two pings unanswered');
      async.elapse(const Duration(minutes: 1));
      expect(client.isConnected, isFalse, reason: 'declared dead');
      unawaited(client.close());
      async.flushMicrotasks();
    });
  });
}
