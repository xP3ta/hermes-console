// Q9-CHAT5 v2: the chat's turn told as step cards
// (ThinkingTraceCard.stepCards). Under the name only what the turn already
// did: the step in hand and a thought being written are the pills' above
// the composer; what a running tool already left to see shows at once.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart' show HermesMotion;
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/message_avatar_header.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(12), child: child),
    ),
  ),
);

Widget _turn(
  List<ChatTraceEvent> events, {
  required bool active,
  bool stopped = false,
  bool stepCards = true,
  Map<String, Widget> rowAttachments = const {},
}) => ThinkingTraceCard(
  events: events,
  active: active,
  liveInPill: true,
  stopped: stopped,
  stepCards: stepCards,
  duration: active ? null : const Duration(seconds: 28),
  rowAttachments: rowAttachments,
  headerBuilder: (context, summary, details) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      MessageAvatarHeader(name: 'Hermes', subtitle: summary),
      details,
    ],
  ),
);

ChatTraceEvent _thought(String id, {bool running = false}) => ChatTraceEvent(
  id: id,
  label: 'Razonamiento',
  status: running ? 'running' : 'completed',
  kind: ChatTraceEventKind.reasoning,
  preview: 'El usuario quiere la maqueta.',
  duration: running ? null : const Duration(seconds: 8),
);

ChatTraceEvent _tool(String id, {String status = 'completed'}) =>
    ChatTraceEvent(
      id: id,
      label: 'terminal',
      status: status,
      detail: 'cp maqueta.html /tmp',
      duration: status == 'running' ? null : const Duration(milliseconds: 2900),
    );

Finder _card(String id) => find.byKey(ValueKey('turn-step-card-$id'));
Finder _line(String id) => find.byKey(ValueKey('turn-line-$id'));
Finder _label() => find.byKey(const ValueKey('turn-line-label'));

void main() {
  setUp(StepsBarMemory.reset);

  testWidgets(
    'QA9715 live thought stays in one compact transcript disclosure',
    (tester) async {
      Widget thought(String text) => _host(
        ThinkingTraceCard(
          events: [
            ChatTraceEvent(
              id: 'live',
              label: 'Pensamiento',
              kind: ChatTraceEventKind.reasoning,
              status: 'running',
              preview: text,
            ),
          ],
          active: true,
          liveInPill: false,
          stepCards: true,
          headerBuilder: (_, summary, details) => details,
        ),
      );
      await tester.pumpWidget(thought('Public reasoning prefix.'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      // ONE folded line: the brain and what it holds (the header's pill
      // says «Pensando»); nothing of the text shows until it is opened.
      expect(find.byKey(const ValueKey('turn-thought-brain')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('turn-thought-label')))
            .data,
        'Pensamiento',
      );
      expect(find.byKey(const ValueKey('turn-thought-tail')), findsNothing);
      expect(
        find.textContaining('Public reasoning prefix.', findRichText: true),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('turn-line-label')), findsNothing);
      await tester.pumpWidget(
        thought('Public reasoning prefix. More public text.'),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('turn-thought-label')), findsOneWidget);
      expect(
        find.textContaining('More public text.', findRichText: true),
        findsNothing,
      );
      // A tap opens it, in the reading size of the chat.
      await tester.tap(find.byKey(const ValueKey('turn-thought-label')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.textContaining('More public text.', findRichText: true),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('live-turn-status')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('live: no status line under the name; the finished thought and '
      'tool are rows of the one line, the tool in hand is not', (tester) async {
    await tester.pumpWidget(
      _host(
        _turn([
          _thought('r', running: true),
          _tool('a'),
          _tool('b', status: 'running'),
        ], active: true),
      ),
    );
    expect(find.byKey(const ValueKey('turn-status-line')), findsNothing);
    expect(
      find.byKey(const ValueKey('turn-step-cards-no-status')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 500));
    // The turn lives: its tools are an open timeline (no fold yet); a
    // thought kept «running» by the gateway but followed by a tool is over.
    expect(find.byKey(const ValueKey('turn-thought-label')), findsNothing);
    expect(
      tester.widget<Text>(_label()).data,
      'Trabajó · Ejecutó 1 comando',
      reason: 'the finished thought and tool are ONE folded line',
    );
    expect(_card('a'), findsNothing);
    await tester.tap(_label());
    await tester.pumpAndSettle();
    expect(_card('a'), findsOneWidget);
    expect(_card('b'), findsNothing, reason: 'the pills say it');
    expect(find.text('Pensando…'), findsNothing);
  });

  testWidgets('live: a thought being written is the pills\', not a card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_turn([_tool('a'), _thought('r', running: true)], active: true)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(_card('r'), findsNothing);
    expect(_line('a'), findsOneWidget);
    expect(_label(), findsOneWidget, reason: 'what is done is one line');
    expect(_card('a'), findsNothing);
    await tester.tap(_label());
    await tester.pumpAndSettle();
    expect(_card('a'), findsOneWidget);
  });

  testWidgets('live: what a running tool already left shows at once (F5)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _turn(
          [_tool('img', status: 'running')],
          active: true,
          rowAttachments: const {
            'img': SizedBox(key: ValueKey('generated-image'), height: 80),
          },
        ),
      ),
    );
    expect(_card('img'), findsNothing);
    expect(find.byKey(const ValueKey('generated-image')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('activity-step-attachment-img')),
      findsOneWidget,
    );
  });

  testWidgets('settled: the thought is «Pensó», the tools ONE line that says '
      'how long it worked and opens into them', (tester) async {
    await tester.pumpWidget(
      _host(_turn([_thought('r'), _tool('a'), _tool('b')], active: false)),
    );
    expect(_line('r'), findsOneWidget, reason: 'the thought is in the line');
    expect(find.byKey(const ValueKey('turn-thought-label')), findsNothing);
    expect(find.text('Trabajó 0:28 · Ejecutó 2 comandos'), findsOneWidget);
    expect(find.text('Pensó 8 s'), findsNothing);
    expect(_card('a'), findsNothing);
    await tester.tap(_label());
    await tester.pumpAndSettle();
    expect(_card('a'), findsOneWidget);
    expect(_card('b'), findsOneWidget);
    expect(find.text('Pensó 8 s'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('turn-inner-thought-label-r')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('turn-reasoning')), findsOneWidget);
    expect(find.byKey(const ValueKey('thinking-trace-summary')), findsNothing);
    expect(find.byKey(const ValueKey('turn-worked-pill')), findsNothing);
  });

  testWidgets('a stopped turn says so in a card of its own', (tester) async {
    await tester.pumpWidget(
      _host(_turn([_tool('a')], active: false, stopped: true)),
    );
    expect(_card('outcome'), findsOneWidget);
    expect(
      find.descendant(
        of: _card('outcome'),
        matching: find.byIcon(Icons.stop_circle_outlined),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a failed or recovered turn says its outcome in words, not by '
      'colour alone (gint67)', (tester) async {
    await tester.pumpWidget(
      _host(_turn([_tool('a', status: 'failed')], active: false)),
    );
    expect(_card('outcome'), findsOneWidget);
    expect(
      find.descendant(
        of: _card('outcome'),
        matching: find.textContaining('Error'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(
      _host(_turn([_tool('a', status: 'failed'), _tool('b')], active: false)),
    );
    expect(
      find.descendant(
        of: _card('outcome'),
        matching: find.byIcon(Icons.warning_amber_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _card('outcome'),
        matching: find.text('Completado tras reintentar'),
      ),
      findsOneWidget,
    );
    // The card does not open: it invites no tap («ver detalles»).
    expect(find.textContaining('detalles'), findsNothing);
    // A turn that ended well has no outcome card: its cards say it.
    final cards = find.byKey(const ValueKey('turn-step-cards'));
    final beforeExit = tester.getSize(cards).height;
    await tester.pumpWidget(_host(_turn([_tool('a')], active: false)));
    expect(_card('outcome'), findsOneWidget, reason: 'one departing visual');
    final halfExit = Duration(
      microseconds: HermesMotion.base.inMicroseconds ~/ 2,
    );
    await tester.pump(halfExit);
    expect(tester.getSize(cards).height, lessThan(beforeExit));
    expect(
      tester.getSize(cards).height,
      greaterThan(tester.getSize(_line('a')).height),
      reason: 'the old outcome shrinks instead of cutting out',
    );
    await tester.pump(halfExit);
    await tester.pump(); // remove the slot after its post-frame onGone
    expect(_card('outcome'), findsNothing);
  });

  testWidgets('a departing recovered outcome leaves semantics immediately', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _host(_turn([_tool('a', status: 'failed'), _tool('b')], active: false)),
      );
      expect(
        find.bySemanticsLabel('Completado tras reintentar'),
        findsOneWidget,
      );
      expect(find.semantics.byLabel('Completado tras reintentar'), findsOne);
      await tester.pumpWidget(_host(_turn([_tool('a')], active: false)));
      expect(_card('outcome'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Completado tras reintentar'),
        findsOneWidget,
        reason: 'the departing widget still owns its cached semantics data',
      );
      expect(
        find.semantics.byLabel('Completado tras reintentar'),
        findsNothing,
        reason: 'the connected accessibility tree excludes the old outcome',
      );
      await tester.pump(HermesMotion.base);
      await tester.pump();
      expect(_card('outcome'), findsNothing);
      expect(find.bySemanticsLabel('Completado tras reintentar'), findsNothing);
      expect(_line('a'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('settled: a call still without its result is not rebuilt as a '
      'card (it may be a turn another surface runs)', (tester) async {
    await tester.pumpWidget(
      _host(
        _turn([
          _tool('done'),
          _tool('PRIVATE', status: 'running'),
        ], active: false),
      ),
    );
    expect(_line('done'), findsOneWidget);
    expect(find.text('Trabajó 0:28 · Ejecutó 1 comando'), findsOneWidget);
    await tester.tap(_label());
    await tester.pump(const Duration(milliseconds: 400));
    expect(_card('done'), findsOneWidget);
    expect(_card('PRIVATE'), findsNothing);
    expect(find.text('cp'), findsOneWidget);
    expect(find.textContaining('cp maqueta'), findsNothing);
  });

  testWidgets('a turn stopped here keeps the step it cut short, said as '
      'stopped, never done', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        _turn(
          [_tool('a'), _tool('cut', status: 'running')],
          active: false,
          stopped: true,
        ),
      ),
    );
    // The cut-short call is never «completado»: its row says failed, and the
    // outcome card after it says «Detenido».
    expect(_line('a'), findsOneWidget);
    expect(find.text('Completado'), findsNothing);
    await tester.tap(_label());
    await tester.pump(const Duration(milliseconds: 400));
    expect(_card('cut'), findsOneWidget);
    // Steps now carry their tool glyph (the chat's one outline icon family),
    // so the card has an icon: what it must never show is a «done» check.
    expect(
      find.descendant(
        of: _card('cut'),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              <IconData>{
                Icons.check,
                Icons.check_circle,
                Icons.check_circle_outline,
                Icons.done,
                Icons.done_all,
              }.contains(w.icon),
        ),
      ),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.key == const ValueKey('turn-step-card-cut') &&
            (w.properties.label ?? '').endsWith('Detenido'),
      ),
      findsOneWidget,
    );
    expect(_card('outcome'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('off, the transcript lines of 137 A / 138 v2 are unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_turn([_tool('a')], active: false, stepCards: false)),
    );
    expect(
      find.byKey(const ValueKey('thinking-trace-summary')),
      findsOneWidget,
    );
    expect(_card('a'), findsNothing);
  });
}
