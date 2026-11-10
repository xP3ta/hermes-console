// QA 9709 (the owner): the voice's wave is not a «curtain» of five bars going up
// and down together: thin bars across the whole width, drawing the recent
// history of the level, moving left as it comes in. Still with «reduce
// motion».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/voice_wave.dart';

const _sample = Duration(milliseconds: 60);

Widget _app(Widget child, {double width = 300, bool reduceMotion = false}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Scaffold(body: Center(child: SizedBox(width: width, child: child))),
    );

VoiceWaveState _state(WidgetTester tester) =>
    tester.state<VoiceWaveState>(find.byType(VoiceWave));

Future<void> _samples(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(_sample);
  }
}

void main() {
  for (final width in const [196.0, 236.0, 288.0, 360.0]) {
    testWidgets('$width dp: the bars fill the width they are given', (
      tester,
    ) async {
      final level = ValueNotifier<double>(0);
      addTearDown(level.dispose);
      await tester.pumpWidget(
        _app(
          VoiceWave(
            mode: VoiceWaveMode.listening,
            level: level,
            color: Colors.orange,
          ),
          width: width,
        ),
      );
      expect(tester.getSize(find.byType(VoiceWave)).width, width);
      final bars = VoiceWave.barsFor(width);
      // Every bar fits, and one more would not.
      const step = VoiceWave.barWidth + VoiceWave.barGap;
      expect(bars * step - VoiceWave.barGap, lessThanOrEqualTo(width));
      expect((bars + 1) * step - VoiceWave.barGap, greaterThan(width));
      // The history keeps one more sample, the one sliding in.
      expect(_state(tester).samples, hasLength(bars + 1));
    });
  }

  testWidgets('listening: the level comes in on the right and moves left', (
    tester,
  ) async {
    final level = ValueNotifier<double>(0);
    addTearDown(level.dispose);
    await tester.pumpWidget(
      _app(
        VoiceWave(
          mode: VoiceWaveMode.listening,
          level: level,
          color: Colors.orange,
        ),
      ),
    );
    final state = _state(tester);
    expect(state.ticking, isTrue);
    // A quiet room first: the bars stay down.
    await _samples(tester, 10);
    expect(state.samples.every((s) => s == 0), isTrue);

    // Speech: the newest bars rise, the older ones are still the quiet.
    level.value = 0.25;
    await _samples(tester, 3);
    final speaking = state.samples;
    expect(speaking.last, greaterThan(0.5));
    expect(speaking.first, 0);

    // Quiet again: what was said moves left and the new bars fall.
    level.value = 0;
    await _samples(tester, 6);
    final after = state.samples;
    expect(after.last, lessThan(speaking.last));
    final rise = after.indexWhere((s) => s > 0.5);
    expect(rise, greaterThan(0));
    expect(rise, lessThan(after.length - 3), reason: 'it slid left');
    // Between two samples the bars are part way to the next place.
    await tester.pump(_sample ~/ 2);
    expect(state.slide, closeTo(0.5, 0.05));
  });

  testWidgets('speaking follows the level it is given, not another', (
    tester,
  ) async {
    final speech = ValueNotifier<double>(0);
    addTearDown(speech.dispose);
    await tester.pumpWidget(
      _app(
        VoiceWave(
          mode: VoiceWaveMode.speaking,
          level: speech,
          color: Colors.green,
        ),
      ),
    );
    await _samples(tester, 5);
    expect(_state(tester).samples.last, 0);
    speech.value = 0.3;
    await _samples(tester, 2);
    expect(_state(tester).samples.last, greaterThan(0.5));
  });

  testWidgets('thinking: a slow pulse, no history; at rest nothing runs', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const VoiceWave(mode: VoiceWaveMode.thinking, color: Colors.grey)),
    );
    final state = _state(tester);
    expect(state.ticking, isTrue);
    await tester.pump(const Duration(milliseconds: 600));
    final early = state.pulse;
    await tester.pump(const Duration(milliseconds: 600));
    expect(state.pulse, greaterThan(early));
    expect(state.samples.every((s) => s == 0), isTrue);

    await tester.pumpWidget(
      _app(const VoiceWave(mode: VoiceWaveMode.rest, color: Colors.grey)),
    );
    expect(_state(tester).ticking, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduce motion: a still wave, nothing scheduled', (tester) async {
    final level = ValueNotifier<double>(0.3);
    addTearDown(level.dispose);
    for (final mode in VoiceWaveMode.values) {
      await tester.pumpWidget(
        _app(
          VoiceWave(mode: mode, level: level, color: Colors.orange),
          reduceMotion: true,
        ),
      );
      final state = _state(tester);
      expect(state.ticking, isFalse, reason: mode.name);
      await _samples(tester, 4);
      expect(state.samples.every((s) => s == 0), isTrue, reason: mode.name);
      expect(tester.binding.transientCallbackCount, 0, reason: mode.name);
    }
  });
}
