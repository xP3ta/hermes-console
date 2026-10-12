// SPDX-License-Identifier: MIT
// The in-chat voice conversation, as Desktop draws it: one thin status line
// above the composer with at most one action that belongs to the state, and
// the conversation controls at the composer's trailing end.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/voice_meter.dart';
import 'package:hermes_android/core/widgets/voice_strip.dart';

const _labels = VoiceStripLabels(
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
);

Widget _host(
  Widget child, {
  double width = 480,
  double textScale = 1,
  bool reducedMotion = false,
}) {
  return MaterialApp(
    theme: AppTheme.fromId('dark'),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: reducedMotion,
      ),
      child: child!,
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
}

Widget _line(
  VoiceStripState state, {
  String? statusLabel,
  double width = 480,
  double textScale = 1,
  ValueGetter<String>? heard,
  VoidCallback? onResume,
  VoidCallback? onStopAndTalk,
  VoidCallback? onRetry,
  VoidCallback? onReview,
}) {
  return _host(
    VoiceStatusLine(
      state: state,
      statusLabel: statusLabel ?? state.name,
      labels: _labels,
      heard: heard,
      onResume: onResume,
      onStopAndTalk: onStopAndTalk,
      onRetry: onRetry,
      onReview: onReview,
    ),
    width: width,
    textScale: textScale,
  );
}

Widget _controls(
  VoiceStripState state, {
  double width = 480,
  double maxWidth = 300,
  double? comfortWidth,
  double textScale = 1,
  bool reducedMotion = false,
  ValueNotifier<double>? micLevel,
  VoidCallback? onPause,
  VoidCallback? onFinishListening,
  VoidCallback? onCancel,
  VoidCallback? onStop,
  VoidCallback? onClose,
}) {
  return _host(
    reducedMotion: reducedMotion,
    Align(
      alignment: Alignment.centerRight,
      child: VoiceComposerControls(
        state: state,
        labels: _labels,
        maxWidth: maxWidth,
        comfortWidth: comfortWidth,
        micLevel: micLevel,
        onPause: onPause,
        onFinishListening: onFinishListening,
        onCancel: onCancel,
        onStop: onStop,
        onClose: onClose ?? () {},
      ),
    ),
    width: width,
    textScale: textScale,
  );
}

Finder _key(String key) => find.byKey(ValueKey(key));

const _lineActions = [
  'voice-strip-retry',
  'voice-strip-review',
  'voice-strip-resume',
  'voice-strip-stop-and-talk',
];

const _composerControls = [
  'voice-strip-pause',
  'voice-strip-finish-listening',
  'voice-strip-cancel',
  'voice-strip-stop',
  'voice-strip-close',
];

void main() {
  group('status line', () {
    testWidgets('is one line announced as a live region', (tester) async {
      await tester.pumpWidget(
        _line(VoiceStripState.listening, statusLabel: 'Escuchando…'),
      );

      expect(find.text('Escuchando…'), findsOneWidget);
      final node = tester.getSemantics(find.bySemanticsLabel('Escuchando…'));
      expect(node.flagsCollection.isLiveRegion, isTrue);
      // Listening carries no action, and the conversation controls are the
      // composer's.
      for (final key in [..._lineActions, ..._composerControls]) {
        expect(_key(key), findsNothing, reason: key);
      }
    });

    testWidgets('is thin, and its action still has a full touch target', (
      tester,
    ) async {
      await tester.pumpWidget(
        _line(VoiceStripState.speaking, onStopAndTalk: () {}),
      );

      expect(tester.getSize(_key('voice-strip')).height, 40);
      final action = tester.getSize(_key('voice-strip-stop-and-talk'));
      expect(action.width, greaterThanOrEqualTo(48));
      expect(action.height, greaterThanOrEqualTo(48));
    });

    testWidgets('shows what is being heard while it listens', (tester) async {
      var heard = '';
      await tester.pumpWidget(
        _line(
          VoiceStripState.listening,
          statusLabel: 'Escuchando…',
          heard: () => heard,
        ),
      );
      expect(find.text('Escuchando…'), findsOneWidget);

      // The engine publishes a partial without telling anyone: the line
      // picks it up on its own.
      heard = '¿Y cuánto\ndisco queda libre?';
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('¿Y cuánto disco queda libre?'), findsOneWidget);
      expect(find.text('Escuchando…'), findsNothing);
      // Assistive technology keeps hearing the state, not every partial.
      expect(find.bySemanticsLabel('Escuchando…'), findsOneWidget);

      heard = '';
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Escuchando…'), findsOneWidget);
    });

    testWidgets('a long utterance stays on one line', (tester) async {
      final long = List.filled(40, 'palabra').join(' ');
      await tester.pumpWidget(
        _line(VoiceStripState.listening, heard: () => long),
      );
      final thin = tester.getSize(_key('voice-strip'));

      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(long), findsOneWidget);
      expect(tester.getSize(_key('voice-strip')), thin);
      expect(tester.takeException(), isNull);
    });

    testWidgets('only reads what is heard while listening', (tester) async {
      var reads = 0;
      String heard() {
        reads++;
        return 'lo anterior';
      }

      await tester.pumpWidget(
        _line(
          VoiceStripState.thinking,
          statusLabel: 'Pensando…',
          heard: heard,
          onStopAndTalk: () {},
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Pensando…'), findsOneWidget);
      expect(find.text('lo anterior'), findsNothing);
      expect(reads, 0);
    });

    for (final state in [
      VoiceStripState.thinking,
      VoiceStripState.toolCall,
      VoiceStripState.speaking,
    ]) {
      testWidgets('${state.name}: its one action is stop and talk', (
        tester,
      ) async {
        var talked = 0;
        await tester.pumpWidget(
          _line(
            state,
            onStopAndTalk: () => talked++,
            onResume: () {},
            onRetry: () {},
            onReview: () {},
          ),
        );

        expect(find.text('Parar y hablar'), findsOneWidget);
        expect(find.bySemanticsLabel('Parar y hablar'), findsOneWidget);
        for (final key in _lineActions) {
          expect(
            _key(key),
            key == 'voice-strip-stop-and-talk' ? findsOneWidget : findsNothing,
            reason: key,
          );
        }

        await tester.tap(_key('voice-strip-stop-and-talk'));
        expect(talked, 1);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('transcribing and loading carry no action', (tester) async {
      for (final state in [
        VoiceStripState.transcribing,
        VoiceStripState.loading,
      ]) {
        await tester.pumpWidget(
          _line(
            state,
            onStopAndTalk: () {},
            onResume: () {},
            onRetry: () {},
            onReview: () {},
          ),
        );
        for (final key in _lineActions) {
          expect(_key(key), findsNothing, reason: '${state.name} $key');
        }
      }
    });

    testWidgets('paused offers resume and stops the clock', (tester) async {
      var resumed = 0;
      await tester.pumpWidget(
        _line(
          VoiceStripState.paused,
          statusLabel: 'En pausa',
          onResume: () => resumed++,
          onStopAndTalk: () {},
        ),
      );

      expect(find.text('Reanudar'), findsOneWidget);
      expect(_key('voice-strip-stop-and-talk'), findsNothing);
      expect(_key('voice-strip-clock'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(_key('voice-strip-clock'), findsNothing);

      await tester.tap(_key('voice-strip-resume'));
      expect(resumed, 1);
    });

    testWidgets('waiting for approval points at the card', (tester) async {
      var reviewed = 0;
      await tester.pumpWidget(
        _line(
          VoiceStripState.waiting,
          onReview: () => reviewed++,
          onResume: () {},
        ),
      );

      expect(find.text('Ver aprobación'), findsOneWidget);
      // One action at most: the card comes before resuming.
      expect(_key('voice-strip-resume'), findsNothing);
      expect(_key('voice-strip-clock'), findsNothing);
      await tester.tap(_key('voice-strip-review'));
      expect(reviewed, 1);
    });

    testWidgets('an error offers retry and stays readable in full', (
      tester,
    ) async {
      var retried = 0;
      const reason =
          'La voz del servidor Hermes no está disponible ahora. '
          'Revisa la voz del servidor en Ajustes.';
      await tester.pumpWidget(
        _line(
          VoiceStripState.error,
          statusLabel: reason,
          width: 360,
          onRetry: () => retried++,
        ),
      );

      // More than one line: a failure cut at "no está…" explains nothing.
      final line = tester.getSize(_key('voice-strip-status'));
      expect(line.height, greaterThan(30));
      // The reason gets the room: retry steps back to its glyph, still named
      // for assistive technology.
      expect(find.text('Reintentar'), findsNothing);
      expect(find.bySemanticsLabel('Reintentar'), findsOneWidget);
      final glyph = tester.getSize(_key('voice-strip-retry'));
      expect(line.width, 360 - 8 - 24 - 9 - glyph.width);
      expect(tester.takeException(), isNull);

      await tester.tap(_key('voice-strip-retry'));
      expect(retried, 1);

      // A reason that fits keeps the action's name on screen.
      await tester.pumpWidget(
        _line(
          VoiceStripState.error,
          statusLabel: 'La voz no responde',
          onRetry: () {},
        ),
      );
      expect(find.text('La voz no responde'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });

    testWidgets(
      'the action gives up its glyph, then its name, for the status',
      (tester) async {
        final action = _key('voice-strip-review');
        final glyph = find.descendant(
          of: action,
          matching: find.byIcon(Icons.shield_outlined),
        );
        Future<void> pump(double width) => tester.pumpWidget(
          _line(
            VoiceStripState.waiting,
            statusLabel: 'Esperando tu aprobación',
            width: width,
            onReview: () {},
          ),
        );
        double statusWidth() =>
            tester.getSize(_key('voice-strip-status')).width;

        await pump(620);
        expect(find.text('Ver aprobación'), findsOneWidget);
        expect(glyph, findsOneWidget);
        final named = statusWidth();

        // Tighter: the name alone, so the status is still read whole.
        await pump(580);
        expect(find.text('Ver aprobación'), findsOneWidget);
        expect(glyph, findsNothing);
        expect(statusWidth(), greaterThanOrEqualTo(named - 30));

        // A status that cannot fit anyway is cut; the action keeps its name,
        // which says what the state is about.
        await pump(450);
        expect(find.text('Ver aprobación'), findsOneWidget);
        expect(glyph, findsOneWidget);
        expect(statusWidth(), greaterThanOrEqualTo(72));

        // Only with no room to read anything does it step back to its glyph,
        // which keeps its name for assistive technology and its target.
        await pump(300);
        expect(find.text('Ver aprobación'), findsNothing);
        expect(glyph, findsOneWidget);
        expect(find.bySemanticsLabel('Ver aprobación'), findsOneWidget);
        expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
        expect(statusWidth(), greaterThanOrEqualTo(72));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('the clock times the current state and restarts with it', (
      tester,
    ) async {
      await tester.pumpWidget(_line(VoiceStripState.listening));
      expect(find.text('0:00'), findsOneWidget);

      await tester.pump(const Duration(seconds: 7));
      expect(find.text('0:07'), findsOneWidget);

      await tester.pump(const Duration(seconds: 60));
      expect(find.text('1:07'), findsOneWidget);

      await tester.pumpWidget(_line(VoiceStripState.thinking));
      expect(find.text('0:00'), findsOneWidget);

      // Leaving the tree stops the timers.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the line keeps the words and the clock: the meter is the '
        "pill's", (tester) async {
      for (final state in VoiceStripState.values) {
        await tester.pumpWidget(_line(state));
        expect(
          find.descendant(
            of: find.byType(VoiceStatusLine),
            matching: find.byType(VoiceMeter),
          ),
          findsNothing,
          reason: state.name,
        );
      }
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('fits a 320dp phone at ${scale}x text with a long status', (
        tester,
      ) async {
        await tester.pumpWidget(
          _line(
            VoiceStripState.speaking,
            // What the composer's surface leaves at 320 dp.
            width: 268,
            textScale: scale,
            statusLabel: List.filled(30, 'texto largo').join(' '),
            onStopAndTalk: () {},
          ),
        );

        expect(tester.takeException(), isNull);
        final action = tester.getSize(_key('voice-strip-stop-and-talk'));
        expect(action.width, greaterThanOrEqualTo(44));
        expect(action.height, greaterThanOrEqualTo(44));
        // The status keeps room to be read; the action keeps its name for
        // assistive technology even when it shrinks to its glyph.
        expect(
          tester.getSize(_key('voice-strip-status')).width,
          greaterThanOrEqualTo(72),
        );
        expect(find.bySemanticsLabel('Parar y hablar'), findsOneWidget);
      });
    }
  });

  group('composer controls', () {
    testWidgets('listening: pause and the end pill, nothing else', (
      tester,
    ) async {
      var paused = 0;
      var closed = 0;
      await tester.pumpWidget(
        _controls(
          VoiceStripState.listening,
          onPause: () => paused++,
          onCancel: () {},
          onClose: () => closed++,
        ),
      );

      expect(find.text('Terminar'), findsOneWidget);
      expect(_key('voice-strip-finish-listening'), findsNothing);
      expect(_key('voice-strip-cancel'), findsNothing);
      for (final key in _lineActions) {
        expect(_key(key), findsNothing, reason: key);
      }

      await tester.tap(_key('voice-strip-pause'));
      await tester.tap(_key('voice-strip-close'));
      expect(paused, 1);
      expect(closed, 1);
    });

    testWidgets('a push-to-finish engine adds the round finish button', (
      tester,
    ) async {
      var finished = 0;
      await tester.pumpWidget(
        _controls(
          VoiceStripState.listening,
          onFinishListening: () => finished++,
          onPause: () {},
        ),
      );

      // Glyphs, each named for assistive technology.
      expect(find.text('Terminar de hablar'), findsNothing);
      expect(find.bySemanticsLabel('Terminar de hablar'), findsOneWidget);
      expect(find.bySemanticsLabel('Pausar'), findsOneWidget);
      expect(find.bySemanticsLabel('Terminar modo voz'), findsOneWidget);

      await tester.tap(_key('voice-strip-finish-listening'));
      expect(finished, 1);
    });

    for (final state in [
      VoiceStripState.thinking,
      VoiceStripState.toolCall,
      VoiceStripState.speaking,
    ]) {
      testWidgets('${state.name}: pause, cancel and end stay separate', (
        tester,
      ) async {
        final calls = <String>[];
        await tester.pumpWidget(
          _controls(
            state,
            onFinishListening: () => calls.add('finish'),
            onPause: () => calls.add('pause'),
            onCancel: () => calls.add('cancel'),
            onClose: () => calls.add('close'),
          ),
        );

        expect(find.bySemanticsLabel('Cancelar tarea'), findsOneWidget);
        // One round button: finishing belongs to listening.
        expect(_key('voice-strip-finish-listening'), findsNothing);
        await tester.tap(_key('voice-strip-pause'));
        await tester.tap(_key('voice-strip-cancel'));
        await tester.tap(_key('voice-strip-close'));
        expect(calls, ['pause', 'cancel', 'close']);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('cancel is only offered while there is a turn to cancel', (
      tester,
    ) async {
      await tester.pumpWidget(
        _controls(VoiceStripState.thinking, onPause: () {}),
      );
      expect(_key('voice-strip-cancel'), findsNothing);

      await tester.pumpWidget(
        _controls(VoiceStripState.listening, onPause: () {}, onCancel: () {}),
      );
      expect(_key('voice-strip-cancel'), findsNothing);
    });

    testWidgets('the round button carries one stop at most', (tester) async {
      final calls = <String>[];
      Future<void> pump(
        VoiceStripState state, {
        bool finish = false,
        bool cancel = false,
      }) => tester.pumpWidget(
        _controls(
          state,
          onPause: () {},
          onFinishListening: finish ? () => calls.add('finish') : null,
          onCancel: cancel ? () => calls.add('cancel') : null,
          onStop: () => calls.add('stop'),
        ),
      );
      Finder round(String key) => _key('voice-strip-$key');

      // Paused while Hermes works: no turn of the conversation's own to
      // cancel, so the composer's Stop stands in the round button.
      await pump(VoiceStripState.paused);
      expect(find.bySemanticsLabel('Detener'), findsOneWidget);
      expect(round('cancel'), findsNothing);
      await tester.tap(round('stop'));
      expect(calls, ['stop']);

      // The conversation's own cancel comes first...
      await pump(VoiceStripState.thinking, cancel: true);
      expect(round('cancel'), findsOneWidget);
      expect(round('stop'), findsNothing);

      // ...and so does finishing what is being said.
      await pump(VoiceStripState.listening, finish: true);
      expect(round('finish-listening'), findsOneWidget);
      expect(round('stop'), findsNothing);
      expect(round('cancel'), findsNothing);
    });

    testWidgets('paused, waiting and error keep only the way out', (
      tester,
    ) async {
      for (final state in [
        VoiceStripState.paused,
        VoiceStripState.waiting,
        VoiceStripState.error,
        VoiceStripState.loading,
      ]) {
        var closed = 0;
        await tester.pumpWidget(
          _controls(
            state,
            onPause: () {},
            onFinishListening: () {},
            onCancel: () {},
            onClose: () => closed++,
          ),
        );

        // Paused: the status line offers Resume, so pause steps away.
        expect(_key('voice-strip-pause'), findsNothing, reason: state.name);
        expect(
          _key('voice-strip-finish-listening'),
          findsNothing,
          reason: state.name,
        );
        expect(_key('voice-strip-cancel'), findsNothing, reason: state.name);
        await tester.tap(_key('voice-strip-close'));
        expect(closed, 1, reason: state.name);
      }
    });

    testWidgets('every control keeps a 48 dp touch target', (tester) async {
      await tester.pumpWidget(
        _controls(
          VoiceStripState.speaking,
          onPause: () {},
          onCancel: () {},
          onClose: () {},
        ),
      );

      for (final key in [
        'voice-strip-pause',
        'voice-strip-cancel',
        'voice-strip-close',
      ]) {
        final size = tester.getSize(_key(key));
        expect(size.width, greaterThanOrEqualTo(48), reason: key);
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
      }
    });

    testWidgets('the end pill gives up its bars, then its word, for room', (
      tester,
    ) async {
      Future<void> pump(VoiceStripState state, double maxWidth) =>
          tester.pumpWidget(
            _controls(
              state,
              maxWidth: maxWidth,
              onPause: () {},
              onCancel: () {},
            ),
          );

      await pump(VoiceStripState.listening, 300);
      expect(find.text('Terminar'), findsOneWidget);
      expect(_key('voice-strip-end-level'), findsOneWidget);
      final full = tester.getSize(_key('voice-strip-close'));

      // The conversation moves between states with and without the round
      // button: the pill does not change shape with them.
      await pump(VoiceStripState.thinking, 300);
      expect(tester.getSize(_key('voice-strip-close')), full);

      await pump(VoiceStripState.listening, 240);
      expect(find.text('Terminar'), findsOneWidget);
      expect(_key('voice-strip-end-level'), findsNothing);

      await pump(VoiceStripState.listening, 150);
      expect(find.text('Terminar'), findsNothing);
      expect(_key('voice-strip-end-level'), findsOneWidget);
      // Still the way out, by name.
      expect(find.bySemanticsLabel('Terminar modo voz'), findsOneWidget);
      final glyph = tester.getSize(_key('voice-strip-close'));
      expect(glyph.width, greaterThanOrEqualTo(48));
      expect(glyph.height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the pill keeps its bars only while the field has its hint', (
      tester,
    ) async {
      // Room for the whole pill, but the composer's field would lose part of
      // its hint: the bars go, the word stays.
      await tester.pumpWidget(
        _controls(
          VoiceStripState.listening,
          maxWidth: 300,
          comfortWidth: 240,
          onPause: () {},
        ),
      );
      expect(find.text('Terminar'), findsOneWidget);
      expect(_key('voice-strip-end-level'), findsNothing);

      await tester.pumpWidget(
        _controls(
          VoiceStripState.listening,
          maxWidth: 300,
          comfortWidth: 300,
          onPause: () {},
        ),
      );
      expect(find.text('Terminar'), findsOneWidget);
      expect(_key('voice-strip-end-level'), findsOneWidget);
    });

    VoiceMeterState meter(WidgetTester tester) =>
        tester.state<VoiceMeterState>(_key('voice-strip-end-level'));

    /// Feeds [value] and lets the bars reach it.
    Future<void> hear(
      WidgetTester tester,
      ValueNotifier<double> level,
      double value,
    ) async {
      level.value = value;
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (!meter(tester).ticking) break;
      }
    }

    /// A quiet room, as a phone's recognition microphone reports it.
    Future<void> quietRoom(
      WidgetTester tester,
      ValueNotifier<double> level,
    ) async {
      for (var chunk = 0; chunk < 10; chunk++) {
        await hear(tester, level, 0.005 + chunk % 2 * 0.002);
      }
    }

    double tallest(WidgetTester tester) =>
        VoiceMeter.barHeight(2, meter(tester).shown);

    testWidgets('the pill meter follows the microphone, in a box that never '
        'moves, and rests when the voice does', (tester) async {
      final level = ValueNotifier<double>(0);
      addTearDown(level.dispose);
      await tester.pumpWidget(
        _controls(VoiceStripState.listening, micLevel: level, onPause: () {}),
      );
      final pill = tester.getSize(_key('voice-strip-close'));
      final box = tester.getSize(_key('voice-strip-end-level'));
      expect(box, const Size(VoiceMeter.width, VoiceMeter.height));

      await quietRoom(tester, level);
      // Five still dots, a third of the box, as in Desktop.
      expect(tallest(tester), closeTo(VoiceMeter.height * 0.3, 0.3));
      expect(meter(tester).ticking, isFalse);

      // Normal speech on a phone peaks around a tenth of full scale: drawn
      // to scale the bars would rise one pixel. They show it clearly, the
      // middle bar the tallest.
      await hear(tester, level, 0.1);
      expect(tallest(tester), greaterThan(10));
      final shown = meter(tester).shown;
      expect(
        VoiceMeter.barHeight(0, shown),
        lessThan(VoiceMeter.barHeight(1, shown)),
      );
      expect(
        VoiceMeter.barHeight(1, shown),
        lessThan(VoiceMeter.barHeight(2, shown)),
      );
      expect(VoiceMeter.barHeight(4, shown), VoiceMeter.barHeight(0, shown));

      await hear(tester, level, 0.18);
      expect(tallest(tester), closeTo(VoiceMeter.height, 0.001));
      final loud = meter(tester).shown;

      // On the way down it moves: a bar does not jump to a level.
      level.value = 0.006;
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(meter(tester).shown, lessThan(loud));
      expect(meter(tester).shown, greaterThan(0.2));
      expect(meter(tester).ticking, isTrue);

      // Back to quiet, back to dots, and nothing left running.
      await hear(tester, level, 0.006);
      expect(tallest(tester), closeTo(VoiceMeter.height * 0.3, 0.3));
      expect(meter(tester).ticking, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);

      // Out of range values never break it, and the pill never moved.
      await hear(tester, level, 9);
      await hear(tester, level, -3);
      await hear(tester, level, double.nan);
      expect(tester.getSize(_key('voice-strip-end-level')), box);
      expect(tester.getSize(_key('voice-strip-close')), pill);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a level tick repaints the meter alone: nothing is built', (
      tester,
    ) async {
      final level = ValueNotifier<double>(0);
      addTearDown(level.dispose);
      var controlsBuilds = 0;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              controlsBuilds++;
              return VoiceComposerControls(
                state: VoiceStripState.listening,
                labels: _labels,
                maxWidth: 300,
                micLevel: level,
                onPause: () {},
                onClose: () {},
              );
            },
          ),
        ),
      );
      expect(controlsBuilds, 1);
      expect(meter(tester).builds, 1);
      // It paints on a layer of its own.
      expect(
        find.descendant(
          of: _key('voice-strip-end-level'),
          matching: find.byType(RepaintBoundary),
        ),
        findsOneWidget,
      );

      await quietRoom(tester, level);
      await hear(tester, level, 0.12);
      await hear(tester, level, 0.2);
      await hear(tester, level, 0.006);

      expect(controlsBuilds, 1);
      expect(meter(tester).builds, 1);
    });

    testWidgets('while the voice is prepared the meter already hears', (
      tester,
    ) async {
      final level = ValueNotifier<double>(0);
      addTearDown(level.dispose);
      await tester.pumpWidget(
        _controls(VoiceStripState.loading, micLevel: level, onPause: () {}),
      );
      // Nothing captured yet: dots, and nothing running.
      expect(meter(tester).shown, 0);
      expect(meter(tester).ticking, isFalse);

      await quietRoom(tester, level);
      await hear(tester, level, 0.12);
      expect(tallest(tester), greaterThan(10));

      // Listening starts: the same meter goes on, it does not start over.
      await tester.pumpWidget(
        _controls(VoiceStripState.listening, micLevel: level, onPause: () {}),
      );
      expect(tallest(tester), greaterThan(10));
    });

    testWidgets('the dots are still whenever nobody is heard', (tester) async {
      final level = ValueNotifier<double>(0);
      addTearDown(level.dispose);
      for (final state in VoiceStripState.values) {
        if (state == VoiceStripState.listening ||
            state == VoiceStripState.loading ||
            state == VoiceStripState.speaking) {
          continue;
        }
        await tester.pumpWidget(
          _controls(state, micLevel: level, onPause: () {}),
        );
        await quietRoom(tester, level);
        await hear(tester, level, 0.5);
        expect(meter(tester).shown, 0, reason: state.name);
        expect(meter(tester).ticking, isFalse, reason: state.name);
      }

      // Listening with no level to read is still too.
      await tester.pumpWidget(
        _controls(VoiceStripState.listening, onPause: () {}),
      );
      expect(meter(tester).shown, 0);
      expect(meter(tester).ticking, isFalse);
    });

    testWidgets('while Hermes speaks it is a turning mark, not bars that '
        'pretend a level', (tester) async {
      final level = ValueNotifier<double>(0);
      addTearDown(level.dispose);
      await tester.pumpWidget(
        _controls(VoiceStripState.speaking, micLevel: level, onPause: () {}),
      );
      final box = tester.getSize(_key('voice-strip-end-level'));
      expect(meter(tester).ticking, isTrue);

      // Whatever the microphone picks up of the playback is not shown.
      level.value = 0.4;
      await tester.pump(const Duration(milliseconds: 100));
      level.value = 0.01;
      await tester.pump(const Duration(milliseconds: 100));
      expect(meter(tester).shown, 0);
      expect(meter(tester).builds, 1);
      expect(tester.getSize(_key('voice-strip-end-level')), box);

      // Paused: it stops with the voice.
      await tester.pumpWidget(
        _controls(VoiceStripState.paused, micLevel: level, onPause: () {}),
      );
      await tester.pump();
      expect(meter(tester).ticking, isFalse);
    });

    testWidgets('with reduced motion the dots never move', (tester) async {
      final level = ValueNotifier<double>(0);
      addTearDown(level.dispose);
      for (final state in [
        VoiceStripState.listening,
        VoiceStripState.loading,
        VoiceStripState.speaking,
      ]) {
        await tester.pumpWidget(
          _controls(
            state,
            reducedMotion: true,
            micLevel: level,
            onPause: () {},
          ),
        );
        await quietRoom(tester, level);
        await hear(tester, level, 0.2);
        expect(meter(tester).shown, 0, reason: state.name);
        expect(meter(tester).ticking, isFalse, reason: state.name);
      }
      // The pill is still the way out, by name.
      expect(find.bySemanticsLabel('Terminar modo voz'), findsOneWidget);

      // Motion back on: it follows again.
      await tester.pumpWidget(
        _controls(VoiceStripState.listening, micLevel: level, onPause: () {}),
      );
      await quietRoom(tester, level);
      await hear(tester, level, 0.15);
      expect(meter(tester).shown, greaterThan(0.5));
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('fits a 320dp phone at ${scale}x text with every control', (
        tester,
      ) async {
        await tester.pumpWidget(
          _controls(
            VoiceStripState.speaking,
            // What the composer leaves the controls at 320 dp.
            width: 152,
            maxWidth: 152,
            textScale: scale,
            onPause: () {},
            onCancel: () {},
            onClose: () {},
          ),
        );

        expect(tester.takeException(), isNull);
        for (final key in [
          'voice-strip-pause',
          'voice-strip-cancel',
          'voice-strip-close',
        ]) {
          final size = tester.getSize(_key(key));
          expect(size.width, greaterThanOrEqualTo(44), reason: key);
          expect(size.height, greaterThanOrEqualTo(44), reason: key);
        }
      });
    }
  });
}
