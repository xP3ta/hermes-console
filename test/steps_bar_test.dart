// Barra-resumen de pasos de herramienta (corte 6): categorías por nombre
// normalizado, textos con plurales y lista regional, estado solo por texto y
// color, expansión recordada por turno, píldora de cabecera.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/chat/chat_live_icon.dart';
import 'package:hermes_android/core/widgets/chat/turn_activity_pill.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_cards.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat/live_motion.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Strings _s(String lang) => lookupStrings(Locale(lang));

const _langs = ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];

Widget _host(
  Widget child, {
  double width = 412,
  double textScale = 1,
  bool reduceMotion = false,
  String lang = 'es',
}) => MaterialApp(
  locale: Locale(lang),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, body) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reduceMotion,
    ),
    child: body!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

TurnStepCardEntry _step(
  String id,
  String? tool, {
  bool running = false,
  bool failed = false,
  Widget? opened,
}) => TurnStepCardEntry(
  id: id,
  kind: TurnStepCardKind.tool,
  title: 'Paso $id',
  detail: 'detalle $id',
  running: running,
  failed: failed,
  toolName: tool,
  semanticsLabel: 'Paso $id',
  opened: opened,
);

Finder _line(String id) => find.byKey(ValueKey('turn-line-$id'));
Finder _row(String id) => find.byKey(ValueKey('turn-step-card-$id'));
Finder _label() => find.byKey(const ValueKey('turn-line-label'));

String _text(WidgetTester tester, Finder finder) {
  final widget = tester.widget(finder);
  return (widget as Text).data!;
}

void main() {
  setUp(StepsBarMemory.reset);

  group('categories', () {
    test('exact names, normalized (case and dashes)', () {
      expect(stepsBarCategory('terminal'), StepsBarCategory.commands);
      expect(stepsBarCategory('Exec-Command'), StepsBarCategory.commands);
      expect(stepsBarCategory('SHELL'), StepsBarCategory.commands);
      expect(stepsBarCategory('apply-patch'), StepsBarCategory.edit);
      expect(stepsBarCategory('write_file'), StepsBarCategory.edit);
      expect(stepsBarCategory('open_file'), StepsBarCategory.readFiles);
      expect(stepsBarCategory('Web-Search'), StepsBarCategory.webSearch);
      expect(stepsBarCategory('browser-search'), StepsBarCategory.webSearch);
      expect(stepsBarCategory('web_fetch'), StepsBarCategory.webPages);
    });

    test('prefix after exact; unknown, empty and null go to «otras»', () {
      expect(stepsBarCategory('patch_file'), StepsBarCategory.edit);
      expect(stepsBarCategory('read_file_range'), StepsBarCategory.readFiles);
      expect(stepsBarCategory('web_search_exa'), StepsBarCategory.webSearch);
      expect(stepsBarCategory('delegate_task'), StepsBarCategory.other);
      expect(stepsBarCategory('mcp-server-tool'), StepsBarCategory.other);
      expect(stepsBarCategory(''), StepsBarCategory.other);
      expect(stepsBarCategory(null), StepsBarCategory.other);
    });

    test('counts keep the order of appearance and «otras» comes last', () {
      expect(
        stepsBarCounts([
          'mystery',
          'web_search',
          'terminal',
          'web_search',
          'mystery2',
          'read_file',
        ]),
        [
          (StepsBarCategory.webSearch, 2),
          (StepsBarCategory.commands, 1),
          (StepsBarCategory.readFiles, 1),
          (StepsBarCategory.other, 2),
        ],
      );
    });

    test('state: running over failed over done', () {
      expect(
        stepsBarStatus(anyRunning: true, anyFailed: true),
        StepsBarStatus.running,
      );
      expect(
        stepsBarStatus(anyRunning: false, anyFailed: true),
        StepsBarStatus.failed,
      );
      expect(
        stepsBarStatus(anyRunning: false, anyFailed: false),
        StepsBarStatus.done,
      );
    });
  });

  group('texts', () {
    test('lists of one, two and three or more, in the regional shape', () {
      final es = _s('es');
      expect(stepsBarJoinList(es, ['a']), 'a');
      expect(stepsBarJoinList(es, ['a', 'b']), 'a y b');
      expect(stepsBarJoinList(es, ['a', 'b', 'c']), 'a, b y c');
      final en = _s('en');
      expect(stepsBarJoinList(en, ['a', 'b', 'c']), 'a, b, and c');
      expect(stepsBarJoinList(_s('ja'), ['a', 'b', 'c']), 'a、b、c');
      expect(stepsBarJoinList(_s('de'), ['a', 'b', 'c', 'd']), 'a, b, c und d');
    });

    test('summary: singular and plural, first letter in capitals', () {
      expect(
        stepsBarSummaryText(_s('es'), ['terminal', 'bash']),
        'Ejecutó 2 comandos',
      );
      expect(stepsBarSummaryText(_s('es'), ['web_fetch']), 'Leyó una página');
      expect(
        stepsBarSummaryText(_s('es'), [
          'web_search',
          'web_search',
          'web_search',
          'x',
          'x',
          'x',
          'x',
        ]),
        'Buscó en la web 3 veces y hizo 4 llamadas',
      );
      expect(
        stepsBarSummaryText(_s('en'), ['read_file', 'patch', 'terminal']),
        'Read a file, edited a file, and ran a command',
      );
    });

    test('the nine languages have a singular and a plural for each kind', () {
      for (final lang in _langs) {
        final s = _s(lang);
        for (final tool in [
          'terminal',
          'patch',
          'read_file',
          'web_search',
          'web_fetch',
          'other_tool',
        ]) {
          final two = stepsBarSummaryText(s, [tool, tool]);
          final one = stepsBarSummaryText(s, [tool]);
          expect(two, contains('2'), reason: '$lang $tool');
          expect(one, isNotEmpty, reason: '$lang $tool');
          if (!['ja', 'ko', 'zh'].contains(lang)) {
            expect(one, isNot(contains('1')), reason: '$lang $tool singular');
          }
        }
        expect(s.stepsBarStatusRunning, isNotEmpty);
        expect(s.stepsBarStatusFailed, isNot(s.stepsBarStatusDone));
      }
    });
  });

  group('line', () {
    testWidgets('state by mark and words; the line reads the summary to a '
        'screen reader', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          TurnStepCards(
            entries: [
              _step('a', 'terminal'),
              _step('b', 'read_file', failed: true),
              _step('c', 'bash'),
            ],
          ),
          reduceMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_label());
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _row('b'), matching: find.text('Fallido')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _row('c'), matching: find.text('Fallido')),
        findsNothing,
      );
      // One mark per step, from the chat's own outline icon family (the
      // terminal for a command), never a filled badge.
      expect(
        find.descendant(of: _row('a'), matching: find.byType(LiveStepMark)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ChatLiveIcon>(
              find.descendant(
                of: _row('a'),
                matching: find.byType(ChatLiveIcon),
              ),
            )
            .glyph,
        ChatLiveGlyph.terminalAgent,
      );
      final node = tester.getSemantics(
        find
            .descendant(
              of: _line('a'),
              matching: find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.button == true,
              ),
            )
            .first,
      );
      expect(
        node.label,
        contains('Ejecutó 2 comandos · Leyó 1 archivo · 1 falló'),
      );
      expect(node.flagsCollection.isExpanded, Tristate.isTrue);
      semantics.dispose();
    });

    testWidgets('in progress turns; reduced motion keeps it still', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          TurnStepCards(
            entries: [_step('a', 'terminal', running: true)],
            live: true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(LiveStepMark), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(
        _host(
          TurnStepCards(
            entries: [_step('a', 'terminal', running: true)],
            live: true,
          ),
          reduceMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    });

    for (final width in const [320.0, 412.0, 773.0]) {
      for (final scale in const [1.0, 2.0]) {
        testWidgets('${width.toInt()} dp, text ${scale}x: the line and its '
            'rows stay inside', (tester) async {
          tester.view.physicalSize = Size(width, 1600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            _host(
              TurnStepCards(
                entries: [
                  _step('a', 'terminal', running: true),
                  _step('b', 'patch'),
                  _step('c', 'read_file'),
                  _step('d', 'web_search'),
                  _step('e', 'web_fetch'),
                  _step('f', 'unknown'),
                ],
                live: true,
              ),
              width: width,
              textScale: scale,
              reduceMotion: true,
              lang: 'de',
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          // Live actions are limited to the most recent three.
          expect(_label(), findsNothing);
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(_line('a')).right,
            lessThanOrEqualTo(width + 0.5),
          );
          expect(_row('c'), findsNothing);
          expect(_row('d'), findsOneWidget);
          expect(
            tester.getRect(_row('f')).right,
            lessThanOrEqualTo(width + 0.5),
          );
          await tester.pumpWidget(
            _host(
              TurnStepCards(
                entries: [
                  for (final (id, tool) in [
                    ('a', 'terminal'),
                    ('b', 'patch'),
                    ('c', 'read_file'),
                    ('d', 'web_search'),
                    ('e', 'web_fetch'),
                    ('f', 'unknown'),
                  ])
                    _step(id, tool, opened: Text('output $id')),
                ],
              ),
              width: width,
              textScale: scale,
              reduceMotion: true,
              lang: 'de',
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.getSize(_line('a')).height, greaterThanOrEqualTo(44));
          await tester.tap(_label());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          for (final id in ['a', 'b', 'c', 'd', 'e', 'f']) {
            expect(tester.getSize(_row(id)).height, greaterThanOrEqualTo(44));
            expect(
              tester.getRect(_row(id)).right,
              lessThanOrEqualTo(width + 0.5),
            );
          }
          await tester.tap(_row('f'));
          await tester.pumpAndSettle();
          expect(find.text('output f'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('header pill', () {
    test('clock is m:ss and the word rotates through the list', () {
      expect(formatTurnClock(Duration.zero), '0:00');
      expect(formatTurnClock(const Duration(seconds: 65)), '1:05');
      expect(formatTurnClock(const Duration(minutes: 12, seconds: 3)), '12:03');
      final s = _s('es');
      final seen = {
        for (var i = 0; i < 6; i++)
          turnActivityWord(s, Duration(seconds: i * kTurnActivityWordSeconds)),
      };
      expect(seen, hasLength(6));
      expect(
        turnActivityWord(s, const Duration(seconds: 6 * 4)),
        turnActivityWord(s, Duration.zero),
      );
    });

    testWidgets('live: word and clock under the name, counting', (
      tester,
    ) async {
      var now = DateTime(2026, 1, 1, 12);
      final started = now;
      await tester.pumpWidget(
        _host(
          TurnActivityPill(startedAt: started, clock: () => now),
          reduceMotion: true,
        ),
      );
      expect(find.text('Cavilando · 0:00'), findsOneWidget);
      now = started.add(const Duration(seconds: 71));
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('1:1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TurnActivityPill),
          matching: find.byType(Icon),
        ),
        findsNothing,
      );
    });

    testWidgets('finished: «Trabajó X · N pasos» is the one line that folds '
        'the steps of the turn; no second pill', (tester) async {
      ChatTraceEvent tool(String id) => ChatTraceEvent(
        id: id,
        label: 'terminal',
        status: 'completed',
        detail: 'ls',
      );
      await tester.pumpWidget(
        _host(
          ThinkingTraceCard(
            events: [tool('a'), tool('b')],
            active: false,
            stepCards: true,
            duration: const Duration(seconds: 72),
            headerBuilder: (_, summary, details) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [summary, details],
            ),
          ),
          reduceMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('turn-worked-pill')), findsNothing);
      expect(_label(), findsOneWidget);
      expect(_text(tester, _label()), 'Trabajó 1:12 · Ejecutó 2 comandos');
      expect(_row('a'), findsNothing);
      await tester.tap(_label());
      await tester.pumpAndSettle();
      expect(_row('a'), findsOneWidget);
      expect(_row('b'), findsOneWidget);
      await tester.tap(_label());
      await tester.pumpAndSettle();
      expect(_row('a'), findsNothing);
    });

    testWidgets('live turn: what is done is one folded line, the step in hand '
        'turns under it, no pill', (tester) async {
      await tester.pumpWidget(
        _host(
          ThinkingTraceCard(
            events: [
              ChatTraceEvent(id: 'a', label: 'terminal', status: 'completed'),
              ChatTraceEvent(id: 'b', label: 'web_search', status: 'running'),
            ],
            active: true,
            stepCards: true,
            headerBuilder: (_, summary, details) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [summary, details],
            ),
          ),
          reduceMotion: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('turn-activity-pill')), findsNothing);
      expect(_label(), findsNothing);
      expect(_row('a'), findsOneWidget);
      expect(_row('b'), findsOneWidget);
      await tester.pumpWidget(
        _host(
          ThinkingTraceCard(
            events: [
              ChatTraceEvent(id: 'a', label: 'terminal', status: 'completed'),
              ChatTraceEvent(id: 'b', label: 'web_search', status: 'completed'),
            ],
            active: false,
            stepCards: true,
            headerBuilder: (_, summary, details) =>
                Column(children: [summary, details]),
          ),
          reduceMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(_row('a'), findsNothing);
      await tester.tap(_label());
      await tester.pumpAndSettle();
      expect(_row('a'), findsOneWidget);
      expect(_row('b'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
