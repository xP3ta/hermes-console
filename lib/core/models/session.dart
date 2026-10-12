import '../utils/bot_mention_text.dart';
import 'package:flutter/foundation.dart';

import '../utils/chat_turn.dart';
import '../utils/plain_preview.dart';
import '../utils/session_timestamp.dart';
import 'reference_directive.dart';
import 'session_category.dart';

/// Derived lifecycle state for a session.
///
/// Color mapping (resolved in UI via HermesThemeColors tokens):
///   active   → success
///   idle     → accent
///   stale    → textDisabled
///   archived → textSecondary  (local-only, never returned by [Session.state])
///   broken   → error
///   unknown  → textSecondary
enum SessionState {
  active,
  idle,
  stale,
  archived,
  broken,
  unknown;

  /// Human-readable label in Spanish for display in the UI.
  /// Internal states (idle, stale, unknown, broken) are mapped to user-friendly terms.
  String get label => switch (this) {
    SessionState.active => 'activa',
    SessionState.idle => 'abierta',
    SessionState.stale => 'antigua',
    SessionState.archived => 'archivada',
    SessionState.broken => 'error',
    SessionState.unknown => 'antigua',
  };
}

/// Generic title used when a session has no readable title of its own.
enum SessionGenericTitle { kanbanTask, scheduledTask, conversation }

/// Session model matching the Gateway API Server response format
/// (`_session_response` en api_server.py del upstream — campos client-safe).
class Session implements SessionSortKey {
  @override
  final String id;
  final String title;
  final String model;
  final String source;
  final int messageCount;
  final bool isActive;
  final String preview;

  /// Último turno compacto que el servidor puede incluir en la lista de
  /// sesiones. Son opcionales para seguir aceptando Gateways antiguos.
  final String? lastUserPreview;
  final String? lastAssistantPreview;
  final double startedAt;
  final double? endedAt;

  /// Last activity timestamp. El servidor lo serializa como `last_active`;
  /// se acepta también `updated_at` por compatibilidad con builds antiguas.
  final double? updatedAt;

  /// Motivo de cierre del servidor (p.ej. "branched" tras un fork).
  final String? endReason;

  /// Sesión origen cuando esta es resultado de un fork.
  final String? parentSessionId;

  /// `_branched_from`: set only by a genuine `/branch` fork.
  final String? branchedFromId;

  /// `_reset_from`: set by `/new` and idle/daily rotation, which start a new
  /// conversation rather than a fork.
  final String? resetFromId;

  /// Stable compression lineage identity advertised by Dashboard 0.19.
  final String? lineageRootId;

  /// Every session id of the compression chain projected onto this row
  /// (`_lineage_ids`, root first). A page can name the same conversation by
  /// its root, a middle segment or a later tip.
  final List<String> lineageIds;

  /// The server's `is_internal_child`: a delegate run Desktop folds under its
  /// parent whatever its source. Null when an older server omits it.
  final bool? isInternalChild;

  /// The server's `scheduler_owned` (cron run rows and session detail): the
  /// scheduler still holds this run's in-flight execution. Null when an
  /// older server omits it.
  final bool? schedulerOwned;

  /// Whether the server published `is_active` itself. [isActive] falls back
  /// to `ended_at == null` when it is absent, which is not liveness.
  final bool isActivePublished;
  final String? cwd;
  final String? gitRepoRoot;
  final String? gitBranch;
  final bool archived;
  final bool? pinned;

  /// The server's `hidden` flag (kept off the default sidebar listing on
  /// every surface). Null when the server does not publish it.
  final bool? hidden;

  /// The server's derived read state (`last_read_at` watermark against the
  /// latest activity). Null when the server does not publish it.
  final bool? unread;

  /// The server's `last_read_at` watermark (seconds). Null when the server
  /// does not publish it or never tracked the session (NULL = read there).
  final double? lastReadAt;

  /// A search hit's FTS snippet as the server sent it, with the `>>>`/`<<<`
  /// match delimiters ([preview] has them stripped). Null for list rows.
  final String? searchSnippet;
  final String? profile;
  final bool? isDefaultProfile;
  final String? handoffPlatform;
  final String? handoffState;
  final String? handoffError;

  /// True cuando este dispositivo conserva texto o adjuntos todavía sin
  /// enviar para la sesión. No forma parte del contrato del servidor.
  final bool hasLocalDraft;

  // Métricas reales del servidor. Caché permanece nullable para distinguir un
  // cero publicado por Hermes de un backend que no expone ese campo.
  final int toolCallCount;
  final int inputTokens;
  final bool inputTokensPublished;
  final int outputTokens;
  final bool outputTokensPublished;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final int reasoningTokens;
  final bool reasoningTokensPublished;
  final int apiCallCount;
  final double? estimatedCostUsd;
  final double? actualCostUsd;
  final bool hasSystemPrompt;

  const Session({
    required this.id,
    required this.title,
    required this.model,
    required this.source,
    required this.messageCount,
    required this.isActive,
    required this.preview,
    this.lastUserPreview,
    this.lastAssistantPreview,
    required this.startedAt,
    this.endedAt,
    this.updatedAt,
    this.endReason,
    this.parentSessionId,
    this.branchedFromId,
    this.resetFromId,
    this.lineageRootId,
    this.lineageIds = const [],
    this.isInternalChild,
    this.schedulerOwned,
    this.isActivePublished = false,
    this.cwd,
    this.gitRepoRoot,
    this.gitBranch,
    this.archived = false,
    this.pinned,
    this.hidden,
    this.unread,
    this.lastReadAt,
    this.searchSnippet,
    this.profile,
    this.isDefaultProfile,
    this.handoffPlatform,
    this.handoffState,
    this.handoffError,
    this.hasLocalDraft = false,
    this.toolCallCount = 0,
    this.inputTokens = 0,
    this.inputTokensPublished = false,
    this.outputTokens = 0,
    this.outputTokensPublished = false,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.reasoningTokens = 0,
    this.reasoningTokensPublished = false,
    this.apiCallCount = 0,
    this.estimatedCostUsd,
    this.actualCostUsd,
    this.hasSystemPrompt = false,
  });

  /// Perfil propietario estable de una conversación.
  ///
  /// Hermes Desktop trata `default` como una identidad explícita: omitirla en
  /// un resume permite que el Gateway use el perfil global que esté activo en
  /// ese instante. Los borradores antiguos sin sello capturan una sola vez el
  /// fallback recibido y desde entonces el binding conserva este valor.
  /// Someone read this session on the server after its latest activity:
  /// it is not unread and carries a real watermark. A NULL watermark means
  /// "never tracked" (Hermes reads it as read), which says nothing about
  /// whether anyone saw the latest reply.
  bool get readOnServer => unread == false && (lastReadAt ?? 0) > 0;

  static String profileOwner(String? profile, {String? fallback}) {
    final owner = profile?.trim();
    if (owner != null && owner.isNotEmpty) return owner;
    final candidate = fallback?.trim();
    return candidate == null || candidate.isEmpty ? 'default' : candidate;
  }

  String get logicalId => lineageRootId ?? id;

  /// Every id this row answers to: its live id, its lineage root and each
  /// compression segment (Desktop's `tombstoneRowIds`).
  Set<String> get identityIds =>
      {id, ?lineageRootId, ...lineageIds}..remove('');

  /// Chat que todavía existe únicamente como borrador cifrado en el móvil.
  bool get isDraftOnly => source == 'mobile-draft';

  /// Sesión creada por la UI que aún no puede existir en `state.db`.
  ///
  /// Las rutas históricas etiquetaban estos chats como `mobile-draft`, pero
  /// las rutas actuales crean un id provisional `mob-*` con `source: mobile`.
  /// En ambos casos abrir el composer no debe pagar un `session.resume`/REST
  /// destinado a fallar: la sesión se crea de forma nativa en el primer envío.
  ///
  /// Compartir desde Android (`source: android-share`) sella el texto recibido
  /// en `preview` antes de que exista ningún turno, así que ahí la única
  /// evidencia durable posible es `messageCount`: exigir un preview vacío o un
  /// id `mob-*` dejaría el caso común (compartir texto) pagando el 4007.
  bool get isUnpersistedMobileDraft =>
      isDraftOnly ||
      (source == 'android-share' && messageCount == 0) ||
      ((source == 'mobile' ||
              source == 'mobile-room' ||
              source == 'mobile-bot') &&
          messageCount == 0 &&
          id.startsWith('mob-') &&
          preview.trim().isEmpty);

  /// Título a mostrar: el del servidor si es real, o uno autogenerado a partir
  /// de las primeras palabras del primer mensaje ([preview]) cuando el servidor
  /// devuelve un placeholder ("Untitled"/"New Chat"/vacío). Los overrides
  /// locales (renombrado manual) los aplica `SessionArchive.titleFor` por encima.
  ///
  /// Generic fallbacks are in Spanish here (the source language) for callers
  /// without a locale; UI surfaces use `localizedSessionTitle`.
  String get displayTitle => titleWith(
    (kind) => switch (kind) {
      SessionGenericTitle.kanbanTask => 'Tarea del Kanban',
      SessionGenericTitle.scheduledTask => 'Tarea programada',
      SessionGenericTitle.conversation => 'Conversación',
    },
  );

  /// [displayTitle] with the generic fallback titles supplied by [generic],
  /// so the UI can localize them.
  String titleWith(String Function(SessionGenericTitle kind) generic) {
    // Worker del Kanban: el dispatcher la nombra/arranca con "work kanban
    // task t_<id>" (id crudo, no dice de qué tarea vino). Título humano.
    if (isKanbanJob) return generic(SessionGenericTitle.kanbanTask);
    // Bot routines store their owner as a technical `[bot:<name>]` prefix.
    final humanizedTitle = _humanizeTitle(
      stripBotMentionNote(title),
    ).replaceFirst(_botRoutinePrefix, '');
    final syntheticTodoTitle = _looksSyntheticTodoTitle(
      humanizedTitle,
      preview,
    );
    if (!isPlaceholderTitle(humanizedTitle) &&
        !_looksInternalTitle(humanizedTitle) &&
        !syntheticTodoTitle) {
      return humanizedTitle;
    }
    // Invocación de skill: el "mensaje" es un blob de sistema; el título limpio
    // es el nombre de la skill, no "IMPORTANT The user has invoked the…".
    final skill = invokedSkill;
    if (skill != null) return skill;
    final generated = titleFromText(cleanPreview);
    if (generated.isNotEmpty) return generated;
    // Job/skill sin contenido legible (preview = solo preámbulo, a veces
    // truncado por el servidor): título genérico, no el preámbulo crudo.
    if (isJob) return generic(SessionGenericTitle.scheduledTask);
    if (_looksInternalTitle(humanizedTitle) || syntheticTodoTitle) {
      return generic(SessionGenericTitle.conversation);
    }
    return title;
  }

  /// ¿Es una sesión de job/cron/skill programada? El servidor las marca con
  /// `source: "cron"` y/o las nombra `cron_<jobid>_<timestamp>` (009-jobs).
  bool get isJob => id.startsWith('cron_') || source == 'cron';

  /// Automation run (Cron, Kanban worker, tool, subagent, webhook, one-shot…)
  /// versus a normal chat. Decided ONLY by the server's `source`, as Desktop's
  /// sidebar does (`SIDEBAR_EXCLUDED_SOURCES`): the same field the library's
  /// `sources`/`exclude_sources` query filters on, so Home, the drawer, the
  /// Chats/Automation tabs and the history cleanup can never disagree.
  bool get isAutomation => AutomationSessionSources.contains(source);

  /// Whether this row is its own entry in a session list (Home recents,
  /// Conversations, drawer), one rule for every screen.
  ///
  /// The server's `is_internal_child` decides first, as in the Desktop
  /// sidebar (store/session.ts): an internal child (a delegate run, whatever
  /// its source) is always folded under its parent. Otherwise a root always
  /// is its own row, and a child (`parent_session_id`) is when a person
  /// chats in it: Hermes lists `/branch` and reset children as their own
  /// rows and Desktop shows them. Automation children (cron, Kanban) stay
  /// folded. Only when an older server omits `is_internal_child` does the
  /// source tell a chat child from a delegate run (`subagent`), a tool
  /// session or an unclassified child, which stay folded. Compression
  /// continuations never arrive as separate rows: the server projects them
  /// onto one row carrying `_lineage_root_id`.
  bool get listsAsOwnRow {
    if (isInternalChild == true) return false;
    final parent = parentSessionId?.trim();
    if (parent == null || parent.isEmpty) return true;
    if (isJob || isKanbanJob) return false;
    if (isInternalChild == false) return true;
    final kind = source.trim();
    return kind.isNotEmpty && SessionCategory.chats.includesSource(kind);
  }

  /// Identificador del cron que originó esta sesión.
  ///
  /// Hermes crea las ejecuciones como `cron_<jobId>_<yyyyMMdd>_<HHmmss>`;
  /// versiones anteriores pueden conservar solo la fecha.
  /// El job id se captura de forma codiciosa para tolerar ids con guiones bajos.
  /// Una sesión marcada solo con `source: cron` puede no conservar el vínculo;
  /// en ese caso devolvemos null y la UI no debe fingir que detuvo el job.
  String? get cronJobId {
    final match = RegExp(r'^cron_(.+)_\d{8}(?:_\d{6})?$').firstMatch(id);
    final value = match?.group(1)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// Sesión lanzada por el dispatcher del Kanban: se nombra/arranca con el
  /// prompt interno `work kanban task t_<id>`.
  static final RegExp _kanbanWorkRe = RegExp(
    r'^\s*work kanban task\s+t_\w+',
    caseSensitive: false,
  );
  bool get isKanbanJob =>
      _kanbanWorkRe.hasMatch(title) || _kanbanWorkRe.hasMatch(preview);

  /// Nombre de la skill si esta sesión es una INVOCACIÓN de skill (el primer
  /// "mensaje" es el blob de sistema con el YAML de la skill), o null.
  String? get invokedSkill {
    final m = RegExp(
      r'invoked the "([^"]+)" skill',
      caseSensitive: false,
    ).firstMatch(preview);
    return m?.group(1);
  }

  /// Preview SIN preámbulos internos ni sintaxis Markdown visible.
  /// Para sesiones del Kanban, el preview es el prompt interno crudo: se oculta.
  String get cleanPreview {
    if (isKanbanJob ||
        _looksAsyncDelegationCarrier(preview) ||
        isBackgroundProcessBackendPreview(preview) ||
        isBackgroundProcessFlattenedPreview(preview)) {
      return '';
    }
    return plainPreview(
      plainReferencePreview(
        stripCronPreamble(
          stripBackgroundProcessCarrier(stripBotMentionNote(preview)),
        ),
      ),
    );
  }

  /// Removes Hermes' synthetic todo handoff from user-visible projections.
  ///
  /// Context compression persists this as an ordinary `user` row so the agent
  /// can restore pending work.  It is not authored chat content.  Match the
  /// stable header only at a message/block boundary and require the following
  /// todo marker, so ordinary discussion of the header remains visible.
  static const _todoContinuationHeader =
      '[Your active task list was preserved across context compression]';
  // SessionDB selects 63 chars, then _shape_preview caps them to 60 + `...`.
  static const _todoContinuationBackendPreview =
      '[Your active task list was preserved across context compress...';
  static final RegExp _asyncDelegationCarrier = RegExp(
    r'^\[ASYNC DELEGATION (?:BATCH )?COMPLETE — deleg_[0-9a-f]{8}\](?:\r?\n|$|\.\.\.$)',
  );

  static bool _looksAsyncDelegationCarrier(String raw) =>
      _asyncDelegationCarrier.hasMatch(raw);

  static String stripTodoContinuation(String raw) {
    var from = 0;
    while (true) {
      final index = raw.indexOf(_todoContinuationHeader, from);
      if (index < 0) return raw;
      final prefix = raw.substring(0, index);
      final atBoundary =
          index == 0 || prefix.endsWith('\n\n') || prefix.endsWith('\r\n\r\n');
      final suffix = raw.substring(index + _todoContinuationHeader.length);
      if (atBoundary && RegExp(r'^(?:\r?\n| )- \[(?: |>)\]').hasMatch(suffix)) {
        return raw.substring(0, index).trimRight();
      }
      from = index + _todoContinuationHeader.length;
    }
  }

  static bool _looksSyntheticTodoTitle(String title, String rawPreview) {
    if (title.trim() != _todoContinuationHeader) return false;
    if (rawPreview.trim() == _todoContinuationBackendPreview) return true;
    final stripped = stripTodoContinuation(rawPreview);
    return stripped != rawPreview && stripped.trim().isEmpty;
  }

  /// Quita el bloque inicial `[IMPORTANT: …]` que el cron antepone al prompt de
  /// un job (instrucción de sistema para el agente: delivery, [SILENT], etc.).
  /// Es ruido; no debe verse en chat ni en la lista. Cubre las variantes
  /// "scheduled cron job" e "invoked the skill". El contenido real va tras el
  /// doble salto o tras el cierre del bloque.
  static String stripCronPreamble(String raw) {
    raw = stripTodoContinuation(raw);
    if (raw.trim() == _todoContinuationBackendPreview) return '';
    final t = raw.trimLeft();
    // Handoff de compactación de contexto (interno): no es contenido del usuario.
    if (t.startsWith('[CONTEXT COMPACTION')) {
      final end = RegExp(
        r'---\s*END OF CONTEXT SUMMARY.*?---',
        caseSensitive: false,
      ).firstMatch(t);
      return end != null ? t.substring(end.end).trim() : '';
    }
    final lower = t.toLowerCase();
    final looksCron =
        lower.contains('cron') ||
        lower.contains('[silent]') ||
        lower.contains('delivery:') ||
        lower.contains('scheduled') ||
        lower.contains('invoked');
    if (t.startsWith('[IMPORTANT:') && looksCron) {
      final sep = t.indexOf('\n\n');
      if (sep >= 0) return t.substring(sep + 2).trimLeft();
      final close = t.lastIndexOf(']');
      if (close >= 0 && close < t.length - 1) {
        return t.substring(close + 1).trimLeft();
      }
      // Todo el texto es preámbulo (o el preview llega truncado por el servidor,
      // cortado dentro del bloque): no hay contenido real que mostrar.
      return '';
    }
    return raw;
  }

  /// ¿El título es un placeholder del servidor (sin título real)?
  /// Decodifica percent-encoding accidental en títulos: a veces el título llega
  /// crudo desde un deep-link/query string (p. ej. "Escribe%20el%20comando")
  /// y se vería con los `%20` literales en la lista. Solo decodifica si hay
  /// secuencias `%XX` válidas y la decodificación no falla; en cualquier otro
  /// caso devuelve el texto tal cual (no toca títulos que usan `%` legítimo).
  static final RegExp _botRoutinePrefix = RegExp(
    r'^\[bot:[a-z0-9][a-z0-9_-]{0,63}\]\s*',
  );

  static String _humanizeTitle(String title) {
    if (!title.contains('%') || !RegExp(r'%[0-9A-Fa-f]{2}').hasMatch(title)) {
      return title;
    }
    try {
      final decoded = Uri.decodeComponent(title);
      return decoded.trim().isEmpty ? title : decoded;
    } catch (e) {
      debugPrint(
        '[session] excepción silenciada (se continúa sin propagar): $e',
      );
      return title;
    }
  }

  static bool isPlaceholderTitle(String title) {
    final t = title.trim().toLowerCase();
    return t.isEmpty ||
        t == 'untitle' ||
        t == 'untitled' ||
        t == 'new chat' ||
        t == 'sin título';
  }

  static bool _looksInternalTitle(String title) {
    final normalized = title.trimLeft().toLowerCase();
    return _looksAsyncDelegationCarrier(title) ||
        normalized.startsWith('[context compaction') ||
        normalized.startsWith('[important:') ||
        normalized.startsWith('operation interrupted:') ||
        normalized == 'operation interrupted.';
  }

  /// Primeras ~6 palabras de [text], limpiadas de puntuación de borde. Base del
  /// título autogenerado.
  static String titleFromText(String text) {
    return stripBotMentionNote(text)
        .split(RegExp(r'\s+'))
        .map((w) => w.replaceAll(RegExp(r"^[^\wÀ-ÿ]+|[^\wÀ-ÿ]+$"), ''))
        .where((w) => w.isNotEmpty)
        .take(6)
        .join(' ');
  }

  /// Best available timestamp for sorting by recent activity.
  @override
  double get lastActivityAt => sessionLastActivityAt(
    startedAt: startedAt,
    endedAt: endedAt,
    updatedAt: updatedAt,
  );

  /// Age of this session expressed as a [Duration] from now.
  Duration get _age {
    final ms = (lastActivityAt * 1000).toInt();
    return DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  /// Derived [SessionState] based on timestamps and message count.
  ///
  /// Rules (evaluated in priority order):
  ///   broken   — id is blank OR startedAt == 0
  ///   active   — still open (endedAt == null) AND last activity < 1 h ago
  ///   idle     — still open (endedAt == null) AND last activity >= 1 h ago
  ///   stale    — closed AND last activity > 7 d ago
  ///              OR messageCount == 0 AND age > 1 day
  ///   unknown  — everything else without enough signal
  ///
  /// NOTE: [SessionState.archived] is local-only and is never returned here.
  /// Use [stateWithArchive] to fold an archival flag into the result.
  SessionState get state {
    if (id.isEmpty || startedAt == 0) return SessionState.broken;

    final age = _age;

    if (endedAt == null) {
      // Open session. Una sesión que nunca se "cerró" pero lleva mucho sin
      // actividad NO es activa: muchas (webui/cli/tui antiguas) quedan abiertas
      // para siempre. Si lleva >7 días inactiva, es "antigua" y se puede limpiar.
      if (age.inHours < 1) return SessionState.active;
      if (age.inDays > 7) return SessionState.stale;
      return SessionState.idle;
    }

    // Closed session
    if (age.inDays > 7) return SessionState.stale;
    if (messageCount == 0 && age.inDays >= 1) return SessionState.stale;

    return SessionState.unknown;
  }

  /// Like [state] but returns [SessionState.archived] when [archived] is true,
  /// unless the session is broken (broken always wins).
  SessionState stateWithArchive(bool archived) {
    if (state == SessionState.broken) return SessionState.broken;
    return archived ? SessionState.archived : state;
  }

  Session copyWith({
    String? id,
    String? title,
    String? model,
    String? source,
    int? messageCount,
    bool? isActive,
    String? preview,
    String? lastUserPreview,
    String? lastAssistantPreview,
    double? startedAt,
    double? endedAt,
    bool clearEndedAt = false,
    double? updatedAt,
    String? endReason,
    String? parentSessionId,
    String? branchedFromId,
    String? resetFromId,
    String? lineageRootId,
    List<String>? lineageIds,
    bool? isInternalChild,
    bool? schedulerOwned,
    bool? isActivePublished,
    String? cwd,
    String? gitRepoRoot,
    bool clearGitRepoRoot = false,
    String? gitBranch,
    bool clearGitBranch = false,
    bool? archived,
    bool? pinned,
    bool? hidden,
    bool? unread,
    double? lastReadAt,
    String? searchSnippet,
    String? profile,
    bool? isDefaultProfile,
    String? handoffPlatform,
    String? handoffState,
    String? handoffError,
    bool? hasLocalDraft,
  }) => Session(
    id: id ?? this.id,
    title: title ?? this.title,
    model: model ?? this.model,
    source: source ?? this.source,
    messageCount: messageCount ?? this.messageCount,
    isActive: isActive ?? this.isActive,
    preview: preview ?? this.preview,
    lastUserPreview: lastUserPreview ?? this.lastUserPreview,
    lastAssistantPreview: lastAssistantPreview ?? this.lastAssistantPreview,
    startedAt: normalizeEpochTimestamp(startedAt) ?? this.startedAt,
    endedAt: clearEndedAt
        ? null
        : normalizeEpochTimestamp(endedAt) ?? this.endedAt,
    updatedAt: normalizeEpochTimestamp(updatedAt) ?? this.updatedAt,
    endReason: endReason ?? this.endReason,
    parentSessionId: parentSessionId ?? this.parentSessionId,
    branchedFromId: branchedFromId ?? this.branchedFromId,
    resetFromId: resetFromId ?? this.resetFromId,
    lineageRootId: lineageRootId ?? this.lineageRootId,
    lineageIds: lineageIds ?? this.lineageIds,
    isInternalChild: isInternalChild ?? this.isInternalChild,
    schedulerOwned: schedulerOwned ?? this.schedulerOwned,
    isActivePublished: isActivePublished ?? this.isActivePublished,
    cwd: cwd ?? this.cwd,
    gitRepoRoot: clearGitRepoRoot ? null : gitRepoRoot ?? this.gitRepoRoot,
    gitBranch: clearGitBranch ? null : gitBranch ?? this.gitBranch,
    archived: archived ?? this.archived,
    pinned: pinned ?? this.pinned,
    hidden: hidden ?? this.hidden,
    unread: unread ?? this.unread,
    lastReadAt: lastReadAt ?? this.lastReadAt,
    searchSnippet: searchSnippet ?? this.searchSnippet,
    profile: profile ?? this.profile,
    isDefaultProfile: isDefaultProfile ?? this.isDefaultProfile,
    handoffPlatform: handoffPlatform ?? this.handoffPlatform,
    handoffState: handoffState ?? this.handoffState,
    handoffError: handoffError ?? this.handoffError,
    hasLocalDraft: hasLocalDraft ?? this.hasLocalDraft,
    toolCallCount: toolCallCount,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cacheReadTokens: cacheReadTokens,
    cacheWriteTokens: cacheWriteTokens,
    reasoningTokens: reasoningTokens,
    apiCallCount: apiCallCount,
    estimatedCostUsd: estimatedCostUsd,
    actualCostUsd: actualCostUsd,
    hasSystemPrompt: hasSystemPrompt,
  );

  factory Session.fromJson(Map<String, dynamic> json) {
    final endedAt = normalizeEpochTimestamp(json['ended_at']);
    final lastActive =
        normalizeEpochTimestamp(json['last_active']) ??
        normalizeEpochTimestamp(json['updated_at']);
    final inputTokens = _nonNegativeInt(json['input_tokens']);
    final outputTokens = _nonNegativeInt(json['output_tokens']);
    final reasoningTokens = _nonNegativeInt(json['reasoning_tokens']);
    final explicitActive = json['is_active'];
    return Session(
      id: _opaqueId(json['id']) ?? '',
      title:
          _boundedText(_mentionDisplayValue(json['title']), 512) ?? 'Untitled',
      model: _boundedText(json['model'], 256) ?? 'Default',
      source: _boundedText(json['source'], 128) ?? '',
      messageCount: _nonNegativeInt(json['message_count']) ?? 0,
      isActive: explicitActive is bool ? explicitActive : endedAt == null,
      preview: _boundedText(_mentionDisplayValue(json['preview']), 2048) ?? '',
      lastUserPreview: _boundedText(
        _mentionDisplayValue(
          json['last_user_preview'] ?? json['lastUserPreview'],
        ),
        2048,
      ),
      lastAssistantPreview: _boundedText(
        json['last_assistant_preview'] ?? json['lastAssistantPreview'],
        2048,
      ),
      startedAt: normalizeEpochTimestamp(json['started_at']) ?? 0,
      endedAt: endedAt,
      updatedAt: lastActive,
      endReason: _boundedText(json['end_reason'], 256),
      parentSessionId: _opaqueId(json['parent_session_id']),
      branchedFromId: _opaqueId(json['_branched_from']),
      resetFromId: _opaqueId(json['_reset_from']),
      lineageRootId: _opaqueId(
        json['_lineage_root_id'] ?? json['lineage_root'],
      ),
      lineageIds: _opaqueIds(json['_lineage_ids']),
      isInternalChild: json['is_internal_child'] is bool
          ? json['is_internal_child'] as bool
          : null,
      schedulerOwned: json['scheduler_owned'] is bool
          ? json['scheduler_owned'] as bool
          : null,
      isActivePublished: explicitActive is bool,
      cwd: _boundedText(json['cwd'], 1024),
      gitRepoRoot: _boundedText(json['git_repo_root'], 1024),
      gitBranch: _boundedText(json['git_branch'], 512),
      archived: json['archived'] == true,
      pinned: json['pinned'] is bool ? json['pinned'] as bool : null,
      hidden: _flag(json['hidden']),
      unread: json['unread'] is bool ? json['unread'] as bool : null,
      lastReadAt: json['last_read_at'] is num
          ? (json['last_read_at'] as num).toDouble()
          : null,
      profile: _boundedText(json['profile'], 256),
      isDefaultProfile: json['is_default_profile'] is bool
          ? json['is_default_profile'] as bool
          : null,
      handoffPlatform: _boundedText(json['handoff_platform'], 128),
      handoffState: _boundedText(json['handoff_state'], 128),
      handoffError: _boundedText(json['handoff_error'], 512),
      toolCallCount: _nonNegativeInt(json['tool_call_count']) ?? 0,
      inputTokens: inputTokens ?? 0,
      inputTokensPublished: inputTokens != null,
      outputTokens: outputTokens ?? 0,
      outputTokensPublished: outputTokens != null,
      cacheReadTokens: _nonNegativeInt(json['cache_read_tokens']),
      cacheWriteTokens: _nonNegativeInt(json['cache_write_tokens']),
      reasoningTokens: reasoningTokens ?? 0,
      reasoningTokensPublished: reasoningTokens != null,
      apiCallCount: _nonNegativeInt(json['api_call_count']) ?? 0,
      estimatedCostUsd: _nonNegativeDouble(json['estimated_cost_usd']),
      actualCostUsd: _nonNegativeDouble(json['actual_cost_usd']),
      hasSystemPrompt: json['has_system_prompt'] == true,
    );
  }

  /// A SQLite flag column: JSON bool, or the raw 0/1 integer the list
  /// endpoints leave unconverted. Anything else is "not published".
  static bool? _flag(Object? value) {
    if (value is bool) return value;
    if (value == 0) return false;
    if (value == 1) return true;
    return null;
  }

  static Session? tryParse(Object? value) {
    if (value is! Map) return null;
    final json = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is String) json[entry.key as String] = entry.value;
    }
    final session = Session.fromJson(json);
    return session.id.isEmpty ? null : session;
  }

  int get totalTokens => inputTokens + outputTokens;

  /// Canonical prompt-token denominator used by Hermes 0.19.
  int get promptTokens =>
      inputTokens + (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0);

  /// Percentage of prompt tokens reused from cache, or null without reuse.
  double? get cacheReadPercent {
    final read = cacheReadTokens;
    if (read == null || read <= 0 || promptTokens <= 0) return null;
    return (100 * read / promptTokens).clamp(0, 100).toDouble();
  }

  /// Duración de la sesión: started_at → ended_at (o última actividad si
  /// sigue abierta). Null si no hay señal suficiente.
  Duration? get sessionDuration {
    if (startedAt == 0) return null;
    final end = endedAt ?? updatedAt;
    if (end == null || end <= startedAt) return null;
    return Duration(milliseconds: ((end - startedAt) * 1000).round());
  }
}

List<String> _opaqueIds(Object? value) {
  if (value is! List) return const [];
  return List<String>.unmodifiable(value.map(_opaqueId).whereType<String>());
}

String? _opaqueId(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > 1024) return null;
  return trimmed;
}

String? _boundedText(Object? value, int maxRunes) {
  if (value is! String) return null;
  final bounded = String.fromCharCodes(value.runes.take(maxRunes));
  final sanitized = bounded
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ')
      .trim();
  return sanitized.isEmpty ? null : sanitized;
}

int? _nonNegativeInt(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  final integer = value.toInt();
  return value == integer ? integer : null;
}

double? _nonNegativeDouble(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  return value.toDouble();
}

Object? _mentionDisplayValue(Object? value) =>
    value is String ? stripBotMentionNote(value) : value;
