// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show VoidCallback;

import 'connection_manager.dart';
import 'ssh_dashboard_tunnel.dart';
import 'ssh_manager.dart';

/// What the SSH tab of Connect asks for.
class SshTunnelRequest {
  const SshTunnelRequest({
    required this.id,
    required this.host,
    required this.port,
    required this.username,
    required this.method,
    required this.secret,
    required this.dashHost,
    required this.dashPort,
    this.passphrase = '',
    this.remember = false,
  });

  /// The connection this tunnel will belong to.
  final String id;
  final String host;
  final int port;
  final String username;
  final SshAuthMethod method;

  /// The password, or the private key.
  final String secret;
  final String dashHost;
  final int dashPort;
  final String passphrase;

  /// Keep the SSH password (or the key's passphrase) on this phone.
  final bool remember;

  /// Changes whenever the tunnel it asks for would be another one.
  String get signature =>
      '$host|$port|$username|${method.id}|$secret|$passphrase|$dashHost|'
      '$dashPort';

  static bool validPort(int? p) => p != null && p >= 1 && p <= 65535;
}

/// What the Connect page needs from the tunnel: open it, keep it, drop it.
abstract interface class SshTunnelOpener {
  /// Opens the tunnel and returns its local port. Throws
  /// [SshTunnelException]. A new or changed server key goes to [onHostKey].
  Future<int> open(SshTunnelRequest request, HostKeyDecision onHostKey);

  /// The sign-in worked: keep the SSH data for this connection.
  Future<void> persist(String id, {required bool remember});

  /// Gives up on a tunnel that never became a connection.
  Future<void> discard(String id);

  /// Keeps the tunnel open while the app is in the background (a browser
  /// sign-in). Call the result when done.
  VoidCallback hold(String id);
}

/// How a pasted or imported key reads, without touching the network.
enum SshKeyState { empty, publicKey, needsPassphrase, ready, invalid }

SshKeyState checkSshKey(String pem, String passphrase) {
  final text = pem.trim();
  if (text.isEmpty) return SshKeyState.empty;
  if (SshManager.looksLikePublicKey(text)) return SshKeyState.publicKey;
  if (SshManager.isEncryptedKey(text) && passphrase.isEmpty) {
    return SshKeyState.needsPassphrase;
  }
  return SshManager.validateKey(text, passphrase) == null
      ? SshKeyState.ready
      : SshKeyState.invalid;
}

/// Opens the Dashboard tunnel of a connection and keeps its SSH data: the
/// glue between the Connect page, the stored connections and the tunnels.
class SshTunnelConnector implements SshTunnelOpener {
  SshTunnelConnector({
    required this.tunnels,
    required this.manager,
    required this.connections,
  }) {
    tunnels.onPortChanged = (id, port) => unawaited(portChanged(id, port));
  }

  /// Set once at start so the Connect screen finds it.
  static SshTunnelConnector? current;

  final SshDashboardTunnels tunnels;
  final SshManager manager;
  final ConnectionManager connections;

  @override
  Future<int> open(SshTunnelRequest r, HostKeyDecision onHostKey) async {
    final key = r.method == SshAuthMethod.key;
    if (key) {
      switch (checkSshKey(r.secret, r.passphrase)) {
        case SshKeyState.publicKey:
          throw const SshTunnelException(SshTunnelFailure.publicKey);
        case SshKeyState.needsPassphrase:
          throw const SshTunnelException(SshTunnelFailure.passphraseNeeded);
        case SshKeyState.empty:
          throw const SshTunnelException(
            SshTunnelFailure.ssh,
            SshFailure.emptyKey,
          );
        case SshKeyState.invalid:
          throw SshTunnelException(
            SshTunnelFailure.ssh,
            SshManager.validateKey(r.secret, r.passphrase) ??
                SshFailure.invalidKey,
          );
        case SshKeyState.ready:
          break;
      }
    }
    final spec = TunnelSpec(
      id: r.id,
      ssh: SshConfig(
        host: r.host.trim(),
        port: r.port,
        username: r.username.trim(),
        method: r.method,
      ),
      credentials: key
          ? SshCredentials(
              privateKeyPem: r.secret.trim(),
              passphrase: r.passphrase.isEmpty ? null : r.passphrase,
            )
          : SshCredentials(password: r.secret),
      dashHost: r.dashHost.trim(),
      dashPort: r.dashPort,
    );
    return tunnels.open(spec, onHostKey: onHostKey);
  }

  @override
  Future<void> persist(String id, {required bool remember}) async {
    final spec = tunnels.specOf(id);
    if (spec == null) return;
    final key = spec.ssh.method == SshAuthMethod.key;
    await manager.saveConfig(
      id,
      host: spec.ssh.host,
      port: spec.ssh.port,
      username: spec.ssh.username,
      method: spec.ssh.method,
      // The password and the passphrase stay on the phone only when asked.
      password: key ? null : (remember ? spec.credentials.password : ''),
      privateKeyPem: key ? spec.credentials.privateKeyPem : null,
      passphrase: key ? (remember ? spec.credentials.passphrase : '') : null,
    );
    await manager.saveTunnelTarget(id, spec.dashHost, spec.dashPort);
    tunnels.markPersisted(id);
  }

  @override
  Future<void> discard(String id) async {
    await tunnels.close(id);
    await manager.clear(id);
  }

  @override
  VoidCallback hold(String id) => tunnels.hold(id);

  /// The tunnel of the connection in use: the others close, and a saved
  /// tunnel connection that has no tunnel yet gets one (opened once the app is
  /// in the foreground). Nothing is asked here: a changed server key is
  /// refused, and a password that was not kept cannot be sent.
  Future<void> ensureActive(String? id) async {
    await tunnels.closeSavedExcept(id);
    if (id == null || tunnels.has(id)) return;
    final target = await manager.loadTunnelTarget(id);
    if (target == null) return;
    final cfg = await manager.loadConfig(id);
    if (cfg == null) return;
    final creds = await manager.loadCredentials(id);
    final usable = cfg.method == SshAuthMethod.key
        ? creds.privateKeyPem != null
        : creds.password != null;
    if (!usable) return;
    SavedConnection? saved;
    for (final c in connections.getConnections()) {
      if (c.id == id) saved = c;
    }
    await tunnels.adopt(
      TunnelSpec(
        id: id,
        ssh: cfg,
        credentials: creds,
        dashHost: target.host,
        dashPort: target.port,
        preferredPort: saved?.dashboardUri?.port,
      ),
    );
  }

  /// The tunnel came back on another local port: the saved address follows.
  Future<void> portChanged(String id, int port) async {
    for (final c in connections.getConnections()) {
      if (c.id != id) continue;
      await connections.upsertConnection(
        c.copyWith(port: port, dashboardUrl: 'http://127.0.0.1:$port'),
      );
    }
  }

  /// Wires the app: the tunnels follow the active connection and the
  /// foreground. Call once, after the first frame's binding exists.
  void start() {
    tunnels.attach();
    connections.activeConnectionId.addListener(_activeChanged);
    _activeChanged();
  }

  void _activeChanged() => unawaited(
    ensureActive(connections.activeConnectionId.value).catchError(
      (Object e) =>
          debugPrint('[ssh-tunnel] restore failed (${e.runtimeType})'),
    ),
  );

  void stop() {
    connections.activeConnectionId.removeListener(_activeChanged);
    tunnels.detach();
  }
}
