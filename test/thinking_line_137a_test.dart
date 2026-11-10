// Mock 137, variant A (the owner, 1.4.0): the model's thinking is one thin line
// that never loads the screen. Live: «Pensando… · 12 s», a live dot and the
// last sentence; a tap opens six lines, another the whole thought, a third
// folds it back. Finished: «Pensamiento · 12 s», a tap opens it whole.
// Hermes Desktop: ThinkingDisclosure, message-parts.tsx l.219-362.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/reasoning_disclosure_prefs.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _start = DateTime(2026, 10, 28, 12);

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
    body: SingleChildScrollView(
      child: SizedBox(width: 360, child: child),
    ),
  ),
);

String _long(int n) => [
  for (var i = 0; i < n; i++) 'Frase $i del pensamiento.',
].join('\n\n');

final _line = find.byKey(const ValueKey('turn-thought-toggle'));
final _body = find.byKey(const ValueKey('turn-reasoning'));
final _snippet = find.byKey(const ValueKey('turn-thought-snippet'));

Future<void> _tap(WidgetTester tester) async {
  await tester.tap(_line);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ReasoningDisclosurePrefs.load();
  });
  tearDown(() => ReasoningDisclosurePrefs.debugUse(null));

  testWidgets('live: one line whose height never changes while it thinks', (
    tester,
  ) async {
    var now = _start.add(const Duration(seconds: 12));
    Widget live(String text) => _app(
      ThinkingLine(text: text, live: true, startedAt: _start, clock: () => now),
    );
    await tester.pumpWidget(live('Miro el log.'));
    expect(tester.getSize(_line).height, 48);
    expect(
      find.descendant(of: _line, matching: find.text('Pensando…')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _line, matching: find.text('12 s')),
      findsOneWidget,
    );
    expect(tester.widget<Text>(_snippet).data, 'Miro el log.');
    expect(_body, findsNothing);
    final height = tester.getSize(find.byType(ThinkingLine)).height;
    // More words: the line says the newest sentence, the height stays.
    await tester.pumpWidget(live('Miro el log. Ahora busco el error.'));
    expect(tester.widget<Text>(_snippet).data, 'Ahora busco el error.');
    await tester.pumpWidget(live(_long(80)));
    expect(tester.getSize(find.byType(ThinkingLine)).height, height);
    // The time counts on its own, once a second.
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.descendant(of: _line, matching: find.text('13 s')),
      findsOneWidget,
    );
  });

  testWidgets('live: line → six lines → whole → line', (tester) async {
    await tester.pumpWidget(
      _app(
        ThinkingLine(
          text: _long(60),
          live: true,
          startedAt: _start,
          clock: () => _start,
        ),
      ),
    );
    // The thought is 12.5 sp now (9 nov live look); the box is still six
    // lines of whatever the thought's size is.
    const six =
        TurnType.reasoning *
        TurnReasoningQuote.lineHeight *
        ThinkingLine.previewLines;
    await _tap(tester);
    expect(_body, findsOneWidget);
    expect(_snippet, findsNothing);
    expect(tester.getSize(_body).height, closeTo(six + 8, 0.5));
    await _tap(tester);
    expect(tester.getSize(_body).height, greaterThan(six * 3));
    await _tap(tester);
    expect(_body, findsNothing);
    expect(_snippet, findsOneWidget);
  });

  testWidgets('finished: «Pensamiento · 12 s», a tap opens it whole', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        ThinkingLine(
          text: _long(30),
          duration: const Duration(seconds: 12, milliseconds: 400),
        ),
      ),
    );
    expect(
      find.descendant(of: _line, matching: find.text('Pensamiento')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _line, matching: find.text('12 s')),
      findsOneWidget,
    );
    expect(_snippet, findsNothing, reason: 'finished: no sentence on the line');
    expect(_body, findsNothing);
    await _tap(tester);
    expect(
      find.descendant(of: _body, matching: find.byType(Scrollable)),
      findsNothing,
      reason: 'the whole thought, no six-line box',
    );
    await _tap(tester);
    expect(_body, findsNothing);
  });

  testWidgets('a thought under a second is «Pensamiento breve»', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const ThinkingLine(
          text: 'Rápido.',
          duration: Duration(milliseconds: 600),
        ),
      ),
    );
    expect(
      find.descendant(of: _line, matching: find.text('Pensamiento breve')),
      findsOneWidget,
    );
  });

  testWidgets('a thought with no text draws no line', (tester) async {
    await tester.pumpWidget(_app(const ThinkingLine(text: '  \n ')));
    expect(_line, findsNothing);
  });

  testWidgets('TalkBack: a button that says what it is and for how long', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        ThinkingLine(
          text: 'Miro el log.',
          live: true,
          startedAt: _start,
          clock: () => _start.add(const Duration(seconds: 12)),
        ),
      ),
    );
    final node = tester.getSemantics(_line);
    expect(node.label, 'Pensando, 12 segundos');
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isExpanded, Tristate.isFalse);
    // The cut sentence is not read: only a reader who opens it reads it.
    expect(find.bySemanticsLabel('Miro el log.'), findsNothing);
    await _tap(tester);
    expect(
      tester.getSemantics(_line).flagsCollection.isExpanded,
      Tristate.isTrue,
    );
    semantics.dispose();
  });

  testWidgets('reduced motion: it opens at once', (tester) async {
    await tester.pumpWidget(
      _app(
        ThinkingLine(
          text: _long(20),
          live: true,
          startedAt: _start,
          clock: () => _start,
        ),
        reduceMotion: true,
      ),
    );
    await tester.tap(_line);
    await tester.pump();
    expect(_body, findsOneWidget);
    expect(find.byType(AnimatedSize), findsNothing);
  });
}
