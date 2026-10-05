// The terminal page's logic: one command at a time, input checked before it
// leaves the device, the server's refusals shown verbatim, history that lives
// in memory only and dies with the page, the lock and the profile.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/terminal_exec.dart';
import 'package:hermes_android/core/services/terminal_pane_controller.dart';

import 'support/fake_terminal_gateway.dart';

Future<TerminalPaneController> _open(
  FakeTerminalGateway gateway, {
  String profile = 'work',
}) async {
  final controller = TerminalPaneController(
    gateway: gateway,
    profile: profile,
    appLockEnabled: () => true,
    verify: () async => true,
  );
  addTearDown(controller.dispose);
  await controller.open();
  return controller;
}

void main() {
  test('run sends exactly the command and the profile', () async {
    final gateway = FakeTerminalGateway();
    final c = await _open(gateway);
    await c.run('  echo hi  ');
    expect(gateway.commands.last, (command: 'echo hi', profile: 'work'));
    expect(c.lastResult?.stdout, 'ok\n');
    expect(c.lastResult?.exitCode, 0);
  });

  test('a second command waits while one is in flight', () async {
    final gateway = FakeTerminalGateway()..hold = Completer<ShellExecResult>();
    final c = await _open(gateway);
    final first = c.run('sleep 1');
    expect(c.busy, isTrue);
    await c.run('echo two');
    expect(gateway.ran, ['sleep 1']);
    gateway.hold!.complete(
      const ShellExecResult(stdout: '', stderr: '', exitCode: 0),
    );
    await first;
    expect(c.busy, isFalse);
  });

  for (final (code, message) in [
    (4005, 'blocked: recursive delete. Use the agent for dangerous commands.'),
    (4004, 'empty command'),
    (5002, 'command timed out (30s)'),
  ]) {
    test('$code is shown verbatim and nothing else is sent', () async {
      final gateway = FakeTerminalGateway()
        ..handler = (_, _) => Future.error(ShellExecRefusal(code, message));
      final c = await _open(gateway);
      await c.run('rm -rf /');
      expect(c.refusal?.code, code);
      expect(c.refusal?.message, message);
      expect(c.lastResult, isNull);
      expect(gateway.ran, ['rm -rf /'], reason: 'no retry, no rewrite');
    });
  }

  test('an unknown failure is generic and carries no text', () async {
    final gateway = FakeTerminalGateway()
      ..handler = (_, _) => Future.error(StateError('secret-marker'));
    final c = await _open(gateway);
    await c.run('ls');
    expect(c.failed, isTrue);
    expect(c.refusal, isNull);
    expect(c.toString(), isNot(contains('secret-marker')));
  });

  group('input', () {
    test('empty and whitespace never reach the server', () async {
      final gateway = FakeTerminalGateway();
      final c = await _open(gateway);
      await c.run('   ');
      expect(c.inputProblem, ShellInputProblem.empty);
      expect(gateway.ran, isEmpty);
    });

    test('more than 4 096 characters is refused, 4 096 is accepted', () async {
      final gateway = FakeTerminalGateway();
      final c = await _open(gateway);
      await c.run('a' * 4097);
      expect(c.inputProblem, ShellInputProblem.tooLong);
      expect(gateway.ran, isEmpty);
      await c.run('a' * 4096);
      expect(gateway.ran.single.length, 4096);
      expect(c.inputProblem, isNull);
    });

    test('control characters are refused, a tab is allowed', () async {
      final gateway = FakeTerminalGateway();
      final c = await _open(gateway);
      for (final bad in ['a\nb', 'a\rb', 'a\x00b', 'a\x1bb', 'a\x7fb']) {
        await c.run(bad);
        expect(c.inputProblem, ShellInputProblem.controlCharacter, reason: bad);
      }
      expect(gateway.ran, isEmpty);
      await c.run('printf\t"x"');
      expect(gateway.ran, ['printf\t"x"']);
    });

    test('a pasted multi-line block is never run by itself', () async {
      final gateway = FakeTerminalGateway();
      final c = await _open(gateway);
      c.onPaste('ls\nrm -rf x\n');
      expect(gateway.ran, isEmpty);
      expect(c.pasted, 'ls rm -rf x');
    });

    test('paste of one line is not run either', () async {
      final gateway = FakeTerminalGateway();
      final c = await _open(gateway);
      c.onPaste('ls');
      expect(gateway.ran, isEmpty);
    });
  });

  group('history', () {
    test(
      'keeps the last 20 newest first, without consecutive repeats',
      () async {
        final gateway = FakeTerminalGateway();
        final c = await _open(gateway);
        for (var i = 0; i < 25; i++) {
          await c.run('cmd $i');
        }
        await c.run('cmd 24');
        expect(c.history.length, 20);
        expect(c.history.first, 'cmd 24');
        expect(c.history.last, 'cmd 5');
      },
    );

    test('refused input is not remembered', () async {
      final c = await _open(FakeTerminalGateway());
      await c.run('');
      await c.run('a\nb');
      expect(c.history, isEmpty);
    });

    test('dispose clears it', () async {
      final c = await _open(FakeTerminalGateway());
      await c.run('ls');
      c.dispose();
      expect(c.history, isEmpty);
      expect(c.lastResult, isNull);
    });

    test('a profile switch clears it and the shown result', () async {
      final gateway = FakeTerminalGateway();
      final c = await _open(gateway);
      await c.run('ls');
      c.switchProfile('other');
      expect(c.history, isEmpty);
      expect(c.lastResult, isNull);
      await c.run('pwd');
      expect(gateway.commands.last.profile, 'other');
    });

    test('a late answer after a profile switch is dropped', () async {
      final gateway = FakeTerminalGateway()
        ..hold = Completer<ShellExecResult>();
      final c = await _open(gateway);
      final pending = c.run('ls');
      c.switchProfile('other');
      gateway.hold!.complete(
        const ShellExecResult(stdout: 'stale', stderr: '', exitCode: 0),
      );
      await pending;
      expect(c.lastResult, isNull);
      expect(c.busy, isFalse);
    });

    test('recall walks back through the history', () async {
      final c = await _open(FakeTerminalGateway());
      await c.run('one');
      await c.run('two');
      expect(c.recallOlder(), 'two');
      expect(c.recallOlder(), 'one');
      expect(c.recallOlder(), 'one');
      expect(c.recallNewer(), 'two');
      expect(c.recallNewer(), '');
    });
  });

  group('availability', () {
    test('-32601 on the probe hides the terminal', () async {
      final gateway = _UnsupportedProbe();
      final c = TerminalPaneController(
        gateway: gateway,
        profile: 'p',
        appLockEnabled: () => true,
        verify: () async => true,
      );
      addTearDown(c.dispose);
      await c.open();
      expect(c.access, TerminalPaneAccess.unsupported);
      await c.run('ls');
      expect(gateway.ran, isEmpty);
    });

    test(
      'a probe that fails for any other reason is not proof of support',
      () async {
        for (final error in <Object>[
          const ShellExecFailure(),
          TimeoutException('slow'),
          StateError('connection dropped'),
        ]) {
          final gateway = _FailingProbe(error);
          final c = TerminalPaneController(
            gateway: gateway,
            profile: 'p',
            appLockEnabled: () => true,
            verify: () async => true,
          );
          addTearDown(c.dispose);
          await c.open();
          expect(c.access, TerminalPaneAccess.unreachable, reason: '$error');
          await c.run('ls');
          expect(gateway.ran, isEmpty, reason: 'nothing runs before support');
        }
      },
    );

    test('unlock again after an unreachable probe can become ready', () async {
      final gateway = _FailingProbe(const ShellExecFailure());
      final c = TerminalPaneController(
        gateway: gateway,
        profile: 'p',
        appLockEnabled: () => true,
        verify: () async => true,
      );
      addTearDown(c.dispose);
      await c.open();
      expect(c.access, TerminalPaneAccess.unreachable);
      gateway.error = null;
      await c.unlock();
      expect(c.access, TerminalPaneAccess.ready);
    });

    test('a read-only connection is unsupported without any request', () async {
      final gateway = FakeTerminalGateway(available: false);
      final c = await _open(gateway);
      expect(c.access, TerminalPaneAccess.unsupported);
      expect(gateway.commands, isEmpty);
    });

    test('the probe is the empty command and runs nothing', () async {
      final gateway = FakeTerminalGateway();
      await _open(gateway);
      expect(gateway.commands.map((c) => c.command), ['']);
    });

    test('listeners are notified when state changes', () async {
      final c = await _open(FakeTerminalGateway());
      var n = 0;
      c.addListener(() => n++);
      await c.run('ls');
      expect(n, greaterThanOrEqualTo(2));
    });
  });
}

class _FailingProbe extends FakeTerminalGateway {
  _FailingProbe(this.error);
  Object? error;

  @override
  Future<ShellExecResult> shellExec(String command, {required String profile}) {
    if (command.isEmpty && error != null) return Future.error(error!);
    return super.shellExec(command, profile: profile);
  }
}

class _UnsupportedProbe extends FakeTerminalGateway {
  @override
  Future<ShellExecResult> shellExec(String command, {required String profile}) {
    commands.add((command: command, profile: profile));
    return Future.error(const ShellExecUnsupported());
  }
}
