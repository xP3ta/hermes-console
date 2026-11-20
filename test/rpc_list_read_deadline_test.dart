// SPDX-License-Identifier: GPL-3.0-only
// The plain list reads a screen waits on with its spinner (the Bots screen,
// Profiles, Extensions, Projects, the agent center) end at Desktop's
// ordinary deadline, 30 s (apps/desktop/src/api/client.ts
// DEFAULT_GATEWAY_REQUEST_TIMEOUT_MS), instead of holding the spinner for
// 120 s when one call hangs. A read the server answers after 25 s, on a
// slow phone network, still succeeds.
import 'dart:async';
import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/spec070_fixtures.dart';

class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');
  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'test');
}

/// An in-memory gateway socket: `gateway.ready` at once, then each RPC is
/// answered after [delayOf] its method (never when that is null) with
/// [resultOf] it, or `{}`.
final class _SlowChannel implements WebSocketChannel {
  _SlowChannel(this.delayOf, this.resultOf) {
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final Duration? Function(String method) delayOf;
  final Map<String, dynamic>? Function(String method) resultOf;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _Sink(this);

  void _onFrame(Map<String, dynamic> frame) {
    final id = frame['id'];
    final method = '${frame['method']}';
    if (id is! int) return;
    final delay = delayOf(method);
    if (delay == null) return;
    Timer(delay, () {
      if (_incoming.isClosed) return;
      _incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': resultOf(method) ?? <String, dynamic>{},
        }),
      );
    });
  }

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Sink implements WebSocketSink {
  _Sink(this.channel);

  final _SlowChannel channel;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) => channel._onFrame(
    Map<String, dynamic>.from(jsonDecode(data as String) as Map),
  );

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

/// The read under test and what the server answers it with.
typedef _Read = ({
  String method,
  Future<Object?> Function(TuiGatewayClient client) call,
  Map<String, dynamic>? result,
});

void main() {
  final groupsCapabilities = spec070Result('groups_capabilities');
  final reads = <_Read>[
    (
      method: 'profiles.list',
      call: (c) => c.listProfiles(),
      result: spec070Result('profiles_list'),
    ),
    (
      method: 'groups.list',
      call: (c) => c.listGroupsDetailed(),
      result: spec070Result('groups_list'),
    ),
    (
      method: 'projects.tree',
      call: (c) => c.projectTree(),
      result: const {'projects': <Object>[]},
    ),
    (method: 'tools.list', call: (c) => c.extensionsInventory(), result: null),
    (
      method: 'session.active_list',
      call: (c) => c.listActiveSessions(),
      result: spec070Result('session_active_list'),
    ),
    (
      method: 'spawn_tree.list',
      call: (c) => c.agentCenterSnapshot(),
      result: null,
    ),
  ];

  /// Starts [read] with the server answering it after [answerAfter] (never
  /// when null) and every other call at once. Returns when it settled.
  ({Duration? settledAt, Object? error, Object? value}) run(
    _Read read, {
    required Duration? answerAfter,
    required Duration elapse,
  }) {
    late ({Duration? settledAt, Object? error, Object? value}) outcome;
    fakeAsync((async) {
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'deadline-${read.method}',
          label: 'Deadline',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'k',
          dashboardUrl: 'http://127.0.0.1:1',
        ),
        dashboard: _Dashboard(),
        heartbeatInterval: Duration.zero,
        now: () => DateTime(2026).add(async.elapsed),
        channelFactory: (_, _) => _SlowChannel(
          (method) => method == read.method ? answerAfter : Duration.zero,
          (method) => method == read.method
              ? read.result
              : method == 'groups.capabilities'
              ? groupsCapabilities
              : null,
        ),
      );
      unawaited(client.connect().catchError((Object _) {}));
      async.elapse(const Duration(milliseconds: 1));
      Duration? settledAt;
      Object? error;
      Object? value;
      final started = async.elapsed;
      read
          .call(client)
          .then<void>(
            (v) {
              value = v;
              settledAt = async.elapsed - started;
            },
            onError: (Object e) {
              error = e;
              settledAt = async.elapsed - started;
            },
          );
      async.elapse(elapse);
      outcome = (settledAt: settledAt, error: error, value: value);
      unawaited(client.close());
      async.flushMicrotasks();
    });
    return outcome;
  }

  for (final read in reads) {
    test('${read.method}: a read that never answers fails at 30 s, not '
        '120 s', () {
      final early = run(
        read,
        answerAfter: null,
        elapse: const Duration(seconds: 29, milliseconds: 999),
      );
      expect(early.settledAt, isNull, reason: 'still waiting at 29.999 s');
      final due = run(
        read,
        answerAfter: null,
        elapse: const Duration(seconds: 30),
      );
      expect(due.settledAt, const Duration(seconds: 30));
      expect(due.error, isNotNull);
    });
  }

  for (final read in reads.where((r) => r.result != null)) {
    test('${read.method}: an answer at 25 s still arrives', () {
      final outcome = run(
        read,
        answerAfter: const Duration(seconds: 25),
        elapse: const Duration(seconds: 26),
      );
      expect(outcome.error, isNull);
      expect(outcome.settledAt, const Duration(seconds: 25));
      expect(outcome.value, isNotNull);
    });
  }
}
