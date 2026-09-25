import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/performance_trace.dart';

void main() {
  test('retains a bounded, content-free trace of slow frames', () {
    final trace = PerformanceTrace(enabled: true, capacity: 2);

    trace.recordFrameForTesting(buildMs: 18, rasterMs: 4);
    trace.recordFrameForTesting(buildMs: 8, rasterMs: 130);
    trace.recordFrameForTesting(buildMs: 3, rasterMs: 2);
    trace.recordFrameForTesting(buildMs: 120, rasterMs: 20);

    expect(trace.snapshotForTesting(), {
      'slowFrames': [
        {'buildMs': 8, 'rasterMs': 130, 'totalMs': 138},
        {'buildMs': 120, 'rasterMs': 20, 'totalMs': 140},
      ],
      'slowFrameCount': 3,
    });
  });
}
