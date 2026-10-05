// Wire contract of shell.exec, terminal.resize and the process.list seed:
// exact params, the server's refusal text kept verbatim, -32601 turning the
// capability off.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/terminal_exec.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
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
        if (answer is Map && answer.containsKey('__error'))
          'error': {'code': answer['__error'], 'message': answer['message']}
        else if (answer is int)
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
      id: 'term-wire',
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

Iterable<Map<String, dynamic>> _calls(
  List<Map<String, dynamic>> r,
  String method,
) => r.where((f) => f['method'] == method);

void main() {
  test('shell.exec sends exactly command and profile', () async {
    final h = _client((_) => {'stdout': 'hi\n', 'stderr': '', 'code': 0});
    final result = await h.client.shellExec('echo hi', profile: 'work');
    expect(_last(h.requests, 'shell.exec'), {
      'command': 'echo hi',
      'profile': 'work',
    });
    expect(result.stdout, 'hi\n');
    expect(result.exitCode, 0);
  });

  test('the command is sent byte for byte, never rewritten', () async {
    final h = _client((_) => {'stdout': '', 'stderr': '', 'code': 0});
    const command = r'ls "$HOME" | wc -l ; echo \t';
    await h.client.shellExec(command, profile: 'p');
    expect(_last(h.requests, 'shell.exec')['command'], command);
  });

  test('a refusal keeps the server code and message verbatim', () async {
    final h = _client(
      (_) => {'__error': 4005, 'message': 'blocked: recursive delete'},
    );
    await expectLater(
      h.client.shellExec('rm -rf /', profile: 'p'),
      throwsA(
        isA<ShellExecRefusal>()
            .having((e) => e.code, 'code', 4005)
            .having((e) => e.message, 'message', 'blocked: recursive delete'),
      ),
    );
  });

  test('-32601 turns the terminal off for the connection', () async {
    final h = _client((_) => {'__error': -32601, 'message': 'nope'});
    expect(h.client.shellExecAvailable, isTrue);
    await expectLater(
      h.client.shellExec('ls', profile: 'p'),
      throwsA(isA<ShellExecUnsupported>()),
    );
    expect(h.client.shellExecAvailable, isFalse);
    final before = _calls(h.requests, 'shell.exec').length;
    await expectLater(
      h.client.shellExec('ls', profile: 'p'),
      throwsA(isA<ShellExecUnsupported>()),
    );
    expect(_calls(h.requests, 'shell.exec').length, before);
  });

  test('a read-only connection never sends a command', () async {
    final h = _client(
      (_) => {'stdout': '', 'stderr': '', 'code': 0},
      readOnly: true,
    );
    expect(h.client.shellExecAvailable, isFalse);
    await expectLater(
      h.client.shellExec('ls', profile: 'p'),
      throwsA(isA<ShellExecUnsupported>()),
    );
    expect(_calls(h.requests, 'shell.exec'), isEmpty);
  });

  test('a malformed answer is rejected, not rendered', () async {
    final h = _client((_) => {'stdout': 1});
    await expectLater(
      h.client.shellExec('ls', profile: 'p'),
      throwsA(isA<ShellExecFailure>()),
    );
  });

  test('an unknown failure carries no server text', () async {
    final h = _client((_) => {'__error': -32000, 'message': 'secret-marker'});
    await expectLater(
      h.client.shellExec('ls', profile: 'p'),
      throwsA(
        isA<ShellExecFailure>().having(
          (e) => e.toString(),
          'toString',
          isNot(contains('secret-marker')),
        ),
      ),
    );
  });

  test('terminal.resize records the width', () async {
    final h = _client((_) => {'cols': 90});
    await h.client.terminalResize('rt-1', 90);
    expect(_last(h.requests, 'terminal.resize'), {
      'session_id': 'rt-1',
      'cols': 90,
    });
  });

  test('terminal.resize failures are swallowed (width is cosmetic)', () async {
    final h = _client((_) => {'__error': -32601, 'message': 'x'});
    await h.client.terminalResize('rt-1', 90);
  });

  test('the process seed reads process.list once with output tails', () async {
    final h = _client(
      (_) => {
        'processes': [
          {
            'session_id': 'p1',
            'command': 'npm run dev',
            'status': 'running',
            'output_tail': 'ready\n',
            'exit_code': null,
          },
          {'session_id': 'p2', 'status': 'exited', 'exit_code': 1},
          {'command': 'no id'},
        ],
      },
    );
    final seeds = await h.client.agentProcessSeeds('rt-1', profile: 'work');
    expect(_calls(h.requests, 'process.list'), hasLength(1));
    expect(_last(h.requests, 'process.list'), {
      'session_id': 'rt-1',
      'profile': 'work',
    });
    expect(seeds.map((s) => s.id), ['p1', 'p2']);
    expect(seeds.first.outputTail, 'ready\n');
    expect(seeds.first.closed, isFalse);
    expect(seeds.last.closed, isTrue);
  });
}
