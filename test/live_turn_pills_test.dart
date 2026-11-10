// Q9-CHAT5 v2 (the owner, the reference video; decisions 1, 3): the live turn is
// ONE status pill above the composer with the turn's only clock, the tool in
// hand in the code face and a verb that turns over at least every 3 s; while
// a tool runs, the step in hand in a fainter pill above it. A screen reader
// hears the state, never the turn of phrase nor the seconds.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/live_turn_pills.dart';
import 'package:hermes_android/core/widgets/chat/live_motion.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/thinking_glyph.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final _start = DateTime(2026, 10, 28, 22, 20);

Widget _host(
  ActivitySnapshot snapshot, {
  Duration elapsed = const Duration(seconds: 8),
  double width = 412,
  double textScale = 1,
  bool reduceMotion = false,
  bool inHeader = false,
  String? mark,
  VoidCallback? onOpenWork,
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reduceMotion,
    ),
    child: Directionality(textDirection: direction, child: child!),
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomLeft,
      child: SizedBox(
        width: width - 24,
        child: Align(
          alignment: Alignment.bottomLeft,
          child: inHeader
              ? ChatIsland(
                  name: 'Console',
                  status: IslandStatus.working,
                  mark: mark,
                  onTap: onOpenWork,
                  activity: snapshot.turnActive
                      ? LiveTurnPills.header(
                          snapshot: snapshot,
                          now: _start.add(elapsed),
                          mark: mark,
                          name: 'Console',
                        )
                      : null,
                )
              : LiveTurnPills(
                  snapshot: snapshot,
                  clock: () => _start.add(elapsed),
                  avatar: const SizedBox.square(
                    key: ValueKey('test-face'),
                    dimension: LiveTurnPills.avatarSize,
                    child: ColoredBox(color: Color(0xFF74C7A5)),
                  ),
                ),
        ),
      ),
    ),
  ),
);

ActivitySnapshot _thinking({String? thought}) => ActivitySnapshot(
  turnActive: true,
  turnStartedAt: _start,
  liveReasoning: thought,
);

ActivitySnapshot _tool({
  String label = 'browser_exec',
  String? detail = 'news.ycombinator.com',
}) => ActivitySnapshot(
  turnActive: true,
  turnStartedAt: _start,
  current: ActivityStep(
    id: 'tool-1',
    kind: ActivityStepKind.tool,
    label: label,
    status: ActivityStepStatus.running,
    detail: detail,
    startedAt: _start,
  ),
);

Finder _status() => find.byKey(const ValueKey('live-turn-status'));
Finder _clock() => find.byKey(const ValueKey('live-turn-clock'));

String _verb(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: _status(),
        matching: find.byWidgetPredicate(
          (w) => w is Text && '${w.key}'.contains('live-turn-verb-'),
        ),
      ),
    )
    .last
    .data!;

void main() {
  tearDown(() {
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.blurAllowed.value = true;
  });

  for (final direction in TextDirection.values) {
    for (final width in [224.0, 773.0]) {
      testWidgets('QA9716 header centers its content $direction width=$width', (
        tester,
      ) async {
        for (final mark in <String?>[null, '2 subagentes']) {
          await tester.pumpWidget(
            _host(
              _thinking(),
              inHeader: true,
              mark: mark,
              width: width,
              textScale: 1.3,
              direction: direction,
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          final island = tester.getRect(find.byKey(const ValueKey('island')));
          final clock = tester.getRect(_clock());
          // One capsule: the face and the clock on one line, centred in it.
          final face = tester.getRect(
            find.byKey(const ValueKey('live-turn-face')),
          );
          expect(face.center.dy, closeTo(island.center.dy, 1));
          expect(clock.center.dy, closeTo(island.center.dy, 1.5));
          if (direction == TextDirection.ltr) {
            expect(face.right, lessThanOrEqualTo(clock.left));
          } else {
            expect(clock.right, lessThanOrEqualTo(face.left));
          }
          expect(_status(), findsOneWidget);
          expect(_clock(), findsOneWidget);
          expect(island.contains(clock.center), isTrue);
          expect(
            find.byKey(const ValueKey('live-turn-status-pill')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        }
      });
    }
  }

  final phases = <String, ActivitySnapshot>{
    'thinking': _thinking(),
    'terminal': _tool(label: 'terminal', detail: 'date'),
    'write': _tool(label: 'write_file', detail: 'public.md'),
    'waiting': ActivitySnapshot(
      turnActive: true,
      turnStartedAt: _start,
      waitingForUser: true,
    ),
    'quiet': ActivitySnapshot(
      turnActive: true,
      turnStartedAt: _start,
      noActivityHint: true,
    ),
    'reply': ActivitySnapshot(
      turnActive: true,
      turnStartedAt: _start,
      headline: 'Respondiendo…',
    ),
  };
  for (final phase in phases.entries) {
    testWidgets(
      'QA9715 header ${phase.key}: one phase, clock and work action',
      (tester) async {
        final semantics = tester.ensureSemantics();
        var opened = 0;
        try {
          // A real chat changes an already mounted resting island in place.
          await tester.pumpWidget(
            _host(
              ActivitySnapshot.idle,
              inHeader: true,
              mark: '2 subagentes',
              onOpenWork: () => opened++,
              width: 224,
              elapsed: const Duration(seconds: 45),
              textScale: 1.34,
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpWidget(
            _host(
              phase.value,
              inHeader: true,
              mark: '2 subagentes',
              onOpenWork: () => opened++,
              width: 224,
              elapsed: const Duration(seconds: 45),
              textScale: 1.34,
            ),
          );
          // The island takes the subtitle's size in its one motion.
          await tester.pump(const Duration(milliseconds: 400));
          final status = _status();
          final label = tester.widget<Semantics>(status).properties.label!;
          expect(find.semantics.byLabel(label), findsOneWidget);
          expect(tester.getSemantics(status).label, label);
          expect(_clock(), findsOneWidget);
          expect(tester.widget<Text>(_clock()).data, '0:45');
          expect(
            find.ancestor(
              of: status,
              matching: find.byKey(const ValueKey('island')),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('live-turn-step-pill')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('live-turn-status-pill')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('live-turn-thought')), findsNothing);
          final island = tester.getRect(find.byKey(const ValueKey('island')));
          final clock = tester.getRect(_clock());
          expect(island.contains(clock.center), isTrue);
          // No badge on the mark: the count lives in the work sheet.
          expect(find.byKey(const ValueKey('live-turn-count')), findsNothing);
          await tester.tap(status);
          await tester.pump();
          expect(opened, 1);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }
  testWidgets(
    'QA9715 header says «Pensando» as ONE steady word, without repeating its '
    'spoken phase',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(_thinking(), inHeader: true, elapsed: Duration.zero),
      );
      final label = tester.getSemantics(_status()).label;
      await tester.pumpWidget(
        _host(
          _thinking(),
          inHeader: true,
          elapsed: const Duration(seconds: 16),
        ),
      );
      expect(find.text('Pensando'), findsOneWidget);
      expect(find.textContaining('Atando cabos'), findsNothing);
      expect(tester.getSemantics(_status()).label, label);
      expect(find.semantics.byLabel(label), findsOneWidget);
      expect(_clock(), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgets('chat-status: the live turn is ONE capsule: brain, state word '
      'and clock; no badge, no chevron', (tester) async {
    await tester.pumpWidget(
      _host(
        _thinking(),
        inHeader: true,
        mark: '3 en marcha',
        elapsed: Duration.zero,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('live-turn-face')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-turn-brain')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-turn-count')), findsNothing);
    expect(find.byKey(const ValueKey('island-mark')), findsNothing);
    expect(find.byKey(const ValueKey('island-chevron')), findsNothing);
    expect(find.text('Pensando'), findsOneWidget);
    expect(_clock(), findsOneWidget);
    // At rest the island is the plain pill again.
    await tester.pumpWidget(
      _host(ActivitySnapshot.idle, inHeader: true, mark: '3 en marcha'),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('live-turn-face')), findsNothing);
  });

  testWidgets('capsule states: a tool turns a ring beside its verb, writing, '
      'coordinating and waiting have their words', (tester) async {
    Future<void> show(ActivitySnapshot snapshot) async {
      await tester.pumpWidget(_host(snapshot, inHeader: true));
      await tester.pump(const Duration(milliseconds: 400));
    }

    await show(_tool(label: 'web_search', detail: 'noticias'));
    expect(find.byKey(const ValueKey('live-turn-ring')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-turn-brain')), findsNothing);
    expect(find.textContaining('Buscando', findRichText: true), findsOneWidget);
    expect(find.textContaining('…'), findsWidgets);
    await show(
      ActivitySnapshot(
        turnActive: true,
        turnStartedAt: _start,
        headline: 'Respondiendo…',
      ),
    );
    expect(find.text('Escribiendo'), findsOneWidget);
    await show(
      ActivitySnapshot(
        turnActive: true,
        turnStartedAt: _start,
        subagentGenericCount: 3,
      ),
    );
    // (the test font is as wide as it is tall: the word may give way, the
    // count never does)
    expect(
      tester.widget<Semantics>(_status()).properties.label,
      startsWith('Coordinando'),
    );
    expect(find.byKey(const ValueKey('live-turn-agents')), findsOneWidget);
    expect(find.text('0/3 agentes'), findsOneWidget);
    expect(_clock(), findsNothing);
    await show(
      ActivitySnapshot(
        turnActive: true,
        turnStartedAt: _start,
        waitingForUser: true,
      ),
    );
    expect(find.byKey(const ValueKey('live-turn-waiting-dot')), findsOneWidget);
    expect(find.textContaining('permiso'), findsOneWidget);
  });

  testWidgets('the capsule is never wider than 210 dp', (tester) async {
    await tester.pumpWidget(
      _host(
        _tool(label: 'mcp__googlecalendar__create_recurring_event'),
        inHeader: true,
        width: 773,
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.getSize(find.byKey(const ValueKey('live-turn-pills'))).width,
      lessThanOrEqualTo(LiveTurnPills.maxPillWidth),
    );
  });

  testWidgets('done: a green check, «Listo» and the final clock, then the '
      'name comes back', (tester) async {
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: Center(
            child: LiveTurnPills.header(
              snapshot: ActivitySnapshot.idle,
              now: _start,
              doneElapsed: const Duration(minutes: 1, seconds: 5),
              onDone: () => done++,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Listo'), findsOneWidget);
    expect(find.byType(LiveResultMark), findsOneWidget);
    expect(tester.widget<Text>(_clock()).data, '1:05');
    expect(done, 0);
    await tester.pump(LiveTurnPills.doneHold);
    expect(done, 1);
  });

  for (final width in const [224.0, 320.0, 412.0]) {
    for (final scale in const [1.0, 1.34]) {
      testWidgets('chat-status: ${width.toInt()} dp x$scale: the face and the '
          'clock are always whole; only the word gives way', (tester) async {
        await tester.pumpWidget(
          _host(
            _tool(label: 'mcp__googlecalendar__create_recurring_event'),
            inHeader: true,
            mark: '12 en marcha',
            width: width,
            textScale: scale,
            elapsed: const Duration(minutes: 12, seconds: 5),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        final island = tester.getRect(find.byKey(const ValueKey('island')));
        final clock = tester.getRect(_clock());
        final face = tester.getRect(
          find.byKey(const ValueKey('live-turn-face')),
        );
        expect(tester.widget<Text>(_clock()).data, '12:05');
        expect(island.contains(clock.center), isTrue);
        expect(island.contains(face.center), isTrue);
        expect(face.right, lessThanOrEqualTo(clock.left));
        expect(tester.getSize(_status()).height, greaterThanOrEqualTo(48));
      });
    }
  }

  testWidgets('chat-status: the shimmer stops with reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_thinking(), inHeader: true, elapsed: Duration.zero),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('live-turn-shimmer')), findsOneWidget);
    await tester.pumpWidget(
      _host(
        _thinking(),
        inHeader: true,
        reduceMotion: true,
        elapsed: Duration.zero,
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('live-turn-shimmer')), findsNothing);
    expect(find.text('Pensando'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('nothing while no turn runs', (tester) async {
    await tester.pumpWidget(_host(ActivitySnapshot.idle));
    expect(find.byKey(const ValueKey('live-turn-pills-none')), findsOneWidget);
    expect(_status(), findsNothing);
  });

  testWidgets('thinking: the brain, «Pensando…» and the turn\'s one clock; '
      'TalkBack hears «Pensando», no seconds', (tester) async {
    final semantics = tester.ensureSemantics();
    // Within the verb's first period (gint67: at 8 s it had turned over
    // twice, as decision 3 says it must).
    await tester.pumpWidget(
      _host(_thinking(), elapsed: const Duration(seconds: 3)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('live-turn-brain')), findsOneWidget);
    expect(find.byType(ThinkingGlyph), findsOneWidget);
    expect(_verb(tester), 'Pensando…');
    expect(tester.widget<Text>(_clock()).data, '0:03');
    expect(find.byKey(const ValueKey('live-turn-step')), findsNothing);
    final node = tester.getSemantics(_status());
    expect(node.label, 'Pensando');
    expect(node.label, isNot(contains('0:')));
    expect(node.flagsCollection.isLiveRegion, isTrue);
    semantics.dispose();
  });

  testWidgets('decision 3: the verb turns over every 4 s through Desktop\'s '
      'list; what TalkBack hears does not', (tester) async {
    final semantics = tester.ensureSemantics();
    final strings = lookupStrings(const Locale('es'));
    final verbs = strings.q9TurnVerbsThink.split('|');
    expect(
      LiveTurnPills.verbPeriod,
      greaterThanOrEqualTo(const Duration(seconds: 3)),
    );
    final seen = <String>[];
    for (final seconds in [0, 3, 4, 7, 8, 12]) {
      await tester.pumpWidget(
        _host(_thinking(), elapsed: Duration(seconds: seconds)),
      );
      await tester.pump(const Duration(seconds: 1));
      seen.add(_verb(tester));
      expect(tester.getSemantics(_status()).label, 'Pensando');
    }
    // Held for a period, then the next one, from the plain verb.
    expect(seen[0], verbs[0]);
    expect(seen[1], verbs[0], reason: '3 s: the same verb still');
    expect(seen[2], verbs[1]);
    expect(seen[3], verbs[1]);
    expect(seen[4], verbs[2]);
    expect(seen[5], verbs[3]);
    semantics.dispose();
  });

  testWidgets('a tool: the face, the verb, the tool in the code face, the '
      'clock; the step in hand in the faint pill above', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(_tool(), elapsed: const Duration(seconds: 3)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('live-turn-brain')), findsNothing);
    expect(
      find.descendant(
        of: _status(),
        matching: find.byKey(const ValueKey('test-face')),
      ),
      findsOneWidget,
    );
    expect(_verb(tester), 'Trabajando…');
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('live-turn-tool'))).data,
      'browser_exec',
    );
    final step = find.byKey(const ValueKey('live-turn-step'));
    expect(step, findsOneWidget);
    expect(
      tester.getRect(step).bottom,
      lessThanOrEqualTo(tester.getRect(_status()).top + 0.5),
      reason: 'the step sits above the status pill',
    );
    expect(tester.getSemantics(_status()).label, 'Trabajando, browser_exec');
    expect(tester.getSemantics(step).label, contains('news.ycombinator.com'));
    semantics.dispose();
  });

  testWidgets('waiting for the user and still working are said as such, '
      'without a turn of phrase', (tester) async {
    await tester.pumpWidget(
      _host(
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _start,
          waitingForUser: true,
        ),
        elapsed: const Duration(seconds: 13),
      ),
    );
    await tester.pump();
    expect(_verb(tester), 'Esperando tu respuesta');
    await tester.pumpWidget(
      _host(
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _start,
          noActivityHint: true,
        ),
        elapsed: const Duration(seconds: 13),
      ),
    );
    await tester.pump();
    expect(_verb(tester), 'Sigo trabajando');
  });

  testWidgets('while it thinks a tap opens the thought being written (137 A); '
      'TalkBack hears a button that opens', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(_thinking(thought: 'El usuario pregunta si puede volver.')),
    );
    await tester.pump();
    final thought = find.byKey(const ValueKey('live-turn-thought'));
    expect(thought, findsNothing);
    var node = tester.getSemantics(_status());
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isExpanded, Tristate.isFalse);
    await tester.tap(_status());
    await tester.pump();
    expect(thought, findsOneWidget);
    expect(
      find.descendant(
        of: thought,
        matching: find.textContaining('volver', findRichText: true),
      ),
      findsWidgets,
    );
    node = tester.getSemantics(_status());
    expect(node.flagsCollection.isExpanded, Tristate.isTrue);
    // Without a thought to read the pill is not a button.
    await tester.pumpWidget(_host(_tool()));
    await tester.pump();
    expect(tester.getSemantics(_status()).flagsCollection.isButton, isFalse);
    expect(thought, findsNothing);
    semantics.dispose();
  });

  testWidgets('rule 2: the status pill is the one blur at the foot; the step '
      'keeps the veil', (tester) async {
    await tester.pumpWidget(_host(_tool()));
    await tester.pump();
    await tester.pump();
    expect(tester.layers.whereType<BackdropFilterLayer>(), hasLength(1));
    BackdropFilter filterOf(String key) => tester.widget<BackdropFilter>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(BackdropFilter),
      ),
    );
    expect(filterOf('live-turn-status-pill').enabled, isTrue);
    expect(filterOf('live-turn-step-pill').enabled, isFalse);
  });

  testWidgets('reduced motion: no blur; and the mark is still at any '
      'setting (ct1215): nothing in it animates, the verb changes in place', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_thinking(), reduceMotion: true));
    await tester.pump();
    expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
    for (final reduce in [true, false]) {
      await tester.pumpWidget(_host(_thinking(), reduceMotion: reduce));
      await tester.pump();
      expect(
        find.descendant(
          of: _status(),
          matching: find.byWidgetPredicate(
            (w) => w is AnimatedWidget || w is ImplicitlyAnimatedWidget,
          ),
        ),
        findsNothing,
      );
    }
  });

  testWidgets('a state the pipeline names (replying) is said as it comes, '
      'never turned over', (tester) async {
    for (final seconds in [0, 5, 9]) {
      await tester.pumpWidget(
        _host(
          ActivitySnapshot(
            turnActive: true,
            turnStartedAt: _start,
            headline: 'Respondiendo…',
          ),
          elapsed: Duration(seconds: seconds),
        ),
      );
      await tester.pump();
      expect(_verb(tester), 'Respondiendo…');
      expect(find.byKey(const ValueKey('live-turn-brain')), findsNothing);
    }
  });

  testWidgets('the status pill is 36 to the eye in a 48 dp target', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_thinking(thought: 'Algo')));
    await tester.pump();
    expect(tester.getSize(_status()).height, greaterThanOrEqualTo(48));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('live-turn-status-pill')))
          .height,
      closeTo(LiveTurnPills.pillHeight, 0.5),
    );
  });

  for (final width in const [320.0, 360.0, 412.0, 773.0]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      testWidgets('${width.toInt()} dp, text ${scale}x: a long tool and step '
          'fit without overflow; the clock always shows', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _host(
            _tool(
              label:
                  'mcp__googlecalendar__create_recurring_event_with_attendees',
              detail: 'un-nombre-de-recurso-bastante-largo.example.com/ruta',
            ),
            width: width,
            textScale: scale,
            elapsed: const Duration(minutes: 12, seconds: 5),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(_clock(), findsOneWidget);
        final pills = tester.getRect(
          find.byKey(const ValueKey('live-turn-pills')),
        );
        expect(pills.right, lessThanOrEqualTo(width - 24 + 0.5));
        expect(
          tester.getRect(_clock()).right,
          lessThanOrEqualTo(
            tester
                .getRect(find.byKey(const ValueKey('live-turn-status-pill')))
                .right,
          ),
        );
      });
    }
  }
}
