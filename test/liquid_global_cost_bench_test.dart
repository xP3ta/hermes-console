// Opt-in software comparison of production AppBar/DockBar/overlay and
// ChatMarkdownBody under deterministic streaming + scroll. This fixture is
// not ChatScreen; the real-app streaming measurement uses liquid_app_probe.
// Never interpret toImage wall time as GPU time or a Fold certification.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';

import 'support/liquid_bench_fixture.dart';

const _run = bool.fromEnvironment('RUN_LIQUID_SOFTWARE_BENCH');

enum _Mode { chrome, glass, painted }

double _percentile(List<double> source, double q) {
  final sorted = [...source]..sort();
  return sorted[((sorted.length - 1) * q).round()];
}

void main() {
  final records = <Map<String, Object?>>[];
  final references =
      <(Size, bool), ({String mode, List<Map<String, Object?>> trace})>{};
  tearDown(() {
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
    FrostedBackdropPolicy.knownHighEnd.value = false;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
  });
  tearDownAll(() {
    final out = Platform.environment['LIQUID_SOFTWARE_BENCH_OUT'];
    if (out == null || records.isEmpty) return;
    File(out)
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(records));
  });
  for (final size in [const Size(412, 915), const Size(884, 1000)]) {
    for (final overlay in [false, true]) {
      for (final mode in _Mode.values) {
        testWidgets('software material $size overlay=$overlay ${mode.name}', (
          tester,
        ) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          FrostedBackdropPolicy.blurAllowed.value = true;
          FrostedBackdropPolicy.reducedPerformance.value = false;
          FrostedBackdropPolicy.knownHighEnd.value = true;
          FrostedBackdropPolicy.liquidGpuValidated.value = false;
          FrostedBackdropPolicy.effectCeiling.value = switch (mode) {
            _Mode.chrome => HermesGlassTier.chrome,
            _Mode.glass => HermesGlassTier.glass,
            _Mode.painted => HermesGlassTier.liquid,
          };
          final root = GlobalKey();
          final stream = ValueNotifier(liquidBenchInitialText);
          final scroll = ScrollController();
          addTearDown(stream.dispose);
          addTearDown(scroll.dispose);
          await tester.pumpWidget(
            liquidBenchScene(
              root: root,
              stream: stream,
              scroll: scroll,
              overlay: overlay,
            ),
          );
          await tester.pumpAndSettle();
          expect(scroll.position.maxScrollExtent, greaterThan(600));
          final liveElement = tester.element(
            find.byKey(liquidBenchLiveAnswerKey),
          );
          final samples = <double>[];
          final pumps = <double>[];
          final trace = <Map<String, Object?>>[];
          final measuredEvidence = <Map<String, Object?>>[];
          LiquidBenchObservation? previous;
          for (var i = 0; i < 72; i++) {
            final delta = liquidBenchDeltaAt(i);
            stream.value += delta;
            scroll.jumpTo(liquidBenchScrollAt(i));
            final pump = Stopwatch()..start();
            await tester.pump(const Duration(milliseconds: 16));
            final pumpMs = pump.elapsedMicroseconds / 1000;
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(root),
            );
            final watch = Stopwatch()..start();
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              image.dispose();
            });
            final rasterMs = watch.elapsedMicroseconds / 1000;
            // Read real mounted/painted text and newest glyph geometry after
            // BOTH timers stop. Notifier activity alone is not evidence.
            final observed = observeLiquidBench(
              tester,
              expectedText: stream.value,
              newestToken: delta.trim(),
              scroll: scroll,
            );
            final frameFilters = tester.layers
                .whereType<BackdropFilterLayer>()
                .length;
            expect(
              frameFilters,
              mode == _Mode.chrome
                  ? 0
                  : overlay
                  ? 3
                  : 2,
            );
            expect(
              tester.element(find.byKey(liquidBenchLiveAnswerKey)),
              same(liveElement),
            );
            expect(observed.scrollPixels, liquidBenchScrollAt(i));
            expect(observed.renderedText, stream.value);
            if (previous != null) {
              expect(
                observed.renderedText.length,
                greaterThan(previous.renderedText.length),
              );
              expect(observed.scrollPixels, greaterThan(previous.scrollPixels));
            }
            previous = observed;
            final evidence = <String, Object?>{
              'step': i,
              'delta': delta,
              ...observed.toJson(),
            };
            trace.add(evidence);
            if (i >= 12) {
              samples.add(rasterMs);
              pumps.add(pumpMs);
              measuredEvidence.add({...evidence, 'filterLayers': frameFilters});
            }
          }
          final reference = references[(size, overlay)];
          if (reference != null) {
            expect(
              trace,
              equals(reference.trace),
              reason:
                  'same inputs, rendered advance and geometry across material modes',
            );
          } else {
            references[(size, overlay)] = (mode: mode.name, trace: trace);
          }
          expect(samples, hasLength(60));
          expect(measuredEvidence, hasLength(60));
          final layers = tester.layers.whereType<BackdropFilterLayer>().length;
          expect(
            layers,
            mode == _Mode.chrome
                ? 0
                : overlay
                ? 3
                : 2,
          );
          expect(tester.takeException(), isNull);
          final record = <String, Object?>{
            'fixture':
                'production components + ChatMarkdownBody; not ChatScreen',
            'mode': mode.name,
            'overlay': overlay,
            'width': size.width,
            'height': size.height,
            'capturePixelRatio': 1,
            'frames': samples.length,
            'warmup': 12,
            'filters': layers,
            'layout':
                '20 completed replies + anchored live window + 20 completed replies',
            'anchor': liquidBenchAnchor,
            'liveWindowHeight': liquidBenchLiveHeight,
            'verifiedWarmupSteps': trace.length - measuredEvidence.length,
            'scrollStartDp': liquidBenchScrollAt(0),
            'scrollStepDp': 6,
            'firstMeasuredScrollDp': measuredEvidence.first['scrollPixels'],
            'lastMeasuredScrollDp': measuredEvidence.last['scrollPixels'],
            'referenceMode': reference?.mode,
            'matchedAnotherMode': reference != null,
            'streamEvidence': measuredEvidence,
            'renderer': 'Skia tester',
            'gpuCertified': false,
            'rasterWallP50Ms': _percentile(samples, .5),
            'rasterWallP90Ms': _percentile(samples, .9),
            'rasterWallP95Ms': _percentile(samples, .95),
            'pumpWallP50Ms': _percentile(pumps, .5),
            'rawRasterWallMs': samples,
            'rawPumpWallMs': pumps,
          };
          records.add(record);
          // ignore: avoid_print
          print('[liquid-software] ${jsonEncode(record)}');
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        }, tags: 'opt-in', skip: !_run || ui.ImageFilter.isShaderFilterSupported);
      }
    }
  }
}
