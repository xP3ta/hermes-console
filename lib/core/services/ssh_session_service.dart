// Sesión SSH/terminal persistente: vive fuera del widget para sobrevivir a la
// navegación y al segundo plano. El `Terminal` de xterm (con su buffer) y el
// shell PTY viven aquí; la pantalla se "engancha" mostrando el mismo Terminal.
// Mientras hay una sesión conectada, se mantiene el proceso vivo (foreground
// service compartido) para no cortar comandos largos al salir.
// 1.4.0: el terminal es un shell normal. Solo si el perfil lo pide de forma
// explícita (opción avanzada, apagada por defecto) se lanza Herdr o tmux tras
// abrir el shell (si `command -v` lo encuentra; nunca se instala nada).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../utils/utf8_chunks.dart';
import 'herdr_agents.dart' show herdrShellQuote;
import 'herdr_status.dart';
import 'ssh_compose_uploads.dart';
import 'ssh_manager.dart';
import 'ssh_session_kind.dart';
import 'ssh_terminal_input.dart';
import 'ssh_working_directory.dart';

enum SshSessionPhase { connecting, ready, closed, error }

/// Why a session that was ready stopped. Only [connectionLost] triggers the
/// automatic reconnection; the other two were wanted.
enum SshSessionEnd {
  /// The remote shell exited (it sent an exit status or signal).
  remoteExit,

  /// The channel closed without an exit status: the connection dropped.
  connectionLost,

  /// The app closed it: the user, removing SSH, the idle timer or closeAll.
  closedByApp,
}

/// Single extension point for F5 (reading Herdr state: panes and their
/// working/blocked/idle status). Called once Herdr or tmux has been launched
/// in the pty of [session], with the same authenticated [client], so a reader
/// can open its own `execute` channel. F1 leaves it unset: the Herdr CLI and
/// socket API must be checked against a real Herdr before anything reads it.
typedef SshMultiplexerAttached = void Function(
  SshTerminalSession session,
  SSHClient client,
);

/// Control character for [data] when the key row's ctrl is armed:
/// letters map to ^A..^Z, `@[\]^_` to their C0 codes, space to NUL and `?`
/// to DEL. Anything else (several characters, escape sequences) passes as is.
String sshCtrlChord(String data) {
  if (data.length != 1) return data;
  final code = data.codeUnitAt(0);
  if (code >= 0x61 && code <= 0x7a) return String.fromCharCode(code - 0x60);
  if (code >= 0x40 && code <= 0x5f) return String.fromCharCode(code - 0x40);
  if (code == 0x20) return String.fromCharCode(0);
  if (code == 0x3f) return String.fromCharCode(0x7f);
  return data;
}

/// Una sesión de terminal viva. El [terminal] persiste entre reconexiones
/// (conserva el scrollback). La UI observa [phase].
class SshTerminalSession {
  final String connectionId;
  final Terminal terminal;
  SSHClient? client;
  SSHSession? shell;

  /// Why the last connection attempt failed; localized by the UI.
  Object? failure;
  final ValueNotifier<SshSessionPhase> phase = ValueNotifier<SshSessionPhase>(
    SshSessionPhase.connecting,
  );

  SshTerminalSession(this.connectionId, this.terminal) {
    // The folder the shell is in, as the shell says it (OSC 7, else bash's
    // default title); the pane shows it under the host (mock 136 v2-A).
    terminal.onPrivateOSC = (code, args) {
      if (code != '7') return;
      final directory = sshWorkingDirectoryFromOsc7(args);
      if (directory == null) return;
      _directoryFromOsc7 = true;
      workingDirectory.value = directory;
    };
    terminal.onTitleChange = (title) {
      final shown = title.trim();
      windowTitle.value = shown.isEmpty ? null : shown;
      if (_directoryFromOsc7) return;
      final directory = sshWorkingDirectoryFromTitle(title);
      if (directory != null) workingDirectory.value = directory;
    };
    phase.addListener(() {
      if (phase.value == SshSessionPhase.closed ||
          phase.value == SshSessionPhase.error) {
        markClosed();
      }
    });
  }

  final Completer<void> _closed = Completer<void>();

  /// Completes once this session enters closed/error or its SSH client ends.
  Future<void> get closedFuture => _closed.future;

  void markClosed() {
    if (!_closed.isCompleted) _closed.complete();
  }

  /// The window title the shell last set (`user@host: ~`); the terminal's
  /// header shows it. Null until it sets one.
  final ValueNotifier<String?> windowTitle = ValueNotifier<String?>(null);

  /// The folder the shell last said it is in; null until it says one.
  final ValueNotifier<String?> workingDirectory = ValueNotifier<String?>(null);

  /// Once the shell speaks OSC 7, its title no longer moves the folder.
  bool _directoryFromOsc7 = false;

  /// Session type resolved when this connection was opened.
  SshSessionKind kind = SshSessionKind.shell;

  // A multiplexer attaches in its own PTY on the same SSH transport. The
  // login shell keeps its own terminal, input and scrollback underneath.
  final _attachment = ValueNotifier<SshTerminalSession?>(null);
  int _attachmentRevision = 0;
  bool _keepPlainShell = false;

  ValueListenable<SshTerminalSession?> get attachment => _attachment;
  SshTerminalSession get visibleTerminal => _attachment.value ?? this;

  /// Set when [kind] is Herdr or tmux but `command -v` did not find it. The
  /// session stays a plain shell and the UI explains how to install it; the
  /// UI clears it once the user has read it.
  final ValueNotifier<SshSessionKind?> missingProgram =
      ValueNotifier<SshSessionKind?>(null);

  /// Why the session stopped; null while it is connecting or ready.
  SshSessionEnd? end;

  /// Reads Herdr's state (F5) when this session launched Herdr; null for a
  /// plain shell, tmux, or when Herdr was not found. The terminal screen
  /// starts and stops its polling.
  HerdrMonitor? herdr;

  /// Ctrl from the terminal key row: the next input goes through
  /// [sshCtrlChord] and the modifier clears itself, unless it was locked
  /// with a double tap ([modifiers]).
  final ValueNotifier<bool> ctrlArmed = ValueNotifier<bool>(false);

  /// The key row's sticky Ctrl (on [ctrlArmed]) and Alt.
  late final SshKeyModifiers modifiers = SshKeyModifiers(ctrlArmed: ctrlArmed);

  /// Applies the armed modifiers, if any, to user input (see
  /// [SshKeyModifiers.apply]: a single character only, never xterm's own
  /// replies nor a paste).
  String applyModifiers(String data) => modifiers.apply(data);

  /// Shell stdout/stderr listeners. Cancelled on close so a client torn down
  /// without its channel completing cannot keep the terminal referenced.
  final List<StreamSubscription<Uint8List>> _outputSubscriptions = [];

  void _cancelOutput() {
    for (final subscription in _outputSubscriptions) {
      unawaited(subscription.cancel());
    }
    _outputSubscriptions.clear();
  }

  /// Último tráfico real (entrada del usuario o salida del servidor). Lo usa
  /// [SshSessionService.closeIdle] para no cortar comandos largos en curso:
  /// mientras produzcan salida, la sesión cuenta como activa (U-11, spec 028).
  DateTime lastActivityAt = DateTime.now();
  void touch() => lastActivityAt = DateTime.now();

  bool get isLive =>
      phase.value == SshSessionPhase.ready ||
      phase.value == SshSessionPhase.connecting;

  /// Whether the underlying SSH client transport is already closed.
  bool get isClientClosed {
    final c = client;
    if (c == null) return false;
    try {
      return c.isClosed;
    } on NoSuchMethodError {
      return false;
    }
  }
}

/// Gestiona sesiones de terminal persistentes, una por instancia.
class SshSessionService {
  final SshManager _ssh;
  SshSessionService(this._ssh);

  /// A remote probe that does not answer in this time counts as "not
  /// installed": the app then launches nothing.
  static const Duration probeTimeout = Duration(seconds: 10);

  final Map<String, SshTerminalSession> _sessions = {};
  final Map<String, Future<SshTerminalSession>> _connecting = {};

  /// IDs de instancias con una sesión de terminal viva (para indicadores en UI).
  final ValueNotifier<Set<String>> activeSessions = ValueNotifier<Set<String>>(
    const {},
  );

  /// Cableado por HermesAppState (igual que SFTP): mantener proceso vivo.
  VoidCallback? onNeedForeground;
  VoidCallback? onMaybeRelease;

  /// See [SshMultiplexerAttached]. Unset in F1.
  SshMultiplexerAttached? onMultiplexerAttached;

  bool get hasActive => _sessions.values.any((s) => s.isLive);

  /// Terminal screens currently visible and in the foreground per connection:
  /// [closeIdle] spares their sessions only while actively viewed.
  final Map<String, int> _views = {};

  /// Marks a terminal screen of [connectionId] as actively visible in the
  /// foreground; pair with [detachView].
  void attachView(String connectionId) {
    _views[connectionId] = (_views[connectionId] ?? 0) + 1;
  }

  /// A terminal screen of [connectionId] closed.
  void detachView(String connectionId) {
    final left = (_views[connectionId] ?? 0) - 1;
    if (left > 0) {
      _views[connectionId] = left;
    } else {
      _views.remove(connectionId);
    }
  }

  /// Whether a terminal screen of [connectionId] is open.
  bool isViewed(String connectionId) => _views.containsKey(connectionId);

  /// Most entries the Compose sheet remembers per connection.
  static const int composeHistoryLimit = 20;

  /// What the Compose sheet sent per connection, the newest first. In
  /// memory only, never stored (a command may carry a secret), and
  /// forgotten when the session is closed.
  final Map<String, List<String>> _composed = {};

  /// The entries the Compose sheet sent to [connectionId], newest first.
  List<String> composeHistory(String connectionId) =>
      List.unmodifiable(_composed[connectionId] ?? const <String>[]);

  /// Compose's draft per connection (text and attachments), in memory.
  final Map<String, SshComposeDraft> _drafts = {};

  /// The Compose draft of [connectionId]; its attachments go up over SFTP
  /// on that connection's terminal session ([openSftp]).
  SshComposeDraft composeDraft(String connectionId) => _drafts.putIfAbsent(
    connectionId,
    () => SshComposeDraft(
      SshComposeUploader(
        () => openSftp(connectionId),
        onSessionDone: () => _sessions[connectionId]?.closedFuture,
      ),
    ),
  );

  /// The Compose draft of [connectionId] if one already exists.
  SshComposeDraft? composeDraftIfPresent(String connectionId) =>
      _drafts[connectionId];

  /// SFTP on [connectionId]'s live terminal connection (the same SSH
  /// client, a channel of its own); throws when there is none.
  Future<SftpClient> openSftp(String connectionId) async {
    final client = _sessions[connectionId]?.client;
    if (client == null) throw StateError('No SSH session');
    return client.sftp();
  }

  /// Remembers [text] as the newest entry sent to [connectionId].
  void rememberComposed(String connectionId, String text) {
    if (text.trim().isEmpty) return;
    final entries = _composed.putIfAbsent(connectionId, () => <String>[]);
    entries
      ..remove(text)
      ..insert(0, text);
    if (entries.length > composeHistoryLimit) {
      entries.removeRange(composeHistoryLimit, entries.length);
    }
  }

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
    final terminal =
        existing?.terminal ??
        Terminal(maxLines: 10000, wordSeparators: sshTerminalWordSeparators);
    final s = SshTerminalSession(connectionId, terminal)
      .._keepPlainShell = existing?._keepPlainShell ?? false;
    s.phase.value = SshSessionPhase.connecting;
    _sessions[connectionId] = s;
    _refresh();
    SSHClient? candidate;
    try {
      s.kind = s._keepPlainShell
          ? SshSessionKind.shell
          : await _ssh.loadSessionKind(connectionId);
      if (!identical(_sessions[connectionId], s)) return s;
      candidate = await _ssh.connect(connectionId, onHostKey: onHostKey);
      s.client = candidate;
      try {
        unawaited(candidate.done.whenComplete(s.markClosed));
      } on NoSuchMethodError {
        // Minimal test double without a done future.
      }
      if (!identical(_sessions[connectionId], s)) {
        candidate.close();
        return s;
      }
      await candidate.authenticated.timeout(const Duration(seconds: 15));
      if (!identical(_sessions[connectionId], s)) {
        candidate.close();
        return s;
      }
      final probe = s.kind.probeCommand;
      var probed = probe == null ? null : await _probeProgram(candidate, probe);
      final fallback = s.kind.fallbackProbeCommand;
      if (probe != null && probed == null && fallback != null) {
        probed = await _probeProgram(candidate, fallback);
      }
      final installed = probe == null || probed != null;
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
      _bindTerminal(s, shell, touch: s.touch);
      shell.done.then((_) {
        s._attachmentRevision++;
        _detachTerminal(s);
        // No exit status or signal means the channel was torn down under
        // the shell: the connection dropped rather than the shell exiting.
        s.end ??= shell.exitCode == null && shell.exitSignal == null
            ? SshSessionEnd.connectionLost
            : SshSessionEnd.remoteExit;
        if (s.end == SshSessionEnd.connectionLost) {
          _drafts[connectionId]?.recoverUncertainSend();
        }
        s.phase.value = SshSessionPhase.closed;
        final banner = _ssh.appStrings.i18n1215SshSessionClosedBanner;
        terminal.write('\r\n\x1b[90m$banner\x1b[0m\r\n');
        _refresh();
        onMaybeRelease?.call();
      });
      s.phase.value = SshSessionPhase.ready;
      _refresh();
      onNeedForeground?.call();
      final launch = s.kind.launchCommand;
      if (launch != null && installed) {
        // The login-shell probe can see a binary outside the PATH of
        // the noninteractive SSH command. Use its verified path for Herdr.
        final herdrPath = s.kind == SshSessionKind.herdr
            ? herdrPathFromProbe(probed ?? '')
            : null;
        final line = herdrPath == null ? launch : "'$herdrPath'";
        final attached = await attachTerminal(s, s.kind, line);
        if (attached && s.attachment.value != null) {
          if (s.kind == SshSessionKind.herdr) {
            final client = candidate;
            s.herdr = HerdrMonitor(
              run: (command) => _runRemote(client, command),
              herdr: herdrPath,
            );
          }
          onMultiplexerAttached?.call(s, candidate);
        } else {
          s.kind = SshSessionKind.shell;
        }
      } else if (!installed) {
        s.missingProgram.value = s.kind;
        s.kind = SshSessionKind.shell;
      }
    } catch (e) {
      candidate?.close();
      if (!identical(_sessions[connectionId], s)) return s;
      s.failure = e;
      s.phase.value = SshSessionPhase.error;
      _refresh();
      onMaybeRelease?.call();
    }
    return s;
  }

  void _bindTerminal(
    SshTerminalSession session,
    SSHSession shell, {
    required VoidCallback touch,
  }) {
    final terminal = session.terminal;
    terminal.onOutput = (data) {
      touch();
      final safe = sshSanitizeTerminalOutput(data);
      if (safe.isEmpty) return;
      final input = session.applyModifiers(safe);
      shell.write(Uint8List.fromList(utf8.encode(input)));
    };
    terminal.onResize = (w, h, pw, ph) => shell.resizeTerminal(w, h, pw, ph);
    // One decoder per stream: a character split across two packets comes
    // out whole, and stdout and stderr never complete each other's.
    final stdoutText = Utf8ChunkDecoder(terminal.write);
    final stderrText = Utf8ChunkDecoder(terminal.write);
    void output(Utf8ChunkDecoder text, Uint8List chunk) {
      touch();
      text.add(chunk);
    }

    session._outputSubscriptions
      ..add(
        shell.stdout.listen(
          (d) => output(stdoutText, d),
          onDone: stdoutText.close,
        ),
      )
      ..add(
        shell.stderr.listen(
          (d) => output(stderrText, d),
          onDone: stderrText.close,
        ),
      );
  }

  /// Open only the chosen multiplexer client. The active shell's stdin
  /// could belong to any process, so switching must not type into it.
  Future<bool> attachTerminal(
    SshTerminalSession session,
    SshSessionKind kind,
    String line,
  ) async {
    final client = session.client;
    if (client == null ||
        session.isClientClosed ||
        !identical(of(session.connectionId), session) ||
        session.phase.value != SshSessionPhase.ready ||
        kind == SshSessionKind.shell ||
        line.isEmpty ||
        RegExp(r'[\x00-\x1F\x7F]').hasMatch(line)) {
      return false;
    }
    final revision = ++session._attachmentRevision;
    final current = session.visibleTerminal.terminal;
    SSHSession channel;
    try {
      final opening = client.execute(
        '"\${SHELL:-/bin/sh}" -lc ${herdrShellQuote(line)}',
        pty: SSHPtyConfig(
          width: current.viewWidth > 0 ? current.viewWidth : 80,
          height: current.viewHeight > 0 ? current.viewHeight : 24,
        ),
      );
      channel = await opening.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          unawaited(
            opening.then<void>(
              (lateChannel) => lateChannel.close(),
              onError: (Object _) {},
            ),
          );
          throw TimeoutException('SSH terminal channel');
        },
      );
    } on Exception catch (error) {
      debugPrint('[ssh] terminal attachment failed (${error.runtimeType})');
      return false;
    }
    if (revision != session._attachmentRevision ||
        !identical(of(session.connectionId), session) ||
        session.phase.value != SshSessionPhase.ready ||
        session.isClientClosed) {
      channel.close();
      return false;
    }

    final attached =
        SshTerminalSession(
            session.connectionId,
            Terminal(
              maxLines: 10000,
              wordSeparators: sshTerminalWordSeparators,
            ),
          )
          ..client = client
          ..shell = channel
          ..kind = kind
          ..phase.value = SshSessionPhase.ready;
    _bindTerminal(attached, channel, touch: session.touch);
    final previous = session._attachment.value;
    session.herdr?.stop();
    session._attachment.value = attached;
    if (previous != null) _closeAttachment(previous);

    void done() {
      if (!identical(session._attachment.value, attached)) return;
      // A completed program returns naturally to the shell. Loss of the
      // transport must still reattach a profile configured to do so.
      if (channel.exitCode != null || channel.exitSignal != null) {
        session._keepPlainShell = true;
        session.kind = SshSessionKind.shell;
      }
      _detachTerminal(session);
    }

    unawaited(
      channel.done.then<void>((_) => done(), onError: (Object _) => done()),
    );
    return true;
  }

  /// Leave an attached client and keep the original login shell alive, for
  /// as long as this connection lives. Going back is a look at the shell,
  /// not a change of the profile: the next connection opens what the
  /// profile says again (a program that EXITED is different, see
  /// [attachTerminal]: reopening it on every reconnect would undo the exit).
  void showPlainShell(SshTerminalSession session) {
    if (!identical(of(session.connectionId), session)) return;
    session.kind = SshSessionKind.shell;
    session._attachmentRevision++;
    _detachTerminal(session);
  }

  void _detachTerminal(SshTerminalSession session) {
    final attached = session._attachment.value;
    session.herdr?.stop();
    if (attached == null) return;
    session._attachment.value = null;
    _closeAttachment(attached);
  }

  void _closeAttachment(SshTerminalSession session) {
    session.end = SshSessionEnd.closedByApp;
    session._cancelOutput();
    session.terminal.onOutput = null;
    session.terminal.onResize = null;
    session.shell?.close();
    session.phase.value = SshSessionPhase.closed;
  }

  /// A probe prints a path: more than this is not one (kept, not read).
  static const int _probeOutputLimit = 4096;

  /// Runs [command] (`command -v …`) on its own `execute` channel, never in
  /// the user's pty. Exit status 0 means installed, and what it printed (the
  /// program's path) is returned; anything else, an error or no answer
  /// within [probeTimeout] counts as missing (null).
  Future<String?> _probeProgram(SSHClient client, String command) async {
    SSHSession? probe;
    try {
      final opening = client.execute(command);
      try {
        probe = await opening.timeout(probeTimeout);
      } on TimeoutException {
        // The channel may still open after the timeout: close it then, as
        // runRemote does, or every slow connect leaves one open.
        unawaited(opening.then((opened) => opened.close(), onError: (_) {}));
        rethrow;
      }
      final channel = probe;
      final out = BytesBuilder(copy: false);
      await Future.wait<void>([
        channel.stdout.forEach((chunk) {
          if (out.length < _probeOutputLimit) out.add(chunk);
        }),
        channel.stderr.drain<void>(),
        channel.done,
      ]).timeout(probeTimeout);
      if (channel.exitCode != 0) return null;
      return utf8.decode(out.takeBytes(), allowMalformed: true);
    } catch (e) {
      debugPrint('[ssh-session] program probe failed (${e.runtimeType})');
      probe?.close();
      return null;
    }
  }

  /// Most a read command may print (stdout and stderr together): a Herdr
  /// snapshot is a few KiB; more is refused, not decoded on the UI thread
  /// every 5 s (review R5A P3-B4-1).
  static const int remoteOutputLimit = 1024 * 1024;

  Future<SshRemoteResult> _runRemote(SSHClient client, String command) =>
      runRemote(client, command);

  /// Runs a command built by the app (Herdr's CLI) on its own `execute`
  /// channel and collects its output, with the same time ([probeTimeout])
  /// and size ([remoteOutputLimit]) limits for every caller. Never touches
  /// the user's pty.
  static Future<SshRemoteResult> runRemote(
    SSHClient client,
    String command,
  ) async {
    final opening = client.execute(command);
    final SSHSession channel;
    try {
      channel = await opening.timeout(probeTimeout);
    } on TimeoutException {
      // The channel may still open after the timeout: close it then, or
      // every timed-out read leaves one open (review R5A P3-B4-2).
      unawaited(opening.then((opened) => opened.close(), onError: (_) {}));
      rethrow;
    }
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    var tooLarge = false;
    void collect(BytesBuilder into, Uint8List chunk) {
      if (out.length + err.length + chunk.length > remoteOutputLimit) {
        tooLarge = true;
        return;
      }
      into.add(chunk);
    }

    try {
      await Future.wait<void>([
        channel.stdout.forEach((chunk) => collect(out, chunk)),
        channel.stderr.forEach((chunk) => collect(err, chunk)),
        channel.done,
      ]).timeout(probeTimeout);
    } catch (_) {
      channel.close();
      rethrow;
    }
    if (tooLarge) {
      throw const FormatException('Remote output over the size limit');
    }
    return SshRemoteResult(
      stdout: utf8.decode(out.takeBytes(), allowMalformed: true),
      stderr: utf8.decode(err.takeBytes(), allowMalformed: true),
      exitCode: channel.exitCode,
    );
  }

  /// Escribe en el shell (p.ej. un comando rápido).
  void send(String connectionId, String data) {
    final s = _sessions[connectionId]?.visibleTerminal;
    if (s?.shell == null || s!.phase.value != SshSessionPhase.ready) return;
    s.shell!.write(Uint8List.fromList(utf8.encode(data)));
  }

  /// Cierra y olvida la sesión de una instancia.
  void close(String connectionId) {
    _composed.remove(connectionId);
    final draft = _drafts.remove(connectionId);
    final s = _sessions.remove(connectionId);
    final keepClientForCleanup =
        draft != null &&
        draft.hasUnsentUploads &&
        s != null &&
        s.client != null &&
        !s.isClientClosed;
    if (s != null) {
      s.end ??= SshSessionEnd.closedByApp;
      _detachTerminal(s);
      s._cancelOutput();
      s.shell?.close();
      if (!keepClientForCleanup) {
        s.client?.close();
      }
      s.phase.value = SshSessionPhase.closed;
    }
    if (keepClientForCleanup) {
      unawaited(
        draft.cleanupUnsent().whenComplete(() {
          draft.dispose();
          s.client?.close();
        }),
      );
    } else {
      draft?.dispose();
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
  /// A session whose terminal is actively visible in the foreground
  /// ([attachView]) is never closed for being quiet. Devuelve cuántas
  /// cerró.
  int closeIdle(Duration maxIdle) {
    final now = DateTime.now();
    final idle = _sessions.entries
        .where(
          (e) =>
              e.value.isLive &&
              !isViewed(e.key) &&
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
