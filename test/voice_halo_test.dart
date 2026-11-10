// SPDX-License-Identifier: MIT
// Voz inline: the sprite's halo is the voice's orb. It follows the level in
// its own layer (no rebuild per tick), eases toward it, and is still with
// reduce motion.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/voice_halo.dart';

Widget _host(Widget halo, {VoidCallback? onParentBuild}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: Builder(
      builder: (context) {
        onParentBuild?.call();
        return SizedBox.square(dimension: 80, child: halo);
      },
    ),
  ),
);

double _amplitude(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.byKey(const ValueKey('voice-halo-paint')),
  );
  return (paint.painter! as VoiceHaloPainter).amplitude.value;
}

void main() {
  testWidgets('the halo follows the level, eased, without rebuilding', (
    tester,
  ) async {
    final level = ValueNotifier<double>(0);
    addTearDown(level.dispose);
    var parentBuilds = 0;
    await tester.pumpWidget(
      _host(
        VoiceHalo(
          mode: VoiceHaloMode.listening,
          color: const Color(0xFF2EC4B6),
          level: level,
        ),
        onParentBuild: () => parentBuilds++,
      ),
    );
    final builds = parentBuilds;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final quiet = _amplitude(tester);

    level.value = 1;
    await tester.pump(const Duration(milliseconds: 16));
    final firstFrame = _amplitude(tester);
    expect(firstFrame, greaterThan(quiet));
    expect(firstFrame, lessThan(0.9), reason: 'eased, not a jump');
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_amplitude(tester), greaterThan(0.9));
    expect(parentBuilds, builds, reason: 'a level tick rebuilds nothing');
  });

  testWidgets('thinking breathes; off fades out and stops ticking', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const VoiceHalo(mode: VoiceHaloMode.thinking, color: Color(0xFF2EC4B6)),
      ),
    );
    final seen = <double>{};
    for (var i = 0; i < 160; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      seen.add((_amplitude(tester) * 100).roundToDouble());
    }
    expect(seen.length, greaterThan(5), reason: 'it breathes');
    expect(seen.every((a) => a > 0), isTrue);

    await tester.pumpWidget(
      _host(const VoiceHalo(mode: VoiceHaloMode.off, color: Color(0xFF2EC4B6))),
    );
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_amplitude(tester), 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduce motion: one still soft halo, no ticker', (tester) async {
    final level = ValueNotifier<double>(0);
    addTearDown(level.dispose);
    await tester.pumpWidget(
      _host(
        VoiceHalo(
          mode: VoiceHaloMode.speaking,
          color: const Color(0xFFFFC37A),
          level: level,
          reduceMotion: true,
        ),
      ),
    );
    expect(_amplitude(tester), VoiceHalo.stillAmplitude);
    level.value = 1;
    await tester.pump(const Duration(milliseconds: 16));
    expect(_amplitude(tester), VoiceHalo.stillAmplitude);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(
      _host(
        const VoiceHalo(
          mode: VoiceHaloMode.off,
          color: Color(0xFFFFC37A),
          reduceMotion: true,
        ),
      ),
    );
    expect(_amplitude(tester), 0);
  });
}
