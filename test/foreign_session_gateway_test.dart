// Wire contract of session.foreign.*: exact params, 60 s timeout window and
// -32601 turning the entry off.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/foreign_session.dart';
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
      id: 'foreign-wire',
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
  test('list sends profile, source and offset and nothing else', () async {
    final h = _client(
      (_) => {
        'sessions': [
          {'id': 'h1', 'source': 'claude', 'label': 'Claude Code', 'mtime': 1},
        ],
        'next_offset': 25,
        'host': 'srv.example.test',
      },
    );
    final page = await h.client.foreignList(
      profile: 'work',
      source: ForeignSource.codex,
      offset: 25,
    );
    expect(_last(h.requests, 'session.foreign.list'), {
      'profile': 'work',
      'source': 'codex',
      'offset': 25,
    });
    expect(page.nextOffset, 25);
    expect(page.sessions.single.id, 'h1');
  });

  test('list without filters omits source and offset', () async {
    final h = _client((_) => {'sessions': <Object>[], 'host': 'h'});
    await h.client.foreignList(profile: 'default');
    expect(_last(h.requests, 'session.foreign.list'), {'profile': 'default'});
  });

  test('import sends exactly profile and id', () async {
    final h = _client((_) => {'session_id': 'local-1'});
    final result = await h.client.foreignImport(
      'opaque-handle',
      profile: 'work',
    );
    expect(_last(h.requests, 'session.foreign.import'), {
      'profile': 'work',
      'id': 'opaque-handle',
    });
    expect(result.sessionId, 'local-1');
  });

  test('preview sends profile and id', () async {
    final h = _client((_) => {'messages': <Object>[], 'total': 0});
    await h.client.foreignPreview('opaque-handle', profile: 'work');
    expect(_last(h.requests, 'session.foreign.preview'), {
      'profile': 'work',
      'id': 'opaque-handle',
    });
  });

  test('-32601 turns the entry off and is not retried', () async {
    final h = _client((_) => -32601);
    expect(h.client.foreignSessionsAvailable, isTrue);
    await expectLater(
      h.client.foreignList(profile: 'work'),
      throwsA(
        isA<DesktopControlFailure>().having(
          (f) => f.kind,
          'kind',
          DesktopControlFailureKind.unsupported,
        ),
      ),
    );
    expect(h.client.foreignSessionsAvailable, isFalse);
    await expectLater(
      h.client.foreignList(profile: 'work'),
      throwsA(isA<DesktopControlFailure>()),
    );
    expect(
      h.requests.where((r) => r['method'] == 'session.foreign.list').length,
      1,
    );
  });

  test('a read-only connection never imports and hides the entry', () async {
    final h = _client((_) => {'session_id': 'x'}, readOnly: true);
    expect(h.client.foreignSessionsAvailable, isFalse);
    await expectLater(
      h.client.foreignImport('opaque', profile: 'work'),
      throwsA(isA<DesktopControlFailure>()),
    );
    expect(
      h.requests.where((r) => r['method'] == 'session.foreign.import'),
      isEmpty,
    );
  });
}
