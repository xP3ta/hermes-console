// What a blocked agent's screen asks (numbered options, question or approval,
// the real order), the one line of a row, the readable terminal text, the
// flat list by folder, and the conversation read from session files.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_agents.dart';
import 'package:hermes_android/core/services/herdr_attention.dart';
import 'package:hermes_android/core/services/herdr_flat_list.dart';
import 'package:hermes_android/core/services/herdr_session_files.dart';
import 'package:hermes_android/core/services/herdr_status.dart';
import 'package:hermes_android/core/services/herdr_transcript.dart';

import 'support/fake_session_files.dart';

List<String> _fx(String name) =>
    File('test/fixtures/herdr/$name').readAsStringSync().split('\n');

String _fixture(String name) =>
    File('test/fixtures/herdr/$name').readAsStringSync();

HerdrAgentRow _row(
  String id,
  HerdrAgentStatus status, {
  String? cwd,
  String agent = 'claude',
  String? name,
}) => HerdrAgentRow(
  pane: HerdrPane(
    paneId: id,
    workspaceId: id.split(':').first,
    status: status,
    agent: agent,
    name: name ?? id,
    cwd: cwd,
  ),
  workspaceLabel: 'ws',
);

void main() {
  group('numbered options', () {
    test('1. and 1) and 1 - forms', () {
      expect(herdrNumberedOptions(['Pick one', '1. Alpha', '2. Beta']), [
        const HerdrOption(1, 'Alpha'),
        const HerdrOption(2, 'Beta'),
      ]);
      expect(
        herdrNumberedOptions([
          'Pick',
          '  1) Alpha',
          '  2) Beta',
        ]).map((o) => o.label),
        ['Alpha', 'Beta'],
      );
      expect(
        herdrNumberedOptions([
          'Pick',
          '1 - Alpha',
          '2 - Beta',
          '3 - Gamma',
        ]).map((o) => o.number),
        [1, 2, 3],
      );
    });

    test('the pointer and the frame of a dialog are not part of the text', () {
      final options = herdrNumberedOptions([
        '╭────────╮',
        '│ Sure? │',
        '│ ❯ 1. Yes │',
        '│   2. No │',
        '╰────────╯',
      ]);
      expect(options, [
        const HerdrOption(1, 'Yes'),
        const HerdrOption(2, 'No'),
      ]);
    });

    test('up to nine options; a tenth line is not one more', () {
      final nine = [for (var i = 1; i <= 9; i++) '$i. Option $i'];
      expect(herdrNumberedOptions(nine), hasLength(9));
      expect(herdrNumberedOptions([...nine, '10. Ten']), hasLength(9));
    });

    test('one option, one that does not start at 1, or gaps: no choice', () {
      expect(herdrNumberedOptions(['1. Only']), isEmpty);
      expect(herdrNumberedOptions(['2. Beta', '3. Gamma']), isEmpty);
      expect(herdrNumberedOptions(['1. Alpha', '3. Gamma']), isEmpty);
    });

    test('numbers inside a sentence are not options', () {
      expect(
        herdrNumberedOptions(['Disk: 1.5 GB free', 'version 2) is out']),
        isEmpty,
      );
    });

    test('a long numbered list in text is not a choice', () {
      expect(
        herdrNumberedOptions(_fx('screen_prose_list_synthetic.txt')),
        isEmpty,
      );
      // Long labels, even at the foot of the screen.
      final long = 'x' * 120;
      expect(herdrNumberedOptions(['Steps', '1. $long', '2. $long']), isEmpty);
      // A list followed by more than a few lines of text.
      expect(
        herdrNumberedOptions([
          '1. Alpha',
          '2. Beta',
          'and then some text',
          'more text',
          'still more',
          'and more',
        ]),
        isEmpty,
      );
    });
  });

  group('what a blocked agent asks', () {
    test('Claude question: options, question line, no invented order', () {
      final ask = herdrReadAsk(_fx('screen_claude_question_synthetic.txt'));
      expect(ask.kind, HerdrAskKind.question);
      expect(ask.options.map((o) => o.label), [
        'Pure unit tests',
        'Fake server',
        'Type something else',
      ]);
      expect(ask.question, 'Which approach do you prefer for the tests?');
      expect(ask.command, isNull);
    });

    test('Claude approval: an approval, with the real command', () {
      final ask = herdrReadAsk(_fx('screen_claude_approval_synthetic.txt'));
      expect(ask.kind, HerdrAskKind.approval);
      expect(ask.command, 'rm -rf build/');
      expect(ask.options, hasLength(3));
      expect(ask.options.first, const HerdrOption(1, 'Yes'));
      expect(ask.question, 'Do you want to proceed?');
    });

    test('Codex approval: the line after the dollar sign', () {
      final ask = herdrReadAsk(_fx('screen_codex_approval_synthetic.txt'));
      expect(ask.kind, HerdrAskKind.approval);
      expect(ask.command, 'rm -rf build/');
      expect(ask.options.map((o) => o.number), [1, 2, 3]);
    });

    test('numbered Yes/No with a command in backticks is an approval, not a '
        'question', () {
      final ask = herdrReadAsk(
        herdrCleanScreen(_fixture('agent_read_ansi_synthetic.txt')).split('\n'),
      );
      expect(ask.kind, HerdrAskKind.approval);
      expect(ask.command, 'flutter test');
      expect(ask.options, hasLength(2));
    });

    test('permission words in the question make an approval; in an option '
        'label alone they do not', () {
      expect(
        herdrReadAsk([
          'Do you trust the files in this folder?',
          '❯ 1. Yes, proceed',
          '  2. No, exit',
        ]).kind,
        HerdrAskKind.approval,
      );
      expect(
        herdrReadAsk([
          'Which list do you want?',
          '1. Allow list',
          '2. Deny list',
        ]).kind,
        HerdrAskKind.question,
      );
    });

    test('without options: y/n is an approval, anything else only waits', () {
      final approval = herdrReadAsk(['some output', 'Allow this edit? (y/n)']);
      expect(approval.kind, HerdrAskKind.approval);
      expect(approval.options, isEmpty);
      expect(approval.command, isNull);
      final waiting = herdrReadAsk(['Working on it', 'Press a key']);
      expect(waiting.kind, HerdrAskKind.waiting);
      expect(waiting.options, isEmpty);
      expect(herdrReadAsk(const []).kind, HerdrAskKind.waiting);
    });

    test('the signature tells two questions apart', () {
      final a = herdrReadAsk(['Sure?', '1. Yes', '2. No']);
      final same = herdrReadAsk(['Sure?', '1. Yes', '2. No']);
      final other = herdrReadAsk(['Sure?', '1. Yes', '2. Maybe']);
      expect(a.signature, same.signature);
      expect(a.signature, isNot(other.signature));
    });
  });

  group('the line of a row', () {
    test('a blocked agent says its command or its question', () {
      final approval = herdrReadAsk(
        _fx('screen_claude_approval_synthetic.txt'),
      );
      expect(herdrActivityLine(const [], ask: approval), 'rm -rf build/');
      final question = herdrReadAsk(
        _fx('screen_claude_question_synthetic.txt'),
      );
      expect(
        herdrActivityLine(const [], ask: question),
        'Which approach do you prefer for the tests?',
      );
    });

    test('a working agent: its last useful line, without bullets or hints', () {
      expect(
        herdrActivityLine(_fx('screen_working_synthetic.txt')),
        'Editing auth.ts…',
      );
    });

    test('an idle agent: its last message, not the prompt box or hints', () {
      expect(
        herdrActivityLine(_fx('screen_idle_synthetic.txt')),
        'Done. I added the tests for the session module and they pass.',
      );
    });

    test('nothing to say is null; long lines get an ellipsis', () {
      expect(herdrActivityLine(const []), isNull);
      expect(herdrActivityLine(['╭──╮', '│  │', '╰──╯']), isNull);
      final long = herdrActivityLine(['word ' * 80], max: 40)!;
      expect(long.length, 40);
      expect(long, endsWith('…'));
    });
  });

  group('the terminal as readable text', () {
    test('frames and rules drop out, text stays', () {
      expect(herdrReadableLines(['╭───╮', '│ hello │', '╰───╯']), ['hello']);
      expect(
        herdrReadableLines(_fx('screen_claude_approval_synthetic.txt')).join(),
        isNot(contains('│')),
      );
    });

    test('symbols the font lacks are written plainly; blank runs collapse', () {
      expect(herdrReadableLines(['⏵⏵ auto mode on (shift+tab to cycle)']), [
        '>> auto mode on (shift+tab to cycle)',
      ]);
      expect(herdrReadableLines(['a', '', '', '───', 'b', '']), ['a', '', 'b']);
      expect(herdrReadableLines(['  indented code', '']), ['  indented code']);
    });
  });

  group('folders and the flat list', () {
    test('short labels tell same-named folders apart', () {
      final labels = herdrFolderLabels([
        '/a/app',
        '/b/app',
        '/home/me',
        '/srv/web',
        '/',
      ]);
      expect(labels['/a/app'], 'a/app');
      expect(labels['/b/app'], 'b/app');
      expect(labels['/home/me'], '~');
      expect(labels['/srv/web'], 'web');
      expect(labels['/'], '/');
    });

    final rows = [
      _row('w1:p1', HerdrAgentStatus.working, cwd: '/a/app', name: 'worker'),
      _row('w2:p1', HerdrAgentStatus.blocked, cwd: '/b/web', name: 'asker'),
      _row('w1:p2', HerdrAgentStatus.idle, cwd: '/a/app', name: 'free'),
      _row('w3:p1', HerdrAgentStatus.done, cwd: '/c/x', name: 'finished'),
      _row('w4:p1', HerdrAgentStatus.idle, name: 'lost'),
    ];

    test('folders in the order of what needs attention; done apart', () {
      final flat = herdrFlatList(rows, unknownLabel: 'Unknown');
      expect(flat.groups.map((g) => g.folder.label), ['web', 'app', 'Unknown']);
      expect(flat.groups[1].rows.map((r) => r.paneId), ['w1:p1', 'w1:p2']);
      expect(flat.needsYou.map((r) => r.paneId), ['w2:p1']);
      expect(flat.done.map((r) => r.paneId), ['w3:p1']);
      expect(
        flat.groups.expand((g) => g.rows).map((r) => r.paneId),
        isNot(contains('w3:p1')),
      );
    });

    test('folder, state and search narrow it together', () {
      final app = herdrFlatList(
        rows,
        unknownLabel: 'Unknown',
        folder: '/a/app',
      );
      expect(app.groups.single.rows, hasLength(2));
      expect(app.needsYou, isEmpty);
      final working = herdrFlatList(
        rows,
        unknownLabel: 'Unknown',
        filter: HerdrStatusFilter.working,
      );
      expect(working.groups.single.rows.single.paneId, 'w1:p1');
      final found = herdrFlatList(rows, unknownLabel: 'Unknown', query: 'ASK');
      expect(found.needsYou.single.paneId, 'w2:p1');
      expect(
        herdrFlatList(rows, unknownLabel: 'Unknown', query: 'zzz').isEmpty,
        isTrue,
      );
    });
  });

  group('masking', () {
    test('what is named like a secret or shaped like one is hidden', () {
      expect(
        herdrMaskSecrets(
          'set API_KEY=sk-abcdefghijklmnopqrstuvwxyz0123456789 now',
        ),
        isNot(contains('sk-abcdefghijklmnop')),
      );
      expect(herdrMaskSecrets('password: hunter2'), contains('••••'));
      expect(herdrMaskSecrets('plain words stay'), 'plain words stay');
    });
  });

  group('the conversation of a Claude Code file', () {
    final turns = herdrParseClaude(_fx('session_claude_synthetic.jsonl'));

    test('messages, thinking, steps and a pending question, in order', () {
      expect(turns.map((t) => t.kind), [
        HerdrTurnKind.user,
        HerdrTurnKind.thinking,
        HerdrTurnKind.assistant,
        HerdrTurnKind.steps,
        HerdrTurnKind.assistant,
        HerdrTurnKind.question,
      ]);
      expect(turns.first.text, 'Add tests to the session module');
      expect(turns[2].text, contains('session.ts'));
    });

    test('tool calls are grouped with their state and result', () {
      final steps = turns[3].steps;
      expect(steps.map((s) => s.name), ['Read', 'Bash']);
      expect(steps[0].summary, 'src/session.ts');
      expect(steps[0].state, HerdrStepState.done);
      expect(steps[0].result, 'line 1\nline 2');
      expect(steps[1].summary, 'npm test');
      expect(steps[1].state, HerdrStepState.failed);
      expect(steps[1].result, '1 failed');
      expect(turns[3].overall, HerdrStepState.failed);
    });

    test(
      'side chains, meta messages, cut lines and unknown kinds are skipped',
      () {
        final all = turns.map((t) => t.text).join('\n');
        expect(all, isNot(contains('SIDECHAIN')));
        expect(all, isNot(contains('META TEXT')));
      },
    );

    test('secrets are masked in what is shown', () {
      expect(turns[4].text, isNot(contains('sk-abcdefghijklmnop')));
      expect(turns[4].text, contains('API_KEY'));
    });

    test('a question waiting for its answer, with its options', () {
      final question = turns.last;
      expect(question.text, 'Which approach do you prefer?');
      expect(question.options, ['Unit tests', 'Fake server']);
      expect(question.answered, isFalse);
    });

    test('a running tool call has no result yet', () {
      final running = herdrParseClaude([
        '{"type":"assistant","uuid":"x","message":{"content":[{"type":"tool_use","id":"z","name":"Bash","input":{"command":"sleep 9"}}]}}',
      ]);
      expect(running.single.steps.single.state, HerdrStepState.running);
      expect(running.single.overall, HerdrStepState.running);
    });

    test('only the newest turns are kept', () {
      final many = [
        for (var i = 0; i < herdrTurnsMax + 20; i++)
          '{"type":"user","uuid":"u$i","message":{"content":"m$i"}}',
      ];
      final kept = herdrParseClaude(many);
      expect(kept, hasLength(herdrTurnsMax));
      expect(kept.last.text, 'm${herdrTurnsMax + 19}');
    });
  });

  group('the conversation of a Codex file', () {
    final turns = herdrParseCodex(_fx('session_codex_synthetic.jsonl'));

    test('user, assistant, a failed command, reasoning; no context text', () {
      expect(turns.map((t) => t.kind), [
        HerdrTurnKind.user,
        HerdrTurnKind.assistant,
        HerdrTurnKind.steps,
        HerdrTurnKind.thinking,
        HerdrTurnKind.assistant,
      ]);
      expect(turns.first.text, 'Fix the lint errors');
      final step = turns[2].steps.single;
      expect(step.summary, 'bash -lc npm run lint');
      expect(step.state, HerdrStepState.failed);
      expect(step.result, '2 problems');
      expect(turns.map((t) => t.text).join(), isNot(contains('DEVELOPER')));
      expect(turns.map((t) => t.text).join(), isNot(contains('environment')));
    });
  });

  group('finding the session file', () {
    const cwd = '/home/demo/proyectos/app';
    final now = DateTime.utc(2026, 11, 2, 12);
    final project = herdrClaudeProjectName(cwd);

    test('the project folder name of a working folder', () {
      expect(
        herdrClaudeProjectName('/home/me/.t3/scratch/x-1'),
        '-home-me--t3-scratch-x-1',
      );
    });

    test('Claude: the newest file of the folder', () {
      final files = FakeSessionFiles()
        ..put(
          '/home/demo/.claude/projects/$project/old.jsonl',
          '{}\n',
          modified: now.subtract(const Duration(hours: 5)),
        )
        ..put(
          '/home/demo/.claude/projects/$project/new.jsonl',
          '{}\n',
          modified: now.subtract(const Duration(minutes: 1)),
        )
        ..put('/home/demo/.claude/projects/$project/notes.txt', 'x');
      expect(
        herdrLocateSession(
          files,
          kind: 'claude',
          cwd: cwd,
          now: now,
          working: true,
        ),
        completion(
          const HerdrSessionRef(
            '/home/demo/.claude/projects/-home-demo-proyectos-app/new.jsonl',
            HerdrTranscriptFormat.claude,
          ),
        ),
      );
    });

    test('Claude: nothing certain, nothing returned', () async {
      final files = FakeSessionFiles()
        ..put(
          '/home/demo/.claude/projects/$project/a.jsonl',
          '{}\n',
          modified: now.subtract(const Duration(hours: 5)),
        );
      // Two agents of that kind in the same folder: cannot be told apart.
      expect(
        await herdrLocateSession(
          files,
          kind: 'claude',
          cwd: cwd,
          now: now,
          working: false,
          sameKindInFolder: 2,
        ),
        isNull,
      );
      // A working agent whose newest file has not moved for hours.
      expect(
        await herdrLocateSession(
          files,
          kind: 'claude',
          cwd: cwd,
          now: now,
          working: true,
        ),
        isNull,
      );
      // No file, another folder, another kind.
      expect(
        await herdrLocateSession(
          files,
          kind: 'claude',
          cwd: '/srv/other',
          now: now,
          working: false,
        ),
        isNull,
      );
      expect(
        await herdrLocateSession(
          files,
          kind: 'hermes',
          cwd: cwd,
          now: now,
          working: false,
        ),
        isNull,
      );
      // An idle agent keeps its (old) file.
      expect(
        await herdrLocateSession(
          files,
          kind: 'claude',
          cwd: cwd,
          now: now,
          working: false,
        ),
        isNotNull,
      );
    });

    test(
      'a quiet agent does not own a file that changed after it went quiet',
      () async {
        final files = FakeSessionFiles()
          ..put(
            '/home/demo/.claude/projects/$project/a.jsonl',
            '{}\n',
            modified: now.subtract(const Duration(seconds: 30)),
          );
        Future<HerdrSessionRef?> locate(Duration? quiet) => herdrLocateSession(
          files,
          kind: 'claude',
          cwd: cwd,
          now: now,
          working: false,
          quietFor: quiet,
        );
        // Quiet for two minutes, yet the file moved 30 s ago: someone else's.
        expect(await locate(const Duration(minutes: 2)), isNull);
        // Quiet for ten seconds: too little to say.
        expect(await locate(const Duration(seconds: 10)), isNotNull);
        expect(await locate(null), isNotNull);
        // The file stopped moving when the agent went quiet.
        files.times['/home/demo/.claude/projects/$project/a.jsonl'] = now
            .subtract(const Duration(seconds: 125));
        expect(await locate(const Duration(minutes: 2)), isNotNull);
      },
    );

    test('Codex: the newest file that names this working folder', () async {
      final files = FakeSessionFiles()
        ..put(
          '/home/demo/.codex/sessions/2026/11/02/rollout-2026-11-02T10-00-00-a.jsonl',
          '{"type":"session_meta","payload":{"cwd":"$cwd"}}\n',
          modified: now.subtract(const Duration(minutes: 30)),
        )
        ..put(
          '/home/demo/.codex/sessions/2026/11/02/rollout-2026-11-02T11-00-00-b.jsonl',
          '{"type":"session_meta","payload":{"cwd":"/srv/other"}}\n',
          modified: now.subtract(const Duration(minutes: 5)),
        )
        ..put(
          '/home/demo/.codex/sessions/2026/11/02/not a rollout.jsonl',
          '{"type":"session_meta","payload":{"cwd":"$cwd"}}\n',
          modified: now,
        );
      final found = await herdrLocateSession(
        files,
        kind: 'codex',
        cwd: cwd,
        now: now,
        working: false,
      );
      expect(found?.path, endsWith('rollout-2026-11-02T10-00-00-a.jsonl'));
      expect(found?.format, HerdrTranscriptFormat.codex);
    });
  });
}
