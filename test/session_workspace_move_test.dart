// `session.workspace.move` as Hermes Desktop sends it: the stored session key
// and a folder, plus the profile when there is one. Failures reach the screen
// as sanitized `DesktopControlFailure`s with no server text.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _RpcError {
  final int code;
  const _RpcError(this.code);
}

typedef _Responder = Object? Function(Map<String, dynamic> frame);

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
  final _Responder respond;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();

  void drop() => unawaited(_incoming.close());

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _Sink((data) {
    final frame = Map<String, dynamic>.from(jsonDecode(data as String) as Map);
    requests.add(frame);
    final answer = respond(frame);
    if (answer == null) return;
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': frame['id'],
        if (answer is _RpcError)
          'error': {'code': answer.code, 'message': 'PRIVATE /srv/secret'}
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

Object? _ok(Map<String, dynamic> frame) => switch (frame['method']) {
  'gateway.capabilities' => {'per_session_exclusive_submit': true},
  'client.capabilities' => {'server_requests': <String>[]},
  'session.workspace.move' => {
    'cwd': '/srv/work/repo',
    'branch': 'main',
    'git_repo_root': '/srv/work/repo',
  },
  _ => <String, dynamic>{},
};

({
  TuiGatewayClient client,
  List<Map<String, dynamic>> requests,
  List<_Channel> channels,
})
_client({bool readOnly = false, _Responder respond = _ok}) {
  final requests = <Map<String, dynamic>>[];
  final channels = <_Channel>[];
  final client = TuiGatewayClient(
    SavedConnection(
      id: 'sx-move',
      label: 'move',
      host: 'hermes.example.test',
      port: 8642,
      apiKey: 'k',
      readOnly: readOnly,
    ),
    dashboard: DashboardClient(
      host: '127.0.0.1',
      port: 1,
      manualToken: 'unused',
    ),
    channelFactory: (_, _) {
      final channel = _Channel(requests, respond);
      channels.add(channel);
      return channel;
    },
  );
  addTearDown(client.close);
  return (client: client, requests: requests, channels: channels);
}

List<Map<String, dynamic>> _moves(List<Map<String, dynamic>> requests) => [
  for (final r in requests)
    if (r['method'] == 'session.workspace.move') r,
];

void main() {
  test('sends the stored session key, the folder and the profile', () async {
    final h = _client();
    final result = await h.client.moveSessionWorkspace(
      sessionKey: 'stored-1',
      cwd: '/srv/work/repo',
      profile: 'work',
    );

    expect(_moves(h.requests).single['params'], {
      'session_key': 'stored-1',
      'cwd': '/srv/work/repo',
      'profile': 'work',
    });
    expect(result.cwd, '/srv/work/repo');
    expect(result.branch, 'main');
    expect(result.gitRepoRoot, '/srv/work/repo');
  });

  test('leaves the profile out when there is none', () async {
    final h = _client();
    await h.client.moveSessionWorkspace(
      sessionKey: 'stored-1',
      cwd: '/srv/work/repo',
    );
    await h.client.moveSessionWorkspace(
      sessionKey: 'stored-1',
      cwd: '/srv/work/repo',
      profile: '  ',
    );
    for (final move in _moves(h.requests)) {
      expect((move['params'] as Map).containsKey('profile'), isFalse);
    }
  });

  test('null branch and git root are absent, not empty', () async {
    final h = _client(
      respond: (frame) => frame['method'] == 'session.workspace.move'
          ? {'cwd': '/srv/work/plain', 'branch': null, 'git_repo_root': null}
          : _ok(frame),
    );
    final result = await h.client.moveSessionWorkspace(
      sessionKey: 'stored-1',
      cwd: '/srv/work/plain',
    );
    expect(result.cwd, '/srv/work/plain');
    expect(result.branch, isNull);
    expect(result.gitRepoRoot, isNull);
  });

  test('a result without a folder is an invalid response', () async {
    final h = _client(
      respond: (frame) => frame['method'] == 'session.workspace.move'
          ? {'cwd': ''}
          : _ok(frame),
    );
    await expectLater(
      h.client.moveSessionWorkspace(sessionKey: 'stored-1', cwd: '/srv/x'),
      throwsA(
        isA<DesktopControlFailure>().having(
          (f) => f.kind,
          'kind',
          DesktopControlFailureKind.invalidResponse,
        ),
      ),
    );
  });

  group('server errors become sanitized failures', () {
    Future<DesktopControlFailure> failWith(int code) async {
      final h = _client(
        respond: (frame) => frame['method'] == 'session.workspace.move'
            ? _RpcError(code)
            : _ok(frame),
      );
      try {
        await h.client.moveSessionWorkspace(
          sessionKey: 'stored-1',
          cwd: '/srv/work/repo',
        );
      } on DesktopControlFailure catch (failure) {
        return failure;
      }
      fail('expected a DesktopControlFailure');
    }

    test('4007 session not found', () async {
      final failure = await failWith(4007);
      expect(failure.kind, DesktopControlFailureKind.unavailable);
      expect(failure.code, 4007);
    });

    test('4016 cwd required', () async {
      final failure = await failWith(4016);
      expect(failure.kind, DesktopControlFailureKind.rejected);
      expect(failure.code, 4016);
    });

    test('4017 folder does not exist', () async {
      final failure = await failWith(4017);
      expect(failure.kind, DesktopControlFailureKind.rejected);
      expect(failure.code, 4017);
    });

    test('5007 move failed', () async {
      final failure = await failWith(5007);
      expect(failure.kind, DesktopControlFailureKind.rejected);
      expect(failure.code, 5007);
    });

    test('-32601 method not found is unsupported', () async {
      final failure = await failWith(-32601);
      expect(failure.kind, DesktopControlFailureKind.unsupported);
    });

    test('no server text or path reaches the failure', () async {
      final failure = await failWith(4017);
      expect(failure.toString(), isNot(contains('secret')));
      expect(failure.toString(), isNot(contains('/srv')));
    });
  });

  test('a read-only connection never reaches the network', () async {
    final h = _client(readOnly: true);
    await expectLater(
      h.client.moveSessionWorkspace(
        sessionKey: 'stored-1',
        cwd: '/srv/work/repo',
      ),
      throwsA(
        isA<DesktopControlFailure>().having(
          (f) => f.kind,
          'kind',
          DesktopControlFailureKind.forbidden,
        ),
      ),
    );
    expect(h.requests, isEmpty);
  });

  test('blank or control-character values are rejected locally', () async {
    final h = _client();
    for (final (key, cwd) in const [
      ('', '/srv/x'),
      ('stored-1', ''),
      ('stored-1', '/srv/x\n/etc'),
      ('stored\u0000-1', '/srv/x'),
    ]) {
      await expectLater(
        h.client.moveSessionWorkspace(sessionKey: key, cwd: cwd),
        throwsA(isA<DesktopControlFailure>()),
        reason: '$key|$cwd',
      );
    }
    expect(_moves(h.requests), isEmpty);
  });

  test('a socket drop during the move fails once and never retries', () async {
    final h = _client(
      respond: (frame) =>
          frame['method'] == 'session.workspace.move' ? null : _ok(frame),
    );
    final pending = h.client.moveSessionWorkspace(
      sessionKey: 'stored-1',
      cwd: '/srv/work/repo',
    );
    final outcome = expectLater(
      pending,
      throwsA(
        isA<DesktopControlFailure>().having(
          (f) => f.kind,
          'kind',
          DesktopControlFailureKind.unavailable,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    h.channels.single.drop();
    await outcome;
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(_moves(h.requests), hasLength(1));
  });
}
