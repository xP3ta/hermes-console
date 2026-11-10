import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat/live_reply_reveal.dart';

// Like pm1215, keep the source/build work distinct from subsequent frames.
// These wall-clock pump samples are a CPU regression budget, not Fold GPU fps.
void main() {
  testWidgets('long stable prefix is not reprocessed on display frames', (
    tester,
  ) async {
    final paragraphs = List.generate(
      180,
      (index) => 'Párrafo $index: ${'palabra ' * 30}',
    );
    final revision = Object();
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 390,
              child: LiveReplyReveal(
                revision: revision,
                child: Builder(
                  builder: (_) {
                    builds++;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final paragraph in paragraphs)
                          RepaintBoundary(child: Text(paragraph)),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final render = tester.renderObject<RenderLiveReplyReveal>(
      find.byType(LiveReplyReveal),
    );
    final geometry = render.geometryBuilds;
    final samples = <double>[];
    for (var frame = 0; frame < 40; frame++) {
      final watch = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 8));
      watch.stop();
      samples.add(watch.elapsedMicroseconds / 1000);
      expect(builds, 1);
      expect(render.geometryBuilds, geometry);
      expect(
        render.clipRectCount,
        lessThanOrEqualTo(3),
        reason: 'closed transcript paragraphs never enter the per-frame path',
      );
    }
    samples.sort();
    final p50 = samples[samples.length ~/ 2];
    final p90 = samples[(samples.length * 0.9).floor()];
    debugPrint(
      'Q9_REPLY_CPU frames=${samples.length} p50=$p50 p90=$p90 max=${samples.last} ms',
    );
    // Same generous magnitude guard as live_streaming_frame_budget; the
    // deterministic no-build/no-geometry assertions above are the core gate.
    expect(p90, lessThan(120));
    await tester.pumpAndSettle();
    expect(debugActiveLiveReplyClocks, 0);
  });
}
