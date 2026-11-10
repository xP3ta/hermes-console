// Mock 138 v2 (the owner, 1.4.0): the tools of a turn are round pills of one
// line, preparing → running (with its timer) → done; the calls already made
// fold into «N herramientas · 0:07», and a finished turn says «Trabajó N s».
// Nothing blurs and nothing keeps the screen drawing: the ring turns on the
// turn's beat, never in a loop.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final _start = DateTime(2026, 10, 28, 12);
final _colors = AppTheme.hermesRedDark.hermes;

Widget _app(Widget child, {bool reduceMotion = false}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: home!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(child: SizedBox(width: 360, child: child)),
  ),
);

ActivityStep _step(
  ActivityStepStatus status, {
  DateTime? startedAt,
  Duration? duration,
}) => ActivityStep(
  id: 't',
  kind: ActivityStepKind.tool,
  label: 'terminal',
  status: status,
  detail: 'df -h',
  startedAt: startedAt,
  duration: duration,
);

Widget _pill(ActivityStep step, {bool reduceMotion = false}) => _app(
  TurnToolRow(step: step, clock: () => _start.add(const Duration(seconds: 2))),
  reduceMotion: reduceMotion,
);

final _row = find.byType(TurnToolRow);

// gint48: the ring's round seat is a DecoratedBox too; the pill is keyed.
ShapeDecoration _shape(WidgetTester tester) =>
    tester
            .widget<DecoratedBox>(
              find.descendant(
                of: _row,
                matching: find.byKey(const ValueKey('turn-tool-pill')),
              ),
            )
            .decoration
        as ShapeDecoration;

Widget _turn(
  List<ChatTraceEvent> events, {
  bool active = true,
  Duration? duration,
}) => _app(
  LiveTurnScope(
    status: LiveTurnStatus(active: active, startedAt: _start),
    clock: () => _start.add(const Duration(seconds: 20)),
    child: ThinkingTraceCard(
      events: events,
      active: active,
      duration: duration,
      liveInPill: true,
      headerBuilder: (context, summary, details) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [summary, details],
      ),
    ),
  ),
);

ChatTraceEvent _tool(
  String id, {
  String status = 'completed',
  DateTime? startedAt,
  Duration? duration,
}) => ChatTraceEvent(
  id: id,
  label: 'terminal',
  status: status,
  detail: 'cmd-$id',
  startedAt: startedAt,
  duration: duration,
);

void main() {
  setUp(TurnEnter.debugForget);

  group('the pill', () {
    testWidgets('running: one round line, accent ring, its own timer', (
      tester,
    ) async {
      await tester.pumpWidget(
        _pill(_step(ActivityStepStatus.running, startedAt: _start)),
      );
      final shape = _shape(tester);
      expect(shape.shape, isA<StadiumBorder>());
      expect(shape.color, isNull, reason: 'only a finished pill is tinted');
      // 32 dp of pill and 2 above and below.
      expect(tester.getSize(_row).height, TurnToolRow.pillHeight + 4);
      final text = tester.widget<Text>(
        find.descendant(of: _row, matching: find.byType(Text)).first,
      );
      expect(text.textSpan!.toPlainText(), 'Ejecutando · df');
      expect(text.maxLines, 1);
      expect(
        find.descendant(of: _row, matching: find.text('2s')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('turn-tool-spin')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('preparing: grey, no ring that turns, no timer', (
      tester,
    ) async {
      await tester.pumpWidget(_pill(_step(ActivityStepStatus.running)));
      expect(find.byKey(const ValueKey('turn-tool-spin')), findsNothing);
      expect(
        find.descendant(of: _row, matching: find.text('2s')),
        findsNothing,
      );
      final title =
          tester
                  .widget<Text>(
                    find.descendant(of: _row, matching: find.byType(Text)),
                  )
                  .textSpan!
              as TextSpan;
      expect(
        title.children!.first.style!.color,
        _colors.textSecondary,
        reason: 'what is not running yet is not in full ink',
      );
    });

    testWidgets('done: tinted, a tick, how long it took', (tester) async {
      await tester.pumpWidget(
        _pill(
          _step(
            ActivityStepStatus.done,
            startedAt: _start,
            duration: const Duration(milliseconds: 700),
          ),
        ),
      );
      expect(_shape(tester).color, _colors.success.withValues(alpha: 0.12));
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: _row, matching: find.byType(Icon)),
            )
            .color,
        _colors.success,
      );
      expect(find.text('0,7 s'), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-tool-spin')), findsNothing);
    });

    testWidgets('failed: the error tint and its glyph', (tester) async {
      await tester.pumpWidget(_pill(_step(ActivityStepStatus.failed)));
      expect(_shape(tester).color, _colors.error.withValues(alpha: 0.12));
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: _row, matching: find.byType(Icon)),
            )
            .icon,
        Icons.error_outline_rounded,
      );
    });

    testWidgets('the ring turns once on the beat, then the screen rests', (
      tester,
    ) async {
      await tester.pumpWidget(
        _pill(_step(ActivityStepStatus.running, startedAt: _start)),
      );
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester.hasRunningAnimations,
        isFalse,
        reason: 'no loop: a running tool does not keep the screen drawing',
      );
    });

    testWidgets('reduced motion: the ring stays still', (tester) async {
      await tester.pumpWidget(
        _pill(
          _step(ActivityStepStatus.running, startedAt: _start),
          reduceMotion: true,
        ),
      );
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('TalkBack reads what it does, on what, and its state', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _pill(
          _step(
            ActivityStepStatus.done,
            duration: const Duration(milliseconds: 700),
          ),
        ),
      );
      expect(tester.getSemantics(_row).label, 'Ejecutó, df, hecho, 0,7 s');
      semantics.dispose();
    });
  });

  group('the turn', () {
    testWidgets('a finished turn that used tools: «Trabajó N s» in bold', (
      tester,
    ) async {
      await tester.pumpWidget(
        _turn(
          [_tool('a'), _tool('b'), _tool('c')],
          active: false,
          duration: const Duration(seconds: 12),
        ),
      );
      final summary = find.byKey(const ValueKey('thinking-trace-summary'));
      expect(find.text('Trabajó 12 s · 3 comandos'), findsOneWidget);
      final text = tester.widget<Text>(
        find.descendant(of: summary, matching: find.byType(Text)),
      );
      final lead = (text.textSpan! as TextSpan).children!.first as TextSpan;
      expect(lead.text, 'Trabajó 12 s · ');
      expect(lead.style!.fontWeight, FontWeight.w600);
      expect(
        find.descendant(of: summary, matching: find.byIcon(Icons.done_rounded)),
        findsOneWidget,
      );
    });

    testWidgets('an opened turn shows its thought whole; its line folds it', (
      tester,
    ) async {
      // gint48: a thought folded again inside a turn the reader opened was
      // out of the tree (TalkBack, a reader who had asked to see it).
      await tester.pumpWidget(
        _turn(
          [
            ChatTraceEvent(
              id: 'r',
              label: 'Razonamiento',
              status: 'completed',
              kind: ChatTraceEventKind.reasoning,
              preview: 'PENSAMIENTO_DEL_TURNO_ABIERTO',
            ),
            _tool('a'),
          ],
          active: false,
          duration: const Duration(seconds: 5),
        ),
      );
      final semantics = tester.ensureSemantics();
      final reasoning = find.byKey(const ValueKey('turn-reasoning'));
      final spoken = find.bySemanticsLabel(
        RegExp('PENSAMIENTO_DEL_TURNO_ABIERTO'),
      );
      // A fold or unfold animates its height (HermesMotion.base, 200 ms):
      // the first frame after the tap starts it, the next one passes its
      // end. gint49: with a single 300 ms frame the opened turn was still
      // 0 dp high, so the tap on the thought's line hit nothing.
      Future<void> tapAndSettleFold(Finder target) async {
        await tester.tap(target);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(reasoning, findsNothing, reason: 'the turn is folded');
      expect(spoken, findsNothing);
      await tapAndSettleFold(
        find.byKey(const ValueKey('thinking-trace-summary')),
      );
      expect(reasoning, findsOneWidget);
      expect(
        find.textContaining('PENSAMIENTO_DEL_TURNO_ABIERTO'),
        findsOneWidget,
      );
      expect(spoken, findsOneWidget, reason: 'opened, TalkBack reads it');
      // Its line folds it, and opens it again.
      final line = find.descendant(
        of: find.byKey(const ValueKey('thinking-trace-step-r')),
        matching: find.byKey(const ValueKey('turn-thought-toggle')),
      );
      await tapAndSettleFold(line);
      expect(reasoning, findsNothing);
      // Folded is out of the tree, so TalkBack cannot read it either.
      expect(spoken, findsNothing);
      await tapAndSettleFold(line);
      expect(reasoning, findsOneWidget);
      expect(spoken, findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a turn that only thought keeps «Pensó durante»', (
      tester,
    ) async {
      await tester.pumpWidget(
        _turn(
          [
            ChatTraceEvent(
              id: 'r',
              label: 'Razonamiento',
              status: 'completed',
              kind: ChatTraceEventKind.reasoning,
              preview: 'Solo pienso.',
            ),
          ],
          active: false,
          duration: const Duration(seconds: 9),
        ),
      );
      expect(find.text('Pensó durante 9s'), findsOneWidget);
      expect(find.textContaining('Trabajó'), findsNothing);
    });

    testWidgets('a thought a tool followed is over: «Pensamiento · 4 s»', (
      tester,
    ) async {
      await tester.pumpWidget(
        _turn([
          ChatTraceEvent(
            id: 'r',
            label: 'Razonamiento',
            // The gateway keeps it «running» until the turn ends.
            status: 'running',
            kind: ChatTraceEventKind.reasoning,
            preview: 'Primero miro el disco.',
            startedAt: _start,
          ),
          _tool(
            'a',
            status: 'running',
            startedAt: _start.add(const Duration(seconds: 4)),
          ),
        ]),
      );
      final line = find.byKey(const ValueKey('turn-thought-toggle'));
      expect(
        find.descendant(of: line, matching: find.text('Pensamiento')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: line, matching: find.text('4 s')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('turn-thought-snippet')), findsNothing);
    });

    testWidgets('the newest thought is live: «Pensando…»', (tester) async {
      await tester.pumpWidget(
        _turn([
          _tool('a', duration: const Duration(seconds: 1)),
          ChatTraceEvent(
            id: 'r',
            label: 'Razonamiento',
            status: 'running',
            kind: ChatTraceEventKind.reasoning,
            preview: 'Ahora leo el resultado.',
            startedAt: _start.add(const Duration(seconds: 8)),
          ),
        ]),
      );
      final line = find.byKey(const ValueKey('turn-thought-toggle'));
      expect(
        find.descendant(of: line, matching: find.text('Pensando…')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('turn-thought-snippet')),
        findsOneWidget,
      );
    });

    testWidgets('a pill that comes in slides and fades, then is plain', (
      tester,
    ) async {
      await tester.pumpWidget(_turn([_tool('a', status: 'running')]));
      await tester.pump();
      await tester.pumpWidget(
        _turn([
          _tool('a', duration: const Duration(seconds: 1)),
          _tool('b', status: 'running', startedAt: _start),
        ]),
      );
      final fade = find.descendant(
        of: find.byKey(const ValueKey('turn-enter-step-b')),
        matching: find.byKey(const ValueKey('turn-enter-fade')),
      );
      expect(fade, findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing, reason: 'no blur');
      await tester.pump();
      await tester.pump(TurnEnter.duration + const Duration(milliseconds: 20));
      expect(fade, findsNothing);
      // The fold took the call that was made; the one in hand is its pill.
      expect(find.text('1 herramienta · 1s'), findsOneWidget);
      expect(find.byType(TurnToolRow), findsOneWidget);
    });
  });
}
