// The flat Agents section: rows without cards grouped by folder, the tray of
// agents that wait on the user, the filter chips, the flat detail with its
// pending-action sheet (answer by number, once), the keys menu, the
// conversation read from a session file, the two panes and the themes.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_status.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

import 'support/fake_herdr_server.dart';
import 'support/fake_session_files.dart';
import 'support/herdr_view_rig.dart';

String _screen(String name) =>
    File('test/fixtures/herdr/$name').readAsStringSync();

const String _app = '/home/demo/proyectos/app';
const String _api = '/home/demo/proyectos/api';
const String _web = '/home/demo/proyectos/web';

FakeHerdrServer _server() =>
    FakeHerdrServer(
        agents: [
          FakeAgent(
            'w1:p1',
            'claude',
            HerdrAgentStatus.blocked,
            name: 'asker',
            cwd: _app,
            seq: 2,
            workspace: 'ws1',
            workspaceId: 'w1',
          ),
          FakeAgent(
            'w2:p1',
            'codex',
            HerdrAgentStatus.blocked,
            name: 'approver',
            cwd: _api,
            seq: 3,
            workspace: 'ws2',
            workspaceId: 'w2',
          ),
          FakeAgent(
            'w3:p1',
            'hermes',
            HerdrAgentStatus.blocked,
            name: 'waiter',
            cwd: _api,
            seq: 4,
            workspace: 'ws3',
            workspaceId: 'w3',
          ),
          FakeAgent(
            'w5:p1',
            'claude',
            HerdrAgentStatus.working,
            name: 'worker',
            cwd: _app,
            workspace: 'ws5',
            workspaceId: 'w5',
          ),
          FakeAgent(
            'w6:p1',
            'codex',
            HerdrAgentStatus.idle,
            name: 'idler',
            cwd: _web,
            workspace: 'ws6',
            workspaceId: 'w6',
          ),
          FakeAgent(
            'w7:p1',
            'claude',
            HerdrAgentStatus.done,
            name: 'finished',
            cwd: _web,
            workspace: 'ws7',
            workspaceId: 'w7',
          ),
        ],
      )
      ..screens['w1:p1'] = _screen('screen_claude_question_synthetic.txt')
      ..screens['w2:p1'] = _screen('screen_codex_approval_synthetic.txt')
      ..screens['w3:p1'] = 'Working on it\nPress a key'
      ..screens['w5:p1'] = _screen('screen_working_synthetic.txt')
      ..screens['w6:p1'] = _screen('screen_idle_synthetic.txt')
      ..screens['w7:p1'] = _screen('screen_idle_synthetic.txt');

Finder _key(String key) => find.byKey(ValueKey(key));

double _top(WidgetTester tester, String key) => tester.getTopLeft(_key(key)).dy;

String _sub(WidgetTester tester, String pane) =>
    tester.widget<Text>(_key('hda-sub-$pane')).data!;

Finder _in(String key, String text) =>
    find.descendant(of: _key(key), matching: find.text(text));

Future<void> _chip(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pump();
  await tester.tap(_key(key));
  await tester.pump();
}

Future<void> _menu(WidgetTester tester, String menu, String item) async {
  await tester.ensureVisible(_key(menu));
  await tester.pump();
  await tester.tap(_key(menu));
  await tester.pumpAndSettle();
  await tester.tap(_key(item));
  await tester.pumpAndSettle();
}

void main() {
  group('the flat list', () {
    testWidgets(
      'rows without cards, grouped by folder, in order of attention',
      (tester) async {
        await openHerdr(tester, _server(), size: const Size(420, 1800));
        expect(find.byType(Card), findsNothing);

        // One heading per working folder; the one with agents that wait on you
        // first, in the order they were listed.
        final app = _top(tester, 'hda-folder-$_app');
        final api = _top(tester, 'hda-folder-$_api');
        final web = _top(tester, 'hda-folder-$_web');
        expect(app, lessThan(api));
        expect(api, lessThan(web));
        // Whole path on hold; the short name on the page.
        expect(find.byTooltip(_app), findsOneWidget);
        expect(find.text('app'), findsWidgets);

        // Inside a folder: waiting, then working.
        expect(
          _top(tester, 'hda-row-w1:p1'),
          lessThan(_top(tester, 'hda-row-w5:p1')),
        );
        expect(
          _top(tester, 'hda-row-w2:p1'),
          lessThan(_top(tester, 'hda-row-w3:p1')),
        );

        // The state in words, with the line of what each one does or asks.
        expect(find.text('Needs an answer'), findsNWidgets(2));
        expect(find.text('Working…'), findsOneWidget);
        expect(find.text('Free'), findsOneWidget);
        expect(
          _sub(tester, 'w1:p1'),
          'Which approach do you prefer for the tests?',
        );
        expect(_sub(tester, 'w2:p1'), 'rm -rf build/');
        expect(_sub(tester, 'w5:p1'), 'Editing auth.ts…');
        expect(
          _sub(tester, 'w6:p1'),
          'Done. I added the tests for the session module and they pass.',
        );
        // A thin line between the rows of a folder, none after the last.
        expect(find.byType(Divider), findsWidgets);
      },
    );

    testWidgets('the tray on top: why each agent waits, its name and folder', (
      tester,
    ) async {
      final rig = await openHerdr(
        tester,
        _server(),
        size: const Size(420, 1800),
      );
      expect(_key('hda-needs-strip'), findsOneWidget);
      expect(_in('hda-need-w1:p1', 'Question'), findsOneWidget);
      expect(_in('hda-need-w2:p1', 'Approval'), findsOneWidget);
      expect(_in('hda-need-w3:p1', 'Waiting for you'), findsOneWidget);
      expect(_in('hda-need-w1:p1', 'asker'), findsOneWidget);
      expect(_in('hda-need-w1:p1', 'app'), findsOneWidget);
      // Above every folder, and only the ones that wait.
      expect(
        _top(tester, 'hda-need-w1:p1'),
        lessThan(_top(tester, 'hda-folder-$_app')),
      );
      expect(_key('hda-need-w5:p1'), findsNothing);

      await tester.tap(_key('hda-need-w2:p1'));
      await tester.pump();
      await tester.pump();
      expect(rig.controller.detailPaneId, 'w2:p1');
      expect(_key('hda-detail'), findsOneWidget);
    });

    testWidgets('finished agents are folded at the end', (tester) async {
      await openHerdr(tester, _server(), size: const Size(420, 1800));
      expect(find.text('Finished (1)'), findsOneWidget);
      expect(_key('hda-row-w7:p1'), findsNothing);
      await tester.tap(_key('hda-done-toggle'));
      await tester.pump();
      expect(_key('hda-row-w7:p1'), findsOneWidget);
      expect(
        _top(tester, 'hda-row-w7:p1'),
        greaterThan(_top(tester, 'hda-row-w6:p1')),
      );
      await tester.tap(_key('hda-done-toggle'));
      await tester.pump();
      expect(_key('hda-row-w7:p1'), findsNothing);
    });

    testWidgets('chips: all, one per folder, then the states, together', (
      tester,
    ) async {
      await openHerdr(tester, _server(), size: const Size(420, 1800));
      for (final key in [
        'hda-filter-all',
        'hda-chip-folder-$_app',
        'hda-chip-folder-$_api',
        'hda-chip-folder-$_web',
        'hda-filter-blocked',
        'hda-filter-working',
        'hda-filter-idle',
      ]) {
        expect(_key(key), findsOneWidget, reason: key);
      }
      await _chip(tester, 'hda-chip-folder-$_api');
      expect(_key('hda-row-w2:p1'), findsOneWidget);
      expect(_key('hda-row-w1:p1'), findsNothing);
      expect(_key('hda-need-w2:p1'), findsOneWidget);
      expect(_key('hda-need-w1:p1'), findsNothing);

      // A folder and a state narrow it together.
      await _chip(tester, 'hda-chip-folder-$_app');
      await _chip(tester, 'hda-filter-working');
      expect(_key('hda-row-w5:p1'), findsOneWidget);
      expect(_key('hda-row-w1:p1'), findsNothing);

      // «All» clears both.
      await _chip(tester, 'hda-filter-all');
      expect(_key('hda-row-w1:p1'), findsOneWidget);
      expect(_key('hda-row-w6:p1'), findsOneWidget);
    });

    testWidgets(
      'state, tray and chips say it in words and are at least 48 dp',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await openHerdr(tester, _server(), size: const Size(420, 1800));
        final tag = tester.getSemantics(_key('hda-need-w1:p1'));
        expect(tag.label, contains('asker'));
        expect(tag.label, contains('Question'));
        final row = tester.getSemantics(_key('hda-tile-w5:p1'));
        expect(row.label, contains('Working…'));
        expect(row.label, contains('Editing auth.ts…'));
        expect(row.label, contains('~/proyectos/app'));
        final header = tester.getSemantics(_key('hda-folder-$_app'));
        expect(header.label, contains(_app));
        for (final key in [
          'hda-need-w1:p1',
          'hda-chip-folder-$_app',
          'hda-filter-all',
          'hda-row-w1:p1',
          'hda-done-toggle',
        ]) {
          expect(
            tester.getSize(_key(key)).height,
            greaterThanOrEqualTo(48),
            reason: key,
          );
        }
        semantics.dispose();
      },
    );
  });

  group('the pending action', () {
    testWidgets('a numbered question: one row per option, the key goes once, '
        'in states', (tester) async {
      final server = _server()..sendKeysDelay = const Duration(seconds: 2);
      final rig = await openHerdr(tester, server);
      await openAgent(tester, rig, 'w1:p1');
      expect(_key('hda-ask-sheet'), findsOneWidget);
      expect(_in('hda-ask-sheet', 'Question'), findsOneWidget);
      expect(
        _in('hda-ask-sheet', 'Which approach do you prefer for the tests?'),
        findsOneWidget,
      );
      expect(_key('hda-ask-command'), findsNothing);
      for (var n = 1; n <= 3; n++) {
        expect(_key('hda-ask-option-$n'), findsOneWidget);
      }
      expect(find.text('Pure unit tests'), findsOneWidget);
      // The sheet sits above the instruction field.
      expect(
        tester.getRect(_key('hda-ask-sheet')).bottom,
        lessThanOrEqualTo(tester.getRect(_key('hda-prompt-field')).top + 1),
      );

      server.commands.clear();
      await tester.tap(_key('hda-ask-option-2'));
      await tester.pump();
      expect(find.text('Sending…'), findsOneWidget);
      // While it is in flight nothing else goes.
      await tester.tap(_key('hda-ask-option-1'));
      await tester.tap(_key('hda-ask-option-2'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Sent ✓'), findsOneWidget);
      expect(server.keysSent, [
        ['2'],
      ]);
      // Held after it went.
      await tester.tap(_key('hda-ask-option-3'));
      await tester.pump();
      expect(server.keysSent, hasLength(1));

      // The agent did not move on: the options come back after a few seconds.
      await tester.pump(const Duration(seconds: 7));
      expect(find.text('Sent ✓'), findsNothing);
      await tester.tap(_key('hda-ask-option-3'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(server.keysSent, [
        ['2'],
        ['3'],
      ]);
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('a key that could not be sent says so, and tries again', (
      tester,
    ) async {
      final server = _server()..sendKeysFails = true;
      final rig = await openHerdr(tester, server);
      await openAgent(tester, rig, 'w1:p1');
      await tester.tap(_key('hda-ask-option-1'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Could not send · Retry'), findsOneWidget);
      server.sendKeysFails = false;
      await tester.tap(_key('hda-ask-option-1'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Sent ✓'), findsOneWidget);
      expect(server.keysSent, [
        ['1'],
        ['1'],
      ]);
      // Let the hold on the options run out.
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('the sheet goes away when the agent stops waiting, and its '
        'options when they leave the screen', (tester) async {
      final server = _server();
      final rig = await openHerdr(tester, server);
      await openAgent(tester, rig, 'w1:p1');
      expect(_key('hda-ask-sheet'), findsOneWidget);

      // The screen no longer shows the options: Enter and Esc remain.
      server.screens['w1:p1'] = 'Waiting for something\nPress a key';
      await tester.pump(const Duration(seconds: 3));
      expect(_key('hda-ask-option-1'), findsNothing);
      expect(_key('hda-blocked-card'), findsOneWidget);

      // The agent moves on.
      server.agents[0].status = HerdrAgentStatus.working;
      server.agents[0].seq = 9;
      await rig.controller.refresh();
      await tester.pump();
      expect(_key('hda-ask-sheet'), findsNothing);
    });

    testWidgets('an approval shows the real command, taken from the screen', (
      tester,
    ) async {
      final rig = await openHerdr(tester, _server());
      await openAgent(tester, rig, 'w2:p1');
      expect(_in('hda-ask-sheet', 'Approval'), findsOneWidget);
      expect(
        tester.widget<SelectableText>(_key('hda-ask-command')).data,
        'rm -rf build/',
      );
      expect(find.text('Yes, proceed (y)'), findsOneWidget);
      expect(_key('hda-ask-option-3'), findsOneWidget);
    });

    testWidgets('no options on the screen: Enter and Esc, no promise that '
        'Enter is yes', (tester) async {
      final server = _server();
      final rig = await openHerdr(tester, server);
      await openAgent(tester, rig, 'w3:p1');
      expect(_in('hda-ask-sheet', 'Waiting for you'), findsOneWidget);
      expect(find.textContaining('not always'), findsOneWidget);
      server.commands.clear();
      await tester.tap(_key('hda-accept'));
      await tester.pump();
      await tester.tap(_key('hda-reject'));
      await tester.pump();
      expect(server.keysSent, [
        ['enter'],
        ['esc'],
      ]);
    });

    testWidgets('nine options at large text scroll inside the sheet', (
      tester,
    ) async {
      final server = _server()
        ..screens['w1:p1'] = [
          'Which one?',
          for (var i = 1; i <= 9; i++) '$i. Option number $i',
        ].join('\n');
      final rig = await openHerdr(
        tester,
        server,
        size: const Size(360, 1300),
        textScale: 2,
      );
      await openAgent(tester, rig, 'w1:p1');
      expect(tester.takeException(), isNull);
      expect(_key('hda-ask-option-9'), findsOneWidget);
      expect(
        tester.getRect(_key('hda-prompt-field')).bottom,
        lessThanOrEqualTo(1300),
      );
      expect(
        tester.getRect(_key('hda-ask-sheet')).height,
        lessThanOrEqualTo(1300 * 0.45 + 1),
      );
    });
  });

  group('the flat detail', () {
    testWidgets('one header, state and folder under the name, a menu', (
      tester,
    ) async {
      final rig = await openHerdr(tester, _server());
      await openAgent(tester, rig, 'w2:p1');
      expect(find.byType(Card), findsNothing);
      expect(_key('hda-detail-back'), findsOneWidget);
      expect(
        tester.widget<Text>(_key('hda-detail-subtitle')).data,
        'Approval · ~/proyectos/api · Demo server',
      );
      expect(
        tester.getSize(_key('hda-detail-menu')).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('the copy-path item puts the folder on the clipboard', (
      tester,
    ) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final rig = await openHerdr(tester, _server());
      await openAgent(tester, rig, 'w5:p1');
      await _menu(tester, 'hda-detail-menu', 'hda-detail-copy');
      expect(copied, [_app]);
    });

    testWidgets('the screen is plain text without frames; the quick keys are '
        'in a menu that cannot overflow', (tester) async {
      final server = _server();
      final rig = await openHerdr(
        tester,
        server,
        size: const Size(320, 700),
        textScale: 2,
      );
      await openAgent(tester, rig, 'w5:p1');
      expect(find.textContaining('Editing auth.ts'), findsWidgets);
      expect(find.textContaining('╭'), findsNothing);
      expect(find.textContaining('│'), findsNothing);
      expect(_key('hda-key-enter'), findsNothing);
      server.commands.clear();
      await _menu(tester, 'hda-keys', 'hda-key-ctrlC');
      expect(server.keysSent, [
        ['ctrl+c'],
      ]);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(_key('hda-keys')).width, greaterThanOrEqualTo(48));
    });

    testWidgets(
      'only an agent started here says it was launched from Console',
      (tester) async {
        final rig = await openHerdr(tester, _server());
        await rig.controller.createAgent(folder: '/srv/web', kind: 'claude');
        await tester.pump(const Duration(seconds: 3));
        await openAgent(tester, rig, 'w4:p1');
        expect(
          tester.widget<Text>(_key('hda-detail-subtitle')).data,
          contains('↳ launched from Console'),
        );
        await openAgent(tester, rig, 'w5:p1');
        expect(
          tester.widget<Text>(_key('hda-detail-subtitle')).data,
          isNot(contains('↳')),
        );
      },
    );
  });

  group('the conversation', () {
    const path = '/home/demo/.claude/projects/-home-demo-proyectos-app/s.jsonl';

    FakeHerdrServer one([String agent = 'claude']) => FakeHerdrServer(
      agents: [
        FakeAgent(
          'w1:p1',
          agent,
          HerdrAgentStatus.idle,
          name: 'solo',
          cwd: _app,
        ),
      ],
    )..screens['w1:p1'] = _screen('screen_working_synthetic.txt');

    FakeSessionFiles files() =>
        FakeSessionFiles()
          ..put(path, _screen('session_claude_synthetic.jsonl'));

    testWidgets('text to read, quiet folds with their state, secrets hidden', (
      tester,
    ) async {
      final rig = await openHerdr(
        tester,
        one(),
        sessionFiles: files(),
        size: const Size(420, 1000),
      );
      await openAgent(tester, rig, 'w1:p1');
      expect(tester.takeException(), isNull);
      expect(_key('hda-transcript'), findsOneWidget);
      expect(_key('hda-no-transcript'), findsNothing);
      expect(find.text('Add tests to the session module'), findsOneWidget);
      expect(
        find.textContaining('session.ts', findRichText: true),
        findsWidgets,
      );
      // Folded: thinking and the tool calls, with their state in words.
      expect(find.text('Thinking'), findsOneWidget);
      expect(find.text('Plan: read the module first.'), findsNothing);
      expect(find.text('2 more steps · failed'), findsOneWidget);
      expect(find.text('Bash · npm test · failed'), findsNothing);
      await tester.tap(_key('hda-fold-2 more steps'));
      await tester.pump();
      expect(find.text('Bash · npm test · failed'), findsOneWidget);
      expect(find.text('Read · src/session.ts · done'), findsOneWidget);
      // A question waiting for its answer, with its options.
      expect(find.text('Which approach do you prefer?'), findsOneWidget);
      expect(find.text('1  Unit tests'), findsOneWidget);
      // The key is not shown.
      expect(
        find.textContaining('sk-abcdefghijklmnop', findRichText: true),
        findsNothing,
      );
    });

    testWidgets('the terminal screen is one tap away in the menu', (
      tester,
    ) async {
      final rig = await openHerdr(tester, one(), sessionFiles: files());
      await openAgent(tester, rig, 'w1:p1');
      expect(_key('hda-output'), findsNothing);
      await _menu(tester, 'hda-detail-menu', 'hda-detail-view');
      expect(_key('hda-output'), findsOneWidget);
      expect(_key('hda-transcript'), findsNothing);
      await _menu(tester, 'hda-detail-menu', 'hda-detail-view');
      expect(_key('hda-transcript'), findsOneWidget);
    });

    testWidgets('no file found with certainty: the clean screen and a quiet '
        'notice; an agent without such files gets no notice', (tester) async {
      final rig = await openHerdr(
        tester,
        one(),
        sessionFiles: FakeSessionFiles(),
      );
      await openAgent(tester, rig, 'w1:p1');
      expect(_key('hda-no-transcript'), findsOneWidget);
      expect(_key('hda-output'), findsOneWidget);
      expect(find.textContaining('Editing auth.ts'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
      final other = await openHerdr(
        tester,
        one('hermes'),
        sessionFiles: files(),
      );
      await openAgent(tester, other, 'w1:p1');
      expect(_key('hda-no-transcript'), findsNothing);
      expect(_key('hda-output'), findsOneWidget);
    });
  });

  group('two panes and themes', () {
    for (final width in [360.0, 600.0, 840.0, 1100.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('${width.toInt()} dp at ${scale}x: list, detail and the '
            'sheet without overflow', (tester) async {
          final rig = await openHerdr(
            tester,
            _server(),
            size: Size(width, 800),
            textScale: scale,
          );
          expect(tester.takeException(), isNull);
          final wide = width >= 600;
          if (wide) {
            final list = tester.getRect(_key('hda-scroll'));
            expect(list.width, inInclusiveRange(300, 380));
          }
          rig.controller.openDetail('w1:p1');
          for (var i = 0; i < 4; i++) {
            await tester.pump();
          }
          expect(tester.takeException(), isNull);
          expect(_key('hda-ask-sheet'), findsOneWidget);
          // At large text the page scrolls: bring the field in, then it is
          // on the screen and the sheet is above it.
          await tester.ensureVisible(_key('hda-prompt-field'));
          await tester.pump();
          expect(
            tester.getRect(_key('hda-prompt-field')).bottom,
            lessThanOrEqualTo(800),
          );
          expect(
            tester.getRect(_key('hda-ask-sheet')).bottom,
            lessThanOrEqualTo(tester.getRect(_key('hda-prompt-field')).top + 1),
          );
          if (wide) {
            // The list stays, the agent is on its right; one back arrow only
            // (none here: the list is beside it).
            expect(_key('hda-row-w1:p1'), findsOneWidget);
            expect(
              tester.getRect(_key('hda-detail')).left,
              greaterThan(tester.getRect(_key('hda-scroll')).right - 1),
            );
            expect(_key('hda-detail-back'), findsNothing);
            // The open agent's row has a soft background and no frame.
            Color tint(String pane) => tester
                .widget<ColoredBox>(
                  find
                      .descendant(
                        of: _key('hda-tile-$pane'),
                        matching: find.byType(ColoredBox),
                      )
                      .first,
                )
                .color;
            expect(tint('w1:p1'), isNot(Colors.transparent));
            expect(tint('w5:p1'), Colors.transparent);
          } else {
            expect(_key('hda-detail-back'), findsOneWidget);
            expect(_key('hda-row-w1:p1'), findsNothing);
          }
        });
      }
    }

    for (final entry in {
      'dark': AppTheme.hermesRedDark,
      'light': AppTheme.hermesRedLight,
    }.entries) {
      testWidgets('${entry.key}: list with tray, then the sheet, at 2x text', (
        tester,
      ) async {
        final rig = await openHerdr(
          tester,
          _server(),
          theme: entry.value,
          textScale: 2,
          size: const Size(320, 700),
        );
        expect(tester.takeException(), isNull);
        expect(_key('hda-needs-strip'), findsOneWidget);
        rig.controller.openDetail('w2:p1');
        for (var i = 0; i < 4; i++) {
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
        expect(_key('hda-ask-command'), findsOneWidget);
      });
    }

    testWidgets('every language renders the tray, the list and the sheet', (
      tester,
    ) async {
      for (final language in ['es', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
        final rig = await openHerdr(
          tester,
          _server(),
          locale: Locale(language),
          textScale: 1.6,
          size: const Size(360, 800),
        );
        expect(tester.takeException(), isNull, reason: language);
        rig.controller.openDetail('w2:p1');
        for (var i = 0; i < 4; i++) {
          await tester.pump();
        }
        expect(tester.takeException(), isNull, reason: language);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });
}
