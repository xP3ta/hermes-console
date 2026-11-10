// What the controller adds for the flat list: one read of each screen for its
// row, answering a numbered question once, the agents this app launched, and
// the conversation read from the session file (found, followed, paged).
import 'dart:io';

import 'package:fake_async/fake_async.dart'; // ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_agents.dart';
import 'package:hermes_android/core/services/herdr_attention.dart';
import 'package:hermes_android/core/services/herdr_session_files.dart';
import 'package:hermes_android/core/services/herdr_status.dart';

import 'support/fake_herdr_server.dart';
import 'support/fake_session_files.dart';
import 'support/herdr_view_rig.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 2, 12);

HerdrAgentsController _controller(
  FakeAsync async,
  FakeHerdrServer server, {
  HerdrSessionFiles? files,
}) => HerdrAgentsController(
  run: server.call,
  store: MemoryHerdrStore(),
  now: () => _t0.add(async.elapsed),
  sessionFiles: files,
)..peekScreens = true;

int _readsOf(FakeHerdrServer server, String pane) => server.herdrCalls
    .map(shellWords)
    .where((w) => w[2] == 'read' && w[3] == pane)
    .length;

String _screen(String name) =>
    File('test/fixtures/herdr/$name').readAsStringSync();

void main() {
  group('the screens read for the list', () {
    test('one read per agent and state; a working one every 20 s', () {
      final server = FakeHerdrServer(
        agents: [
          FakeAgent('w1:p1', 'claude', HerdrAgentStatus.blocked),
          FakeAgent('w2:p1', 'codex', HerdrAgentStatus.working, workspace: 'b'),
          FakeAgent('w3:p1', 'hermes', HerdrAgentStatus.idle, workspace: 'c'),
        ],
      );
      fakeAsync((async) {
        final c = _controller(async, server)..setActive(true);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 60));
        expect(_readsOf(server, 'w1:p1'), 1);
        expect(_readsOf(server, 'w3:p1'), 1);
        expect(_readsOf(server, 'w2:p1'), inInclusiveRange(3, 4));
        // The blocked agent moves on: its state changed, one more read.
        server.agents[0].seq = 2;
        async.elapse(const Duration(seconds: 12));
        expect(_readsOf(server, 'w1:p1'), 2);
        c.dispose();
      });
    });

    test('rows get their question and their line from what was read', () {
      final server =
          FakeHerdrServer(
              agents: [
                FakeAgent('w1:p1', 'claude', HerdrAgentStatus.blocked),
                FakeAgent(
                  'w2:p1',
                  'codex',
                  HerdrAgentStatus.working,
                  workspace: 'b',
                ),
              ],
            )
            ..screens['w1:p1'] = _screen('screen_claude_approval_synthetic.txt')
            ..screens['w2:p1'] = _screen('screen_working_synthetic.txt');
      fakeAsync((async) {
        final c = _controller(async, server)..setActive(true);
        async.flushMicrotasks();
        final blocked = c.allRows.firstWhere((r) => r.paneId == 'w1:p1');
        final working = c.allRows.firstWhere((r) => r.paneId == 'w2:p1');
        expect(c.askFor(blocked)!.kind, HerdrAskKind.approval);
        expect(c.activityFor(blocked), 'rm -rf build/');
        expect(c.askFor(working), isNull);
        expect(c.activityFor(working), 'Editing auth.ts…');
        c.dispose();
      });
    });

    test('a controller nobody asked to peek reads no screens', () {
      final server = FakeHerdrServer(
        agents: [FakeAgent('w1:p1', 'claude', HerdrAgentStatus.blocked)],
      );
      fakeAsync((async) {
        final c = _controller(async, server)
          ..peekScreens = false
          ..setActive(true);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        expect(server.readCalls, 0);
        c.dispose();
      });
    });
  });

  group('answering a numbered question', () {
    FakeHerdrServer asking() => FakeHerdrServer(
      agents: [FakeAgent('w1:p1', 'claude', HerdrAgentStatus.blocked)],
    )..screens['w1:p1'] = _screen('screen_claude_question_synthetic.txt');

    test('the key of the number goes once; no second send while it is in '
        'flight or held', () {
      final server = asking()..sendKeysDelay = const Duration(seconds: 2);
      fakeAsync((async) {
        final c = _controller(async, server)..setActive(true);
        async.flushMicrotasks();
        final row = c.allRows.single;
        final ask = c.askFor(row)!;
        expect(ask.options, hasLength(3));

        bool? first;
        c.sendOption(row, ask, 2).then((v) => first = v);
        async.flushMicrotasks();
        expect(c.optionSendFor(row, ask)?.phase, HerdrOptionPhase.sending);
        var second = true;
        c.sendOption(row, ask, 1).then((v) => second = v);
        async.flushMicrotasks();
        expect(second, isFalse);

        async.elapse(const Duration(seconds: 3));
        expect(first, isTrue);
        expect(c.optionSendFor(row, ask)?.phase, HerdrOptionPhase.sent);
        expect(server.keysSent, [
          ['2'],
        ]);

        // Held: the same question is not answered twice.
        var third = true;
        c.sendOption(row, ask, 3).then((v) => third = v);
        async.elapse(const Duration(seconds: 3));
        expect(third, isFalse);
        expect(server.keysSent, hasLength(1));

        // The agent did not move on: after the hold it can be tried again.
        async.elapse(HerdrAgentsController.optionSentHold);
        expect(c.optionSendFor(row, ask), isNull);
        c.dispose();
      });
    });

    test('a refused key says so and can be sent again', () {
      final server = asking()..sendKeysFails = true;
      fakeAsync((async) {
        final c = _controller(async, server)..setActive(true);
        async.flushMicrotasks();
        final row = c.allRows.single;
        final ask = c.askFor(row)!;
        bool? sent;
        c.sendOption(row, ask, 1).then((v) => sent = v);
        async.flushMicrotasks();
        expect(sent, isFalse);
        expect(c.optionSendFor(row, ask)?.phase, HerdrOptionPhase.failed);

        server.sendKeysFails = false;
        c.sendOption(row, ask, 1).then((v) => sent = v);
        async.flushMicrotasks();
        expect(sent, isTrue);
        expect(c.optionSendFor(row, ask)?.phase, HerdrOptionPhase.sent);
        c.dispose();
      });
    });

    test('a number that is not among the options sends nothing', () {
      final server = asking();
      fakeAsync((async) {
        final c = _controller(async, server)..setActive(true);
        async.flushMicrotasks();
        final row = c.allRows.single;
        bool? sent;
        c.sendOption(row, c.askFor(row)!, 7).then((v) => sent = v);
        async.flushMicrotasks();
        expect(sent, isFalse);
        expect(server.keysSent, isEmpty);
        c.dispose();
      });
      expect(() => HerdrKey.digit(0), throwsA(isA<HerdrInputException>()));
      expect(HerdrKey.digit(9).wire, '9');
    });
  });

  test('only agents this app started count as launched from Console', () {
    final server = FakeHerdrServer(
      agents: [FakeAgent('w1:p1', 'claude', HerdrAgentStatus.idle)],
    );
    fakeAsync((async) {
      final c = _controller(async, server)..setActive(true);
      async.flushMicrotasks();
      c.createAgent(folder: '/srv/web', kind: 'claude');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 3));
      expect(c.createdPaneId, 'w4:p1');
      expect(c.launchedHere('w4:p1'), isTrue);
      expect(c.launchedHere('w1:p1'), isFalse);
      c.dispose();
    });
  });

  group('the conversation of the open agent', () {
    const cwd = '/home/demo/proyectos/app';
    const path = '/home/demo/.claude/projects/-home-demo-proyectos-app/s.jsonl';

    FakeHerdrServer claude({
      HerdrAgentStatus status = HerdrAgentStatus.idle,
      String agent = 'claude',
    }) =>
        FakeHerdrServer(agents: [FakeAgent('w1:p1', agent, status, cwd: cwd)]);

    FakeSessionFiles withFile({DateTime? modified}) => FakeSessionFiles()
      ..put(
        path,
        _screen('session_claude_synthetic.jsonl'),
        modified: modified ?? _t0,
      );

    test('found, shown and followed as the file grows', () {
      final server = claude();
      final files = withFile();
      fakeAsync((async) {
        final c = _controller(async, server, files: files)..setActive(true);
        async.flushMicrotasks();
        c.openDetail('w1:p1');
        async.flushMicrotasks();
        expect(c.transcriptPhase, HerdrTranscriptPhase.ready);
        expect(c.transcriptTurns, hasLength(6));
        expect(c.transcriptHasEarlier, isFalse);

        final reads = files.reads;
        async.elapse(const Duration(seconds: 3));
        // Nothing new in the file: nothing more is read.
        expect(files.reads, reads);

        files.append(
          path,
          '{"type":"assistant","uuid":"z","message":{"content":[{"type":"text","text":"More news"}]}}\n',
        );
        async.elapse(const Duration(seconds: 3));
        expect(c.transcriptTurns, hasLength(7));
        expect(c.transcriptTurns.last.text, 'More news');
        c.dispose();
      });
    });

    test('a line still being written is not parsed until it is whole', () {
      final server = claude();
      final files = withFile();
      fakeAsync((async) {
        final c = _controller(async, server, files: files)..setActive(true);
        async.flushMicrotasks();
        c.openDetail('w1:p1');
        async.flushMicrotasks();
        files.append(
          path,
          '{"type":"assistant","uuid":"z","message":{"content":',
        );
        async.elapse(const Duration(seconds: 3));
        expect(c.transcriptTurns, hasLength(6));
        files.append(path, '[{"type":"text","text":"Whole now"}]}}\n');
        async.elapse(const Duration(seconds: 3));
        expect(c.transcriptTurns.last.text, 'Whole now');
        c.dispose();
      });
    });

    test(
      'two agents of the same kind in a folder: the screen, not a guess',
      () {
        final server = FakeHerdrServer(
          agents: [
            FakeAgent('w1:p1', 'claude', HerdrAgentStatus.idle, cwd: cwd),
            FakeAgent(
              'w2:p1',
              'claude',
              HerdrAgentStatus.idle,
              cwd: cwd,
              workspace: 'b',
            ),
          ],
        );
        fakeAsync((async) {
          final c = _controller(async, server, files: withFile())
            ..setActive(true);
          async.flushMicrotasks();
          c.openDetail('w1:p1');
          async.flushMicrotasks();
          expect(c.transcriptPhase, HerdrTranscriptPhase.unavailable);
          expect(c.transcriptTurns, isEmpty);
          c.dispose();
        });
      },
    );

    test(
      'a working agent whose file has not moved for an hour: the screen',
      () {
        final server = claude(status: HerdrAgentStatus.working);
        fakeAsync((async) {
          final c = _controller(
            async,
            server,
            files: withFile(modified: _t0.subtract(const Duration(hours: 1))),
          )..setActive(true);
          async.flushMicrotasks();
          c.openDetail('w1:p1');
          async.flushMicrotasks();
          expect(c.transcriptPhase, HerdrTranscriptPhase.unavailable);
          c.dispose();
        });
      },
    );

    test(
      'an agent that keeps no such file, or no source: nothing looked for',
      () {
        final files = withFile();
        fakeAsync((async) {
          final c = _controller(async, claude(agent: 'hermes'), files: files)
            ..setActive(true);
          async.flushMicrotasks();
          c.openDetail('w1:p1');
          async.flushMicrotasks();
          expect(c.transcriptPhase, HerdrTranscriptPhase.off);
          expect(files.lists, 0);
          c.dispose();
        });
        fakeAsync((async) {
          final c = _controller(async, claude())..setActive(true);
          async.flushMicrotasks();
          c.openDetail('w1:p1');
          async.flushMicrotasks();
          expect(c.transcriptPhase, HerdrTranscriptPhase.off);
          c.dispose();
        });
      },
    );

    test('a long file: the end first, earlier messages on request', () {
      final big = StringBuffer();
      for (var i = 0; i < 3000; i++) {
        big.writeln(
          '{"type":"user","uuid":"u$i","message":{"content":"number $i ${'x' * 100}"}}',
        );
      }
      final files = FakeSessionFiles()
        ..put(path, big.toString(), modified: _t0);
      fakeAsync((async) {
        final c = _controller(async, claude(), files: files)..setActive(true);
        async.flushMicrotasks();
        c.openDetail('w1:p1');
        async.flushMicrotasks();
        expect(c.transcriptPhase, HerdrTranscriptPhase.ready);
        expect(c.transcriptHasEarlier, isTrue);
        expect(c.transcriptTurns.last.text, startsWith('number 2999'));
        c.loadEarlierTranscript();
        async.flushMicrotasks();
        expect(c.transcriptHasEarlier, isFalse);
        expect(c.transcriptTurns.last.text, startsWith('number 2999'));
        c.dispose();
      });
    });

    test(
      'a file that changed after the agent went quiet is someone else\'s',
      () {
        final files = withFile();
        fakeAsync((async) {
          final c = _controller(async, claude(), files: files)..setActive(true);
          async.flushMicrotasks();
          c.openDetail('w1:p1');
          async.flushMicrotasks();
          expect(c.transcriptPhase, HerdrTranscriptPhase.ready);
          // Quiet for over a minute and still its file: fine.
          async.elapse(const Duration(seconds: 80));
          expect(c.transcriptPhase, HerdrTranscriptPhase.ready);
          // Another session of the same tool in this folder writes the file.
          files.times[path] = _t0.add(const Duration(seconds: 80));
          async.elapse(const Duration(seconds: 60));
          expect(c.transcriptPhase, HerdrTranscriptPhase.unavailable);
          expect(c.transcriptTurns, isEmpty);
          c.dispose();
        });
      },
    );

    test('following a long session keeps memory and parsing bounded', () {
      final big = StringBuffer();
      for (var i = 0; i < 3000; i++) {
        big.writeln(
          '{"type":"user","uuid":"u$i","message":{"content":"number $i ${'x' * 100}"}}',
        );
      }
      final files = FakeSessionFiles()
        ..put(path, big.toString(), modified: _t0);
      fakeAsync((async) {
        final c = _controller(async, claude(), files: files)..setActive(true);
        async.flushMicrotasks();
        c.openDetail('w1:p1');
        async.flushMicrotasks();
        for (var round = 0; round < 6; round++) {
          final more = StringBuffer();
          for (var i = 0; i < 100; i++) {
            more.writeln(
              '{"type":"user","uuid":"t$round-$i","message":{"content":"tail $round-$i ${'y' * 100}"}}',
            );
          }
          files.append(path, more.toString());
          async.elapse(const Duration(seconds: 3));
          expect(
            c.transcriptBytes,
            lessThanOrEqualTo(HerdrAgentsController.transcriptWindow),
          );
        }
        expect(c.transcriptTurns.last.text, startsWith('tail 5-99'));
        expect(c.transcriptHasEarlier, isTrue);
        c.dispose();
      });
    });

    test('closing the agent forgets its conversation', () {
      fakeAsync((async) {
        final c = _controller(async, claude(), files: withFile())
          ..setActive(true);
        async.flushMicrotasks();
        c.openDetail('w1:p1');
        async.flushMicrotasks();
        expect(c.transcriptTurns, isNotEmpty);
        c.closeDetail();
        expect(c.transcriptTurns, isEmpty);
        expect(c.transcriptPhase, HerdrTranscriptPhase.off);
        c.dispose();
      });
    });
  });
}
