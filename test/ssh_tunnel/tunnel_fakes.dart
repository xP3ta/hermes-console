// SPDX-License-Identifier: GPL-3.0-only
// Fakes for the Dashboard tunnel: no sockets, no SSH server.
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:hermes_android/core/services/ssh_dashboard_tunnel.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';

/// One end of a byte stream: [emit] is what arrives, [sent] what was written.
class FakeEnd implements TunnelEnd {
  FakeEnd() {
    _out.stream.listen(sent.addAll, onDone: () => writeClosed = true);
  }

  final _in = StreamController<List<int>>();
  final _out = StreamController<List<int>>();
  final sent = <int>[];
  bool writeClosed = false;
  bool destroyed = false;

  @override
  Stream<List<int>> get stream => _in.stream;

  @override
  StreamSink<List<int>> get sink => _out.sink;

  void emit(List<int> data) => _in.add(data);

  /// The peer stops sending.
  void finish() => unawaited(_in.close());

  @override
  void destroy() {
    destroyed = true;
    if (!_in.isClosed) unawaited(_in.close());
  }
}

class FakeServer implements TunnelServer {
  FakeServer(this.port);

  @override
  final int port;
  final _connections = StreamController<TunnelEnd>();
  bool closed = false;

  @override
  Stream<TunnelEnd> get connections => _connections.stream;

  /// A connection of the Dashboard client to the local port.
  FakeEnd accept() {
    final end = FakeEnd();
    _connections.add(end);
    return end;
  }

  @override
  Future<void> close() async {
    closed = true;
    await _connections.close();
  }
}

class FakeClient implements TunnelClient {
  final remotes = <FakeEnd>[];
  final forwards = <(String, int)>[];
  Object? forwardError;

  /// When set, forward never answers until it completes.
  Completer<void>? stall;
  bool closed = false;
  final _done = Completer<void>();

  @override
  Future<TunnelEnd> forward(String host, int port) async {
    forwards.add((host, port));
    final error = forwardError;
    if (error != null) throw error;
    await stall?.future;
    final end = FakeEnd();
    remotes.add(end);
    return end;
  }

  @override
  Future<void> get done => _done.future;

  /// The SSH link drops.
  void drop() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void close() {
    closed = true;
    drop();
  }
}

/// Hands out [FakeClient]s and [FakeServer]s and remembers how it was asked.
class TunnelRig {
  final clients = <FakeClient>[];
  final servers = <FakeServer>[];
  final preferred = <int?>[];
  final hostKeyAnswers = <bool>[];
  final loginsWith = <HostKeyDecision>[];

  /// A server key to ask about on every login; null = known and trusted.
  SshHostKeyPrompt? prompt;
  Object? forwardError;
  int nextPort = 41000;

  /// Ports the local bind refuses to give back (taken meanwhile).
  final taken = <int>{};

  Future<TunnelClient> client(TunnelSpec spec, HostKeyDecision ask) async {
    loginsWith.add(ask);
    final p = prompt;
    if (p != null) {
      final ok = await ask(p);
      hostKeyAnswers.add(ok);
      if (!ok) throw SSHHostkeyError('rejected');
    }
    final c = FakeClient()..forwardError = forwardError;
    clients.add(c);
    return c;
  }

  Future<TunnelServer> server(int? want) async {
    preferred.add(want);
    final port = want != null && !taken.contains(want) ? want : nextPort++;
    final s = FakeServer(port);
    servers.add(s);
    return s;
  }

  SshDashboardTunnels tunnels({
    TunnelLimits limits = const TunnelLimits(
      forwardTimeout: Duration(milliseconds: 80),
      halfCloseGrace: Duration(milliseconds: 80),
    ),
    void Function(String, int)? onPortChanged,
  }) => SshDashboardTunnels(
    clientFactory: client,
    serverFactory: server,
    limits: limits,
    backgroundGrace: Duration.zero,
    onPortChanged: onPortChanged,
  );
}

TunnelSpec fakeSpec({
  String id = 'c1',
  String dashHost = '127.0.0.1',
  int dashPort = 9119,
  int? preferredPort,
  String password = 'pw',
}) => TunnelSpec(
  id: id,
  ssh: const SshConfig(
    host: 'srv.example.com',
    port: 22,
    username: 'root',
    method: SshAuthMethod.password,
  ),
  credentials: SshCredentials(password: password),
  dashHost: dashHost,
  dashPort: dashPort,
  preferredPort: preferredPort,
);

Future<bool> trustNothing(SshHostKeyPrompt _) async => false;
Future<bool> trustAll(SshHostKeyPrompt _) async => true;
