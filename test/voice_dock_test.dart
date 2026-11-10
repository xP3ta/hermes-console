// SPDX-License-Identifier: MIT
// Voz inline: the composer becomes the voice dock — mute, a live wave with
// the state's one action as a chip, and ✕ — and nothing in it moves between
// states.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/voice_dock.dart';
import 'package:hermes_android/core/widgets/voice_strip.dart'
    show VoiceStripState;
import 'package:hermes_android/core/widgets/voice_wave.dart';

const _labels = VoiceDockLabels(
  pause: 'Pausar',
  resume: 'Reanudar',
  close: 'Terminar modo voz',
  sendNow: 'Enviar ya',
  interrupt: 'Interrumpir',
  retry: 'Reintentar',
  review: 'Revisar',
  type: 'Escribir en vez de hablar',
);

Widget _host(
  Widget child, {
  double width = 380,
  double textScale = 1,
  bool reducedMotion = false,
  TextDirection direction = TextDirection.ltr,
}) {
  return MaterialApp(
    theme: AppTheme.fromId('dark'),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: reducedMotion,
      ),
      child: Directionality(textDirection: direction, child: child!),
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(width: width, height: 52, child: child),
      ),
    ),
  );
}

final _calls = <String>[];

VoiceDock _dock(VoiceStripState state, {bool reduceMotion = false}) =>
    VoiceDock(
      state: state,
      labels: _labels,
      onPause: () => _calls.add('pause'),
      onResume: () => _calls.add('resume'),
      onFinishListening: () => _calls.add('finish'),
      onStopAndTalk: () => _calls.add('stopAndTalk'),
      onRetry: () => _calls.add('retry'),
      onReview: () => _calls.add('review'),
      onType: () => _calls.add('type'),
      onClose: () => _calls.add('close'),
      reduceMotion: reduceMotion,
    );

Finder get _mute => find.byWidgetPredicate(
  (w) =>
      w.key == const ValueKey('voice-strip-pause') ||
      w.key == const ValueKey('voice-strip-resume') ||
      w.key == const ValueKey('voice-dock-mute'),
);

const _chipKeys = [
  'voice-strip-finish-listening',
  'voice-strip-stop-and-talk',
  'voice-strip-retry',
  'voice-strip-review',
];

String? _chipShown(WidgetTester tester) {
  for (final key in _chipKeys) {
    if (find.byKey(ValueKey(key)).evaluate().isNotEmpty) return key;
  }
  return null;
}

void main() {
  setUp(_calls.clear);

  testWidgets('no slot of the dock moves between the nine states', (
    tester,
  ) async {
    Rect? mute;
    Rect? close;
    Rect? dock;
    for (final state in VoiceStripState.values) {
      await tester.pumpWidget(_host(_dock(state)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_mute, findsOneWidget, reason: '$state');
      final m = tester.getRect(_mute);
      final c = tester.getRect(find.byKey(const ValueKey('voice-strip-close')));
      final d = tester.getRect(find.byKey(const ValueKey('voice-dock')));
      mute ??= m;
      close ??= c;
      dock ??= d;
      expect(m, mute, reason: '$state');
      expect(c, close, reason: '$state');
      expect(d, dock, reason: '$state');
      expect(tester.takeException(), isNull, reason: '$state');
    }
  });

  testWidgets('each state offers its one action as a chip, by the rules', (
    tester,
  ) async {
    const expected = {
      VoiceStripState.loading: null,
      VoiceStripState.listening: 'voice-strip-finish-listening',
      VoiceStripState.transcribing: null,
      VoiceStripState.thinking: null,
      VoiceStripState.toolCall: null,
      VoiceStripState.speaking: 'voice-strip-stop-and-talk',
      VoiceStripState.waiting: 'voice-strip-review',
      VoiceStripState.paused: null,
      VoiceStripState.error: 'voice-strip-retry',
    };
    for (final entry in expected.entries) {
      await tester.pumpWidget(_host(_dock(entry.key)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_chipShown(tester), entry.value, reason: '${entry.key}');
    }

    // Without an engine that waits to be told, listening has no chip.
    await tester.pumpWidget(
      _host(
        VoiceDock(
          state: VoiceStripState.listening,
          labels: _labels,
          onClose: () {},
          onPause: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(_chipShown(tester), isNull);
  });

  testWidgets('with work to stop, Stop is the chip where the state has '
      'none of its own', (tester) async {
    Widget dock(VoiceStripState state) => _host(
      VoiceDock(
        state: state,
        labels: const VoiceDockLabels(
          pause: 'Pausar',
          resume: 'Reanudar',
          close: 'Terminar modo voz',
          sendNow: 'Enviar ya',
          interrupt: 'Interrumpir',
          retry: 'Reintentar',
          review: 'Revisar',
          type: 'Escribir en vez de hablar',
          stop: 'Detener',
        ),
        onClose: () {},
        onPause: () {},
        onResume: () {},
        onStopAndTalk: () {},
        onRetry: () {},
        onStop: () => _calls.add('stop'),
      ),
    );
    const stop = ValueKey('voice-dock-stop');
    for (final state in [
      VoiceStripState.thinking,
      VoiceStripState.toolCall,
      VoiceStripState.paused,
      VoiceStripState.listening,
    ]) {
      await tester.pumpWidget(dock(state));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(stop), findsOneWidget, reason: '$state');
    }
    await tester.tap(find.byKey(stop));
    expect(_calls, ['stop']);
    expect(find.bySemanticsLabel('Detener'), findsOneWidget);

    // The state's own action wins over Stop.
    for (final state in [VoiceStripState.speaking, VoiceStripState.error]) {
      await tester.pumpWidget(dock(state));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(stop), findsNothing, reason: '$state');
    }
  });

  testWidgets('mute pauses a live state, resumes a paused one, and is '
      'dimmed where nothing can pause', (tester) async {
    await tester.pumpWidget(_host(_dock(VoiceStripState.listening)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('voice-strip-pause')));
    expect(_calls, ['pause']);

    await tester.pumpWidget(_host(_dock(VoiceStripState.paused)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-strip-resume')));
    expect(_calls, ['pause', 'resume']);

    await tester.pumpWidget(_host(_dock(VoiceStripState.loading)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('voice-dock-mute')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-dock-mute')));
    expect(_calls, ['pause', 'resume'], reason: 'nothing to pause yet');

    await tester.tap(find.byKey(const ValueKey('voice-strip-close')));
    await tester.tap(find.byKey(const ValueKey('voice-dock-wave')));
    expect(_calls, ['pause', 'resume', 'close', 'type']);
  });

  testWidgets('mute, ✕ and the chip are 48 dp targets with their names', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(_dock(VoiceStripState.speaking)));
    await tester.pump(const Duration(milliseconds: 300));
    for (final key in [
      'voice-strip-pause',
      'voice-strip-close',
      'voice-strip-stop-and-talk',
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
    }
    expect(find.bySemanticsLabel('Pausar'), findsOneWidget);
    expect(find.bySemanticsLabel('Terminar modo voz'), findsOneWidget);
    expect(find.bySemanticsLabel('Interrumpir'), findsOneWidget);
    expect(find.bySemanticsLabel('Escribir en vez de hablar'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('right to left, ✕ is on the left and mute on the right', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_dock(VoiceStripState.listening), direction: TextDirection.rtl),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final close = tester.getRect(
      find.byKey(const ValueKey('voice-strip-close')),
    );
    final mute = tester.getRect(_mute);
    expect(close.right, lessThan(mute.left));
  });

  testWidgets('reduce motion keeps the wave still', (tester) async {
    await tester.pumpWidget(
      _host(_dock(VoiceStripState.listening, reduceMotion: true)),
    );
    await tester.pump();
    expect(
      tester.widget<VoiceWave>(find.byType(VoiceWave)).mode,
      VoiceWaveMode.rest,
    );

    await tester.pumpWidget(_host(_dock(VoiceStripState.listening)));
    await tester.pump();
    expect(
      tester.widget<VoiceWave>(find.byType(VoiceWave)).mode,
      VoiceWaveMode.listening,
    );
  });

  testWidgets('a narrow dock at 200 % text cuts the chip, never overflows', (
    tester,
  ) async {
    for (final state in VoiceStripState.values) {
      await tester.pumpWidget(_host(_dock(state), width: 240, textScale: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '$state');
      expect(
        tester.getRect(find.byKey(const ValueKey('voice-strip-close'))).right,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey('voice-dock'))).right,
        ),
      );
    }
  });
}
