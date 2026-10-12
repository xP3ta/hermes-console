// Visual evidence of the island at 390×844, Spanish, dark: the real floating
// header and island over a stand-in transcript and composer. Writes PNGs only
// when `DESIGN_SHOTS_DIR` is set (environment, or `--dart-define`); without
// it this is a layout smoke test of every state: nothing overflows and the
// island never reaches the composer.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/core/widgets/island_card.dart';
import 'package:hermes_android/core/widgets/mascot/header_mascot.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_atlas.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_identity.dart';
import 'package:hermes_android/core/widgets/running_work.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart';

const _size = Size(390, 844);
const _statusBar = 38.0;
const _root = ValueKey('island-shot');

class _Scene {
  const _Scene({
    this.status = IslandStatus.idle,
    this.events = const [],
    this.timer,
  });

  final IslandStatus status;
  final List<IslandEvent> events;
  final String? timer;
}

final _scene = ValueNotifier<_Scene>(const _Scene());

/// What the conversation has alive outside its turn.
final _alive = ValueNotifier<ActivitySnapshot>(ActivitySnapshot.idle);
final _islandKey = GlobalKey(debugLabel: 'shot-island');
final _now = DateTime(2026, 10, 12, 20, 39);

final _subScope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

SubagentActivity _sub(String id, String goal, Duration ago) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _subScope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: id,
  ),
  source: SubagentActivitySource.native,
  phase: SubagentActivityPhase.tool,
  subagentId: id,
  details: SubagentActivityDetails(
    goalPreview: goal,
    startedAt: _now.subtract(ago),
  ),
);

SessionActivityProcess _process(String id, String command, Duration ago) =>
    SessionActivityProcess(
      id: id,
      command: command,
      notifyOnComplete: false,
      startedAt: _now.subtract(ago),
    );

final _daily = SessionActivitySchedule(
  kind: SessionActivityScheduleKind.loop,
  status: 'active',
  interval: const Duration(hours: 24),
  lastRunAt: _now.subtract(const Duration(hours: 12, minutes: 9)),
  nextDueAt: _now.add(const Duration(hours: 11, minutes: 51)),
  runCount: 6,
);

ActivitySnapshot _four() => ActivitySnapshot(
  processes: [
    _process('p1', 'sleep 20 && echo listo', const Duration(seconds: 12)),
  ],
  subagents: [_sub('s1', 'Revisar el kernel', const Duration(seconds: 5))],
  schedules: [_daily],
  goal: const SessionActivityGoal(title: 'Publicar 1.2.15', status: 'active'),
);

ActivitySnapshot _six() => ActivitySnapshot(
  processes: [
    _process('p1', 'sleep 20 && echo listo', const Duration(seconds: 12)),
    _process('p2', 'npm run dev', const Duration(minutes: 12, seconds: 40)),
  ],
  subagents: [
    _sub('s1', 'Revisar el kernel', const Duration(seconds: 5)),
    _sub('s2', 'Revisar el disco', const Duration(seconds: 3)),
  ],
  schedules: [_daily],
  goal: const SessionActivityGoal(title: 'Publicar 1.2.15', status: 'active'),
);

/// The island grows into the card of what is alive, as the chat does it.
void _openCard(BuildContext context) => showRunningWorkCard(
  context: context,
  origin: () => ChatIsland.surfaceRectIn(_islandKey.currentContext),
  dismissLabel: 'Cerrar',
  snapshot: _alive,
  clock: () => _now,
  // The stand-in composer: 54 dp tall, 34 dp above the bottom.
  reserveBelow: () => 54 + 34,
  actions: (close) => RunningWorkActions(
    openSubagent: (_) {},
    stopProcess: (_) {},
    goalDetails: () {},
    pauseGoal: () {},
    resumeGoal: () {},
  ),
  header: (context, close) => ValueListenableBuilder<ActivitySnapshot>(
    valueListenable: _alive,
    builder: (context, value, _) => ChatIsland(
      flat: true,
      open: true,
      name: 'Hermes',
      status: _scene.value.status,
      mark: '${RunningWork.aliveCount(value)} en marcha',
      notices: HermesNotice.feedOf(context),
      onTap: close,
    ),
  ),
);

/// A chat reduced to its outline: enough to judge the header over a real
/// page (text scrolling under it, the composer at the foot).
class _Chat extends StatelessWidget {
  const _Chat();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    Widget bubble(String text) => Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.fromLTRB(80, 10, 16, 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text, style: TextStyle(color: colors.textPrimary)),
      ),
    );
    Widget reply(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 40, 6),
      child: Text(
        text,
        style: TextStyle(color: colors.textPrimary, fontSize: 15, height: 1.5),
      ),
    );
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.only(
                top: FloatingChatHeader.insetFor(context) + 8,
                bottom: 120,
              ),
              children: [
                reply('Las tres partes de la prueba funcionan:'),
                reply('•  Herramientas en primer plano: OK.'),
                reply('•  Segundo plano con aviso: OK.'),
                reply('•  Subagentes en paralelo: OK.'),
                bubble('Y tareas'),
                reply(
                  'Hecho: 4 de 5 tareas. Dejé sin hacer «Revisar disco al '
                  '92 % y carga alta» porque era opcional. ¿La hago ahora?',
                ),
                bubble('Sí, y mira también la carga'),
                reply('Voy con las dos.'),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: FloatingChatHeader(
              leading: FloatingHeaderButton(
                icon: Icons.menu_rounded,
                tooltip: 'Menú',
                onPressed: () {},
              ),
              trailing: FloatingHeaderButton(
                icon: Icons.add_rounded,
                tooltip: 'Nuevo chat',
                onPressed: () {},
              ),
              // The default chat: Hermes' own sprite, through the engine.
              mascot: const HeaderMascotRequest(
                identity: 'hermes',
                state: HeaderMascotState.idle,
              ),
              faces: const SizedBox.shrink(),
              pill: ListenableBuilder(
                listenable: Listenable.merge([_scene, _alive]),
                builder: (context, _) => ChatIsland(
                  key: _islandKey,
                  name: 'Hermes',
                  status: _scene.value.status,
                  events: _scene.value.events,
                  notices: HermesNotice.feedOf(context),
                  trailing: _scene.value.timer == null
                      ? null
                      : Text(
                          _scene.value.timer!,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            color: colors.textSecondary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                  // Only while something is alive: how many, and a tap
                  // opens them.
                  mark: RunningWork.aliveCount(_alive.value) > 0
                      ? '${RunningWork.aliveCount(_alive.value)} en marcha'
                      : null,
                  onTap: RunningWork.aliveCount(_alive.value) > 0
                      ? () => _openCard(context)
                      : null,
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 34,
            child: Container(
              key: const ValueKey('composer'),
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(27),
                border: Border.all(color: colors.divider),
              ),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Icon(Icons.add_rounded, color: colors.textSecondary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Pregunta a Hermes…',
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  ),
                  Icon(Icons.mic_none_rounded, color: colors.textSecondary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _pump(WidgetTester tester, {ThemeData? theme}) async {
  await loadDesignFonts();
  // The sprite's atlas is decoded before the first frame of the shot.
  await tester.runAsync(() => MascotAtlas.load(MascotIdentity.hermes.sprite));
  tester.view
    ..physicalSize = _size
    ..devicePixelRatio = 1
    ..padding = const FakeViewPadding(top: _statusBar)
    ..viewPadding = const FakeViewPadding(top: _statusBar);
  addTearDown(tester.view.reset);
  _scene.value = const _Scene();
  _alive.value = ActivitySnapshot.idle;
  IslandPresenters.resetForTesting();
  await tester.pumpWidget(
    RepaintBoundary(
      key: _root,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: theme ?? AppTheme.hermesRedDark,
        home: const HeaderMascotScope(
          builder: buildHeaderMascot,
          child: _Chat(),
        ),
      ),
    ),
  );
  await _frames(tester);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String? get _dir {
  const defined = String.fromEnvironment('DESIGN_SHOTS_DIR');
  if (defined.isNotEmpty) return defined;
  final env = Platform.environment['DESIGN_SHOTS_DIR'];
  return env == null || env.isEmpty ? null : env;
}

/// Checks the frame (no overflow, the island clear of the composer and of
/// the status bar) and saves it as `<name>.png` when a directory is given.
Future<void> _shot(WidgetTester tester, String name) async {
  await _frames(tester);
  expect(tester.takeException(), isNull, reason: name);
  final island = tester.getRect(find.byKey(const ValueKey('island')));
  final composer = tester.getRect(find.byKey(const ValueKey('composer')));
  expect(island.bottom, lessThan(composer.top), reason: name);
  expect(island.top, greaterThan(_statusBar), reason: name);
  expect(island.left, greaterThan(56), reason: name);
  expect(island.right, lessThan(390 - 56), reason: name);
  final card = find.byKey(const ValueKey('island-card'));
  if (card.evaluate().isNotEmpty) {
    // The card grows out of the island, downward, and stops short of the
    // composer.
    final rect = tester.getRect(card);
    expect(rect.top, closeTo(island.top, 1), reason: name);
    expect(rect.bottom, lessThanOrEqualTo(composer.top), reason: name);
    expect(rect.left, greaterThanOrEqualTo(0), reason: name);
    expect(rect.right, lessThanOrEqualTo(390), reason: name);
  }
  final dir = _dir;
  if (dir == null) return;
  final boundary =
      tester.renderObject(find.byKey(_root)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

IslandEvent _needsYou() => IslandEvent(
  id: 'needs-you',
  tone: IslandTone.needsYou,
  sticky: true,
  line: 'Te necesita',
  action: IslandAction(label: 'Ver', onPressed: () {}),
);

void main() {
  testWidgets('island · at rest', (tester) async {
    await _pump(tester);
    await _shot(tester, '01_rest');
  });

  testWidgets('island · working', (tester) async {
    await _pump(tester);
    // What it says when the work shows…
    _scene.value = const _Scene(
      status: IslandStatus.working,
      timer: '0:07',
      events: [
        IslandEvent(
          id: 'working',
          icon: Icons.bolt_rounded,
          line: 'Trabajando',
          detail: 'Terminal',
          sticky: true,
          trailing: Text('0:07', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
    await _shot(tester, '02_working_said');
    // …and how it stays while the turn runs.
    _scene.value = const _Scene(status: IslandStatus.working, timer: '0:42');
    await _shot(tester, '03_working');
  });

  testWidgets('island · needs you', (tester) async {
    await _pump(tester);
    _scene.value = _Scene(status: IslandStatus.needsYou, events: [_needsYou()]);
    await _shot(tester, '04_needs_you');
  });

  testWidgets('island · something from another chat', (tester) async {
    await _pump(tester);
    final context = tester.element(find.byKey(const ValueKey('composer')));
    HermesNotice.of(context).show(
      title: 'Fable terminó',
      message: 'Diseño de píldora de estados',
      icon: Icons.check_circle_outline,
      tint: AppTheme.hermesRedDark.hermes.success,
      priority: HermesNoticePriority.high,
      duration: const Duration(days: 1),
      action: HermesNoticeAction(label: 'Ir', onPressed: () {}),
    );
    await _shot(tester, '05_outside_event');
    HermesNotice.of(context).clearSnackBars();
  });

  testWidgets('island · two at a time', (tester) async {
    await _pump(tester);
    final context = tester.element(find.byKey(const ValueKey('composer')));
    HermesNotice.of(context).show(
      title: 'Forja pide permiso',
      message: 'git push',
      icon: Icons.verified_user_outlined,
      tint: AppTheme.hermesRedDark.hermes.warning,
      priority: HermesNoticePriority.high,
      sticky: true,
      action: HermesNoticeAction(label: 'Ir', onPressed: () {}),
    );
    _scene.value = const _Scene(
      status: IslandStatus.error,
      events: [
        IslandEvent(
          id: 'turn-failed',
          tone: IslandTone.error,
          sticky: true,
          line: 'No se envió',
        ),
      ],
    );
    await _shot(tester, '06_two_queued');
  });

  testWidgets('island · offline, reconnecting and back', (tester) async {
    await _pump(tester);
    _scene.value = const _Scene(
      status: IslandStatus.offline,
      events: [
        IslandEvent(
          id: 'connection',
          tone: IslandTone.error,
          icon: Icons.cloud_off_outlined,
          sticky: true,
          line: 'Sin conexión',
        ),
      ],
    );
    await _shot(tester, '07_offline');
    // Dismissed: the red dot keeps saying it.
    _scene.value = const _Scene(status: IslandStatus.offline);
    await _shot(tester, '08_offline_dot');
    _scene.value = const _Scene(
      status: IslandStatus.reconnecting,
      events: [
        IslandEvent(
          id: 'connection',
          revision: 1,
          tone: IslandTone.warning,
          icon: Icons.cloud_off_outlined,
          busy: true,
          sticky: true,
          line: 'Reconectando…',
        ),
      ],
    );
    await _shot(tester, '09_reconnecting');
  });

  testWidgets('island · an event opened to read it', (tester) async {
    await _pump(tester);
    _scene.value = _Scene(
      events: [
        IslandEvent(
          id: 'recovered-turn',
          tone: IslandTone.warning,
          icon: Icons.help_outline_rounded,
          sticky: true,
          line: 'Sin confirmar',
          more:
              'No se pudo confirmar si este turno llegó al servidor. Revisa '
              'la conversación antes de volver a enviarlo.',
          action: IslandAction(label: 'Restaurar', onPressed: () {}),
          secondary: IslandAction(label: 'Descartar', onPressed: () {}),
        ),
      ],
    );
    await _shot(tester, '10_recovered');
    await tester.tap(find.byKey(const ValueKey('island-event-line')));
    await _shot(tester, '11_recovered_open');
  });

  testWidgets('island · what is alive: only the name, the count, its card', (
    tester,
  ) async {
    await _pump(tester);
    await _shot(tester, '12_bare');
    expect(find.byKey(const ValueKey('island-mark')), findsNothing);
    // A tap on the bare name opens nothing.
    await tester.tap(find.byKey(const ValueKey('island')), warnIfMissed: false);
    await _frames(tester);
    expect(find.byKey(const ValueKey('island-card')), findsNothing);

    _alive.value = _four();
    await _shot(tester, '13_marked');
    expect(find.text('4 en marcha'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('island')));
    await _shot(tester, '14_open_4');
    for (final row in [
      'running-process-p1',
      'running-subagent-s1',
      'running-loop-0',
      'running-goal',
    ]) {
      final rect = tester.getRect(find.byKey(ValueKey(row)));
      expect(rect.height, greaterThanOrEqualTo(66), reason: row);
    }
    // Four rows fit: nothing to scroll.
    final rows = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('island-card-rows')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(rows.position.maxScrollExtent, 0);

    // A notice that arrives meanwhile takes the first line; the rows stay.
    final context = tester.element(find.byKey(const ValueKey('island-card')));
    HermesNotice.of(context).show(
      title: 'Fable terminó',
      message: 'Diseño de píldora de estados',
      icon: Icons.check_circle_outline,
      tint: AppTheme.hermesRedDark.hermes.success,
      priority: HermesNoticePriority.high,
      duration: const Duration(days: 1),
      action: HermesNoticeAction(label: 'Ver', onPressed: () {}),
    );
    await _shot(tester, '18_open_notice');
    final card = tester.getRect(find.byKey(const ValueKey('island-card')));
    final notice = tester.getRect(find.textContaining('Fable terminó'));
    expect(card.contains(notice.center), isTrue);
    expect(
      notice.bottom,
      lessThan(
        tester.getRect(find.byKey(const ValueKey('running-process-p1'))).top,
      ),
    );
    expect(find.byKey(const ValueKey('running-goal')), findsOneWidget);
    HermesNotice.of(context).clearSnackBars();
  });

  testWidgets('island · six alive: the card stops growing and scrolls', (
    tester,
  ) async {
    await _pump(tester);
    _alive.value = _six();
    await _frames(tester);
    expect(find.text('6 en marcha'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('island')));
    await _shot(tester, '15_open_6');
    final card = tester.getRect(find.byKey(const ValueKey('island-card')));
    expect(card.height, lessThanOrEqualTo(kIslandCardMaxHeight));
    final rows = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('island-card-rows')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(rows.position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('island · the card with the keyboard open', (tester) async {
    await _pump(tester);
    _alive.value = _four();
    await _frames(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('island')));
    await _shot(tester, '16_keyboard');
  });

  testWidgets('island · one of them ends: said once, with Ver', (tester) async {
    await _pump(tester);
    _alive.value = ActivitySnapshot(
      subagents: _four().subagents,
      schedules: _four().schedules,
      goal: _four().goal,
    );
    _scene.value = _Scene(
      events: [
        IslandEvent(
          id: 'running-work',
          tone: IslandTone.success,
          duration: const Duration(seconds: 6),
          line: 'Proceso terminó',
          detail: 'sleep 20 && echo listo',
          action: IslandAction(label: 'Ver', onPressed: () {}),
        ),
      ],
    );
    await _shot(tester, '17_event');
    await tester.pump(const Duration(seconds: 7));
    await _frames(tester);
    // …and back to the count of what is left.
    expect(find.text('3 en marcha'), findsOneWidget);
  });

  testWidgets('island · the card in the light theme', (tester) async {
    await _pump(tester, theme: AppTheme.hermesRedLight);
    _alive.value = _four();
    await _frames(tester);
    await _shot(tester, '19_marked_light');
    await tester.tap(find.byKey(const ValueKey('island')));
    await _shot(tester, '20_open_light');
    // Every row's icon is drawn at a size that reads at a glance.
    final icons = tester.widgetList<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('island-running-work')),
        matching: find.byType(Icon),
      ),
    );
    expect(icons, hasLength(4));
    for (final icon in icons) {
      expect(icon.size, inInclusiveRange(20, 24));
      expect(icon.semanticLabel, isNotEmpty);
    }
  });
}
