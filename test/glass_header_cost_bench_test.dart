// Q9-CRISTAL (the owner, rule 7 of the order): the frame cost of the header's
// glass, measured as REPORT-Q9-CHAT5 measures the foot's
// (test/glass_cost_bench_test.dart): a reply streaming at the end of a
// long list that scrolls a step each frame, under a header of three pieces
// (a round button, a title pill, an actions pill), in three set-ups:
//   none     no blur: the header of before (the fallback);
//   strip    the design: one HermesGlassStrip, ONE blur for the pieces;
//   pieces   each piece its own blur: what the strip avoids.
// The whole screen is rasterized (toImage) and timed each frame; the
// numbers are printed as `[glass-cost-header]` lines for the report (the host
// rasterizes in software; on the Fold see REPORT-Q9-CRISTAL). The test
// asserts what the design promises: the strip pushes one backdrop layer
// for three pieces.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';

enum _Header { none, strip, pieces }

class _Stream extends ChangeNotifier {
  final words = <String>[];
  void add(String word) {
    words.add(word);
    notifyListeners();
  }
}

/// The visible height of a header piece (HermesAppBar.pieceSize).
const double _pieceHeight = 44;

/// A piece of the header: in the strip, its outline and the strip's veil;
/// on its own, the composer's glass with its own blur.
Widget _piece(_Header header, double width) {
  final radius = BorderRadius.circular(_pieceHeight / 2);
  const box = SizedBox(height: _pieceHeight);
  if (header == _Header.pieces) {
    return FrostedBackdrop.glass(
      borderRadius: radius,
      child: SizedBox(width: width, child: box),
    );
  }
  return Builder(
    builder: (context) {
      final chrome = HermesChrome.ofContext(context);
      return HermesGlassPiece(
        shape: const StadiumBorder(),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: HermesGlassStrip.of(context)?.veil ?? chrome.fill,
            borderRadius: radius,
            border: Border.all(color: chrome.line),
          ),
          child: SizedBox(width: width, child: box),
        ),
      );
    },
  );
}

Widget _scene(
  _Header header,
  _Stream stream,
  ScrollController scroll,
  Key root,
) {
  final pieces = Row(
    children: [
      const SizedBox(width: 8),
      _piece(header, 44),
      const Spacer(),
      _piece(header, 170),
      const Spacer(),
      _piece(header, 96),
      const SizedBox(width: 8),
    ],
  );
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
                padding: const EdgeInsets.fromLTRB(12, 80, 16, 40),
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
              left: 0,
              right: 0,
              top: 24,
              height: 56,
              child: HermesGlassStrip(
                enabled: header == _Header.strip,
                child: Center(child: pieces),
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
  final results = <_Header, ({double raster, double p90})>{};

  for (final header in _Header.values) {
    testWidgets('[glass-cost-header] ${header.name}: a reply streaming '
        'behind the header', (tester) async {
      tester.view.physicalSize = const Size(1080, 2256);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final stream = _Stream();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final root = GlobalKey();
      await tester.pumpWidget(_scene(header, stream, scroll, root));
      await tester.pump();
      final raster = <double>[];
      for (var frame = 0; frame < frames; frame++) {
        stream.add('palabra$frame');
        if (scroll.hasClients) {
          scroll.jumpTo(
            (scroll.offset + 6).clamp(0.0, scroll.position.maxScrollExtent),
          );
        }
        await tester.pump(const Duration(milliseconds: 16));
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
      results[header] = (raster: _median(raster), p90: _p90(raster));
      // ignore: avoid_print
      print(
        '[glass-cost-header] header=${header.name} frames=$frames '
        'backdropLayers=$layers '
        'raster_median_ms=${_median(raster).toStringAsFixed(2)} '
        'raster_p90_ms=${_p90(raster).toStringAsFixed(2)}',
      );
      switch (header) {
        case _Header.none:
          expect(layers, 0);
        case _Header.strip:
          expect(layers, 1, reason: 'one blur for three pieces');
        case _Header.pieces:
          expect(layers, 3);
      }
    });
  }

  test('[glass-cost-header] summary', () {
    // Every set-up must have run: a summary of nothing is not a measure.
    expect(results.keys, unorderedEquals(_Header.values));
    final none = results[_Header.none]!;
    final strip = results[_Header.strip]!;
    final pieces = results[_Header.pieces]!;
    // ignore: avoid_print
    print(
      '[glass-cost-header] summary '
      'strip/none=${(strip.raster / none.raster).toStringAsFixed(2)}x '
      'pieces/none=${(pieces.raster / none.raster).toStringAsFixed(2)}x '
      'strip_p90_ms=${strip.p90.toStringAsFixed(2)} '
      'pieces_p90_ms=${pieces.p90.toStringAsFixed(2)}',
    );
  });
}
