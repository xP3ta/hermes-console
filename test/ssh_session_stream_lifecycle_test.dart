import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

class _FakeShell implements SSHSession {
  final stdoutController = StreamController<Uint8List>();
  final stderrController = StreamController<Uint8List>();
  final _done = Completer<void>();
  bool closed = false;

  @override
  Stream<Uint8List> get stdout => stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => stderrController.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void close() => closed = true;

  @override
  void write(Uint8List data) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements SSHClient {
  _FakeClient(this.shellSession);

  final _FakeShell shellSession;
  bool closed = false;

  @override
  Future<void> get authenticated => Future<void>.value();

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
  _FakeSshManager(this.clients) : super(SecureStorage(), _FakeConnections());

  final List<_FakeClient> clients;

  @override
  Strings get appStrings => lookupStrings(const Locale('en'));

  @override
  Future<SSHClient> connect(
    String connectionId, {
    required Future<bool> Function(SshHostKeyPrompt) onHostKey,
  }) async {
    final client = _FakeClient(_FakeShell());
    clients.add(client);
    return client;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('closing a session releases its shell output subscriptions', () async {
    final clients = <_FakeClient>[];
    final service = SshSessionService(_FakeSshManager(clients));

    final session = await service.connect('c1', onHostKey: (_) async => true);
    expect(session.phase.value, SshSessionPhase.ready);
    final shell = clients.single.shellSession;
    expect(shell.stdoutController.hasListener, isTrue);
    expect(shell.stderrController.hasListener, isTrue);

    service.close('c1');

    expect(shell.closed, isTrue);
    expect(clients.single.closed, isTrue);
    expect(shell.stdoutController.hasListener, isFalse);
    expect(shell.stderrController.hasListener, isFalse);
  });

  test('output still reaches the terminal while the session is open', () async {
    final clients = <_FakeClient>[];
    final service = SshSessionService(_FakeSshManager(clients));

    final session = await service.connect('c1', onHostKey: (_) async => true);
    final shell = clients.single.shellSession;
    shell.stdoutController.add(Uint8List.fromList('hello-out'.codeUnits));
    shell.stderrController.add(Uint8List.fromList('hello-err'.codeUnits));
    await Future<void>.delayed(Duration.zero);

    final text = session.terminal.buffer.lines.toList().join('\n');
    expect(text, contains('hello-out'));
    expect(text, contains('hello-err'));
  });

  group('output split across packets (UTF-8)', () {
    Future<(SshTerminalSession, _FakeShell)> open() async {
      final clients = <_FakeClient>[];
      final service = SshSessionService(_FakeSshManager(clients));
      final session = await service.connect('c1', onHostKey: (_) async => true);
      return (session, clients.single.shellSession);
    }

    String screen(SshTerminalSession session) =>
        session.terminal.buffer.lines.toList().join('\n');

    test('a character split between two packets reaches it whole', () async {
      final (session, shell) = await open();
      final bytes = utf8.encode('mañana 😀');
      // «ñ» is two bytes: the first packet ends between them.
      shell.stdoutController
        ..add(Uint8List.fromList(bytes.sublist(0, 3)))
        ..add(Uint8List.fromList(bytes.sublist(3)));
      await Future<void>.delayed(Duration.zero);

      expect(screen(session), contains('mañana 😀'));
      expect(screen(session), isNot(contains('\uFFFD')));
    });

    test('stdout and stderr do not complete each other', () async {
      final (session, shell) = await open();
      final enye = utf8.encode('ñ');
      shell.stdoutController.add(Uint8List.fromList(enye.sublist(0, 1)));
      await Future<void>.delayed(Duration.zero);
      shell.stderrController.add(Uint8List.fromList(utf8.encode('x')));
      await Future<void>.delayed(Duration.zero);
      shell.stdoutController.add(Uint8List.fromList(enye.sublist(1)));
      await Future<void>.delayed(Duration.zero);

      expect(screen(session), contains('xñ'));
      expect(screen(session), isNot(contains('\uFFFD')));
    });

    test('an output that ends half-way shows one U+FFFD', () async {
      final (session, shell) = await open();
      shell.stdoutController.add(Uint8List.fromList([0x6F, 0x6B, 0xE2, 0x82]));
      await Future<void>.delayed(Duration.zero);
      expect(screen(session), contains('ok'));
      expect(screen(session), isNot(contains('\uFFFD')));

      await shell.stdoutController.close();
      await Future<void>.delayed(Duration.zero);
      expect('\uFFFD'.allMatches(screen(session)), hasLength(1));
    });
  });

  test(
    'reconnecting after close drops the previous shell subscriptions',
    () async {
      final clients = <_FakeClient>[];
      final service = SshSessionService(_FakeSshManager(clients));

      final first = await service.connect('c1', onHostKey: (_) async => true);
      clients.first.shellSession.stdoutController.add(
        Uint8List.fromList('before'.codeUnits),
      );
      await Future<void>.delayed(Duration.zero);
      service.closeAll();
      final second = await service.connect('c1', onHostKey: (_) async => true);

      expect(identical(first, second), isFalse);
      expect(clients.first.shellSession.stdoutController.hasListener, isFalse);
      expect(clients.last.shellSession.stdoutController.hasListener, isTrue);
    },
  );
}
