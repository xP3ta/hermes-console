// Ola 5 (AUDITORIA-PULIDO §2.16, P1): «Omitir» skips the question, and only
// it, as Desktop's Skip does (`clarify/pending.tsx:246-253`, `skipClarify`
// in `store/clarify.ts:231-249`). «Detener tarea» keeps stopping the turn.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/interactive_prompt_reducer.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/interactive_prompt_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _skip = ValueKey('interactive-skip');

final _key = InteractivePromptKey(
  runtimeSessionId: 'runtime-a',
  requestId: 'srq-skip00000001',
);

InteractivePromptEntry _entry(InteractivePromptRequest request) =>
    InteractivePromptEntry(
      key: request.key,
      request: request,
      status: InteractivePromptStatus.pending,
    );

final _legacy = ClarifyPromptRequest(
  key: _key,
  question: '¿Qué rama?',
  choices: const ['main', 'qa'],
);

final _batch = ClarifyPromptRequest(
  key: _key,
  questions: const [
    ClarifyQuestion(
      qid: 'q0',
      question: '¿Bebida?',
      choices: ['Café', 'Té'],
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  InteractivePromptRequest request, {
  required VoidCallback onCancel,
  VoidCallback? onSkip,
  bool busy = false,
  Size size = const Size(800, 900),
  double textScale = 1,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
                  entry: _entry(request),
                  busy: busy,
                  onSubmit: (_) {},
                  onSubmitBatch: (_) {},
                  onCancel: onCancel,
                  onSkip: onSkip,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final (name, request) in [('legacy', _legacy), ('batch', _batch)]) {
    testWidgets('$name: «Omitir» skips the question, not the turn', (
      tester,
    ) async {
      var skipped = 0;
      var stopped = 0;
      await _pump(
        tester,
        request,
        onCancel: () => stopped++,
        onSkip: () => skipped++,
      );
      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(TextButton, 'Omitir'), findsOneWidget);
      // «Detener tarea» is still there, apart.
      expect(find.text('Detener tarea'), findsOneWidget);
      final size = tester.getSize(find.byKey(_skip));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));

      await tester.tap(find.byKey(_skip));
      await tester.pump();
      expect(skipped, 1);
      expect(stopped, 0);
    });
  }

  testWidgets('busy: «Omitir» cannot be pressed twice', (tester) async {
    var skipped = 0;
    await _pump(
      tester,
      _legacy,
      onCancel: () {},
      onSkip: () => skipped++,
      busy: true,
    );
    expect(tester.widget<TextButton>(find.byKey(_skip)).enabled, isFalse);
    await tester.tap(find.byKey(_skip), warnIfMissed: false);
    expect(skipped, 0);
  });

  testWidgets('sudo has nothing to skip', (tester) async {
    await _pump(
      tester,
      SudoPromptRequest(key: _key),
      onCancel: () {},
      onSkip: () => fail('sudo must not offer «Omitir»'),
    );
    expect(find.byKey(_skip), findsNothing);
    expect(find.text('Detener tarea'), findsOneWidget);
  });

  testWidgets('without onSkip the card is as before', (tester) async {
    await _pump(tester, _batch, onCancel: () {});
    expect(find.byKey(_skip), findsNothing);
  });

  testWidgets('compact at 1.3x: «Omitir» as an icon keeps its word and is '
      'pressed by TalkBack', (tester) async {
    final semantics = tester.ensureSemantics();
    var skipped = 0;
    await _pump(
      tester,
      _batch,
      onCancel: () {},
      onSkip: () => skipped++,
      size: const Size(360, 640),
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Omitir'), findsOneWidget);
    final size = tester.getSize(find.byKey(_skip));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(size.width, greaterThanOrEqualTo(48));
    final node = tester.getSemantics(find.byKey(_skip));
    expect(
      node,
      isSemantics(
        label: 'Omitir',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pump();
    expect(skipped, 1);
    semantics.dispose();
  });

  // Ola 5 (AUDITORIA-PULIDO §2.16 P2/P3): the same accent surface as the
  // approval, radius 22, and no grabber (the card is not dragged).
  testWidgets('clarify sits on the accent surface, radius 22, no grabber', (
    tester,
  ) async {
    await _pump(tester, _batch, onCancel: () {}, onSkip: () {});
    final card = find.byType(InteractivePromptCard);
    final colors = Theme.of(tester.element(card)).hermes;
    final surface = tester.widget<Material>(
      find.descendant(of: card, matching: find.byType(Material)).first,
    );
    expect(surface.color, blockingRequestSurface(colors));
    expect(
      (surface.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(22),
    );
    expect(
      find.descendant(
        of: card,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.constraints?.maxWidth == 36 &&
              widget.constraints?.maxHeight == 4,
        ),
      ),
      findsNothing,
    );
  });
}
