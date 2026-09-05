// Message bubbles and timeline rows: user and assistant turns, streaming
// hosts, error bubbles and the empty-chat states.
part of 'chat_screen.dart';

class _UserTurnGroup {
  final Map<String, dynamic> primary;
  final List<Map<String, dynamic>> supplements = [];

  _UserTurnGroup(this.primary);
}

/// Welcome state shown when the session has no messages yet.
/// Terminal-style prompt with a blinking block cursor.
class _EmptyChatState extends StatelessWidget {
  final String model;
  final String agentName;
  final MissionRoom? missionRoom;
  final Map<String, AgentProfile> missionRoomProfiles;
  final MissionProfileAvatarCache? missionAvatarCache;

  const _EmptyChatState({
    required this.model,
    this.agentName = 'hermes',
    this.missionRoom,
    this.missionRoomProfiles = const {},
    this.missionAvatarCache,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final room = missionRoom;
    if (room != null) {
      final english = Localizations.localeOf(context).languageCode == 'en';
      return Center(
        key: const ValueKey('mission-room-empty-state'),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MissionRoomEmptyRoster(
                  room: room,
                  profiles: missionRoomProfiles,
                  avatarCache: missionAvatarCache,
                ),
                const SizedBox(height: 20),
                Text(
                  english ? 'Start with the team' : 'Empieza con el equipo',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  english
                      ? 'Talk to @${room.managerProfile} or mention another bot to assign a task.'
                      : 'Habla con @${room.managerProfile} o menciona otro bot para asignarle una tarea.',
                  key: const ValueKey('mission-room-empty-manager'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.42,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - t)),
              child: child,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // El chat forma parte de la presencia completa. En off,
              // minimal o con Companion deshabilitado no se reserva espacio
              // ni se introduce un fallback que contradiga la preferencia.
              Builder(
                builder: (ctx) {
                  final companion = ctx
                      .findAncestorStateOfType<HermesAppState>()
                      ?.companion;
                  if (companion == null) return const SizedBox.shrink();
                  return AnimatedBuilder(
                    animation: companion,
                    builder: (context, _) {
                      if (!companion.isInitialized ||
                          !companion.enabled ||
                          !companion.presenceLevel.showsStatusPresence) {
                        return const SizedBox.shrink();
                      }
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CompanionMessagePresence(
                            companion: companion,
                            mood: HermesSparkMood.idle,
                            size: 120,
                            animateIdle: true,
                          ),
                          const SizedBox(height: 18),
                        ],
                      );
                    },
                  );
                },
              ),
              Text(
                agentName,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  color: colors.accent,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    Strings.of(context).chaEmptyPrompt,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.textSecondary,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(width: 3),
                  _BlinkingCursor(
                    key: const ValueKey('empty-chat-blink-clock'),
                    color: colors.accent,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MissionRoomEmptyRoster extends StatelessWidget {
  final MissionRoom room;
  final Map<String, AgentProfile> profiles;
  final MissionProfileAvatarCache? avatarCache;

  const _MissionRoomEmptyRoster({
    required this.room,
    required this.profiles,
    required this.avatarCache,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final members = <String>[
      room.managerProfile,
      ...room.memberProfiles.where((profile) => profile != room.managerProfile),
    ].take(4).toList(growable: false);
    const size = 42.0;
    const overlap = 29.0;
    return SizedBox(
      width: size + ((members.length - 1) * overlap),
      height: size,
      child: Stack(
        children: [
          for (var index = 0; index < members.length; index++)
            PositionedDirectional(
              start: index * overlap,
              child: Container(
                width: size,
                height: size,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: colors.background,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: index == 0
                        ? colors.warning.withValues(alpha: 0.72)
                        : colors.divider,
                  ),
                ),
                child: _missionIdentityAvatar(
                  key: ValueKey('mission-room-empty-avatar-${members[index]}'),
                  profileName: members[index],
                  profiles: profiles,
                  cache: avatarCache,
                  size: size - 6,
                  manager: index == 0,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Widget _missionIdentityAvatar({
  required Key key,
  required String profileName,
  required Map<String, AgentProfile> profiles,
  required MissionProfileAvatarCache? cache,
  required double size,
  bool manager = false,
}) {
  final profile = profiles[profileName];
  return MissionProfileAvatar(
    key: key,
    profileName: profileName,
    hasAvatar: profile?.hasAvatar ?? false,
    cache: cache,
    size: size,
    manager: manager,
    shape: profile?.botShape,
    colorHex: profile?.botColorHex,
    imageKind: profile?.botImageKind,
  );
}

/// Cursor de terminal que parpadea (▍). Usado en el chat vacío para dar un
/// toque animado al "Escríbeme para empezar".
class _BlinkingCursor extends StatefulWidget {
  final Color color;
  const _BlinkingCursor({super.key, required this.color});

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with WidgetsBindingObserver {
  static const Duration _blinkInterval = Duration(milliseconds: 550);

  Timer? _clock;
  bool _visible = true;
  bool _reduceMotion = false;
  bool _tickerModeEnabled = true;
  bool _appActive = true;
  int _debugBlinkCount = 0;

  bool get debugClockActive => _clock?.isActive ?? false;
  int get debugBlinkCount => _debugBlinkCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    final changed =
        _reduceMotion != reduced || _tickerModeEnabled != tickerEnabled;
    _reduceMotion = reduced;
    _tickerModeEnabled = tickerEnabled;
    if (changed || _clock == null) _syncClock();
  }

  bool get _shouldBlink =>
      mounted && _appActive && _tickerModeEnabled && !_reduceMotion;

  void _syncClock({bool notify = false}) {
    _clock?.cancel();
    _clock = null;
    final visibilityChanged = !_visible;
    _visible = true;
    if (_shouldBlink) {
      _clock = Timer.periodic(_blinkInterval, (_) {
        if (!_shouldBlink) {
          _syncClock(notify: true);
          return;
        }
        setState(() {
          _visible = !_visible;
          _debugBlinkCount++;
        });
      });
    }
    if (notify && visibilityChanged && mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) return;
    _appActive = active;
    _syncClock(notify: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    _clock = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      key: const ValueKey('empty-chat-cursor'),
      opacity: _visible ? 1.0 : 0.0,
      child: Text('▍', style: TextStyle(fontSize: 13, color: widget.color)),
    );
  }
}

/// Tipo de error inferido a partir del mensaje, para encabezar la burbuja con
/// una causa concreta (no un "error" genérico).
// Alias locales para mantener compatibilidad con el código existente de esta
// pantalla sin renombrar cada uso (_ErrorKind → ChatErrorKind).
typedef _ErrorKind = ChatErrorKind;
final _classifyError = classifyChatError;

/// Error bubble shown when the stream fails — inline with retry button.
///
/// Diferencia el tipo de error (conexión/modelo/herramienta/local/desconocido)
/// y permite desplegar el detalle técnico completo sin volcarlo por defecto.
class _ErrorBubble extends StatefulWidget {
  final String error;
  final String prompt;
  final VoidCallback onRetry;

  /// Acción opcional para reiniciar el gateway (se ofrece en errores de
  /// "agente colgado"/conexión, donde el servidor puede estar atascado).
  final VoidCallback? onRestartGateway;

  const _ErrorBubble({
    required this.error,
    required this.prompt,
    required this.onRetry,
    this.onRestartGateway,
  });

  @override
  State<_ErrorBubble> createState() => _ErrorBubbleState();
}

class _ErrorBubbleState extends State<_ErrorBubble> {
  bool _expanded = false;

  String _kindLabel(_ErrorKind kind, Strings s) => switch (kind) {
    _ErrorKind.connection => s.chaErrConnection,
    _ErrorKind.model => s.chaErrModel,
    _ErrorKind.tool => s.chaErrTool,
    _ErrorKind.local => s.chaErrLocal,
    _ErrorKind.localColdStart => s.chaErrLocalColdStart,
    _ErrorKind.firstTokenTimeout => s.chaErrFirstTokenTimeout,
    _ErrorKind.searchToolUnavailable => s.chaErrSearchToolUnavailable,
    _ErrorKind.unknown => s.chaErrUnknown,
  };

  String? _kindHint(_ErrorKind kind, Strings s) => switch (kind) {
    _ErrorKind.connection => s.chaErrHintConnection,
    _ErrorKind.model => s.chaErrHintModel,
    _ErrorKind.tool => null,
    _ErrorKind.local => s.chaErrHintLocal,
    _ErrorKind.localColdStart => s.chaErrHintLocalColdStart,
    _ErrorKind.firstTokenTimeout => s.chaErrHintFirstTokenTimeout,
    _ErrorKind.searchToolUnavailable => s.chaErrHintSearchToolUnavailable,
    _ErrorKind.unknown => null,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final kind = _classifyError(widget.error);
    final summary = widget.error.length > 140
        ? '${widget.error.substring(0, 140)}…'
        : widget.error;
    final hasMore = widget.error.length > 140 || widget.error.contains('\n');

    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 56, top: 11, bottom: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Presencia (006): el Companion muestra su estado de error
                // cuando el turno falla y no se puede continuar. Decorativo,
                // invisible si la presencia está apagada.
                Builder(
                  builder: (ctx) {
                    final app = ctx.findAncestorStateOfType<HermesAppState>();
                    if (app == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: CompanionMessagePresence(
                        companion: app.companion,
                        mood: HermesSparkMood.error,
                        size: 32,
                      ),
                    );
                  },
                ),
                Text(
                  '▸ hermes',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.error,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: colors.error.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colors.error.withValues(alpha: 0.18)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(kind.icon, size: 14, color: colors.error),
                    const SizedBox(width: 6),
                    Text(
                      _kindLabel(kind, str),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: colors.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _expanded ? widget.error : summary,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: colors.error.withValues(alpha: 0.92),
                    fontFamily: _expanded ? 'monospace' : null,
                  ),
                ),
                if (_kindHint(kind, str) != null && !_expanded) ...[
                  const SizedBox(height: 4),
                  Text(
                    _kindHint(kind, str)!,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ],
                const SizedBox(height: 8),
                // A-114 (spec 028): las acciones de recuperación pasan a
                // targets ≥48dp con rol de botón (eran texto de 11px con
                // ~25dp tocables); el visual compacto se conserva.
                Row(
                  children: [
                    _ErrorBubbleAction(
                      label: Strings.of(context).chaRetry,
                      color: colors.error,
                      onTap: widget.onRetry,
                    ),
                    // En errores de "agente colgado"/conexión, ofrecer reiniciar
                    // el gateway del servidor (puede estar atascado).
                    if (widget.onRestartGateway != null &&
                        (kind == _ErrorKind.firstTokenTimeout ||
                            kind == _ErrorKind.connection)) ...[
                      const SizedBox(width: 8),
                      _ErrorBubbleAction(
                        label: Strings.of(context).chaRestartGateway,
                        color: colors.error,
                        onTap: widget.onRestartGateway,
                      ),
                    ],
                    if (hasMore) ...[
                      const SizedBox(width: 8),
                      _ErrorBubbleAction(
                        label: _expanded
                            ? Strings.of(context).chaErrHideDetails
                            : Strings.of(context).chaErrViewDetails,
                        color: colors.textSecondary,
                        outlined: false,
                        onTap: () => setState(() => _expanded = !_expanded),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Acción compacta de la tarjeta de error. A-114 (spec 028): rol de botón y
/// target táctil ≥48dp para TalkBack/motricidad reducida; el visual sigue
/// siendo la pastilla pequeña de siempre.
class _ErrorBubbleAction extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Color color;
  final bool outlined;

  const _ErrorBubbleAction({
    required this.label,
    required this.onTap,
    required this.color,
    this.outlined = true,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: outlined
                  ? BoxDecoration(
                      border: Border.all(color: color.withValues(alpha: 0.5)),
                      borderRadius: BorderRadius.circular(6),
                    )
                  : null,
              child: Text(label, style: TextStyle(fontSize: 11, color: color)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Assistant message with a subtle status mark (e.g. "cancelled").
class _AssistantMessageWithMark extends StatelessWidget {
  final String content;
  final String mark;
  final bool verbose;
  final Map<String, dynamic> metadata;
  final Map<String, _LinkPreviewData?> linkCache;
  final Future<void> Function(String url) fetchLinkPreview;
  final String? Function(String text) firstUrl;
  final String agentName;
  final String? roomManagerProfile;
  final _AssistantRenderSlice? slice;
  final _AssistantTerminalProjection? terminalProjection;
  final List<String> technicalDetails;
  final VoidCallback? onRegenerate;

  const _AssistantMessageWithMark({
    required this.content,
    required this.mark,
    required this.linkCache,
    required this.fetchLinkPreview,
    required this.firstUrl,
    this.verbose = false,
    this.metadata = const {},
    this.agentName = 'hermes',
    this.roomManagerProfile,
    this.slice,
    this.terminalProjection,
    this.technicalDetails = const [],
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _AssistantMessage(
          content: content,
          verbose: verbose,
          metadata: metadata,
          linkCache: linkCache,
          fetchLinkPreview: fetchLinkPreview,
          firstUrl: firstUrl,
          agentName: agentName,
          roomManagerProfile: roomManagerProfile,
          slice: slice,
          terminalProjection: terminalProjection,
          technicalDetails: technicalDetails,
          onRegenerate: onRegenerate,
        ),
        // La marca pertenece al mensaje completo: en un render troceado solo la
        // lleva el slice de cierre, no cada fragmento.
        if (slice?.showFooter ?? true)
          Padding(
            padding: const EdgeInsets.only(left: 14, bottom: 4),
            child: Text(
              mark,
              style: TextStyle(fontSize: 10, color: colors.textDisabled),
            ),
          ),
      ],
    );
  }
}

class _LiveAssistantFrame {
  final int turnSerial;
  final String content;
  final Map<String, dynamic> metadata;
  final bool isStreaming;

  const _LiveAssistantFrame({
    required this.turnSerial,
    required this.content,
    required this.metadata,
    required this.isStreaming,
  });
}

class _LiveAssistantHost extends StatelessWidget {
  final ValueListenable<_LiveAssistantFrame?> frame;
  final Widget Function(BuildContext context, _LiveAssistantFrame frame)
  builder;
  final VoidCallback? onBuild;

  const _LiveAssistantHost({
    super.key,
    required this.frame,
    required this.builder,
    this.onBuild,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_LiveAssistantFrame?>(
      valueListenable: frame,
      builder: (context, value, _) {
        onBuild?.call();
        if (value == null) return const SizedBox.shrink();
        return builder(context, value);
      },
    );
  }
}

/// Prefijo ya cerrado de la respuesta viva. Su contenido no vuelve a cambiar
/// mientras el modelo escribe la cola, así que el parseo de CommonMark y el
/// resaltado de sus bloques `pre` se ejecutan UNA vez por prefijo nuevo en vez
/// de en cada frame del streaming: mientras [data] y el tema no cambien, build
/// devuelve la MISMA instancia de widget y el subtree no se reconstruye.
class _StableStreamingMarkdown extends StatefulWidget {
  /// Segmento ya preparado ([prepareAssistantAnswerStructure]) y escapado
  /// ([escapePathGlobs]); la reparación por bloque se aplica aquí dentro.
  final String data;
  final Widget Function(String data) markdown;
  final ChatPerformanceProbe? performanceProbe;

  const _StableStreamingMarkdown({
    required this.data,
    required this.markdown,
    this.performanceProbe,
  });

  @override
  State<_StableStreamingMarkdown> createState() =>
      _StableStreamingMarkdownState();
}

class _StableStreamingMarkdownState extends State<_StableStreamingMarkdown> {
  String? _source;
  ThemeData? _theme;
  Widget? _rendered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cached = _rendered;
    if (cached != null && _source == widget.data && identical(_theme, theme)) {
      return cached;
    }
    widget.performanceProbe?.liveStableProjectionComputations++;
    _source = widget.data;
    _theme = theme;
    return _rendered = widget.markdown(
      normalizeStableStreamingPrefix(widget.data),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final bool isUser;
  final bool verbose;
  final Map<String, dynamic> metadata;
  final Map<String, _LinkPreviewData?> linkCache;
  final Future<void> Function(String url) fetchLinkPreview;
  final String? Function(String text) firstUrl;

  final VoidCallback? onSpeak;
  final ValueListenable<ReadAloudSnapshot>? readAloud;
  final String? readAloudMessageKey;
  final ReadAloudStopBehavior readAloudStopBehavior;
  final String agentName;
  final String? roomManagerProfile;
  final bool isStreaming;
  final _AssistantRenderSlice? assistantSlice;
  final _AssistantTerminalProjection? terminalProjection;
  final List<String> technicalDetails;
  final VoidCallback? onEdit;
  final VoidCallback? onRegenerate;
  final AssistantSuggestionCallback? onSuggestionSelected;
  final bool compact;
  final ChatPerformanceProbe? performanceProbe;

  const _MessageBubble({
    required this.content,
    required this.isUser,
    required this.linkCache,
    required this.fetchLinkPreview,
    required this.firstUrl,
    this.verbose = false,
    this.metadata = const {},
    this.onSpeak,
    this.readAloud,
    this.readAloudMessageKey,
    this.readAloudStopBehavior = ReadAloudStopBehavior.pauseAndResume,
    this.agentName = 'hermes',
    this.roomManagerProfile,
    this.isStreaming = false,
    this.assistantSlice,
    this.terminalProjection,
    this.technicalDetails = const [],
    this.onEdit,
    this.onRegenerate,
    this.onSuggestionSelected,
    this.compact = false,
    this.performanceProbe,
  });

  @override
  Widget build(BuildContext context) {
    return isUser
        ? _UserMessage(
            content: content,
            verbose: verbose,
            metadata: metadata,
            onEdit: onEdit,
            compact: compact,
          )
        : _AssistantMessage(
            content: content,
            verbose: verbose,
            metadata: metadata,
            linkCache: linkCache,
            fetchLinkPreview: fetchLinkPreview,
            firstUrl: firstUrl,
            onSpeak: onSpeak,
            readAloud: readAloud,
            readAloudMessageKey: readAloudMessageKey,
            readAloudStopBehavior: readAloudStopBehavior,
            agentName: agentName,
            roomManagerProfile: roomManagerProfile,
            isStreaming: isStreaming,
            slice: assistantSlice,
            terminalProjection: terminalProjection,
            technicalDetails: technicalDetails,
            onRegenerate: onRegenerate,
            onSuggestionSelected: onSuggestionSelected,
            compact: compact,
            performanceProbe: performanceProbe,
          );
  }
}

/// Frontera estable de selección para un único mensaje terminado.
///
/// `MarkdownBody(selectable: true)` convierte cada bloque en un `EditableText`.
/// En una lista invertida Android intenta entonces hacer `bringIntoView` al
/// mostrar el menú y desplaza el mensaje bajo el dedo. Una región por mensaje
/// mantiene el Markdown como `Text.rich`, permite selección parcial y no toca el
/// scroll. Al deshabilitar la región se limpia la selección de forma explícita;
/// durante el desmontaje se deja que Flutter retire primero el Overlay y se
/// conserva una limpieza final defensiva en [dispose].
@visibleForTesting
class ChatMessageSelectionArea extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final Object? selectionIdentity;

  const ChatMessageSelectionArea({
    super.key,
    required this.child,
    this.enabled = true,
    this.selectionIdentity,
  });

  @override
  State<ChatMessageSelectionArea> createState() =>
      _ChatMessageSelectionAreaState();
}

class _ChatMessageSelectionAreaState extends State<ChatMessageSelectionArea> {
  final GlobalKey<SelectionAreaState> _selectionAreaKey =
      GlobalKey<SelectionAreaState>();

  void _clearSelection() {
    final area = _selectionAreaKey.currentState;
    if (area == null) return;
    final region = area.selectableRegion;
    region.hideToolbar();
    region.clearSelection();
  }

  @override
  void didUpdateWidget(ChatMessageSelectionArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.enabled && !widget.enabled) ||
        oldWidget.selectionIdentity != widget.selectionIdentity) {
      _clearSelection();
    }
  }

  @override
  void dispose() {
    _clearSelection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return SelectionArea(
      key: _selectionAreaKey,
      magnifierConfiguration: TextMagnifierConfiguration.disabled,
      child: widget.child,
    );
  }
}

/// Chip limpio que sustituye a un blob de SISTEMA (preámbulo de cron/skill o
/// resumen de compactación) en el chat. Mantener pulsado copia el contenido
/// crudo (para depurar). Se usa para cualquier rol (user o assistant).
class _SystemBlobChip extends StatelessWidget {
  final String label;
  final String raw;
  const _SystemBlobChip({required this.label, required this.raw});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    return Padding(
      padding: const EdgeInsets.only(left: 56, right: 12, top: 11, bottom: 3),
      child: Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: raw));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(Strings.of(context).chaCopied),
                duration: const Duration(seconds: 1),
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt_rounded, size: 15, color: colors.accent),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Evento durable del transcript con tratamiento editorial, no una burbuja.
/// El contenido interno solo queda accesible mediante pulsación larga para
/// diagnóstico; rutas, roles y payloads nunca se vuelcan en el chat.
class _TimelineSystemEventRow extends StatelessWidget {
  final String title;
  final String? detail;
  final IconData icon;
  final String raw;

  const _TimelineSystemEventRow({
    required this.title,
    required this.detail,
    required this.icon,
    required this.raw,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final semanticLabel = [
      title,
      if (detail case final value? when value.trim().isNotEmpty) value,
    ].join('. ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
      child: Semantics(
        label: semanticLabel,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: raw));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(Strings.of(context).chaCopied),
                duration: const Duration(seconds: 1),
              ),
            );
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Icon(
                    icon,
                    size: 16,
                    color: colors.textSecondary.withValues(alpha: 0.72),
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (detail case final value?
                          when value.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          value,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.textSecondary.withValues(alpha: 0.72),
                            fontSize: 12,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Esquemas permitidos para un enlace del markdown del chat. Pura (sin I/O)
/// para poder testearla: bloquea `intent://`, `file://`, `tel:` inyectado,
/// etc. — el `href` puede venir de un modelo remoto, no es de confiar sin
/// filtrar. Público para test unitario (`test/chat_markdown_link_test.dart`).
bool isAllowedMarkdownLinkScheme(String? href) {
  const allowedSchemes = {'http', 'https', 'mailto'};
  final uri = href == null ? null : Uri.tryParse(href);
  return uri != null && allowedSchemes.contains(uri.scheme);
}

/// Abre un enlace tocado dentro del markdown del chat (usuario o agente),
/// validando el esquema con [isAllowedMarkdownLinkScheme] antes de lanzarlo.
Future<void> _openMarkdownLink(BuildContext context, String? href) async {
  if (!isAllowedMarkdownLinkScheme(href)) {
    debugPrint('Enlace de markdown bloqueado (esquema no permitido): $href');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).chaLinkSchemeBlocked),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    return;
  }
  try {
    await launchUrl(Uri.parse(href!), mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('No se pudo abrir el enlace de markdown ($href): $e');
  }
}

class _UserMessage extends StatelessWidget {
  final String content;
  final bool verbose;
  final Map<String, dynamic> metadata;
  final List<String> supplements;
  final VoidCallback? onEdit;
  final bool compact;

  const _UserMessage({
    required this.content,
    this.verbose = false,
    this.metadata = const {},
    this.supplements = const [],
    this.onEdit,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;

    // Los blobs de sistema (cron/skill/compactación) los intercepta el
    // renderizador central (_buildRenderUnit → _SystemBlobChip), antes de llegar
    // aquí, así que en este punto `content` ya es un mensaje real del usuario.
    final List<String> metaLines = _buildMetaLines(verbose, metadata);
    final timestamp = _formatMessageTimestamp(metadata);
    final parsed = _parseUserContent(content);

    return ChatMessageSelectionArea(
      selectionIdentity: metadata['message_id'] ?? metadata['id'] ?? metadata,
      child: Padding(
        padding: EdgeInsets.only(
          left: 56,
          right: 12,
          top: compact ? 5 : 11,
          bottom: compact ? 1 : 3,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: compact ? 8 : 11,
              ),
              // Burbuja estilo Claude: panel suave uniforme, redondeado, SIN
              // borde. El mensaje del agente va en texto plano; el del usuario
              // en esta burbuja sutil.
              decoration: BoxDecoration(
                color: colors.surfaceVariant.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (metaLines.isNotEmpty)
                    _MetaBlock(lines: metaLines, onDark: true),
                  if (parsed.attachments.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: parsed.text.isNotEmpty ? 8 : 0,
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final attachment in parsed.attachments)
                            Builder(
                              builder: (context) {
                                final historyReference =
                                    attachment.historyReference;
                                if (historyReference != null) {
                                  return AttachmentHistoryCard(
                                    key: ValueKey(
                                      'history-attachment-'
                                      '${historyReference.index}-'
                                      '${historyReference.storageKey}',
                                    ),
                                    name: attachment.name,
                                    sizeLabel: attachment.sizeLabel,
                                    reference: historyReference,
                                  );
                                }
                                final imgPath = attachment.imagePath;
                                final imgFile =
                                    (imgPath != null &&
                                        File(imgPath).existsSync())
                                    ? File(imgPath)
                                    : null;
                                return AttachmentCard(
                                  name: attachment.name,
                                  mimeType: '',
                                  sizeLabel: attachment.sizeLabel,
                                  thumbnailFile: imgFile,
                                  onTap: imgFile != null
                                      ? () => showImageViewer(context, imgFile)
                                      : null,
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  if (parsed.text.isNotEmpty)
                    MarkdownBody(
                      data: parsed.text,
                      selectable: false,
                      // Respeta los saltos de línea simples (CommonMark los
                      // colapsaría en espacios → texto "todo junto").
                      softLineBreak: true,
                      onTapLink: (text, href, title) =>
                          _openMarkdownLink(context, href),
                      styleSheet: _userSheet(theme, colors),
                    ),
                  if (supplements.isNotEmpty) ...[
                    const SizedBox(height: 11),
                    Divider(
                      height: 1,
                      color: colors.divider.withValues(alpha: 0.45),
                    ),
                    const SizedBox(height: 9),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_comment_outlined,
                          size: 14,
                          color: colors.accent,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            Strings.of(context).chaSteerSupplementsLabel,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    for (var index = 0; index < supplements.length; index++)
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: index == supplements.length - 1 ? 0 : 7,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 2,
                              height: 18,
                              margin: const EdgeInsets.only(top: 2, right: 8),
                              decoration: BoxDecoration(
                                color: colors.accent.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                supplements[index],
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.35,
                                  color: colors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onEdit != null)
                  IconButton(
                    onPressed: onEdit,
                    tooltip: Strings.of(context).chaEditMessage,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    icon: Icon(
                      Icons.edit_outlined,
                      size: 15,
                      color: colors.textSecondary,
                    ),
                  ),
                // A-104 (spec 028): acción con nombre para TalkBack y target
                // de 48dp (el icono visual sigue siendo discreto).
                IconButton(
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(
                        text: userMessageClipboardText(parsed.text),
                      ),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(Strings.of(context).chaCopied),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  tooltip: Strings.of(context).chaCopyMessage,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: Icon(
                    Icons.copy_rounded,
                    size: 13,
                    color: colors.textSecondary,
                  ),
                ),
                if (timestamp != null) _MessageTimestamp(timestamp),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Construye la respuesta del asistente respetando la estructura que escribió el
/// modelo. La ruta compartida por el chat y [AssistantMarkdownView] solo aplica
/// reparaciones sintácticas conservadoras; no inventa títulos, callouts ni chips
/// inline a partir de prosa corriente.
///
/// [markdown] recibe el texto normalizado para un MarkdownBody. [callout] se
/// conserva en la firma por compatibilidad con los hosts existentes, pero los
/// callouts solo podrán volver a la ruta normal con una sintaxis explícita.
List<Widget> buildAssistantAnswerBlocks(
  String answer, {
  required bool isStreaming,
  bool structured = false,
  required Widget Function(String data) markdown,
  required Widget Function(CalloutContentBlock block) callout,
  void Function(String? href)? onLinkTap,
}) {
  // Conserva la estructura escrita por el modelo. Solo normalizamos comandos
  // inequívocos y encabezados Markdown pegados (`##Título`), sin convertir
  // prosa corta, etiquetas con `:` ni líneas sueltas en títulos o listas.
  final enhanced = structured
      ? answer
      : prepareAssistantAnswerStructure(answer);
  final blocks = enhanced.trim().isEmpty
      ? const <ContentBlock>[]
      : <ContentBlock>[MarkdownContentBlock(enhanced)];
  final widgets = <Widget>[];
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 4));
    if (b is MarkdownContentBlock) {
      // El streaming (cierre de vallas/backticks a medias) solo aplica al
      // último bloque, que es el que sigue creciendo.
      final streamingTail = isStreaming && i == blocks.length - 1;
      // Escapa primero los globs de rutas: sus asteriscos son literales y no
      // deben participar en el balanceo visual de énfasis Markdown. Las rutas
      // normales permanecen como texto; solo el backtick explícito crea código.
      final escaped = escapePathGlobs(b.text);
      // Durante el streaming se normalizan también los bloques cerrados para
      // que un delimitador huérfano como `**` no llegue como texto visible. El
      // bloque terminal se pinta tal cual llegó del servidor.
      final data = normalizeStreamingMarkdown(
        escaped,
        isStreaming: streamingTail,
      );
      // Las tablas GFM completas se pintan con un render propio (limpio, con
      // columnas dimensionadas y scroll horizontal) en vez del MarkdownBody, que
      // las descuadra. El bloque en streaming NO se trocea: una tabla a medias
      // parpadearía al llegar las filas, así que cae al Markdown hasta cerrar.
      if (streamingTail) {
        widgets.add(markdown(data));
      } else {
        var firstSeg = true;
        for (final seg in splitAnswerTables(data)) {
          if (!firstSeg) widgets.add(const SizedBox(height: 4));
          firstSeg = false;
          if (seg is TableSegment) {
            widgets.add(MarkdownTable(rows: seg.rows, onLinkTap: onLinkTap));
          } else if (seg is MarkdownSegment) {
            widgets.add(markdown(seg.text));
          }
        }
      }
    } else if (b is CalloutContentBlock) {
      widgets.add(callout(b));
    }
  }
  return widgets;
}

/// Primera fase pura del render del asistente. Separarla permite ejecutarla una
/// sola vez antes de dividir una respuesta larga en hijos virtualizados; la
/// ruta habitual sigue llamándola desde [buildAssistantAnswerBlocks].
@visibleForTesting
String prepareAssistantAnswerStructure(String answer) =>
    enhanceCommandBlocks(tidyAssistantMarkdown(flattenInlineHtml(answer)));

@visibleForTesting
void validateRemoteChatImageTransport(Uri uri) {
  TransportPrivacy.requireAllowed(uri.toString());
}

@visibleForTesting
Uri validateRemoteChatImageRedirect(Uri current, String location) {
  final target = current.resolve(location);
  validateRemoteChatImageTransport(target);
  if (target.origin != current.origin) {
    throw ArgumentError.value(
      target,
      'location',
      'Redirect cross-origin no permitido',
    );
  }
  return target;
}

class _AssistantMessage extends StatelessWidget {
  final String content;
  final bool verbose;
  final Map<String, dynamic> metadata;
  final Map<String, _LinkPreviewData?> linkCache;
  final Future<void> Function(String url) fetchLinkPreview;
  final String? Function(String text) firstUrl;
  final VoidCallback? onSpeak;
  final ValueListenable<ReadAloudSnapshot>? readAloud;
  final String? readAloudMessageKey;
  final ReadAloudStopBehavior readAloudStopBehavior;
  final String agentName;
  final String? roomManagerProfile;
  final bool isStreaming;
  final _AssistantRenderSlice? slice;
  final _AssistantTerminalProjection? terminalProjection;
  final List<String> technicalDetails;
  final VoidCallback? onRegenerate;
  final AssistantSuggestionCallback? onSuggestionSelected;
  final bool compact;
  final ChatPerformanceProbe? performanceProbe;

  const _AssistantMessage({
    required this.content,
    required this.linkCache,
    required this.fetchLinkPreview,
    required this.firstUrl,
    this.verbose = false,
    this.metadata = const {},
    this.onSpeak,
    this.readAloud,
    this.readAloudMessageKey,
    this.readAloudStopBehavior = ReadAloudStopBehavior.pauseAndResume,
    this.agentName = 'hermes',
    this.roomManagerProfile,
    this.isStreaming = false,
    this.slice,
    this.terminalProjection,
    this.technicalDetails = const [],
    this.onRegenerate,
    this.onSuggestionSelected,
    this.compact = false,
    this.performanceProbe,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;

    final List<String> metaLines = _buildMetaLines(verbose, metadata);
    final timestamp = _formatMessageTimestamp(metadata);

    // Separa el razonamiento (`<think>…`) de la respuesta final para mostrarlos
    // como bloques distintos (razonamiento discreto y plegable arriba). El
    // backend también entrega razonamiento ESTRUCTURADO fuera del content
    // (reasoning_content de DeepSeek-reasoner, reasoning_details de OpenRouter):
    // se compone con el inline para que no desaparezca de la burbuja; sin este
    // merge un assistant con razonamiento pero content vacío quedaría invisible.
    final split = mergeStructuredReasoning(
      terminalProjection?.split ?? slice?.plan.split ?? splitReasoning(content),
      metadata,
    );
    final showHeader = slice?.showHeader ?? true;
    final showFooter = slice?.showFooter ?? true;
    final structuredImages = _structuredGeneratedImages(metadata);
    final textualGeneratedBasenames = <String, int>{};
    if (structuredImages.isNotEmpty) {
      for (final segment in GeneratedImageService.segments(
        split.answer,
      ).whereType<ImageSegment>()) {
        final key = segment.basename.toLowerCase();
        textualGeneratedBasenames[key] =
            (textualGeneratedBasenames[key] ?? 0) + 1;
      }
    }
    final structuredFooterImages = showFooter
        ? structuredImages
              .where((ref) {
                final basename = ref.basename;
                if (ref.kind != GeneratedImageSourceKind.serverCache ||
                    basename == null) {
                  return true;
                }
                final key = basename.toLowerCase();
                final remaining = textualGeneratedBasenames[key] ?? 0;
                if (remaining <= 0) return true;
                textualGeneratedBasenames[key] = remaining - 1;
                return false;
              })
              .toList(growable: false)
        : const <_StructuredGeneratedImage>[];
    String stripStructuredEchoes(String text) =>
        _stripStructuredGeneratedImageEchoes(text, structuredImages);
    final suggestionProjection =
        terminalProjection?.suggestions ??
        (!isStreaming && showFooter && onSuggestionSelected != null
            ? projectAssistantSuggestions(split.answer)
            : AssistantSuggestionsProjection(body: split.answer));
    final answer = suggestionProjection.body;

    // Un bloque de Markdown de la respuesta, con la presentación de siempre.
    // El [data] ya viene normalizado por [buildAssistantAnswerBlocks].
    MarkdownBody markdownWidget(String data) => MarkdownBody(
      data: data,
      selectable: false,
      // CommonMark conserva los párrafos (líneas en blanco) y trata un salto
      // simple como espacio. Mostrar cada salto interno del modelo partía
      // frases después de paréntesis y hacía la respuesta demasiado estrecha.
      softLineBreak: false,
      onTapLink: (text, href, title) => _openMarkdownLink(context, href),
      sizedImageBuilder: (config) => _GatedChatImage(
        uri: config.uri,
        width: config.width,
        height: config.height,
        colors: colors,
      ),
      styleSheet: _assistantSheet(theme, colors),
      builders: {'pre': _PreCodeBuilder()},
    );

    /// Reparte un segmento vivo en prefijo estable cacheable + cola mutable.
    /// Solo la cola se reconstruye en cada frame; el prefijo conserva el mismo
    /// widget mientras su contenido no cambie (ni parseo ni resaltado nuevos).
    Iterable<Widget> streamingSplitWidgets(String text) sync* {
      final prepared = prepareAssistantAnswerStructure(text);
      final escaped = escapePathGlobs(prepared);
      final tailStart = streamingMarkdownTailStart(escaped);
      if (tailStart <= 0) {
        yield markdownWidget(
          normalizeStreamingMarkdown(escaped, isStreaming: true),
        );
        return;
      }
      final tail = normalizeStreamingMarkdown(
        escaped.substring(tailStart),
        isStreaming: true,
      );
      final stable = escaped.substring(0, tailStart);
      if (stable.trim().isNotEmpty) {
        yield _StableStreamingMarkdown(
          data: stable,
          markdown: markdownWidget,
          performanceProbe: performanceProbe,
        );
        if (tail.trim().isNotEmpty) {
          // La costura reproduce el blockSpacing (10) que separa esos bloques
          // cuando todo el segmento vive en un único MarkdownBody.
          yield const SizedBox(height: 10);
        }
      }
      if (tail.trim().isNotEmpty) yield markdownWidget(tail);
    }

    Iterable<Widget> answerWidgets() sync* {
      final projected = terminalProjection;
      if (projected != null) {
        for (final block in projected.blocks) {
          switch (block) {
            case _ProjectedAssistantMarkdown(:final data):
              final visible = stripStructuredEchoes(data);
              if (visible.trim().isNotEmpty) yield markdownWidget(visible);
            case _ProjectedAssistantTable(:final rows):
              yield MarkdownTable(
                rows: rows,
                onLinkTap: (href) => _openMarkdownLink(context, href),
              );
            case _ProjectedAssistantImage(:final basename):
              final ref = _StructuredGeneratedImage.textPath(basename);
              yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
            case _ProjectedAssistantGap():
              yield const SizedBox(height: 4);
          }
        }
        for (final ref in structuredFooterImages) {
          yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
        }
        return;
      }
      final renderSlice = slice;
      if (renderSlice != null) {
        switch (renderSlice.body) {
          case _AssistantGeneratedImageChunk(:final basename):
            final ref = _StructuredGeneratedImage.textPath(basename);
            yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
          case _AssistantMarkdownChunk(:final data):
            yield* buildAssistantAnswerBlocks(
              stripStructuredEchoes(data),
              isStreaming: false,
              structured: true,
              markdown: markdownWidget,
              callout: (block) => CalloutCard(
                kind: block.kind,
                title: block.title,
                body: block.body,
              ),
              onLinkTap: (href) => _openMarkdownLink(context, href),
            );
        }
        for (final ref in structuredFooterImages) {
          yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
        }
        return;
      }
      for (final segment in GeneratedImageService.segments(answer)) {
        if (segment is ImageSegment) {
          final ref = _StructuredGeneratedImage.textPath(segment.basename);
          yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
          continue;
        }
        final text = stripStructuredEchoes((segment as TextSegment).text);
        if (text.trim().isEmpty) continue;
        // Respuesta viva larga: el prefijo de bloques cerrados se proyecta una
        // sola vez por contenido; cada frame solo normaliza y parsea la cola
        // mutable. El texto resultante es byte a byte el mismo que el de la
        // ruta de bloque único (las reparaciones son independientes por bloque).
        if (isStreaming && text.length >= _liveAssistantStableSplitMinChars) {
          yield* streamingSplitWidgets(text);
          continue;
        }
        yield* buildAssistantAnswerBlocks(
          text,
          isStreaming: isStreaming,
          markdown: markdownWidget,
          callout: (block) => CalloutCard(
            kind: block.kind,
            title: block.title,
            body: block.body,
          ),
          onLinkTap: (href) => _openMarkdownLink(context, href),
        );
      }
      for (final ref in structuredFooterImages) {
        yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
      }
    }

    // La copia completa vive en la cabecera y la selección parcial en la región
    // exterior. El Markdown permanece como texto normal: ningún párrafo crea un
    // EditableText que pueda mover el scroll al mostrar sus tiradores.
    return ChatMessageSelectionArea(
      enabled: !isStreaming,
      selectionIdentity: metadata['message_id'] ?? metadata['id'] ?? metadata,
      child: Padding(
        padding: EdgeInsets.only(
          left: 12,
          right: 16,
          top: showHeader ? (compact ? 5 : 11) : 0,
          bottom: showFooter ? (compact ? 1 : 3) : 0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showHeader)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    // La Companion local representa a Hermes Console, no al
                    // perfil manager de una Mission Room. Mostrarla junto a
                    // `@manager` atribuiría una identidad falsa. Las salas
                    // usarán aquí el avatar/PetDex profile-aware cuando el
                    // Gateway lo entregue; hasta entonces conservan la etiqueta
                    // textual honesta.
                    if (roomManagerProfile == null)
                      Builder(
                        builder: (ctx) {
                          final app = ctx
                              .findAncestorStateOfType<HermesAppState>();
                          if (app == null) return const SizedBox.shrink();
                          final mood = isStreaming
                              ? HermesSparkMood.thinking
                              : HermesSparkMood.idle;
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: CompanionMessagePresence(
                              companion: app.companion,
                              mood: mood,
                              size: 32,
                            ),
                          );
                        },
                      ),
                    Expanded(
                      child: Text(
                        roomManagerProfile == null
                            ? '>_ ${agentName.toUpperCase()}'
                            : '@$roomManagerProfile',
                        key: roomManagerProfile == null
                            ? null
                            : const ValueKey('mission-room-assistant-label'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: roomManagerProfile == null ? 12.5 : 13.5,
                          fontWeight: FontWeight.w700,
                          color: colors.accent,
                          letterSpacing: roomManagerProfile == null ? 0.5 : 0,
                        ),
                      ),
                    ),
                    if (onSpeak != null && readAloudMessageKey != null) ...[
                      const SizedBox(width: 6),
                      ReadAloudButton(
                        messageKey: readAloudMessageKey!,
                        state: readAloud,
                        stopBehavior: readAloudStopBehavior,
                        onPressed: onSpeak,
                      ),
                    ],
                    Semantics(
                      button: true,
                      label: Strings.of(context).chaCopyMessage,
                      excludeSemantics: true,
                      child: Tooltip(
                        message: Strings.of(context).chaCopyMessage,
                        child: InkWell(
                          onTap: () {
                            // Copia la respuesta final (sin el razonamiento `<think>`);
                            // si solo hubo razonamiento, copia el contenido íntegro.
                            Clipboard.setData(
                              ClipboardData(
                                text: markdownToClipboardText(
                                  answer.isNotEmpty ? answer : content,
                                ),
                              ),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(Strings.of(context).chaCopied),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(24),
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: Center(
                              child: Icon(
                                Icons.copy_rounded,
                                size: 16,
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (onRegenerate != null)
                      Semantics(
                        button: true,
                        label: Strings.of(context).chaRegenerate,
                        excludeSemantics: true,
                        child: Tooltip(
                          message: Strings.of(context).chaRegenerate,
                          child: InkWell(
                            onTap: onRegenerate,
                            borderRadius: BorderRadius.circular(24),
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: Center(
                                child: Icon(
                                  Icons.refresh_rounded,
                                  size: 18,
                                  color: colors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (showHeader && metaLines.isNotEmpty)
              _MetaBlock(lines: metaLines, onDark: false),
            // Razonamiento del modelo (`<think>…`) como bloque discreto y plegado,
            // separado de la respuesta final. Solo aparece si lo hay.
            if (showHeader && split.hasReasoning)
              ReasoningBlock(
                reasoning: split.reasoning,
                inProgress: split.reasoningInProgress,
              ),
            if (answer.isNotEmpty) ...answerWidgets(),
            if (showFooter && technicalDetails.isNotEmpty)
              _AssistantTechnicalDetails(details: technicalDetails),
            if (showFooter && suggestionProjection.hasSuggestions)
              HermesSuggestions(
                suggestions: suggestionProjection.suggestions,
                onSelected: onSuggestionSelected!,
              ),
            if (showFooter && metadata['show_link_preview'] == true)
              Builder(
                builder: (ctx) {
                  final first = firstUrl(answer);
                  if (first == null) return const SizedBox.shrink();
                  return _LinkPreviewLoader(
                    url: first,
                    linkCache: linkCache,
                    fetchLinkPreview: fetchLinkPreview,
                  );
                },
              ),
            if (showFooter && timestamp != null) _MessageTimestamp(timestamp),
          ],
        ),
      ),
    );
  }
}

/// IDs y envelopes operativos conservados bajo demanda.
///
/// La respuesta cotidiana muestra etiquetas humanas. Este disclosure permite
/// diagnosticar o copiar los valores originales sin convertirlos en el
/// headline del mensaje ni depender de selección de texto inestable.
class _AssistantTechnicalDetails extends StatefulWidget {
  final List<String> details;

  const _AssistantTechnicalDetails({required this.details});

  @override
  State<_AssistantTechnicalDetails> createState() =>
      _AssistantTechnicalDetailsState();
}

class _AssistantTechnicalDetailsState
    extends State<_AssistantTechnicalDetails> {
  bool _expanded = false;

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: widget.details.join('\n')));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(Strings.of(context).chaCopied),
        duration: const Duration(milliseconds: 900),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            label: strings.ieTechnicalDetails,
            excludeSemantics: true,
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.terminal_rounded,
                        size: 15,
                        color: colors.textDisabled,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        strings.ieTechnicalDetails,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 160),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 17,
                          color: colors.textDisabled,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 22, right: 2, bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: SingleChildScrollView(
                        primary: false,
                        child: Text(
                          widget.details.join('\n'),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            height: 1.45,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: strings.chaCopyMessage,
                    excludeSemantics: true,
                    child: IconButton(
                      onPressed: () => _copy(context),
                      tooltip: strings.chaCopyMessage,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: Icon(
                        Icons.copy_rounded,
                        size: 15,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MessageTimestamp extends StatelessWidget {
  final String value;

  const _MessageTimestamp(this.value);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
      child: Text(
        value,
        // A-202 (spec 028): timestamps en mono (§8/§3); A-112: textSecondary
        // para que el texto informativo llegue a 4.5:1.
        style: TextStyle(
          fontSize: 10,
          fontFamily: 'monospace',
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

class _MetaBlock extends StatelessWidget {
  final List<String> lines;
  final bool onDark;
  const _MetaBlock({required this.lines, required this.onDark});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        // Ambas burbujas son oscuras ahora; el bloque meta se distingue por
        // un velo negro sutil en las dos variantes.
        color: Colors.black.withValues(alpha: onDark ? 0.25 : 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: lines
            .map(
              (l) => Text(
                l,
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            )
            .toList(),
      ),
    );
  }
}
