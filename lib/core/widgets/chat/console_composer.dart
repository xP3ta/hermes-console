import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/attachment_draft.dart';
import '../../theme/app_theme.dart';
import '../attachment_card.dart';
import '../attachment_source_sheet.dart';
import '../hermes_premium_ui.dart';

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
  });

  final bool recording;
  final bool transcribing;

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
    this.voiceModeAction,
    this.showBotModeToggle = true,
    this.footer,
    this.palette,
    this.hintText,
    this.fieldEnabled = true,
    this.fieldReadOnly = false,
    this.onKeyboardSubmit,
    this.onContentInserted,
    this.reduceMotion = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Enviar: recibe el texto actual y [attachments].
  final ConsoleComposerSend onSend;

  /// Fuente de adjunto elegida en el menú `+`; `null` oculta el `+`.
  final ValueChanged<AttachmentSourceChoice>? onAttach;
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

  /// Acción primaria alternativa (p. ej. modo voz del chat principal) que
  /// sustituye a enviar cuando no hay nada que enviar.
  final Widget? voiceModeAction;

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

    if (dictation.interactive) {
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
          backgroundColor: enabled
              ? Colors.white
              : colors.surfaceVariant.withValues(alpha: 0.72),
          foregroundColor: enabled ? Colors.black : colors.textDisabled,
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
                enabled: showStop ? stopEnabled : sendEnabled,
                onSend: _send,
                onQueue: onQueue,
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
    final footer = showBotModeToggle ? this.footer : null;
    // La lectura de `viewInsets`/orientación vive en un `Builder` propio: así
    // solo este subárbol se reconstruye con cada frame de la animación del
    // teclado, en vez de suscribir al host (y con él el transcript) a
    // `MediaQuery.of`.
    return Builder(
      builder: (imeContext) {
        // En horizontal el IME ocupa más de media pantalla. El composer normal
        // (campo de hasta cuatro líneas + fila de acciones + SafeArea) puede
        // quedar más alto que el viewport restante y provocar un RenderFlex
        // overflow.
        final compactIme =
            MediaQuery.viewInsetsOf(imeContext).bottom > 0 &&
            MediaQuery.orientationOf(imeContext) == Orientation.landscape;
        return Container(
          key: const ValueKey('chat-composer-host'),
          padding: compactIme
              ? const EdgeInsets.fromLTRB(12, 2, 12, 3)
              : const EdgeInsets.fromLTRB(14, 4, 14, 10),
          color: colors.background,
          child: SafeArea(
            bottom: !compactIme,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConsoleComposerPaletteOverlay(
                  palette: palette,
                  child: HermesComposerSurface(
                    focused: focusNode.hasFocus,
                    unfocusedHorizontalInset: 12,
                    padding: compactIme
                        ? const EdgeInsets.symmetric(horizontal: 4)
                        : EdgeInsets.zero,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (attachments.isNotEmpty)
                          ConsoleAttachmentPreviewStrip(
                            key: const ValueKey('composer-attachment-preview'),
                            attachments: attachments,
                            onRemove: onRemoveAttachment,
                            onRetry: onRetryAttachment,
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
                                enabled: attachEnabled,
                              ),
                            if (recording)
                              _dictationCancel(context, colors, dictation!),
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
                                        ),
                                      ),
                                    ),
                                    if (recording && level != null)
                                      SizedBox(
                                        key: const ValueKey(
                                          'dictation-recording-area',
                                        ),
                                        height: kConsoleDictationComposerHeight,
                                        child: Center(
                                          child: IgnorePointer(
                                            child: ConsoleDictationVisualizer(
                                              key: const ValueKey(
                                                'dictation-visualizer',
                                              ),
                                              level: level,
                                              color: colors.textSecondary,
                                              mutedColor: colors.textDisabled,
                                              transcribing: transcribing,
                                              listeningLabel: Strings.of(
                                                context,
                                              ).chaVoiceListeningLabel,
                                              transcribingLabel: Strings.of(
                                                context,
                                              ).chaVoiceTranscribingLabel,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            if (dictation != null)
                              _dictationAction(context, colors, dictation),
                            if (recording)
                              _dictationSend(context, colors, dictation!),
                            if (!recording) ...[
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
                ),
                ?footer,
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildField(
    BuildContext context,
    HermesThemeColors colors, {
    required bool compactIme,
    required bool recording,
  }) {
    final onContentInserted = this.onContentInserted;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      style: recording ? const TextStyle(color: Colors.transparent) : null,
      cursorColor: recording ? Colors.transparent : null,
      decoration: InputDecoration(
        hintText: hintText ?? Strings.of(context).chaHintUser,
        hintStyle: TextStyle(
          color: recording ? Colors.transparent : colors.textSecondary,
          fontSize: 14,
        ),
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        contentPadding: EdgeInsets.fromLTRB(
          4,
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
              allowedMimeTypes: const [
                'image/png',
                'image/jpeg',
                'image/gif',
                'image/webp',
              ],
              onContentInserted: onContentInserted,
            ),
      textInputAction: TextInputAction.newline,
      readOnly: fieldReadOnly,
      enabled: fieldEnabled,
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

/// Compact strip shown above the input bar when a file is staged.
/// Shows a thumbnail for images or a document icon for other files.
/// Reflects the real per-item state; remove and retry never affect siblings.
class ConsoleAttachmentPreviewStrip extends StatelessWidget {
  final List<AttachmentDraft> attachments;
  final ValueChanged<String>? onRemove;
  final ValueChanged<String>? onRetry;

  const ConsoleAttachmentPreviewStrip({
    required this.attachments,
    required this.onRemove,
    required this.onRetry,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // A horizontal scroll view shrink-wraps to its content, and the composer
    // column centres its children: one or two thumbs ended up floating in the
    // middle of the input. Take the full width and pin the row to the start
    // edge (RTL-aware) so attachments stack from the leading side.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < attachments.length; index++) ...[
                if (index > 0) const SizedBox(width: 10),
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
                        attachment.uploadState ==
                        AttachmentUploadState.uploading;
                    final openPreview = previewable
                        ? () => showImageViewer(
                            context,
                            File(attachment.localPath),
                          )
                        : null;
                    return Semantics(
                      container: changing || previewable,
                      explicitChildNodes: changing || previewable,
                      liveRegion:
                          changing ||
                          attachment.uploadState == AttachmentUploadState.error,
                      label: changing
                          ? Strings.of(
                              context,
                            ).chaAttachmentUploadInProgress(attachment.name)
                          : previewable
                          ? Strings.of(
                              context,
                            ).chaPreviewAttachment(attachment.name)
                          : null,
                      button: previewable,
                      onTap: openPreview,
                      child: AttachmentCard(
                        key: ValueKey('attachment-card-${attachment.localId}'),
                        name: attachment.name,
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
  final VoidCallback onStop;

  const ConsoleSendButton({
    super.key,
    required this.mode,
    required this.onSend,
    required this.onStop,
    this.onQueue,
    this.enabled = true,
    this.busy = false,
  });

  @override
  State<ConsoleSendButton> createState() => _ConsoleSendButtonState();
}

class _ConsoleSendButtonState extends State<ConsoleSendButton> {
  void _handleTap() {
    if (!widget.enabled) return;
    HapticFeedback.lightImpact();
    if (widget.mode == ConsoleSendMode.stop) {
      widget.onStop();
    } else {
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
            ConsoleSendMode.send => s.chaSendTooltip,
            ConsoleSendMode.stop => s.chaStopTooltip,
          };
    final icon = switch (widget.mode) {
      ConsoleSendMode.send => Icons.arrow_upward,
      ConsoleSendMode.stop => Icons.stop_rounded,
    };
    final bg = !widget.enabled ? colors.surfaceVariant : colors.accent;
    final fg = !widget.enabled ? colors.textDisabled : colors.onAccent;
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
    return HermesTactileAction(
      icon: icon,
      iconSize: isStop ? 21 : 19,
      semanticLabel: tooltip,
      onPressed: widget.enabled ? _handleTap : null,
      onLongPress: isStop || !widget.enabled || onQueue == null
          ? null
          : () {
              HapticFeedback.lightImpact();
              onQueue();
            },
      backgroundColor: bg,
      foregroundColor: fg,
      enabled: widget.enabled,
      size: 42,
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
    with WidgetsBindingObserver {
  static const _barCount = 48;
  static const _frameInterval = Duration(microseconds: 33334);
  final ValueNotifier<List<double>> _samples = ValueNotifier(
    List<double>.filled(_barCount, 0),
  );
  Timer? _sampleTimer;
  bool _tickerModeEnabled = true;
  bool _appActive = true;

  bool get _shouldSampleLevel =>
      !widget.transcribing && _tickerModeEnabled && _appActive;

  @visibleForTesting
  bool get debugClockActive => _sampleTimer?.isActive ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _syncSampleClock();
  }

  @override
  void didUpdateWidget(ConsoleDictationVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transcribing != widget.transcribing) {
      _syncSampleClock();
    }
  }

  void _syncSampleClock() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    if (!_shouldSampleLevel) return;
    _sampleTimer = Timer.periodic(_frameInterval, (_) {
      if (!_shouldSampleLevel) {
        _syncSampleClock();
        return;
      }
      final raw = widget.level.value.clamp(0.0, 1.0).toDouble();
      // Solo amplifica la representación visual: no modifica el PCM ni lo que
      // recibe el motor STT. El pequeño noise gate mantiene el silencio plano.
      final sample = ((raw - 0.018) / 0.42).clamp(0.0, 1.0).toDouble();
      final history = _samples.value;
      _samples.value = <double>[...history.skip(1), sample];
    });
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
    _samples.dispose();
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

class _ConsoleDictationBarsPainter extends CustomPainter {
  const _ConsoleDictationBarsPainter({
    required this.samples,
    required this.color,
    required this.mutedColor,
    required this.transcribing,
  }) : super(repaint: samples);

  final ValueListenable<List<double>> samples;
  final Color color;
  final Color mutedColor;
  final bool transcribing;

  @override
  void paint(Canvas canvas, Size size) {
    final history = samples.value;
    if (history.isEmpty || size.isEmpty) return;
    final barCount = history.length;
    final slotWidth = size.width / barCount;
    final barWidth = math.min(3.2, math.max(1.7, slotWidth * 0.52));
    final paint = Paint();
    for (var index = 0; index < barCount; index++) {
      final sample = history[index].clamp(0.0, 1.0).toDouble();
      final barHeight = 3.2 + sample * (kConsoleDictationWaveHeight - 3.2);
      final recency = index / math.max(1, barCount - 1);
      paint.color = transcribing
          ? mutedColor.withValues(alpha: 0.32)
          : color.withValues(alpha: 0.5 + recency * 0.4);
      final rect = Rect.fromLTWH(
        slotWidth * (index + 0.5) - barWidth / 2,
        (kConsoleDictationWaveHeight - barHeight) / 2,
        barWidth,
        barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ConsoleDictationBarsPainter oldDelegate) =>
      !identical(oldDelegate.samples, samples) ||
      oldDelegate.color != color ||
      oldDelegate.mutedColor != mutedColor ||
      oldDelegate.transcribing != transcribing;
}
