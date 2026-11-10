// Regressions for the actual timed fixture, without invoking its benchmark.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';

import 'support/liquid_bench_fixture.dart';

Future<void> _mount(
  WidgetTester tester,
  Size size,
  bool overlay,
  ValueNotifier<String> stream,
  ScrollController scroll,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    liquidBenchScene(
      root: GlobalKey(),
      stream: stream,
      scroll: scroll,
      overlay: overlay,
    ),
  );
  await tester.pumpAndSettle();
  expect(scroll.position.maxScrollExtent, greaterThan(600));
}

void main() {
  setUp(() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = true;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
  });
  tearDown(() {
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
    FrostedBackdropPolicy.knownHighEnd.value = false;
  });
  final references = <(Size, bool), List<Map<String, Object?>>>{};
  for (final size in [const Size(412, 915), const Size(884, 1000)]) {
    for (final overlay in [false, true]) {
      for (final ceiling in HermesGlassTier.values) {
        testWidgets(
          '$size overlay=$overlay $ceiling: live text and glyphs advance visibly',
          (tester) async {
            FrostedBackdropPolicy.effectCeiling.value = ceiling;
            final stream = ValueNotifier(liquidBenchInitialText);
            final scroll = ScrollController();
            addTearDown(stream.dispose);
            addTearDown(scroll.dispose);
            await _mount(tester, size, overlay, stream, scroll);
            final element = tester.element(
              find.byKey(liquidBenchLiveAnswerKey),
            );
            final trace = <Map<String, Object?>>[];
            LiquidBenchObservation? previous;
            for (var step = 0; step < 72; step++) {
              final delta = liquidBenchDeltaAt(step);
              stream.value += delta;
              scroll.jumpTo(liquidBenchScrollAt(step));
              await tester.pump(const Duration(milliseconds: 16));
              final observed = observeLiquidBench(
                tester,
                expectedText: stream.value,
                newestToken: delta.trim(),
                scroll: scroll,
              );
              expect(
                tester.element(find.byKey(liquidBenchLiveAnswerKey)),
                same(element),
              );
              expect(observed.renderedText, stream.value);
              expect(observed.scrollPixels, liquidBenchScrollAt(step));
              if (previous != null) {
                expect(
                  observed.renderedText.length,
                  greaterThan(previous.renderedText.length),
                );
                expect(
                  observed.scrollPixels,
                  greaterThan(previous.scrollPixels),
                );
              }
              previous = observed;
              trace.add(observed.toJson());
              expect(tester.takeException(), isNull);
            }
            final reference = references[(size, overlay)];
            if (reference == null) {
              references[(size, overlay)] = trace;
            } else {
              expect(
                trace,
                equals(reference),
                reason: 'same workload in every mode',
              );
            }
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
          },
        );
      }
    }
  }

  testWidgets(
    'visibility guard rejects unconsumed deltas and an offscreen live answer',
    (tester) async {
      FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.chrome;
      final stream = ValueNotifier(liquidBenchInitialText);
      final scroll = ScrollController();
      addTearDown(stream.dispose);
      addTearDown(scroll.dispose);
      await _mount(tester, const Size(412, 915), true, stream, scroll);
      scroll.jumpTo(liquidBenchScrollAt(0));
      await tester.pump();
      expect(
        () => observeLiquidBench(
          tester,
          expectedText: stream.value,
          newestToken: 'respuesta.',
          scroll: scroll,
        ),
        returnsNormally,
      );
      stream.value += ' sin consumir';
      // Deliberately do not pump: a notifier change must NOT pass as render work.
      expect(
        () => observeLiquidBench(
          tester,
          expectedText: stream.value,
          newestToken: 'consumir',
          scroll: scroll,
        ),
        throwsStateError,
      );
      await tester.pump();
      expect(
        () => observeLiquidBench(
          tester,
          expectedText: stream.value,
          newestToken: 'consumir',
          scroll: scroll,
        ),
        returnsNormally,
      );
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(
        () => observeLiquidBench(
          tester,
          expectedText: stream.value,
          newestToken: 'consumir',
          scroll: scroll,
        ),
        throwsStateError,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
