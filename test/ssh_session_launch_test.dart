import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/herdr_agents.dart'
    show herdrShellQuote;
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/ssh_terminal_input.dart';
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
  final List<_FakeShell> attachments = [];
  Future<SSHSession>? pendingAttachment;
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
    if (pty != null) {
      final pending = pendingAttachment;
      if (pending != null) return pending;
      final attached = _FakeShell();
      attachments.add(attached);
      return attached;
    }
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

  test('Herdr uses its own PTY after the probe', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.herdr);
    final service = SshSessionService(ssh);
    final attached = <SshTerminalSession>[];
    service.onMultiplexerAttached = (session, _) => attached.add(session);

    final session = await service.connect('c1', onHostKey: (_) async => true);

    final client = ssh.clients.single;
    expect(client.executed, [
      sshHerdrProbeCommand,
      '"\${SHELL:-/bin/sh}" -lc ${herdrShellQuote("'/usr/bin/x'")}',
    ]);
    expect(client.shellSession.written, isEmpty);
    expect(session.attachment.value?.shell, same(client.attachments.single));
    expect(session.missingProgram.value, isNull);
    expect(attached, [session]);
  });

  test('tmux opens a dedicated create-or-attach PTY', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.tmux);
    final service = SshSessionService(ssh);

    await service.connect('c1', onHostKey: (_) async => true);

    final client = ssh.clients.single;
    expect(client.executed, [
      sshTmuxProbeCommand,
      sshInLoginShell(sshTmuxLaunchCommand),
    ]);
    expect(client.shellSession.written, isEmpty);
    expect(client.attachments, hasLength(1));
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
        '"\${SHELL:-/bin/sh}" -lc ${herdrShellQuote("'/usr/bin/x'")}',
      ]);
      expect(client.shellSession.written, isEmpty);
      expect(session.attachment.value?.shell, same(client.attachments.single));
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
    ssh.clients.first.attachments.single.end();
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
    expect(ssh.clients.last.executed, [
      sshTmuxProbeCommand,
      sshInLoginShell(sshTmuxLaunchCommand),
    ]);
    expect(ssh.clients.last.shellSession.written, isEmpty);
    expect(first.attachment.value, isNull);
    expect(
      second.attachment.value?.shell,
      same(ssh.clients.last.attachments.single),
    );
    expect(second.phase.value, SshSessionPhase.ready);
  });

  test(
    'Herdr, tmux and the normal shell keep their own terminal input',
    () async {
      final ssh = _FakeSshManager(kind: SshSessionKind.shell);
      final service = SshSessionService(ssh);
      final root = await service.connect('c1', onHostKey: (_) async => true);
      final client = ssh.clients.single;
      final shell = client.shellSession;
      shell.stdoutController.add(
        Uint8List.fromList(utf8.encode('base prompt')),
      );
      await _settle();

      expect(
        await service.attachTerminal(root, SshSessionKind.herdr, 'herdr'),
        isTrue,
      );
      final herdr = client.attachments.single;
      expect(root.visibleTerminal.terminal, isNot(same(root.terminal)));
      root.visibleTerminal.terminal.textInput('n');
      expect(herdr.written, ['n']);
      expect(shell.written, isEmpty);

      expect(
        await service.attachTerminal(
          root,
          SshSessionKind.tmux,
          sshTmuxLaunchCommand,
        ),
        isTrue,
      );
      final tmux = client.attachments.last;
      expect(herdr.closed, isTrue);
      expect(herdr.stdoutController.hasListener, isFalse);
      expect(root.visibleTerminal.kind, SshSessionKind.tmux);

      service.showPlainShell(root);
      expect(tmux.closed, isTrue);
      expect(client.closed, isFalse);
      expect(shell.closed, isFalse);
      expect(root.phase.value, SshSessionPhase.ready);
      expect(root.visibleTerminal, same(root));
      expect(
        root.terminal.buffer.lines.toList().join('\n'),
        contains('base prompt'),
      );
      root.terminal.textInput('a');
      expect(shell.written, ['a']);
    },
  );

  test('leaving an attachment invalidates a switch still opening', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.shell);
    final service = SshSessionService(ssh);
    final root = await service.connect('c1', onHostKey: (_) async => true);
    final client = ssh.clients.single;
    await service.attachTerminal(root, SshSessionKind.herdr, 'herdr');

    final next = Completer<SSHSession>();
    client.pendingAttachment = next.future;
    final switching = service.attachTerminal(
      root,
      SshSessionKind.tmux,
      sshTmuxLaunchCommand,
    );
    service.showPlainShell(root);
    final lateChannel = _FakeShell();
    next.complete(lateChannel);

    expect(await switching, isFalse);
    expect(lateChannel.closed, isTrue);
    expect(root.visibleTerminal, same(root));
    expect(client.shellSession.closed, isFalse);
  });

  test(
    'a program exit goes back to the shell and stays there on reconnect',
    () async {
      final ssh = _FakeSshManager(kind: SshSessionKind.herdr);
      final service = SshSessionService(ssh);
      final root = await service.connect('c1', onHostKey: (_) async => true);
      final client = ssh.clients.single;
      client.attachments.single.end(exitCode: 0);
      await _settle();
      expect(root.visibleTerminal, same(root));
      expect(client.shellSession.closed, isFalse);

      client.shellSession.end();
      await _settle();
      final reconnected = await service.connect(
        'c1',
        onHostKey: (_) async => true,
      );
      expect(reconnected.visibleTerminal, same(reconnected));
      expect(ssh.clients.last.attachments, isEmpty);
      expect(ssh.clients.last.executed, isEmpty);
    },
  );

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

  // 1.4.3: Ctrl double tapped stays on for every key; Alt puts ESC first;
  // a paste goes through untouched by either.
  test('locked ctrl, alt and a paste reach the shell as meant', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.shell);
    final service = SshSessionService(ssh);
    final session = await service.connect('c1', onHostKey: (_) async => true);
    final shell = ssh.clients.single.shellSession;
    final modifiers = session.modifiers;

    modifiers.ctrl.tap();
    modifiers.ctrl.tap();
    expect(modifiers.ctrl.locked.value, isTrue);
    session.terminal.textInput('c');
    session.terminal.textInput('c');
    sshPasteText(session.terminal, 'c', modifiers: modifiers);
    modifiers.ctrl.tap();
    modifiers.alt.tap();
    session.terminal.textInput('b');
    session.terminal.textInput('b');

    expect(shell.written, ['\x03', '\x03', 'c', '\x1bb', 'b']);
  });

  // U-11 and 1.4.3: the idle close never takes a terminal that is open
  // (on screen, or a panel of the workspace); closed, it goes as before.
  test('the idle close spares a session whose terminal is open', () async {
    final ssh = _FakeSshManager(kind: SshSessionKind.shell);
    final service = SshSessionService(ssh);
    final session = await service.connect('c1', onHostKey: (_) async => true);
    final client = ssh.clients.single;
    session.lastActivityAt = DateTime.now().subtract(
      const Duration(minutes: 30),
    );

    service.attachView('c1');
    service.attachView('c1');
    expect(service.closeIdle(const Duration(minutes: 10)), 0);
    expect(session.phase.value, SshSessionPhase.ready);
    expect(client.closed, isFalse);

    // Two screens on it: closing one is not enough.
    service.detachView('c1');
    expect(service.closeIdle(const Duration(minutes: 10)), 0);
    expect(session.phase.value, SshSessionPhase.ready);

    service.detachView('c1');
    expect(service.isViewed('c1'), isFalse);
    expect(service.closeIdle(const Duration(minutes: 10)), 1);
    expect(session.phase.value, SshSessionPhase.closed);
    expect(session.end, SshSessionEnd.closedByApp);
    expect(client.closed, isTrue);
  });

  test('Compose remembers in memory, newest first, until closed', () async {
    final service = SshSessionService(
      _FakeSshManager(kind: SshSessionKind.shell),
    );
    await service.connect('c1', onHostKey: (_) async => true);

    service.rememberComposed('c1', 'ls -la');
    service.rememberComposed('c1', 'git status');
    service.rememberComposed('c1', 'ls -la');
    service.rememberComposed('c1', '   ');
    expect(service.composeHistory('c1'), ['ls -la', 'git status']);
    expect(service.composeHistory('c2'), isEmpty);
    for (var i = 0; i < 30; i++) {
      service.rememberComposed('c1', 'echo $i');
    }
    expect(
      service.composeHistory('c1').length,
      SshSessionService.composeHistoryLimit,
    );
    expect(service.composeHistory('c1').first, 'echo 29');

    service.close('c1');
    expect(service.composeHistory('c1'), isEmpty);
  });
}
