// ActiveChatService: the singleton registry that owns every live ActiveChat
// above the Navigator, so a turn keeps running when its screen closes.
// ignore_for_file: prefer_initializing_formals
part of 'active_chat_service.dart';

class _HomeWidgetChatMetadata {
  _HomeWidgetChatMetadata.fromSession(Session session)
    : model = _nonEmpty(session.model),
      inputTokens = session.inputTokens,
      outputTokens = session.outputTokens,
      cacheReadTokens = session.cacheReadTokens,
      cacheWriteTokens = session.cacheWriteTokens,
      lastActivityAtMs = (session.lastActivityAt * 1000).round(),
      isUnpersistedMobileDraft = session.isUnpersistedMobileDraft;

  String? model;
  String? provider;
  int inputTokens;
  int outputTokens;
  int? cacheReadTokens;
  int? cacheWriteTokens;
  int lastActivityAtMs;
  bool isUnpersistedMobileDraft;
  bool hasContextSnapshot = false;
  int? contextUsed;
  int? contextMax;
  int? contextPercent;

  void refresh(Session session) {
    model = _nonEmpty(session.model) ?? model;
    inputTokens = session.inputTokens;
    outputTokens = session.outputTokens;
    cacheReadTokens = session.cacheReadTokens;
    cacheWriteTokens = session.cacheWriteTokens;
    lastActivityAtMs = (session.lastActivityAt * 1000).round();
    isUnpersistedMobileDraft = session.isUnpersistedMobileDraft;
  }

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

/// Registro de chats con streaming activo. Singleton vivo en HermesAppState.
class ActiveChatService {
  ActiveChatService({
    this.notifications,
    this.policy,
    SharedPreferences? prefs,
    CancelledTurnTombstoneStore? cancelledTurnStore,
  }) : _prefs = prefs,
       _cancelledTurnStore = cancelledTurnStore {
    _restoreObservedFirstTokenLatencies();
    unawaited(_drainPendingCancelledTurnCleanup());
  }

  final NotificationService? notifications;

  /// Política de aprobaciones compartida. Inyectada para que el auto-approval
  /// (YOLO / reglas guardadas) ocurra en la capa de servicio, no en la pantalla.
  final ApprovalPolicyService? policy;

  /// Prefs para registrar runs en RunRegistry cuando se inician desde el chat.
  /// Si es null (p.ej. en tests), el registro se omite sin efecto secundario.
  final SharedPreferences? _prefs;
  final CancelledTurnTombstoneStore? _cancelledTurnStore;

  final Map<String, ActiveChat> _chats = {};
  final Map<String, List<SteerProjection>> _steerProjectionCache = {};
  final Map<ActiveChat, _HomeWidgetChatMetadata> _homeWidgetMetadata = {};
  final LinkedHashMap<String, int> _observedFirstTokenLatencyCache =
      LinkedHashMap<String, int>();
  static const _observedFirstTokenLatencyPrefsKey =
      'active_chat_observed_ttft_v1';
  HermesHomeWidgetPublisher? _homeWidgetPublisher;
  String? _homeWidgetActiveConnectionId;
  HermesHomeWidgetSnapshot? _lastHomeWidgetSemantic;

  static String chatKey(String connectionId, String sessionId) =>
      '$connectionId::$sessionId';

  static const _pendingCancelledTurnCleanupKey =
      'cancelled_turn_cleanup_pending_v1';
  Future<void> _cleanupMutation = Future<void>.value();

  Future<void> _enqueueCancelledTurnCleanup(List<String> command) {
    final prefs = _prefs;
    if (prefs == null) return Future<void>.value();
    final operation = _cleanupMutation.then((_) async {
      final encoded = jsonEncode(command);
      final pending =
          prefs.getStringList(_pendingCancelledTurnCleanupKey) ?? [];
      if (!pending.contains(encoded)) pending.add(encoded);
      await prefs.setStringList(_pendingCancelledTurnCleanupKey, pending);
    });
    _cleanupMutation = operation.catchError((_) {});
    return operation;
  }

  Future<void> _drainPendingCancelledTurnCleanup() {
    final operation = _cleanupMutation.then((_) async {
      final prefs = _prefs;
      final store = _cancelledTurnStore;
      if (prefs == null || store == null) return;
      final pending =
          prefs.getStringList(_pendingCancelledTurnCleanupKey) ?? [];
      if (pending.isEmpty) return;
      final remaining = <String>[];
      for (final encoded in pending) {
        try {
          final command = jsonDecode(encoded);
          if (command is! List || command.isEmpty) continue;
          if (command.first == 'session' && command.length == 4) {
            await store.removeSession(
              connectionId: command[1] as String,
              profile: command[2] as String,
              sessionId: command[3] as String,
            );
          } else if (command.first == 'connection' && command.length == 2) {
            await store.removeConnection(command[1] as String);
          }
        } catch (_) {
          remaining.add(encoded);
        }
      }
      await prefs.setStringList(_pendingCancelledTurnCleanupKey, remaining);
    });
    _cleanupMutation = operation.catchError((_) {});
    return operation;
  }

  Future<int> clearCancelledTurnsForSession({
    required String connectionId,
    required String profile,
    required String sessionId,
  }) async {
    final owner = Session.profileOwner(profile);
    final scopeIds = <String>{sessionId};
    final matchingChats = <ActiveChat>[];
    for (final chat in _chats.values) {
      if (chat.connection.id != connectionId || chat.sessionProfile != owner) {
        continue;
      }
      final aliases = <String>{
        chat.sessionId,
        chat.serverSessionId,
        chat.logicalSessionId,
      };
      if (!aliases.contains(sessionId)) continue;
      matchingChats.add(chat);
      scopeIds.addAll(aliases);
    }

    var removed = 0;
    Object? firstError;
    StackTrace? firstStack;
    for (final scopeId in scopeIds) {
      try {
        removed +=
            await _cancelledTurnStore?.removeSession(
              connectionId: connectionId,
              profile: owner,
              sessionId: scopeId,
            ) ??
            0;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
        await _enqueueCancelledTurnCleanup([
          'session',
          connectionId,
          owner,
          scopeId,
        ]);
      }
    }
    for (final chat in matchingChats) {
      chat.clearCancelledTurnTombstones();
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
    return removed;
  }

  Future<int> clearCancelledTurnsForConnection(String connectionId) async {
    var removed = 0;
    try {
      removed = await _cancelledTurnStore?.removeConnection(connectionId) ?? 0;
    } catch (_) {
      await _enqueueCancelledTurnCleanup(['connection', connectionId]);
      rethrow;
    } finally {
      for (final entry in _chats.entries) {
        try {
          final parts = jsonDecode(entry.key);
          if (parts is List &&
              parts.isNotEmpty &&
              parts.first == connectionId) {
            entry.value.clearCancelledTurnTombstones();
          }
        } catch (_) {
          if (entry.key.startsWith('$connectionId::')) {
            entry.value.clearCancelledTurnTombstones();
          }
        }
      }
    }
    return removed;
  }

  static String _registryKey(
    String connectionId,
    String sessionId,
    String profile,
  ) => jsonEncode(<String>[
    connectionId,
    Session.profileOwner(profile),
    sessionId,
  ]);

  static String _legacyChatKey(String connectionId, String sessionId) =>
      '$connectionId::$sessionId';

  int? _cachedObservedFirstTokenLatencyMs(
    String connectionId,
    String sessionId, {
    required String profile,
  }) {
    final owner = Session.profileOwner(profile);
    final current =
        _observedFirstTokenLatencyCache[_registryKey(
          connectionId,
          sessionId,
          owner,
        )];
    if (current != null) return current;
    // Las versiones anteriores no sellaban el perfil. Solo `default` puede
    // adoptar esa métrica: aplicarla a un owner alternativo mezclaría chats
    // que comparten ids entre perfiles.
    if (owner != 'default') return null;
    return _observedFirstTokenLatencyCache[_legacyChatKey(
      connectionId,
      sessionId,
    )];
  }

  String _projectionKey(
    String connectionId,
    String sessionId, {
    required String profile,
  }) => _registryKey(connectionId, sessionId, profile);

  /// Condición extra para NO bajar el foreground service aunque no haya runs en
  /// curso. La usa el modo voz: mientras el TTS sigue hablando en 2º plano tras
  /// completar el run, el proceso debe seguir vivo o el SO cortaría la voz a
  /// media frase. La cablea HermesAppState con el estado del VoiceConversation.
  bool Function()? keepAliveWhile;

  /// Reevalúa si procede bajar el foreground service (lo llama el modo voz cuando
  /// el TTS deja de hablar en 2º plano: ya no hay nada que mantener vivo).
  Future<void> maybeReleaseForeground() => _maybeStopForeground();

  /// Identidades `conexión + perfil + sesión` con un stream EN CURSO.
  ///
  /// Las superficies lo observan como señal de invalidación y consultan
  /// [isActive] para resolver el estado. Incluir el perfil garantiza que el fin
  /// de A notifique aunque B conserve el mismo sessionId en otro owner.
  final ValueNotifier<Set<String>> activeIds = ValueNotifier<Set<String>>({});

  /// Conecta la salida no sensible hacia Glance. El servicio sigue siendo el
  /// único reducer del estado vivo del chat; la app solo conserva la parte base
  /// (instancia, salud y tema) del snapshot.
  void bindHomeWidgetPublisher(
    HermesHomeWidgetPublisher publisher, {
    required String? activeConnectionId,
  }) {
    _homeWidgetPublisher = publisher;
    _homeWidgetActiveConnectionId = activeConnectionId;
    _lastHomeWidgetSemantic = null;
  }

  /// Cambiar de instancia invalida inmediatamente toda identidad y métrica de
  /// la sesión anterior. Los eventos tardíos se ignoran por connection id.
  Future<void> setHomeWidgetActiveConnection(String? connectionId) async {
    if (_homeWidgetActiveConnectionId == connectionId) return;
    _homeWidgetActiveConnectionId = connectionId;
    _lastHomeWidgetSemantic = null;
    final publisher = _homeWidgetPublisher;
    if (publisher == null) return;
    try {
      await publisher.update(
        (current) => current.copyWith(
          clearModel: true,
          clearProvider: true,
          clearSessionId: true,
          clearSessionTitle: true,
          agentState: HomeWidgetAgentState.disconnected,
          clearToolName: true,
          clearContextUsed: true,
          clearContextMax: true,
          clearContextPercent: true,
          clearInputTokens: true,
          clearOutputTokens: true,
          clearCacheReadTokens: true,
          clearCacheWriteTokens: true,
          clearFirstTokenLatencyMs: true,
          clearLastActivityAtMs: true,
        ),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[home-widget] session clear unavailable (${error.runtimeType})',
        );
      }
    }
  }

  MapEntry<String, ActiveChat>? _entryFor(
    String connectionId,
    String sessionId, {
    String? profile,
  }) {
    final owner = profile == null ? null : Session.profileOwner(profile);
    if (owner != null) {
      final key = _registryKey(connectionId, sessionId, owner);
      final direct = _chats[key];
      if (direct != null) return MapEntry(key, direct);
    }
    MapEntry<String, ActiveChat>? match;
    for (final entry in _chats.entries) {
      final chat = entry.value;
      if (chat.connection.id != connectionId ||
          (owner != null && chat.sessionProfile != owner) ||
          (chat.sessionId != sessionId && chat.storedSessionId != sessionId)) {
        continue;
      }
      // Sin perfil explícito nunca elegimos arbitrariamente entre dos homes.
      // Los payloads legacy deben resolver primero su Session autoritativa.
      if (match != null && !identical(match.value, chat)) return null;
      match = entry;
    }
    return match;
  }

  /// Devuelve el chat activo por su ID móvil o por el ID persistido de Hermes.
  ActiveChat? of(String connectionId, String sessionId, {String? profile}) =>
      _entryFor(connectionId, sessionId, profile: profile)?.value;

  /// ¿La sesión tiene un stream en curso?
  bool isActive(String connectionId, String sessionId, {String? profile}) {
    if (profile == null) {
      // Uso de indicador únicamente: sin perfil no elegimos un chat ni
      // devolvemos contenido, pero sí podemos afirmar si cualquiera de los
      // owners con ese id sigue ejecutándose.
      return _chats.values.any(
        (chat) =>
            chat.connection.id == connectionId &&
            (chat.sessionId == sessionId ||
                chat.storedSessionId == sessionId) &&
            chat.isStreaming,
      );
    }
    return _entryFor(
          connectionId,
          sessionId,
          profile: profile,
        )?.value.isStreaming ??
        false;
  }

  int? observedFirstTokenLatencyMs(
    String connectionId,
    String sessionId, {
    String? profile,
  }) {
    final chat = of(connectionId, sessionId, profile: profile);
    if (chat != null) return chat.observedFirstTokenLatencyMs;
    return _cachedObservedFirstTokenLatencyMs(
      connectionId,
      sessionId,
      profile: Session.profileOwner(profile),
    );
  }

  void _restoreObservedFirstTokenLatencies() {
    final raw = _prefs?.getString(_observedFirstTokenLatencyPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String &&
            key.isNotEmpty &&
            key.length <= 520 &&
            value is int &&
            value >= 0) {
          _observedFirstTokenLatencyCache[key] = value;
        }
      }
      while (_observedFirstTokenLatencyCache.length > 128) {
        _observedFirstTokenLatencyCache.remove(
          _observedFirstTokenLatencyCache.keys.first,
        );
      }
    } catch (_) {
      // Métrica local opcional: datos antiguos/corruptos no bloquean el chat.
    }
  }

  Future<void> _persistObservedFirstTokenLatencies() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(
      _observedFirstTokenLatencyPrefsKey,
      jsonEncode(_observedFirstTokenLatencyCache),
    );
  }

  void _rememberObservedFirstTokenLatency(ActiveChat chat, int? latencyMs) {
    final ids = <String>{chat.sessionId, chat.logicalSessionId};
    final storedId = chat.storedSessionId;
    if (storedId != null && storedId.isNotEmpty) ids.add(storedId);
    final owner = Session.profileOwner(chat.sessionProfile);
    for (final id in ids) {
      final key = _registryKey(chat.connection.id, id, owner);
      if (latencyMs == null) {
        _observedFirstTokenLatencyCache.remove(key);
      } else {
        _observedFirstTokenLatencyCache.remove(key);
        _observedFirstTokenLatencyCache[key] = latencyMs;
      }
      if (owner == 'default') {
        _observedFirstTokenLatencyCache.remove(
          _legacyChatKey(chat.connection.id, id),
        );
      }
    }
    while (_observedFirstTokenLatencyCache.length > 128) {
      _observedFirstTokenLatencyCache.remove(
        _observedFirstTokenLatencyCache.keys.first,
      );
    }
    unawaited(_persistObservedFirstTokenLatencies());
  }

  /// Refresca selección local de modelo/proveedor sin publicar desde la UI.
  /// La proyección final siempre se reduce aquí junto al runtime autoritativo.
  void updateHomeWidgetSessionMetadata(
    ActiveChat chat, {
    Session? session,
    String? model,
    String? provider,
  }) {
    final metadata = _homeWidgetMetadata[chat];
    if (metadata == null) return;
    if (session != null) metadata.refresh(session);
    final normalizedModel = _nonEmptyWidgetText(model);
    final normalizedProvider = _nonEmptyWidgetText(provider);
    if (normalizedModel != null && normalizedModel != 'hermes-agent') {
      metadata.model = normalizedModel;
    }
    if (normalizedProvider != null && normalizedProvider != 'gateway') {
      metadata.provider = normalizedProvider;
    }
    _publishHomeWidgetChat(chat);
  }

  /// Mirrors the exact context projection already accepted by ChatScreen.
  /// Values may be null to represent the same honest unknown state; this
  /// reducer never estimates occupancy from cumulative token counters.
  void updateHomeWidgetSessionContext(
    ActiveChat chat, {
    required int? contextUsed,
    required int? contextMax,
    required int? contextPercent,
  }) {
    final metadata = _homeWidgetMetadata[chat];
    if (metadata == null) return;
    metadata
      ..hasContextSnapshot = true
      ..contextUsed = contextUsed
      ..contextMax = contextMax
      ..contextPercent = contextPercent;
    _publishHomeWidgetChat(chat);
  }

  void _onHomeWidgetChatEvent(ActiveChat chat, ActiveChatEvent event) {
    _publishHomeWidgetChat(chat, event: event);
  }

  HomeWidgetAgentState _homeWidgetAgentState(
    ActiveChat chat,
    ActiveChatEvent? event,
  ) {
    if (event == ActiveChatEvent.error) return HomeWidgetAgentState.error;
    if (event == ActiveChatEvent.done || event == ActiveChatEvent.cancelled) {
      return HomeWidgetAgentState.idle;
    }
    if (event == ActiveChatEvent.token) return HomeWidgetAgentState.streaming;
    if (event == ActiveChatEvent.toolProgress ||
        event == ActiveChatEvent.subagentActivity) {
      return HomeWidgetAgentState.toolExecution;
    }
    if (event == ActiveChatEvent.started ||
        event == ActiveChatEvent.connected ||
        event == ActiveChatEvent.waiting) {
      return HomeWidgetAgentState.thinking;
    }
    if (chat.needsInput ||
        event == ActiveChatEvent.approvalRequest ||
        event == ActiveChatEvent.interactiveRequest) {
      return HomeWidgetAgentState.waitingApproval;
    }
    return switch (chat.state) {
      ChatPipelineState.connecting ||
      ChatPipelineState.waiting => HomeWidgetAgentState.thinking,
      ChatPipelineState.executing => HomeWidgetAgentState.toolExecution,
      ChatPipelineState.streaming => HomeWidgetAgentState.streaming,
      ChatPipelineState.failed => HomeWidgetAgentState.error,
      ChatPipelineState.idle ||
      ChatPipelineState.completed ||
      ChatPipelineState.cancelled => HomeWidgetAgentState.idle,
    };
  }

  String? _runningHomeWidgetTool(ActiveChat chat) {
    for (final tool in chat.trace.reversed) {
      if (tool.status == 'running') return _nonEmptyWidgetText(tool.label);
    }
    return null;
  }

  bool _homeWidgetEventTouchesActivity(
    ActiveChat chat,
    ActiveChatEvent? event,
  ) => switch (event) {
    ActiveChatEvent.started ||
    ActiveChatEvent.connected ||
    ActiveChatEvent.waiting ||
    ActiveChatEvent.token ||
    ActiveChatEvent.toolProgress ||
    ActiveChatEvent.approvalRequest ||
    ActiveChatEvent.interactiveRequest ||
    ActiveChatEvent.subagentActivity ||
    ActiveChatEvent.done ||
    ActiveChatEvent.error ||
    ActiveChatEvent.cancelled => true,
    ActiveChatEvent.sessionInfo => chat.isStreaming,
    _ => false,
  };

  void _publishHomeWidgetChat(ActiveChat chat, {ActiveChatEvent? event}) {
    final publisher = _homeWidgetPublisher;
    final metadata = _homeWidgetMetadata[chat];
    if (publisher == null ||
        metadata == null ||
        chat.connection.id != _homeWidgetActiveConnectionId) {
      return;
    }
    // A draft created by the composer is not addressable through Hermes yet.
    // Publishing its provisional mob-* id would replace the last real session
    // and make the widget's Return action point at a non-existent REST record.
    if (metadata.isUnpersistedMobileDraft &&
        chat.storedSessionId == null &&
        chat.serverSessionId.startsWith('mob-')) {
      return;
    }
    final current = publisher.latest;
    final usage = chat.desktopRuntimeInfo.usage;
    final runtimeModel = _nonEmptyWidgetText(chat.desktopRuntimeInfo.model);
    final turnModel = _nonEmptyWidgetText(chat._lastModel);
    final runtimeProvider = _nonEmptyWidgetText(
      chat.desktopRuntimeInfo.provider,
    );
    final sameSession = current.sessionId == chat.serverSessionId;
    final candidateSessionTitle = _meaningfulWidgetSessionTitle(
      chat.sessionTitle,
    );
    final sessionTitle =
        candidateSessionTitle ?? (sameSession ? current.sessionTitle : null);
    final contextUsed = metadata.hasContextSnapshot
        ? metadata.contextUsed
        : usage?.contextUsed ?? (sameSession ? current.contextUsed : null);
    final contextMax = metadata.hasContextSnapshot
        ? metadata.contextMax
        : usage?.contextMax ?? (sameSession ? current.contextMax : null);
    final contextPercent = metadata.hasContextSnapshot
        ? metadata.contextPercent
        : usage?.contextPercent?.round().clamp(0, 100);
    final livePublishesCache =
        usage?.cacheReadTokens != null || usage?.cacheWriteTokens != null;
    final metadataPublishesCache =
        metadata.cacheReadTokens != null || metadata.cacheWriteTokens != null;
    final useMetadataPromptUsage =
        metadataPublishesCache && !livePublishesCache;
    final agentState = _homeWidgetAgentState(chat, event);
    final toolName = agentState == HomeWidgetAgentState.toolExecution
        ? _runningHomeWidgetTool(chat)
        : null;
    final previousSessionActivity = current.sessionId == chat.serverSessionId
        ? current.lastActivityAtMs
        : null;
    var next = HermesHomeWidgetSnapshot(
      configured: true,
      instanceId: chat.connection.id,
      instanceLabel: chat.connection.label,
      connectionState: switch (event) {
        ActiveChatEvent.connected ||
        ActiveChatEvent.waiting ||
        ActiveChatEvent.token ||
        ActiveChatEvent.toolProgress ||
        ActiveChatEvent.approvalRequest ||
        ActiveChatEvent.interactiveRequest ||
        ActiveChatEvent.subagentActivity ||
        ActiveChatEvent.done ||
        ActiveChatEvent.cancelled => HomeWidgetConnectionState.connected,
        ActiveChatEvent.started
            when current.connectionState ==
                HomeWidgetConnectionState.disconnected =>
          HomeWidgetConnectionState.connecting,
        _ => current.connectionState,
      },
      model:
          runtimeModel ??
          (turnModel == 'hermes-agent' ? null : turnModel) ??
          metadata.model,
      provider: runtimeProvider ?? metadata.provider,
      sessionId: chat.serverSessionId,
      sessionTitle: sessionTitle,
      agentState: agentState,
      toolName: toolName,
      contextUsed: contextUsed,
      contextMax: contextMax,
      contextPercent: contextPercent,
      inputTokens: useMetadataPromptUsage
          ? metadata.inputTokens
          : usage?.input ?? metadata.inputTokens,
      outputTokens: usage?.output ?? metadata.outputTokens,
      cacheReadTokens: livePublishesCache
          ? usage?.cacheReadTokens
          : metadata.cacheReadTokens,
      cacheWriteTokens: livePublishesCache
          ? usage?.cacheWriteTokens
          : metadata.cacheWriteTokens,
      firstTokenLatencyMs: chat.observedFirstTokenLatencyMs,
      lastActivityAtMs: previousSessionActivity ?? metadata.lastActivityAtMs,
      theme: current.theme,
      showAdvancedMetrics: current.showAdvancedMetrics,
    );
    var semantic = next.copyWith(updatedAtMs: 0);
    if (semantic == _lastHomeWidgetSemantic) return;
    if (_homeWidgetEventTouchesActivity(chat, event)) {
      next = next.copyWith(
        lastActivityAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      semantic = next.copyWith(updatedAtMs: 0);
    }
    _lastHomeWidgetSemantic = semantic;
    unawaited(_publishHomeWidgetSnapshot(publisher, next));
  }

  Future<void> _publishHomeWidgetSnapshot(
    HermesHomeWidgetPublisher publisher,
    HermesHomeWidgetSnapshot snapshot,
  ) async {
    try {
      await publisher.publish(snapshot);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[home-widget] chat state unavailable (${error.runtimeType})',
        );
      }
    }
  }

  static String? _nonEmptyWidgetText(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String? _meaningfulWidgetSessionTitle(String? value) {
    final normalized = _nonEmptyWidgetText(value);
    if (normalized == null) return null;
    final placeholder = normalized.toLowerCase();
    if (const <String>{
      'untitled',
      'sin titulo',
      'sin título',
      'new session',
      'new conversation',
      'nueva conversacion',
      'nueva conversación',
    }.contains(placeholder)) {
      return null;
    }
    return normalized;
  }

  /// Engancha (o crea) el chat de una sesión. Lo usa la pantalla al abrirse.
  ActiveChat attach({
    required SavedConnection connection,
    required String sessionId,
    String? logicalSessionId,
    required String sessionTitle,
    Session? sessionSnapshot,
    String? sessionProfile,
    String? initialStoredSessionId,
    NotificationChatSurface notificationSurface =
        NotificationChatSurface.normal,
    String? notificationRoomId,
    bool authoritativeStoredSessionBinding = false,
    String? selectedProvider,
    @visibleForTesting ApiClient? api,
    @visibleForTesting HermesDesktopGateway? desktopGateway,
    @visibleForTesting StoredSessionMessageLoader? storedMessageLoader,
    @visibleForTesting Future<bool> Function()? turnIdempotencyCapability,
    @visibleForTesting bool disableForegroundKeepAlive = false,
  }) {
    final owner = Session.profileOwner(
      sessionProfile ?? sessionSnapshot?.profile,
    );
    final key = _registryKey(connection.id, sessionId, owner);
    final existing = of(connection.id, sessionId, profile: owner);
    if (existing != null) {
      if (existing.bindKnownStoredSession(
        initialStoredSessionId,
        authoritative: authoritativeStoredSessionBinding,
      )) {
        // Reabrir el chat retira la petición de liberación que dejó la salida
        // anterior; si no, un hueco sin oyentes podría destruirlo bajo la
        // pantalla recién abierta y dejarla sin eventos.
        existing.cancelReleaseRequest();
        existing.sessionTitle = sessionTitle;
        existing._bindSessionProfile(owner);
        existing.bindNotificationTarget(
          notificationSurface,
          roomId: notificationRoomId,
        );
        final metadata = _homeWidgetMetadata[existing];
        if (sessionSnapshot != null) metadata?.refresh(sessionSnapshot);
        final provider = _nonEmptyWidgetText(selectedProvider);
        if (provider != null && provider != 'gateway') {
          metadata?.provider = provider;
        }
        _publishHomeWidgetChat(existing);
        return existing;
      }
      // Un binding nuevo no puede saltarse una escritura durable en vuelo. La
      // próxima invalidación/attach resolverá la identidad tras el commit.
      if (existing.hasPendingDurableCancellation) return existing;
      // A stable mobile Bot/Room route can be reopened after its authoritative
      // stored id changes. Never retarget an existing runtime; dispose that
      // binding and attach a fresh chat for the new durable identity.
      _dispose(key);
    }
    final tombstoneGeneration = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              connection.id,
              connection.kind.name,
              connection.host,
              connection.port,
              connection.useHttps,
              connection.gatewayAuthMode.storageKey,
              connection.apiKey,
            ]),
          ),
        )
        .toString();
    final cancelledTurnStore = _cancelledTurnStore;
    final initialTombstoneSessionIds = <String>{
      sessionId,
      if (logicalSessionId != null && logicalSessionId.isNotEmpty)
        logicalSessionId,
      if (initialStoredSessionId != null && initialStoredSessionId.isNotEmpty)
        initialStoredSessionId,
    };
    late final ActiveChat chat;
    chat = ActiveChat(
      connection: connection,
      sessionId: sessionId,
      logicalSessionId: logicalSessionId,
      sessionTitle: sessionTitle,
      notificationSurface: notificationSurface,
      notificationRoomId: notificationRoomId,
      sessionProfile: owner,
      initialStoredSessionId: initialStoredSessionId,
      notifications: notifications,
      policy: policy,
      onTerminal: () => _onChatTerminal(key),
      onUnused: () => _onChatUnused(key),
      beforeTerminalNotification: _maybeStopForeground,
      onRunStarted: (runId) => _onRunStarted(key, runId),
      onForegroundKeepAlive: disableForegroundKeepAlive
          ? null
          : () async {
              // Deliberadamente SIN await: este callback corre en el camino
              // del turno, justo antes de prompt.submit. Arrancar el foreground
              // service es una ida al SO que puede tardar cientos de ms, y el
              // prompt no puede esperarla. La lease solo importa cuando la app
              // pasa a 2º plano, mucho después de este punto.
              unawaited(_acquireActiveTurnForeground());
            },
      api: api,
      desktopGateway: desktopGateway,
      storedMessageLoader: storedMessageLoader,
      turnIdempotencyCapability: turnIdempotencyCapability,
      initialObservedFirstTokenLatencyMs: _cachedObservedFirstTokenLatencyMs(
        connection.id,
        sessionId,
        profile: owner,
      ),
      onObservedFirstTokenLatency: (latencyMs) {
        _rememberObservedFirstTokenLatency(chat, latencyMs);
        if (latencyMs != null) {
          _onHomeWidgetChatEvent(chat, ActiveChatEvent.token);
        }
      },
      onEvent: (event) => _onHomeWidgetChatEvent(chat, event),
      initialSteerProjections:
          _steerProjectionCache[_projectionKey(
            connection.id,
            sessionId,
            profile: owner,
          )] ??
          const [],
      // La primera conversación puede cambiar de id al adoptar la sesión
      // durable de Desktop. Restaura la unión exacta de ruta, lineage y stored
      // id para que un Stop confirmado no desaparezca tras reabrir.
      initialCancelledTurnTombstones:
          cancelledTurnStore?.loadAliases(
            connectionId: connection.id,
            profile: owner,
            sessionIds: initialTombstoneSessionIds,
            generation: tombstoneGeneration,
          ) ??
          const [],
      onCancelledTurn: cancelledTurnStore == null
          ? null
          : (tombstone) {
              final aliases = <String>{...initialTombstoneSessionIds};
              final storedId = chat.storedSessionId;
              if (storedId != null && storedId.isNotEmpty) {
                aliases.add(storedId);
              }
              return cancelledTurnStore.addAliases(
                connectionId: connection.id,
                profile: owner,
                sessionIds: aliases,
                tombstone: tombstone,
                generation: tombstoneGeneration,
              );
            },
    );
    _chats[key] = chat;
    final seed =
        sessionSnapshot ??
        Session(
          id: sessionId,
          title: sessionTitle,
          model: '',
          source: 'mobile',
          messageCount: 0,
          isActive: false,
          preview: '',
          startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
        );
    final metadata = _HomeWidgetChatMetadata.fromSession(seed);
    final provider = _nonEmptyWidgetText(selectedProvider);
    if (provider != null && provider != 'gateway') {
      metadata.provider = provider;
    }
    _homeWidgetMetadata[chat] = metadata;
    _publishHomeWidgetChat(chat);
    return chat;
  }

  /// Un run arrancó: registra la vigilancia en 2º plano y levanta el foreground
  /// service. Esto mantiene vivo el proceso (y con él el isolate de UI que
  /// corre el SSE) mientras el agente responde, aunque el usuario salga de la
  /// app, bloquee o apague la pantalla. Si el SO matase el proceso igualmente,
  /// el isolate del servicio sigue sondeando el run y avisa al terminar.
  Future<void> _onRunStarted(String key, String runId) async {
    final chat = _chats[key];
    if (chat == null) return;
    // Registrar en RunRegistry para que Task Center (Ejecuciones) vea los runs
    // lanzados desde el chat, no solo los de RunsTab. Es un añadido puro:
    // si prefs es null (tests) se omite sin efecto. RunRegistry.add es idempotente.
    final prefs = _prefs;
    if (prefs != null) {
      try {
        final registry = await RunRegistry.load(prefs, chat.connection.id);
        await registry.add(
          RunRecord(
            runId: runId,
            prompt: chat.lastPrompt,
            sessionId: chat.sessionId,
            createdAt: DateTime.now().millisecondsSinceEpoch / 1000,
            lastStatus: 'queued',
            connId: chat.connection.id,
            profile: chat.sessionProfile,
          ),
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('ActiveChatService RunRegistry add falló: $e');
        }
      }
    }
    try {
      await BackgroundWatch.add(
        SavedRunWatch(
          connId: chat.connection.id,
          profile: chat.sessionProfile,
          base: chat.connection.baseUrl,
          runId: runId,
          prompt: chat.lastPrompt,
          sessionId: chat.sessionId,
        ),
      );
      await BackgroundListener.ensureAutomationForeground();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ActiveChatService foreground start falló: $e');
      }
    }
    _refreshActiveIds();
  }

  /// Reconciliación global al volver de 2º plano: re-sincroniza cualquier chat
  /// cuyo stream pudiera haberse cortado mientras la app estaba suspendida.
  Future<void> reconcileAfterResume() async {
    for (final chat in _chats.values.toList()) {
      await chat.reconcileAfterResume();
    }
  }

  Future<void> suspendIdleConnections() async {
    await Future.wait(
      _chats.values.map((chat) => chat.suspendIdleDesktopConnection()),
    );
  }

  /// Suelta el chat al cerrar la pantalla: si NO está en streaming, lo libera
  /// (cierra el cliente HTTP); si está en streaming, lo deja correr en segundo
  /// plano (se reaprovechará al volver y se reapará al terminar sin oyentes).
  void release(String connectionId, String sessionId, {String? profile}) {
    final entry = _entryFor(connectionId, sessionId, profile: profile);
    if (entry == null) return;
    final chat = entry.value;
    _rememberSteerProjections(chat);
    chat.requestReleaseWhenUnused();
    if (chat.isStreaming ||
        chat.hasPendingDurableCancellation ||
        chat.hasListeners ||
        chat.voiceBargeHandoffPending) {
      _refreshActiveIds();
      return;
    }
    _dispose(entry.key);
  }

  void _onChatUnused(String key) {
    final chat = _chats[key];
    if (chat == null ||
        !chat.releaseRequested ||
        chat.isStreaming ||
        chat.hasPendingDurableCancellation ||
        chat.hasListeners ||
        chat.voiceBargeHandoffPending) {
      return;
    }
    _dispose(key);
  }

  /// Marca el inicio de un envío: registra la sesión como activa.
  void markStarted(String connectionId, String sessionId) =>
      _refreshActiveIds();

  void _onChatTerminal(String key) {
    final chat = _chats[key];
    if (chat != null) {
      _rememberObservedFirstTokenLatency(
        chat,
        chat.observedFirstTokenLatencyMs,
      );
    }
    _refreshActiveIds();
    // El run terminó: deja de vigilarlo en 2º plano y, si ya no queda ningún
    // run activo, baja el foreground service.
    final runId = chat?.currentRunId;
    if (runId != null && chat != null) {
      BackgroundWatch.remove(
        runId,
        connId: chat.connection.id,
        profile: chat.sessionProfile,
      );
    }
    _maybeStopForeground();
    if (chat == null) return;
    // Si nadie está mirando el chat (la pantalla se cerró), libéralo: el
    // refetch y la notificación ya ocurrieron en onDone.
    if (!chat.isStreaming &&
        !chat.hasPendingDurableCancellation &&
        !chat.hasListeners &&
        !chat.voiceBargeHandoffPending) {
      _dispose(key);
    }
  }

  /// Toma la lease que mantiene vivo el proceso mientras el agente responde.
  ///
  /// Sin ella Android congela el isolate en cuanto la app pasa a 2º plano: el
  /// socket del turno muere sin entregar su cierre, la respuesta se pierde y el
  /// chat se queda "ejecutando" para siempre. Es best-effort — un fallo aquí
  /// nunca puede impedir que el turno arranque.
  Future<void> _acquireActiveTurnForeground() async {
    try {
      await BackgroundListener.setActiveTurnRequired(true);
      await BackgroundListener.ensureAutomationForeground();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ActiveChatService foreground keep-alive falló: $e');
      }
    }
    _refreshActiveIds();
  }

  /// Baja el foreground service salvo que (a) el usuario activó la escucha
  /// permanente opt-in, o (b) aún hay otro run en curso.
  Future<void> _maybeStopForeground() async {
    if (_chats.values.any((c) => c.isStreaming)) return;
    try {
      // Ningún turno sigue vivo: suelta la lease antes que nada. Es idempotente
      // y no puede parar un runtime que la voz o el opt-in permanente aún
      // piden. Va dentro del try: este camino corre desde el terminal del
      // turno, donde un fallo de plataforma no puede propagarse.
      await BackgroundListener.setActiveTurnRequired(false);
      // El modo voz puede seguir hablando en 2º plano tras completar el run.
      if (keepAliveWhile?.call() ?? false) return;
      if (await BackgroundListener.isEnabled()) return;
      await BackgroundListener.releaseIdleRuntime();
    } catch (e) {
      if (kDebugMode) debugPrint('ActiveChatService foreground stop falló: $e');
    }
  }

  void _rememberSteerProjections(ActiveChat chat) {
    final sessionIds = <String>{chat.sessionId};
    final storedId = chat.storedSessionId;
    if (storedId != null && storedId.isNotEmpty) sessionIds.add(storedId);
    final projections = chat.steerProjections;
    for (final id in sessionIds) {
      final key = _projectionKey(
        chat.connection.id,
        id,
        profile: chat.sessionProfile,
      );
      if (projections.isEmpty) {
        _steerProjectionCache.remove(key);
      } else {
        _steerProjectionCache[key] = List<SteerProjection>.of(projections);
      }
    }
    // Memoria acotada: son proyecciones de UI, no un transcript local.
    while (_steerProjectionCache.length > 32) {
      _steerProjectionCache.remove(_steerProjectionCache.keys.first);
    }
  }

  void _dispose(String key) {
    final chat = _chats.remove(key);
    if (chat != null) {
      _homeWidgetMetadata.remove(chat);
      _rememberSteerProjections(chat);
      _rememberObservedFirstTokenLatency(
        chat,
        chat.observedFirstTokenLatencyMs,
      );
    }
    chat?.dispose();
    _refreshActiveIds();
  }

  void _refreshActiveIds() {
    final ids = <String>{};
    for (final entry in _chats.entries) {
      if (!entry.value.isStreaming) continue;
      final profile = entry.value.sessionProfile;
      ids.add(
        _registryKey(entry.value.connection.id, entry.value.sessionId, profile),
      );
      final storedId = entry.value.storedSessionId;
      if (storedId != null && storedId.isNotEmpty) {
        ids.add(_registryKey(entry.value.connection.id, storedId, profile));
      }
    }
    if (ids.length != activeIds.value.length ||
        !ids.containsAll(activeIds.value)) {
      activeIds.value = ids;
    }
  }

  void dispose() {
    unawaited(
      BackgroundListener.setActiveTurnRequired(false).catchError((_) => false),
    );
    for (final chat in _chats.values) {
      chat.dispose();
    }
    _chats.clear();
    _homeWidgetMetadata.clear();
    _observedFirstTokenLatencyCache.clear();
    activeIds.dispose();
  }
}
