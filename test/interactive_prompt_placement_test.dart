// The clarify card over a chat never runs into the band of the chat's
// floating header (the face, the island, «≡» and «+»): the owner saw it on the
// open Fold (chat beside the chat list) with its question and first option
// under the header. Mounted as the chat mounts it: the band measured with
// FloatingChatHeader.insetFor, the card in InteractivePromptPlacement above
// the bottom bars.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/interactive_prompt_reducer.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/interactive_prompt_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// The composer and its status pill under the card (the chat's bottom bars).
const double _bars = 120;
const _confirm = ValueKey('interactive-batch-confirm');
const _cancel = ValueKey('interactive-batch-cancel');

const _questions = [
  ClarifyQuestion(
    qid: 'q0',
    question:
        '¿Qué estrategia debemos aplicar para cerrar esta operación sin '
        'perder ninguna garantía importante?',
    choices: [
      'Continuar con la alternativa conservadora y verificable paso a paso',
      'Aplicar la migración completa manteniendo la compatibilidad hacia atrás',
      'Posponer hasta disponer de toda la evidencia necesaria del servidor',
    ],
  ),
  ClarifyQuestion(
    qid: 'q1',
    question: '¿En qué rama dejamos los cambios antes de revisarlos juntos?',
    choices: [
      'En la rama de la versión actual, junto al resto de arreglos de hoy',
      'En una rama nueva solo para esta tarea, para revisarla por separado',
      'Directamente en la rama principal después de pasar todos los tests',
    ],
  ),
  ClarifyQuestion(
    qid: 'q2',
    question: '¿Cómo avisamos al equipo cuando el cambio esté listo?',
    choices: [
      'Con un mensaje en el canal del equipo y el enlace a la revisión',
      'Con una nota en la tarea del tablero y una mención a quien revisa',
      'Sin aviso: el equipo lo verá en el resumen diario de la mañana',
    ],
  ),
];

class _Shown {
  _Shown(this.band, this.bottom);

  /// Bottom edge of the header's band.
  final double band;

  /// Top edge of the bottom bars: the card ends above it.
  final double bottom;
}

Future<_Shown> _pump(
  WidgetTester tester, {
  required Size size,
  required List<Map<String, String>> submissions,
  double textScale = 1,
  double keyboard = 0,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1
    ..padding = const FakeViewPadding(top: 24)
    ..viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  final key = InteractivePromptKey(
    runtimeSessionId: 'runtime-a',
    requestId: 'batch-band',
  );
  var band = 0.0;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            band = FloatingChatHeader.insetFor(context);
            return Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: band,
                        child: const ColoredBox(color: Colors.black12),
                      ),
                      Positioned.fill(
                        child: InteractivePromptPlacement(
                          topInset: band,
                          child: InteractivePromptCard(
                            entry: InteractivePromptEntry(
                              key: key,
                              request: ClarifyPromptRequest(
                                key: key,
                                questions: _questions,
                              ),
                              status: InteractivePromptStatus.pending,
                            ),
                            busy: false,
                            onSubmit: (_) {},
                            onSubmitBatch: submissions.add,
                            onCancel: () {},
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: _bars),
              ],
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  return _Shown(band, size.height - keyboard - _bars);
}

/// Nothing of the card inside the header's band or below its room; [what]
/// starts inside the card, below the band, and with [whole] ends inside it
/// too (a long option at 200 % can be taller than a card squeezed by the
/// keyboard: then it starts in view and scrolls).
void _expectClear(
  WidgetTester tester,
  _Shown shown,
  Finder what,
  String why, {
  bool whole = true,
}) {
  final card = tester.getRect(find.byType(InteractivePromptCard));
  expect(card.top, greaterThanOrEqualTo(shown.band), reason: 'card');
  expect(card.bottom, lessThanOrEqualTo(shown.bottom + 0.5), reason: 'card');
  final rect = tester.getRect(what);
  expect(rect.top, greaterThanOrEqualTo(shown.band), reason: why);
  expect(rect.top, greaterThanOrEqualTo(card.top), reason: why);
  expect(rect.top, lessThan(card.bottom), reason: why);
  if (whole) {
    expect(rect.bottom, lessThanOrEqualTo(card.bottom + 0.5), reason: why);
  }
}

/// Height from the card's top to the actions pinned at its foot, or null
/// when the actions scroll with the card (the keyboard up).
double? _roomAboveActions(WidgetTester tester) {
  final actions = find.byKey(const ValueKey('interactive-prompt-actions'));
  final scrolls = find.ancestor(of: actions, matching: find.byType(Scrollable));
  if (scrolls.evaluate().isNotEmpty) return null;
  final card = tester.getRect(find.byType(InteractivePromptCard));
  return tester.getRect(actions).top - card.top;
}

/// Picks the first choice of every question, scrolling to each, and sends.
/// Each option is tapped just inside its top edge: the part surely in view.
///
/// With [whole], an option ends above the pinned actions. One taller than
/// the whole room above them cannot (at 200 % on 360 dp the first option
/// wraps to 9 lines, ≈ 348 dp, in ≈ 307): it starts in view, and scrolling
/// to its end shows that end above the actions.
Future<void> _answerAndConfirm(
  WidgetTester tester,
  _Shown shown,
  List<Map<String, String>> submissions, {
  bool whole = true,
}) async {
  for (final question in _questions) {
    final label = question.choices.first;
    final option = find.widgetWithText(OutlinedButton, label);
    await tester.ensureVisible(option);
    await tester.pump();
    final room = whole ? _roomAboveActions(tester) : null;
    final fits = room == null || tester.getSize(option).height <= room;
    _expectClear(tester, shown, option, label, whole: whole && fits);
    await tester.tapAt(tester.getRect(option).topLeft + const Offset(24, 12));
    await tester.pump();
    if (room != null) {
      if (!fits) {
        await Scrollable.ensureVisible(tester.element(option), alignment: 1);
        await tester.pump();
      }
      final actions = find.byKey(const ValueKey('interactive-prompt-actions'));
      final card = tester.getRect(find.byType(InteractivePromptCard));
      final end = tester.getRect(option).bottom;
      expect(
        end,
        lessThanOrEqualTo(tester.getRect(actions).top + 0.5),
        reason: label,
      );
      expect(end, greaterThan(card.top), reason: label);
    }
  }
  await tester.ensureVisible(find.byKey(_confirm));
  await tester.pump();
  _expectClear(tester, shown, find.byKey(_confirm), 'confirm');
  expect(find.byKey(_confirm).hitTestable(), findsOneWidget);
  await tester.tap(find.byKey(_confirm));
  await tester.pump();
  expect(submissions, [
    {for (final q in _questions) q.qid: q.choices.first},
  ]);
}

void main() {
  for (final size in const [Size(450, 704), Size(360, 640)]) {
    final name = '${size.width.toInt()}x${size.height.toInt()}';
    for (final textScale in const [1.0, 2.0]) {
      testWidgets('$name at ${textScale}x: below the header, actions in view', (
        tester,
      ) async {
        final submissions = <Map<String, String>>[];
        final shown = await _pump(
          tester,
          size: size,
          textScale: textScale,
          submissions: submissions,
        );
        expect(tester.takeException(), isNull);
        // The first question starts in view, clear of the band, without
        // scrolling; at 100 % its first option too. The header and the
        // actions always show whole.
        _expectClear(
          tester,
          shown,
          find.text(_questions.first.question),
          'first question',
          whole: textScale == 1,
        );
        if (textScale == 1) {
          _expectClear(
            tester,
            shown,
            find.widgetWithText(OutlinedButton, _questions.first.choices.first),
            'first option',
          );
        }
        for (final action in [_cancel, _confirm]) {
          _expectClear(tester, shown, find.byKey(action), '$action');
          expect(find.byKey(action).hitTestable(), findsOneWidget);
        }
        await _answerAndConfirm(tester, shown, submissions);
        expect(tester.takeException(), isNull);
      });
    }

    // With the keyboard up the room left is small: the card still never
    // enters the band, and everything in it is reachable.
    for (final textScale in const [1.0, 2.0]) {
      testWidgets('$name at ${textScale}x, keyboard up: below the header', (
        tester,
      ) async {
        final submissions = <Map<String, String>>[];
        final shown = await _pump(
          tester,
          size: size,
          textScale: textScale,
          keyboard: 280,
          submissions: submissions,
        );
        expect(tester.takeException(), isNull);
        _expectClear(tester, shown, find.byType(InteractivePromptCard), 'card');
        await _answerAndConfirm(tester, shown, submissions, whole: false);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
