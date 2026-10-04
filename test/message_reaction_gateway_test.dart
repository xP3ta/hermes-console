// Wire contract of message.react: exact params, the full reaction list back,
// read-only refusal and -32601 turning the capability off.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 't');
}

final class _Channel implements WebSocketChannel {
  _Channel(this.requests, this.respond) {
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final List<Map<String, dynamic>> requests;
  final Object Function(Map<String, dynamic> frame) respond;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _Sink((data) {
    final frame = Map<String, dynamic>.from(jsonDecode(data as String) as Map);
    requests.add(frame);
    final answer = respond(frame);
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': frame['id'],
        if (answer is int)
          'error': {'code': answer, 'message': 'x'}
        else
          'result': answer,
      }),
    );
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Sink implements WebSocketSink {
  _Sink(this.onAdd);
  final void Function(dynamic) onAdd;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) => onAdd(data);

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

({TuiGatewayClient client, List<Map<String, dynamic>> requests}) _client(
  Object Function(Map<String, dynamic> frame) respond, {
  bool readOnly = false,
}) {
  final requests = <Map<String, dynamic>>[];
  final client = TuiGatewayClient(
    SavedConnection(
      id: 'react-wire',
      label: 'wire',
      host: 'hermes.local',
      port: 8642,
      apiKey: 'k',
      readOnly: readOnly,
    ),
    dashboard: _Dashboard(),
    channelFactory: (_, _) => _Channel(requests, (frame) {
      return switch (frame['method']) {
        'gateway.capabilities' => {'per_session_exclusive_submit': true},
        'client.capabilities' => {'server_requests': <String>[]},
        _ => respond(frame),
      };
    }),
  );
  addTearDown(client.close);
  return (client: client, requests: requests);
}

Map<String, dynamic> _last(List<Map<String, dynamic>> r, String method) =>
    r.lastWhere((f) => f['method'] == method)['params'] as Map<String, dynamic>;

void main() {
  test('persisted rows send session, row id, emoji and author', () async {
    final h = _client(
      (_) => {
        'row_id': 42,
        'reactions': [
          {'emoji': '👍', 'author': 'user', 'at': 1.0},
        ],
      },
    );
    final result = await h.client.reactToMessage(
      'rt-1',
      rowId: 42,
      emoji: '👍',
      profile: 'work',
    );
    expect(_last(h.requests, 'message.react'), {
      'session_id': 'rt-1',
      'profile': 'work',
      'row_id': 42,
      'emoji': '👍',
      'author': 'user',
    });
    expect(result.rowId, 42);
    expect(result.reactions.single.emoji, '👍');
  });

  test('a live row names newest_role instead of a row id', () async {
    final h = _client((_) => {'row_id': 7, 'reactions': <Object>[]});
    await h.client.reactToMessage('rt-1', newestRole: 'assistant', emoji: null);
    final params = _last(h.requests, 'message.react');
    expect(params['newest_role'], 'assistant');
    expect(params.containsKey('row_id'), isFalse);
    expect(params.containsKey('emoji'), isFalse);
  });

  test('a call naming neither row nor role never leaves the device', () async {
    final h = _client((_) => {'row_id': 1, 'reactions': <Object>[]});
    await expectLater(
      h.client.reactToMessage('rt-1', emoji: '👍'),
      throwsA(isA<ArgumentError>()),
    );
    expect(h.requests.where((f) => f['method'] == 'message.react'), isEmpty);
  });

  test('a read-only connection refuses before sending', () async {
    final h = _client(
      (_) => {'row_id': 1, 'reactions': <Object>[]},
      readOnly: true,
    );
    await expectLater(
      h.client.reactToMessage('rt-1', rowId: 1, emoji: '👍'),
      throwsA(isA<DesktopControlFailure>()),
    );
    expect(h.requests.where((f) => f['method'] == 'message.react'), isEmpty);
  });

  test('-32601 turns reactions off for the connection', () async {
    final h = _client((_) => -32601);
    expect(await h.client.confirmMessageReactions('rt-1'), isFalse);
    expect(h.client.messageReactionsAvailable, isFalse);
    await expectLater(
      h.client.reactToMessage('rt-1', rowId: 1, emoji: '👍'),
      throwsA(isA<DesktopControlFailure>()),
    );
    expect(h.client.messageReactionsAvailable, isFalse);
  });

  group('availability is never assumed', () {
    test('a fresh connection offers nothing before it is confirmed', () {
      final h = _client((_) => {'row_id': 1, 'reactions': <Object>[]});
      expect(h.client.messageReactionsAvailable, isFalse);
    });

    test(
      'the probe names only the session, so nothing can be written',
      () async {
        final h = _client((_) => -32602);
        expect(await h.client.confirmMessageReactions('rt-1'), isTrue);
        expect(_last(h.requests, 'message.react'), {'session_id': 'rt-1'});
        expect(h.client.messageReactionsAvailable, isTrue);
      },
    );

    test(
      '-32601 on the probe keeps it hidden and is not asked again',
      () async {
        final h = _client((_) => -32601);
        expect(await h.client.confirmMessageReactions('rt-1'), isFalse);
        expect(await h.client.confirmMessageReactions('rt-1'), isFalse);
        expect(
          h.requests.where((f) => f['method'] == 'message.react').length,
          1,
        );
      },
    );

    test('any other failure confirms nothing', () async {
      final h = _client((_) => -32000);
      expect(await h.client.confirmMessageReactions('rt-1'), isFalse);
      expect(h.client.messageReactionsAvailable, isFalse);
    });

    test('a read-only connection is never probed', () async {
      final h = _client((_) => -32602, readOnly: true);
      expect(await h.client.confirmMessageReactions('rt-1'), isFalse);
      expect(h.requests.where((f) => f['method'] == 'message.react'), isEmpty);
    });

    test('a successful reaction confirms the capability', () async {
      final h = _client((_) => {'row_id': 1, 'reactions': <Object>[]});
      await h.client.reactToMessage('rt-1', rowId: 1, emoji: '👍');
      expect(h.client.messageReactionsAvailable, isTrue);
    });
  });

  test('an answer without a reaction list is rejected, not trusted', () async {
    final h = _client((_) => {'row_id': 1});
    await expectLater(
      h.client.reactToMessage('rt-1', rowId: 1, emoji: '👍'),
      throwsA(isA<DesktopControlFailure>()),
    );
  });
}
