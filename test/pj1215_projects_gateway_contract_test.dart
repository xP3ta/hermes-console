// Wire contract for the Projects write surface: exact JSON-RPC methods and
// params, Dashboard git routes and the `session.create` workspace pair, all
// as Hermes Desktop sends them.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _RecordingDashboard extends DashboardClient {
  _RecordingDashboard()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  final List<(String, String, Map<String, dynamic>?)> calls = [];
  int? failStatus;
  Map<String, dynamic> Function(String endpoint)? respond;

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 't');

  Map<String, dynamic> _answer(String endpoint) {
    final status = failStatus;
    if (status != null) throw DashboardHttpException(status);
    return respond?.call(endpoint) ?? <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    calls.add(('GET', endpoint, null));
    return _answer(endpoint);
  }

  @override
  Future<Map<String, dynamic>> apiPost(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(('POST', endpoint, body));
    return _answer(endpoint);
  }
}

typedef _Responder = Object Function(Map<String, dynamic> frame);

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
        if (answer is _RpcError)
          'error': {'code': answer.code, 'message': 'x'}
        else
          'result': answer,
      }),
    );
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RpcError {
  final int code;
  const _RpcError(this.code);
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

Object _defaultAnswer(Map<String, dynamic> frame) => switch (frame['method']) {
  'gateway.capabilities' => {'per_session_exclusive_submit': true},
  'client.capabilities' => {'server_requests': <String>[]},
  'projects.update' || 'projects.create' => {
    'project': {'id': 'p_1'},
  },
  'projects.delete' => {'projects': <Object>[], 'active_id': null},
  'projects.set_active' => {'active_id': 'p_1'},
  'session.create' => {'session_id': 'rt-1', 'stored_session_id': 'st-1'},
  _ => <String, dynamic>{},
};

({
  TuiGatewayClient client,
  List<Map<String, dynamic>> requests,
  _RecordingDashboard dashboard,
})
_client({bool readOnly = false, _Responder respond = _defaultAnswer}) {
  final requests = <Map<String, dynamic>>[];
  final dashboard = _RecordingDashboard();
  final client = TuiGatewayClient(
    SavedConnection(
      id: 'pj1215-wire',
      label: 'wire',
      host: 'hermes.local',
      port: 8642,
      apiKey: 'k',
      readOnly: readOnly,
    ),
    dashboard: dashboard,
    channelFactory: (_, _) => _Channel(requests, respond),
  );
  addTearDown(client.close);
  return (client: client, requests: requests, dashboard: dashboard);
}

Map<String, dynamic>? _params(List<Map<String, dynamic>> requests, String m) =>
    requests.lastWhere((r) => r['method'] == m)['params']
        as Map<String, dynamic>?;

void main() {
  test('projects.update sends id + changed fields only', () async {
    final h = _client();
    await h.client.updateProject('p_abc', name: 'Console');
    expect(_params(h.requests, 'projects.update'), {
      'id': 'p_abc',
      'name': 'Console',
    });
    await h.client.updateProject('p_abc', color: 'hsl(30 68% 58%)');
    expect(_params(h.requests, 'projects.update'), {
      'id': 'p_abc',
      'color': 'hsl(30 68% 58%)',
    });
    await h.client.updateProject('p_abc', icon: '');
    expect(_params(h.requests, 'projects.update'), {'id': 'p_abc', 'icon': ''});
  });

  test('project ids that are paths never reach a write RPC', () async {
    final h = _client();
    await expectLater(
      h.client.deleteProject('/srv/work/repo'),
      throwsA(isA<DesktopControlFailure>()),
    );
    await expectLater(
      h.client.updateProject('p_x', icon: 'Bad Icon!'),
      throwsA(isA<DesktopControlFailure>()),
    );
    expect(h.requests.where((r) => r['method'] == 'projects.delete'), isEmpty);
  });

  test('projects.create adopts an auto repo like Desktop', () async {
    final h = _client();
    await h.client.createProject(
      name: 'homelab',
      primaryPath: '/srv/work/homelab',
      icon: 'rocket',
    );
    expect(_params(h.requests, 'projects.create'), {
      'name': 'homelab',
      'folders': ['/srv/work/homelab'],
      'primary_path': '/srv/work/homelab',
      'icon': 'rocket',
      'use': false,
    });
  });

  test('projects.delete and projects.set_active', () async {
    final h = _client();
    await h.client.deleteProject('p_1');
    await h.client.setActiveProject('p_1');
    expect(_params(h.requests, 'projects.delete'), {'id': 'p_1'});
    expect(_params(h.requests, 'projects.set_active'), {'id': 'p_1'});
  });

  test('read-only connections refuse every project write locally', () async {
    final h = _client(readOnly: true);
    expect(h.client.projectWritesAllowed, isFalse);
    await expectLater(
      h.client.deleteProject('p_1'),
      throwsA(
        isA<DesktopControlFailure>().having(
          (f) => f.kind,
          'kind',
          DesktopControlFailureKind.forbidden,
        ),
      ),
    );
    expect(
      () => h.client.addWorktree('/r', branch: 'x'),
      throwsA(isA<DesktopControlFailure>()),
    );
    expect(h.dashboard.calls, isEmpty);
  });

  test('-32601 on a project write is reported as unsupported', () async {
    final h = _client(
      respond: (frame) => frame['method'] == 'projects.update'
          ? const _RpcError(-32601)
          : _defaultAnswer(frame),
    );
    await expectLater(
      h.client.updateProject('p_1', name: 'x'),
      throwsA(
        isA<DesktopControlFailure>().having(
          (f) => f.kind,
          'kind',
          DesktopControlFailureKind.unsupported,
        ),
      ),
    );
  });

  test('git routes mirror Desktop remoteGit', () async {
    final h = _client();
    h.dashboard.respond = (endpoint) => switch (endpoint) {
      final e when e.startsWith('git/base-branches') => {
        'branches': [
          {'name': 'origin/main', 'isRemote': true, 'isDefault': true},
        ],
      },
      final e when e.startsWith('git/branches') => {
        'branches': [
          {'name': 'fix/a', 'checkedOut': false},
        ],
      },
      'git/worktree/add' => {
        'path': '/srv/repo/.worktrees/x',
        'branch': 'x',
        'repoRoot': '/srv/repo',
      },
      _ => <String, dynamic>{},
    };

    final bases = await h.client.listBaseBranches('/srv/my repo');
    expect(bases.single.isDefault, isTrue);
    final branches = await h.client.listBranches('/srv/repo');
    expect(branches.single.name, 'fix/a');
    final created = await h.client.addWorktree(
      '/srv/repo',
      branch: 'x',
      base: 'origin/main',
    );
    await h.client.addWorktree('/srv/repo', existingBranch: 'fix/a');
    await h.client.switchBranch('/srv/repo', 'main');

    expect(created.path, '/srv/repo/.worktrees/x');
    expect(
      [
        for (final c in h.dashboard.calls) [c.$1, c.$2, c.$3],
      ],
      [
        ('GET', 'git/base-branches?path=%2Fsrv%2Fmy+repo', null),
        ('GET', 'git/branches?path=%2Fsrv%2Frepo', null),
        (
          'POST',
          'git/worktree/add',
          {
            'path': '/srv/repo',
            'name': 'x',
            'branch': 'x',
            'base': 'origin/main',
          },
        ),
        (
          'POST',
          'git/worktree/add',
          {'path': '/srv/repo', 'existingBranch': 'fix/a'},
        ),
        ('POST', 'git/branch/switch', {'path': '/srv/repo', 'branch': 'main'}),
      ].map((c) => [c.$1, c.$2, c.$3]).toList(),
    );
  });

  test('a backend without /api/git is remembered as unsupported', () async {
    final h = _client();
    h.dashboard.failStatus = 404;
    await expectLater(
      h.client.listBaseBranches('/srv/repo'),
      throwsA(
        isA<DesktopControlFailure>().having(
          (f) => f.kind,
          'kind',
          DesktopControlFailureKind.unsupported,
        ),
      ),
    );
    h.dashboard.failStatus = null;
    await expectLater(
      h.client.listBranches('/srv/repo'),
      throwsA(isA<DesktopControlFailure>()),
    );
    expect(h.dashboard.calls, hasLength(1), reason: 'gated after a 404');
  });

  test(
    'session.create carries cwd + cwd_explicit for a project chat',
    () async {
      final h = _client();
      await h.client.createForFirstSubmitConfigured(
        config: const DesktopSessionCreateConfig(
          workspace: '/home/demo/code/hermes-console',
        ),
      );
      final params = _params(h.requests, 'session.create')!;
      expect(params['cwd'], '/home/demo/code/hermes-console');
      expect(params['cwd_explicit'], isTrue);
      expect(params['source'], 'desktop');

      await h.client.createForFirstSubmitConfigured(
        config: const DesktopSessionCreateConfig(),
      );
      final plain = _params(h.requests, 'session.create')!;
      expect(plain.containsKey('cwd'), isFalse);
      expect(plain.containsKey('cwd_explicit'), isFalse);
    },
  );
}
