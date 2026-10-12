import 'dart:convert';

import 'package:flutter/foundation.dart';

enum HomeWidgetConnectionState {
  unconfigured,
  noInstance,
  connecting,
  connected,
  error,
  disconnected,
}

enum HomeWidgetAgentState {
  idle,
  thinking,
  streaming,
  toolExecution,
  waitingApproval,
  error,
  disconnected,
}

enum HomeWidgetTheme { light, dark, oled }

/// Something a chat is waiting for the owner to answer (schema 2).
@immutable
class HomeWidgetNeed {
  const HomeWidgetNeed({
    required this.requestId,
    this.question = false,
    this.text,
    this.actionPayload,
  });

  /// The server's own id of the request: an answer can only ever be for it.
  final String requestId;

  /// A question to answer in words; false for a permission to grant or deny.
  final bool question;

  /// What is asked: the command, or the question. Public display text only.
  final String? text;

  /// Payload of Permitir / Rechazar (a `NotificationActionPayload`); null
  /// when it can only be answered in the app.
  final String? actionPayload;

  Map<String, Object?> toMap() => {
    'rid': requestId,
    if (question) 'question': true,
    'text': ?_safeText(text, 160),
    'action': ?_safeText(actionPayload, 4000),
  };

  static HomeWidgetNeed? fromMap(Object? value) {
    if (value is! Map) return null;
    final requestId = _safeText(value['rid'], 256, opaque: true);
    if (requestId == null) return null;
    return HomeWidgetNeed(
      requestId: requestId,
      question: value['question'] == true,
      text: _safeText(value['text'], 160),
      actionPayload: _safeText(value['action'], 4000),
    );
  }
}

/// One chat that is running or waiting for the owner right now (schema 2).
@immutable
class HomeWidgetChatActivity {
  const HomeWidgetChatActivity({
    required this.sessionId,
    required this.state,
    this.title,
    this.profile,
    this.phase,
    this.startedAtMs,
    this.need,
  });

  final String sessionId;
  final String? title;

  /// Profile that owns the chat (null for the default one).
  final String? profile;

  /// thinking, streaming, toolExecution or waitingApproval: never idle.
  final HomeWidgetAgentState state;

  /// The running tool in plain words ("Terminal"); null when it is thinking
  /// or answering.
  final String? phase;

  /// When this turn started: the widget's timer counts from here.
  final int? startedAtMs;

  /// Set while [state] is waitingApproval and the request is known.
  final HomeWidgetNeed? need;

  bool get needsYou => state == HomeWidgetAgentState.waitingApproval;

  Map<String, Object?> toMap() => {
    'sid': sessionId,
    'title': ?_safeText(title, 96),
    'profile': ?_safeText(profile, 64),
    'state': state.name,
    'phase': ?_safeText(phase, 48),
    'started_ms': ?_safeNonNegativeInt(startedAtMs),
    'need': ?need?.toMap(),
  };

  static HomeWidgetChatActivity? fromMap(Object? value) {
    if (value is! Map) return null;
    final sessionId = _safeText(value['sid'], 256, opaque: true);
    final state = _enumByName(
      HomeWidgetAgentState.values,
      value['state'],
      HomeWidgetAgentState.idle,
    );
    if (sessionId == null || !activeStates.contains(state)) return null;
    return HomeWidgetChatActivity(
      sessionId: sessionId,
      title: _safeText(value['title'], 96),
      profile: _safeText(value['profile'], 64),
      state: state,
      phase: _safeText(value['phase'], 48),
      startedAtMs: _safePositiveInt(value['started_ms']),
      need: HomeWidgetNeed.fromMap(value['need']),
    );
  }

  /// The states that mean "this chat is doing something right now".
  static const activeStates = {
    HomeWidgetAgentState.thinking,
    HomeWidgetAgentState.streaming,
    HomeWidgetAgentState.toolExecution,
    HomeWidgetAgentState.waitingApproval,
  };
}

/// One window of a subscription's limits, as the widget writes it (text the
/// app already localized).
@immutable
class HomeWidgetLimitWindow {
  const HomeWidgetLimitWindow({
    required this.label,
    required this.usedPercent,
    this.detail,
  });

  /// «Sesión actual», «Semana»: in the language of the app.
  final String label;

  /// 0..100 (a window over its limit reads 100).
  final int usedPercent;

  /// «Se reinicia en 2 h 13 min»; absent when there is none.
  final String? detail;

  Map<String, Object?> toMap() => {
    'label': _safeText(label, 48),
    'used_percent': usedPercent.clamp(0, 100),
    'detail': ?_safeText(detail, 64),
  };

  static HomeWidgetLimitWindow? fromMap(Object? value) {
    if (value is! Map) return null;
    final label = _safeText(value['label'], 48);
    final used = _safeNonNegativeInt(value['used_percent']);
    if (label == null || used == null) return null;
    return HomeWidgetLimitWindow(
      label: label,
      usedPercent: used.clamp(0, 100),
      detail: _safeText(value['detail'], 64),
    );
  }
}

/// The limits of ONE subscription and whose they are: the provider as the
/// server reports it and, when the server names one, the plan. Never a
/// guessed plan (additive field of schema 2).
@immutable
class HomeWidgetLimitGroup {
  const HomeWidgetLimitGroup({
    required this.provider,
    required this.providerName,
    this.plan,
    this.inUse = false,
    this.windows = const [],
  });

  /// Stable provider id (Hermes' slug: `openai-codex`, `anthropic`, `nous`).
  final String provider;

  /// The provider's name for people («OpenAI Codex»).
  final String providerName;

  /// «Plus», «Max 5x»; null when the server gives none.
  final String? plan;

  /// The account behind the model of the active profile's chat.
  final bool inUse;
  final List<HomeWidgetLimitWindow> windows;

  static final _id = RegExp(r'^[a-z0-9][a-z0-9._-]{0,39}$');

  Map<String, Object?> toMap() => {
    'provider': provider,
    'provider_name': _safeText(providerName, 48),
    'plan': ?_safeText(plan, 32),
    'in_use': inUse,
    'windows': [
      for (final w in windows.take(HermesHomeWidgetSnapshot.maxLimitWindows))
        w.toMap(),
    ],
  };

  static HomeWidgetLimitGroup? fromMap(Object? value) {
    if (value is! Map) return null;
    final provider = value['provider'];
    final name = _safeText(value['provider_name'], 48);
    if (provider is! String || !_id.hasMatch(provider) || name == null) {
      return null;
    }
    final raw = value['windows'];
    return HomeWidgetLimitGroup(
      provider: provider,
      providerName: name,
      plan: _safeText(value['plan'], 32),
      inUse: _safeBool(value['in_use']),
      windows: [
        if (raw is List)
          for (final w in raw.take(HermesHomeWidgetSnapshot.maxLimitWindows))
            ?HomeWidgetLimitWindow.fromMap(w),
      ],
    );
  }
}

/// Secret-free snapshot consumed by the Android Glance widget.
///
/// The model intentionally owns validation and serialization so Flutter,
/// tests and Kotlin all project the same bounded contract. It never accepts a
/// URL, prompt, response, credential or reasoning field.
@immutable
class HermesHomeWidgetSnapshot {
  /// 2 added [active]: every chat running or waiting for the owner, with a
  /// plain-word phase, the turn's start and the pending request. A reader of
  /// schema 1 ignores it; a snapshot of schema 1 reads here with none.
  static const schemaVersion = 2;

  /// Snapshots this build can read (one written by 1.2.14 is schema 1).
  static const readableSchemaVersions = {1, 2};

  /// More than any widget draws; bounds the stored string.
  static const maxActive = 6;
  static const maxLimitGroups = 3;
  static const maxLimitWindows = 4;
  static const storagePrefix = 'hermes_widget_';
  static const atomicStorageKey = '${storagePrefix}atomic_snapshot_v1';
  static const staleAfter = Duration(minutes: 15);

  const HermesHomeWidgetSnapshot({
    this.configured = false,
    this.instanceId,
    this.instanceLabel,
    this.connectionState = HomeWidgetConnectionState.unconfigured,
    this.model,
    this.provider,
    this.sessionId,
    this.sessionTitle,
    this.agentState = HomeWidgetAgentState.disconnected,
    this.toolName,
    this.contextUsed,
    this.contextMax,
    this.contextPercent,
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.firstTokenLatencyMs,
    this.lastActivityAtMs,
    this.updatedAtMs = 0,
    this.theme = HomeWidgetTheme.dark,
    this.showAdvancedMetrics = true,
    this.active = const [],
    this.limits = const [],
  });

  static const empty = HermesHomeWidgetSnapshot();

  final bool configured;
  final String? instanceId;
  final String? instanceLabel;
  final HomeWidgetConnectionState connectionState;
  final String? model;
  final String? provider;
  final String? sessionId;
  final String? sessionTitle;
  final HomeWidgetAgentState agentState;
  final String? toolName;
  final int? contextUsed;
  final int? contextMax;
  final int? contextPercent;
  final int? inputTokens;
  final int? outputTokens;

  /// Optional future-compatible fields. Hermes currently publishes these only
  /// on some usage surfaces/providers; callers must leave them null otherwise.
  final int? cacheReadTokens;
  final int? cacheWriteTokens;

  /// Client-observed submit-to-first-token latency, only when measured by the
  /// active chat. It is not synthesized from total duration.
  final int? firstTokenLatencyMs;

  /// Real activity time for the current session. This is distinct from
  /// [updatedAtMs], which only timestamps publication/staleness.
  final int? lastActivityAtMs;
  final int updatedAtMs;
  final HomeWidgetTheme theme;
  final bool showAdvancedMetrics;

  /// Chats of this instance running or waiting for the owner right now,
  /// the ones that need the owner first.
  final List<HomeWidgetChatActivity> active;

  /// Plan limits by subscription, the one in use first. Empty when Home has
  /// not read them; a widget then shows no limits (never old ones as new).
  final List<HomeWidgetLimitGroup> limits;

  bool isStaleAt(int nowMs) =>
      updatedAtMs <= 0 || nowMs - updatedAtMs > staleAfter.inMilliseconds;

  int? get cachePercent {
    final read = cacheReadTokens;
    final input = inputTokens;
    if (read == null || input == null) return null;
    final prompt = input + read + (cacheWriteTokens ?? 0);
    if (read <= 0 || prompt <= 0) return null;
    return ((read / prompt) * 100).round().clamp(0, 100);
  }

  HermesHomeWidgetSnapshot copyWith({
    bool? configured,
    String? instanceId,
    bool clearInstanceId = false,
    String? instanceLabel,
    bool clearInstanceLabel = false,
    HomeWidgetConnectionState? connectionState,
    String? model,
    bool clearModel = false,
    String? provider,
    bool clearProvider = false,
    String? sessionId,
    bool clearSessionId = false,
    String? sessionTitle,
    bool clearSessionTitle = false,
    HomeWidgetAgentState? agentState,
    String? toolName,
    bool clearToolName = false,
    int? contextUsed,
    bool clearContextUsed = false,
    int? contextMax,
    bool clearContextMax = false,
    int? contextPercent,
    bool clearContextPercent = false,
    int? inputTokens,
    bool clearInputTokens = false,
    int? outputTokens,
    bool clearOutputTokens = false,
    int? cacheReadTokens,
    bool clearCacheReadTokens = false,
    int? cacheWriteTokens,
    bool clearCacheWriteTokens = false,
    int? firstTokenLatencyMs,
    bool clearFirstTokenLatencyMs = false,
    int? lastActivityAtMs,
    bool clearLastActivityAtMs = false,
    int? updatedAtMs,
    HomeWidgetTheme? theme,
    bool? showAdvancedMetrics,
    List<HomeWidgetChatActivity>? active,
    List<HomeWidgetLimitGroup>? limits,
  }) => HermesHomeWidgetSnapshot(
    configured: configured ?? this.configured,
    instanceId: clearInstanceId ? null : instanceId ?? this.instanceId,
    instanceLabel: clearInstanceLabel
        ? null
        : instanceLabel ?? this.instanceLabel,
    connectionState: connectionState ?? this.connectionState,
    model: clearModel ? null : model ?? this.model,
    provider: clearProvider ? null : provider ?? this.provider,
    sessionId: clearSessionId ? null : sessionId ?? this.sessionId,
    sessionTitle: clearSessionTitle ? null : sessionTitle ?? this.sessionTitle,
    agentState: agentState ?? this.agentState,
    toolName: clearToolName ? null : toolName ?? this.toolName,
    contextUsed: clearContextUsed ? null : contextUsed ?? this.contextUsed,
    contextMax: clearContextMax ? null : contextMax ?? this.contextMax,
    contextPercent: clearContextPercent
        ? null
        : contextPercent ?? this.contextPercent,
    inputTokens: clearInputTokens ? null : inputTokens ?? this.inputTokens,
    outputTokens: clearOutputTokens ? null : outputTokens ?? this.outputTokens,
    cacheReadTokens: clearCacheReadTokens
        ? null
        : cacheReadTokens ?? this.cacheReadTokens,
    cacheWriteTokens: clearCacheWriteTokens
        ? null
        : cacheWriteTokens ?? this.cacheWriteTokens,
    firstTokenLatencyMs: clearFirstTokenLatencyMs
        ? null
        : firstTokenLatencyMs ?? this.firstTokenLatencyMs,
    lastActivityAtMs: clearLastActivityAtMs
        ? null
        : lastActivityAtMs ?? this.lastActivityAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    theme: theme ?? this.theme,
    showAdvancedMetrics: showAdvancedMetrics ?? this.showAdvancedMetrics,
    active: active ?? this.active,
    limits: limits ?? this.limits,
  );

  factory HermesHomeWidgetSnapshot.fromMap(Map<Object?, Object?> map) {
    final version = _safeInt(map['schema_version']);
    if (!readableSchemaVersions.contains(version)) return empty;
    final rawActive = map['active'];
    final used = _safeNonNegativeInt(map['context_used']);
    final max = _safePositiveInt(map['context_max']);
    final suppliedPercent = _safeNonNegativeInt(map['context_percent']);
    final percent = max == null || used == null
        ? null
        : (suppliedPercent ?? ((used / max) * 100).round()).clamp(0, 100);
    return HermesHomeWidgetSnapshot(
      configured: _safeBool(map['configured']),
      instanceId: _safeText(map['instance_id'], 256, opaque: true),
      instanceLabel: _safeText(map['instance_label'], 64),
      connectionState: _enumByName(
        HomeWidgetConnectionState.values,
        map['connection_state'],
        HomeWidgetConnectionState.unconfigured,
      ),
      model: _safeText(map['model'], 96),
      provider: _safeText(map['provider'], 64),
      sessionId: _safeText(map['session_id'], 256, opaque: true),
      sessionTitle: _safeText(map['session_title'], 96),
      agentState: _enumByName(
        HomeWidgetAgentState.values,
        map['agent_state'],
        HomeWidgetAgentState.disconnected,
      ),
      toolName: _safeText(map['tool_name'], 64),
      contextUsed: used,
      contextMax: max,
      contextPercent: percent,
      inputTokens: _safeNonNegativeInt(map['input_tokens']),
      outputTokens: _safeNonNegativeInt(map['output_tokens']),
      cacheReadTokens: _safeNonNegativeInt(map['cache_read_tokens']),
      cacheWriteTokens: _safeNonNegativeInt(map['cache_write_tokens']),
      firstTokenLatencyMs: _safeNonNegativeInt(map['first_token_latency_ms']),
      lastActivityAtMs: _safeNonNegativeInt(map['last_activity_at_ms']),
      updatedAtMs: _safeNonNegativeInt(map['updated_at_ms']) ?? 0,
      theme: _enumByName(
        HomeWidgetTheme.values,
        map['theme'],
        HomeWidgetTheme.dark,
      ),
      showAdvancedMetrics: map.containsKey('show_advanced_metrics')
          ? _safeBool(map['show_advanced_metrics'])
          : true,
      active: [
        if (rawActive is List)
          for (final entry in rawActive.take(maxActive))
            ?HomeWidgetChatActivity.fromMap(entry),
      ],
      limits: [
        if (map['limits'] case final List rawLimits)
          for (final entry in rawLimits.take(maxLimitGroups))
            ?HomeWidgetLimitGroup.fromMap(entry),
      ],
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'schema_version': schemaVersion,
    'configured': configured,
    'instance_id': _safeText(instanceId, 256, opaque: true),
    'instance_label': _safeText(instanceLabel, 64),
    'connection_state': connectionState.name,
    'model': _safeText(model, 96),
    'provider': _safeText(provider, 64),
    'session_id': _safeText(sessionId, 256, opaque: true),
    'session_title': _safeText(sessionTitle, 96),
    'agent_state': agentState.name,
    'tool_name': _safeText(toolName, 64),
    'context_used': _safeNonNegativeInt(contextUsed),
    'context_max': _safePositiveInt(contextMax),
    'context_percent': contextPercent?.clamp(0, 100),
    'input_tokens': _safeNonNegativeInt(inputTokens),
    'output_tokens': _safeNonNegativeInt(outputTokens),
    'cache_read_tokens': _safeNonNegativeInt(cacheReadTokens),
    'cache_write_tokens': _safeNonNegativeInt(cacheWriteTokens),
    'first_token_latency_ms': _safeNonNegativeInt(firstTokenLatencyMs),
    'last_activity_at_ms': _safeNonNegativeInt(lastActivityAtMs),
    'updated_at_ms': _safeNonNegativeInt(updatedAtMs) ?? 0,
    'theme': theme.name,
    'show_advanced_metrics': showAdvancedMetrics,
    'active': [for (final chat in active.take(maxActive)) chat.toMap()],
    'limits': [for (final group in limits.take(maxLimitGroups)) group.toMap()],
  };

  /// The field-by-field mirror of the snapshot: its plain values only. The
  /// lists live in the atomic copy, which is what the widgets read.
  Map<String, Object?> toStorageMap() => <String, Object?>{
    for (final entry in toMap().entries)
      if (entry.value is! List) '$storagePrefix${entry.key}': entry.value,
  };

  String toAtomicStorageValue() => jsonEncode(toMap());

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HermesHomeWidgetSnapshot &&
          toAtomicStorageValue() == other.toAtomicStorageValue();

  @override
  int get hashCode => toAtomicStorageValue().hashCode;
}

T _enumByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw is String) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
  }
  return fallback;
}

bool _safeBool(Object? value) => value == true;

int? _safeInt(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  if (value is String) return int.tryParse(value);
  return null;
}

int? _safeNonNegativeInt(Object? value) {
  final parsed = _safeInt(value);
  return parsed == null || parsed < 0 ? null : parsed;
}

int? _safePositiveInt(Object? value) {
  final parsed = _safeNonNegativeInt(value);
  return parsed == null || parsed == 0 ? null : parsed;
}

String? _safeText(Object? value, int maxLength, {bool opaque = false}) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (opaque && !RegExp(r'^[A-Za-z0-9._:@+-]+$').hasMatch(trimmed)) {
    return null;
  }
  return trimmed.length <= maxLength
      ? trimmed
      : trimmed.substring(0, maxLength);
}
