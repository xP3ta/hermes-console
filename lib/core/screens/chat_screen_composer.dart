// The composer: text controllers, slash/mention palettes, the attachment
// strip, the send button, dictation visuals and the queued-turn row.
part of 'chat_screen.dart';

class _EditUserMessageSheet extends StatefulWidget {
  final String initialText;

  const _EditUserMessageSheet({required this.initialText});

  @override
  State<_EditUserMessageSheet> createState() => _EditUserMessageSheetState();
}

class _EditUserMessageSheetState extends State<_EditUserMessageSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  void _releaseFocus() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus.hasFocus) focus.unfocus();
  }

  void _close([String? result]) {
    _releaseFocus();
    Navigator.of(context).pop(result);
  }

  @override
  void deactivate() {
    _releaseFocus();
    super.deactivate();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final body = SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => _close(),
                  icon: const Icon(Icons.close_rounded),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    strings.chaEditTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceVariant.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: colors.divider.withValues(alpha: 0.42),
                ),
              ),
              child: TextField(
                key: const ValueKey('edit-message-composer'),
                controller: _controller,
                autofocus: true,
                minLines: 2,
                maxLines: 8,
                decoration: InputDecoration(
                  hintText: strings.chaEditHint,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 15,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              strings.chaEditRewindWarning,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 74),
          ],
        ),
      ),
    );
    return Stack(
      children: [
        body,
        Positioned(
          left: 16,
          right: 16,
          bottom: 18,
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => _close(),
                child: Text(
                  MaterialLocalizations.of(context).cancelButtonLabel,
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                  minimumSize: const Size(0, 46),
                ),
                onPressed: () => _close(_controller.text.trim()),
                child: Text(strings.chaEditApply),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

extension _ComposerPalettePlacement on Widget {
  Widget _withComposerPalette(Widget? palette) =>
      _ComposerPaletteOverlay(palette: palette, child: this);
}

class _ComposerPaletteOverlay extends StatefulWidget {
  final Widget child;
  final Widget? palette;

  const _ComposerPaletteOverlay({required this.child, required this.palette});

  @override
  State<_ComposerPaletteOverlay> createState() =>
      _ComposerPaletteOverlayState();
}

class _ComposerPaletteOverlayState extends State<_ComposerPaletteOverlay> {
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

class _SlashAccentTextEditingController extends TextEditingController {
  TextRange? slashCommandRange() {
    final parsed = parseSlashCommand(value.text);
    if (parsed == null) return null;
    final text = value.text;
    final start = text.length - text.trimLeft().length;
    final trimmed = text.trimLeft();
    final sp = trimmed.indexOf(RegExp(r'\s'));
    final end = start + (sp == -1 ? trimmed.length : sp);
    return TextRange(start: start, end: end);
  }

  TextRange composingRange(TextEditingValue value, bool withComposing) {
    final range = value.composing;
    if (!withComposing || !value.isComposingRangeValid || range.isCollapsed) {
      return TextRange.empty;
    }
    return range;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    final slashRange = slashCommandRange();
    if (text.isEmpty || slashRange == null) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final composing = composingRange(value, withComposing);
    final cuts = <int>{0, slashRange.start, slashRange.end, text.length};
    if (!composing.isCollapsed) {
      cuts
        ..add(composing.start)
        ..add(composing.end);
    }
    final orderedCuts = cuts.toList()..sort();
    final spans = <InlineSpan>[];
    for (var index = 0; index < orderedCuts.length - 1; index++) {
      final start = orderedCuts[index];
      final end = orderedCuts[index + 1];
      if (start == end) continue;
      var segmentStyle = style;
      if (start >= slashRange.start && end <= slashRange.end) {
        segmentStyle = (segmentStyle ?? const TextStyle()).copyWith(
          color: Theme.of(context).hermes.accent,
        );
      }
      if (!composing.isCollapsed &&
          start >= composing.start &&
          end <= composing.end) {
        segmentStyle = (segmentStyle ?? const TextStyle()).merge(
          const TextStyle(decoration: TextDecoration.underline),
        );
      }
      spans.add(
        TextSpan(text: text.substring(start, end), style: segmentStyle),
      );
    }
    return TextSpan(style: style, children: spans);
  }
}

class _RoomMentionTextEditingController
    extends _SlashAccentTextEditingController {
  final Set<String> Function() selectedMentions;
  Color? mentionColor;

  _RoomMentionTextEditingController({required this.selectedMentions});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    final slashRange = slashCommandRange();
    final mentions = selectedMentions()
        .map((mention) => mention.trim())
        .where((mention) => mention.isNotEmpty)
        .toSet();
    if (text.isEmpty || mentions.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final alternatives = mentions.map(RegExp.escape).join('|');
    final mentionRanges =
        RegExp(
              '(^|\\s)(@(?:$alternatives))(?=\\s|\$|[.,;:!?])',
              caseSensitive: false,
            )
            .allMatches(text)
            .map((match) {
              final leadingLength = (match.group(1) ?? '').length;
              return TextRange(
                start: match.start + leadingLength,
                end: match.end,
              );
            })
            .toList(growable: false);
    if (mentionRanges.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final composing = composingRange(value, withComposing);
    final cuts = <int>{0, text.length};
    if (slashRange != null) {
      cuts
        ..add(slashRange.start)
        ..add(slashRange.end);
    }
    for (final range in mentionRanges) {
      cuts
        ..add(range.start)
        ..add(range.end);
    }
    if (!composing.isCollapsed) {
      cuts
        ..add(composing.start)
        ..add(composing.end);
    }
    final orderedCuts = cuts.toList()..sort();
    final spans = <InlineSpan>[];
    for (var index = 0; index < orderedCuts.length - 1; index++) {
      final start = orderedCuts[index];
      final end = orderedCuts[index + 1];
      if (start == end) continue;
      final isSlash =
          slashRange != null &&
          start >= slashRange.start &&
          end <= slashRange.end;
      final isMention = mentionRanges.any(
        (range) => start >= range.start && end <= range.end,
      );
      final isComposing =
          !composing.isCollapsed &&
          start >= composing.start &&
          end <= composing.end;
      var segmentStyle = style;
      if (isSlash) {
        segmentStyle = (segmentStyle ?? const TextStyle()).copyWith(
          color: Theme.of(context).hermes.accent,
        );
      }
      if (isMention) {
        segmentStyle = (segmentStyle ?? const TextStyle()).merge(
          TextStyle(color: mentionColor, fontWeight: FontWeight.w800),
        );
      }
      if (isComposing) {
        segmentStyle = (segmentStyle ?? const TextStyle()).merge(
          const TextStyle(decoration: TextDecoration.underline),
        );
      }
      spans.add(
        TextSpan(text: text.substring(start, end), style: segmentStyle),
      );
    }
    return TextSpan(style: style, children: spans);
  }
}

class _RoomMentionPalette extends StatelessWidget {
  final MissionRoom room;
  final List<String> profiles;
  final Map<String, AgentProfile> profileRoster;
  final MissionProfileAvatarCache? avatarCache;
  final ValueChanged<String> onPick;

  const _RoomMentionPalette({
    required this.room,
    required this.profiles,
    required this.profileRoster,
    required this.avatarCache,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final english = Localizations.localeOf(context).languageCode == 'en';
    return Container(
      key: const ValueKey('room-mention-palette'),
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 9),
      constraints: const BoxConstraints(maxHeight: 224),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.divider.withValues(alpha: 0.72)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 22,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Material(
          color: Colors.transparent,
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 5),
            itemCount: profiles.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              indent: 58,
              color: colors.divider.withValues(alpha: 0.45),
            ),
            itemBuilder: (context, index) {
              final profile = profiles[index];
              final manager = profile == room.managerProfile;
              return InkWell(
                key: ValueKey('room-mention-$profile'),
                onTap: () => onPick(profile),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 9, 14, 9),
                  child: Row(
                    children: [
                      _missionIdentityAvatar(
                        key: ValueKey('room-mention-avatar-$profile'),
                        profileName: profile,
                        profiles: profileRoster,
                        cache: avatarCache,
                        size: 34,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '@$profile',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.08,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        manager
                            ? Icons.forum_outlined
                            : Icons.view_kanban_outlined,
                        size: 15,
                        color: manager ? colors.accent : colors.textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        manager
                            ? (english ? 'Talk' : 'Hablar')
                            : (english ? 'Assign task' : 'Asignar tarea'),
                        style: TextStyle(
                          color: manager ? colors.accent : colors.textSecondary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Paleta de comandos slash: aparece sobre el compositor al escribir `/…` y
/// lista los comandos que coinciden. Tocar uno lo ejecuta o rellena su nombre.
class _SlashPalette extends StatelessWidget {
  final List<SlashCommand> commands;
  final ValueChanged<SlashCommand> onPick;

  const _SlashPalette({required this.commands, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      key: const ValueKey('chat-slash-palette'),
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 9),
      constraints: const BoxConstraints(maxHeight: 224),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.divider.withValues(alpha: 0.72)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 22,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Material(
          color: Colors.transparent,
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 5),
            itemCount: commands.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              indent: 58,
              color: colors.divider.withValues(alpha: 0.45),
            ),
            itemBuilder: (ctx, i) {
              final command = commands[i];
              return InkWell(
                key: ValueKey('chat-slash-command-${command.name}'),
                onTap: () => onPick(command),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 14, 8),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: colors.accent.withValues(alpha: 0.11),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colors.accent.withValues(alpha: 0.24),
                          ),
                        ),
                        child: Text(
                          '/',
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            color: colors.accent,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '/${command.name}',
                                    style: TextStyle(
                                      color: colors.accent,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  if (command.argHint.isNotEmpty)
                                    TextSpan(
                                      text: '  ${command.argHint}',
                                      style: TextStyle(
                                        color: colors.textSecondary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              command.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textSecondary,
                                fontSize: 12.5,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Compact strip shown above the input bar when a file is staged.
/// Shows a thumbnail for images or a document icon for other files.
/// Reflects the real per-item state; remove and retry never affect siblings.
class _AttachmentPreviewStrip extends StatelessWidget {
  final List<AttachmentDraft> attachments;
  final ValueChanged<String>? onRemove;
  final ValueChanged<String>? onRetry;

  const _AttachmentPreviewStrip({
    required this.attachments,
    required this.onRemove,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
                      attachment.uploadState == AttachmentUploadState.uploading;
                  final openPreview = previewable
                      ? () =>
                            showImageViewer(context, File(attachment.localPath))
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
    );
  }
}

/// Modo del botón principal del composer.
/// - [send]: envío normal (idle).
/// - [stop]: el agente responde; el borrador del turno siguiente no sustituye Stop.
enum _SendMode { send, stop }

class _SendButton extends StatefulWidget {
  final _SendMode mode;

  /// A-017 (spec 028): con el campo vacío la flecha se pinta atenuada y no
  /// responde — antes lucía activa (ámbar + glow) pero el tap no hacía nada.
  final bool enabled;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const _SendButton({
    required this.mode,
    required this.onSend,
    required this.onStop,
    this.enabled = true,
    this.busy = false,
  });

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  void _handleTap() {
    if (!widget.enabled) return;
    HapticFeedback.lightImpact();
    if (widget.mode == _SendMode.stop) {
      widget.onStop();
    } else {
      widget.onSend();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final isStop = widget.mode == _SendMode.stop;
    final s = Strings.of(context);
    final tooltip = widget.busy
        ? s.chaUploadingAttachment
        : switch (widget.mode) {
            _SendMode.send => s.chaSendTooltip,
            _SendMode.stop => s.chaStopTooltip,
          };
    final icon = switch (widget.mode) {
      _SendMode.send => Icons.arrow_upward,
      _SendMode.stop => Icons.stop_rounded,
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

    return HermesTactileAction(
      icon: icon,
      iconSize: isStop ? 21 : 19,
      semanticLabel: tooltip,
      onPressed: widget.enabled ? _handleTap : null,
      backgroundColor: bg,
      foregroundColor: fg,
      enabled: widget.enabled,
      size: 42,
    );
  }
}

/// Fila compacta para un seguimiento pendiente: comparte el eje del composer,
/// no ocupa un turno visual y se puede retirar antes del envío automático.
class _QueuedRow extends StatelessWidget {
  final String text;
  final List<String> attachmentNames;
  final VoidCallback onCancel;

  const _QueuedRow({
    required this.text,
    this.attachmentNames = const [],
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final preview = text.length > 72 ? '${text.substring(0, 72)}…' : text;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Icon(
            Icons.subdirectory_arrow_right_rounded,
            size: 16,
            color: colors.textDisabled,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (preview.trim().isNotEmpty)
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.25,
                      color: colors.textSecondary,
                    ),
                  ),
                if (attachmentNames.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    children: attachmentNames
                        .map(
                          (name) => Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: colors.textDisabled,
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            tooltip: Strings.of(context).chaCancelQueuedMessage,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            padding: EdgeInsets.zero,
            icon: Icon(
              Icons.close_rounded,
              size: 16,
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Visualizador compacto del dictado. La onda ocupa una franja reservada bajo
/// los parciales visibles en el campo. No graba ni procesa audio; solo observa
/// [VoiceService.micLevel].
class _DictationVisualizer extends StatefulWidget {
  const _DictationVisualizer({
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
  State<_DictationVisualizer> createState() => _DictationVisualizerState();
}

class _DictationVisualizerState extends State<_DictationVisualizer>
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
  void didUpdateWidget(_DictationVisualizer oldWidget) {
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
          height: _dictationWaveHeight,
          child: SizedBox(
            key: const ValueKey('dictation-bars'),
            child: RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey('dictation-bars-paint'),
                painter: _DictationBarsPainter(
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

class _DictationBarsPainter extends CustomPainter {
  const _DictationBarsPainter({
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
      final barHeight = 3.2 + sample * (_dictationWaveHeight - 3.2);
      final recency = index / math.max(1, barCount - 1);
      paint.color = transcribing
          ? mutedColor.withValues(alpha: 0.32)
          : color.withValues(alpha: 0.5 + recency * 0.4);
      final rect = Rect.fromLTWH(
        slotWidth * (index + 0.5) - barWidth / 2,
        (_dictationWaveHeight - barHeight) / 2,
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
  bool shouldRepaint(covariant _DictationBarsPainter oldDelegate) =>
      !identical(oldDelegate.samples, samples) ||
      oldDelegate.color != color ||
      oldDelegate.mutedColor != mutedColor ||
      oldDelegate.transcribing != transcribing;
}
