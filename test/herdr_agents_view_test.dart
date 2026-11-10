import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/herdr_agents_screen.dart';
import 'package:hermes_android/core/services/agent_processes.dart';
import 'package:hermes_android/core/services/herdr_agents.dart';
import 'package:hermes_android/core/services/herdr_harness.dart';
import 'package:hermes_android/core/services/herdr_status.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/herdr_agents_widgets.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_folder_source.dart';
import 'support/fake_herdr_server.dart';

class _Store implements HerdrAgentsStore {
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

const String _server = 'Demo server';

FakeHerdrServer _fake() => FakeHerdrServer(
  agents: [
    FakeAgent('w1:p1', 'claude', HerdrAgentStatus.working, name: 'reviewer'),
    FakeAgent('w1:p2', 'codex', HerdrAgentStatus.blocked, seq: 2),
    FakeAgent(
      'w2:p1',
      'hermes',
      HerdrAgentStatus.idle,
      workspace: 'logs',
      cwd: '/home/demo/proyectos/logs',
    ),
  ],
);

Widget _app(
  Widget child, {
  ThemeData? theme,
  double textScale = 1,
  Locale locale = const Locale('en'),
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: home!,
  ),
  home: Scaffold(body: child),
);

/// Fails with the whole description of an error the widgets reported (an
/// overflow says which widget it is).
void noException(WidgetTester tester, String step) {
  final error = tester.takeException();
  if (error != null) {
    fail(
      '$step: ${error is FlutterError ? error.toStringDeep() : error}'
      '\n${_reported.join('\n')}',
    );
  }
}

/// What the framework reported, with the widget that caused it.
final List<String> _reported = [];

/// Keeps what the framework reports, for [noException].
void recordReports() {
  _reported.clear();
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    _reported.add(details.toString());
    previous?.call(details);
  };
}

void _view(WidgetTester tester, [Size size = const Size(420, 900)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

class _Rig {
  _Rig(
    WidgetTester tester,
    this.server,
    this.store, {
    bool withProcesses = false,
    bool probeAsAlias = false,
  }) {
    controller = HerdrAgentsController(
      run: probeAsAlias
          ? (command) async => command == sshHerdrProbeCommand
                ? const SshRemoteResult(
                    stdout: "alias herdr='x'\n",
                    exitCode: 0,
                  )
                : server.call(command)
          : server.call,
      store: store,
      // The binding's clock follows the test's fake time.
      now: () => tester.binding.clock.now(),
      startRetry: Duration.zero,
      detector: HerdrHarnessDetector(),
    );
    scanner = withProcesses ? AgentProcessScanner(run: server.call) : null;
  }

  final FakeHerdrServer server;
  final _Store store;
  late final HerdrAgentsController controller;
  late final AgentProcessScanner? scanner;
  final FakeFolderSource folders = FakeFolderSource();

  /// Lines the view asked to type into a terminal.
  final List<String> typed = [];

  Widget view() => HerdrAgentsView(
    controller: controller,
    server: _server,
    processes: scanner,
    folders: folders,
    onOpenTerminal: (line) async => typed.add(line),
  );
}

Future<_Rig> _open(
  WidgetTester tester, {
  FakeHerdrServer? server,
  _Store? store,
  ThemeData? theme,
  double textScale = 1,
  Locale locale = const Locale('en'),
  Size size = const Size(420, 900),
  bool withProcesses = false,
  bool probeAsAlias = false,
}) async {
  _view(tester, size);
  final rig = _Rig(
    tester,
    server ?? _fake(),
    store ?? _Store(),
    withProcesses: withProcesses,
    probeAsAlias: probeAsAlias,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    rig.controller.dispose();
    rig.scanner?.dispose();
  });
  await tester.pumpWidget(
    _app(rig.view(), theme: theme, textScale: textScale, locale: locale),
  );
  await tester.pump();
  await tester.pump();
  return rig;
}

/// What the app sent that changes something: no reads of the list or of a
/// screen (the polling goes on while a dialog is open).
List<List<String>> _writes(FakeHerdrServer server) => [
  for (final call in server.herdrCalls)
    if (!{'snapshot', 'read'}.contains(shellWords(call)[2])) shellWords(call),
];

double _top(WidgetTester tester, String paneId) =>
    tester.getTopLeft(find.byKey(ValueKey('hda-row-$paneId'))).dy;

/// A chip of the filter line may sit past the edge of the line: bring it in.
Future<void> _tapChip(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
}

/// Scrolls the list until the row is built and on screen.
Future<void> _reveal(WidgetTester tester, String key) async {
  final scrollable = find
      .descendant(
        of: find.byKey(const ValueKey('hda-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(
    find.byKey(ValueKey(key)),
    200,
    scrollable: scrollable,
  );
  await tester.pump();
}

void main() {
  testWidgets('the list: one row per agent, those waiting on you first', (
    tester,
  ) async {
    final rig = await _open(tester);

    expect(find.text(_server), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w1:p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w1:p2')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w2:p1')), findsOneWidget);
    // The shell pane is not an agent.
    expect(find.byKey(const ValueKey('hda-row-w9:p1')), findsNothing);
    expect(_top(tester, 'w1:p2'), lessThan(_top(tester, 'w1:p1')));
    expect(_top(tester, 'w1:p1'), lessThan(_top(tester, 'w2:p1')));

    // Name, state in words (with colour and icon) and one line of what each
    // does; the one that waits on you is also in the tray on top.
    expect(find.text('reviewer'), findsOneWidget);
    expect(find.text('codex'), findsWidgets);
    expect(find.text('Working…'), findsOneWidget);
    expect(find.text('Approval'), findsWidgets);
    expect(find.text('Free'), findsOneWidget);
    expect(find.byIcon(Icons.front_hand_outlined), findsWidgets);
    expect(find.byIcon(Icons.autorenew_rounded), findsWidgets);
    expect(find.byKey(const ValueKey('hda-need-w1:p2')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-need-w1:p1')), findsNothing);
    expect(rig.controller.needsYou, 1);
  });

  testWidgets('filters narrow the list by state', (tester) async {
    await _open(tester);

    await _tapChip(tester, 'hda-filter-working');
    expect(find.byKey(const ValueKey('hda-row-w1:p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w1:p2')), findsNothing);

    await _tapChip(tester, 'hda-filter-blocked');
    expect(find.byKey(const ValueKey('hda-row-w1:p2')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w1:p1')), findsNothing);

    await _tapChip(tester, 'hda-filter-all');
    expect(find.byKey(const ValueKey('hda-row-w2:p1')), findsOneWidget);
  });

  testWidgets('targets are at least 48 dp and rows say everything', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _open(tester);
    for (final key in [
      'hda-filter-all',
      'hda-filter-blocked',
      'hda-need-w1:p2',
      'hda-new',
      'hda-menu',
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
    }
    expect(
      tester.getSize(find.byKey(const ValueKey('hda-row-w1:p1'))).height,
      greaterThanOrEqualTo(48),
    );
    final node = tester.getSemantics(
      find.byKey(const ValueKey('hda-tile-w1:p2')),
    );
    expect(node.label, contains('codex'));
    // The state is in the words, not only in a colour.
    expect(node.label, contains('Approval'));
    expect(node.label, contains('~/proyectos/app'));
    semantics.dispose();
  });

  testWidgets('a pause or a hidden tab stops the reads', (tester) async {
    final rig = await _open(tester);
    final before = rig.server.commands.length;
    expect(before, greaterThan(0));

    // The real order: resumed > inactive > hidden > paused, and back.
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));
    expect(rig.server.commands.length, before);

    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await tester.pump();
    expect(rig.server.commands.length, greaterThan(before));
  });

  testWidgets('Herdr not installed: one line, a way to install, no more', (
    tester,
  ) async {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
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
    final server = _fake()..installed = false;
    final store = _Store();
    final rig = await _open(tester, server: server, store: store);

    expect(rig.controller.phase, HerdrAgentsPhase.notInstalled);
    expect(find.byKey(const ValueKey('hda-install-hint')), findsOneWidget);
    expect(find.text('Herdr is not installed on this server.'), findsOneWidget);
    // Nothing alarming, nothing to create, and nothing else was run.
    expect(find.byKey(const ValueKey('hda-new')), findsNothing);
    expect(server.commands, [
      sshHerdrProbeCommand,
      sshHerdrFallbackProbeCommand,
    ]);

    await tester.tap(find.byKey(const ValueKey('hda-install-how')));
    await tester.pumpAndSettle();
    final shown = tester.widget<SelectableText>(
      find.byKey(const ValueKey('hda-install-command')),
    );
    expect(shown.data, sshHerdrInstallCommand);
    await tester.tap(find.byKey(const ValueKey('hda-install-copy')));
    await tester.pump();
    expect(clipboard, [sshHerdrInstallCommand]);
    expect(find.byKey(const ValueKey('hda-install-project')), findsOneWidget);

    // Closing the sheet runs nothing: the app never installs.
    await tester.tap(find.byKey(const ValueKey('hda-install-close')));
    await tester.pumpAndSettle();
    expect(server.commands.length, 2);

    // Dismissed: remembered, and the line is gone.
    await tester.tap(find.byKey(const ValueKey('hda-install-dismiss')));
    await tester.pump();
    expect(store.dismissed, isTrue);
    expect(find.byKey(const ValueKey('hda-install-hint')), findsNothing);
    expect(find.textContaining('not installed'), findsNothing);
  });

  testWidgets('a dismissed hint does not come back for that server', (
    tester,
  ) async {
    final server = _fake()..installed = false;
    final store = _Store()..dismissed = true;
    await _open(tester, server: server, store: store);
    expect(find.byKey(const ValueKey('hda-install-hint')), findsNothing);
    expect(find.text('No agents running'), findsOneWidget);
    // Still reachable from the menu.
    await tester.tap(find.byKey(const ValueKey('hda-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hda-menu-install')), findsOneWidget);
  });

  testWidgets('installed, no agents: empty state with a way to create', (
    tester,
  ) async {
    final server = _fake()..agents.clear();
    await _open(tester, server: server);
    expect(find.text('No agents running'), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-message-action')), findsOneWidget);
    expect(find.text('New agent'), findsOneWidget);
  });

  testWidgets('connection error, timeout and stopped server each say so', (
    tester,
  ) async {
    final down = _fake()..failWith = StateError('socket closed');
    await _open(tester, server: down);
    expect(find.text('Could not talk to the server.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final slow = _fake()..failWith = TimeoutException('slow');
    await _open(tester, server: slow);
    expect(find.text('The server took too long to answer.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final stopped = _fake()..serverRunning = false;
    await _open(tester, server: stopped);
    expect(find.text('Herdr is not running'), findsOneWidget);
  });

  testWidgets('opening an agent shows its screen and who a prompt is for', (
    tester,
  ) async {
    final server = _fake();
    server.screens['w1:p1'] = 'Reading lib/main.dart\nAll done';
    server.agents[0].status = HerdrAgentStatus.idle;
    final rig = await _open(tester, server: server);

    // The list reads each screen once for its line; from here on count the
    // open agent's own reads.
    rig.server.commands.clear();
    await tester.tap(find.byKey(const ValueKey('hda-row-w1:p1')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-detail')), findsOneWidget);
    expect(find.textContaining('Reading lib/main.dart'), findsOneWidget);
    expect(rig.server.readCalls, 1);
    expect(find.text('To reviewer · ~/proyectos/app'), findsOneWidget);

    // Back leaves the detail and stops reading its screen.
    await tester.tap(find.byKey(const ValueKey('hda-detail-back')));
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-detail')), findsNothing);
    final reads = server.readCalls;
    await tester.pump(const Duration(minutes: 1));
    expect(server.readCalls, reads);
  });

  testWidgets('a prompt goes to the open agent and the field clears', (
    tester,
  ) async {
    final server = _fake();
    await _open(tester, server: server);
    await tester.tap(find.byKey(const ValueKey('hda-row-w1:p1')));
    await tester.pump();
    await tester.pump();

    server.commands.clear();
    await tester.enterText(
      find.byKey(const ValueKey('hda-prompt-field')),
      "add tests; it's urgent",
    );
    await tester.tap(find.byKey(const ValueKey('hda-send')));
    await tester.pump();
    await tester.pump();

    final sent = server.herdrCalls
        .map(shellWords)
        .where((w) => w[2] == 'prompt')
        .toList();
    expect(sent, [
      [fakeHerdrPath, 'agent', 'prompt', 'w1:p1', "add tests; it's urgent"],
    ]);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('hda-prompt-field')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('nothing is sent for an empty prompt', (tester) async {
    final server = _fake();
    await _open(tester, server: server);
    await tester.tap(find.byKey(const ValueKey('hda-row-w1:p1')));
    await tester.pump();
    await tester.pump();
    server.commands.clear();
    await tester.tap(find.byKey(const ValueKey('hda-send')));
    await tester.pump();
    await tester.pump();
    expect(server.herdrCalls.where((c) => c.contains("'prompt'")), isEmpty);
  });

  testWidgets('a blocked agent: accept and reject send Enter and Esc', (
    tester,
  ) async {
    // A screen with no numbered options: Enter and Esc are all there is.
    final server = _fake()
      ..screens['w1:p2'] = 'Waiting for your decision\nPress a key';
    await _open(tester, server: server);
    await tester.tap(find.byKey(const ValueKey('hda-row-w1:p2')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('hda-blocked-card')), findsOneWidget);
    // The card does not promise that Enter means «yes».
    expect(find.textContaining('not always'), findsOneWidget);
    expect(find.text('Enter (highlighted)'), findsOneWidget);
    server.commands.clear();
    await tester.tap(find.byKey(const ValueKey('hda-accept')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('hda-reject')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('hda-keys')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hda-key-ctrlC')));
    await tester.pumpAndSettle();

    final keys = server.herdrCalls
        .map(shellWords)
        .where((w) => w[2] == 'send-keys')
        .map((w) => w.sublist(3))
        .toList();
    expect(keys, [
      ['w1:p2', 'enter'],
      ['w1:p2', 'esc'],
      ['w1:p2', 'ctrl+c'],
    ]);

    // A text to a blocked agent is refused by Herdr: nothing typed.
    await tester.enterText(
      find.byKey(const ValueKey('hda-prompt-field')),
      'go on',
    );
    await tester.tap(find.byKey(const ValueKey('hda-send')));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('hda-prompt-field')))
          .controller!
          .text,
      'go on',
    );
  });

  Future<void> openCreate(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('hda-new')));
    await tester.pumpAndSettle();
  }

  /// Picks `/srv` through the browser (home > up > srv).
  Future<void> pickFolderSrv(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('hda-create-folder-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hda-folder-home')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hda-folder-crumb-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hda-folder-dir-srv')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hda-folder-use')));
    await tester.pumpAndSettle();
  }

  testWidgets('creating an agent: one form, a short question, then it starts', (
    tester,
  ) async {
    // A harness that takes a few seconds, as a real one can.
    final server = _fake()
      ..startCommandAfter = const Duration(seconds: 3)
      ..agentAppearsAfter = const Duration(seconds: 3);
    final store = _Store();
    final rig = await _open(tester, server: server, store: store);
    server.commands.clear();

    await openCreate(tester);
    expect(find.byKey(const ValueKey('hda-create-dialog')), findsOneWidget);
    // Nothing chosen yet: «Start» waits for a folder.
    var start = tester.widget<HerdrGelButton>(
      find.byKey(const ValueKey('hda-create-start')),
    );
    expect(start.onTap, isNull);

    await tester.tap(find.byKey(const ValueKey('hda-kind-codex')));
    await tester.pump();
    await pickFolderSrv(tester);
    expect(find.text('/srv'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('hda-create-name')),
      'my work',
    );
    await tester.pump();
    start = tester.widget<HerdrGelButton>(
      find.byKey(const ValueKey('hda-create-start')),
    );
    expect(start.onTap, isNotNull);
    expect(_writes(server), isEmpty);

    await tester.tap(find.byKey(const ValueKey('hda-create-start')));
    await tester.pumpAndSettle();
    // One short line: what, where, on which server.
    expect(find.byKey(const ValueKey('hda-create-confirm')), findsOneWidget);
    expect(find.text('codex in /srv on $_server.'), findsOneWidget);
    expect(_writes(server), isEmpty);

    // Cancel: still nothing.
    await tester.tap(find.byKey(const ValueKey('hda-create-cancel')));
    await tester.pumpAndSettle();
    expect(_writes(server), isEmpty);
    expect(store.remembered, isEmpty);

    // Again, and confirm.
    await openCreate(tester);
    await tester.tap(find.byKey(const ValueKey('hda-kind-codex')));
    await pickFolderSrv(tester);
    await tester.enterText(
      find.byKey(const ValueKey('hda-create-name')),
      'my work',
    );
    await tester.tap(find.byKey(const ValueKey('hda-create-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hda-create-go')));
    await tester.pump();
    await tester.pump();

    final calls = _writes(server);
    expect(calls.first.sublist(1, 7), [
      'workspace',
      'create',
      '--cwd',
      '/srv',
      '--label',
      'my work',
    ]);
    expect(calls[1][2], 'start');
    expect(store.remembered, ['/srv']);
    expect(store.kind, 'codex');
    expect(rig.controller.startJobs, hasLength(1));
    // The row is there at once, with its spinner and «Starting…».
    expect(find.byKey(const ValueKey('hda-start-tile-w4:p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-start-spinner')), findsOneWidget);
    expect(find.textContaining('Starting…'), findsWidgets);
    // No alarm anywhere.
    expect(find.byKey(const ValueKey('hda-start-retry')), findsNothing);

    // And once the agent is in Herdr, the row is the agent's own.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-start-spinner')), findsNothing);
    expect(find.byKey(const ValueKey('hda-row-w4:p1')), findsOneWidget);
  });

  testWidgets('only the harnesses the server has can be chosen', (
    tester,
  ) async {
    final server = _fake()..harnesses = {'claude', 'hermes'};
    await _open(tester, server: server);
    await openCreate(tester);

    for (final kind in ['claude', 'hermes']) {
      final chip = tester.widget<HerdrGelButton>(
        find.byKey(ValueKey('hda-kind-$kind')),
      );
      expect(chip.onTap, isNotNull, reason: kind);
    }
    for (final kind in ['codex', 'opencode', 'gemini', 'pi', 'copilot']) {
      final chip = tester.widget<HerdrGelButton>(
        find.byKey(ValueKey('hda-kind-$kind')),
      );
      expect(chip.onTap, isNull, reason: kind);
    }
    expect(find.text('Not installed'), findsNWidgets(5));
    expect(find.byKey(const ValueKey('hda-harness-note')), findsOneWidget);

    // Installing one on the server and checking again enables it.
    server.harnesses.add('pi');
    await tester.tap(find.byKey(const ValueKey('hda-harness-refresh')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<HerdrGelButton>(find.byKey(const ValueKey('hda-kind-pi')))
          .onTap,
      isNotNull,
    );
    expect(find.text('Not installed'), findsNWidgets(4));
  });

  testWidgets('the last used harness is remembered and offered first', (
    tester,
  ) async {
    final server = _fake()..harnesses = {'claude', 'gemini'};
    final store = _Store()..kind = 'gemini';
    await _open(tester, server: server, store: store);
    await openCreate(tester);
    expect(
      tester
          .widget<HerdrGelButton>(find.byKey(const ValueKey('hda-kind-gemini')))
          .selected,
      isTrue,
    );
  });

  testWidgets('a chosen harness that is not there moves to one that is', (
    tester,
  ) async {
    final server = _fake()..harnesses = {'opencode'};
    final store = _Store()..kind = 'claude';
    await _open(tester, server: server, store: store);
    await openCreate(tester);
    expect(
      tester
          .widget<HerdrGelButton>(
            find.byKey(const ValueKey('hda-kind-opencode')),
          )
          .selected,
      isTrue,
    );
  });

  testWidgets('none installed: says so and cannot start', (tester) async {
    final server = _fake()..harnesses = {};
    await _open(tester, server: server);
    await openCreate(tester);
    expect(find.byKey(const ValueKey('hda-harness-none')), findsOneWidget);
    expect(
      tester
          .widget<HerdrGelButton>(
            find.byKey(const ValueKey('hda-create-start')),
          )
          .onTap,
      isNull,
    );
  });

  testWidgets('detection failed: every harness is offered, with a quiet note', (
    tester,
  ) async {
    final server = _fake()..harnessFails = true;
    await _open(tester, server: server);
    await openCreate(tester);
    expect(find.byKey(const ValueKey('hda-harness-failed')), findsOneWidget);
    for (final kind in ['claude', 'pi', 'copilot']) {
      expect(
        tester
            .widget<HerdrGelButton>(find.byKey(ValueKey('hda-kind-$kind')))
            .onTap,
        isNotNull,
      );
    }
    expect(find.text('Not installed'), findsNothing);
  });

  testWidgets('a start that fails for real says why, with retry and terminal', (
    tester,
  ) async {
    final server = _fake()
      ..startError = 'agent_start_timeout_0_9_5.json'
      ..agentAppearsAfter = null;
    final rig = await _open(tester, server: server);
    await rig.controller.createAgent(folder: '/srv', kind: 'pi');
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-start-spinner')), findsOneWidget);
    // Past the deadline, the next look turns it into the failure.
    for (var i = 0; i < 32; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump();
    expect(find.text('pi did not start'), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-start-spinner')), findsNothing);
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('hda-start-reason')),
          )
          .data,
      contains('pi: command not found'),
    );

    // «Open in terminal»: the workspace's focus, then Herdr.
    await tester.tap(find.byKey(const ValueKey('hda-start-terminal')));
    await tester.pump();
    expect(rig.typed.single, contains("workspace focus 'w4'"));

    // «Retry» starts it in the same workspace.
    server
      ..startError = null
      ..agentAppearsAfter = Duration.zero;
    await tester.tap(find.byKey(const ValueKey('hda-start-retry')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-start-retry')), findsNothing);
    expect(find.byKey(const ValueKey('hda-row-w4:p1')), findsOneWidget);
    expect(server.created.length, 1);
  });

  testWidgets('folders: grouped by working folder, whole path on hold', (
    tester,
  ) async {
    final rig = await _open(tester);
    // One heading per working folder, short; its whole path is its tooltip.
    expect(
      find.byKey(const ValueKey('hda-group-/home/demo/proyectos/app')),
      findsOneWidget,
    );
    expect(find.text('app'), findsWidgets);
    expect(find.text('logs'), findsWidgets);
    expect(find.byTooltip('/home/demo/proyectos/app'), findsOneWidget);
    // The folder with the agent that waits on you is first.
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey('hda-folder-/home/demo/proyectos/app')),
          )
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(
                const ValueKey('hda-folder-/home/demo/proyectos/logs'),
              ),
            )
            .dy,
      ),
    );
    // No cards: the rows are lines on the page.
    expect(find.byType(Card), findsNothing);
    // Workspaces with only shells are one folded line, not a heading each.
    expect(find.byKey(const ValueKey('hda-shells')), findsOneWidget);
    expect(find.text('Terminals only (1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-shell-w9')), findsNothing);
    await _reveal(tester, 'hda-shells-toggle');
    await tester.tap(find.byKey(const ValueKey('hda-shells-toggle')));
    await tester.pump();
    await tester.pump();
    await _reveal(tester, 'hda-shell-w9');
    await tester.tap(find.byKey(const ValueKey('hda-shell-w9')));
    await tester.pumpAndSettle();
    expect(rig.typed, [
      "'$fakeHerdrPath' workspace focus 'w9' >/dev/null 2>&1; "
          "'$fakeHerdrPath'",
    ]);
  });

  testWidgets('an agent opens in the terminal by its own pane id', (
    tester,
  ) async {
    final rig = await _open(tester);
    await tester.tap(find.byKey(const ValueKey('hda-row-w1:p1')));
    await tester.pump();
    await tester.pump();
    // The terminal is an item of the agent's menu, not a loose icon.
    await tester.tap(find.byKey(const ValueKey('hda-detail-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hda-detail-terminal')));
    await tester.pumpAndSettle();
    expect(rig.typed, ["'$fakeHerdrPath' agent attach 'w1:p1'"]);
  });

  testWidgets('search narrows the list; nothing found says so', (tester) async {
    await _open(tester);
    await tester.enterText(find.byKey(const ValueKey('hda-search')), 'logs');
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-row-w2:p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w1:p1')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('hda-search')), 'zzzz');
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-no-matches')), findsOneWidget);
  });

  testWidgets('a quiet card at the end for agents outside Herdr', (
    tester,
  ) async {
    final server = _fake()
      ..agents.clear()
      ..processes = const ['codex', 'codex'];
    final rig = await _open(tester, server: server, withProcesses: true);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-outside-processes')), findsOneWidget);
    expect(find.textContaining('codex ×2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hda-outside-open')));
    await tester.pump();
    expect(rig.typed, ["'$fakeHerdrPath'"]);
  });

  testWidgets('read only: no way to create, the output still shows', (
    tester,
  ) async {
    final server = _fake();
    final rig = await _open(tester, server: server, probeAsAlias: true);
    expect(rig.controller.canWrite, isFalse);
    expect(find.byKey(const ValueKey('hda-new')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('hda-row-w1:p1')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-read-only')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-prompt-field')), findsNothing);
  });

  group('the folder picker', () {
    Future<_Rig> openPicker(WidgetTester tester, {_Store? store}) async {
      final rig = await _open(
        tester,
        store: store,
        server: _fake()..harnesses = {'claude'},
      );
      await openCreate(tester);
      await tester.tap(find.byKey(const ValueKey('hda-create-folder-pick')));
      await tester.pumpAndSettle();
      return rig;
    }

    testWidgets('starts with home, where agents run and the recent ones', (
      tester,
    ) async {
      final store = _Store()..remembered.addAll(['/srv/old']);
      await openPicker(tester, store: store);
      expect(find.byKey(const ValueKey('hda-folder-home')), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('hda-folder-running-/home/demo/proyectos/app'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('hda-folder-recent-/srv/old')),
        findsOneWidget,
      );
      // Choosing a recent one answers at once.
      await tester.tap(
        find.byKey(const ValueKey('hda-folder-recent-/srv/old')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hda-folder-picker')), findsNothing);
      expect(find.text('/srv/old'), findsWidgets);
    });

    testWidgets('browse: breadcrumbs, filter, hidden folders, git badge', (
      tester,
    ) async {
      final rig = await openPicker(tester);
      await tester.tap(find.byKey(const ValueKey('hda-folder-home')));
      await tester.pumpAndSettle();
      expect(rig.folders.listed, ['/home/demo']);
      // Folders only, sorted, hidden ones out of the way.
      final names = [
        for (final name in ['alpha', 'proyectos', 'Zeta', '.config'])
          find.byKey(ValueKey('hda-folder-dir-$name')).evaluate().isNotEmpty,
      ];
      expect(names, [true, true, true, false]);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('hda-folder-dir-alpha')))
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('hda-folder-dir-proyectos')),
              )
              .dy,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('hda-folder-hidden')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('hda-folder-dir-.config')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('hda-folder-dir-proyectos')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hda-folder-dir-app')));
      await tester.pumpAndSettle();
      // This one is a repository.
      expect(find.byKey(const ValueKey('hda-folder-git')), findsOneWidget);
      expect(find.byKey(const ValueKey('hda-folder-dir-lib')), findsOneWidget);

      // The breadcrumb goes back up; there the badge is gone.
      await tester.tap(find.byKey(const ValueKey('hda-folder-crumb-3')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hda-folder-git')), findsNothing);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('hda-folder-filter')),
          matching: find.byType(TextField),
        ),
        'we',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('hda-folder-dir-web')), findsOneWidget);
      expect(find.byKey(const ValueKey('hda-folder-dir-app')), findsNothing);
      // «Up» goes to the parent.
      await tester.tap(find.byKey(const ValueKey('hda-folder-up')));
      await tester.pumpAndSettle();
      expect(rig.folders.listed.last, '/home/demo');
    });

    testWidgets('«new folder here» validates the name and creates by SFTP', (
      tester,
    ) async {
      final rig = await openPicker(tester);
      await tester.tap(find.byKey(const ValueKey('hda-folder-home')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hda-folder-new')));
      await tester.pumpAndSettle();

      Future<void> tryName(String name, String message) async {
        await tester.enterText(
          find.byKey(const ValueKey('hda-folder-new-name')),
          name,
        );
        await tester.tap(find.byKey(const ValueKey('hda-folder-new-go')));
        await tester.pump();
        expect(find.text(message), findsOneWidget, reason: name);
        expect(rig.folders.made, isEmpty, reason: name);
      }

      await tryName('   ', 'Write a name.');
      await tryName('a/b', r'The name cannot contain / or \.');
      await tryName(r'a\b', r'The name cannot contain / or \.');
      await tryName('..', 'The name cannot be . or ..');
      await tryName('.', 'The name cannot be . or ..');
      await tryName('a\u0000b', 'The name has control characters.');
      await tryName('x' * 200, 'The name is too long.');

      // A good one is made under the folder being browsed, and opened.
      await tester.enterText(
        find.byKey(const ValueKey('hda-folder-new-name')),
        'new project',
      );
      await tester.tap(find.byKey(const ValueKey('hda-folder-new-go')));
      await tester.pumpAndSettle();
      expect(rig.folders.made, ['/home/demo/new project']);
      expect(rig.folders.listed.last, '/home/demo/new project');
      await tester.tap(find.byKey(const ValueKey('hda-folder-use')));
      await tester.pumpAndSettle();
      expect(find.text('~/new project'), findsWidgets);
    });

    testWidgets('a folder that cannot be created says so and stays', (
      tester,
    ) async {
      final rig = await openPicker(tester);
      await tester.tap(find.byKey(const ValueKey('hda-folder-home')));
      await tester.pumpAndSettle();
      rig.folders.failMkdir = true;
      await tester.tap(find.byKey(const ValueKey('hda-folder-new')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('hda-folder-new-name')),
        'x',
      );
      await tester.tap(find.byKey(const ValueKey('hda-folder-new-go')));
      await tester.pumpAndSettle();
      expect(find.text('Could not create the folder.'), findsOneWidget);
      expect(find.byKey(const ValueKey('hda-folder-picker')), findsOneWidget);
    });

    testWidgets('pin and unpin: favourites come first next time', (
      tester,
    ) async {
      final store = _Store();
      await openPicker(tester, store: store);
      await tester.tap(find.byKey(const ValueKey('hda-folder-home')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hda-folder-dir-proyectos')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hda-folder-star')));
      await tester.pump();
      expect(store.pinned, ['/home/demo/proyectos']);

      // Back at the starting points the pinned folder is listed; one tap
      // chooses it.
      await tester.tap(find.byKey(const ValueKey('hda-folder-crumb-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hda-folder-up')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('hda-folder-fav-/home/demo/proyectos')),
        findsOneWidget,
      );
      // Unpin from the browser.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('hda-folder-fav-/home/demo/proyectos')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hda-folder-star')));
      await tester.pump();
      expect(store.pinned, isEmpty);
    });

    testWidgets(
      'a typed path is checked: missing is refused, a folder passes',
      (tester) async {
        await openPicker(tester);
        await tester.tap(find.byKey(const ValueKey('hda-folder-advanced')));
        await tester.pumpAndSettle();
        Future<void> typePath(String path) async {
          await tester.enterText(
            find.byKey(const ValueKey('hda-folder-path-field')),
            path,
          );
          await tester.tap(find.byKey(const ValueKey('hda-folder-path-go')));
          await tester.pumpAndSettle();
        }

        await typePath('relative/dir');
        expect(
          find.text('Enter an absolute folder that starts with /.'),
          findsOneWidget,
        );
        await typePath('/does/not/exist');
        expect(
          find.text('That path is not a folder on the server.'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('hda-folder-picker')), findsOneWidget);
        await typePath('/home/demo/proyectos/web/');
        expect(find.byKey(const ValueKey('hda-folder-picker')), findsNothing);
        expect(find.text('~/proyectos/web'), findsWidgets);
      },
    );

    testWidgets('an unreadable folder offers a retry', (tester) async {
      final rig = await openPicker(tester);
      rig.folders.failList = true;
      await tester.tap(find.byKey(const ValueKey('hda-folder-home')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hda-folder-error')), findsOneWidget);
      rig.folders.failList = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('hda-folder-dir-alpha')),
        findsOneWidget,
      );
    });
  });

  group('layouts', () {
    for (final width in [360.0, 600.0, 840.0, 1100.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('${width.toInt()} dp at ${scale}x: list, detail, sheets', (
          tester,
        ) async {
          recordReports();
          final rig = await _open(
            tester,
            size: Size(width, 760),
            textScale: scale,
          );
          noException(tester, 'layout step 1');
          final wide = width >= 600;
          // The header holds the server and its actions on one line, nothing
          // over it.
          final header = tester.getRect(
            find.byKey(const ValueKey('hda-server-name')),
          );
          final menu = tester.getRect(find.byKey(const ValueKey('hda-menu')));
          expect(menu.left, greaterThanOrEqualTo(header.left));
          expect(
            (menu.center.dy - header.center.dy).abs(),
            lessThan(48 * scale),
          );

          // At large text the row may sit below the fold: scroll to it.
          await _reveal(tester, 'hda-row-w1:p1');
          await tester.tap(find.byKey(const ValueKey('hda-row-w1:p1')));
          await tester.pump();
          await tester.pump();
          noException(tester, 'layout step 2');
          if (wide) {
            // Two panes: the list stays, the output sits to its right.
            expect(find.byKey(const ValueKey('hda-row-w1:p1')), findsOneWidget);
            final list = tester.getRect(
              find.byKey(const ValueKey('hda-scroll')),
            );
            expect(list.width, inInclusiveRange(300, 380));
            expect(
              tester.getRect(find.byKey(const ValueKey('hda-detail'))).left,
              greaterThan(list.right - 1),
            );
            // The list is beside the agent: no second back arrow.
            expect(find.byKey(const ValueKey('hda-detail-back')), findsNothing);
          } else {
            // One pane: the detail has the screen, with its back button.
            expect(find.byKey(const ValueKey('hda-row-w1:p1')), findsNothing);
            expect(
              find.byKey(const ValueKey('hda-detail-back')),
              findsOneWidget,
            );
          }
          // The instruction field is on screen and not covered.
          final field = tester.getRect(
            find.byKey(const ValueKey('hda-prompt-field')),
          );
          expect(field.bottom, lessThanOrEqualTo(760));
          expect(field.width, greaterThan(100));

          rig.controller.closeDetail();
          await tester.pump();
          await openCreate(tester);
          noException(tester, 'layout step 3');
          // The form scrolls at large text: bring the field into view.
          await tester.ensureVisible(
            find.byKey(const ValueKey('hda-create-folder-pick')),
          );
          await tester.pump();
          await tester.tap(
            find.byKey(const ValueKey('hda-create-folder-pick')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('hda-folder-home')));
          await tester.pumpAndSettle();
          noException(tester, 'layout step 4');
          expect(
            tester.getRect(find.byKey(const ValueKey('hda-folder-use'))).right,
            lessThanOrEqualTo(width),
          );
        });
      }
    }
  });

  for (final entry in {
    'dark': AppTheme.hermesRedDark,
    'light': AppTheme.hermesRedLight,
  }.entries) {
    testWidgets('${entry.key}: list, detail and hint at 2x text in 320 dp', (
      tester,
    ) async {
      final rig = await _open(
        tester,
        theme: entry.value,
        textScale: 2,
        size: const Size(320, 700),
      );
      expect(tester.takeException(), isNull);

      rig.controller.openDetail('w1:p2');
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('hda-detail')), findsOneWidget);
      rig.controller.closeDetail();
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      final bare = await _open(
        tester,
        server: _fake()..installed = false,
        theme: entry.value,
        textScale: 2,
        size: const Size(320, 700),
      );
      expect(bare.controller.phase, HerdrAgentsPhase.notInstalled);
      await tester.tap(find.byKey(const ValueKey('hda-install-how')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('hda-install-close')));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('every language renders the list without overflow', (
    tester,
  ) async {
    for (final language in ['es', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
      await _open(
        tester,
        locale: Locale(language),
        textScale: 1.6,
        size: const Size(360, 800),
      );
      expect(tester.takeException(), isNull, reason: language);
      await tester.pumpWidget(const SizedBox());
    }
  });

  test('duration words: now, minutes, hours, days', () {
    final s = lookupStrings(const Locale('en'));
    expect(hdaDurationText(s, const Duration(seconds: 20)), 'Just now');
    expect(hdaDurationText(s, const Duration(minutes: 5)), '5m');
    expect(hdaDurationText(s, const Duration(hours: 3)), '3h');
    expect(hdaDurationText(s, const Duration(days: 2)), '2d');
  });
}
