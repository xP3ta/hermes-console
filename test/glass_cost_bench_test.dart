// Q9-CHAT5 v2, the owner's cost rule 5: the frame cost of the glass, with a
// reply streaming behind it, measured the same way on every run (the host's
// software rasterizer; on the Fold see REPORT-Q9-CHAT5, «Medir en el
// dispositivo»). The foot as delivered: the composer solid (it is
// `HermesComposerSurface`, opaque by Ola 3's rule; REVIEW-Q9-CHAT5) and the
// live turn's two pills, in three set-ups:
//   none     the pills solid (sigma 0): the cost floor;
//   zoned    the design: the pills in glass, ONE blur at the foot (rule 2);
//   all      both pills blurring: what rule 2 avoids.
// Each frame a token is appended to the reply and the list scrolls a step,
// as while streaming; the whole screen is then rasterized (toImage) and
// timed. The numbers are printed as `[glass-cost]` lines for the report;
// the test only asserts what the design promises: the zoned foot pushes one
// backdrop layer, and costs no more than every surface blurring.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';

enum _Foot { none, zoned, all }

class _Stream extends ChangeNotifier {
  final words = <String>[];
  void add(String word) {
    words.add(word);
    notifyListeners();
  }
}

Widget _scene(_Foot foot, _Stream stream, ScrollController scroll, Key root) {
  Widget surface(
    String id,
    double width,
    double height, {
    int priority = 0,
    bool solid = false,
  }) {
    final radius = BorderRadius.circular(height / 2);
    final child = SizedBox(width: width, height: height);
    return switch (solid ? _Foot.none : foot) {
      _Foot.none => FrostedBackdrop(
        key: ValueKey(id),
        sigma: 0,
        tint: AppTheme.hermesRedDark.hermes.surface,
        borderRadius: radius,
        builder: (context, fill) => DecoratedBox(
          decoration: BoxDecoration(color: fill, borderRadius: radius),
          child: child,
        ),
      ),
      _Foot.zoned => FrostedBackdrop.glass(
        key: ValueKey(id),
        zone: FrostedZone.bottom,
        zonePriority: priority,
        borderRadius: radius,
        child: child,
      ),
      _Foot.all => FrostedBackdrop.glass(
        key: ValueKey(id),
        borderRadius: radius,
        child: child,
      ),
    };
  }

  return RepaintBoundary(
    key: root,
    child: MaterialApp(
      theme: AppTheme.hermesRedDark,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          children: [
            ListenableBuilder(
              listenable: stream,
              builder: (context, _) => ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(12, 0, 16, 220),
                children: [
                  for (var i = 0; i < 40; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        'Respuesta anterior $i con varias palabras que ocupan '
                        'una línea entera del transcript.',
                      ),
                    ),
                  Text(stream.words.join(' ')),
                ],
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  surface('step', 300, 36),
                  const SizedBox(height: 8),
                  surface('status', 190, 36, priority: 1),
                  const SizedBox(height: 8),
                  surface('composer', 388, 56, solid: true),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

double _p90(List<double> values) {
  final sorted = [...values]..sort();
  return sorted[(sorted.length * 0.9).floor().clamp(0, sorted.length - 1)];
}

void main() {
  const frames = 60;
  final results = <_Foot, ({double raster, double p90, double pump})>{};

  for (final foot in _Foot.values) {
    testWidgets('[glass-cost] ${foot.name}: a reply streaming behind the foot', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2256);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final stream = _Stream();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final root = GlobalKey();
      await tester.pumpWidget(_scene(foot, stream, scroll, root));
      await tester.pump();
      final raster = <double>[];
      final pumps = <double>[];
      for (var frame = 0; frame < frames; frame++) {
        stream.add('palabra$frame');
        if (scroll.hasClients) {
          scroll.jumpTo(
            (scroll.offset + 6).clamp(0.0, scroll.position.maxScrollExtent),
          );
        }
        final pump = Stopwatch()..start();
        await tester.pump(const Duration(milliseconds: 16));
        pumps.add(pump.elapsedMicroseconds / 1000);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(root),
        );
        final watch = Stopwatch()..start();
        await tester.runAsync(() async {
          final ui.Image image = await boundary.toImage(pixelRatio: 2.625);
          image.dispose();
        });
        raster.add(watch.elapsedMicroseconds / 1000);
      }
      final layers = tester.layers.whereType<BackdropFilterLayer>().length;
      results[foot] = (
        raster: _median(raster),
        p90: _p90(raster),
        pump: _median(pumps),
      );
      // ignore: avoid_print
      print(
        '[glass-cost] foot=${foot.name} frames=$frames '
        'backdropLayers=$layers '
        'raster_median_ms=${_median(raster).toStringAsFixed(2)} '
        'raster_p90_ms=${_p90(raster).toStringAsFixed(2)} '
        'pump_median_ms=${_median(pumps).toStringAsFixed(2)}',
      );
      switch (foot) {
        case _Foot.none:
          expect(layers, 0);
        case _Foot.zoned:
          expect(layers, 1, reason: 'rule 2: one blur at the foot');
        case _Foot.all:
          expect(layers, 2);
      }
    });
  }

  test('[glass-cost] summary', () {
    // Every set-up must have run: a summary of nothing is not a measure.
    expect(results.keys, unorderedEquals(_Foot.values));
    final none = results[_Foot.none]!;
    final zoned = results[_Foot.zoned]!;
    final all = results[_Foot.all]!;
    // ignore: avoid_print
    print(
      '[glass-cost] summary zoned/none=${(zoned.raster / none.raster).toStringAsFixed(2)}x '
      'all/none=${(all.raster / none.raster).toStringAsFixed(2)}x '
      'zoned_p90_ms=${zoned.p90.toStringAsFixed(2)} '
      'all_p90_ms=${all.p90.toStringAsFixed(2)}',
    );
    // Rule 2's reason to be: one blur costs no more than three. A noisy
    // machine gets a 15 % margin.
    expect(zoned.raster, lessThanOrEqualTo(all.raster * 1.15));
  });
}
