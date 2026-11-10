// APK 9801 (the owner): the face on the island rests ON the pill, and the live
// thought is one folded row whose opened text reads like the chat.
//
// * Geometry: the face's base overlaps the pill's top edge by 6 to 8 dp,
//   centred, and the pill's own top never moves.
// * The thought's row never repeats the header's «Pensando» in any language.
// * Opened, a thought is the chat's reading size, upright, with its bold
//   subtitles on their own line and no asterisks anywhere.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/reasoning_plain.dart';
import 'package:hermes_android/core/widgets/chat/live_motion.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _statusBar = 24.0;

Finder _key(String key) => find.byKey(ValueKey(key));

void _view(WidgetTester tester, double width) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = Size(width, 800)
    ..padding = const FakeViewPadding(top: _statusBar)
    ..viewPadding = const FakeViewPadding(top: _statusBar);
  addTearDown(tester.view.reset);
}

Widget _header({double textScale = 1, bool glass = false}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: true,
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: Scaffold(
    body: Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FloatingChatHeader(
            glass: glass,
            leading: FloatingHeaderButton(
              icon: Icons.menu_rounded,
              tooltip: 'Menú',
              onPressed: () {},
            ),
            trailing: FloatingHeaderButton(
              icon: Icons.more_horiz_rounded,
              tooltip: 'Ajustes',
              onPressed: () {},
            ),
            faces: const SizedBox.square(
              key: ValueKey('face'),
              dimension: FloatingChatHeader.faceSize,
            ),
            pill: ChatIsland(
              name: 'xPeta',
              status: IslandStatus.working,
              hint: 'Ver',
              onTap: () {},
            ),
          ),
        ),
      ],
    ),
  ),
);

TurnStepCardEntry _thought(String id, {bool running = false, String? text}) =>
    TurnStepCardEntry(
      id: id,
      kind: TurnStepCardKind.thought,
      title: 'Pensó',
      semanticsLabel: 'Pensó',
      running: running,
      text: text,
      duration: running ? null : const Duration(seconds: 4),
      durationText: running ? null : '4 s',
      opened: text == null ? null : TurnReasoningQuote(text: text),
    );

Widget _rows(
  List<TurnStepCardEntry> entries, {
  double textScale = 1,
  bool reduceMotion = false,
  double width = 360,
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
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 40, 16, 40),
        child: SizedBox(
          width: width - 28,
          child: TurnStepCards(entries: entries, live: true),
        ),
      ),
    ),
  ),
);

/// Font size, weight and slant the first run of [phrase] is painted with.
({double? size, FontWeight? weight, FontStyle? slant}) _painted(
  WidgetTester tester,
  String phrase,
) {
  ({double? size, FontWeight? weight, FontStyle? slant})? walk(
    InlineSpan span,
    TextStyle? inherited,
  ) {
    if (span is! TextSpan) return null;
    final style = inherited?.merge(span.style) ?? span.style;
    if ((span.text ?? '').contains(phrase)) {
      return (
        size: style?.fontSize,
        weight: style?.fontWeight,
        slant: style?.fontStyle,
      );
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      final found = walk(child, style);
      if (found != null) return found;
    }
    return null;
  }

  for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
    final found = walk(text.text, null);
    if (found != null) return found;
  }
  throw StateError('«$phrase» is not painted');
}

void main() {
  group('the face rests on the pill', () {
    for (final textScale in const [1.0, 1.34, 2.0]) {
      for (final glass in const [false, true]) {
        testWidgets('texto ×$textScale${glass ? ', cristal' : ''}: su base '
            'solapa el borde de la píldora 6 a 8 dp, centrada, sin hueco', (
          tester,
        ) async {
          _view(tester, 360);
          await tester.pumpWidget(_header(textScale: textScale, glass: glass));
          await tester.pump();
          final face = tester.getRect(_key('face'));
          final pill = tester.getRect(_key('island'));
          // The base is BELOW the pill's top edge: no air under the face.
          expect(face.bottom, greaterThan(pill.top));
          expect(face.bottom - pill.top, FloatingChatHeader.faceOverlap);
          expect(FloatingChatHeader.faceOverlap, inInclusiveRange(6, 8));
          expect(face.center.dx, closeTo(pill.center.dx, 0.5));
          expect(face.height, 48);
          // The face never covers the pill's line, at any text size.
          final line = tester.getRect(_key('island-name'));
          expect(face.bottom, lessThanOrEqualTo(line.top + 0.01));
          // The pill's top edge is where it always was: below the face's
          // whole body and the status bar.
          expect(
            pill.top,
            _statusBar + 1 + FloatingChatHeader.faceSize,
            reason: 'the overlap never moves the island',
          );
          expect(face.top, greaterThanOrEqualTo(_statusBar));
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('the thought row', () {
    test(
      'says a noun, never the header pill\'s «Pensando», in 9 languages',
      () {
        for (final locale in Strings.supportedLocales) {
          final s = lookupStrings(locale);
          expect(s.litThoughtRow, isNotEmpty, reason: locale.languageCode);
          expect(
            s.litThoughtRow,
            isNot(s.turnLineThinking),
            reason: locale.languageCode,
          );
        }
        expect(Strings.supportedLocales.length, 9);
      },
    );

    testWidgets('live: ONE folded row as tall as «Trabajó», no tail, no second '
        '«Pensando»', (tester) async {
      await tester.pumpWidget(
        _rows([
          _thought('b', running: true, text: 'Miro la rama y reparto tests.'),
        ]),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final label = _key('turn-thought-label');
      expect(label, findsOneWidget);
      expect(tester.widget<Text>(label).data, 'Pensamiento');
      expect(find.text('Pensando'), findsNothing);
      expect(_key('turn-thought-tail'), findsNothing);
      expect(
        find.textContaining('Miro la rama', findRichText: true),
        findsNothing,
      );
      final row = tester.getRect(_key('turn-thought-b'));
      expect(row.height, TurnStepCards.lineHeight);
      expect(
        tester.widget<Text>(label).style!.fontStyle,
        isNot(FontStyle.italic),
      );
    });

    for (final scale in const [1.0, 2.0]) {
      testWidgets('texto ×$scale en 320 dp: la fila plegada no desborda', (
        tester,
      ) async {
        await tester.pumpWidget(
          _rows(
            [_thought('b', running: true, text: 'Miro la rama.')],
            textScale: scale,
            width: 320,
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        expect(_key('turn-thought-label'), findsOneWidget);
      });
    }

    testWidgets('reducir movimiento: sin tickers, plegada, abre en un frame', (
      tester,
    ) async {
      await tester.pumpWidget(
        _rows([
          _thought('b', running: true, text: 'Miro la rama.'),
        ], reduceMotion: true),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byType(LiveBrain), findsOneWidget);
      expect(
        find.textContaining('Miro la rama', findRichText: true),
        findsNothing,
      );
      tester
          .widget<InkWell>(
            find
                .ancestor(
                  of: _key('turn-thought-label'),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .onTap!();
      await tester.pump();
      expect(
        find.textContaining('Miro la rama', findRichText: true),
        findsOneWidget,
      );
    });
  });

  group('an opened thought reads like the chat', () {
    const thought =
        '**Revisar la rama**\nPrimero leo los cambios y `git diff`.\n\n'
        '**Plan**\n\nLuego reparto tests entre los agentes.';

    testWidgets('reading size, upright, bold subtitles, no asterisks', (
      tester,
    ) async {
      await tester.pumpWidget(
        _rows([_thought('a', text: thought)], reduceMotion: true),
      );
      await tester.pumpAndSettle();
      tester
          .widget<InkWell>(
            find
                .ancestor(
                  of: _key('turn-thought-label'),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .onTap!();
      await tester.pump();
      expect(find.textContaining('*', findRichText: true), findsNothing);
      expect(find.textContaining('`', findRichText: true), findsNothing);
      final body = _painted(tester, 'Luego reparto tests');
      expect(body.size, TurnType.reasoning);
      // Live look, 9 nov 2026: a thought is 12.5 sp, quiet italic,
      // with no louder title (Desktop message-parts.tsx:326,346: tool-size
      // tertiary body). It was 15 sp / w700 titles (APK 9801).
      expect(TurnType.reasoning, 12.5);
      expect(body.slant, FontStyle.italic);
      final subtitle = _painted(tester, 'Revisar la rama');
      expect(subtitle.weight, FontWeight.w600);
      expect(subtitle.size, TurnType.reasoning);
      // The subtitle is a block of its own, above the sentence it heads.
      final title = tester.getRect(
        find.textContaining('Revisar la rama', findRichText: true),
      );
      final first = tester.getRect(
        find.textContaining('Primero leo', findRichText: true),
      );
      expect(title.bottom, lessThanOrEqualTo(first.top));
    });

    test('structureReasoning gives a bold-only line its own paragraph', () {
      expect(
        structureReasoning('**Plan**\nPaso uno.\nPaso dos.'),
        '**Plan**\n\nPaso uno.\nPaso dos.',
      );
      expect(
        structureReasoning('Antes.\n**Plan**\nDespués.'),
        'Antes.\n\n**Plan**\n\nDespués.',
      );
      // Already apart, inline bold, a title still being written, code: as is.
      expect(structureReasoning('**Plan**\n\nTexto'), '**Plan**\n\nTexto');
      expect(
        structureReasoning('Usa **negrita** aquí.'),
        'Usa **negrita** aquí.',
      );
      expect(structureReasoning('**Chec'), '**Chec');
      expect(structureReasoning('sin marcas\nfin'), 'sin marcas\nfin');
      expect(structureReasoning('```\n**x**\n```'), '```\n**x**\n```');
    });

    test('a growing thought keeps its laid-out start', () {
      final a = structureReasoning('Primero.\n\n**Plan**\n');
      final b = structureReasoning('Primero.\n\n**Plan**\nSegundo paso.');
      expect(b.startsWith(a.trimRight()), isTrue);
    });
  });
}
