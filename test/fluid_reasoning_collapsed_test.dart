// CHAT-FLUIDO 3: Hermes Desktop's «Collapse thinking by default»
// (store/reasoning-disclosure.ts).
//
// Mock 137 A (the owner, 1.4.0, §5 «Ajustes y servidor»): on by default, the
// thought being written is one thin line, «Pensando… · 7 s» with its last
// sentence, that the reader opens to six lines. Off is Console before 1.4.0:
// open at six lines while it thinks. The line is there either way.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/reasoning_disclosure_prefs.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _start = DateTime(2026, 10, 26, 12);

Widget _live() => MaterialApp(
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
          events: [
            ChatTraceEvent(
              id: 'r1',
              label: 'Razonamiento',
              status: 'running',
              kind: ChatTraceEventKind.reasoning,
              preview: 'Primero miro el log reciente.',
              startedAt: _start,
            ),
          ],
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

final _toggle = find.byKey(const ValueKey('turn-thought-toggle'));
final _quote = find.byKey(const ValueKey('turn-reasoning'));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ReasoningDisclosurePrefs.load();
  });

  tearDown(() => ReasoningDisclosurePrefs.debugUse(null));

  group('preference', () {
    test('on by default (mock 137 A: one line)', () {
      expect(ReasoningDisclosurePrefs.shared.collapsedByDefault, isTrue);
    });

    test('kept on the device both ways', () async {
      final prefs = await SharedPreferences.getInstance();
      await ReasoningDisclosurePrefs.shared.setCollapsedByDefault(false);
      expect(prefs.getBool(ReasoningDisclosurePrefs.key), isFalse);
      final reloaded = await ReasoningDisclosurePrefs.load(prefs);
      expect(reloaded.collapsedByDefault, isFalse);
      await reloaded.setCollapsedByDefault(true);
      expect(prefs.getBool(ReasoningDisclosurePrefs.key), isTrue);
    });

    test('listeners hear a change', () async {
      var heard = 0;
      final prefs = ReasoningDisclosurePrefs.shared..addListener(() => heard++);
      await prefs.setCollapsedByDefault(false);
      await prefs.setCollapsedByDefault(false);
      expect(heard, 1);
    });
  });

  testWidgets('on (default): one line with its time and last sentence; a tap '
      'opens six lines, and they stay open', (tester) async {
    await tester.pumpWidget(_live());
    expect(_toggle, findsOneWidget);
    expect(
      find.descendant(of: _toggle, matching: find.text('Pensando…')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _toggle, matching: find.text('7 s')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('turn-thought-snippet')))
          .data,
      'Primero miro el log reciente.',
    );
    expect(_quote, findsNothing);
    // The line is a 48 dp target of fixed height.
    expect(tester.getSize(_toggle).height, 48);
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_quote, findsOneWidget);
    expect(find.byKey(const ValueKey('turn-thought-snippet')), findsNothing);
    // A new reasoning delta does not close what the reader opened.
    await tester.pumpWidget(_live());
    expect(_quote, findsOneWidget);
  });

  testWidgets('off: open at six lines while it thinks, under its line', (
    tester,
  ) async {
    await ReasoningDisclosurePrefs.shared.setCollapsedByDefault(false);
    await tester.pumpWidget(_live());
    expect(_toggle, findsOneWidget);
    expect(_quote, findsOneWidget);
    expect(find.text('Primero miro el log reciente.'), findsOneWidget);
  });

  testWidgets('switching the setting updates a live turn on screen', (
    tester,
  ) async {
    await tester.pumpWidget(_live());
    expect(_quote, findsNothing);
    await ReasoningDisclosurePrefs.shared.setCollapsedByDefault(false);
    await tester.pump();
    expect(_quote, findsOneWidget);
    expect(_toggle, findsOneWidget);
  });
}
