// The step rows of the chat (the opened «Trabajó · …» line), the subagent's
// detail page and the «Trabajando» pill: one outline icon family, one size,
// one quiet ink; no filled badge, no coloured circle behind an icon, no dot
// before the pill's words. Only a failure takes a colour (the error ink), and
// it keeps its own glyph too, so it never differs by colour alone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart' show HermesListRow;
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/models/subagent_steps.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart';
import 'package:hermes_android/core/widgets/chat/chat_live_icon.dart';
import 'package:hermes_android/core/widgets/chat/live_motion.dart';
import 'package:hermes_android/core/widgets/chat/turn_activity_pill.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_cards.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/subagent_work_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final ThemeData _theme = AppTheme.hermesRedDark;
final HermesThemeColors _colors = _theme.extension<HermesThemeColors>()!;

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: _theme,
  home: Scaffold(
    body: SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 412, child: child),
      ),
    ),
  ),
);

TurnStepCardEntry _tool(String id, String tool, {bool failed = false}) =>
    TurnStepCardEntry(
      id: id,
      kind: TurnStepCardKind.tool,
      title: 'Paso $id',
      toolName: tool,
      failed: failed,
      semanticsLabel: 'Paso $id',
    );

/// Any circle painted as a box decoration (a dot, a badge's disc).
Finder _circles(Finder of) => find.descendant(
  of: of,
  matching: find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).shape == BoxShape.circle,
  ),
);

ChatLiveIcon _iconIn(WidgetTester tester, Finder of) => tester.widget(
  find.descendant(of: of, matching: find.byType(ChatLiveIcon)).first,
);

void main() {
  setUp(StepsBarMemory.reset);

  testWidgets('opened line: every row one outline glyph, one size, one quiet '
      'ink; the failed row the error sign in the error ink', (tester) async {
    await tester.pumpWidget(
      _host(
        TurnStepCards(
          entries: [
            _tool('a', 'terminal'),
            _tool('b', 'read_file'),
            _tool('c', 'skill_view'),
            _tool('d', 'search_files', failed: true),
            const TurnStepCardEntry(
              id: 't',
              kind: TurnStepCardKind.thought,
              title: 'Pensó un momento',
              semanticsLabel: 'Pensó un momento',
              duration: Duration(milliseconds: 400),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('turn-line-label')));
    await tester.pumpAndSettle();

    Finder row(String id) => find.byKey(ValueKey('turn-step-card-$id'));
    final a = _iconIn(tester, row('a'));
    final b = _iconIn(tester, row('b'));
    final c = _iconIn(tester, row('c'));
    final d = _iconIn(tester, row('d'));
    // What the step was, as the live row and its pills say it.
    expect(a.glyph, ChatLiveGlyph.terminalAgent);
    expect(b.glyph, ChatLiveGlyph.toolCall);
    expect(c.glyph, ChatLiveGlyph.toolCall);
    for (final icon in [a, b, c]) {
      expect(icon.color, _colors.textSecondary);
      expect(icon.size, HermesIcon.sm);
    }
    // The failure differs in glyph AND ink, never in a filled disc.
    expect(d.glyph, ChatLiveGlyph.error);
    expect(d.color, _colors.error);
    expect(d.color, isNot(a.color));
    expect(d.size, a.size);

    // The thought row: the chat's reasoning glyph, same ink and size.
    final thought = _iconIn(
      tester,
      find.byKey(const ValueKey('turn-inner-thought-t')),
    );
    expect(thought.glyph, ChatLiveGlyph.reasoning);
    expect(thought.color, _colors.textSecondary);
    expect(thought.size, HermesIcon.sm);

    // The folded line's own mark: the outline check in the quiet ink.
    final head = tester.widget<LiveResultMark>(
      find.byKey(const ValueKey('turn-line-mark')),
    );
    expect(head.ok, isFalse, reason: 'one step failed');

    // No circle box, no success green anywhere in the list.
    final list = find.byKey(const ValueKey('turn-step-cards'));
    expect(_circles(list), findsNothing);
    for (final icon in tester.widgetList<ChatLiveIcon>(
      find.descendant(of: list, matching: find.byType(ChatLiveIcon)),
    )) {
      expect(icon.color, isNot(_colors.success));
      expect(icon.color, isNot(_colors.accent));
    }
  });

  testWidgets('the folded line\'s mark: quiet check, error sign on failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const Column(
          children: [
            LiveResultMark(key: ValueKey('ok'), ok: true),
            LiveResultMark(key: ValueKey('ko'), ok: false),
          ],
        ),
      ),
    );
    final ok = _iconIn(tester, find.byKey(const ValueKey('ok')));
    final ko = _iconIn(tester, find.byKey(const ValueKey('ko')));
    expect(ok.glyph, ChatLiveGlyph.check);
    expect(ok.color, _colors.textSecondary);
    expect(ko.glyph, ChatLiveGlyph.error);
    expect(ko.color, _colors.error);
    // No disc is painted, whether the strips are loaded or not (the old
    // mark filled one).
    for (final key in const ['ok', 'ko']) {
      expect(
        tester.renderObject(find.byKey(ValueKey(key))),
        paintsExactlyCountTimes(#drawCircle, 0),
      );
    }
  });

  testWidgets('a running row turns a thin ring in the quiet ink', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        TurnStepCards(
          live: true,
          entries: [
            const TurnStepCardEntry(
              id: 'r',
              kind: TurnStepCardKind.tool,
              title: 'Ejecutando',
              toolName: 'terminal',
              running: true,
              semanticsLabel: 'Ejecutando',
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final ring = tester.widget<LiveRing>(find.byType(LiveRing));
    expect(ring.running, isTrue);
    expect(ring.color, _colors.textSecondary);
    expect(_circles(find.byType(TurnStepCards)), findsNothing);
  });

  testWidgets('the line\'s header: quiet ink settled, error ink failed', (
    tester,
  ) async {
    for (final failed in [false, true]) {
      await tester.pumpWidget(
        _host(
          TurnInlineActivity(
            key: ValueKey(failed),
            label: 'Trabajó',
            live: false,
            failed: failed,
            steps: 3,
            open: false,
            onTap: () {},
          ),
        ),
      );
      // The live look (9 nov): a settled line ends in the green ring with
      // its check inside; a failed one keeps the outline error sign.
      if (failed) {
        final icon = tester.widget<ChatLiveIcon>(find.byType(ChatLiveIcon));
        expect(icon.glyph, ChatLiveGlyph.error);
        expect(icon.color, _colors.error);
      } else {
        expect(find.byType(ChatLiveIcon), findsNothing);
        expect(find.byKey(const ValueKey('live-ring-check')), findsOneWidget);
      }
    }
  });

  testWidgets('«Trabajando» pill: words only, no dot; still a live region', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(const SubagentWorkPill(working: true, showCount: false)),
    );
    await tester.pump();
    expect(find.text('Trabajando'), findsOneWidget);
    final pill = find.byKey(const ValueKey('activity-pill'));
    expect(_circles(pill), findsNothing);
    expect(
      find.descendant(
        of: pill,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).shape == BoxShape.circle,
        ),
      ),
      findsNothing,
    );
    final node = tester.getSemantics(
      find.byKey(const ValueKey('subagent-work-status')),
    );
    expect(node.label, contains('Trabajando'));
    expect(node.flagsCollection.isLiveRegion, isTrue);
    semantics.dispose();
  });

  testWidgets('waiting for the reader stays apart: the warning ink', (
    tester,
  ) async {
    Color inkOf() => tester
        .widget<Text>(find.byKey(const ValueKey('subagent-work-clock')))
        .style!
        .color!;
    await tester.pumpWidget(
      _host(const SubagentWorkPill(working: true, showCount: false)),
    );
    await tester.pump();
    final working = inkOf();
    await tester.pumpWidget(
      _host(
        const SubagentWorkPill(
          working: true,
          showCount: false,
          waitingForUser: true,
        ),
      ),
    );
    await tester.pump();
    final waiting = inkOf();
    expect(waiting, _colors.warning);
    expect(waiting, isNot(working));
    expect(_circles(find.byKey(const ValueKey('activity-pill'))), findsNothing);
  });

  group('subagent detail page', () {
    final scope = SubagentActivityScope(
      connectionId: 'c',
      parentSessionId: 'p',
      runtimeSessionId: 'r',
      turnEpoch: 1,
    );
    SubagentActivity agent(SubagentActivityPhase phase, {String? tool}) =>
        SubagentActivity(
          key: SubagentActivityKey(
            scope: scope,
            identityKind: SubagentIdentityKind.subagent,
            stableId: 'child',
          ),
          source: SubagentActivitySource.native,
          phase: phase,
          subagentId: 'child',
          childSessionId: 'child-session',
          details: SubagentActivityDetails(
            goalPreview: 'Revisar el proyecto',
            activeToolName: tool,
            startedAt: DateTime.utc(2026, 9, 27, 11, 59),
          ),
        );

    Future<void> pump(
      WidgetTester tester,
      SubagentActivity activity,
      SubagentStepLog log,
    ) async {
      final roster = ValueNotifier<List<SubagentActivity>>([activity]);
      addTearDown(roster.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: _theme,
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: SubagentDetailScreen(
            roster: roster,
            activityKey: activity.key,
            parentTitle: 'Chat',
            steps: log,
            clock: () => DateTime.utc(2026, 9, 27, 12),
            routeObserver: RouteObserver<PageRoute<dynamic>>(),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('steps and the step in hand: the chat\'s glyphs, quiet ink, '
        'no dots', (tester) async {
      final log = SubagentStepLog();
      final t0 = DateTime.utc(2026, 9, 27, 11, 59);
      log.observe(agent(SubagentActivityPhase.thinking), t0);
      log.observe(
        agent(SubagentActivityPhase.tool, tool: 'terminal'),
        t0.add(const Duration(seconds: 5)),
      );
      await pump(
        tester,
        agent(SubagentActivityPhase.tool, tool: 'terminal'),
        log,
      );
      final steps = find.byKey(const ValueKey('subagent-detail-steps'));
      await tester.scrollUntilVisible(steps, 200);
      final first = tester.widget<ChatLiveIcon>(
        find.byKey(const ValueKey('subagent-detail-step-icon-0')),
      );
      final second = tester.widget<ChatLiveIcon>(
        find.byKey(const ValueKey('subagent-detail-step-icon-1')),
      );
      expect(first.glyph, ChatLiveGlyph.reasoning);
      expect(first.live, isFalse);
      expect(second.glyph, ChatLiveGlyph.terminalAgent);
      expect(second.live, isTrue, reason: 'the step in hand plays');
      for (final icon in [first, second]) {
        expect(icon.color, _colors.textSecondary);
        expect(icon.size, HermesIcon.sm);
      }
      expect(_circles(steps), findsNothing);
      final timeline = find.byKey(const ValueKey('subagent-detail-timeline'));
      expect(_circles(timeline), findsNothing);
      final current = tester.widget<ChatLiveIcon>(
        find.byKey(const ValueKey('subagent-detail-current-icon')),
      );
      expect(current.glyph, ChatLiveGlyph.terminalAgent);
      expect(current.color, _colors.textSecondary);
    });

    testWidgets('«Qué ha hecho» of a finished agent: every row has its mark', (
      tester,
    ) async {
      final done = SubagentActivity(
        key: SubagentActivityKey(
          scope: scope,
          identityKind: SubagentIdentityKind.subagent,
          stableId: 'child',
        ),
        source: SubagentActivitySource.native,
        phase: SubagentActivityPhase.completed,
        subagentId: 'child',
        childSessionId: 'child-session',
        details: SubagentActivityDetails(
          goalPreview: 'Revisar el proyecto',
          startedAt: DateTime.utc(2026, 9, 27, 11, 59),
          completedAt: DateTime.utc(2026, 9, 27, 11, 59, 4),
          toolCount: 2,
        ),
      );
      await pump(tester, done, SubagentStepLog());
      final timeline = find.byKey(const ValueKey('subagent-detail-timeline'));
      final rows = find.descendant(
        of: timeline,
        matching: find.byType(HermesListRow),
      );
      // Empezó, Terminó (clock), 2 herramientas, Terminó (elapsed).
      expect(rows, findsNWidgets(4));
      for (final row in tester.widgetList<HermesListRow>(rows)) {
        expect(
          find.descendant(
            of: find.byWidget(row),
            matching: find.byType(ChatLiveIcon),
          ),
          findsOneWidget,
        );
      }
      for (final icon in tester.widgetList<ChatLiveIcon>(
        find.descendant(of: timeline, matching: find.byType(ChatLiveIcon)),
      )) {
        expect(icon.color, _colors.textSecondary);
        expect(icon.live, isFalse);
      }
      expect(
        tester
            .widget<ChatLiveIcon>(
              find.byKey(const ValueKey('subagent-detail-fact-icon-1')),
            )
            .glyph,
        ChatLiveGlyph.check,
      );
      expect(_circles(timeline), findsNothing);
    });

    testWidgets('a failure keeps the outline sign, in the error ink only', (
      tester,
    ) async {
      for (final phase in [
        SubagentActivityPhase.completed,
        SubagentActivityPhase.failed,
      ]) {
        await pump(tester, agent(phase), SubagentStepLog());
        final current = tester.widget<ChatLiveIcon>(
          find.byKey(const ValueKey('subagent-detail-current-icon')),
        );
        final failed = phase == SubagentActivityPhase.failed;
        expect(
          current.glyph,
          failed ? ChatLiveGlyph.error : ChatLiveGlyph.check,
        );
        expect(current.color, failed ? _colors.error : _colors.textSecondary);
        expect(current.live, isFalse);
        expect(
          _circles(find.byKey(const ValueKey('subagent-detail-timeline'))),
          findsNothing,
        );
      }
    });
  });
}
