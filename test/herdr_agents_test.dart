import 'dart:async';
import 'dart:io';

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_agents.dart';
import 'package:hermes_android/core/services/herdr_status.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_herdr_server.dart';

class _MemoryStore implements HerdrAgentsStore {
  bool dismissed = false;
  final List<String> remembered = [];
  String? kind;

  @override
  bool get hintDismissed => dismissed;

  @override
  Future<void> dismissHint() async => dismissed = true;

  @override
  List<String> get folders => remembered;

  @override
  Future<void> rememberFolder(String folder) async {
    remembered
      ..remove(folder)
      ..insert(0, folder);
  }

  final List<String> pinned = [];

  @override
  List<String> get favorites => pinned;

  @override
  Future<void> toggleFavorite(String folder) async {
    if (!pinned.remove(folder)) pinned.add(folder);
  }

  @override
  String? get lastKind => kind;

  @override
  Future<void> setLastKind(String value) async => kind = value;
}

FakeHerdrServer _server({bool installed = true}) => FakeHerdrServer(
  installed: installed,
  agents: [
    FakeAgent('w1:p1', 'claude', HerdrAgentStatus.working, name: 'reviewer'),
    FakeAgent('w1:p2', 'codex', HerdrAgentStatus.blocked, seq: 2),
    FakeAgent('w2:p1', 'hermes', HerdrAgentStatus.idle, workspace: 'logs'),
  ],
);

void main() {
  group('quoting and the whitelist', () {
    test('herdrShellQuote closes, escapes and reopens a single quote', () {
      expect(herdrShellQuote('plain'), "'plain'");
      expect(herdrShellQuote("it's"), r"'it'\''s'");
      expect(herdrShellQuote(''), "''");
    });

    final hostile = <String>[
      "it's",
      r'$(rm -rf /)',
      '`id`',
      'a; b && c | d',
      'line one\nline two',
      '"double" and \\ backslash',
      "'; touch /tmp/x; '",
      r'${HOME} $HOME',
      'ñandú 日本語',
    ];
    for (final text in hostile) {
      test('a prompt of ${text.length} chars reaches Herdr as one word', () {
        final line = HerdrCommand.prompt(
          'w1:p1',
          text,
        ).render(herdr: fakeHerdrPath);
        // shellWords throws on any unquoted shell syntax, so parsing proves
        // there is none; the last word must be the text itself.
        expect(shellWords(line), [
          fakeHerdrPath,
          'agent',
          'prompt',
          'w1:p1',
          text.trim(),
        ]);
      });
    }

    test('a prompt that starts with a dash cannot be read as a flag', () {
      final words = shellWords(
        HerdrCommand.prompt('w1:p1', '--wait now').render(herdr: fakeHerdrPath),
      );
      expect(words.last, ' --wait now');
    });

    test('prompts are refused when empty, huge or with control chars', () {
      void refused(String text, HerdrInputProblem problem) {
        expect(
          () => HerdrCommand.prompt('w1:p1', text),
          throwsA(
            isA<HerdrInputException>().having(
              (e) => e.problem,
              'problem',
              problem,
            ),
          ),
        );
      }

      refused('   \n ', HerdrInputProblem.empty);
      refused('a' * (herdrPromptMaxBytes + 1), HerdrInputProblem.tooLong);
      // Multi-byte text counts in bytes, not characters.
      refused('ñ' * (herdrPromptMaxBytes ~/ 2 + 1), HerdrInputProblem.tooLong);
      refused('nul\x00byte', HerdrInputProblem.badChars);
      refused('esc\x1b[31m', HerdrInputProblem.badChars);
      refused('bell\x07', HerdrInputProblem.badChars);
      refused('del\x7f', HerdrInputProblem.badChars);
      expect(
        () => HerdrCommand.prompt('w1:p1', 'a' * herdrPromptMaxBytes),
        returnsNormally,
      );
    });

    test('only the eight whitelisted subcommands can be built', () {
      // The six of the first cut, plus two read-only ones: `pane read` (what
      // a pane's shell said, for a start that failed) and `session list`.
      expect(HerdrCommand.allowedSubcommands, {
        'api snapshot',
        'agent read',
        'agent prompt',
        'agent send-keys',
        'agent start',
        'workspace create',
        'pane read',
        'session list',
      });
      final built = <HerdrCommand>[
        HerdrCommand.snapshot(),
        HerdrCommand.read('w1:p1'),
        HerdrCommand.prompt('w1:p1', 'hi'),
        HerdrCommand.sendKeys('w1:p1', [HerdrKey.enter]),
        HerdrCommand.workspaceCreate('/srv/app'),
        HerdrCommand.agentStart('claude', 'claude', 'w4:p1'),
      ];
      expect(built.map((c) => c.subcommand).toSet(), {
        'api snapshot',
        'agent read',
        'agent prompt',
        'agent send-keys',
        'agent start',
        'workspace create',
      });
      for (final command in built) {
        final line = command.render(herdr: fakeHerdrPath);
        final words = shellWords(line);
        // Nothing that closes, kills, installs or runs a shell line.
        for (final banned in [
          'pane',
          'run',
          'send-text',
          'integration',
          'server',
          'update',
          'machine',
          'plugin',
          'send-input',
        ]) {
          expect(words.skip(1).take(2), isNot(contains(banned)));
        }
        expect(words.first, fakeHerdrPath);
      }
    });

    test('the two read-only additions are fixed, validated and harmless', () {
      final read = HerdrCommand.paneRead('w4:p1');
      final sessions = HerdrCommand.sessionList();
      expect(read.isWrite, isFalse);
      expect(sessions.isWrite, isFalse);
      expect(shellWords(read.render(herdr: fakeHerdrPath)).sublist(1), [
        'pane',
        'read',
        'w4:p1',
        '--source',
        'recent',
        '--lines',
        '20',
      ]);
      expect(shellWords(sessions.render(herdr: fakeHerdrPath)).sublist(1), [
        'session',
        'list',
        '--json',
      ]);
      // Reads can go by name, in the login shell, with plain words only.
      expect(sessions.render(), sshInLoginShell('herdr session list --json'));
      // Never any of the verbs that act on panes, sessions or the server.
      for (final command in [read, sessions]) {
        final words = shellWords(command.render(herdr: fakeHerdrPath));
        for (final banned in [
          'close',
          'run',
          'send-text',
          'send-keys',
          'stop',
          'delete',
          'kill',
          'attach',
          'focus',
        ]) {
          expect(words.skip(1), isNot(contains(banned)), reason: banned);
        }
      }
      // The pane id is validated, and the lines are bounded.
      for (final id in ['w1:p1; ls', r'$(id)', 'w1', '../p']) {
        expect(
          () => HerdrCommand.paneRead(id),
          throwsA(isA<HerdrInputException>()),
          reason: id,
        );
      }
      expect(
        shellWords(
          HerdrCommand.paneRead(
            'w1:p1',
            lines: 9999,
          ).render(herdr: fakeHerdrPath),
        ).last,
        '40',
      );
    });

    test('writes need the resolved absolute path; reads can go by name', () {
      expect(
        () => HerdrCommand.prompt('w1:p1', 'hi').render(),
        throwsA(isA<HerdrInputException>()),
      );
      expect(
        () => HerdrCommand.workspaceCreate('/srv/app').render(),
        throwsA(isA<HerdrInputException>()),
      );
      for (final path in ['herdr', 'bin/herdr', "/tmp/it's/herdr", '/a b/h']) {
        expect(
          () => HerdrCommand.snapshot().render(herdr: path),
          throwsA(isA<HerdrInputException>()),
          reason: path,
        );
      }
      expect(
        HerdrCommand.read('w1:p1').render(),
        sshInLoginShell('herdr agent read w1:p1 --source visible'),
      );
    });

    test('pane ids, names and kinds are checked before they are used', () {
      for (final id in ['w1:p1; ls', 'w1', r'$(id)', '../p1', 'w1:p1 w1:p2']) {
        expect(
          () => HerdrCommand.read(id),
          throwsA(isA<HerdrInputException>()),
          reason: id,
        );
      }
      expect(
        () => HerdrCommand.agentStart('Bad Name', 'claude', 'w4:p1'),
        throwsA(isA<HerdrInputException>()),
      );
      expect(
        () => HerdrCommand.agentStart('x' * 33, 'claude', 'w4:p1'),
        throwsA(isA<HerdrInputException>()),
      );
      expect(
        () => HerdrCommand.agentStart('ok', 'rm -rf', 'w4:p1'),
        throwsA(isA<HerdrInputException>()),
      );
      expect(
        () => HerdrCommand.sendKeys('w1:p1', const []),
        throwsA(isA<HerdrInputException>()),
      );
    });

    test('folders: absolute only, quoted, labelled by their name', () {
      expect(herdrFolder(' /srv/app/ '), '/srv/app');
      expect(herdrFolder('/'), '/');
      for (final bad in ['', 'app', '~/app', '../x', '/a\nb', '/a\x00b']) {
        expect(
          () => herdrFolder(bad),
          throwsA(isA<HerdrInputException>()),
          reason: bad,
        );
      }
      final words = shellWords(
        HerdrCommand.workspaceCreate(
          "/srv/my app's dir",
        ).render(herdr: fakeHerdrPath),
      );
      expect(words, [
        fakeHerdrPath,
        'workspace',
        'create',
        '--cwd',
        "/srv/my app's dir",
        '--label',
        'my app-s dir',
        '--no-focus',
      ]);
      expect(herdrLabelFor('/srv/-rf'), 'rf');
      expect(herdrLabelFor('/'), 'agent');
    });

    test('read lines are bounded', () {
      expect(
        HerdrCommand.read('w1:p1', lines: 100000).words.last,
        '$herdrReadMaxLines',
      );
      expect(HerdrCommand.read('w1:p1', lines: 0).words.last, '1');
    });
  });

  group('parsing', () {
    test('the screen loses escape sequences and keeps its text', () {
      final text = parseHerdrReadOutput(
        SshRemoteResult(stdout: _ansi, exitCode: 0),
      );
      expect(text, contains('Reading lib/main.dart'));
      expect(text, contains('Do you want to run `flutter test`?'));
      expect(text, isNot(contains('\x1b')));
      expect(text, isNot(contains('\r')));
      expect(text.endsWith('\n'), isFalse);
    });

    test('a long screen keeps its end', () {
      final text = herdrCleanScreen('${'x' * 40000}\nTAIL');
      expect(text.length, herdrScreenMaxChars);
      expect(text.endsWith('TAIL'), isTrue);
    });

    test('workspace create gives the root pane', () {
      final created = parseHerdrCreated(
        SshRemoteResult(stdout: _createFixture, exitCode: 0),
      );
      expect(created.paneId, 'w4:p1');
      expect(created.workspaceId, 'w4');
      expect(
        () => parseHerdrCreated(
          const SshRemoteResult(stdout: '{"result":{}}', exitCode: 0),
        ),
        throwsFormatException,
      );
      expect(
        () => parseHerdrCreated(
          const SshRemoteResult(
            stdout: '{"result":{"root_pane":{"pane_id":"x; ls"}}}',
            exitCode: 0,
          ),
        ),
        throwsFormatException,
      );
    });

    test('Herdr errors become HerdrError, other failures FormatException', () {
      expect(
        herdrErrorOf(
          const SshRemoteResult(
            stdout: '',
            stderr: '{"error":{"code":"agent_blocked","message":"x"}}',
            exitCode: 1,
          ),
        )?.code,
        HerdrErrorCodes.agentBlocked,
      );
      expect(
        herdrErrorOf(
          const SshRemoteResult(stdout: '', stderr: 'oops', exitCode: 1),
        ),
        isNull,
      );
      expect(
        () => herdrExpectOk(
          const SshRemoteResult(stdout: '', stderr: 'usage', exitCode: 2),
        ),
        throwsFormatException,
      );
    });
  });

  group('list, order and time in state', () {
    test('blocked first, then working, then the rest; filters', () {
      final server = _server();
      final snapshot = HerdrSnapshot.fromJson(
        server.snapshotJson()['snapshot']! as Map<String, Object?>,
      );
      final rows = herdrAgentRows(snapshot);
      expect(rows.map((r) => r.paneId), ['w1:p2', 'w1:p1', 'w2:p1']);
      expect(rows.map((r) => r.title), ['codex', 'reviewer', 'hermes']);
      expect(rows.map((r) => r.workspaceLabel), ['app', 'app', 'logs']);
      // The plain shell pane is not an agent.
      expect(snapshot.panes.map((p) => p.paneId), contains('w9:p1'));
      expect(rows.map((r) => r.paneId), isNot(contains('w9:p1')));
      expect(
        herdrAgentRows(snapshot, filter: HerdrStatusFilter.blocked).length,
        1,
      );
      expect(
        herdrAgentRows(
          snapshot,
          filter: HerdrStatusFilter.working,
        ).single.paneId,
        'w1:p1',
      );
      expect(
        herdrAgentRows(snapshot, filter: HerdrStatusFilter.idle).single.paneId,
        'w2:p1',
      );
    });

    test('the state clock counts from the change it saw', () {
      final clock = HerdrStateClock();
      final server = _server();
      HerdrSnapshot snap() => HerdrSnapshot.fromJson(
        server.snapshotJson()['snapshot']! as Map<String, Object?>,
      );
      final t0 = DateTime(2026, 11, 2, 10);
      expect(clock.observe(snap().panes, t0), isEmpty);
      expect(
        clock.inState('w1:p1', t0.add(const Duration(minutes: 3))),
        const Duration(minutes: 3),
      );
      // The working agent now waits on you: that one is announced.
      server.agents[0].status = HerdrAgentStatus.blocked;
      final t1 = t0.add(const Duration(minutes: 5));
      expect(clock.observe(snap().panes, t1), {'w1:p1'});
      expect(
        clock.inState('w1:p1', t1.add(const Duration(seconds: 20))),
        const Duration(seconds: 20),
      );
      // The one that was blocked all along is not announced again.
      expect(
        clock.observe(snap().panes, t1.add(const Duration(seconds: 3))),
        isEmpty,
      );
      // A new sequence number restarts the count even in the same state.
      server.agents[0].seq = 7;
      final t2 = t1.add(const Duration(minutes: 1));
      clock.observe(snap().panes, t2);
      expect(
        clock.inState('w1:p1', t2.add(const Duration(seconds: 1))),
        const Duration(seconds: 1),
      );
      expect(clock.inState('w7:p7', t2), isNull);
    });

    test(
      'delays: quick when busy, slower when still, backing off on errors',
      () {
        expect(herdrListDelay(busy: true, failures: 0).inSeconds, 3);
        expect(herdrListDelay(busy: false, failures: 0).inSeconds, 10);
        expect(
          herdrListDelay(busy: false, failures: 0, starting: true).inSeconds,
          1,
        );
        expect(
          [for (var f = 1; f <= 5; f++) herdrListDelay(busy: true, failures: f)]
              .map((d) => d.inSeconds),
          [15, 30, 60, 60, 60],
        );
        int read(HerdrAgentStatus s, int unchanged, [int failures = 0]) =>
            herdrReadDelay(
              status: s,
              unchanged: unchanged,
              failures: failures,
            ).inSeconds;
        expect(read(HerdrAgentStatus.working, 0), 1);
        expect(read(HerdrAgentStatus.working, 2), 1);
        expect(read(HerdrAgentStatus.working, 3), 2);
        expect(read(HerdrAgentStatus.working, 8), 4);
        expect(read(HerdrAgentStatus.idle, 0), 2);
        expect(read(HerdrAgentStatus.idle, 3), 4);
        expect(read(HerdrAgentStatus.idle, 6), 8);
        expect(
          herdrReadDelay(
            status: HerdrAgentStatus.idle,
            unchanged: 9,
            failures: 0,
            boosted: true,
          ).inMilliseconds,
          700,
        );
        expect(
          [for (var f = 1; f <= 5; f++) read(HerdrAgentStatus.idle, 0, f)],
          [4, 8, 16, 30, 30],
        );
      },
    );
  });

  group('the controller against a fake server', () {
    late FakeHerdrServer server;
    late _MemoryStore store;
    late DateTime now;

    HerdrAgentsController make({Duration startRetry = Duration.zero}) =>
        HerdrAgentsController(
          run: server.call,
          store: store,
          now: () => now,
          startRetry: startRetry,
        );

    setUp(() {
      server = _server();
      store = _MemoryStore();
      now = DateTime(2026, 11, 2, 10);
    });

    test('Herdr not installed: says so, runs nothing else, can recheck', () {
      fakeAsync((async) {
        server.installed = false;
        final c = make()..setActive(true);
        async.flushMicrotasks();

        expect(c.phase, HerdrAgentsPhase.notInstalled);
        expect(c.rows, isEmpty);
        // Only the two read-only looks; nothing was installed or run.
        expect(server.commands, [
          sshHerdrProbeCommand,
          sshHerdrFallbackProbeCommand,
        ]);
        async.elapse(const Duration(minutes: 5));
        expect(server.commands.length, 2);

        server.installed = true;
        unawaited(c.recheck());
        async.flushMicrotasks();
        expect(c.phase, HerdrAgentsPhase.ready);
        expect(c.canWrite, isTrue);
        c.dispose();
      });
    });

    test('found only by the folder look still counts as installed', () {
      fakeAsync((async) {
        server.onlyInFolders = true;
        final c = make()..setActive(true);
        async.flushMicrotasks();
        expect(c.phase, HerdrAgentsPhase.ready);
        expect(c.canWrite, isTrue);
        c.dispose();
      });
    });

    test('the hint is remembered once dismissed', () async {
      server.installed = false;
      final c = make();
      expect(c.hintDismissed, isFalse);
      await c.dismissHint();
      expect(c.hintDismissed, isTrue);
      expect(store.dismissed, isTrue);
      c.dispose();
    });

    test('installed with no agents: ready and empty', () {
      fakeAsync((async) {
        server.agents.clear();
        final c = make()..setActive(true);
        async.flushMicrotasks();
        expect(c.phase, HerdrAgentsPhase.ready);
        expect(c.allRows, isEmpty);
        expect(c.needsYou, 0);
        c.dispose();
      });
    });

    test('working, blocked and idle agents, blocked first', () {
      fakeAsync((async) {
        final c = make()..setActive(true);
        async.flushMicrotasks();
        expect(c.phase, HerdrAgentsPhase.ready);
        expect(c.rows.map((r) => r.status), [
          HerdrAgentStatus.blocked,
          HerdrAgentStatus.working,
          HerdrAgentStatus.idle,
        ]);
        expect(c.needsYou, 1);
        c.setFilter(HerdrStatusFilter.working);
        expect(c.rows.single.title, 'reviewer');
        c.dispose();
      });
    });

    test('no Herdr server running: its own state, polled slowly', () {
      fakeAsync((async) {
        server.serverRunning = false;
        final c = make()..setActive(true);
        async.flushMicrotasks();
        expect(c.phase, HerdrAgentsPhase.serverStopped);
        expect(c.snapshot, isNull);
        server.serverRunning = true;
        async.elapse(const Duration(seconds: 16));
        expect(c.phase, HerdrAgentsPhase.ready);
        c.dispose();
      });
    });

    test('a connection error and a timeout are told apart', () {
      fakeAsync((async) {
        server.failWith = StateError('socket closed');
        final c = make()..setActive(true);
        async.flushMicrotasks();
        expect(c.phase, HerdrAgentsPhase.connectionError);
        c.dispose();

        server.failWith = TimeoutException('no answer');
        final d = make()..setActive(true);
        async.flushMicrotasks();
        expect(d.phase, HerdrAgentsPhase.timedOut);
        d.dispose();
      });
    });

    test('after an error it retries with 15, 30 then 60 s, and recovers', () {
      fakeAsync((async) {
        final c = make()..setActive(true);
        async.flushMicrotasks();
        expect(server.snapshotCalls, 1);

        server.failWith = StateError('down');
        // The next read (t=3) fails; the retries come 15, 30 and 60 s on.
        async.elapse(const Duration(seconds: 8));
        expect(server.commands.length, 3);
        expect(c.stale, isTrue);
        expect(c.rows, isNotEmpty);

        async.elapse(const Duration(seconds: 9));
        expect(server.commands.length, 3);
        async.elapse(const Duration(seconds: 2));
        expect(server.commands.length, 4);
        async.elapse(const Duration(seconds: 28));
        expect(server.commands.length, 4);
        async.elapse(const Duration(seconds: 2));
        expect(server.commands.length, 5);
        async.elapse(const Duration(seconds: 58));
        expect(server.commands.length, 5);
        async.elapse(const Duration(seconds: 3));
        expect(server.commands.length, 6);

        server.failWith = null;
        async.elapse(const Duration(seconds: 61));
        expect(server.commands.length, greaterThanOrEqualTo(7));
        expect(c.stale, isFalse);
        c.dispose();
      });
    });

    test(
      'adaptive refresh: 3 s with an agent busy, 10 s when all are idle',
      () {
        fakeAsync((async) {
          final c = make()..setActive(true);
          async.flushMicrotasks();
          final first = server.snapshotCalls;
          async.elapse(const Duration(seconds: 9));
          expect(server.snapshotCalls - first, 3);

          for (final agent in server.agents) {
            agent.status = HerdrAgentStatus.idle;
          }
          async.elapse(const Duration(seconds: 3));
          final idleFrom = server.snapshotCalls;
          async.elapse(const Duration(seconds: 30));
          expect(server.snapshotCalls - idleFrom, 3);
          c.dispose();
        });
      },
    );

    test('nothing runs while hidden or in the background', () {
      fakeAsync((async) {
        final c = make()..setActive(true);
        async.flushMicrotasks();
        c.setActive(false);
        final calls = server.commands.length;
        async.elapse(const Duration(minutes: 10));
        expect(server.commands.length, calls);

        c.setActive(true);
        async.flushMicrotasks();
        expect(server.commands.length, greaterThan(calls));
        c.dispose();
        final after = server.commands.length;
        async.elapse(const Duration(minutes: 10));
        expect(server.commands.length, after);
      });
    });

    test('a read that lands after a stop is dropped', () {
      fakeAsync((async) {
        final gate = Completer<SshRemoteResult>();
        var armed = false;
        final c = HerdrAgentsController(
          run: (command) {
            if (armed && command.contains("'snapshot'")) return gate.future;
            return server.call(command);
          },
          store: store,
          now: () => now,
        )..setActive(true);
        async.flushMicrotasks();
        armed = true;
        async.elapse(const Duration(seconds: 3));
        c.setActive(false);
        final before = c.snapshot;
        server.agents.clear();
        gate.complete(
          SshRemoteResult(
            stdout:
                '{"result":{"snapshot":{"workspaces":[],"panes":[],"agents":[]}}}',
            exitCode: 0,
          ),
        );
        async.flushMicrotasks();
        expect(c.snapshot, same(before));
        c.dispose();
      });
    });

    // A hide and show while a call is on the wire: the new run found it busy
    // and asked nothing, so the old call must hand over when it lands.
    test('a list read on the wire across a hide and show keeps polling', () {
      fakeAsync((async) {
        final gate = Completer<SshRemoteResult>();
        var armed = false;
        final c = HerdrAgentsController(
          run: (command) {
            if (armed && command.contains("'snapshot'")) {
              armed = false;
              return gate.future;
            }
            return server.call(command);
          },
          store: store,
          now: () => now,
        )..setActive(true);
        async.flushMicrotasks();
        armed = true;
        async.elapse(const Duration(seconds: 3));
        expect(armed, isFalse, reason: 'the next read is on the wire');
        c.setActive(false);
        c.setActive(true);
        async.flushMicrotasks();
        final before = server.snapshotCalls;
        gate.complete(
          const SshRemoteResult(
            stdout:
                '{"result":{"snapshot":{"workspaces":[],"panes":[],"agents":[]}}}',
            exitCode: 0,
          ),
        );
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        expect(server.snapshotCalls, before + 1, reason: 'read again now');
        async.elapse(const Duration(seconds: 30));
        expect(server.snapshotCalls, greaterThan(before + 3));
        c.dispose();
      });
    });

    test('a probe on the wire across a hide and show still ends ready', () {
      fakeAsync((async) {
        final gate = Completer<SshRemoteResult>();
        var held = true;
        final c = HerdrAgentsController(
          run: (command) {
            if (held && command == sshHerdrProbeCommand) {
              held = false;
              return gate.future;
            }
            return server.call(command);
          },
          store: store,
          now: () => now,
        )..setActive(true);
        async.flushMicrotasks();
        expect(c.phase, HerdrAgentsPhase.probing);
        c.setActive(false);
        c.setActive(true);
        async.flushMicrotasks();
        gate.complete(
          const SshRemoteResult(stdout: '$fakeHerdrPath\n', exitCode: 0),
        );
        async.flushMicrotasks();
        expect(c.phase, HerdrAgentsPhase.ready);
        c.dispose();
      });
    });

    test('a screen read on the wire across a hide and show keeps reading', () {
      fakeAsync((async) {
        final gate = Completer<SshRemoteResult>();
        var armed = false;
        final c = HerdrAgentsController(
          run: (command) {
            if (armed && command.contains("'read'")) {
              armed = false;
              return gate.future;
            }
            return server.call(command);
          },
          store: store,
          now: () => now,
        )..setActive(true);
        async.flushMicrotasks();
        armed = true;
        c.openDetail('w1:p1');
        async.flushMicrotasks();
        expect(armed, isFalse, reason: 'the first read is on the wire');
        c.setActive(false);
        c.setActive(true);
        async.flushMicrotasks();
        final before = server.readCalls;
        gate.completeError(StateError('dropped'));
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        expect(server.readCalls, before + 1, reason: 'read again now');
        expect(c.detailLoaded, isTrue);
        c.dispose();
      });
    });

    test('another agent opened during a screen read is read too', () {
      fakeAsync((async) {
        final gate = Completer<SshRemoteResult>();
        var armed = false;
        final c = HerdrAgentsController(
          run: (command) {
            if (armed && command.contains("'read'")) {
              armed = false;
              return gate.future;
            }
            return server.call(command);
          },
          store: store,
          now: () => now,
        )..setActive(true);
        async.flushMicrotasks();
        armed = true;
        c.openDetail('w1:p1');
        async.flushMicrotasks();
        expect(armed, isFalse, reason: 'the first read is on the wire');
        c.openDetail('w1:p2');
        async.flushMicrotasks();
        final before = server.readCalls;
        gate.completeError(StateError('dropped'));
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        expect(server.readCalls, before + 1, reason: 'the new agent is read');
        expect(c.detailLoaded, isTrue);
        c.dispose();
      });
    });

    test('the open agent: reads its screen, slows down when still, stops', () {
      fakeAsync((async) {
        final c = make()..setActive(true);
        async.flushMicrotasks();
        c.openDetail('w1:p1');
        async.flushMicrotasks();
        expect(c.detailLoaded, isTrue);
        expect(c.detailText, contains('Reading lib/main.dart'));
        expect(c.detailText, isNot(contains('\x1b')));
        expect(server.readCalls, 1);

        // Working and changing: every second.
        server.screens['w1:p1'] = 'step 1';
        async.elapse(const Duration(seconds: 2));
        expect(c.detailText, 'step 1');
        server.screens['w1:p1'] = 'step 2';
        async.elapse(const Duration(seconds: 2));
        expect(c.detailText, 'step 2');

        // Same text again and again: the gaps grow (1 s, then 2, then 4).
        async.elapse(const Duration(seconds: 12));
        final settled = server.readCalls;
        async.elapse(const Duration(seconds: 30));
        expect(server.readCalls - settled, lessThanOrEqualTo(10));
        expect(server.readCalls - settled, greaterThanOrEqualTo(3));

        c.closeDetail();
        final after = server.readCalls;
        async.elapse(const Duration(minutes: 5));
        expect(server.readCalls, after);
        c.dispose();
      });
    });

    test('a failing read backs off and says so, then recovers', () {
      fakeAsync((async) {
        final c = make()..setActive(true);
        async.flushMicrotasks();
        c.openDetail('w1:p1');
        async.flushMicrotasks();
        server.failWith = StateError('down');
        async.elapse(const Duration(seconds: 3));
        expect(c.detailFailed, isTrue);
        server.failWith = null;
        async.elapse(const Duration(seconds: 40));
        expect(c.detailFailed, isFalse);
        c.dispose();
      });
    });

    test('a prompt goes to the pane asked and to no other', () {
      fakeAsync((async) {
        final c = make()..setActive(true);
        async.flushMicrotasks();
        server.commands.clear();
        HerdrActionResult? result;
        c.sendPrompt('w2:p1', "fix it; it's 'urgent'").then((r) => result = r);
        async.flushMicrotasks();
        expect(result, HerdrActionResult.ok);
        final sent = server.herdrCalls
            .map(shellWords)
            .where((w) => w[2] == 'prompt')
            .toList();
        expect(sent, [
          [fakeHerdrPath, 'agent', 'prompt', 'w2:p1', "fix it; it's 'urgent'"],
        ]);
        c.dispose();
      });
    });

    test('a blocked agent gets nothing and the app says why', () {
      fakeAsync((async) {
        final c = make()..setActive(true);
        async.flushMicrotasks();
        HerdrActionResult? result;
        c.sendPrompt('w1:p2', 'go on').then((r) => result = r);
        async.flushMicrotasks();
        expect(result, HerdrActionResult.agentBlocked);
        c.dispose();
      });
    });

    test('keys are sent by name; an unknown pane is not found', () {
      fakeAsync((async) {
        final c = make()..setActive(true);
        async.flushMicrotasks();
        server.commands.clear();
        final results = <HerdrActionResult>[];
        c.sendKey('w1:p2', HerdrKey.enter).then(results.add);
        c.sendKey('w1:p2', HerdrKey.esc).then(results.add);
        c.sendKey('w1:p2', HerdrKey.ctrlC).then(results.add);
        c.sendKey('w5:p5', HerdrKey.enter).then(results.add);
        async.flushMicrotasks();
        expect(results, [
          HerdrActionResult.ok,
          HerdrActionResult.ok,
          HerdrActionResult.ok,
          HerdrActionResult.notFound,
        ]);
        final keys = server.herdrCalls
            .map(shellWords)
            .where((w) => w[2] == 'send-keys')
            .map((w) => w.sublist(3))
            .toList();
        expect(keys, [
          ['w1:p2', 'enter'],
          ['w1:p2', 'esc'],
          ['w1:p2', 'ctrl+c'],
          ['w5:p5', 'enter'],
        ]);
        c.dispose();
      });
    });

    test('invalid input is refused without touching the server', () {
      fakeAsync((async) {
        final c = make()..setActive(true);
        async.flushMicrotasks();
        server.commands.clear();
        final results = <HerdrActionResult>[];
        c.sendPrompt('w1:p1', '   ').then(results.add);
        c.sendPrompt('w1:p1', 'a\x00b').then(results.add);
        c.sendPrompt('nope', 'hi').then(results.add);
        c.createAgent(folder: 'relative', kind: 'claude').then(results.add);
        c.createAgent(folder: '/srv/app', kind: 'rm').then(results.add);
        async.flushMicrotasks();
        expect(results, everyElement(HerdrActionResult.invalid));
        expect(server.commands, isEmpty);
        c.dispose();
      });
    });

    test('creating an agent: workspace, then start with a free name', () {
      fakeAsync((async) {
        final c = make()..setActive(true);
        async.flushMicrotasks();
        server.commands.clear();
        HerdrActionResult? result;
        c
            .createAgent(folder: '/srv/app/', kind: 'codex')
            .then((r) => result = r);
        async.flushMicrotasks();

        expect(result, HerdrActionResult.ok);
        final calls = server.herdrCalls.map(shellWords).toList();
        expect(calls[0].sublist(1), [
          'workspace',
          'create',
          '--cwd',
          '/srv/app',
          '--label',
          'app',
          '--no-focus',
        ]);
        // `codex` is taken (the unnamed codex agent has no name, so free).
        expect(calls[1].sublist(1), [
          'agent',
          'start',
          'codex',
          '--kind',
          'codex',
          '--pane',
          'w4:p1',
          '--timeout',
          '8000',
        ]);
        expect(c.createdPaneId, 'w4:p1');
        expect(store.remembered, ['/srv/app']);
        expect(store.kind, 'codex');
        c.dispose();
      });
    });

    test('a new agent never reuses the name of a live one', () {
      server.agents.add(
        FakeAgent('w3:p1', 'claude', HerdrAgentStatus.idle, name: 'claude'),
      );
      server.agents.add(
        FakeAgent('w3:p2', 'claude', HerdrAgentStatus.idle, name: 'claude-2'),
      );
      fakeAsync((async) {
        final c = make()..setActive(true);
        async.flushMicrotasks();
        expect(c.uniqueName('claude'), 'claude-3');
        expect(c.uniqueName('codex'), 'codex');
        c.dispose();
      });
    });

    test('Herdr only as an alias: the list works, writes are refused', () {
      fakeAsync((async) {
        final aliasServer = _server();
        final c = HerdrAgentsController(
          run: (command) async {
            if (command == sshHerdrProbeCommand) {
              return const SshRemoteResult(
                stdout: "alias herdr='x'\n",
                exitCode: 0,
              );
            }
            return aliasServer.call(command);
          },
          store: store,
          now: () => now,
        )..setActive(true);
        async.flushMicrotasks();
        expect(c.phase, HerdrAgentsPhase.ready);
        expect(c.canWrite, isFalse);
        HerdrActionResult? result;
        c.sendPrompt('w1:p1', 'hi').then((r) => result = r);
        async.flushMicrotasks();
        expect(result, HerdrActionResult.noPath);
        expect(
          aliasServer.commands.where((c) => c.contains('prompt')),
          isEmpty,
        );
        c.dispose();
      });
    });

    test(
      'folder suggestions: where agents run, then remembered ones',
      () async {
        store.remembered.addAll(['/srv/old', '/home/demo/proyectos/app']);
        final c = make();
        expect(c.folderSuggestions, ['/srv/old', '/home/demo/proyectos/app']);
        c.dispose();
      },
    );
  });

  group('per-server memory on the phone', () {
    test(
      'the hint, the folders and the kind are kept per connection',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final a = PrefsHerdrAgentsStore(prefs, 'conn-a');
        final b = PrefsHerdrAgentsStore(prefs, 'conn-b');

        expect(a.hintDismissed, isFalse);
        await a.dismissHint();
        expect(a.hintDismissed, isTrue);
        expect(b.hintDismissed, isFalse);
        // A new store over the same prefs (a restart) still knows.
        expect(PrefsHerdrAgentsStore(prefs, 'conn-a').hintDismissed, isTrue);

        for (var i = 0; i < 9; i++) {
          await a.rememberFolder('/srv/p$i');
        }
        await a.rememberFolder('/srv/p5');
        expect(a.folders.length, PrefsHerdrAgentsStore.maxFolders);
        expect(a.folders.first, '/srv/p5');
        expect(a.folders.where((f) => f == '/srv/p5').length, 1);
        expect(b.folders, isEmpty);

        await a.setLastKind('claude');
        expect(a.lastKind, 'claude');
        expect(b.lastKind, isNull);
      },
    );
  });
}

final String _ansi = _read('agent_read_ansi_synthetic.txt');
final String _createFixture = _read('workspace_create_synthetic.json');

String _read(String name) =>
    File('test/fixtures/herdr/$name').readAsStringSync();
