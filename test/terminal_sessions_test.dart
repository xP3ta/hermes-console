import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_status.dart';
import 'package:hermes_android/core/services/terminal_sessions.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/ssh_sessions_sheet.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_herdr_server.dart';

/// Names a hostile server could give a session.
const List<String> _hostile = [
  "it's",
  r'$(id)',
  'a;b',
  '`x`',
  'a b',
  '"q"',
  r'\',
  '*',
  'a|b',
  'é日本',
];

void main() {
  group('lines typed into the terminal', () {
    test('tmux attaches by its id, one quoted word', () {
      expect(TerminalAttach.tmux(r'$3'), r"tmux attach-session -t '$3'");
      for (final bad in [
        '3',
        r'$',
        r'$a',
        r'$3; ls',
        r'$(id)',
        'name',
        '',
        r'$1234567890',
      ]) {
        expect(TerminalAttach.tmux(bad), isNull, reason: bad);
      }
    });

    test('a Herdr session: validated name, every word quoted', () {
      expect(
        TerminalAttach.herdrSession('work', herdr: fakeHerdrPath),
        "'$fakeHerdrPath' session attach 'work'",
      );
      // Without a resolved path it goes by name in the shell.
      expect(
        TerminalAttach.herdrSession('work'),
        "herdr session attach 'work'",
      );
      // The default session is plain `herdr`.
      expect(TerminalAttach.herdrSession('default', isDefault: true), 'herdr');
      expect(
        TerminalAttach.herdrSession(
          'default',
          isDefault: true,
          herdr: fakeHerdrPath,
        ),
        "'$fakeHerdrPath'",
      );
    });

    test('hostile names stay one inert word', () {
      const prefix = "'$fakeHerdrPath' session attach ";
      for (final name in _hostile) {
        final line = TerminalAttach.herdrSession(name, herdr: fakeHerdrPath)!;
        // After the fixed words, exactly one quoted word: the name itself.
        expect(line, startsWith(prefix), reason: name);
        expect(shellWords(line.substring(prefix.length)), [name], reason: name);
      }
    });

    test('newlines, NUL and other control characters are refused', () {
      for (final name in [
        'a\nb',
        'a\rb',
        'a\u0000b',
        'a\tb',
        'a\u001bb',
        'a\u007fb',
        'a\u0085b',
        '',
        '-x',
        '--session',
        'x' * 129,
      ]) {
        expect(terminalSessionNameOk(name), isFalse, reason: name);
        expect(
          TerminalAttach.herdrSession(name, herdr: fakeHerdrPath),
          isNull,
          reason: name,
        );
      }
      expect(terminalSessionNameOk('x' * 128), isTrue);
    });

    test('an agent and a workspace: ids from Herdr only', () {
      expect(
        TerminalAttach.herdrAgent('w5:p1', herdr: fakeHerdrPath),
        "'$fakeHerdrPath' agent attach 'w5:p1'",
      );
      expect(
        TerminalAttach.herdrWorkspace('w2', herdr: fakeHerdrPath),
        "'$fakeHerdrPath' workspace focus 'w2' >/dev/null 2>&1; "
        "'$fakeHerdrPath'",
      );
      for (final bad in ['w1:p1; ls', r'$(id)', 'w', 'x1', 'w1\nw2', '']) {
        expect(TerminalAttach.herdrAgent(bad), isNull, reason: bad);
        expect(TerminalAttach.herdrWorkspace(bad), isNull, reason: bad);
      }
      // A path that is not a plain absolute one is not used as a program.
      expect(
        TerminalAttach.herdrAgent('w5:p1', herdr: "/tmp/it's/herdr"),
        "herdr agent attach 'w5:p1'",
      );
    });

    test('none of the lines can hold a newline', () {
      final lines = <String?>[
        TerminalAttach.tmux(r'$9'),
        TerminalAttach.herdrAgent('w1:p1'),
        TerminalAttach.herdrWorkspace('w1'),
        TerminalAttach.herdrSession('x y'),
        for (final n in _hostile) TerminalAttach.herdrSession(n),
      ];
      for (final line in lines) {
        expect(line, isNotNull);
        expect(line!.runes.any((r) => r < 0x20 || r == 0x7f), isFalse);
      }
    });
  });

  group('what is on the server', () {
    test('tmux sessions parse; odd lines are skipped', () {
      final sessions = parseTmuxSessions(
        '\$0\t2\t1\twork\n'
        'junk\n'
        '\$1\t1\t0\tname\twith tab\n'
        'x\t1\t0\tbad id\n'
        '\$2\tmany\t0\tbad count\n'
        '\$3\t1\t0\t\n'
        '\$4\t3\t0\tit\'s\n',
      );
      expect(sessions.map((s) => s.id), [r'$0', r'$1', r'$4']);
      expect(sessions.first.name, 'work');
      expect(sessions.first.windows, 2);
      expect(sessions.first.attached, 1);
      expect(sessions[1].name, 'name\twith tab');
    });

    test('tmux: not installed, no server and a list are told apart', () async {
      final server = FakeHerdrServer()..tmux = null;
      expect(
        (await loadTmuxSessions(server.call)).state,
        TerminalProgram.notInstalled,
      );
      server.tmux = const [];
      final empty = await loadTmuxSessions(server.call);
      expect(empty.state, TerminalProgram.ready);
      expect(empty.sessions, isEmpty);
      server.tmux = const [
        FakeTmux(r'$0', 'work', windows: 2, attached: 1),
        FakeTmux(r'$1', 'logs'),
      ];
      final list = await loadTmuxSessions(server.call);
      expect(list.sessions.map((s) => s.name), ['work', 'logs']);
      server.failWith = StateError('dropped');
      expect(
        (await loadTmuxSessions(server.call)).state,
        TerminalProgram.failed,
      );
      // Only the one fixed command was asked.
      expect(server.commands.toSet(), {sshTmuxListCommand});
      expect(sshTmuxListCommand, contains('tmux list-sessions -F'));
    });

    test('Herdr: its sessions and the workspaces of the default one', () async {
      final server = FakeHerdrServer(
        agents: [FakeAgent('w1:p1', 'claude', HerdrAgentStatus.blocked)],
      )..focusedWorkspace = 'w1';
      final listing = await loadHerdrSessions(server.call);
      expect(listing.state, TerminalProgram.ready);
      expect(listing.herdr, fakeHerdrPath);
      expect(listing.sessions.map((s) => s.name), ['default', 'work']);
      expect(listing.sessions.first.isDefault, isTrue);
      expect(listing.sessions.last.running, isFalse);
      expect(listing.workspaces.map((w) => w.label), ['app', 'shell']);
      expect(listing.workspaces.first.focused, isTrue);
      // Reads only.
      final verbs = server.herdrCalls.map((c) => shellWords(c).sublist(1, 3));
      expect(
        verbs,
        containsAll([
          ['api', 'snapshot'],
          ['session', 'list'],
        ]),
      );
      expect(verbs.length, 2);
    });

    test('Herdr: not installed, server stopped, and a bad listing', () async {
      expect(
        (await loadHerdrSessions(
          (FakeHerdrServer()..installed = false).call,
        )).state,
        TerminalProgram.notInstalled,
      );
      final stopped = FakeHerdrServer()..serverRunning = false;
      final listing = await loadHerdrSessions(stopped.call);
      expect(listing.state, TerminalProgram.ready);
      expect(listing.workspaces, isEmpty);
      expect(parseHerdrSessions('not json'), isEmpty);
      expect(parseHerdrSessions('{"sessions":[{"name":"a\\nb"}]}'), isEmpty);
      expect(parseHerdrSessions('{"sessions":[{"name":"-x"}]}'), isEmpty);
    });
  });

  group('recent attaches', () {
    test('kept per server, newest first, at most eight', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final a = TerminalRecentStore(prefs, 'a');
      final b = TerminalRecentStore(prefs, 'b');
      await a.add(const TerminalRecent(TerminalRecentKind.tmux, 'one'));
      await a.add(const TerminalRecent(TerminalRecentKind.tmux, 'two'));
      await a.add(const TerminalRecent(TerminalRecentKind.tmux, 'one'));
      expect(a.items.map((r) => r.name), ['one', 'two']);
      expect(b.items, isEmpty);
      for (var i = 0; i < 12; i++) {
        await a.add(TerminalRecent(TerminalRecentKind.herdrWorkspace, 'w$i'));
      }
      expect(a.items.length, TerminalRecentStore.max);
      expect(a.items.first.name, 'w11');
      expect(a.items.first.kind, TerminalRecentKind.herdrWorkspace);
    });

    test('a corrupt entry is dropped', () async {
      SharedPreferences.setMockInitialValues({
        'tss.recent.a': ['not json', '["nope","x"]', '["tmux","ok"]', '[1]'],
      });
      final prefs = await SharedPreferences.getInstance();
      expect(TerminalRecentStore(prefs, 'a').items.map((r) => r.name), ['ok']);
    });
  });

  group('the sheet', () {
    Future<TerminalSessionChoice?> open(
      WidgetTester tester,
      FakeHerdrServer server, {
      TerminalRecentStore? recents,
      Size size = const Size(420, 900),
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      TerminalSessionChoice? choice;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            Strings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.hermesRedDark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => choice = await showSshSessionsSheet(
                  context,
                  run: server.call,
                  recents: recents,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return choice;
    }

    testWidgets('Shell stays; tmux and Herdr list what is there', (
      tester,
    ) async {
      final server = FakeHerdrServer(
        agents: [FakeAgent('w1:p1', 'claude', HerdrAgentStatus.working)],
      )..tmux = const [FakeTmux(r'$0', 'work', windows: 2, attached: 1)];
      await open(tester, server);

      expect(find.byKey(const ValueKey('ssh-sessions-shell')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ssh-sessions-tab-tmux')));
      await tester.pumpAndSettle();
      expect(find.text('work'), findsOneWidget);
      expect(find.text('2 windows · In use'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ssh-sessions-tab-herdr')));
      await tester.pumpAndSettle();
      expect(find.text('Default session'), findsOneWidget);
      expect(find.text('work'), findsOneWidget);
      expect(find.text('Stopped'), findsOneWidget);
      expect(find.text('app'), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
      // A stopped session cannot be chosen.
      expect(
        find.byKey(const ValueKey('ssh-sessions-herdr-session-work')),
        findsOneWidget,
      );
    });

    testWidgets('choosing a tmux row returns the exact line', (tester) async {
      final server = FakeHerdrServer()
        ..tmux = const [FakeTmux(r'$7', "it's \$(x)")];
      TerminalSessionChoice? choice;
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            Strings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.hermesRedDark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => choice = await showSshSessionsSheet(
                  context,
                  run: server.call,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ssh-sessions-tab-tmux')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey(r'ssh-sessions-tmux-$7')));
      await tester.pumpAndSettle();
      // By id, so the name's quote and `$()` never reach the shell.
      expect(choice!.line, r"tmux attach-session -t '$7'");
      expect(choice!.recent.name, "it's \$(x)");
      expect(choice!.recent.kind, TerminalRecentKind.tmux);
    });

    testWidgets('no tmux, no Herdr: each tab says «Not installed»', (
      tester,
    ) async {
      final server = FakeHerdrServer(installed: false)..tmux = null;
      await open(tester, server);
      await tester.tap(find.byKey(const ValueKey('ssh-sessions-tab-tmux')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ssh-sessions-tmux-missing')),
        findsOneWidget,
      );
      expect(find.text('Not installed'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ssh-sessions-tab-herdr')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ssh-sessions-herdr-missing')),
        findsOneWidget,
      );
    });

    testWidgets('Recent shows only what still exists', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final recents = TerminalRecentStore(prefs, 'a');
      await recents.add(const TerminalRecent(TerminalRecentKind.tmux, 'gone'));
      await recents.add(const TerminalRecent(TerminalRecentKind.tmux, 'work'));
      final server = FakeHerdrServer()..tmux = const [FakeTmux(r'$0', 'work')];
      await open(tester, server, recents: recents);
      await tester.tap(find.byKey(const ValueKey('ssh-sessions-tab-recent')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ssh-sessions-recent-tmux-work')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ssh-sessions-recent-tmux-gone')),
        findsNothing,
      );
    });

    for (final width in [360.0, 600.0, 840.0, 1100.0]) {
      testWidgets('fits at ${width.toInt()} dp and 2x text', (tester) async {
        final server = FakeHerdrServer()
          ..tmux = [
            for (var i = 0; i < 12; i++) FakeTmux('\$$i', 'session-$i'),
          ];
        await open(tester, server, size: Size(width, 700), textScale: 2);
        await tester.tap(find.byKey(const ValueKey('ssh-sessions-tab-tmux')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('session-0'), findsOneWidget);
      });
    }
  });
}
