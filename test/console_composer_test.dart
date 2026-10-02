import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/voice/sherpa_stt_worker.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_source_sheet.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('es'),
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: Align(alignment: Alignment.bottomCenter, child: child),
  ),
);

/// Records the bars a dictation painter draws, without a real canvas.
class _BarsCanvas implements Canvas {
  final List<Rect> bars = <Rect>[];

  @override
  void drawRRect(RRect rrect, Paint paint) => bars.add(rrect.outerRect);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

List<Rect> _paintedBars(WidgetTester tester) {
  final paint = find.byKey(const ValueKey('dictation-bars-paint'));
  final size = tester.getSize(paint);
  final canvas = _BarsCanvas();
  tester.widget<CustomPaint>(paint).painter!.paint(canvas, size);
  return canvas.bars;
}

void main() {
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  ConsoleComposerDictation dictation({
    bool recording = false,
    VoidCallback? onStart,
    ValueListenable<double>? level,
  }) => ConsoleComposerDictation(
    recording: recording,
    level: level,
    onStart: onStart ?? () {},
    onStop: () {},
    onCancel: () {},
    onSend: () {},
  );

  testWidgets('envía el texto y los adjuntos por onSend', (tester) async {
    String? sentText;
    List<AttachmentDraft>? sentAttachments;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => ConsoleComposer(
            controller: controller,
            focusNode: focusNode,
            onAttach: (_) {},
            dictation: dictation(),
            sendEnabled: true,
            onSend: (text, attachments) {
              sentText = text;
              sentAttachments = attachments;
            },
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('composer-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('mic')), findsOneWidget);
    expect(find.byKey(const ValueKey('send')), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hola sala');
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('send')),
        matching: find.byType(ConsoleSendButton),
      ),
    );
    await tester.pump();
    expect(sentText, 'hola sala');
    expect(sentAttachments, isEmpty);
  });

  testWidgets('el campo crece con el texto hasta cuatro líneas', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onSend: (_, _) {},
        ),
      ),
    );
    final row = find.byKey(const ValueKey('composer-input-row'));
    final before = tester.getSize(row).height;
    await tester.enterText(find.byType(TextField), 'uno\ndos\ntres');
    await tester.pump();
    expect(tester.getSize(row).height, greaterThan(before));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 1);
    expect(field.maxLines, 4);
  });

  testWidgets('stop sustituye a enviar y llama a onStop', (tester) async {
    var stopped = 0;
    await tester.pumpWidget(
      _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onSend: (_, _) {},
          showStop: true,
          onStop: () => stopped++,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('stop')), findsOneWidget);
    expect(find.byKey(const ValueKey('send')), findsNothing);
    await tester.tap(find.byType(ConsoleSendButton));
    await tester.pump();
    expect(stopped, 1);
  });

  testWidgets('showBotModeToggle=false oculta modo voz y pastilla de modo', (
    tester,
  ) async {
    Widget build(bool show) => _host(
      ConsoleComposer(
        controller: controller,
        focusNode: focusNode,
        onSend: (_, _) {},
        showBotModeToggle: show,
        voiceModeAction: const SizedBox(key: ValueKey('voice-mode-launch')),
        footer: const SizedBox(key: ValueKey('mode-pill')),
      ),
    );
    await tester.pumpWidget(build(true));
    expect(find.byKey(const ValueKey('voice-mode-launch')), findsOneWidget);
    expect(find.byKey(const ValueKey('mode-pill')), findsOneWidget);

    await tester.pumpWidget(build(false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-mode-launch')), findsNothing);
    expect(find.byKey(const ValueKey('mode-pill')), findsNothing);
    expect(find.byKey(const ValueKey('send')), findsOneWidget);
  });

  testWidgets('sin onAttach ni dictado no hay + ni micrófono', (tester) async {
    await tester.pumpWidget(
      _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onSend: (_, _) {},
        ),
      ),
    );
    expect(find.byType(AttachmentSourceMenuButton), findsNothing);
    expect(find.byKey(const ValueKey('mic')), findsNothing);
  });

  testWidgets('el micrófono arranca el dictado y grabando muestra la onda', (
    tester,
  ) async {
    var started = 0;
    await tester.pumpWidget(
      _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onSend: (_, _) {},
          dictation: dictation(onStart: () => started++),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('mic')));
    await tester.pump();
    expect(started, 1);

    final level = ValueNotifier<double>(0.4);
    addTearDown(level.dispose);
    await tester.pumpWidget(
      _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onSend: (_, _) {},
          onAttach: (_) {},
          dictation: dictation(recording: true, level: level),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('dictation-visualizer')), findsOneWidget);
    expect(find.byKey(const ValueKey('dictation-cancel')), findsOneWidget);
    expect(find.byKey(const ValueKey('dictation-send')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-add')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('dictation visualizer', () {
    Future<ValueNotifier<double>> pumpRecording(
      WidgetTester tester, {
      bool reduceMotion = false,
    }) async {
      final level = ValueNotifier<double>(0);
      addTearDown(level.dispose);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: _host(
            ConsoleComposer(
              controller: controller,
              focusNode: focusNode,
              onSend: (_, _) {},
              dictation: dictation(recording: true, level: level),
            ),
          ),
        ),
      );
      return level;
    }

    Future<void> feed(
      WidgetTester tester,
      ValueNotifier<double> level,
      List<double> values, {
      Duration each = const Duration(milliseconds: 100),
    }) async {
      for (final value in values) {
        level.value = value;
        for (
          var t = Duration.zero;
          t < each;
          t += const Duration(milliseconds: 16)
        ) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
    }

    // Sherpa and the server engine publish `RMS * 4`; the Desktop speech gate
    // sits at 0.098 on that scale, so normal speech lives around 0.05-0.25.
    const speech = SherpaDesktopSpeechGate.levelThreshold;

    testWidgets('normal speech levels raise the bars well above the floor', (
      tester,
    ) async {
      final level = await pumpRecording(tester);
      await feed(tester, level, const [speech, speech, speech]);

      final bars = _paintedBars(tester);
      final tallest = bars.map((bar) => bar.height).reduce(math.max);
      expect(tallest, greaterThanOrEqualTo(kConsoleDictationWaveHeight * 0.45));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a changing voice level produces a visibly varying wave', (
      tester,
    ) async {
      final level = await pumpRecording(tester);
      // Pauses between syllables fall back to the ambient (~0.02).
      await feed(tester, level, const [
        0.02,
        0.2,
        0.02,
        0.2,
        0.02,
        0.2,
        0.02,
        0.2,
      ]);

      final heights = _paintedBars(
        tester,
      ).skip(24).map((bar) => bar.height).toList();
      final spread = heights.reduce(math.max) - heights.reduce(math.min);
      expect(spread, greaterThanOrEqualTo(kConsoleDictationWaveHeight * 0.3));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('dB-normalised engines still vary above their ambient', (
      tester,
    ) async {
      // Whisper and the clip engines report `(dBFS + 60) / 60`: a quiet room
      // already reads ~0.55 and speech peaks near 0.8.
      final level = await pumpRecording(tester);
      await feed(tester, level, List<double>.filled(20, 0.55));
      await feed(tester, level, const [0.55, 0.8, 0.55, 0.8, 0.55, 0.8]);

      final heights = _paintedBars(
        tester,
      ).skip(24).map((bar) => bar.height).toList();
      final spread = heights.reduce(math.max) - heights.reduce(math.min);
      expect(spread, greaterThanOrEqualTo(kConsoleDictationWaveHeight * 0.3));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('silence keeps the bars at their resting height', (
      tester,
    ) async {
      final level = await pumpRecording(tester);
      await feed(tester, level, const [0.01, 0.01, 0.01, 0.01]);

      final bars = _paintedBars(tester);
      final tallest = bars.map((bar) => bar.height).reduce(math.max);
      expect(tallest, lessThanOrEqualTo(4));
      for (final bar in bars) {
        expect(bar.center.dy, closeTo(kConsoleDictationWaveHeight / 2, 0.01));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the live bar eases toward the level on every frame', (
      tester,
    ) async {
      final level = await pumpRecording(tester);
      await feed(tester, level, const [0.01]);
      final dynamic state = tester.state(
        find.byKey(const ValueKey('dictation-visualizer')),
      );
      expect(state.debugClockActive, isTrue);

      level.value = 0.3;
      final newest = <double>[];
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        newest.add(_paintedBars(tester).last.height);
      }
      // Smooth attack: no instant jump, but a steady rise frame after frame.
      expect(newest.first, lessThan(kConsoleDictationWaveHeight * 0.75));
      for (var i = 1; i < newest.length; i++) {
        expect(newest[i], greaterThan(newest[i - 1]));
      }
      expect(newest.last, greaterThan(kConsoleDictationWaveHeight * 0.6));

      // The history glides between frames instead of stepping every 33 ms.
      final before = _paintedBars(tester).map((bar) => bar.left).toList();
      await tester.pump(const Duration(milliseconds: 16));
      final after = _paintedBars(tester).map((bar) => bar.left).toList();
      expect(after, isNot(orderedEquals(before)));

      // No frame callbacks or timers while the app is in the background.
      expect(state.debugAnimating, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(state.debugAnimating, isFalse);
      expect(state.debugClockActive, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(state.debugAnimating, isTrue);
      expect(state.debugClockActive, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('reduced motion shows the level without easing or gliding', (
      tester,
    ) async {
      final level = await pumpRecording(tester, reduceMotion: true);
      await feed(tester, level, const [0.01]);
      final dynamic state = tester.state(
        find.byKey(const ValueKey('dictation-visualizer')),
      );
      expect(state.debugAnimating, isFalse);
      expect(state.debugClockActive, isTrue);

      level.value = speech;
      await tester.pump(const Duration(milliseconds: 34));
      final bars = _paintedBars(tester);
      expect(bars.last.height, greaterThanOrEqualTo(12));

      // Between history steps nothing moves: no interpolated frames.
      final settled = await () async {
        await tester.pump(const Duration(milliseconds: 1));
        return _paintedBars(tester);
      }();
      await tester.pump(const Duration(milliseconds: 16));
      final later = _paintedBars(tester);
      expect(
        later.map((bar) => bar.left),
        orderedEquals(settled.map((bar) => bar.left)),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
