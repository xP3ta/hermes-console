// Sesión SSH/terminal persistente: vive fuera del widget para sobrevivir a la
// navegación y al segundo plano. El `Terminal` de xterm (con su buffer) y el
// shell PTY viven aquí; la pantalla se "engancha" mostrando el mismo Terminal.
// Mientras hay una sesión conectada, se mantiene el proceso vivo (foreground
// service compartido) para no cortar comandos largos al salir.
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import 'ssh_manager.dart';

enum SshSessionPhase { connecting, ready, closed, error }

/// Una sesión de terminal viva. El [terminal] persiste entre reconexiones
/// (conserva el scrollback). La UI observa [phase].
class SshTerminalSession {
  final String connectionId;
  final Terminal terminal;
  SSHClient? client;
  SSHSession? shell;
  String? error;
  final ValueNotifier<SshSessionPhase> phase = ValueNotifier<SshSessionPhase>(
    SshSessionPhase.connecting,
  );

  SshTerminalSession(this.connectionId, this.terminal);

  /// Último tráfico real (entrada del usuario o salida del servidor). Lo usa
  /// [SshSessionService.closeIdle] para no cortar comandos largos en curso:
  /// mientras produzcan salida, la sesión cuenta como activa (U-11, spec 028).
  DateTime lastActivityAt = DateTime.now();
  void touch() => lastActivityAt = DateTime.now();

  bool get isLive =>
      phase.value == SshSessionPhase.ready ||
      phase.value == SshSessionPhase.connecting;
}

/// Gestiona sesiones de terminal persistentes, una por instancia.
class SshSessionService {
  final SshManager _ssh;
  SshSessionService(this._ssh);

  final Map<String, SshTerminalSession> _sessions = {};
  final Map<String, Future<SshTerminalSession>> _connecting = {};

  /// IDs de instancias con una sesión de terminal viva (para indicadores en UI).
  final ValueNotifier<Set<String>> activeSessions = ValueNotifier<Set<String>>(
    const {},
  );

  /// Cableado por HermesAppState (igual que SFTP): mantener proceso vivo.
  VoidCallback? onNeedForeground;
  VoidCallback? onMaybeRelease;

  bool get hasActive => _sessions.values.any((s) => s.isLive);

  SshTerminalSession? of(String connectionId) => _sessions[connectionId];

  void _refresh() {
    activeSessions.value = _sessions.entries
        .where((e) => e.value.isLive)
        .map((e) => e.key)
        .toSet();
  }

  /// Devuelve la sesión viva de la instancia, o crea/conecta una nueva. Reusa el
  /// `Terminal` previo (conserva scrollback) si lo había.
  Future<SshTerminalSession> connect(
    String connectionId, {
    required Future<bool> Function(SshHostKeyPrompt) onHostKey,
  }) {
    final existing = _sessions[connectionId];
    if (existing != null && existing.phase.value == SshSessionPhase.ready) {
      return Future.value(existing);
    }
    final inFlight = _connecting[connectionId];
    if (inFlight != null) return inFlight;
    final future = _connectOnce(connectionId, onHostKey: onHostKey);
    _connecting[connectionId] = future;
    return future.whenComplete(() {
      if (identical(_connecting[connectionId], future)) {
        _connecting.remove(connectionId);
      }
    });
  }

  Future<SshTerminalSession> _connectOnce(
    String connectionId, {
    required Future<bool> Function(SshHostKeyPrompt) onHostKey,
  }) async {
    final existing = _sessions[connectionId];
    final terminal = existing?.terminal ?? Terminal(maxLines: 10000);
    final s = SshTerminalSession(connectionId, terminal);
    s.phase.value = SshSessionPhase.connecting;
    _sessions[connectionId] = s;
    _refresh();
    SSHClient? candidate;
    try {
      candidate = await _ssh.connect(connectionId, onHostKey: onHostKey);
      s.client = candidate;
      if (!identical(_sessions[connectionId], s)) {
        candidate.close();
        return s;
      }
      await candidate.authenticated.timeout(const Duration(seconds: 15));
      if (!identical(_sessions[connectionId], s)) {
        candidate.close();
        return s;
      }
      final shell = await candidate
          .shell(
            pty: SSHPtyConfig(
              width: terminal.viewWidth > 0 ? terminal.viewWidth : 80,
              height: terminal.viewHeight > 0 ? terminal.viewHeight : 24,
            ),
          )
          .timeout(const Duration(seconds: 15));
      s.shell = shell;
      if (!identical(_sessions[connectionId], s)) {
        shell.close();
        candidate.close();
        return s;
      }
      terminal.onOutput = (data) {
        s.touch();
        shell.write(Uint8List.fromList(utf8.encode(data)));
      };
      terminal.onResize = (w, h, pw, ph) => shell.resizeTerminal(w, h, pw, ph);
      shell.stdout.listen((d) {
        s.touch();
        terminal.write(utf8.decode(d, allowMalformed: true));
      });
      shell.stderr.listen((d) {
        s.touch();
        terminal.write(utf8.decode(d, allowMalformed: true));
      });
      shell.done.then((_) {
        s.phase.value = SshSessionPhase.closed;
        terminal.write('\r\n\x1b[90m[sesión cerrada]\x1b[0m\r\n');
        _refresh();
        onMaybeRelease?.call();
      });
      s.phase.value = SshSessionPhase.ready;
      _refresh();
      onNeedForeground?.call();
    } catch (e) {
      candidate?.close();
      if (!identical(_sessions[connectionId], s)) return s;
      s.error = SshManager.describeError(e);
      s.phase.value = SshSessionPhase.error;
      _refresh();
      onMaybeRelease?.call();
    }
    return s;
  }

  /// Escribe en el shell (p.ej. un comando rápido).
  void send(String connectionId, String data) {
    final s = _sessions[connectionId];
    if (s?.shell == null || s!.phase.value != SshSessionPhase.ready) return;
    s.shell!.write(Uint8List.fromList(utf8.encode(data)));
  }

  /// Cierra y olvida la sesión de una instancia.
  void close(String connectionId) {
    final s = _sessions.remove(connectionId);
    if (s != null) {
      s.shell?.close();
      s.client?.close();
      s.phase.value = SshSessionPhase.closed;
    }
    _refresh();
    onMaybeRelease?.call();
  }

  /// Acción global de usuario desde la notificación dataSync. Copiar primero
  /// las claves hace seguro cerrar callbacks que mutan el mismo mapa.
  void closeAll() {
    for (final connectionId in _sessions.keys.toList(growable: false)) {
      close(connectionId);
    }
  }

  /// U-11 (spec 028): cierra las sesiones vivas sin tráfico desde hace más de
  /// [maxIdle]. Lo invoca el timer de background de main.dart — una shell
  /// parada en el prompt no justifica mantener el FGS y la radio despiertos
  /// toda la noche. La UI ya sabe recuperarse: al volver, la pantalla del
  /// terminal muestra "sesión cerrada" con Reconectar (scrollback intacto).
  /// Devuelve cuántas cerró.
  int closeIdle(Duration maxIdle) {
    final now = DateTime.now();
    final idle = _sessions.entries
        .where(
          (e) =>
              e.value.isLive &&
              now.difference(e.value.lastActivityAt) > maxIdle,
        )
        .map((e) => e.key)
        .toList();
    for (final id in idle) {
      close(id);
    }
    return idle.length;
  }
}
