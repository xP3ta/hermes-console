import 'dart:async';
import 'dart:io';

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_status.dart';

/// Exact command lines sent to the server: Herdr's CLI in the login shell.
String _login(String command) => '"\${SHELL:-/bin/sh}" -lc \'$command\'';

/// Output captured from a real Herdr 0.9.5 server (paths anonymised).
final String _snapshotStdout = File(
  'test/fixtures/herdr/snapshot_0_9_5.json',
).readAsStringSync();
final String _notRunningStderr = File(
  'test/fixtures/herdr/server_not_running_0_9_5.json',
).readAsStringSync();

SshRemoteResult _ok() => SshRemoteResult(stdout: _snapshotStdout, exitCode: 0);
SshRemoteResult _notRunning() =>
    SshRemoteResult(stdout: '', stderr: _notRunningStderr, exitCode: 1);

void main() {
  group('parseHerdrSnapshotOutput (Herdr 0.9.5 output)', () {
    test('workspaces, panes, agents and their states', () {
      final snapshot = parseHerdrSnapshotOutput(_ok());

      expect(snapshot.version, '0.9.5');
      expect(snapshot.workspaces.map((w) => w.label), ['app', 'logs', 'real']);
      expect(snapshot.workspaces.map((w) => w.status), [
        HerdrAgentStatus.blocked,
        HerdrAgentStatus.done,
        HerdrAgentStatus.unknown,
      ]);
      expect(snapshot.workspaces.first.focused, isTrue);

      final panes = {for (final p in snapshot.panes) p.paneId: p};
      expect(panes.keys, ['w1:p1', 'w1:p2', 'w2:p1', 'w3:p1']);
      expect(panes['w1:p1']!.agent, 'claude');
      expect(panes['w1:p1']!.name, 'reviewer');
      expect(panes['w1:p1']!.status, HerdrAgentStatus.working);
      expect(panes['w1:p2']!.agent, 'codex');
      expect(panes['w1:p2']!.name, isNull);
      expect(panes['w1:p2']!.status, HerdrAgentStatus.blocked);
      expect(panes['w2:p1']!.status, HerdrAgentStatus.done);
      expect(panes['w3:p1']!.hasAgent, isFalse);
      expect(panes['w3:p1']!.status, HerdrAgentStatus.unknown);
      expect(panes['w3:p1']!.cwd, '/home/demo/proyectos/app');

      expect(snapshot.focusedPaneId, 'w1:p1');
      expect(snapshot.focusedPane!.name, 'reviewer');
      expect(snapshot.needsYou, 1);
    });

    test('Herdr error object on stderr becomes a HerdrError', () {
      expect(
        () => parseHerdrSnapshotOutput(_notRunning()),
        throwsA(
          isA<HerdrError>().having(
            (e) => e.code,
            'code',
            HerdrError.serverNotRunning,
          ),
        ),
      );
    });

    // Review P2-F5-3: a login profile that prints (motd, banners) before
    // Herdr's JSON must not turn the state into 'could not read'.
    test('text printed by the login profile before the JSON is skipped', () {
      final noisy = parseHerdrSnapshotOutput(
        SshRemoteResult(
          stdout: 'Welcome to demo-host\nLast login: today\n$_snapshotStdout',
          exitCode: 0,
        ),
      );
      expect(noisy.focusedPane!.name, 'reviewer');
      expect(
        () => parseHerdrSnapshotOutput(
          SshRemoteResult(
            stdout: '',
            stderr: 'motd line\n$_notRunningStderr',
            exitCode: 1,
          ),
        ),
        throwsA(isA<HerdrError>()),
      );
    });

    test('anything else is a FormatException', () {
      expect(
        () => parseHerdrSnapshotOutput(
          const SshRemoteResult(
            stdout: '',
            stderr: 'sh: 1: herdr: not found',
            exitCode: 127,
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => parseHerdrSnapshotOutput(
          const SshRemoteResult(stdout: '{"result":{}}', exitCode: 0),
        ),
        throwsFormatException,
      );
      expect(
        () => parseHerdrSnapshotOutput(
          const SshRemoteResult(stdout: 'not json', exitCode: 0),
        ),
        throwsFormatException,
      );
    });

    test('unknown states and missing fields degrade safely', () {
      final snapshot = HerdrSnapshot.fromJson({
        'workspaces': [
          {'workspace_id': 'w1', 'agent_status': 'sleeping'},
          {'label': 'no id'},
        ],
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'agent_status': 7},
          {'workspace_id': 'w1'},
        ],
      });
      expect(snapshot.workspaces, hasLength(1));
      expect(snapshot.workspaces.single.label, 'w1');
      expect(snapshot.workspaces.single.status, HerdrAgentStatus.unknown);
      expect(snapshot.panes.single.status, HerdrAgentStatus.unknown);
      expect(snapshot.focusedPane, isNull);
      expect(snapshot.needsYou, 0);
    });
  });

  test('focus command only for ids shaped like Herdr pane ids', () {
    expect(
      herdrFocusAgentCommand('w1:p2'),
      _login('herdr agent focus w1:p2'),
    );
    expect(
      herdrFocusAgentCommand('w12:p345'),
      _login('herdr agent focus w12:p345'),
    );
    for (final bad in [
      '',
      'w1',
      'w1:t1',
      'w1:p1; rm -rf ~',
      r'w1:p1$(id)',
      'w1:p1 --help',
      "w1:p1'",
      'w1:p1\n',
    ]) {
      expect(herdrFocusAgentCommand(bad), isNull, reason: bad);
    }
  });

  // Review R5A P2-B4-3: Herdr's path, resolved once by the launch probe,
  // runs as is; anything that is not a plain absolute path is not used.
  test('the probe gives a path only when it is a plain absolute one', () {
    expect(
      herdrPathFromProbe('/home/u/.local/bin/herdr\n'),
      '/home/u/.local/bin/herdr',
    );
    // A login profile may print first: the last line counts.
    expect(
      herdrPathFromProbe('Welcome!\n/usr/local/bin/herdr\n'),
      '/usr/local/bin/herdr',
    );
    for (final bad in [
      '',
      'herdr',
      'alias herdr=/opt/herdr',
      '/opt/my herdr',
      "/opt/herdr'; id",
      r'/opt/$(id)/herdr',
      '/opt/herdr\n; id',
    ]) {
      expect(herdrPathFromProbe(bad), isNull, reason: bad);
    }
  });

  test('with a path, Herdr runs directly, without a login shell', () {
    const path = '/home/u/.local/bin/herdr';
    expect(herdrSnapshotCommand(path), "'$path' api snapshot");
    expect(herdrSnapshotCommand(null), sshHerdrSnapshotCommand);
    expect(
      herdrFocusAgentCommand('w1:p2', herdr: path),
      "'$path' agent focus w1:p2",
    );
    expect(herdrFocusAgentCommand('w1:p1; id', herdr: path), isNull);
  });

  test('the snapshot command is a constant read', () {
    expect(sshHerdrSnapshotCommand, _login('herdr api snapshot'));
  });

  group('HerdrMonitor', () {
    test('reads at once, then every 5 s; nothing after stop', () {
      fakeAsync((async) {
        final calls = <String>[];
        final monitor = HerdrMonitor(
          run: (command) async {
            calls.add(command);
            return _ok();
          },
        );
        monitor.start();
        async.flushMicrotasks();
        expect(calls, [_login('herdr api snapshot')]);
        expect(monitor.view.value.snapshot!.needsYou, 1);

        async.elapse(const Duration(seconds: 5));
        expect(calls, hasLength(2));
        async.elapse(const Duration(seconds: 5));
        expect(calls, hasLength(3));

        monitor.stop();
        async.elapse(const Duration(minutes: 1));
        expect(calls, hasLength(3));
        expect(async.pendingTimers, isEmpty);
        monitor.dispose();
      });
    });

    test('server not running: clear state and back off to 15 s', () {
      fakeAsync((async) {
        var calls = 0;
        final monitor = HerdrMonitor(
          run: (_) async {
            calls++;
            return calls == 1 ? _ok() : _notRunning();
          },
        );
        monitor.start();
        async.elapse(const Duration(seconds: 5));
        expect(calls, 2);
        expect(monitor.view.value.notRunning, isTrue);
        expect(monitor.view.value.snapshot, isNull);

        async.elapse(const Duration(seconds: 14));
        expect(calls, 2);
        async.elapse(const Duration(seconds: 1));
        expect(calls, 3);
        monitor.dispose();
      });
    });

    test('a failed read keeps the last snapshot and marks it', () {
      fakeAsync((async) {
        var calls = 0;
        final monitor = HerdrMonitor(
          run: (_) async {
            calls++;
            if (calls == 1) return _ok();
            throw TimeoutException('slow');
          },
        );
        monitor.start();
        async.elapse(const Duration(seconds: 5));
        expect(monitor.view.value.failed, isTrue);
        expect(monitor.view.value.snapshot, isNotNull);
        monitor.dispose();
      });
    });

    test('never two reads at once; a late result after stop is dropped', () {
      fakeAsync((async) {
        final pending = <Completer<SshRemoteResult>>[];
        final monitor = HerdrMonitor(
          run: (_) {
            final c = Completer<SshRemoteResult>();
            pending.add(c);
            return c.future;
          },
        );
        monitor.start();
        async.flushMicrotasks();
        unawaited(monitor.refresh());
        async.elapse(const Duration(seconds: 30));
        expect(pending, hasLength(1));

        monitor.stop();
        pending.single.complete(_ok());
        async.flushMicrotasks();
        expect(monitor.view.value.snapshot, isNull);
        expect(async.pendingTimers, isEmpty);
        monitor.dispose();
      });
    });

    test('focusAgent runs the exact command, then reads again', () {
      fakeAsync((async) {
        final calls = <String>[];
        final monitor = HerdrMonitor(
          run: (command) async {
            calls.add(command);
            return command == sshHerdrSnapshotCommand
                ? _ok()
                : const SshRemoteResult(stdout: '{}', exitCode: 0);
          },
        );
        monitor.start();
        async.flushMicrotasks();

        bool? focused;
        monitor.focusAgent('w1:p2').then((ok) => focused = ok);
        async.flushMicrotasks();
        expect(focused, isTrue);
        expect(calls, [
          _login('herdr api snapshot'),
          _login('herdr agent focus w1:p2'),
          _login('herdr api snapshot'),
        ]);

        monitor.focusAgent('w1:p2; reboot').then((ok) => focused = ok);
        async.flushMicrotasks();
        expect(focused, isFalse);
        expect(calls, hasLength(3));
        monitor.dispose();
      });
    });
  });

  group('HerdrMonitor after review F4F5', () {
    // P1-F5-1: stop() and start() while a read is in flight used to leave
    // the monitor "running" with no timer and no read, forever.
    test('stop and start during a read keep polling', () {
      fakeAsync((async) {
        final pending = <Completer<SshRemoteResult>>[];
        final monitor = HerdrMonitor(
          run: (_) {
            final c = Completer<SshRemoteResult>();
            pending.add(c);
            return c.future;
          },
        );
        monitor.start();
        async.flushMicrotasks();
        expect(pending, hasLength(1));

        monitor.stop();
        monitor.start();
        async.flushMicrotasks();
        // start() found the old read busy: no second read yet.
        expect(pending, hasLength(1));

        pending.first.complete(_ok());
        async.elapse(const Duration(seconds: 5));
        expect(pending, hasLength(2), reason: 'polling resumed');
        expect(monitor.isRunning, isTrue);

        pending.last.complete(_ok());
        async.elapse(const Duration(seconds: 5));
        expect(pending, hasLength(3));
        monitor.dispose();
      });
    });

    // P1-F5-2: the monitor is the session's; it polls while any screen
    // that shows it holds it, and stops when the last lets go.
    test('polls while at least one holder is on screen', () {
      fakeAsync((async) {
        var reads = 0;
        final monitor = HerdrMonitor(
          run: (_) async {
            reads++;
            return _ok();
          },
        );
        monitor
          ..acquire()
          ..acquire();
        async.elapse(const Duration(seconds: 1));
        expect(reads, 1);

        monitor.release();
        async.elapse(const Duration(seconds: 10));
        expect(reads, 3, reason: 'the other holder still shows it');

        monitor.release();
        async.elapse(const Duration(minutes: 1));
        expect(reads, 3);
        expect(monitor.isRunning, isFalse);
        expect(async.pendingTimers, isEmpty);

        // Extra releases are harmless; a new holder starts again.
        monitor
          ..release()
          ..acquire();
        async.flushMicrotasks();
        expect(reads, 4);
        monitor.dispose();
      });
    });

    test('stop() (session ended) stops every holder at once', () {
      fakeAsync((async) {
        var reads = 0;
        final monitor = HerdrMonitor(
          run: (_) async {
            reads++;
            return _ok();
          },
        );
        monitor
          ..acquire()
          ..acquire()
          ..stop();
        async.elapse(const Duration(minutes: 1));
        expect(reads, 1);
        expect(monitor.isRunning, isFalse);
        monitor.dispose();
      });
    });
  });
}
