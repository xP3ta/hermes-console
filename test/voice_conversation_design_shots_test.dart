// SPDX-License-Identifier: MIT
// Visual evidence of the in-chat voice conversation: the thin status line
// above the composer and the conversation controls at the composer's
// trailing end, in every state, at 390×844 dark with the app's real fonts.
//
// Without `DESIGN_SHOTS_DIR` (an environment variable, or a
// `--dart-define`) it is a layout test: nothing overflows and the pieces
// stay where the design puts them. With it, each state is written as a PNG.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_notch.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/core/widgets/voice_strip.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart';

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

/// One state of the conversation as the chat screen projects it.
class _Shot {
  const _Shot(
    this.name,
    this.state,
    this.status, {
    this.heard = '',
    this.level,
    this.pushToFinish = false,
    this.turnRunning = false,
    this.elapsed = Duration.zero,
    this.draft = '',
  });

  final String name;
  final VoiceStripState state;
  final String status;
  final String heard;
  final double? level;
  final bool pushToFinish;
  final bool turnRunning;
  final Duration elapsed;

  /// Text already written in the composer.
  final String draft;
}

const _shots = [
  _Shot(
    'voice_v2_1_listening',
    VoiceStripState.listening,
    'Escuchando…',
    heard: '¿Y cuánto disco queda libre?',
    level: 0.8,
    pushToFinish: true,
    elapsed: Duration(seconds: 14),
  ),
  _Shot(
    'voice_v2_1b_listening_no_partial',
    VoiceStripState.listening,
    'Escuchando…',
    level: 0.35,
    elapsed: Duration(seconds: 3),
  ),
  _Shot(
    'voice_v2_2_working',
    VoiceStripState.toolCall,
    'Ejecutando…',
    turnRunning: true,
    elapsed: Duration(seconds: 7),
  ),
  _Shot(
    'voice_v2_3_speaking',
    VoiceStripState.speaking,
    'Hablando…',
    elapsed: Duration(seconds: 5),
  ),
  _Shot('voice_v2_4_paused', VoiceStripState.paused, 'En pausa'),
  _Shot(
    'voice_v2_4b_paused_turn_running',
    VoiceStripState.paused,
    'En pausa',
    turnRunning: true,
  ),
  _Shot('voice_v2_5_error', VoiceStripState.error, 'La voz no responde'),
  _Shot(
    'voice_v2_5b_error_long',
    VoiceStripState.error,
    'La voz del servidor Hermes no está disponible ahora. Revisa la voz del '
        'servidor en Ajustes.',
  ),
  _Shot(
    'voice_v2_6_waiting_approval',
    VoiceStripState.waiting,
    'Esperando tu aprobación',
    turnRunning: true,
  ),
  _Shot(
    'voice_v2_7_writing',
    VoiceStripState.thinking,
    'Pensando…',
    turnRunning: true,
    elapsed: Duration(seconds: 2),
    draft: 'Y de paso dime cuánta memoria queda',
  ),
];

/// The bottom of a chat during a voice conversation, with the real composer,
/// status line, controls, notch and status pill; the transcript is a still.
class _Scene extends StatefulWidget {
  const _Scene(this.shot);

  final _Shot shot;

  @override
  State<_Scene> createState() => _SceneState();
}

class _SceneState extends State<_Scene> {
  late final _controller = TextEditingController(text: widget.shot.draft);
  final _focus = FocusNode();
  final _metrics = ValueNotifier(const SessionContextMetrics(percent: 3));
  late final _level = ValueNotifier(widget.shot.level ?? 0);

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _metrics.dispose();
    _level.dispose();
    super.dispose();
  }

  Widget _transcript(HermesThemeColors colors) => Padding(
    padding: const EdgeInsets.fromLTRB(26, 0, 26, 12 + kChatNotchHeight),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'Busca cómo era el onboarding nuevo',
              style: TextStyle(color: colors.textPrimary, fontSize: 15),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Text(
          'Hermes',
          style: TextStyle(
            color: colors.accent,
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'El onboarding nuevo tiene tres pasos: conectar el '
          'servidor, elegir un perfil y probar la voz.',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 15,
            height: 1.5,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final shot = widget.shot;
    final state = shot.state;
    final listening = state == VoiceStripState.listening;
    final composing = shot.draft.isNotEmpty;
    // As the chat screen decides it: the round button carries the composer's
    // Stop while the conversation has no turn of its own to cancel.
    final carriesStop =
        shot.turnRunning &&
        !state.canCancelTurn &&
        !composing &&
        !(listening && shot.pushToFinish);
    return Scaffold(
      backgroundColor: colors.background,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _transcript(colors)),
                // As in the chat: the notch rides on the bottom group's top
                // edge, over the space the transcript reserves for it.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: kChatNotchSlotHeight,
                  child: Center(
                    child: ChatNotch(
                      open: false,
                      semanticLabel: 'Ajustes del chat',
                      onOpen: () {},
                    ),
                  ),
                ),
              ],
            ),
          ),
          ConsoleComposerBand(
            focusNode: _focus,
            top: 2,
            bottom: 3,
            child: KeyedSubtree(
              key: const ValueKey('voice-conversation-surface'),
              child: VoiceStatusLine(
                state: state,
                statusLabel: shot.status,
                heard: () => shot.heard,
                labels: _labels,
                onResume: state == VoiceStripState.paused ? () {} : null,
                onStopAndTalk: () {},
                onRetry: state == VoiceStripState.error ? () {} : null,
                onReview: state == VoiceStripState.waiting ? () {} : null,
              ),
            ),
          ),
          ConsoleComposer(
            controller: _controller,
            focusNode: _focus,
            onAttach: (_) {},
            onSend: (_, _) {},
            sendEnabled: composing,
            hintText: 'Escribe…',
            topPadding: 0,
            voiceControls: ConsoleComposerVoiceControls(
              takesPrimarySlot: !composing,
              minWidth: VoiceComposerControls.minWidth,
              builder: (context, maxWidth, comfortWidth) =>
                  VoiceComposerControls(
                    state: state,
                    labels: _labels,
                    maxWidth: maxWidth,
                    comfortWidth: comfortWidth,
                    micLevel: listening ? _level : null,
                    onFinishListening: listening && shot.pushToFinish
                        ? () {}
                        : null,
                    onPause: state == VoiceStripState.waiting ? null : () {},
                    onCancel: shot.turnRunning ? () {} : null,
                    onStop: carriesStop ? () {} : null,
                    onClose: () {},
                  ),
            ),
            footer: Center(
              child: ChatStatusPill(
                metrics: _metrics,
                onOpenContext: () {},
                modelLabel: 'Sonnet 5.5',
                onOpenModel: () {},
                permissionsLabel: 'YOLO',
                permissionsFlag: 'YOLO',
                permissionsColor: colors.error,
                onOpenPermissions: () {},
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Shot shot, {
  Size size = const Size(390, 844),
}) async {
  await loadDesignFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: designShotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        // The theme the approved mockup is drawn in.
        theme: AppTheme.fromId('classic-dark'),
        home: _Scene(shot),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  if (shot.elapsed > Duration.zero) await tester.pump(shot.elapsed);
}

Future<void> _save(WidgetTester tester, String name) async {
  const defined = String.fromEnvironment('DESIGN_SHOTS_DIR');
  final dir = defined.isNotEmpty
      ? defined
      : Platform.environment['DESIGN_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  final boundary =
      tester.renderObject(find.byKey(designShotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Finder _key(String key) => find.byKey(ValueKey(key));

void main() {
  for (final shot in _shots) {
    testWidgets('${shot.name} fits 390x844 (PNG with DESIGN_SHOTS_DIR)', (
      tester,
    ) async {
      await _pump(tester, shot);
      expect(tester.takeException(), isNull);

      final line = tester.getRect(_key('voice-strip'));
      final surface = tester.getRect(_key('hermes-composer-visible-surface'));
      // The line sits on the composer, at its width.
      expect(line.left, surface.left);
      expect(line.right, surface.right);
      expect(surface.top - line.bottom, closeTo(7, 0.01));
      if (shot.state != VoiceStripState.error) expect(line.height, 40);
      // The way out is always there, with its bars and its name on a phone
      // this wide.
      expect(find.text('Terminar'), findsOneWidget);
      expect(_key('voice-strip-end-level'), findsOneWidget);
      expect(tester.getSize(_key('voice-strip-close')).height, 48);
      // Writing moves the controls above the field; otherwise one row.
      expect(
        _key('composer-voice-row'),
        shot.draft.isEmpty ? findsNothing : findsOneWidget,
      );
      expect(
        tester.getSize(find.byType(TextField)).width,
        greaterThanOrEqualTo(shot.draft.isEmpty ? 72 : 200),
      );

      await _save(tester, shot.name);
    });
  }

  testWidgets('listening fits a 360dp phone (PNG with DESIGN_SHOTS_DIR)', (
    tester,
  ) async {
    await _pump(tester, _shots.first, size: const Size(360, 780));
    expect(tester.takeException(), isNull);
    expect(find.text('Terminar'), findsOneWidget);
    expect(
      tester.getSize(find.byType(TextField)).width,
      greaterThanOrEqualTo(72),
    );
    await _save(tester, 'voice_v2_8_listening_360');
  });
}
