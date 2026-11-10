import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// The interactive pty. Records everything the app types into it.
class _FakeShell implements SSHSession {
  final stdoutController = StreamController<Uint8List>();
  final stderrController = StreamController<Uint8List>();
  final _done = Completer<void>();
  final List<String> written = [];
  int? fakeExitCode;
  bool closed = false;

  String get typed => written.join();

  void end({int? exitCode}) {
    fakeExitCode = exitCode;
    _done.complete();
  }

  @override
  Stream<Uint8List> get stdout => stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => stderrController.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => fakeExitCode;

  @override
  SSHSessionExitSignal? get exitSignal => null;

  @override
  void close() => closed = true;

  @override
  void write(Uint8List data) => written.add(utf8.decode(data));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A finished `execute` channel with the given exit status.
class _FakeProbe implements SSHSession {
  _FakeProbe(this.code);

  final int code;

  @override
  Stream<Uint8List> get stdout =>
      Stream.value(Uint8List.fromList(utf8.encode('/usr/bin/x\n')));

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  Future<void> get done => Future<void>.value();

  @override
  int? get exitCode => code;

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements SSHClient {
  _FakeClient(this.shellSession, this.probe, {this.fallbackProbe});

  final _FakeShell shellSession;

  /// Exit status of `command -v …`; null makes the probe throw.
  final int? probe;

  /// Exit status of the second, folder-by-folder look; the first probe's
  /// when unset.
  final int? fallbackProbe;
  final List<String> executed = [];
  bool closed = false;

  @override
  Future<void> get authenticated => Future<void>.value();

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    executed.add(command);
    final code = command == sshHerdrFallbackProbeCommand
        ? (fallbackProbe ?? probe)
        : probe;
    if (code == null) throw SSHChannelOpenError(1, 'denied');
    return _FakeProbe(code);
  }

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async => shellSession;

  @override
  void close() => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConnections implements ConnectionManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshManager extends SshManager {
  _FakeSshManager({required this.kind, this.probe = 0, this.fallbackProbe})
    : super(SecureStorage(), _FakeConnections());

  SshSessionKind kind;
  int? probe;
  int? fallbackProbe;
  final List<_FakeClient> clients = [];

  @override
  Strings get appStrings => lookupStrings(const Locale('en'));

  @override
  Future<SshSessionKind> loadSessionKind(String connectionId) async => kind;

  @override
  Future<SSHClient> connect(
    String connectionId, {
    required Future<bool> Function(SshHostKeyPrompt) onHostKey,
  }) async {
    final client = _FakeClient(
      _FakeShell(),
      probe,
      fallbackProbe: fallbackProbe,
    );
    clients.add(client);
    return client;
  }
}

Future<void> _settle() => pumpEventQueue();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('plain shell: no probe and nothing typed, exactly as before', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.shell);
    final service = SshSessionService(ssh);
    var attached = 0;
    service.onMultiplexerAttached = (_, _) => attached++;

    final session = await service.connect('c1', onHostKey: (_) async => true);

    expect(session.phase.value, SshSessionPhase.ready);
    expect(session.kind, SshSessionKind.shell);
    expect(ssh.clients.single.executed, isEmpty);
    expect(ssh.clients.single.shellSession.written, isEmpty);
    expect(session.missingProgram.value, isNull);
    expect(attached, 0);
  });

  for (final legacy in ['herdr', 'tmux']) {
    test('a profile saved as `$legacy` before the plain terminal opens a '
        'plain shell: no probe, no write', () async {
      // The manager reads it through fromStored, as SshManager does.
      final ssh = _FakeSshManager(kind: SshSessionKind.fromStored(legacy));
      final service = SshSessionService(ssh);
      var attached = 0;
      service.onMultiplexerAttached = (_, _) => attached++;

      final session = await service.connect('c1', onHostKey: (_) async => true);
      await _settle();

      expect(session.kind, SshSessionKind.shell);
      expect(ssh.clients.single.executed, isEmpty);
      expect(ssh.clients.single.shellSession.written, isEmpty);
      expect(session.herdr, isNull);
      expect(attached, 0);
    });
  }

  test('Herdr: probes on its own channel, then types `herdr`', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.herdr);
    final service = SshSessionService(ssh);
    final attached = <SshTerminalSession>[];
    service.onMultiplexerAttached = (session, _) => attached.add(session);

    final session = await service.connect('c1', onHostKey: (_) async => true);

    final client = ssh.clients.single;
    expect(client.executed, [sshHerdrProbeCommand]);
    expect(client.shellSession.written, ['herdr\n']);
    expect(session.missingProgram.value, isNull);
    expect(attached, [session]);
  });

  test('tmux: types the exact create-or-attach command', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.tmux);
    final service = SshSessionService(ssh);

    await service.connect('c1', onHostKey: (_) async => true);

    final client = ssh.clients.single;
    expect(client.executed, [sshTmuxProbeCommand]);
    expect(client.shellSession.written, [
      'tmux new-session -A -D -s hermes-console\n',
    ]);
  });

  for (final kind in [SshSessionKind.herdr, SshSessionKind.tmux]) {
    test('${kind.id} missing: runs nothing and reports it', () async {
      final ssh = _FakeSshManager(kind: kind, probe: 1);
      final service = SshSessionService(ssh);
      var attached = 0;
      service.onMultiplexerAttached = (_, _) => attached++;

      final session = await service.connect('c1', onHostKey: (_) async => true);

      final client = ssh.clients.single;
      // Only the probes ran (Herdr gets a second look); nothing (no
      // installer either) reached the pty.
      expect(client.executed, [kind.probeCommand, ?kind.fallbackProbeCommand]);
      expect(client.shellSession.written, isEmpty);
      expect(session.phase.value, SshSessionPhase.ready);
      expect(session.missingProgram.value, kind);
      expect(attached, 0);
    });
  }

  test(
    'Herdr the login shell misses but its folder has: launches it',
    () async {
      final ssh = _FakeSshManager(
        kind: SshSessionKind.herdr,
        probe: 1,
        fallbackProbe: 0,
      );
      final service = SshSessionService(ssh);

      final session = await service.connect('c1', onHostKey: (_) async => true);

      final client = ssh.clients.single;
      expect(client.executed, [
        sshHerdrProbeCommand,
        sshHerdrFallbackProbeCommand,
      ]);
      // The fake prints /usr/bin/x: the validated path is what gets typed.
      expect(client.shellSession.written, ["'/usr/bin/x'\n"]);
      expect(session.missingProgram.value, isNull);
      expect(session.herdr, isNotNull);
    },
  );

  test('the fallback look is constant, POSIX and only looks', () {
    expect(sshHerdrFallbackProbeCommand, startsWith("/bin/sh -c '"));
    expect(sshHerdrFallbackProbeCommand, contains('.local/bin/herdr'));
    expect(sshHerdrFallbackProbeCommand, isNot(contains('curl')));
    expect(sshHerdrFallbackProbeCommand, isNot(contains('install')));
    // One quoted argument: no stray single quote inside the body.
    final body = sshHerdrFallbackProbeCommand.substring(
      "/bin/sh -c '".length,
      sshHerdrFallbackProbeCommand.length - 1,
    );
    expect(body, isNot(contains("'")));
  });

  test('a probe that fails counts as missing', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.herdr, probe: null);
    final service = SshSessionService(ssh);

    final session = await service.connect('c1', onHostKey: (_) async => true);

    expect(ssh.clients.single.shellSession.written, isEmpty);
    expect(session.phase.value, SshSessionPhase.ready);
    expect(session.missingProgram.value, SshSessionKind.herdr);
  });

  test('a channel closed without exit status is a lost connection', () async {
    final service = SshSessionService(
      _FakeSshManager(kind: SshSessionKind.shell),
    );
    final session = await service.connect('c1', onHostKey: (_) async => true);
    final shell = session.shell! as _FakeShell;

    shell.end();
    await _settle();

    expect(session.phase.value, SshSessionPhase.closed);
    expect(session.end, SshSessionEnd.connectionLost);
  });

  test('a shell that exits is not a lost connection', () async {
    final service = SshSessionService(
      _FakeSshManager(kind: SshSessionKind.shell),
    );
    final session = await service.connect('c1', onHostKey: (_) async => true);
    final shell = session.shell! as _FakeShell;

    shell.end(exitCode: 0);
    await _settle();

    expect(session.phase.value, SshSessionPhase.closed);
    expect(session.end, SshSessionEnd.remoteExit);
  });

  test('closing from the app is marked as wanted', () async {
    final service = SshSessionService(
      _FakeSshManager(kind: SshSessionKind.shell),
    );
    final session = await service.connect('c1', onHostKey: (_) async => true);

    service.close('c1');
    (session.shell! as _FakeShell).end();
    await _settle();

    expect(session.end, SshSessionEnd.closedByApp);
  });

  test('reconnecting with tmux reattaches and keeps the scrollback', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.tmux);
    final service = SshSessionService(ssh);
    final first = await service.connect('c1', onHostKey: (_) async => true);
    ssh.clients.first.shellSession.stdoutController.add(
      Uint8List.fromList(utf8.encode('before-drop')),
    );
    await _settle();
    ssh.clients.first.shellSession.end();
    await _settle();

    final second = await service.connect('c1', onHostKey: (_) async => true);

    expect(identical(first, second), isFalse);
    expect(identical(first.terminal, second.terminal), isTrue);
    expect(
      second.terminal.buffer.lines.toList().join('\n'),
      contains('before-drop'),
    );
    expect(ssh.clients.last.shellSession.written, [
      'tmux new-session -A -D -s hermes-console\n',
    ]);
    expect(second.phase.value, SshSessionPhase.ready);
  });

  test('one-shot ctrl turns the next key into a control character', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.shell);
    final service = SshSessionService(ssh);
    final session = await service.connect('c1', onHostKey: (_) async => true);
    final shell = ssh.clients.single.shellSession;

    session.ctrlArmed.value = true;
    session.terminal.textInput('b');
    session.terminal.textInput('b');

    expect(shell.written, ['\x02', 'b']);
    expect(session.ctrlArmed.value, isFalse);
  });

  // Review P2-4: xterm's own replies travel the same way as keys.
  test('a terminal reply does not use up the armed ctrl', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.shell);
    final service = SshSessionService(ssh);
    final session = await service.connect('c1', onHostKey: (_) async => true);
    final shell = ssh.clients.single.shellSession;

    session.ctrlArmed.value = true;
    // Cursor position report (DSR answer) generated by the terminal.
    session.terminal.textInput('\x1b[12;1R');
    expect(session.ctrlArmed.value, isTrue);
    session.terminal.textInput('b');

    expect(shell.written, ['\x1b[12;1R', '\x02']);
    expect(session.ctrlArmed.value, isFalse);
  });
}
