// Review R5A B3-1 (P1) and B3-2: with a large text size in little room
// the clarify card keeps «Detener tarea» and «Confirmar» on one row. Shown
// as icons they still carry their word (tooltip and TalkBack label), and
// TalkBack's double tap presses them: the agent's turn never waits on a
// button nobody can press. While the words fit in that row, they show.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/interactive_prompt_reducer.dart';
import 'package:hermes_android/core/widgets/interactive_prompt_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _cancel = ValueKey('interactive-batch-cancel');
const _confirm = ValueKey('interactive-batch-confirm');

/// The card over a chat, as the chat places it: below a 125 dp header band
/// (24 of status bar), above 120 dp of bottom bars.
Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required double textScale,
  required VoidCallback onCancel,
  required void Function(Map<String, String>) onSubmitBatch,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = InteractivePromptKey(
    runtimeSessionId: 'runtime-a',
    requestId: 'compact-actions',
  );
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
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: InteractivePromptPlacement(
                topInset: 125,
                child: InteractivePromptCard(
                  entry: InteractivePromptEntry(
                    key: key,
                    request: ClarifyPromptRequest(
                      key: key,
                      questions: const [
                        ClarifyQuestion(
                          qid: 'q0',
                          question: '¿Bebida?',
                          choices: ['Café', 'Té'],
                        ),
                      ],
                    ),
                    status: InteractivePromptStatus.pending,
                  ),
                  busy: false,
                  onSubmit: (_) {},
                  onSubmitBatch: onSubmitBatch,
                  onCancel: onCancel,
                ),
              ),
            ),
            const SizedBox(height: 120),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void _tapBySemantics(WidgetTester tester, Finder finder) {
  final node = tester.getSemantics(finder);
  node.owner!.performAction(node.id, SemanticsAction.tap);
}

void main() {
  testWidgets('360x640 at 1.3x: icons with their words, pressed by '
      'TalkBack', (tester) async {
    final semantics = tester.ensureSemantics();
    var cancelled = 0;
    final submissions = <Map<String, String>>[];
    await _pump(
      tester,
      size: const Size(360, 640),
      textScale: 1.3,
      onCancel: () => cancelled++,
      onSubmitBatch: submissions.add,
    );
    expect(tester.takeException(), isNull);
    // Icons: the words do not fit beside each other at this size.
    expect(find.text('Detener tarea'), findsNothing);
    expect(find.byTooltip('Detener tarea'), findsOneWidget);
    expect(find.byTooltip('Confirmar y continuar'), findsOneWidget);
    for (final key in [_cancel, _confirm]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
    }

    expect(
      tester.getSemantics(find.byKey(_cancel)),
      isSemantics(
        label: 'Detener tarea',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    // Nothing answered yet: «Confirmar» is off, and says so.
    expect(
      tester.getSemantics(find.byKey(_confirm)),
      isSemantics(
        label: 'Confirmar y continuar',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );

    _tapBySemantics(tester, find.byKey(_cancel));
    await tester.pump();
    expect(cancelled, 1);

    await tester.ensureVisible(find.text('Café'));
    await tester.pump();
    await tester.tap(find.text('Café'));
    await tester.pump();
    expect(
      tester.getSemantics(find.byKey(_confirm)),
      isSemantics(
        label: 'Confirmar y continuar',
        isButton: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    _tapBySemantics(tester, find.byKey(_confirm));
    await tester.pump();
    expect(submissions, [{'q0': 'Café'}]);
    semantics.dispose();
  });

  // Review R5A B3-5: a single answer is a radio button for TalkBack.
  testWidgets('a single-answer option reads as a radio button', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      size: const Size(800, 900),
      textScale: 1,
      onCancel: () {},
      onSubmitBatch: (_) {},
    );
    final option = find.widgetWithText(OutlinedButton, 'Café');
    expect(
      tester.getSemantics(option),
      isSemantics(
        isInMutuallyExclusiveGroup: true,
        hasCheckedState: true,
        isChecked: false,
      ),
    );
    await tester.tap(option);
    await tester.pump();
    expect(
      tester.getSemantics(option),
      isSemantics(
        isInMutuallyExclusiveGroup: true,
        hasCheckedState: true,
        isChecked: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('little room at 1.0x on a wide window: one row, with words', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(800, 500),
      textScale: 1,
      onCancel: () {},
      onSubmitBatch: (_) {},
    );
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(TextButton, 'Detener tarea'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Confirmar y continuar'),
      findsOneWidget,
    );
    expect(find.byTooltip('Confirmar y continuar'), findsNothing);
    // Both on the same row.
    expect(
      tester.getRect(find.byKey(_cancel)).center.dy,
      moreOrLessEquals(tester.getRect(find.byKey(_confirm)).center.dy),
    );
  });
}
