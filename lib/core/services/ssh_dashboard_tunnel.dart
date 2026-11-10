// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart';

import 'ssh_manager.dart';

/// Why a tunnel to the Dashboard could not be opened.
enum SshTunnelFailure {
  /// The SSH side failed; [SshTunnelException.ssh] says how.
  ssh,

  /// The SSH server did not open the connection to the Dashboard (a wrong
  /// host or port there).
  dashboardRefused,

  /// What was pasted is a public key; a private one is needed.
  publicKey,

  /// The private key is encrypted and no passphrase was given.
  passphraseNeeded,

  /// The tunnel already serves another Dashboard address.
  otherAddress,
}

class SshTunnelException implements Exception {
  const SshTunnelException(this.failure, [this.ssh]);

  final SshTunnelFailure failure;
  final SshFailure? ssh;

  @override
  String toString() => 'SshTunnelException(${failure.name}, ${ssh?.name})';
}

/// One end of a byte stream: a socket of this phone, or an SSH channel.
abstract interface class TunnelEnd {
  Stream<List<int>> get stream;
  StreamSink<List<int>> get sink;
  void destroy();
}

/// The loopback listener the Dashboard client connects to.
abstract interface class TunnelServer {
  int get port;
  Stream<TunnelEnd> get connections;
  Future<void> close();
}

/// An authenticated SSH connection that can reach the Dashboard.
abstract interface class TunnelClient {
  /// Opens a channel to [host]:[port] as seen from the SSH server.
  Future<TunnelEnd> forward(String host, int port);

  /// Completes when the SSH connection ends, however it ends.
  Future<void> get done;

  void close();
}

/// The person's answer to a new or changed server key.
typedef HostKeyDecision = Future<bool> Function(SshHostKeyPrompt prompt);

/// What a tunnel needs to exist: the SSH login and the Dashboard it reaches.
class TunnelSpec {
  const TunnelSpec({
    required this.id,
    required this.ssh,
    required this.credentials,
    required this.dashHost,
    required this.dashPort,
    this.preferredPort,
  });

  /// The connection this tunnel belongs to.
  final String id;
  final SshConfig ssh;
  final SshCredentials credentials;

  /// The Dashboard as seen from the SSH server.
  final String dashHost;
  final int dashPort;

  /// The local port to try first, so a saved address keeps working.
  final int? preferredPort;

  bool sameDashboard(TunnelSpec other) =>
      dashHost == other.dashHost && dashPort == other.dashPort;

  bool sameLogin(TunnelSpec other) =>
      ssh.host == other.ssh.host &&
      ssh.port == other.ssh.port &&
      ssh.username == other.ssh.username &&
      ssh.method == other.ssh.method &&
      credentials.password == other.credentials.password &&
      credentials.privateKeyPem == other.credentials.privateKeyPem &&
      credentials.passphrase == other.credentials.passphrase;
}

typedef TunnelClientFactory =
    Future<TunnelClient> Function(TunnelSpec spec, HostKeyDecision onHostKey);

/// Binds on 127.0.0.1 only; [preferred] is tried first, then any free port.
typedef TunnelServerFactory = Future<TunnelServer> Function(int? preferred);

/// Limits and timeouts of a tunnel.
class TunnelLimits {
  const TunnelLimits({
    this.maxConnections = 16,
    this.connectTimeout = const Duration(seconds: 20),
    this.forwardTimeout = const Duration(seconds: 10),
    this.halfCloseGrace = const Duration(seconds: 30),
  });

  /// Connections served at once; the surplus is dropped at once.
  final int maxConnections;

  /// SSH connection plus authentication.
  final Duration connectTimeout;

  /// The SSH server opening the channel to the Dashboard.
  final Duration forwardTimeout;

  /// How long one side may stay open after the other one ended.
  final Duration halfCloseGrace;
}

/// Copies bytes both ways between two ends, closes both when either side
/// fails, and never lets a half-open pair live past [grace].
class TunnelPipe {
  TunnelPipe(this.a, this.b, {required this.grace, this.onClosed});

  final TunnelEnd a;
  final TunnelEnd b;
  final Duration grace;
  final VoidCallback? onClosed;
  final _subs = <StreamSubscription<List<int>>>[];
  Timer? _graceTimer;
  int _ended = 0;
  bool _closed = false;

  bool get closed => _closed;

  void start() {
    _wire(a, b);
    _wire(b, a);
  }

  void _wire(TunnelEnd from, TunnelEnd to) {
    _subs.add(
      from.stream.listen(
        (data) {
          if (_closed) return;
          try {
            to.sink.add(data);
          } catch (_) {
            close();
          }
        },
        onError: (Object _) => close(),
        onDone: () {
          _ended++;
          // Half-close: what the other side still has to say gets through.
          try {
            unawaited(to.sink.close().then((_) {}, onError: (Object _) {}));
          } catch (_) {
            // Already closed.
          }
          if (_ended >= 2) {
            close();
          } else {
            _graceTimer ??= Timer(grace, close);
          }
        },
        cancelOnError: true,
      ),
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _graceTimer?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    a.destroy();
    b.destroy();
    onClosed?.call();
  }
}

enum TunnelState { suspended, starting, up, closed }

/// One tunnel: a loopback listener whose connections are forwarded over one
/// SSH connection to the Dashboard. It can be suspended (everything closed,
/// nothing kept open) and resumed on the same local port when it is free.
class SshDashboardTunnel {
  SshDashboardTunnel(
    this.spec, {
    required this.clientFactory,
    required this.serverFactory,
    this.limits = const TunnelLimits(),
    this.onPortChanged,
    bool suspended = true,
  }) : _lastPort = spec.preferredPort,
       state = ValueNotifier(
         suspended ? TunnelState.suspended : TunnelState.starting,
       );

  final TunnelSpec spec;
  final TunnelLimits limits;
  final void Function(int port)? onPortChanged;
  final ValueNotifier<TunnelState> state;
  final TunnelClientFactory clientFactory;
  final TunnelServerFactory serverFactory;
  final _pipes = <TunnelPipe>{};
  TunnelClient? _client;
  Future<TunnelClient>? _connecting;
  TunnelServer? _server;
  StreamSubscription<TunnelEnd>? _accepting;
  int? _lastPort;
  int _slots = 0;
  int _generation = 0;

  /// Kept for later launches; only these are closed when another connection
  /// becomes the active one.
  bool persisted = false;

  int? get port => _server?.port;
  bool get isUp => state.value == TunnelState.up;
  int get openConnections => _slots;

  /// The first start. Throws [SshTunnelException]; the tunnel is then closed.
  Future<void> start(HostKeyDecision onHostKey) async {
    state.value = TunnelState.starting;
    final gen = ++_generation;
    try {
      final client = await _connect(onHostKey);
      await _probe(client);
      if (gen != _generation) {
        client.close();
        throw const SshTunnelException(SshTunnelFailure.ssh);
      }
      _client = client;
      await _bind();
    } catch (e) {
      await close();
      throw _wrap(e);
    }
  }

  /// Back from suspension: the listener first (so the saved address answers),
  /// the SSH connection in the background. A key that changed is refused.
  Future<void> resume() async {
    if (state.value == TunnelState.closed || _server != null) return;
    state.value = TunnelState.starting;
    final gen = ++_generation;
    try {
      await _bind();
    } catch (_) {
      if (gen == _generation) state.value = TunnelState.suspended;
      return;
    }
    unawaited(_live().then((_) {}, onError: (Object _) {}));
  }

  /// Closes the listener, every connection and the SSH link.
  Future<void> suspend() async {
    if (state.value == TunnelState.closed) return;
    _generation++;
    await _teardown();
    state.value = TunnelState.suspended;
  }

  Future<void> close() async {
    if (state.value == TunnelState.closed) return;
    _generation++;
    state.value = TunnelState.closed;
    await _teardown();
  }

  Future<void> _teardown() async {
    final accepting = _accepting;
    _accepting = null;
    await accepting?.cancel();
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close();
      } catch (_) {
        // Already gone.
      }
    }
    for (final p in _pipes.toList()) {
      p.close();
    }
    _pipes.clear();
    _client?.close();
    _client = null;
    _connecting = null;
  }

  Future<TunnelClient> _connect(HostKeyDecision onHostKey) async {
    try {
      final client = await clientFactory(
        spec,
        onHostKey,
      ).timeout(limits.connectTimeout);
      unawaited(
        client.done.then((_) {}, onError: (Object _) {}).whenComplete(() {
          if (identical(_client, client)) _client = null;
        }),
      );
      return client;
    } catch (e) {
      throw _wrap(e);
    }
  }

  /// A channel to the Dashboard, opened and dropped at once: a wrong host or
  /// port shows here, not as a login that never answers.
  Future<void> _probe(TunnelClient client) async {
    try {
      final end = await client
          .forward(spec.dashHost, spec.dashPort)
          .timeout(limits.forwardTimeout);
      end.destroy();
    } catch (_) {
      client.close();
      throw const SshTunnelException(SshTunnelFailure.dashboardRefused);
    }
  }

  Future<void> _bind() async {
    final server = await serverFactory(_lastPort);
    final previous = _lastPort;
    _server = server;
    _lastPort = server.port;
    _accepting = server.connections.listen(_accept, onError: (Object _) {});
    state.value = TunnelState.up;
    if (previous != null && previous != server.port) {
      onPortChanged?.call(server.port);
    }
  }

  /// The SSH link, reconnected when it dropped. New keys are never trusted
  /// here: nobody is looking at the screen.
  Future<TunnelClient> _live() {
    final client = _client;
    if (client != null) return Future.value(client);
    return _connecting ??= () async {
      final gen = _generation;
      try {
        final fresh = await _connect((_) async => false);
        if (gen != _generation) {
          fresh.close();
          throw const SshTunnelException(SshTunnelFailure.ssh);
        }
        _client = fresh;
        return fresh;
      } finally {
        _connecting = null;
      }
    }();
  }

  Future<void> _accept(TunnelEnd local) async {
    if (_slots >= limits.maxConnections) {
      local.destroy();
      return;
    }
    _slots++;
    final gen = _generation;
    try {
      final client = await _live();
      final remote = await client
          .forward(spec.dashHost, spec.dashPort)
          .timeout(limits.forwardTimeout);
      if (gen != _generation) {
        remote.destroy();
        local.destroy();
        _slots--;
        return;
      }
      late final TunnelPipe pipe;
      pipe = TunnelPipe(
        local,
        remote,
        grace: limits.halfCloseGrace,
        onClosed: () {
          _pipes.remove(pipe);
          _slots--;
        },
      );
      _pipes.add(pipe);
      pipe.start();
    } catch (e) {
      local.destroy();
      _slots--;
      // M2: a Dashboard that refuses one connection (SSH channel open
      // failure) says nothing about the link. Anything else, above all a
      // forward that never answers, means the SSH link is dead or half-open:
      // drop it so the next connection dials a fresh one instead of waiting
      // on a link whose `done` will never complete.
      if (e is! SSHChannelOpenError && gen == _generation) {
        _dropLink();
      }
    }
  }

  void _dropLink() {
    final client = _client;
    if (client == null) return;
    _client = null;
    client.close();
  }

  static SshTunnelException _wrap(Object e) {
    if (e is SshTunnelException) return e;
    return SshTunnelException(
      SshTunnelFailure.ssh,
      SshManager.classifyError(e),
    );
  }
}

/// The tunnels of the app, by connection. They live while the connection is
/// in use and the app is in the foreground: in the background everything is
/// closed (after a short grace), and back in the foreground it is restored.
class SshDashboardTunnels with WidgetsBindingObserver {
  SshDashboardTunnels({
    required this.clientFactory,
    this.serverFactory = bindLoopbackTunnelServer,
    this.limits = const TunnelLimits(),
    this.backgroundGrace = const Duration(seconds: 10),
    this.maxHold = const Duration(minutes: 5),
    this.onPortChanged,
  });

  final TunnelLimits limits;
  final Duration backgroundGrace;

  /// The longest a [hold] keeps a tunnel awake in the background.
  final Duration maxHold;

  /// A tunnel came back on another local port: the saved address changes.
  void Function(String id, int port)? onPortChanged;
  final TunnelClientFactory clientFactory;
  final TunnelServerFactory serverFactory;
  final _tunnels = <String, SshDashboardTunnel>{};
  final _holds = <String, int>{};
  Timer? _graceTimer;
  bool _background = false;

  bool get inBackground => _background;

  void attach() {
    final state = WidgetsBinding.instance.lifecycleState;
    _background =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    WidgetsBinding.instance.addObserver(this);
  }

  void detach() {
    _graceTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        foregrounded();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        backgrounded();
      case AppLifecycleState.inactive:
        break;
    }
  }

  bool has(String id) => _tunnels.containsKey(id);
  int? portOf(String id) => _tunnels[id]?.port;
  TunnelSpec? specOf(String id) => _tunnels[id]?.spec;
  ValueNotifier<TunnelState>? stateOf(String id) => _tunnels[id]?.state;
  Iterable<String> get ids => _tunnels.keys.toList();

  SshDashboardTunnel _make(TunnelSpec spec, {required bool suspended}) =>
      SshDashboardTunnel(
        spec,
        clientFactory: clientFactory,
        serverFactory: serverFactory,
        limits: limits,
        suspended: suspended,
        onPortChanged: (p) => onPortChanged?.call(spec.id, p),
      );

  /// Opens the tunnel and returns its local port. The same connection with
  /// the same login and Dashboard answers with the tunnel it has; with the
  /// same login on another Dashboard address it refuses.
  Future<int> open(
    TunnelSpec spec, {
    required HostKeyDecision onHostKey,
  }) async {
    final existing = _tunnels[spec.id];
    if (existing != null) {
      if (!existing.spec.sameDashboard(spec)) {
        throw const SshTunnelException(SshTunnelFailure.otherAddress);
      }
      if (existing.spec.sameLogin(spec) && existing.isUp) {
        return existing.port!;
      }
      await close(spec.id);
    }
    final tunnel = _make(spec, suspended: false);
    await tunnel.start(onHostKey);
    _tunnels[spec.id] = tunnel;
    return tunnel.port!;
  }

  /// Takes a tunnel that is already known (a saved connection) without
  /// opening anything until the app is in the foreground.
  Future<void> adopt(TunnelSpec spec) async {
    if (_tunnels.containsKey(spec.id)) return;
    final tunnel = _make(spec, suspended: true)..persisted = true;
    _tunnels[spec.id] = tunnel;
    if (!_background) await tunnel.resume();
  }

  void markPersisted(String id) {
    final t = _tunnels[id];
    if (t != null) t.persisted = true;
  }

  Future<void> close(String id) async {
    final t = _tunnels.remove(id);
    _holds.remove(id);
    await t?.close();
  }

  /// Closes the saved tunnels of every connection but [keep].
  Future<void> closeSavedExcept(String? keep) async {
    for (final id in ids) {
      if (id != keep && _tunnels[id]?.persisted == true) await close(id);
    }
  }

  Future<void> closeAll() async {
    for (final id in ids) {
      await close(id);
    }
  }

  /// Keeps [id] awake in the background (a browser sign-in reaches the
  /// Dashboard through it while the app waits). Call the result when done; it
  /// lets go by itself after [maxHold].
  VoidCallback hold(String id) {
    _holds[id] = (_holds[id] ?? 0) + 1;
    var released = false;
    late final Timer timer;
    void release() {
      if (released) return;
      released = true;
      timer.cancel();
      final left = (_holds[id] ?? 1) - 1;
      if (left <= 0) {
        _holds.remove(id);
        if (_background) unawaited(_tunnels[id]?.suspend());
      } else {
        _holds[id] = left;
      }
    }

    timer = Timer(maxHold, release);
    return release;
  }

  void backgrounded() {
    _background = true;
    _graceTimer?.cancel();
    if (backgroundGrace == Duration.zero) {
      unawaited(_suspendAll());
    } else {
      _graceTimer = Timer(backgroundGrace, () => unawaited(_suspendAll()));
    }
  }

  void foregrounded() {
    _background = false;
    _graceTimer?.cancel();
    _graceTimer = null;
    for (final t in _tunnels.values.toList()) {
      if (t.state.value == TunnelState.suspended) unawaited(t.resume());
    }
  }

  Future<void> _suspendAll() async {
    for (final entry in _tunnels.entries.toList()) {
      if ((_holds[entry.key] ?? 0) > 0) continue;
      await entry.value.suspend();
    }
  }
}

/// The real listener: a ServerSocket on 127.0.0.1, never on another address.
Future<TunnelServer> bindLoopbackTunnelServer(int? preferred) async {
  ServerSocket? socket;
  if (preferred != null) {
    try {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, preferred);
    } on SocketException {
      socket = null;
    }
  }
  socket ??= await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  return _LoopbackServer(socket);
}

class _LoopbackServer implements TunnelServer {
  _LoopbackServer(this._socket);

  final ServerSocket _socket;

  @override
  int get port => _socket.port;

  @override
  Stream<TunnelEnd> get connections => _socket.map<TunnelEnd>(_SocketEnd.new);

  @override
  Future<void> close() async {
    await _socket.close();
  }
}

class _SocketEnd implements TunnelEnd {
  _SocketEnd(this._socket);

  final Socket _socket;

  @override
  Stream<List<int>> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  void destroy() => _socket.destroy();
}

/// The real SSH side: logs in with [SshManager.connectWith], keeps the server
/// key per server and waits for the login before it hands the client over.
TunnelClientFactory sshTunnelClientFactory(SshManager manager) =>
    (spec, onHostKey) async {
      final client = await manager.connectWith(
        spec.ssh,
        spec.credentials,
        hostKeyScopes: [SshManager.serverScope(spec.ssh.host, spec.ssh.port)],
        onHostKey: onHostKey,
      );
      // The transport can fail on its own too; nobody awaits that future.
      unawaited(client.done.then((_) {}, onError: (Object _) {}));
      try {
        await client.authenticated;
      } catch (_) {
        client.close();
        rethrow;
      }
      return _SshClient(client);
    };

class _SshClient implements TunnelClient {
  _SshClient(this._client);

  final SSHClient _client;

  @override
  Future<TunnelEnd> forward(String host, int port) async =>
      _ChannelEnd(await _client.forwardLocal(host, port));

  @override
  Future<void> get done => _client.done;

  @override
  void close() => _client.close();
}

class _ChannelEnd implements TunnelEnd {
  _ChannelEnd(this._channel);

  final SSHForwardChannel _channel;

  @override
  Stream<List<int>> get stream => _channel.stream;

  @override
  StreamSink<List<int>> get sink => _channel.sink;

  @override
  void destroy() => _channel.destroy();
}
