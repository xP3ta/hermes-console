import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/liquid_glass.dart';
import '../../models/agent_profile.dart' show kMainProfileFallbackName;
import '../../models/attachment_draft.dart';
import '../../utils/large_paste.dart';
import '../../utils/responsive.dart';
import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart' show HermesMotion, HermesType;
import '../attachment_card.dart';
import '../attachment_source_sheet.dart';
import '../hermes_premium_ui.dart';
import 'composer_clipboard_menu.dart';
import 'composer_pasted_image.dart';
import '../../feedback/haptics.dart';

/// Dictado del composer. El host conserva el motor de voz; aquí solo se pinta
/// el estado y se enrutan las acciones (mic, detener, cancelar, enviar).
class ConsoleComposerDictation {
  const ConsoleComposerDictation({
    required this.onStart,
    required this.onStop,
    required this.onCancel,
    required this.onSend,
    this.recording = false,
    this.transcribing = false,
    this.interactive = true,
    this.cancelEnabled = true,
    this.sendEnabled = false,
    this.level,
    this.partial = '',
  });

  final bool recording;
  final bool transcribing;

  /// Live text of the take while it is spoken (Hermes `stt.streaming`);
  /// empty shows only the wave. Desktop shows it in its dictation pill
  /// (`voice-activity.tsx:195-196`).
  final String partial;

  /// Muestra el micrófono cuando no se está grabando.
  final bool interactive;
  final bool cancelEnabled;
  final bool sendEnabled;

  /// Nivel del micrófono (0..1) para la onda; `null` no la pinta.
  final ValueListenable<double>? level;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onCancel;
  final VoidCallback onSend;
}

/// Envío genérico del composer: texto actual y adjuntos preparados.
typedef ConsoleComposerSend =
    void Function(String text, List<AttachmentDraft> attachments);

/// Controls of a running voice conversation, drawn at the composer's trailing
/// end. The host keeps the conversation; the composer only gives them room.
class ConsoleComposerVoiceControls {
  const ConsoleComposerVoiceControls({
    required this.builder,
    required this.minWidth,
    this.takesPrimarySlot = true,
  });

  /// Builds the controls for the width they may take, so the field keeps
  /// room to be typed in. Within `comfortWidth` (never more than `maxWidth`)
  /// the field also shows its hint whole: what the controls can do without
  /// stays inside it.
  final Widget Function(
    BuildContext context,
    double maxWidth,
    double comfortWidth,
  )
  builder;

  /// The least the controls need. With less room beside the field (a
  /// message being written on a phone) they move to a row of their own,
  /// above the field.
  final double minWidth;

  /// The controls stand where the start-voice button would be. `false` keeps
  /// the composer's own send/stop button, at its usual place.
  final bool takesPrimarySlot;
}

/// El composer único de Console (spec 070, T104): `+` para adjuntar, campo que
/// crece con el texto (1–4 líneas; 2 en horizontal con teclado), micrófono de
/// dictado y botón enviar/detener. Lo usan el chat principal y las salas.
///
/// Es un widget controlado: el host posee el [controller], el [focusNode], los
/// adjuntos y el estado de envío, y recibe [onSend]/[onAttach]/[onStop].
class ConsoleComposer extends StatelessWidget {
  const ConsoleComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    this.onAttach,
    this.onScanDocument,
    this.attachEnabled = true,
    this.attachments = const [],
    this.onRemoveAttachment,
    this.onRetryAttachment,
    this.dictation,
    this.onStop,
    this.showStop = false,
    this.sendEnabled = true,
    this.stopEnabled = true,
    this.busy = false,
    this.onQueue,
    this.sendLabel,
    this.voiceModeAction,
    this.voiceControls,
    this.voiceDock,
    this.voiceDockShown = false,
    this.voiceDockHint,
    this.locked = false,
    this.showBotModeToggle = true,
    this.footer,
    this.palette,
    this.hintText,
    this.fieldEnabled = true,
    this.fieldReadOnly = false,
    this.onKeyboardSubmit,
    this.onContentInserted,
    this.reduceMotion = false,
    this.inputFormatters,
    this.onOpenPastedText,
    this.topPadding = 4,
    this.material,
  });

  /// Air above the composer surface. A chat passes 0 so the notch tab,
  /// drawn just above the composer, sits ON the surface's top edge.
  final double topPadding;

  /// Optional shared edge finish; the composer keeps its opaque reading fill.
  /// Null preserves callers that have not opted into the chat material.
  final HermesLiquid? material;

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Enviar: recibe el texto actual y [attachments].
  final ConsoleComposerSend onSend;

  /// Fuente de adjunto elegida en el menú `+`; `null` oculta el `+`.
  final ValueChanged<AttachmentSourceChoice>? onAttach;

  /// Entrada "Escanear documento" del menú `+`; `null` la oculta.
  final VoidCallback? onScanDocument;
  final bool attachEnabled;

  /// Adjuntos preparados (tira de vistas previas sobre el campo).
  final List<AttachmentDraft> attachments;
  final ValueChanged<String>? onRemoveAttachment;
  final ValueChanged<String>? onRetryAttachment;

  /// Dictado; `null` oculta el micrófono.
  final ConsoleComposerDictation? dictation;

  /// Detener el turno en curso (visible con [showStop]).
  final VoidCallback? onStop;
  final bool showStop;
  final bool sendEnabled;
  final bool stopEnabled;

  /// Muestra la lanzadera de subida/envío en lugar de la flecha.
  final bool busy;

  /// Pulsación larga en enviar: poner en cola.
  final VoidCallback? onQueue;
  final String? sendLabel;

  /// Acción primaria alternativa (p. ej. modo voz del chat principal) que
  /// sustituye a enviar cuando no hay nada que enviar.
  final Widget? voiceModeAction;

  /// A voice conversation is running in this chat: its controls take the
  /// trailing end and the dictation microphone steps aside, since the
  /// conversation holds the microphone. Typing and sending are unchanged.
  final ConsoleComposerVoiceControls? voiceControls;

  /// Voz inline: the voice dock, laid over the input row in the composer
  /// field's own footprint and material while [voiceDockShown]. The input
  /// row stays mounted under it (the field keeps its text, focus and IME
  /// connection, and its height is the dock's), so the swap is a 250 ms
  /// cross-fade and nothing above the composer moves.
  final Widget? voiceDock;
  final bool voiceDockShown;

  /// One muted line under the dock («Di «stop» para salir…»). It is drawn
  /// in the composer's bottom margin and never adds height: it only shows
  /// where that margin has room for it and the text scale is under 1.3.
  final String? voiceDockHint;

  /// The dock's cross-fade with the input row.
  static const Duration voiceDockSwap = HermesMotion.voiceSwap;

  /// Disables the composer's own controls (attach, field, dictation, send or
  /// stop, footer) and leaves [voiceControls] live. For a host that locks the
  /// composer while a voice conversation still has to be paused or ended.
  final bool locked;

  /// Controles de modo del chat principal (pastilla de modo/contexto bajo el
  /// composer y lanzadera de modo voz). Las salas los ocultan con `false`.
  final bool showBotModeToggle;

  /// Contenido bajo el composer (la pastilla de modo del chat principal).
  final Widget? footer;

  /// Paleta flotante anclada sobre el composer (slash, @menciones).
  final Widget? palette;

  /// Placeholder; por defecto el del chat.
  final String? hintText;
  final bool fieldEnabled;
  final bool fieldReadOnly;

  /// Ctrl/Cmd+Enter. Por defecto envía.
  final VoidCallback? onKeyboardSubmit;

  /// Imágenes insertadas desde el teclado (GIF/sticker); `null` lo desactiva.
  final ValueChanged<KeyboardInsertedContent>? onContentInserted;
  final bool reduceMotion;

  /// Composer-level input rules (typed `@` references, large pastes).
  final List<TextInputFormatter>? inputFormatters;

  /// Tap on a collapsed large paste (by local id): expand it to edit.
  final ValueChanged<String>? onOpenPastedText;

  void _send() => onSend(controller.text, attachments);

  Widget _dictationAction(
    BuildContext context,
    HermesThemeColors colors,
    ConsoleComposerDictation dictation,
  ) {
    if (dictation.recording) {
      if (dictation.transcribing) {
        return Semantics(
          key: const ValueKey('recording'),
          liveRegion: true,
          label: Strings.of(context).chaVoiceTranscribingLabel,
          child: SizedBox.square(
            key: const ValueKey('dictation-transcribing'),
            dimension: 48,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceVariant.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: 36,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      return Semantics(
        key: const ValueKey('recording'),
        button: true,
        label: Strings.of(context).chaStopDictationTooltip,
        child: SizedBox.square(
          key: const ValueKey('dictation-stop'),
          dimension: 48,
          child: Center(
            child: HermesTactileAction(
              icon: Icons.stop_rounded,
              iconSize: 17,
              semanticLabel: Strings.of(context).chaStopDictationTooltip,
              onPressed: dictation.onStop,
              backgroundColor: colors.surfaceVariant.withValues(alpha: 0.9),
              foregroundColor: colors.textPrimary,
              size: 36,
            ),
          ),
        ),
      );
    }

    if (dictation.interactive && !locked) {
      return HermesTactileAction(
        key: const ValueKey('mic'),
        icon: Icons.mic_none_rounded,
        onPressed: dictation.onStart,
        semanticLabel: controller.text.trim().isEmpty
            ? Strings.of(context).chaVoiceDictationTooltip
            : Strings.of(context).chaContinueDictationTooltip,
        backgroundColor: Colors.transparent,
        foregroundColor: colors.textPrimary,
        size: 44,
        iconSize: 25,
        visual: HermesTactileActionVisual.quiet,
      );
    }

    return const SizedBox.shrink(key: ValueKey('no-mic'));
  }

  /// The recording area: the wave, and the live text over it dimmed so the
  /// level still shows without competing with the words.
  Widget _dictationArea(
    BuildContext context,
    HermesThemeColors colors,
    ValueListenable<double> level, {
    required bool transcribing,
    required String partial,
  }) {
    final dimmed = partial.isNotEmpty;
    return IgnorePointer(
      child: Stack(
        alignment: Alignment.center,
        children: [
          ConsoleDictationVisualizer(
            key: const ValueKey('dictation-visualizer'),
            level: level,
            color: dimmed
                ? colors.textSecondary.withValues(alpha: 0.28)
                : colors.textSecondary,
            mutedColor: dimmed
                ? colors.textDisabled.withValues(alpha: 0.28)
                : colors.textDisabled,
            transcribing: transcribing,
            listeningLabel: Strings.of(context).chaVoiceListeningLabel,
            transcribingLabel: Strings.of(context).chaVoiceTranscribingLabel,
          ),
          if (dimmed)
            Positioned.fill(
              child: ConsoleDictationPartial(
                key: const ValueKey('dictation-partial'),
                text: partial,
                color: colors.textPrimary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _dictationCancel(
    BuildContext context,
    HermesThemeColors colors,
    ConsoleComposerDictation dictation,
  ) {
    return SizedBox.square(
      key: const ValueKey('dictation-cancel'),
      dimension: 48,
      child: HermesTactileAction(
        icon: Icons.close_rounded,
        iconSize: 30,
        semanticLabel: Strings.of(context).chaCancel,
        onPressed: dictation.cancelEnabled ? dictation.onCancel : null,
        backgroundColor: Colors.transparent,
        foregroundColor: colors.textPrimary,
        size: 44,
        visual: HermesTactileActionVisual.quiet,
      ),
    );
  }

  Widget _dictationSend(
    BuildContext context,
    HermesThemeColors colors,
    ConsoleComposerDictation dictation,
  ) {
    final enabled = dictation.sendEnabled;
    return SizedBox.square(
      key: const ValueKey('dictation-send'),
      dimension: 48,
      child: Center(
        child: HermesTactileAction(
          icon: Icons.arrow_upward_rounded,
          iconSize: 23,
          semanticLabel: Strings.of(context).chaSendTooltip,
          onPressed: enabled ? dictation.onSend : null,
          // Like the main send (AUDITORIA-PULIDO §2.3): white on a light
          // grey read as nothing in the light theme.
          backgroundColor: enabled
              ? colors.accent
              : colors.surfaceVariant.withValues(alpha: 0.72),
          foregroundColor: enabled ? colors.onAccent : colors.textDisabled,
          enabled: enabled,
          size: 42,
        ),
      ),
    );
  }

  Widget _primaryAction() {
    final voice = showBotModeToggle ? voiceModeAction : null;
    return AnimatedSwitcher(
      key: const ValueKey('composer-primary-action-switcher'),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) => AnimatedBuilder(
        animation: animation,
        child: FadeTransition(opacity: animation, child: child),
        builder: (context, child) => Transform.scale(
          scale: animation.value,
          transformHitTests: false,
          child: IgnorePointer(
            ignoring: animation.status == AnimationStatus.reverse,
            child: child,
          ),
        ),
      ),
      child: voice != null
          ? KeyedSubtree(key: const ValueKey('voice'), child: voice)
          : KeyedSubtree(
              key: ValueKey(showStop ? 'stop' : 'send'),
              child: ConsoleSendButton(
                busy: busy,
                mode: showStop ? ConsoleSendMode.stop : ConsoleSendMode.send,
                enabled: !locked && (showStop ? stopEnabled : sendEnabled),
                onSend: _send,
                onQueue: locked ? null : onQueue,
                sendLabel: sendLabel,
                onStop: onStop ?? () {},
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final dictation = this.dictation;
    final recording = dictation?.recording ?? false;
    final transcribing = dictation?.transcribing ?? false;
    final level = dictation?.level;
    final livePartial = dictation?.partial.trim() ?? '';
    final footer = showBotModeToggle ? this.footer : null;
    final voiceControls = showBotModeToggle ? this.voiceControls : null;
    final voiceTakesPrimarySlot = voiceControls?.takesPrimarySlot ?? false;
    final voiceDock = showBotModeToggle ? this.voiceDock : null;
    final dockShown = voiceDock != null && voiceDockShown;
    final swap = reduceMotion ? Duration.zero : voiceDockSwap;
    // La lectura del teclado/orientación vive en un builder propio: así
    // solo este subárbol se reconstruye con cada frame de la animación del
    // teclado, en vez de suscribir al host (y con él el transcript) a
    // `MediaQuery.of`.
    return _KeyboardUpBuilder(
      builder: (imeContext, keyboardUp) {
        // En horizontal el IME ocupa más de media pantalla. El composer normal
        // (campo de hasta cuatro líneas + fila de acciones + SafeArea) puede
        // quedar más alto que el viewport restante y provocar un RenderFlex
        // overflow.
        final compactIme =
            keyboardUp &&
            MediaQuery.orientationOf(imeContext) == Orientation.landscape;
        var voiceMaxWidth = 0.0;
        var voiceComfortWidth = 0.0;
        var voiceOwnRow = false;
        if (voiceControls != null) {
          final rowWidth = _inputRowWidth(imeContext, compactIme: compactIme);
          double beside(double idleField) => _voiceInlineWidth(
            rowWidth,
            recording: recording,
            primaryVisible: !recording && !voiceTakesPrimarySlot,
            idleField: idleField,
          );
          voiceMaxWidth = beside(_voiceMinFieldWidth);
          voiceComfortWidth = beside(
            math.max(_voiceMinFieldWidth, _hintFieldWidth(imeContext)),
          );
          voiceOwnRow = voiceMaxWidth < voiceControls.minWidth;
          if (voiceOwnRow) voiceMaxWidth = voiceComfortWidth = rowWidth;
        }
        // A chat pane beside the workspace (an open Fold) left the field
        // narrower than its hint, which broke over four lines and grew the
        // composer («Pregunta / a / Hermes / …»). There it stays on one line.
        // A phone keeps its composer as it was.
        final narrowField =
            voiceControls == null &&
            _besideWorkspace(imeContext) &&
            _hintWouldWrap(
              imeContext,
              compactIme: compactIme,
              recording: recording,
              primaryVisible: !recording && !voiceTakesPrimarySlot,
            );
        return Container(
          key: const ValueKey('chat-composer-host'),
          padding: compactIme
              ? EdgeInsets.fromLTRB(12, math.min(2, topPadding), 12, 3)
              : EdgeInsets.fromLTRB(
                  kConsoleComposerSideInset,
                  topPadding,
                  kConsoleComposerSideInset,
                  10,
                ),
          // pm1215 (owner, QA 9494): no band behind the composer. Like under
          // the floating header, the transcript stays visible running under
          // and beside it; only the composer pill has a surface.
          child: SafeArea(
            // The composer sits at the bottom: the status bar is never its
            // concern. Since the floating header (fh1215) a chat has no app
            // bar, so the body's MediaQuery still carries the top inset and
            // a top SafeArea pushed the field down by the status bar,
            // leaving the notch floating above it (QA 9493).
            top: false,
            bottom: !compactIme,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConsoleComposerPaletteOverlay(
                  palette: palette,
                  child: ListenableBuilder(
                    // Focus styling listens to the node itself, so a focus
                    // flip never needs a host (screen) rebuild.
                    listenable: focusNode,
                    // The input row is always under the same Stack, so the
                    // dock coming or going never remounts the field.
                    child: Stack(
                      children: [
                        _ComposerSwap(
                          key: const ValueKey('composer-input-swap'),
                          shown: !dockShown,
                          duration: swap,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // the owner (Fold horizontal, APK 9708): with the
                              // keyboard up in landscape the tray of 60 dp thumbs
                              // grew the composer up to the header and no message
                              // was left. There the attachments are chips in the
                              // input row (ConsoleAttachmentChips).
                              if (attachments.isNotEmpty && !compactIme)
                                ConsoleAttachmentPreviewStrip(
                                  key: const ValueKey(
                                    'composer-attachment-preview',
                                  ),
                                  // QA 9493: the tray sits flush at the composer's
                                  // own start inset, in the column of the leading
                                  // `+` glyph (the text start without one), never
                                  // after the `+` with a gap its width.
                                  textStart: recording || onAttach != null
                                      ? _leadingGlyphInset
                                      : _fieldStartPadding,
                                  attachments: attachments,
                                  onRemove: locked ? null : onRemoveAttachment,
                                  onRetry: locked ? null : onRetryAttachment,
                                  onOpenPastedText: locked
                                      ? null
                                      : onOpenPastedText,
                                ),
                              if (voiceControls != null && voiceOwnRow)
                                Align(
                                  key: const ValueKey('composer-voice-row'),
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: voiceControls.builder(
                                    imeContext,
                                    voiceMaxWidth,
                                    voiceComfortWidth,
                                  ),
                                ),
                              Row(
                                key: const ValueKey('composer-input-row'),
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (!recording && onAttach != null)
                                    AttachmentSourceMenuButton(
                                      key: const ValueKey('composer-add'),
                                      semanticLabel: Strings.of(
                                        context,
                                      ).chaAttachTooltip,
                                      onSelected: onAttach!,
                                      onScanDocument: onScanDocument,
                                      enabled: attachEnabled && !locked,
                                    ),
                                  if (recording)
                                    _dictationCancel(
                                      context,
                                      colors,
                                      dictation!,
                                    ),
                                  if (attachments.isNotEmpty && compactIme)
                                    ConsoleAttachmentChips(
                                      key: const ValueKey(
                                        'composer-attachment-chips',
                                      ),
                                      attachments: attachments,
                                      onRemove: locked
                                          ? null
                                          : onRemoveAttachment,
                                    ),
                                  Expanded(
                                    child: SizedBox(
                                      height: recording
                                          ? kConsoleDictationComposerHeight
                                          : null,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          ExcludeSemantics(
                                            excluding: recording,
                                            child: CallbackShortcuts(
                                              bindings: {
                                                const SingleActivator(
                                                  LogicalKeyboardKey.enter,
                                                  control: true,
                                                ): onKeyboardSubmit ?? _send,
                                                const SingleActivator(
                                                  LogicalKeyboardKey.enter,
                                                  meta: true,
                                                ): onKeyboardSubmit ?? _send,
                                              },
                                              child: _buildField(
                                                context,
                                                colors,
                                                compactIme: compactIme,
                                                recording: recording,
                                                singleLineHint:
                                                    voiceControls != null ||
                                                    narrowField,
                                                shortHint: narrowField,
                                              ),
                                            ),
                                          ),
                                          if (recording && level != null)
                                            SizedBox(
                                              key: const ValueKey(
                                                'dictation-recording-area',
                                              ),
                                              height:
                                                  kConsoleDictationComposerHeight,
                                              child: _dictationArea(
                                                context,
                                                colors,
                                                level,
                                                transcribing: transcribing,
                                                partial: livePartial,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (dictation != null &&
                                      (voiceControls == null || recording))
                                    _dictationAction(
                                      context,
                                      colors,
                                      dictation,
                                    ),
                                  if (recording)
                                    _dictationSend(context, colors, dictation!),
                                  if (voiceControls != null && !voiceOwnRow)
                                    voiceControls.builder(
                                      imeContext,
                                      voiceMaxWidth,
                                      voiceComfortWidth,
                                    ),
                                  if (!recording && !voiceTakesPrimarySlot) ...[
                                    const SizedBox(width: 2),
                                    SizedBox.square(
                                      dimension: 48,
                                      child: Center(child: _primaryAction()),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (voiceDock != null)
                          Positioned.fill(
                            child: _ComposerSwap(
                              key: const ValueKey('voice-dock-swap'),
                              shown: dockShown,
                              duration: swap,
                              child: voiceDock,
                            ),
                          ),
                      ],
                    ),
                    builder: (context, child) {
                      final surface = HermesComposerSurface(
                        material: material,
                        focused: focusNode.hasFocus,
                        unfocusedHorizontalInset: kConsoleComposerSurfaceInset,
                        padding: compactIme
                            ? const EdgeInsets.symmetric(horizontal: 4)
                            : EdgeInsets.zero,
                        child: child!,
                      );
                      final hint =
                          voiceDock == null || compactIme || footer != null
                          ? null
                          : _voiceDockHintLine(imeContext, colors);
                      // Always the same Stack, so the hint coming or going
                      // never remounts the composer.
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          surface,
                          if (hint != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: -hint.height - _voiceDockHintGap,
                              height: hint.height,
                              child: IgnorePointer(
                                child: AnimatedOpacity(
                                  key: const ValueKey('voice-dock-hint'),
                                  opacity: dockShown ? 1 : 0,
                                  duration: swap,
                                  child: hint.line,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                if (footer != null)
                  IgnorePointer(
                    ignoring: locked,
                    child: ExcludeSemantics(excluding: locked, child: footer),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Space between the composer surface and the dock's hint line.
  static const double _voiceDockHintGap = 2;

  /// The dock's hint line, or null where it has no room: under the surface
  /// there are the composer's 10 dp of margin and the system's bottom inset,
  /// and a text scale of 1.3 or more never gets it.
  ({Widget line, double height})? _voiceDockHintLine(
    BuildContext context,
    HermesThemeColors colors,
  ) {
    final text = voiceDockHint;
    if (text == null || text.isEmpty) return null;
    final scaler = MediaQuery.textScalerOf(context);
    if (scaler.scale(1) >= 1.3) return null;
    final style = TextStyle(
      fontSize: HermesType.caption.fontSize,
      height: 1.25,
      color: colors.textSecondary,
    );
    final height = scaler.scale(style.fontSize! * style.height!).ceilToDouble();
    final room = 10 + MediaQuery.paddingOf(context).bottom;
    if (height + _voiceDockHintGap > room) return null;
    return (
      height: height,
      line: Text(
        text,
        key: const ValueKey('voice-dock-hint-text'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: style,
      ),
    );
  }

  /// Field width the voice controls always leave free beside them, and the
  /// width a message being written needs.
  static const double _voiceMinFieldWidth = 60;
  static const double _voiceComposingFieldWidth = 160;

  /// Width the field needs to show its hint whole on one line.
  double _hintFieldWidth(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.useMaterial3
        ? theme.textTheme.bodyLarge
        : theme.textTheme.titleMedium;
    final painter = TextPainter(
      text: TextSpan(
        text:
            hintText ??
            Strings.of(context).mpnComposerHint(kMainProfileFallbackName),
        style: (base ?? const TextStyle()).copyWith(
          fontSize: HermesType.text.fontSize,
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    // The field's own start and end padding, and a hair of slack.
    return width.ceilToDouble() + _fieldStartPadding + 4 + 2;
  }

  /// Width of the input row on the resting (unfocused) surface, inside its
  /// 1 dp border, so focusing the field never reshapes the voice controls.
  double _inputRowWidth(BuildContext context, {required bool compactIme}) =>
      MediaQuery.sizeOf(context).width -
      2 * (compactIme ? 12 + 4 : kConsoleComposerSideInset) -
      2 * kConsoleComposerSurfaceInset -
      2;

  /// Width the voice controls may take beside a field that keeps
  /// [idleField] with nothing being written.
  double _voiceInlineWidth(
    double rowWidth, {
    required bool recording,
    required bool primaryVisible,
    required double idleField,
  }) {
    var taken = 0.0;
    if (recording || onAttach != null) taken += _leadingExtent;
    if (recording) taken += 2 * 48;
    if (primaryVisible) taken += 2 + 48;
    // Stop stands beside an empty field; send or the busy mark beside a
    // message being written.
    final composing = recording || (primaryVisible && !showStop);
    final field = composing ? _voiceComposingFieldWidth : idleField;
    return math.max(0, rowWidth - taken - field);
  }

  /// This chat is a pane narrower than an expanded window: beside the
  /// workspace (the panes get their own size as the screen size).
  static bool _besideWorkspace(BuildContext context) {
    final view = View.of(context);
    final window = view.physicalSize.width / view.devicePixelRatio;
    return window >= Responsive.expandedBreakpoint &&
        MediaQuery.sizeOf(context).width < window - 0.5;
  }

  /// The field, between its controls, is narrower than its hint on one
  /// line (measured like the room the voice controls get).
  bool _hintWouldWrap(
    BuildContext context, {
    required bool compactIme,
    required bool recording,
    required bool primaryVisible,
  }) {
    var taken = 0.0;
    if (recording || onAttach != null) taken += _leadingExtent;
    if (dictation != null) taken += 48;
    if (primaryVisible) taken += 2 + 48;
    final field = _inputRowWidth(context, compactIme: compactIme) - taken;
    return field < _hintFieldWidth(context);
  }

  /// Width of the leading control (attach `+`, or cancel while dictating).
  static const double _leadingExtent = 48;

  /// Start of the leading control's 23 dp glyph inside its 48 dp slot.
  static const double _leadingGlyphInset = (_leadingExtent - 23) / 2;

  /// Start padding of the text inside the field.
  static const double _fieldStartPadding = 4;

  static Widget _defaultContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) => AdaptiveTextSelectionToolbar.editableText(
    editableTextState: editableTextState,
  );

  Widget _buildField(
    BuildContext context,
    HermesThemeColors colors, {
    required bool compactIme,
    required bool recording,
    bool singleLineHint = false,
    bool shortHint = false,
  }) {
    final onContentInserted = this.onContentInserted;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      // What is written keeps the hint's size: it jumped from 14 to M3's 16
      // at the first letter (AUDITORIA-PULIDO §2.3).
      style: TextStyle(
        fontSize: HermesType.text.fontSize,
        color: recording ? Colors.transparent : null,
      ),
      cursorColor: recording ? Colors.transparent : null,
      decoration: InputDecoration(
        // Beside the workspace the default hint is the short one (mock 134
        // «Pregunta…») instead of a cut «Pregunta a Herme…».
        hintText:
            hintText ??
            (shortHint
                ? Strings.of(context).chaHintUserShort
                : Strings.of(
                    context,
                  ).mpnComposerHint(kMainProfileFallbackName)),
        hintStyle: TextStyle(
          color: recording ? Colors.transparent : colors.textSecondary,
          fontSize: HermesType.text.fontSize,
        ),
        // A narrow field (beside the voice controls, or in a chat pane
        // beside the workspace) keeps its hint on one line instead of
        // growing the composer; past the field's width it ends in "…".
        hintMaxLines: singleLineHint ? 1 : null,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        contentPadding: EdgeInsets.fromLTRB(
          _fieldStartPadding,
          compactIme ? 10 : 12,
          4,
          recording ? kConsoleDictationWaveHeight + 8 : (compactIme ? 10 : 12),
        ),
        isDense: true,
      ),
      minLines: 1,
      maxLines: compactIme ? 2 : 4,
      textCapitalization: TextCapitalization.sentences,
      keyboardType: TextInputType.multiline,
      contentInsertionConfiguration: onContentInserted == null
          ? null
          : ContentInsertionConfiguration(
              allowedMimeTypes: kComposerInsertableImageMimeTypes,
              onContentInserted: onContentInserted,
            ),
      // Long-press "Paste image": Flutter's Paste reads text only, so an
      // image copied in another app comes through the native clipboard.
      contextMenuBuilder: onContentInserted == null
          ? _defaultContextMenu
          : (context, editableTextState) => ComposerClipboardMenu(
              editableTextState: editableTextState,
              onContentInserted: onContentInserted,
            ),
      textInputAction: TextInputAction.newline,
      inputFormatters: inputFormatters,
      readOnly: fieldReadOnly,
      enabled: fieldEnabled && !locked,
    );
  }
}

/// Ancla una paleta flotante (slash, @menciones) justo encima del composer sin
/// reemplazar el `TextField` que conserva el IME.
class ConsoleComposerPaletteOverlay extends StatefulWidget {
  final Widget child;
  final Widget? palette;

  const ConsoleComposerPaletteOverlay({
    super.key,
    required this.child,
    required this.palette,
  });

  @override
  State<ConsoleComposerPaletteOverlay> createState() =>
      _ConsoleComposerPaletteOverlayState();
}

class _ConsoleComposerPaletteOverlayState
    extends State<ConsoleComposerPaletteOverlay> {
  final _controller = OverlayPortalController();
  final _link = LayerLink();
  final _targetKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Mantener el portal montado evita un frame intermedio al abrir la paleta y,
    // sobre todo, no reemplaza el TextField que conserva el ownership del IME.
    _controller.show();
  }

  @override
  Widget build(BuildContext context) {
    final targetRenderObject = _targetKey.currentContext?.findRenderObject();
    final targetTop =
        targetRenderObject is RenderBox &&
            targetRenderObject.hasSize &&
            targetRenderObject.attached
        ? targetRenderObject.localToGlobal(Offset.zero).dy
        : MediaQuery.sizeOf(context).height;
    final paletteMaxHeight = math.max(0.0, targetTop - 8);
    return LayoutBuilder(
      builder: (context, constraints) => OverlayPortal(
        controller: _controller,
        overlayChildBuilder: (context) => Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topCenter,
            followerAnchor: Alignment.bottomCenter,
            child: SizedBox(
              width: constraints.maxWidth,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: paletteMaxHeight),
                child: widget.palette ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        child: CompositedTransformTarget(
          key: _targetKey,
          link: _link,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Whether the on-screen keyboard is up. A Scaffold that makes room for the
/// keyboard takes its inset out of its body's MediaQuery, and the composer
/// lives in that body: there the inset reads 0 with the keyboard up (gate
/// gint37: the chips never showed). The view's own inset says it. Only the
/// builder is rebuilt, and only when the keyboard comes or goes.
class _KeyboardUpBuilder extends StatefulWidget {
  const _KeyboardUpBuilder({required this.builder});

  final Widget Function(BuildContext context, bool keyboardUp) builder;

  @override
  State<_KeyboardUpBuilder> createState() => _KeyboardUpBuilderState();
}

class _KeyboardUpBuilderState extends State<_KeyboardUpBuilder>
    with WidgetsBindingObserver {
  ui.FlutterView? _view;
  bool _up = false;

  bool get _viewKeyboardUp => (_view?.viewInsets.bottom ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.maybeOf(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (mounted && _viewKeyboardUp != _up) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    _up = MediaQuery.viewInsetsOf(context).bottom > 0 || _viewKeyboardUp;
    return widget.builder(context, _up);
  }
}

/// The staged attachments as chips inside the input row, for the keyboard
/// up in landscape (the owner, Fold horizontal, APK 9708): a 28 dp thumb or file
/// glyph and the name, in a 40 dp pill with a 48 dp remove target. The
/// composer stays one row: chips, field, send. Scrolls sideways when there
/// are more than fit in [maxWidth].
class ConsoleAttachmentChips extends StatelessWidget {
  const ConsoleAttachmentChips({
    required this.attachments,
    required this.onRemove,
    super.key,
  });

  final List<AttachmentDraft> attachments;
  final ValueChanged<String>? onRemove;

  /// Widest the chips get beside the field.
  static const double maxWidth = 180;
  static const double height = 40;
  static const double target = 48;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final attachment in attachments) ...[
              _chip(context, colors, strings, attachment),
              const SizedBox(width: 4),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    HermesThemeColors colors,
    Strings strings,
    AttachmentDraft attachment,
  ) {
    final image =
        attachment.isImage &&
        attachment.localPath.isNotEmpty &&
        File(attachment.localPath).existsSync();
    final remove = attachment.localId.isEmpty || onRemove == null
        ? null
        : () => onRemove!(attachment.localId);
    final name = isPastedContentName(attachment.name)
        ? strings.t1215PastedContent
        : attachment.name;
    return SizedBox(
      key: ValueKey('composer-attachment-chip-${attachment.localId}'),
      height: target,
      child: Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [
          Semantics(
            label: name,
            child: Container(
              height: height,
              padding: EdgeInsetsDirectional.only(
                start: 6,
                end: remove == null ? 12 : target - 4,
              ),
              decoration: ShapeDecoration(
                color: colors.surfaceVariant,
                shape: StadiumBorder(side: BorderSide(color: colors.divider)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox.square(
                      dimension: 28,
                      child: image
                          ? Image.file(
                              File(attachment.localPath),
                              fit: BoxFit.cover,
                              cacheWidth: 84,
                            )
                          : ColoredBox(
                              color: colors.background,
                              child: Icon(
                                Icons.insert_drive_file_outlined,
                                size: 16,
                                color: colors.textSecondary,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 72),
                    child: ExcludeSemantics(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (remove != null)
            PositionedDirectional(
              end: 0,
              top: 0,
              bottom: 0,
              width: target,
              child: Semantics(
                button: true,
                label: strings.chaRemoveAttachment,
                excludeSemantics: true,
                child: Tooltip(
                  message: strings.chaRemoveAttachment,
                  child: GestureDetector(
                    key: ValueKey(
                      'composer-attachment-chip-remove-${attachment.localId}',
                    ),
                    behavior: HitTestBehavior.opaque,
                    onTap: remove,
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact strip shown above the input bar when a file is staged.
/// Shows a thumbnail for images or a document icon for other files.
/// Reflects the real per-item state; remove and retry never affect siblings.
class ConsoleAttachmentPreviewStrip extends StatelessWidget {
  final List<AttachmentDraft> attachments;
  final ValueChanged<String>? onRemove;
  final ValueChanged<String>? onRetry;
  final ValueChanged<String>? onOpenPastedText;

  /// Offset from the input's start edge where the first tile starts: the
  /// composer's content inset (the leading glyph's column).
  final double textStart;

  const ConsoleAttachmentPreviewStrip({
    required this.attachments,
    required this.onRemove,
    required this.onRetry,
    this.onOpenPastedText,
    this.textStart = 12,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // A horizontal scroll view shrink-wraps to its content, and the composer
    // column centres its children: one or two thumbs ended up floating in the
    // middle of the input. Take the full width and pin the row to the start
    // edge (RTL-aware) so attachments stack from the leading side.
    //
    // The scroll view spans the whole input, and the first tile starts at
    // [textStart], the composer's content inset. The top and end padding
    // leave room for the 48 dp remove/retry targets that overhang each tile,
    // so none is cut; the visible × sits inside the tile's corner.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsetsDirectional.fromSTEB(
          textStart,
          AttachmentCard.compactTargetTop,
          AttachmentCard.compactTargetSide,
          2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = 0; index < attachments.length; index++) ...[
              if (index > 0) const SizedBox(width: 8),
              Builder(
                builder: (context) {
                  final attachment = attachments[index];
                  final hasLocalImage =
                      attachment.isImage &&
                      attachment.localPath.isNotEmpty &&
                      File(attachment.localPath).existsSync();
                  final previewable =
                      hasLocalImage &&
                      (attachment.uploadState ==
                              AttachmentUploadState.pending ||
                          attachment.uploadState ==
                              AttachmentUploadState.error);
                  final changing =
                      attachment.uploadState == AttachmentUploadState.uploading;
                  final pasted =
                      !attachment.isImage &&
                      isPastedContentName(attachment.name);
                  final editablePaste =
                      pasted &&
                      onOpenPastedText != null &&
                      attachment.localId.isNotEmpty &&
                      attachment.uploadState == AttachmentUploadState.pending;
                  final displayName = pasted
                      ? Strings.of(context).t1215PastedContent
                      : attachment.name;
                  final openPreview = previewable
                      ? () =>
                            showImageViewer(context, File(attachment.localPath))
                      : editablePaste
                      ? () => onOpenPastedText!(attachment.localId)
                      : null;
                  return Semantics(
                    container: changing || previewable || editablePaste,
                    explicitChildNodes:
                        changing || previewable || editablePaste,
                    liveRegion:
                        changing ||
                        attachment.uploadState == AttachmentUploadState.error,
                    label: changing
                        ? Strings.of(
                            context,
                          ).chaAttachmentUploadInProgress(attachment.name)
                        : previewable || editablePaste
                        ? Strings.of(context).chaPreviewAttachment(displayName)
                        : null,
                    button: previewable || editablePaste,
                    onTap: openPreview,
                    child: AttachmentCard(
                      key: ValueKey('attachment-card-${attachment.localId}'),
                      compact: true,
                      name: displayName,
                      mimeType: attachment.mimeType,
                      sizeLabel: attachment.formattedSize,
                      thumbnailFile: hasLocalImage
                          ? File(attachment.localPath)
                          : null,
                      showUploadState: true,
                      uploadState: attachment.uploadState,
                      onTap: openPreview,
                      onRetry:
                          attachment.uploadState ==
                                  AttachmentUploadState.error &&
                              attachment.localId.isNotEmpty &&
                              onRetry != null
                          ? () => onRetry!(attachment.localId)
                          : null,
                      onRemove: attachment.localId.isEmpty || onRemove == null
                          ? null
                          : () => onRemove!(attachment.localId),
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Modo del botón primario del composer.
enum ConsoleSendMode { send, stop }

/// Botón primario del composer: enviar (pulsación larga = poner en cola) o
/// detener el turno en curso.
class ConsoleSendButton extends StatefulWidget {
  final ConsoleSendMode mode;

  /// A-017 (spec 028): con el campo vacío la flecha se pinta atenuada y no
  /// responde — antes lucía activa (ámbar + glow) pero el tap no hacía nada.
  final bool enabled;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback? onQueue;
  final String? sendLabel;
  final VoidCallback onStop;

  const ConsoleSendButton({
    super.key,
    required this.mode,
    required this.onSend,
    required this.onStop,
    this.onQueue,
    this.sendLabel,
    this.enabled = true,
    this.busy = false,
  });

  @override
  State<ConsoleSendButton> createState() => _ConsoleSendButtonState();
}

class _ConsoleSendButtonState extends State<ConsoleSendButton> {
  void _handleTap() {
    if (!widget.enabled) return;
    if (widget.mode == ConsoleSendMode.stop) {
      // Stopping a turn is a light press; sending commits.
      HermesHaptics.tap();
      widget.onStop();
    } else {
      HermesHaptics.confirm();
      widget.onSend();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final isStop = widget.mode == ConsoleSendMode.stop;
    final s = Strings.of(context);
    final tooltip = widget.busy
        ? s.chaUploadingAttachment
        : switch (widget.mode) {
            ConsoleSendMode.send => widget.sendLabel ?? s.chaSendTooltip,
            ConsoleSendMode.stop => s.chaStopTooltip,
          };
    final icon = switch (widget.mode) {
      ConsoleSendMode.send => Icons.arrow_upward,
      ConsoleSendMode.stop => Icons.stop_rounded,
    };
    // Q9-CHAT5 v2 (the owner, decision 5): stop is red, the theme's error tone,
    // with the ink that reads on it.
    final bg = !widget.enabled
        ? colors.surfaceVariant
        : isStop
        ? colors.error
        : colors.accent;
    final fg = !widget.enabled
        ? colors.textDisabled
        : isStop
        ? (ThemeData.estimateBrightnessForColor(colors.error) == Brightness.dark
              ? Colors.white
              : Colors.black)
        : colors.onAccent;
    if (widget.busy) {
      return Semantics(
        label: tooltip,
        liveRegion: true,
        child: SizedBox.square(
          dimension: 42,
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.textSecondary,
            ),
          ),
        ),
      );
    }

    final onQueue = widget.onQueue;
    return Semantics(
      onLongPressHint: !isStop && widget.enabled && onQueue != null
          ? s.biQueueThisMessageHint
          : null,
      child: HermesTactileAction(
        icon: icon,
        iconSize: isStop ? 21 : 19,
        semanticLabel: tooltip,
        onPressed: widget.enabled ? _handleTap : null,
        onLongPress: isStop || !widget.enabled || onQueue == null
            ? null
            : () {
                HermesHaptics.tap();
                onQueue();
              },
        backgroundColor: bg,
        foregroundColor: fg,
        enabled: widget.enabled,
        size: 42,
      ),
    );
  }
}

/// Side inset of the composer in a screen, and how much further its surface
/// draws in while the field is not focused. A band stacked on the composer
/// ([ConsoleComposerBand]) follows both.
const double kConsoleComposerSideInset = 14;
const double kConsoleComposerSurfaceInset = 12;

/// A band stacked on the composer that keeps the width of its surface, also
/// while the surface widens on focus.
class ConsoleComposerBand extends StatelessWidget {
  const ConsoleComposerBand({
    super.key,
    required this.focusNode,
    required this.child,
    this.top = 0,
    this.bottom = 0,
  });

  /// The composer's own focus node.
  final FocusNode focusNode;
  final double top;
  final double bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return ListenableBuilder(
      listenable: focusNode,
      child: child,
      builder: (context, child) => AnimatedPadding(
        // Same motion as [HermesComposerSurface].
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.fromLTRB(
          kConsoleComposerSideInset +
              (focusNode.hasFocus ? 0 : kConsoleComposerSurfaceInset),
          top,
          kConsoleComposerSideInset +
              (focusNode.hasFocus ? 0 : kConsoleComposerSurfaceInset),
          bottom,
        ),
        child: child,
      ),
    );
  }
}

/// The live text of a dictation in one line. When it does not fit, the
/// newest words stay in view and the start is clipped; large text never
/// overflows the row.
class ConsoleDictationPartial extends StatelessWidget {
  const ConsoleDictationPartial({
    required this.text,
    required this.color,
    super.key,
  });

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final style = textTheme.bodyMedium?.copyWith(color: color);
    // Its own node: without `container` the label folds into the area's
    // node beside the listening status, and a screen reader never reads the
    // words on their own.
    return Semantics(
      container: true,
      label: text,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          physics: const NeverScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              child: Text(text, maxLines: 1, softWrap: false, style: style),
            ),
          ),
        ),
      ),
    );
  }
}

/// Alto del campo mientras se dicta.
const double kConsoleDictationComposerHeight = 48;

/// Alto de la franja de la onda del dictado.
const double kConsoleDictationWaveHeight = 28;

/// Visualizador compacto del dictado. La onda ocupa una franja reservada bajo
/// los parciales visibles en el campo. No graba ni procesa audio; solo observa
/// [VoiceService.micLevel].
class ConsoleDictationVisualizer extends StatefulWidget {
  const ConsoleDictationVisualizer({
    required this.level,
    required this.color,
    required this.mutedColor,
    required this.transcribing,
    required this.listeningLabel,
    required this.transcribingLabel,
    super.key,
  });

  final ValueListenable<double> level;
  final Color color;
  final Color mutedColor;
  final bool transcribing;
  final String listeningLabel;
  final String transcribingLabel;

  @override
  State<ConsoleDictationVisualizer> createState() =>
      _ConsoleDictationVisualizerState();
}

class _ConsoleDictationVisualizerState extends State<ConsoleDictationVisualizer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _barCount = 36;
  static const _frameInterval = Duration(microseconds: 33334);

  /// About 1.5 s of history: the quietest recent level is the noise floor.
  static const _floorWindow = 45;

  /// Margin above the noise floor that still reads as silence.
  static const _noiseGate = 0.015;

  /// Level rise above the noise floor that fills the whole bar. It suits both
  /// the linear `RMS * 4` engines (sherpa, server) and the dB-normalised
  /// Whisper/clip engines, where the ambient already sits around 0.4-0.6.
  static const _fullScaleRise = 0.3;
  static const _attack = Duration(milliseconds: 45);
  static const _release = Duration(milliseconds: 110);

  final ValueNotifier<List<double>> _samples = ValueNotifier(
    List<double>.filled(_barCount, 0),
  );
  final _ConsoleDictationWaveMotion _motion = _ConsoleDictationWaveMotion();
  late final Ticker _ticker = createTicker(_onTick);
  final List<double> _floorHistory = <double>[];
  Duration _lastTick = Duration.zero;
  Duration _sincePush = Duration.zero;
  Timer? _sampleTimer;
  bool _tickerModeEnabled = true;
  bool _appActive = true;
  bool _reduceMotion = false;

  bool get _shouldSampleLevel =>
      !widget.transcribing && _tickerModeEnabled && _appActive;

  @visibleForTesting
  bool get debugClockActive => _sampleTimer?.isActive ?? false;

  @visibleForTesting
  bool get debugAnimating => _ticker.isActive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _floorHistory.add(widget.level.value.clamp(0.0, 1.0).toDouble());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncSampleClock();
  }

  @override
  void didUpdateWidget(ConsoleDictationVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transcribing != widget.transcribing) {
      _syncSampleClock();
    }
  }

  double get _rawLevel => widget.level.value.clamp(0.0, 1.0).toDouble();

  /// Maps the engine level to a bar height (0..1). Only the visual is
  /// amplified: the PCM and what the STT engine receives stay untouched.
  double _displayLevel(double raw) {
    final floor = _floorHistory.reduce(math.min);
    final rise = ((raw - floor - _noiseGate) / _fullScaleRise).clamp(0.0, 1.0);
    // A perceptual curve so normal speech, not only shouting, moves the bars.
    return math.pow(rise, 0.6).toDouble();
  }

  void _syncSampleClock() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    final animate = _shouldSampleLevel && !_reduceMotion;
    if (!animate && _ticker.isActive) _ticker.stop();
    if (!_shouldSampleLevel) return;
    if (animate && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
    if (!animate) _motion.update(live: 0, phase: 0, visible: false);
    _sampleTimer = Timer.periodic(_frameInterval, (_) {
      if (!_shouldSampleLevel) {
        _syncSampleClock();
        return;
      }
      final raw = _rawLevel;
      _floorHistory.add(raw);
      if (_floorHistory.length > _floorWindow) _floorHistory.removeAt(0);
      // Animated: the eased live bar becomes the newest history bar, so the
      // hand-off is seamless. Reduced motion: the level is shown as is.
      final sample = _reduceMotion ? _displayLevel(raw) : _motion.live;
      final history = _samples.value;
      _sincePush = Duration.zero;
      _samples.value = <double>[...history.skip(1), sample];
    });
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _lastTick;
    _lastTick = elapsed;
    _sincePush += dt;
    final target = _displayLevel(_rawLevel);
    final live = _motion.live;
    final tau = target > live ? _attack : _release;
    final blend =
        1 - math.exp(-dt.inMicroseconds / tau.inMicroseconds.toDouble());
    _motion.update(
      live: live + (target - live) * blend,
      phase: (_sincePush.inMicroseconds / _frameInterval.inMicroseconds).clamp(
        0.0,
        1.0,
      ),
      visible: true,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) return;
    _appActive = active;
    _syncSampleClock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sampleTimer?.cancel();
    _ticker.dispose();
    _samples.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.transcribing
        ? widget.transcribingLabel
        : widget.listeningLabel;
    return Semantics(
      key: const ValueKey('dictation-status-semantics'),
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: SizedBox(
          key: const ValueKey('dictation-wave-history'),
          width: double.infinity,
          height: kConsoleDictationWaveHeight,
          child: SizedBox(
            key: const ValueKey('dictation-bars'),
            child: RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey('dictation-bars-paint'),
                painter: _ConsoleDictationBarsPainter(
                  samples: _samples,
                  motion: _motion,
                  color: widget.color,
                  mutedColor: widget.mutedColor,
                  transcribing: widget.transcribing,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Per-frame state of the animated wave: the eased live bar and how far the
/// history has glided (0..1 of a slot) since the last history step.
class _ConsoleDictationWaveMotion extends ChangeNotifier {
  double live = 0;
  double phase = 0;
  bool visible = false;

  void update({
    required double live,
    required double phase,
    required bool visible,
  }) {
    if (this.live == live && this.phase == phase && this.visible == visible) {
      return;
    }
    this.live = live;
    this.phase = phase;
    this.visible = visible;
    notifyListeners();
  }
}

class _ConsoleDictationBarsPainter extends CustomPainter {
  _ConsoleDictationBarsPainter({
    required this.samples,
    required this.motion,
    required this.color,
    required this.mutedColor,
    required this.transcribing,
  }) : super(repaint: Listenable.merge([samples, motion]));

  final ValueListenable<List<double>> samples;
  final _ConsoleDictationWaveMotion motion;
  final Color color;
  final Color mutedColor;
  final bool transcribing;

  static const double _minBarHeight = 3.2;

  @override
  void paint(Canvas canvas, Size size) {
    final history = samples.value;
    if (history.isEmpty || size.isEmpty) return;
    final animated = motion.visible;
    // The animated wave keeps one extra slot on the right for the live bar.
    final slots = history.length + (animated ? 1 : 0);
    final slotWidth = size.width / slots;
    final barWidth = math.min(4.5, math.max(2.0, slotWidth * 0.58));
    final glide = animated ? motion.phase * slotWidth : 0.0;
    final paint = Paint();

    void drawBar(int slot, double level, double recency) {
      final value = level.clamp(0.0, 1.0).toDouble();
      final barHeight =
          _minBarHeight + value * (kConsoleDictationWaveHeight - _minBarHeight);
      final centerX = slotWidth * (slot + 0.5) - glide;
      // The oldest bar fades out as it glides past the left edge.
      final edgeFade = (centerX / slotWidth).clamp(0.0, 1.0).toDouble();
      if (edgeFade <= 0) return;
      paint.color = transcribing
          ? mutedColor.withValues(alpha: 0.32 * edgeFade)
          : color.withValues(alpha: (0.45 + recency * 0.5) * edgeFade);
      final rect = Rect.fromLTWH(
        centerX - barWidth / 2,
        (kConsoleDictationWaveHeight - barHeight) / 2,
        barWidth,
        barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(barWidth / 2)),
        paint,
      );
    }

    final lastSlot = math.max(1, slots - 1);
    for (var index = 0; index < history.length; index++) {
      drawBar(index, history[index], index / lastSlot);
    }
    if (animated) drawBar(history.length, motion.live, 1);
  }

  @override
  bool shouldRepaint(covariant _ConsoleDictationBarsPainter oldDelegate) =>
      !identical(oldDelegate.samples, samples) ||
      !identical(oldDelegate.motion, motion) ||
      oldDelegate.color != color ||
      oldDelegate.mutedColor != mutedColor ||
      oldDelegate.transcribing != transcribing;
}

/// One side of the composer's swap with the voice dock: it fades in or out
/// in its place and, hidden, takes neither touches nor TalkBack's focus. It
/// keeps its size and its subtree either way.
class _ComposerSwap extends StatelessWidget {
  const _ComposerSwap({
    required this.shown,
    required this.duration,
    required this.child,
    super.key,
  });

  final bool shown;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: shown ? 1 : 0,
    duration: duration,
    child: IgnorePointer(
      ignoring: !shown,
      child: ExcludeSemantics(excluding: !shown, child: child),
    ),
  );
}
