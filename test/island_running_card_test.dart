import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/core/widgets/island_card.dart';
import 'package:hermes_android/core/widgets/running_work.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart' show loadDesignFonts;

// The island is the home of what a conversation has alive outside its turn:
// with nothing alive it is only the name and a tap does nothing; with
// something alive it says how many and a tap grows it into a card with one
// row per thing.

const _statusBar = 38.0;
const _composerHeight = 72.0;
final _t0 = DateTime(2026, 10, 12, 20, 39);

final _alive = ValueNotifier<ActivitySnapshot>(ActivitySnapshot.idle);
final _clock = ValueNotifier<DateTime>(_t0);
var _transcriptBuilds = 0;
final _stopped = <String>[];
final _opened = <String?>[];
var _goalPaused = 0;
var _goalOpened = 0;

final _scope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

SubagentActivity _sub(String id, String goal) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: id,
  ),
  source: SubagentActivitySource.native,
  phase: SubagentActivityPhase.tool,
  subagentId: id,
  details: SubagentActivityDetails(
    goalPreview: goal,
    startedAt: _t0.subtract(const Duration(seconds: 5)),
  ),
);

SessionActivityProcess _process(String id, String command) =>
    SessionActivityProcess(
      id: id,
      command: command,
      notifyOnComplete: false,
      startedAt: _t0.subtract(const Duration(seconds: 12)),
    );

final _loop = SessionActivitySchedule(
  kind: SessionActivityScheduleKind.loop,
  status: 'active',
  interval: const Duration(hours: 24),
  lastRunAt: null,
  nextDueAt: _t0.add(const Duration(hours: 10)),
  runCount: 2,
);

const _goal = SessionActivityGoal(title: 'Publicar 1.2.15', status: 'active');

ActivitySnapshot _one() =>
    ActivitySnapshot(processes: [_process('p1', 'sleep 20 && echo listo')]);

ActivitySnapshot _four() => ActivitySnapshot(
  processes: [_process('p1', 'sleep 20 && echo listo')],
  subagents: [_sub('s1', 'Revisar el kernel')],
  schedules: [_loop],
  goal: _goal,
);

ActivitySnapshot _six() => ActivitySnapshot(
  processes: [
    _process('p1', 'sleep 20 && echo listo'),
    _process('p2', 'npm run dev'),
  ],
  subagents: [_sub('s1', 'Revisar el kernel'), _sub('s2', 'Revisar el disco')],
  schedules: [_loop],
  goal: _goal,
);

/// What the island says it has to open, as the chat words it.
String? _mark(ActivitySnapshot value) {
  final alive = RunningWork.aliveCount(value);
  if (alive > 0) return '$alive en marcha';
  final ended = RunningWork.endedCount(value);
  return ended > 0 ? '$ended terminado' : null;
}

/// The chat's transcript: nothing the island or its card does may rebuild it.
class _Transcript extends StatelessWidget {
  const _Transcript();

  @override
  Widget build(BuildContext context) {
    _transcriptBuilds++;
    return ListView(
      children: [
        for (var i = 0; i < 30; i++)
          SizedBox(height: 48, child: Text('Mensaje $i')),
      ],
    );
  }
}

/// A chat reduced to what the island lives with, wired as the chat wires
/// it: the count on the island while something is alive, and the card.
class _Chat extends StatelessWidget {
  const _Chat();

  static final _islandKey = GlobalKey(debugLabel: 'test-island');

  void _open(BuildContext context) => showRunningWorkCard(
    context: context,
    origin: () => ChatIsland.surfaceRectIn(_islandKey.currentContext),
    dismissLabel: 'Cerrar',
    snapshot: _alive,
    clock: () => _clock.value,
    reserveBelow: () => _composerHeight,
    actions: (close) => RunningWorkActions(
      stopProcess: (process) => _stopped.add(process.id),
      openSubagent: (activity) {
        close();
        _opened.add(activity?.subagentId);
      },
      goalDetails: () {
        close();
        _goalOpened++;
      },
      pauseGoal: () => _goalPaused++,
      dismissSubagents: () => _alive.value = ActivitySnapshot.idle,
    ),
    header: (context, close) => ValueListenableBuilder<ActivitySnapshot>(
      valueListenable: _alive,
      builder: (context, value, _) {
        return ChatIsland(
          key: const ValueKey('island-card-line'),
          flat: true,
          open: true,
          name: 'Hermes',
          status: IslandStatus.idle,
          mark: _mark(value),
          notices: HermesNotice.feedOf(context),
          onTap: close,
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const Positioned.fill(child: _Transcript()),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FloatingChatHeader(
            leading: FloatingHeaderButton(
              key: const ValueKey('menu'),
              icon: Icons.menu_rounded,
              tooltip: 'Menú',
              onPressed: () {},
            ),
            trailing: FloatingHeaderButton(
              key: const ValueKey('new'),
              icon: Icons.add_rounded,
              tooltip: 'Nuevo chat',
              onPressed: () {},
            ),
            faces: const SizedBox.square(
              key: ValueKey('sprite'),
              dimension: FloatingChatHeader.faceSize,
              child: ColoredBox(color: Colors.green),
            ),
            pill: ValueListenableBuilder<ActivitySnapshot>(
              valueListenable: _alive,
              builder: (context, value, _) {
                final mark = _mark(value);
                return ChatIsland(
                  key: _islandKey,
                  name: 'Hermes',
                  status: IslandStatus.idle,
                  notices: HermesNotice.feedOf(context),
                  mark: mark,
                  hint: mark != null ? 'Ver' : null,
                  onTap: mark != null ? () => _open(context) : null,
                );
              },
            ),
          ),
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SizedBox(
            key: ValueKey('composer'),
            height: _composerHeight,
            child: TextField(),
          ),
        ),
      ],
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  bool reduce = false,
  double textScale = 1,
}) async {
  // The app's real faces: the rows are measured as they are drawn.
  await loadDesignFonts();
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size
    ..padding = const FakeViewPadding(top: _statusBar)
    ..viewPadding = const FakeViewPadding(top: _statusBar);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduce,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: const _Chat(),
    ),
  );
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _key(String key) => find.byKey(ValueKey(key));
Finder get _island => _key('island');
Finder get _card => _key('island-card');
Finder get _composer => _key('composer');

Future<void> _openCard(WidgetTester tester) async {
  await tester.tap(_island);
  await _settle(tester);
  expect(_card, findsOneWidget);
}

ScrollPosition _rows(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: _key('island-card-rows'),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

void main() {
  setUp(() {
    _alive.value = ActivitySnapshot.idle;
    _clock.value = _t0;
    _transcriptBuilds = 0;
    _stopped.clear();
    _opened.clear();
    _goalPaused = 0;
    _goalOpened = 0;
    IslandPresenters.resetForTesting();
  });

  testWidgets('nothing alive: only the name, and a tap opens nothing', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    expect(_key('island-mark'), findsNothing);
    expect(_key('island-chevron'), findsNothing);
    await tester.tap(_island, warnIfMissed: false);
    await tester.tapAt(tester.getCenter(_key('sprite')));
    await _settle(tester);
    expect(_card, findsNothing);
    final node = tester.getSemantics(
      find.bySemanticsLabel('Hermes, Conectado'),
    );
    expect(node.flagsCollection.isButton, isFalse);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    handle.dispose();
  });

  testWidgets('something alive: the island says how many and a tap grows it '
      'into their card', (tester) async {
    await _pump(tester);
    _alive.value = _four();
    await _settle(tester);
    expect(find.text('4 en marcha'), findsOneWidget);
    final island = tester.getRect(_island);
    await _openCard(tester);
    final card = tester.getRect(_card);
    // It grows out of the island: from its top, downward and to the sides,
    // the sprite still standing on it.
    expect(card.top, closeTo(island.top, 0.5));
    expect(card.center.dx, closeTo(195, 0.5));
    expect(card.width, greaterThan(island.width));
    expect(card.left, greaterThanOrEqualTo(0));
    expect(card.right, lessThanOrEqualTo(390));
    expect(tester.getRect(_key('sprite')).bottom, lessThan(card.top + 8));
    // Its first line repeats the island, the chevron pointing back up.
    final line = tester.getRect(_key('island-card-line'));
    expect(line.top, closeTo(card.top, 1));
    expect(
      find.descendant(
        of: _key('island-card-line'),
        matching: find.text('4 en marcha'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: _key('island-card-line'),
              matching: _key('island-chevron'),
            ),
          )
          .icon,
      Icons.keyboard_arrow_up_rounded,
    );
    // One row per thing, whole, under it.
    for (final row in [
      'running-process-p1',
      'running-subagent-s1',
      'running-loop-0',
      'running-goal',
    ]) {
      final rect = tester.getRect(_key(row));
      expect(rect.top, greaterThanOrEqualTo(line.bottom), reason: row);
      expect(rect.bottom, lessThanOrEqualTo(card.bottom), reason: row);
    }
    expect(_rows(tester).maxScrollExtent, 0);
    expect(card.bottom, lessThan(tester.getRect(_composer).top));
    expect(find.byType(BackdropFilter), findsNothing, reason: 'no blur');
  });

  testWidgets('each row does what it says', (tester) async {
    await _pump(tester);
    _alive.value = _four();
    await _settle(tester);
    await _openCard(tester);
    await tester.tap(_key('running-process-stop-p1'));
    expect(_stopped, ['p1']);
    await tester.ensureVisible(_key('running-goal-action'));
    await _settle(tester);
    await tester.tap(_key('running-goal-action'));
    expect(_goalPaused, 1);
    // Stopping or pausing leaves the card open; going to see closes it.
    await _settle(tester);
    expect(_card, findsOneWidget);
    await tester.ensureVisible(_key('running-subagent-open-s1'));
    await _settle(tester);
    await tester.tap(_key('running-subagent-open-s1'));
    await _settle(tester);
    expect(_opened, ['s1']);
    expect(_card, findsNothing);
    await _openCard(tester);
    await tester.ensureVisible(find.text('Publicar 1.2.15'));
    await _settle(tester);
    await tester.tap(find.text('Publicar 1.2.15'));
    await _settle(tester);
    expect(_goalOpened, 1);
    expect(_card, findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('nothing alive but subagents that ended: it still opens, to '
      'see and clear them', (tester) async {
    await _pump(tester);
    final ended = SubagentActivity(
      key: SubagentActivityKey(
        scope: _scope,
        identityKind: SubagentIdentityKind.subagent,
        stableId: 's9',
      ),
      source: SubagentActivitySource.native,
      phase: SubagentActivityPhase.completed,
      subagentId: 's9',
      details: const SubagentActivityDetails(goalPreview: 'Revisar el log'),
    );
    _alive.value = ActivitySnapshot(subagents: [ended]);
    await _settle(tester);
    expect(RunningWork.aliveCount(_alive.value), 0);
    expect(find.text('1 terminado'), findsOneWidget);
    await _openCard(tester);
    expect(_key('running-subagent-s9'), findsOneWidget);
    // Cleared, nothing is left: the card closes and the island is its name.
    await tester.tap(_key('running-subagents-dismiss'));
    await _settle(tester);
    expect(_card, findsNothing);
    expect(_key('island-mark'), findsNothing);
  });

  testWidgets('it closes with a tap outside, with Back, by dragging it up and '
      'by tapping the island again', (tester) async {
    await _pump(tester);
    _alive.value = _four();
    await _settle(tester);

    await _openCard(tester);
    await tester.tapAt(const Offset(195, 700));
    await _settle(tester);
    expect(_card, findsNothing);

    await _openCard(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(_card, findsNothing);

    await _openCard(tester);
    await tester.drag(_key('island-card-grabber'), const Offset(0, -220));
    await _settle(tester);
    expect(_card, findsNothing);

    await _openCard(tester);
    await tester.tap(_key('island-card-line'));
    await _settle(tester);
    expect(_card, findsNothing);
    // And the island is there again, with its count.
    expect(find.text('4 en marcha'), findsOneWidget);
  });

  testWidgets('one thing: a card of one row', (tester) async {
    await _pump(tester);
    _alive.value = _one();
    await _settle(tester);
    expect(find.text('1 en marcha'), findsOneWidget);
    await _openCard(tester);
    final card = tester.getRect(_card);
    final row = tester.getRect(_key('running-process-p1'));
    expect(row.height, greaterThanOrEqualTo(66));
    expect(card.height, lessThan(IslandMetrics.flatHeight + row.height + 24));
  });

  testWidgets('six things: it stops growing and scrolls inside', (
    tester,
  ) async {
    await _pump(tester);
    _alive.value = _six();
    await _settle(tester);
    await _openCard(tester);
    final card = tester.getRect(_card);
    expect(card.height, lessThanOrEqualTo(kIslandCardMaxHeight));
    expect(card.bottom, lessThan(tester.getRect(_composer).top));
    expect(_rows(tester).maxScrollExtent, greaterThan(0));
    // Its first line does not scroll away with the rows.
    final line = tester.getRect(_key('island-card-line'));
    await tester.drag(_key('running-subagent-s1'), const Offset(0, -30));
    await _settle(tester);
    expect(_card, findsOneWidget, reason: 'scrolling its rows does not close');
    expect(_rows(tester).pixels, greaterThan(0));
    expect(tester.getRect(_key('island-card-line')), line);
    await tester.ensureVisible(_key('running-goal'));
    await _settle(tester);
    final last = tester.getRect(_key('running-goal'));
    expect(last.bottom, lessThanOrEqualTo(card.bottom));
  });

  testWidgets('with the keyboard open it ends above the composer', (
    tester,
  ) async {
    await _pump(tester);
    _alive.value = _six();
    await _settle(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await _settle(tester);
    await _openCard(tester);
    final card = tester.getRect(_card);
    final composer = tester.getRect(_composer);
    expect(composer.bottom, lessThanOrEqualTo(844 - 320));
    expect(card.bottom, lessThanOrEqualTo(composer.top));
    expect(_rows(tester).maxScrollExtent, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a notice that arrives while it is open takes its first line; '
      'the rows stay', (tester) async {
    await _pump(tester);
    _alive.value = _four();
    await _settle(tester);
    await _openCard(tester);
    var seen = 0;
    HermesNotice.of(tester.element(_card)).show(
      title: 'Fable terminó',
      message: 'Diseño de píldora',
      priority: HermesNoticePriority.high,
      duration: const Duration(seconds: 8),
      action: HermesNoticeAction(label: 'Ver', onPressed: () => seen++),
    );
    await _settle(tester);
    final card = tester.getRect(_card);
    final notice = tester.getRect(find.textContaining('Fable terminó'));
    expect(card.contains(notice.center), isTrue);
    expect(
      notice.bottom,
      lessThanOrEqualTo(tester.getRect(_key('running-process-p1')).top),
    );
    expect(_key('hermes-notice-lane'), findsNothing);
    for (final row in ['running-process-p1', 'running-goal']) {
      expect(_key(row), findsOneWidget);
    }
    await tester.tap(_key('hermes-notice-action'));
    await _settle(tester);
    expect(seen, 1);
    // Said, it gives the line back to the count.
    expect(find.textContaining('Fable terminó'), findsNothing);
    expect(
      find.descendant(
        of: _key('island-card-line'),
        matching: find.text('4 en marcha'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('it follows what is alive, and closes itself when nothing is '
      'left', (tester) async {
    await _pump(tester);
    _alive.value = _four();
    await _settle(tester);
    await _openCard(tester);
    _alive.value = ActivitySnapshot(schedules: [_loop], goal: _goal);
    await _settle(tester);
    expect(_key('running-process-p1'), findsNothing);
    expect(
      find.descendant(
        of: _key('island-card-line'),
        matching: find.text('2 en marcha'),
      ),
      findsOneWidget,
    );
    _alive.value = ActivitySnapshot.idle;
    await _settle(tester);
    expect(_card, findsNothing);
    // Back to the bare name.
    expect(_key('island-mark'), findsNothing);
    await tester.tap(_island, warnIfMissed: false);
    await _settle(tester);
    expect(_card, findsNothing);
  });

  testWidgets('animations off: it opens and closes without the morph', (
    tester,
  ) async {
    await _pump(tester, reduce: true);
    _alive.value = _four();
    await tester.pump();
    final island = tester.getRect(_island);
    await tester.tap(_island);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // Already at its place and size on the first frames: it only fades.
    final first = tester.getRect(_card);
    await _settle(tester);
    expect(tester.getRect(_card), first);
    expect(first.top, closeTo(island.top, 0.5));
    await tester.tap(_key('island-card-line'));
    await _settle(tester);
    expect(_card, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the transcript is not rebuilt by the count, the card or its '
      'timers', (tester) async {
    await _pump(tester);
    await _settle(tester);
    final built = _transcriptBuilds;
    _alive.value = _one();
    await _settle(tester);
    _alive.value = _four();
    await _settle(tester);
    await _openCard(tester);
    // The rows count their seconds inside the card.
    expect(
      find.descendant(
        of: _key('running-process-p1'),
        matching: find.textContaining('0:12', findRichText: true),
      ),
      findsOneWidget,
    );
    for (var second = 1; second <= 3; second++) {
      _clock.value = _t0.add(Duration(seconds: second));
      await tester.pump(const Duration(seconds: 1));
    }
    expect(
      find.descendant(
        of: _key('running-process-p1'),
        matching: find.textContaining('0:15', findRichText: true),
      ),
      findsOneWidget,
    );
    _alive.value = _six();
    await _settle(tester);
    await tester.tap(_key('island-card-line'));
    await _settle(tester);
    _alive.value = ActivitySnapshot.idle;
    await _settle(tester);
    expect(_transcriptBuilds, built);
  });

  testWidgets('320 dp at twice the text size: the name gives way, the count '
      'stays, nothing overflows and every action is reached', (tester) async {
    await _pump(tester, size: const Size(320, 640), textScale: 2);
    _alive.value = _four();
    await _settle(tester);
    expect(tester.takeException(), isNull);
    final island = tester.getRect(_island);
    expect(island.left, greaterThan(tester.getRect(_key('menu')).right));
    expect(island.right, lessThan(tester.getRect(_key('new')).left));
    final mark = tester.getRect(_key('island-mark'));
    final chevron = tester.getRect(_key('island-chevron'));
    expect(mark.left, greaterThanOrEqualTo(island.left));
    expect(chevron.right, lessThanOrEqualTo(island.right));
    expect(
      tester
          .renderObject<RenderParagraph>(_key('island-mark'))
          .didExceedMaxLines,
      isFalse,
      reason: 'the count is whole',
    );

    await _openCard(tester);
    expect(tester.takeException(), isNull);
    final card = tester.getRect(_card);
    expect(card.left, greaterThanOrEqualTo(0));
    expect(card.right, lessThanOrEqualTo(320));
    expect(card.bottom, lessThanOrEqualTo(tester.getRect(_composer).top));
    for (final action in ['running-process-stop-p1', 'running-goal-action']) {
      await tester.ensureVisible(_key(action));
      await _settle(tester);
      final rect = tester.getRect(_key(action));
      expect(rect.left, greaterThanOrEqualTo(card.left), reason: action);
      expect(rect.right, lessThanOrEqualTo(card.right), reason: action);
    }
    expect(tester.takeException(), isNull);
  });
}
