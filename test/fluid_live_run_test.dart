// CHAT-FLUIDO 5: a live run of two or more tool calls gets a header, like
// Hermes Desktop's ToolRun (components/assistant-ui/tool/fallback.tsx):
// closed it shows only the call in hand (Desktop's ticker), open every
// call of the run. One call: no header. Mock 138 v2: the header is the
// fold of the calls already made, «2 herramientas · 0:07».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final _start = DateTime(2026, 10, 26, 12);

ChatTraceEvent _call(String id, {bool running = false}) => ChatTraceEvent(
  id: id,
  label: 'terminal',
  status: running ? 'running' : 'completed',
  detail: 'cmd-$id',
  startedAt: _start,
  duration: running ? null : const Duration(milliseconds: 400),
);

Widget _host(List<ChatTraceEvent> events) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: SingleChildScrollView(
      child: LiveTurnScope(
        status: LiveTurnStatus(active: true, startedAt: _start),
        clock: () => _start.add(const Duration(seconds: 7)),
        child: ThinkingTraceCard(
          events: events,
          active: true,
          liveInPill: true,
          headerBuilder: (context, summary, details) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [summary, details],
          ),
        ),
      ),
    ),
  ),
);

final _header = find.byKey(const ValueKey('turn-run-header'));
final _rows = find.byType(TurnToolRow);

void main() {
  final strings = lookupStrings(const Locale('es'));

  testWidgets('one call: no header, the call in hand', (tester) async {
    await tester.pumpWidget(_host([_call('a', running: true)]));
    expect(_header, findsNothing);
    expect(_rows, findsOneWidget);
  });

  testWidgets('a run: the calls made fold into «N herramientas»; closed, '
      'the call in hand only', (tester) async {
    // Mock 138 v2 (the owner, 1.4.0): «2 herramientas · 0:07», only the call in
    // hand has a line of its own. It used to say what the run used
    // («3 comandos»); the finished turn still does. These calls took 0.4 s
    // each: under a second the fold says no time.
    final run = [_call('a'), _call('b'), _call('c', running: true)];
    await tester.pumpWidget(_host(run));
    expect(_header, findsOneWidget);
    expect(find.text(strings.tk140ToolsCount(2)), findsOneWidget);
    // Desktop's ticker: the call in hand.
    expect(_rows, findsOneWidget);
  });

  testWidgets('the fold adds up the time of the calls it holds', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    ChatTraceEvent slow(String id) => ChatTraceEvent(
      id: id,
      label: 'terminal',
      status: 'completed',
      detail: 'cmd-$id',
      startedAt: _start,
      duration: const Duration(seconds: 4),
    );
    await tester.pumpWidget(
      _host([slow('a'), slow('b'), _call('c', running: true)]),
    );
    expect(find.text('2 herramientas · 8s'), findsOneWidget);
    expect(tester.getSemantics(_header).label, '2 herramientas, 8 segundos');
    semantics.dispose();
  });

  testWidgets('open: every call of the run, oldest first', (tester) async {
    await tester.pumpWidget(
      _host([_call('a'), _call('b'), _call('c', running: true)]),
    );
    await tester.tap(_header);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_rows, findsNWidgets(3));
    final tops = [
      for (final id in ['a', 'b', 'c'])
        tester.getTopLeft(find.byKey(ValueKey('turn-enter-step-$id'))).dy,
    ];
    expect(tops[0], lessThan(tops[1]));
    expect(tops[1], lessThan(tops[2]));
    // Closing it goes back to the call in hand.
    await tester.tap(_header);
    await tester.pump();
    expect(_rows, findsOneWidget);
  });

  testWidgets('the header opens from a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host([_call('a'), _call('b', running: true)]));
    expect(
      tester.getSemantics(_header),
      isSemantics(isButton: true, hasTapAction: true),
    );
    semantics.dispose();
  });
}
