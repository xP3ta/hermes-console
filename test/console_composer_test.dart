import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/voice/sherpa_stt_worker.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_source_sheet.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/voice_meter.dart';
import 'package:hermes_android/core/widgets/voice_strip.dart';
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
    const speech = SherpaSpeechGate.desktopLevel;

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

  group('voice conversation controls', () {
    const controlsKey = ValueKey('voice-controls');

    /// Stand-in for the conversation's controls: the composer only gives
    /// them room, it does not know what they are.
    ConsoleComposerVoiceControls controls({
      bool takesPrimarySlot = true,
      List<double>? widths,
      VoidCallback? onTap,
    }) => ConsoleComposerVoiceControls(
      takesPrimarySlot: takesPrimarySlot,
      minWidth: 96,
      builder: (context, maxWidth, comfortWidth) {
        expect(comfortWidth, lessThanOrEqualTo(maxWidth));
        widths?.add(maxWidth);
        return GestureDetector(
          key: controlsKey,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: const SizedBox(width: 96, height: 48),
        );
      },
    );

    testWidgets('the voice meter moves without building the composer', (
      tester,
    ) async {
      final level = ValueNotifier<double>(0);
      addTearDown(level.dispose);
      var composerBuilds = 0;
      var controlsBuilds = 0;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              composerBuilds++;
              return ConsoleComposer(
                controller: controller,
                focusNode: focusNode,
                onAttach: (_) {},
                dictation: dictation(),
                onSend: (_, _) {},
                sendEnabled: false,
                voiceControls: ConsoleComposerVoiceControls(
                  takesPrimarySlot: true,
                  minWidth: VoiceComposerControls.minWidth,
                  builder: (context, maxWidth, comfortWidth) {
                    controlsBuilds++;
                    return VoiceComposerControls(
                      state: VoiceStripState.listening,
                      maxWidth: maxWidth,
                      comfortWidth: comfortWidth,
                      micLevel: level,
                      labels: const VoiceStripLabels(
                        finishListening: 'Terminar de hablar',
                        pause: 'Pausar',
                        resume: 'Reanudar',
                        stopAndTalk: 'Parar y hablar',
                        cancel: 'Cancelar tarea',
                        stop: 'Detener',
                        retry: 'Reintentar',
                        review: 'Ver aprobación',
                        close: 'Terminar modo voz',
                        end: 'Terminar',
                      ),
                      onPause: () {},
                      onClose: () {},
                    );
                  },
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      final meter = tester.state<VoiceMeterState>(find.byType(VoiceMeter));
      final builtComposer = composerBuilds;
      final builtControls = controlsBuilds;
      final builtMeter = meter.builds;

      // A second of somebody talking, a level every 20 ms.
      for (var chunk = 0; chunk < 50; chunk++) {
        level.value = chunk < 10 ? 0.005 : 0.05 + (chunk % 5) * 0.03;
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(meter.shown, greaterThan(0.3), reason: 'it did move');
      expect(composerBuilds, builtComposer);
      expect(controlsBuilds, builtControls);
      expect(meter.builds, builtMeter);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('they take the place of the start-voice button', (
      tester,
    ) async {
      Widget build({required bool voice}) => _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onAttach: (_) {},
          dictation: dictation(),
          onSend: (_, _) {},
          sendEnabled: false,
          voiceModeAction: voice
              ? null
              : const SizedBox(key: ValueKey('voice-mode-launch')),
          voiceControls: voice ? controls() : null,
        ),
      );
      await tester.pumpWidget(build(voice: true));

      expect(find.byKey(controlsKey), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-mode-launch')), findsNothing);
      // The conversation holds the microphone: dictation steps aside.
      expect(find.byKey(const ValueKey('mic')), findsNothing);
      expect(find.byType(ConsoleSendButton), findsNothing);
      // Still a composer: the field and the attach button are where they were.
      expect(find.byKey(const ValueKey('composer-add')), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'sigo escribiendo');
      expect(controller.text, 'sigo escribiendo');
      // The controls end the row, where the start button stands.
      final row = tester.getRect(
        find.byKey(const ValueKey('composer-input-row')),
      );
      expect(tester.getRect(find.byKey(controlsKey)).right, row.right);

      // Leaving the conversation puts the usual trailing end back.
      await tester.pumpWidget(build(voice: false));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(controlsKey), findsNothing);
      expect(find.byKey(const ValueKey('voice-mode-launch')), findsOneWidget);
      expect(find.byKey(const ValueKey('mic')), findsOneWidget);
      expect(controller.text, 'sigo escribiendo');
    });

    testWidgets('send stays beside them when there is something to send', (
      tester,
    ) async {
      final idle = <double>[];
      final composing = <double>[];
      String? sent;
      var queued = 0;
      Widget build({required bool composingNow}) => _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onAttach: (_) {},
          dictation: dictation(),
          onSend: (text, _) => sent = text,
          onQueue: () => queued++,
          sendEnabled: composingNow,
          voiceControls: controls(
            takesPrimarySlot: !composingNow,
            widths: composingNow ? composing : idle,
          ),
        ),
      );
      await tester.pumpWidget(build(composingNow: false));
      expect(find.byKey(const ValueKey('send')), findsNothing);

      await tester.enterText(find.byType(TextField), 'un mensaje');
      await tester.pumpWidget(build(composingNow: true));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(controlsKey), findsOneWidget);
      expect(find.byKey(const ValueKey('send')), findsOneWidget);
      // Send keeps its usual place at the end of the row.
      expect(
        tester.getRect(find.byType(ConsoleSendButton)).left,
        greaterThanOrEqualTo(tester.getRect(find.byKey(controlsKey)).right),
      );
      // Writing needs the field: the controls are asked to take less.
      expect(composing.last, lessThan(idle.last));

      await tester.tap(find.byType(ConsoleSendButton));
      expect(sent, 'un mensaje');
      await tester.longPress(find.byType(ConsoleSendButton));
      expect(queued, 1);
    });

    testWidgets('on a phone they move above the field while writing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final widths = <double>[];
      Widget build({required bool composingNow}) => _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onAttach: (_) {},
          onSend: (_, _) {},
          sendEnabled: composingNow,
          voiceControls: controls(
            takesPrimarySlot: !composingNow,
            widths: widths,
          ),
        ),
      );
      await tester.pumpWidget(build(composingNow: false));
      final row = find.byKey(const ValueKey('composer-input-row'));
      final ownRow = find.byKey(const ValueKey('composer-voice-row'));
      final restingRow = tester.getSize(row).width;
      expect(ownRow, findsNothing);
      expect(
        tester.getRect(find.byKey(controlsKey)).right,
        tester.getRect(row).right,
      );

      await tester.enterText(find.byType(TextField), 'un mensaje largo');
      await tester.pumpWidget(build(composingNow: true));
      await tester.pump(const Duration(milliseconds: 300));

      // Their own row, above the field and against the trailing edge; the
      // field gets the whole row back and send its usual place.
      expect(ownRow, findsOneWidget);
      final controlsRect = tester.getRect(find.byKey(controlsKey));
      expect(controlsRect.bottom, lessThanOrEqualTo(tester.getRect(row).top));
      expect(controlsRect.right, tester.getRect(row).right);
      // Offered the row as the resting composer has it.
      expect(widths.last, restingRow);
      expect(
        restingRow,
        390 -
            2 * kConsoleComposerSideInset -
            2 * kConsoleComposerSurfaceInset -
            2,
      );
      // Attach, the field and send share the input row, as without voice.
      expect(
        tester.getSize(find.byType(TextField)).width,
        tester.getSize(row).width - 48 - 2 - 48,
      );
      expect(find.byKey(const ValueKey('send')), findsOneWidget);
      expect(controller.text, 'un mensaje largo');
      expect(tester.takeException(), isNull);
    });

    testWidgets('stop stays beside them when the host still offers it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var stopped = 0;
      await tester.pumpWidget(
        _host(
          ConsoleComposer(
            controller: controller,
            focusNode: focusNode,
            onAttach: (_) {},
            onSend: (_, _) {},
            showStop: true,
            onStop: () => stopped++,
            voiceControls: controls(takesPrimarySlot: false),
          ),
        ),
      );

      expect(find.byKey(controlsKey), findsOneWidget);
      expect(find.byKey(const ValueKey('stop')), findsOneWidget);
      // Nothing is being written: on a phone too they share the row.
      expect(find.byKey(const ValueKey('composer-voice-row')), findsNothing);
      await tester.tap(find.byType(ConsoleSendButton));
      expect(stopped, 1);
    });

    testWidgets('focusing the field does not reshape them', (tester) async {
      final widths = <double>[];
      await tester.pumpWidget(
        _host(
          ConsoleComposer(
            controller: controller,
            focusNode: focusNode,
            onAttach: (_) {},
            onSend: (_, _) {},
            voiceControls: controls(widths: widths),
          ),
        ),
      );
      final resting = widths.last;
      final field = tester.widget<TextField>(find.byType(TextField));
      // The narrow field keeps its hint on one line.
      expect(field.decoration!.hintMaxLines, 1);

      await tester.tap(find.byType(TextField));
      await tester.pump(const Duration(milliseconds: 300));
      expect(focusNode.hasFocus, isTrue);
      expect(widths.last, resting);
    });

    testWidgets('a locked composer keeps the conversation controls live', (
      tester,
    ) async {
      var taps = 0;
      var footerTaps = 0;
      var sent = 0;
      controller.text = 'borrador';
      await tester.pumpWidget(
        _host(
          ConsoleComposer(
            controller: controller,
            focusNode: focusNode,
            onAttach: (_) {},
            onSend: (_, _) => sent++,
            sendEnabled: true,
            locked: true,
            footer: GestureDetector(
              key: const ValueKey('mode-pill'),
              behavior: HitTestBehavior.opaque,
              onTap: () => footerTaps++,
              child: const SizedBox(width: 80, height: 30),
            ),
            voiceControls: controls(
              takesPrimarySlot: false,
              onTap: () => taps++,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(controlsKey));
      expect(taps, 1);

      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
        tester
            .widget<AttachmentSourceMenuButton>(
              find.byType(AttachmentSourceMenuButton),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.byType(ConsoleSendButton), warnIfMissed: false);
      await tester.tap(
        find.byKey(const ValueKey('mode-pill')),
        warnIfMissed: false,
      );
      expect(sent, 0);
      expect(footerTaps, 0);
      expect(controller.text, 'borrador');
    });

    testWidgets('a room never shows them', (tester) async {
      await tester.pumpWidget(
        _host(
          ConsoleComposer(
            controller: controller,
            focusNode: focusNode,
            onSend: (_, _) {},
            dictation: dictation(),
            showBotModeToggle: false,
            voiceControls: controls(),
          ),
        ),
      );

      expect(find.byKey(controlsKey), findsNothing);
      expect(find.byKey(const ValueKey('mic')), findsOneWidget);
      expect(find.byKey(const ValueKey('send')), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.hintMaxLines, isNull);
    });

    for (final composing in [false, true]) {
      testWidgets('fits a 320dp phone at 2x text, '
          '${composing ? 'while writing' : 'with nothing to send'}', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        if (composing) controller.text = 'un mensaje que ocupa varias líneas';
        await tester.pumpWidget(
          _host(
            ConsoleComposer(
              controller: controller,
              focusNode: focusNode,
              onAttach: (_) {},
              dictation: dictation(),
              onSend: (_, _) {},
              sendEnabled: composing,
              voiceControls: ConsoleComposerVoiceControls(
                takesPrimarySlot: !composing,
                minWidth: VoiceComposerControls.minWidth,
                builder: (context, maxWidth, comfortWidth) =>
                    VoiceComposerControls(
                      state: VoiceStripState.speaking,
                      maxWidth: maxWidth,
                      comfortWidth: comfortWidth,
                      labels: const VoiceStripLabels(
                        finishListening: 'Terminar de hablar',
                        pause: 'Pausar',
                        resume: 'Reanudar',
                        stopAndTalk: 'Parar y hablar',
                        cancel: 'Cancelar tarea',
                        stop: 'Detener',
                        retry: 'Reintentar',
                        review: 'Ver aprobación',
                        close: 'Terminar modo voz',
                        end: 'Terminar',
                      ),
                      onPause: () {},
                      onCancel: () {},
                      onClose: () {},
                    ),
              ),
            ),
          ),
        );
        expect(
          MediaQuery.textScalerOf(
            tester.element(find.byType(ConsoleComposer)),
          ).scale(10),
          20,
        );

        expect(tester.takeException(), isNull);
        for (final key in [
          'voice-strip-pause',
          'voice-strip-cancel',
          'voice-strip-close',
        ]) {
          final size = tester.getSize(find.byKey(ValueKey(key)));
          expect(size.width, greaterThanOrEqualTo(44), reason: key);
          expect(size.height, greaterThanOrEqualTo(44), reason: key);
        }
        expect(
          find.byType(ConsoleSendButton),
          composing ? findsOneWidget : findsNothing,
        );
        // Writing keeps a usable field: the controls move above it.
        expect(
          find.byKey(const ValueKey('composer-voice-row')),
          composing ? findsOneWidget : findsNothing,
        );
        expect(
          tester.getSize(find.byType(TextField)).width,
          greaterThanOrEqualTo(composing ? 160 : 60),
        );
      });
    }
  });
}
