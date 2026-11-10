// QA 9709: the voice capsule's wave follows the reply while it plays. The
// server's streamed voice is the audio Console has in hand: the sink that
// feeds AudioTrack also says how loud each window is, at the pace it plays.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/hermes_pcm_stream.dart';
import 'package:hermes_android/core/services/voice/pcm_level_sink.dart';

class _Sink implements HermesPcmStreamSink {
  final List<String> calls = [];

  @override
  int get generation => 7;

  @override
  Future<void> configure(HermesPcmFormat format) async =>
      calls.add('configure ${format.sampleRate}');

  @override
  Future<void> write(Uint8List pcm16le) async =>
      calls.add('write ${pcm16le.length}');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> finish() async => calls.add('finish');

  @override
  Future<void> stop() async => calls.add('stop');
}

/// [seconds] of a sine at [amplitude] (0..1), 16 kHz mono int16.
Uint8List _tone(double seconds, double amplitude, {int rate = 16000}) {
  final count = (seconds * rate).round();
  final data = ByteData(count * 2);
  for (var i = 0; i < count; i++) {
    final v = amplitude * math.sin(2 * math.pi * 220 * i / rate);
    data.setInt16(i * 2, (v * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  const format = HermesPcmFormat(sampleRate: 16000, channels: 1);
  // 16 windows a second at 16 kHz: 1000 samples, 62.5 ms each.
  const window = Duration(microseconds: 62500);

  test('window levels: the RMS of each window, louder is higher', () {
    final loud = pcmWindowLevels(_tone(0.25, 0.8), 1000);
    final soft = pcmWindowLevels(_tone(0.25, 0.1), 1000);
    expect(loud, hasLength(4));
    // A sine's RMS is its amplitude / √2.
    for (final level in loud) {
      expect(level, closeTo(0.8 / math.sqrt2, 0.01));
    }
    expect(soft.first, closeTo(0.1 / math.sqrt2, 0.01));
    // 2000 samples of silence (4000 bytes): two windows of nothing.
    expect(pcmWindowLevels(Uint8List(4000), 1000), [0, 0]);
    // A last shorter window counts too: 1500 samples are two windows.
    expect(pcmWindowLevels(Uint8List(3000), 1000), [0, 0]);
  });

  // In testWidgets the clock is the test's own: a pump plays the windows,
  // and a timer still pending at the end fails the test, so every timer
  // the sink starts must be gone by then.
  testWidgets('what AudioTrack accepted is told window by window, at its '
      'pace, then 0', (tester) async {
    final inner = _Sink();
    final level = ValueNotifier<double>(0);
    addTearDown(level.dispose);
    final sink = LevelReportingPcmSink(inner, level);

    await sink.configure(format);
    await sink.write(_tone(0.25, 0.8));
    expect(level.value, closeTo(0.8 / math.sqrt2, 0.01), reason: 'at once');
    // Its four windows play one after the other, then nothing.
    for (var i = 1; i < 4; i++) {
      await tester.pump(window);
      expect(level.value, greaterThan(0.5), reason: 'window $i');
    }
    await tester.pump(window);
    expect(level.value, 0, reason: 'drained');
    await tester.pump(window * 4);
    expect(level.value, 0, reason: 'nothing more comes');

    // A softer block reads softer.
    await sink.write(_tone(0.125, 0.1));
    expect(level.value, closeTo(0.1 / math.sqrt2, 0.01));
    await sink.finish();
    expect(level.value, 0);
    await tester.pump(window * 4);
    expect(level.value, 0);
    expect(inner.calls, [
      'configure 16000',
      'write 8000',
      'write 4000',
      'finish',
    ]);
  });

  testWidgets('pause holds the level at 0 and resume goes on; stop clears '
      'it', (tester) async {
    final inner = _Sink();
    final level = ValueNotifier<double>(0);
    addTearDown(level.dispose);
    final sink = LevelReportingPcmSink(inner, level);
    await sink.configure(format);
    await sink.write(_tone(0.5, 0.6));
    expect(level.value, greaterThan(0));

    await sink.pause();
    expect(level.value, 0);
    await tester.pump(window * 4);
    expect(level.value, 0, reason: 'paused: nothing plays');

    await sink.resume();
    expect(level.value, greaterThan(0));
    await tester.pump(window);
    expect(level.value, greaterThan(0), reason: 'it goes on playing');

    await sink.stop();
    expect(level.value, 0);
    await tester.pump(window * 10);
    expect(level.value, 0);
    expect(sink.generation, 7);
    expect(inner.calls, contains('stop'));
  });
}
