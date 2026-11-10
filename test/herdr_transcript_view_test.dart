import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_transcript.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/herdr_transcript_view.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  HerdrTurn steps(String key, {String command = 'ls -la'}) => HerdrTurn(
    HerdrTurnKind.steps,
    key: key,
    steps: [
      HerdrStep(id: '$key-c1', name: 'bash', summary: command)
        ..state = HerdrStepState.done,
    ],
  );

  Widget host(
    ScrollController controller,
    List<HerdrTurn> turns, {
    required bool hasEarlier,
  }) => MaterialApp(
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.hermesRedDark,
    home: Scaffold(
      body: HerdrTranscriptView(
        turns: turns,
        hasEarlier: hasEarlier,
        onLoadEarlier: () {},
        controller: controller,
      ),
    ),
  );

  Finder fold() => find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('hda-fold-'),
  );

  testWidgets('a fold the reader opened survives loading earlier turns, and '
      'its row keeps its element', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final later = [
      HerdrTurn(HerdrTurnKind.user, key: 'u1', text: 'hola'),
      steps('s1'),
    ];
    final earlier = [
      HerdrTurn(HerdrTurnKind.user, key: 'u0', text: 'antes'),
      HerdrTurn(HerdrTurnKind.assistant, key: 'a0', text: 'respuesta previa'),
    ];
    await tester.pumpWidget(host(controller, later, hasEarlier: true));
    await tester.pumpAndSettle();
    expect(fold(), findsOneWidget);
    expect(find.textContaining('bash'), findsNothing);
    await tester.tap(fold());
    await tester.pumpAndSettle();
    expect(find.textContaining('bash'), findsOneWidget, reason: 'fold opened');
    final foldElement = tester.element(fold());

    // «Load earlier» prepends two turns: the opened fold stays open and the
    // row is the same element (not remounted under a new key).
    await tester.pumpWidget(
      host(controller, [...earlier, ...later], hasEarlier: false),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('bash'),
      findsOneWidget,
      reason: 'the opened fold closed when older turns were prepended',
    );
    expect(identical(tester.element(fold()), foldElement), isTrue);
    expect(find.text('antes'), findsOneWidget);
  });

  testWidgets('repeated turn keys stay apart, counted from the newest turn', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    // Two step turns sharing a key (one message with two tool blocks).
    final turns = [
      HerdrTurn(HerdrTurnKind.user, key: 'u1', text: 'hola'),
      steps('m1', command: 'first'),
      steps('m1', command: 'second'),
    ];
    await tester.pumpWidget(host(controller, turns, hasEarlier: true));
    await tester.pumpAndSettle();
    expect(fold(), findsNWidgets(2));
    // Open the newest one only (the list is reversed: it comes first).
    await tester.tap(fold().first);
    await tester.pumpAndSettle();
    expect(find.textContaining('second'), findsOneWidget);
    expect(find.textContaining('first'), findsNothing);
    // Prepending keeps the same one open.
    await tester.pumpWidget(
      host(controller, [
        HerdrTurn(HerdrTurnKind.user, key: 'u0', text: 'antes'),
        ...turns,
      ], hasEarlier: false),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('second'), findsOneWidget);
    expect(find.textContaining('first'), findsNothing);
  });
}
