import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/design/liquid_sheen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _composer = ValueKey('hermes-composer-visible-surface');
const _capsule = ValueKey('status-pill-capsule');

class _Fixture {
  final text = TextEditingController(text: 'Borrador conservado');
  final focus = FocusNode();
  final metrics = ValueNotifier(const SessionContextMetrics(percent: 23));

  Widget app({HermesLiquid? material, bool readOnly = false}) {
    final footer = ChatStatusPill(
      material: material,
      metrics: metrics,
      onOpenContext: () {},
      modelLabel: 'Modelo',
      onOpenModel: () {},
    );
    return MaterialApp(
      theme: AppTheme.hermesRedDark,
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: false, highContrast: false),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: readOnly
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HermesComposerSurface(
                      material: material,
                      child: const Text('Solo lectura'),
                    ),
                    footer,
                  ],
                )
              : ConsoleComposer(
                  material: material,
                  controller: text,
                  focusNode: focus,
                  onSend: (_, _) {},
                  footer: footer,
                ),
        ),
      ),
    );
  }

  void dispose() {
    text.dispose();
    focus.dispose();
    metrics.dispose();
  }
}

Color _composerFill(WidgetTester tester) =>
    (tester.widget<AnimatedContainer>(find.byKey(_composer)).decoration
            as BoxDecoration)
        .color!;

Color _capsuleFill(WidgetTester tester) =>
    (tester.widget<Container>(find.byKey(_capsule)).decoration as BoxDecoration)
        .color!;

CustomPainter? _rim(WidgetTester tester, int index) => tester
    .widget<CustomPaint>(
      find
          .descendant(
            of: find.byType(HermesSheen).at(index),
            matching: find.byType(CustomPaint),
          )
          .first,
    )
    .foregroundPainter;

void main() {
  void resetPolicy() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = false;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
  }

  setUp(() {
    resetPolicy();
    FrostedBackdropPolicy.knownHighEnd.value = true;
  });
  tearDown(resetPolicy);

  testWidgets('unopted callers keep their original opaque surfaces', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();
    expect(find.byType(HermesSheen), findsNothing);
    expect(_composerFill(tester).a, 1);
    expect(_capsuleFill(tester).a, 1);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final readOnly in [false, true]) {
    testWidgets('shared finish preserves capsule bounds/fills, '
        'readOnly=$readOnly', (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.app(readOnly: readOnly));
      await tester.pumpAndSettle();
      final composerRect = tester.getRect(find.byKey(_composer));
      final capsuleRect = tester.getRect(find.byKey(_capsule));
      final composerFill = _composerFill(tester);
      final capsuleFill = _capsuleFill(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      final attempts = HermesLiquidShader.loadAttempts;
      await tester.pumpWidget(
        fixture.app(material: HermesLiquid.pill, readOnly: readOnly),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HermesSheen), findsNWidgets(2));
      expect(tester.getRect(find.byKey(_composer)), composerRect);
      expect(tester.getRect(find.byKey(_capsule)), capsuleRect);
      expect(_composerFill(tester), composerFill);
      expect(_capsuleFill(tester), capsuleFill);
      expect(_composerFill(tester).a, 1);
      expect(_capsuleFill(tester).a, 1);
      expect(_rim(tester, 0), isNotNull);
      expect(_rim(tester, 1), isNotNull);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(HermesLiquidShader.loadAttempts, attempts);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('policy fallback keeps editing state and opaque reading fill', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(material: HermesLiquid.pill));
    fixture.focus.requestFocus();
    await tester.pumpAndSettle();
    fixture.text.selection = const TextSelection(
      baseOffset: 2,
      extentOffset: 7,
    );
    await tester.pump();
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    final value = fixture.text.value;
    final composerRect = tester.getRect(find.byKey(_composer));
    final capsuleRect = tester.getRect(find.byKey(_capsule));
    expect(_rim(tester, 0), isNotNull);
    expect(_rim(tester, 1), isNotNull);
    FrostedBackdropPolicy.reducedPerformance.value = true;
    await tester.pump();
    expect(_rim(tester, 0), isNull);
    expect(_rim(tester, 1), isNull);
    expect(
      tester.state<EditableTextState>(find.byType(EditableText)),
      editable,
    );
    expect(fixture.focus.hasFocus, isTrue);
    expect(fixture.text.value, value);
    expect(tester.getRect(find.byKey(_composer)), composerRect);
    expect(tester.getRect(find.byKey(_capsule)), capsuleRect);
    expect(_composerFill(tester).a, 1);
    expect(_capsuleFill(tester).a, 1);
    expect(find.byType(BackdropFilter), findsNothing);
    FrostedBackdropPolicy.reducedPerformance.value = false;
    await tester.pump();
    expect(_rim(tester, 0), isNotNull);
    expect(_rim(tester, 1), isNotNull);
    expect(
      tester.state<EditableTextState>(find.byType(EditableText)),
      editable,
    );
    expect(fixture.text.value, value);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
