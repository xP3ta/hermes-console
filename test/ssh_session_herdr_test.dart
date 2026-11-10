import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/herdr_status.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final String _snapshotStdout = File(
  'test/fixtures/herdr/snapshot_0_9_5.json',
).readAsStringSync();

class _FakeShell implements SSHSession {
  final stdoutController = StreamController<Uint8List>();
  final stderrController = StreamController<Uint8List>();
  final _done = Completer<void>();
  final List<String> written = [];

  void end() => _done.complete();

  @override
  Stream<Uint8List> get stdout => stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => stderrController.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => null;

  @override
  SSHSessionExitSignal? get exitSignal => null;

  @override
  void close() {}

  @override
  void write(Uint8List data) => written.add(utf8.decode(data));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A finished `execute` channel with fixed output.
class _FakeExec implements SSHSession {
  _FakeExec(this.code, {this.out = ''});

  final int code;
  final String out;

  @override
  Stream<Uint8List> get stdout =>
      Stream.value(Uint8List.fromList(utf8.encode(out)));

  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

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
  _FakeClient(this.shellSession, {required this.probeOut, this.snapshotOut});

  final _FakeShell shellSession;

  /// What `command -v herdr` prints.
  final String probeOut;

  /// What a snapshot prints, if not the fixture.
  final String? snapshotOut;
  final List<String> executed = [];

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
    if (command.endsWith('api snapshot') ||
        command == sshHerdrSnapshotCommand) {
      return _FakeExec(0, out: snapshotOut ?? _snapshotStdout);
    }
    return _FakeExec(0, out: probeOut);
  }

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async => shellSession;

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConnections implements ConnectionManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshManager extends SshManager {
  _FakeSshManager(
    this.kind, {
    this.probeOut = '/usr/local/bin/x\n',
    this.snapshotOut,
  }) : super(SecureStorage(), _FakeConnections());

  final SshSessionKind kind;
  final String probeOut;
  final String? snapshotOut;
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
      probeOut: probeOut,
      snapshotOut: snapshotOut,
    );
    clients.add(client);
    return client;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a Herdr session reads its state on its own channel', () async {
    final ssh = _FakeSshManager(SshSessionKind.herdr);
    final service = SshSessionService(ssh);
    final session = await service.connect('c1', onHostKey: (_) async => true);
    final client = ssh.clients.single;

    final monitor = session.herdr!;
    monitor.start();
    await pumpEventQueue();

    // Review R5A P2-B4-3: the probe resolved Herdr's path once; the reads
    // run it directly, without a login shell each time.
    expect(client.executed, [
      sshHerdrProbeCommand,
      herdrSnapshotCommand('/usr/local/bin/x'),
    ]);
    expect(
      herdrSnapshotCommand('/usr/local/bin/x'),
      "'/usr/local/bin/x' api snapshot",
    );
    // The pty only ever got the launch line.
    expect(client.shellSession.written, ['herdr\n']);
    expect(monitor.view.value.snapshot!.focusedPane!.name, 'reviewer');
    monitor.stop();
  });

  test('without a usable path the reads use the login shell', () async {
    for (final probeOut in ['herdr\n', 'alias herdr=x\n', '']) {
      final ssh = _FakeSshManager(SshSessionKind.herdr, probeOut: probeOut);
      final service = SshSessionService(ssh);
      final session = await service.connect('c1', onHostKey: (_) async => true);
      final monitor = session.herdr!;
      monitor.start();
      await pumpEventQueue();
      expect(
        ssh.clients.single.executed,
        [sshHerdrProbeCommand, sshHerdrSnapshotCommand],
        reason: probeOut,
      );
      monitor.stop();
    }
  });

  // Review R5A P3-B4-1: a read never collects more than the limit.
  test('a snapshot over the size limit is a failed read', () async {
    final ssh = _FakeSshManager(
      SshSessionKind.herdr,
      snapshotOut: 'x' * (SshSessionService.remoteOutputLimit + 1),
    );
    final service = SshSessionService(ssh);
    final session = await service.connect('c1', onHostKey: (_) async => true);
    final monitor = session.herdr!;
    monitor.start();
    await pumpEventQueue();
    expect(monitor.view.value.failed, isTrue);
    expect(monitor.view.value.snapshot, isNull);
    monitor.stop();
  });

  test('plain shell and tmux sessions have no Herdr monitor', () async {
    for (final kind in [SshSessionKind.shell, SshSessionKind.tmux]) {
      final service = SshSessionService(_FakeSshManager(kind));
      final session = await service.connect(
        'c1',
        onHostKey: (_) async => true,
      );
      expect(session.herdr, isNull, reason: kind.id);
    }
  });

  test('closing or losing the session stops the monitor', () async {
    final ssh = _FakeSshManager(SshSessionKind.herdr);
    final service = SshSessionService(ssh);
    final session = await service.connect('c1', onHostKey: (_) async => true);
    session.herdr!.start();
    await pumpEventQueue();
    expect(session.herdr!.isRunning, isTrue);

    ssh.clients.single.shellSession.end();
    await pumpEventQueue();
    expect(session.herdr!.isRunning, isFalse);

    final second = await service.connect('c1', onHostKey: (_) async => true);
    second.herdr!.start();
    service.close('c1');
    expect(second.herdr!.isRunning, isFalse);
  });

  test('the monitor reports a missing server from stderr', () async {
    final stderr = File(
      'test/fixtures/herdr/server_not_running_0_9_5.json',
    ).readAsStringSync();
    final monitor = HerdrMonitor(
      run: (_) async =>
          SshRemoteResult(stdout: '', stderr: stderr, exitCode: 1),
    );
    monitor.start();
    await pumpEventQueue();
    expect(monitor.view.value.notRunning, isTrue);
    monitor.dispose();
  });
}
