import 'package:fake_async/fake_async.dart'; // ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_harness.dart';
import 'package:hermes_android/core/services/herdr_status.dart';

import 'support/fake_herdr_server.dart';

void main() {
  group('the commands', () {
    test('are constants of the app: no part of them comes from the user', () {
      expect(sshHarnessLoginCommand, contains('command -v claude codex'));
      expect(sshHarnessLoginCommand, startsWith('"\${SHELL:-/bin/sh}" -lc '));
      for (final name in herdrHarnessNames) {
        expect(sshHarnessLoginCommand, contains(name));
        expect(sshHarnessFolderCommand, contains(name));
      }
      // Reads only: nothing that writes, runs a harness or leaves the box.
      for (final command in [sshHarnessLoginCommand, sshHarnessFolderCommand]) {
        for (final banned in [
          '--version',
          'rm ',
          'curl',
          '>',
          'sudo',
          'eval',
          'install',
          'mkdir',
        ]) {
          expect(command, isNot(contains(banned)), reason: banned);
        }
      }
      // The folder look runs under plain sh, whatever the user's shell is.
      expect(sshHarnessFolderCommand, startsWith("/bin/sh -c '"));
    });

    test('the seven names are the ones Herdr 0.9.5 knows', () {
      expect(herdrHarnessNames, [
        'claude',
        'codex',
        'hermes',
        'opencode',
        'gemini',
        'pi',
        'copilot',
      ]);
    });
  });

  group('parsing', () {
    test('by the file name of each absolute path, not by exit status', () {
      final found = parseHerdrHarnessOutput(
        '/home/demo/.local/bin/claude\n'
        '/usr/local/bin/codex\n'
        '/opt/x/hermes\n'
        '/home/demo/.local/bin/opencode\n',
      );
      expect(found.keys, ['claude', 'codex', 'hermes', 'opencode']);
      expect(found['codex'], '/usr/local/bin/codex');
    });

    test('a banner, an alias or a function name is not a harness', () {
      final found = parseHerdrHarnessOutput(
        'Welcome back\n'
        "alias claude='x'\n"
        'pi\n'
        '/home/demo/bin/not-gemini\n'
        '/home/demo/bin/gemini extra\n'
        '/home/demo/.local/bin/gemini\n'
        '${'/a' * 300}/copilot\n',
      );
      expect(found.keys, ['gemini']);
    });

    test('the first path of a name wins', () {
      final found = parseHerdrHarnessOutput('/a/pi\n/b/pi\n');
      expect(found['pi'], '/a/pi');
    });
  });

  group('detecting', () {
    test('some installed, some not: the report says which', () async {
      final server = FakeHerdrServer()..harnesses = {'claude', 'codex'};
      final detector = HerdrHarnessDetector();
      final report = await detector.detect('srv', server.call);
      expect(report.failed, isFalse);
      expect(report.installed.keys, ['claude', 'codex']);
      expect(report.isInstalled('claude'), isTrue);
      expect(report.isInstalled('pi'), isFalse);
      expect(report.missing, ['hermes', 'opencode', 'gemini', 'pi', 'copilot']);
      // Both constant commands, nothing else.
      expect(server.commands.toSet(), {
        sshHarnessLoginCommand,
        sshHarnessFolderCommand,
      });
    });

    test('none installed is an answer, not a failure', () async {
      final server = FakeHerdrServer()..harnesses = {};
      final report = await HerdrHarnessDetector().detect('srv', server.call);
      expect(report.failed, isFalse);
      expect(report.installed, isEmpty);
      expect(report.isInstalled('claude'), isFalse);
    });

    test(
      'a server that does not answer: all offered, nothing cached',
      () async {
        final server = FakeHerdrServer()..harnessFails = true;
        final detector = HerdrHarnessDetector();
        final report = await detector.detect('srv', server.call);
        expect(report.failed, isTrue);
        expect(report.isInstalled('pi'), isTrue);
        expect(report.missing, isEmpty);
        expect(detector.fresh('srv'), isNull);

        server.harnessFails = false;
        final again = await detector.detect('srv', server.call);
        expect(again.failed, isFalse);
      },
    );

    test(
      'one command failing is not the end: the other still counts',
      () async {
        final report = await HerdrHarnessDetector().detect('srv', (
          command,
        ) async {
          if (command == sshHarnessLoginCommand) throw StateError('no');
          return const SshRemoteResult(
            stdout: '/home/demo/.bun/bin/gemini\n',
            exitCode: 0,
          );
        });
        expect(report.failed, isFalse);
        expect(report.installed.keys, ['gemini']);
      },
    );

    test('cached per server for the TTL, with a way to force a look', () {
      fakeAsync((async) {
        final server = FakeHerdrServer();
        var clock = DateTime(2026, 11, 2, 10);
        final detector = HerdrHarnessDetector(
          ttl: const Duration(minutes: 5),
          now: () => clock.add(async.elapsed),
        );
        detector.detect('a', server.call);
        async.flushMicrotasks();
        expect(server.commands.length, 2);

        detector.detect('a', server.call);
        async.flushMicrotasks();
        expect(server.commands.length, 2, reason: 'from the cache');

        // Another server has its own entry.
        detector.detect('b', server.call);
        async.flushMicrotasks();
        expect(server.commands.length, 4);

        // Refresh button: asks again at once.
        detector.detect('a', server.call, force: true);
        async.flushMicrotasks();
        expect(server.commands.length, 6);

        async.elapse(const Duration(minutes: 6));
        expect(detector.fresh('a'), isNull);
        detector.detect('a', server.call);
        async.flushMicrotasks();
        expect(server.commands.length, 8);
        clock = clock.add(const Duration(seconds: 1));
      });
    });

    test('two looks at once share one', () {
      fakeAsync((async) {
        final server = FakeHerdrServer();
        final detector = HerdrHarnessDetector();
        detector.detect('a', server.call);
        detector.detect('a', server.call);
        async.flushMicrotasks();
        expect(server.commands.length, 2);
      });
    });
  });
}
