import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/subagent_child_session.dart';
import 'package:hermes_android/core/services/subagent_live_watch.dart';
import 'package:hermes_android/core/services/subagent_tail_log.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart'
    show SubagentTailView;
import 'package:hermes_android/core/widgets/subagent_stream_view.dart'
    show SubagentTailToolRow;
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_subagent_watch_gateway.dart';
import 'support/inter_font.dart';

// A running child read from its own stored session (fake REST) while the
// live mirror (fake gateway) says little: the case the device harness SC4
// showed as one frozen row over an empty page.

const String _goal =
    'Ejecuta exactamente for i in 1 2 3; do echo paso \$i; sleep 10; done '
    'usando terminal en primer plano.';
const String _command = r'for i in 1 2 3; do echo paso $i; sleep 10; done';
const double _t0 = 1762628000;

final SubagentActivityScope _scope = SubagentActivityScope(
  connectionId: 'connection-child',
  parentSessionId: 'parent-child',
  runtimeSessionId: 'runtime-child',
  turnEpoch: 1,
);

SubagentActivity _child({
  SubagentActivityPhase phase = SubagentActivityPhase.running,
  String? childSessionId = watchTestChild,
  String goal = _goal,
}) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: 'sa-0-child',
  ),
  source: SubagentActivitySource.native,
  phase: phase,
  subagentId: 'sa-0-child',
  childSessionId: childSessionId,
  details: SubagentActivityDetails(goalPreview: goal),
);

Map<String, dynamic> _user(String text, {int id = 1}) => {
  'id': id,
  'role': 'user',
  'content': text,
  'timestamp': _t0,
};

Map<String, dynamic> _call(
  int id,
  String callId,
  String command, {
  double at = _t0 + 1,
  String text = '',
}) => {
  'id': id,
  'role': 'assistant',
  'content': text,
  'tool_calls': [
    {
      'id': callId,
      'type': 'function',
      'function': {
        'name': 'terminal',
        'arguments': jsonEncode({'command': command, 'timeout': 150}),
      },
    },
  ],
  'timestamp': at,
};

Map<String, dynamic> _result(
  int id,
  String callId,
  String output, {
  int exit = 0,
  double at = _t0 + 13,
}) => {
  'id': id,
  'role': 'tool',
  'tool_call_id': callId,
  'content': jsonEncode({'output': output, 'exit_code': exit, 'error': null}),
  'timestamp': at,
};

Map<String, dynamic> _say(int id, String text, {double at = _t0 + 14}) => {
  'id': id,
  'role': 'assistant',
  'content': text,
  'timestamp': at,
};

List<Map<String, dynamic>> get _started => [
  _user(_goal),
  _call(2, 'call-1', _command, text: 'Lo ejecuto.'),
];

List<Map<String, dynamic>> get _progressed => [
  ..._started,
  _result(3, 'call-1', 'paso 1\npaso 2\npaso 3'),
  _say(4, 'Ahora listo los ficheros.'),
  _call(5, 'call-2', 'ls -la /tmp', at: _t0 + 15),
];

/// Lets a route transition and pending reads finish. Not pumpAndSettle: a
/// running call's clock ticks every second.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

/// Timers the code under test asked for; tests fire them by hand.
class _Timers {
  final List<(Duration, VoidCallback)> pending = [];

  VoidCallback schedule(Duration delay, VoidCallback callback) {
    final entry = (delay, callback);
    pending.add(entry);
    return () => pending.remove(entry);
  }

  /// Fires the oldest pending timer (it removes itself first).
  void fire() {
    final entry = pending.removeAt(0);
    entry.$2();
  }
}

void main() {
  group('child session as rows', () {
    test('goal, words, a finished call with output and a running call', () {
      final transcript = subagentChildTranscript(_progressed);
      expect(transcript.goal, _goal);
      final kinds = [for (final e in transcript.entries) e.kind];
      expect(kinds, [
        SubagentTailKind.text,
        SubagentTailKind.tool,
        SubagentTailKind.text,
        SubagentTailKind.tool,
      ]);
      final done = transcript.entries[1];
      expect(done.id, 'child-call-call-1');
      expect(done.command, _command);
      expect(done.finished, isTrue);
      expect(done.failed, isFalse);
      expect(done.exitCode, 0);
      expect(done.output, 'paso 1\npaso 2\npaso 3');
      expect(done.durationSeconds, closeTo(12, .001));
      final running = transcript.runningTool!;
      expect(running.id, 'child-call-call-2');
      expect(running.finished, isFalse);
      expect(
        transcript.startedAt[running.id],
        DateTime.fromMillisecondsSinceEpoch(
          ((_t0 + 15) * 1000).round(),
          isUtc: true,
        ),
      );
      expect(transcript.callIds[running.id], 'call-2');
    });

    test('masks secrets, drops reasoning and compacted rows', () {
      final transcript = subagentChildTranscript([
        _user(_goal),
        {
          'id': 2,
          'role': 'assistant',
          'content': '',
          'reasoning': 'pienso en el token sk-abcdefghijklmnop',
          'tool_calls': [
            {
              'id': 'c',
              'function': {
                'name': 'terminal',
                'arguments': jsonEncode({
                  'command': 'curl -H "Authorization: Bearer abc123def456" x',
                }),
              },
            },
          ],
        },
        {'id': 3, 'role': 'assistant', 'content': 'viejo', 'active': false},
        _result(
          4,
          'c',
          'API_KEY=sk-abcdefghijklmnopqrstuv\nhecho',
          exit: 2,
        ),
      ]);
      expect(transcript.entries, hasLength(1));
      final call = transcript.entries.single;
      expect(call.command, isNot(contains('abc123def456')));
      expect(call.output, isNot(contains('sk-abcdefghijklmnopqrstuv')));
      expect(call.output, contains('hecho'));
      expect(call.failed, isTrue);
      expect(call.exitCode, 2);
      expect(
        transcript.entries.any((e) => e.text.contains('pienso')),
        isFalse,
      );
    });

    test('same rows read twice sign the same; a new row signs anew', () {
      final a = subagentChildTranscript(_started);
      final b = subagentChildTranscript(_started);
      final c = subagentChildTranscript(_progressed);
      expect(a.signature, b.signature);
      expect(a.signature, isNot(c.signature));
    });
  });

  group('merge with the live sources', () {
    test('a log call already stored is one row; its end is taken', () {
      final stored = subagentChildTranscript(_started);
      final tail = parseSubagentTailLog(
        '10:00:01 tool     | -> terminal(for i in 1 2 3 + 3 comandos)\n'
        '10:00:13 result   | terminal ok 12.0s: {"output": "paso 1", '
        '"exit_code": 0}\n'
        '10:00:15 tool     | -> terminal(ls -la /tmp)',
      );
      final rows = mergeSubagentChildRows(stored, tail: tail);
      final tools = [
        for (final r in rows)
          if (r.kind == SubagentTailKind.tool) r,
      ];
      expect(tools, hasLength(2));
      expect(tools.first.id, 'child-call-call-1');
      expect(tools.first.finished, isTrue);
      expect(tools.first.output, 'paso 1');
      // Newer than the snapshot: shown until the next read stores it.
      expect(tools.last.command, 'ls -la /tmp');
      expect(tools.last.finished, isFalse);
    });

    test('a mirrored tool with a stored call id is not a second row', () {
      final stored = subagentChildTranscript(_started);
      final rows = mergeSubagentChildRows(
        stored,
        watch: [
          SubagentWatchBlock.tool(
            const SubagentWatchTool(
              id: 'call-1',
              name: 'terminal',
              preview: 'for i in 1 2 3',
            ),
          ),
          SubagentWatchBlock.tool(
            const SubagentWatchTool(id: 'call-9', name: 'read_file'),
          ),
        ],
      );
      final tools = [
        for (final r in rows)
          if (r.kind == SubagentTailKind.tool) r.id,
      ];
      expect(tools, ['child-call-call-1', 'watch-call-9']);
    });
  });

  group('merge: one row per call', () {
    test('mirror ids that differ from the stored ones are the same calls', () {
      final stored = subagentChildTranscript([
        _user(_goal),
        _call(2, 'call-1', 'echo paso1; sleep 10'),
        _result(3, 'call-1', 'paso1'),
        _call(4, 'call-2', 'echo paso2; sleep 10', at: _t0 + 15),
      ]);
      final rows = mergeSubagentChildRows(
        stored,
        watch: [
          SubagentWatchBlock.tool(
            const SubagentWatchTool(
              id: 'm-1',
              name: 'terminal',
              preview: 'echo paso1; sleep 10',
            ),
          ),
          SubagentWatchBlock.tool(
            const SubagentWatchTool(
              id: 'm-2',
              name: 'terminal',
              preview: 'echo paso2; sleep 10',
            ),
          ),
          SubagentWatchBlock.tool(
            const SubagentWatchTool(
              id: 'm-3',
              name: 'terminal',
              preview: 'echo paso3; sleep 10',
            ),
          ),
        ],
      );
      expect([
        for (final r in rows)
          if (r.kind == SubagentTailKind.tool) r.id,
      ], ['child-call-call-1', 'child-call-call-2', 'watch-m-3']);
    });

    test('a call seen by the log and the mirror before it is stored is one',
        () {
      final stored = subagentChildTranscript(_started);
      final tail = parseSubagentTailLog(
        '10:00:01 tool     | -> terminal(for i in 1 2 3 + 3 comandos)\n'
        '10:00:15 tool     | -> terminal(ls -la /tmp)',
      );
      final rows = mergeSubagentChildRows(
        stored,
        tail: tail,
        watch: [
          SubagentWatchBlock.tool(
            const SubagentWatchTool(
              id: 'm-2',
              name: 'terminal',
              preview: 'ls -la /tmp',
            ),
          ),
        ],
      );
      expect(
        [
          for (final r in rows)
            if (r.kind == SubagentTailKind.tool) r.command,
        ],
        [_command, 'ls -la /tmp'],
      );
    });
  });

  group('feed', () {
    late _Timers timers;
    late List<List<Map<String, dynamic>>> answers;
    late int reads;
    Object? failWith;

    setUp(() {
      timers = _Timers();
      answers = [_started];
      reads = 0;
      failWith = null;
    });

    SubagentChildFeed feed({SubagentChildSessionResolver? resolve}) {
      final feed = SubagentChildFeed(
        read: (id) async {
          reads++;
          final error = failWith;
          if (error != null) throw error;
          return answers.length > 1 ? answers.removeAt(0) : answers.first;
        },
        resolve: resolve,
        schedule: timers.schedule,
      );
      addTearDown(feed.dispose);
      return feed;
    }

    test('reads at once, every 2 s, and notifies only on change', () async {
      final subject = feed();
      var notified = 0;
      subject.addListener(() => notified++);
      subject.sync(activity: _child(), visible: true);
      await pumpEventQueue();
      expect(reads, 1);
      expect(subject.value.status, SubagentChildFeedStatus.live);
      expect(subject.value.transcript.entries, hasLength(2));
      final afterFirst = notified;
      expect(timers.pending.single.$1, const Duration(seconds: 2));

      timers.fire();
      await pumpEventQueue();
      expect(reads, 2);
      expect(notified, afterFirst, reason: 'nothing changed: no repaint');

      answers = [_progressed];
      timers.fire();
      await pumpEventQueue();
      expect(reads, 3);
      expect(notified, afterFirst + 1);
      expect(subject.value.transcript.entries, hasLength(4));
    });

    test('backs off on errors and keeps what it read', () async {
      final subject = feed();
      subject.sync(activity: _child(), visible: true);
      await pumpEventQueue();
      final kept = subject.value.transcript;
      failWith = StateError('offline');
      timers.fire();
      await pumpEventQueue();
      expect(timers.pending.single.$1, const Duration(seconds: 4));
      timers.fire();
      await pumpEventQueue();
      expect(timers.pending.single.$1, const Duration(seconds: 8));
      expect(subject.value.transcript, same(kept));
      failWith = null;
      timers.fire();
      await pumpEventQueue();
      expect(timers.pending.single.$1, const Duration(seconds: 2));
    });

    test('stops when hidden, resumes at once, stops on dispose', () async {
      final subject = SubagentChildFeed(
        read: (id) async {
          reads++;
          return _started;
        },
        schedule: timers.schedule,
      );
      subject.sync(activity: _child(), visible: true);
      await pumpEventQueue();
      expect(timers.pending, hasLength(1));
      subject.sync(activity: _child(), visible: false);
      expect(timers.pending, isEmpty);
      expect(subject.active, isFalse);
      subject.sync(activity: _child(), visible: true);
      await pumpEventQueue();
      expect(reads, 2);
      subject.dispose();
      expect(timers.pending, isEmpty);
      await pumpEventQueue();
      expect(reads, 2);
    });

    test('reads once more when the child ends, then stops', () async {
      final subject = feed();
      subject.sync(activity: _child(), visible: true);
      await pumpEventQueue();
      answers = [_progressed];
      subject.sync(
        activity: _child(phase: SubagentActivityPhase.completed),
        visible: true,
      );
      await pumpEventQueue();
      expect(reads, 2);
      expect(subject.value.transcript.entries, hasLength(4));
      expect(timers.pending, isEmpty);
      expect(subject.active, isFalse);
    });

    test('unknown id waits, a sibling found by search is refused, then '
        'the roster id is read', () async {
      var resolves = 0;
      final subject = feed(
        resolve: (_) async {
          resolves++;
          return 'sibling';
        },
      );
      answers = [
        [_user('Otra tarea distinta que hace un hermano del subagente')],
        _started,
      ];
      subject.sync(activity: _child(childSessionId: null), visible: true);
      await pumpEventQueue();
      expect(resolves, 1);
      expect(subject.value.status, SubagentChildFeedStatus.waiting);
      expect(subject.value.hasRows, isFalse);
      subject.sync(activity: _child(), visible: true);
      await pumpEventQueue();
      expect(subject.childSessionId, watchTestChild);
      expect(subject.value.status, SubagentChildFeedStatus.live);
      expect(subject.value.hasRows, isTrue);
    });
  });

  group('detail page', () {
    setUpAll(loadInterFont);

    late _Timers timers;
    late ValueNotifier<List<SubagentActivity>> roster;
    late List<Map<String, dynamic>> stored;
    late int reads;
    late FakeWatchGateway gateway;

    Future<void> pumpPage(
      WidgetTester tester, {
      SubagentActivity? activity,
      bool withWatch = false,
      String? tailLog,
    }) async {
      tester.view.physicalSize = const Size(960, 2142);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      timers = _Timers();
      reads = 0;
      gateway = FakeWatchGateway();
      final subject = activity ?? _child();
      roster = ValueNotifier([subject]);
      addTearDown(roster.dispose);
      final observer = RouteObserver<PageRoute<dynamic>>();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          navigatorObservers: [observer],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-detail'),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => SubagentDetailScreen(
                      roster: roster,
                      activityKey: subject.key,
                      parentTitle: 'Chat de prueba',
                      canTail: (_) => tailLog != null,
                      onTail: tailLog == null
                          ? null
                          : (_) async => SubagentTailView(
                              available: true,
                              content: tailLog,
                              truncated: false,
                            ),
                      scheduleTailPoll: timers.schedule,
                      openLiveWatch: (_) => withWatch
                          ? SubagentLiveWatch(
                              gateway: gateway,
                              childSessionId: watchTestChild,
                              profile: 'p',
                              isCurrent: () => true,
                              childIsLive: () =>
                                  subagentIsLive(roster.value.single),
                            )
                          : null,
                      readChildMessages: (id) async {
                        reads++;
                        return [...stored];
                      },
                      clock: () => DateTime.fromMillisecondsSinceEpoch(
                        ((_t0 + 40) * 1000).round(),
                        isUtc: true,
                      ),
                      routeObserver: observer,
                    ),
                  ),
                ),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-detail')));
      await _settle(tester);
    }

    testWidgets('renders the child session from the top and grows with it', (
      tester,
    ) async {
      stored = _started;
      await pumpPage(tester);
      expect(reads, 1);

      // Its task, its words and the running call with its command.
      expect(find.text(_goal), findsWidgets);
      expect(find.text('Lo ejecuto.'), findsOneWidget);
      const callRow = ValueKey('subagent-tail-child-call-call-1');
      expect(find.byKey(callRow), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subagent-tail-command-child-call-call-1')),
        findsOneWidget,
      );
      expect(find.text('Ejecutando comando'), findsOneWidget);
      // The header line says what it does now and on what.
      final now = find.byKey(const ValueKey('subagent-detail-now'));
      expect(now, findsOneWidget);
      expect(
        find.descendant(
          of: now,
          matching: find.textContaining('Usando terminal'),
        ),
        findsOneWidget,
      );

      // Top-aligned: the first row sits right under the header line, not
      // at the bottom of an empty page.
      final barBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
      final nowBottom = tester.getBottomLeft(now).dy;
      final firstTop = tester
          .getTopLeft(find.byKey(const ValueKey('subagent-prompt-toggle')))
          .dy;
      expect(nowBottom - barBottom, lessThan(48));
      expect(firstTop - nowBottom, inInclusiveRange(0, 40));
      expect(tester.getTopLeft(find.byKey(callRow)).dy, lessThan(firstTop + 400));

      // The session gains rows: the next refresh paints them.
      stored = _progressed;
      expect(timers.pending.single.$1, SubagentDetailScreen.childRefresh);
      timers.fire();
      await tester.pump();
      await tester.pump();
      expect(reads, 2);
      expect(find.text('Comando ejecutado'), findsOneWidget);
      expect(find.textContaining('paso 1'), findsOneWidget);
      expect(find.text('Ahora listo los ficheros.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subagent-tail-child-call-call-2')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: now, matching: find.textContaining('ls -la /tmp')),
        findsOneWidget,
      );

      // Leaving the page stops the refresh.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await _settle(tester);
      expect(timers.pending, isEmpty);
      final before = reads;
      await tester.pump(const Duration(seconds: 10));
      expect(reads, before);
    });

    testWidgets('a covered page stops reading and reads again on return', (
      tester,
    ) async {
      stored = _started;
      await pumpPage(tester);
      expect(timers.pending, hasLength(1));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('otra'))),
      );
      await _settle(tester);
      expect(timers.pending, isEmpty);
      navigator.pop();
      await _settle(tester);
      expect(reads, 2);
      expect(timers.pending, hasLength(1));
    });

    testWidgets('a mirrored tool and its stored call are one row', (
      tester,
    ) async {
      stored = _started;
      await pumpPage(tester, withWatch: true);
      gateway.emit('watch-1', 'tool.start', {
        'name': 'terminal',
        'tool_call_id': 'call-1',
        'preview': 'for i in 1 2 3',
      });
      await tester.pump();
      expect(
        find.byKey(const ValueKey('subagent-tail-child-call-call-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('subagent-stream-tool-call-1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('subagent-tail-watch-call-1')),
        findsNothing,
      );
      expect(find.text('Ejecutando comando'), findsOneWidget);
    });

    // Live detail: one representation of the tools (the child's chat rows).
    List<Map<String, dynamic>> twoTools() => [
      _user(_goal),
      _call(2, 'call-1', 'echo paso1; sleep 10'),
      _result(3, 'call-1', 'paso1'),
      _call(4, 'call-2', 'echo paso2; sleep 10', at: _t0 + 15),
    ];

    void expectOneRowPerTool(WidgetTester tester) {
      expect(
        find.byKey(const ValueKey('subagent-tail-child-call-call-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('subagent-tail-child-call-call-2')),
        findsOneWidget,
      );
      // Nothing but the two rows of the child's chat: no compact copy.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is SubagentTailToolRow &&
              !(w.key as ValueKey<String>).value.contains('child-call-'),
        ),
        findsNothing,
      );
      expect(find.byType(SubagentTailToolRow), findsNWidgets(2));
      expect(find.textContaining('+ 1 comando'), findsNothing);
      expect(find.textContaining('echo paso1'), findsOneWidget);
      expect(find.textContaining('echo paso2'), findsWidgets);
      expect(find.text('Ejecutando comando'), findsOneWidget);
      expect(find.text('Comando ejecutado'), findsOneWidget);
    }

    testWidgets('live: mirrored tools with their own ids are not a second '
        'list', (tester) async {
      stored = twoTools();
      await pumpPage(tester, withWatch: true);
      gateway.emit('watch-1', 'tool.start', {
        'name': 'terminal',
        'tool_id': 'mirror-a',
        'preview': 'echo paso1; sleep 10',
      });
      gateway.emit('watch-1', 'tool.start', {
        'name': 'terminal',
        'tool_id': 'mirror-b',
        'preview': 'echo paso2; sleep 10',
      });
      await tester.pump();
      expectOneRowPerTool(tester);
    });

    testWidgets('live: the polled log of the same calls is not a second '
        'list', (tester) async {
      stored = twoTools();
      await pumpPage(
        tester,
        tailLog:
            '10:00:01 tool     | -> terminal(echo paso1 + 1 comando)\n'
            '10:00:13 result   | terminal ok 12.0s: {"output": "paso1", '
            '"exit_code": 0}\n'
            '10:00:15 tool     | -> terminal(echo paso2 + 1 comando)',
      );
      await tester.pump();
      expectOneRowPerTool(tester);
    });

    testWidgets('without its id yet it says it waits, then shows it', (
      tester,
    ) async {
      stored = _started;
      await pumpPage(tester, activity: _child(childSessionId: null));
      expect(reads, 0);
      expect(find.text('Esperando al subagente…'), findsOneWidget);
      roster.value = [_child()];
      await tester.pump();
      await tester.pump();
      expect(reads, 1);
      expect(find.text('Esperando al subagente…'), findsNothing);
      expect(
        find.byKey(const ValueKey('subagent-tail-child-call-call-1')),
        findsOneWidget,
      );
    });

    testWidgets('another opener never reads the child session', (
      tester,
    ) async {
      stored = _started;
      tester.view.physicalSize = const Size(960, 2142);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      timers = _Timers();
      reads = 0;
      final subject = _child();
      roster = ValueNotifier([subject]);
      addTearDown(roster.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: SubagentDetailScreen(
            roster: roster,
            activityKey: subject.key,
            parentTitle: 'Chat',
            hideGoal: true,
            canTail: (_) => false,
            scheduleTailPoll: timers.schedule,
            openLiveWatch: (_) => null,
            readChildMessages: (id) async {
              reads++;
              return stored;
            },
            routeObserver: RouteObserver<PageRoute<dynamic>>(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(reads, 0);
      expect(find.text('Lo ejecuto.'), findsNothing);
      expect(find.byKey(const ValueKey('subagent-detail-now')), findsNothing);
    });
  });
}
