import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/herdr_agents_screen.dart';

class _Channel implements SSHSession {
  _Channel(this.out);

  final String out;

  @override
  Stream<Uint8List> get stdout =>
      Stream.value(Uint8List.fromList(utf8.encode(out)));

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  Future<void> get done => Future<void>.value();

  @override
  int? get exitCode => 0;

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements SSHClient {
  _Client(this.name, {this.fail = false});

  final String name;
  bool fail;
  bool closed = false;
  final List<String> commands = [];

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    commands.add(command);
    if (fail) throw StateError('channel refused');
    return _Channel(name);
  }

  @override
  void close() => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('the terminal session client is used when it is ready', () async {
    final terminal = _Client('terminal');
    var opened = 0;
    final transport = HerdrAgentsTransport(
      open: () async {
        opened++;
        return _Client('own');
      },
      shared: () => terminal,
    );

    final result = await transport.run('herdr api snapshot');

    expect(result.stdout, 'terminal');
    expect(result.exitCode, 0);
    expect(opened, 0);
    expect(terminal.commands, ['herdr api snapshot']);
    transport.close();
    // The terminal's client is not ours to close.
    expect(terminal.closed, isFalse);
  });

  test('without a terminal it opens one client, once, and reuses it', () async {
    final own = _Client('own');
    var opened = 0;
    final transport = HerdrAgentsTransport(
      open: () async {
        opened++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return own;
      },
      shared: () => null,
    );

    // Two commands at once share the one connection being opened.
    final results = await Future.wait([transport.run('a'), transport.run('b')]);
    await transport.run('c');

    expect(results.map((r) => r.stdout), ['own', 'own']);
    expect(opened, 1);
    expect(own.commands, ['a', 'b', 'c']);

    transport.close();
    expect(own.closed, isTrue);
  });

  test('a client of its own that fails is dropped and reopened', () async {
    final first = _Client('first', fail: true);
    final second = _Client('second');
    final clients = [first, second];
    final transport = HerdrAgentsTransport(
      open: () async => clients.removeAt(0),
      shared: () => null,
    );

    await expectLater(transport.run('x'), throwsStateError);
    expect(first.closed, isTrue);
    final result = await transport.run('y');
    expect(result.stdout, 'second');
    transport.close();
  });

  test('a failed opening is not remembered', () async {
    var attempts = 0;
    final transport = HerdrAgentsTransport(
      open: () async {
        attempts++;
        if (attempts == 1) throw StateError('network down');
        return _Client('own');
      },
      shared: () => null,
    );
    await expectLater(transport.run('x'), throwsStateError);
    expect((await transport.run('x')).stdout, 'own');
    expect(attempts, 2);
    transport.close();
  });

  test('once closed it opens nothing more', () async {
    final gate = Completer<SSHClient>();
    final transport = HerdrAgentsTransport(
      open: () => gate.future,
      shared: () => null,
    );
    final pending = transport.run('x');
    transport.close();
    final client = _Client('own');
    gate.complete(client);
    await expectLater(pending, throwsStateError);
    expect(client.closed, isTrue);
  });
}
