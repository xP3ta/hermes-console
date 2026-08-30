import 'interactive_prompt.dart';

/// Typed, defensive projection of the Hermes Agent 0.19 Desktop session
/// lifecycle responses.
///
/// These values can contain conversation text and paths. They are deliberately
/// kept in memory and must never be written to diagnostic logs.
class DesktopSessionSnapshot {
  final String runtimeSessionId;
  final String storedSessionId;
  final bool created;
  final List<DesktopSessionMessage> messages;
  final bool messagesProvided;
  final int? messageCount;

  /// `session.resume` con `defer_history:true` (Hermes Agent 0.20): el ack es
  /// inmediato, llega con `messages:[]` y el historial se hidrata en segundo
  /// plano (eventos `session.resume_progress`). Servidores antiguos omiten el
  /// campo → false.
  final bool hydrating;
  final DesktopInflightTurn? inflight;
  final DesktopQueuedTurn? queued;
  final bool running;
  final String? status;
  final DateTime? startedAt;
  final DesktopSessionRuntimeInfo info;
  final Map<String, dynamic> raw;
  final Map<String, dynamic>? pendingClarify;
  final InteractivePromptParseOutcome? pendingClarifyOutcome;
  final bool pendingClarifyProvided;

  const DesktopSessionSnapshot({
    required this.runtimeSessionId,
    required this.storedSessionId,
    required this.created,
    this.messages = const [],
    this.messagesProvided = false,
    this.messageCount,
    this.hydrating = false,
    this.inflight,
    this.queued,
    this.running = false,
    this.status,
    this.startedAt,
    this.info = const DesktopSessionRuntimeInfo(),
    this.raw = const {},
    this.pendingClarify,
    this.pendingClarifyOutcome,
    this.pendingClarifyProvided = false,
  });

  factory DesktopSessionSnapshot.fromJson(
    Map<String, dynamic> json, {
    required String requestedStoredSessionId,
    required bool created,
    required String method,
  }) {
    final runtimeSessionId = _nonEmptyString(json['session_id']);
    if (runtimeSessionId == null) {
      throw FormatException('$method omitted a valid runtime session id');
    }

    // `resumed` is a session id in the 0.19 contract, but older/newer servers
    // may use it as a boolean status flag. Identity fields are intentionally
    // strict: a bool/number must never become the persisted strings "true" or
    // "42" through an incidental toString().
    final storedSessionId =
        _nonEmptyString(json['stored_session_id']) ??
        _nonEmptyString(json['session_key']) ??
        _nonEmptyString(json['resumed']) ??
        _nonEmptyString(requestedStoredSessionId);
    if (storedSessionId == null) {
      throw FormatException('$method omitted a valid stored session id');
    }

    final rawMessages = json['messages'];
    final messages = <DesktopSessionMessage>[];
    if (rawMessages is List) {
      for (var index = 0; index < rawMessages.length; index++) {
        final parsed = DesktopSessionMessage.tryParse(
          rawMessages[index],
          serverOrdinal: index,
        );
        if (parsed != null) messages.add(parsed);
      }
    }

    final pendingClarifyProvided = json.containsKey('pending_clarify');
    final pendingClarifyOutcome =
        pendingClarifyProvided && json['pending_clarify'] != null
        ? InteractivePromptParseOutcome.tryFromGatewayEvent(
            type: 'clarify.request',
            runtimeSessionId: runtimeSessionId,
            payload: json['pending_clarify'],
            source: InteractivePromptParseSource.authoritativeKindSlot,
          )
        : null;
    final pendingClarify = pendingClarifyOutcome is InteractivePromptParsed
        ? _stringKeyedMap(json['pending_clarify'])
        : null;

    return DesktopSessionSnapshot(
      runtimeSessionId: runtimeSessionId,
      storedSessionId: storedSessionId,
      created: created,
      messages: List.unmodifiable(messages),
      messagesProvided: rawMessages is List,
      messageCount: _nonNegativeInt(json['message_count']),
      hydrating: json['hydrating'] == true,
      inflight: DesktopInflightTurn.tryParse(json['inflight']),
      queued: DesktopQueuedTurn.tryParse(json['queued']),
      running: json['running'] is bool && json['running'] == true,
      status: _nonEmptyString(json['status']),
      startedAt: _epochSeconds(json['started_at']),
      info: DesktopSessionRuntimeInfo.fromJson(json['info']),
      pendingClarify: pendingClarify,
      pendingClarifyOutcome: pendingClarifyOutcome,
      pendingClarifyProvided: pendingClarifyProvided,
      // Keep only unknown, non-payload extension fields. The 0.19 snapshot can
      // contain the whole transcript and a many-KiB system prompt; duplicating
      // those in `raw` increases memory pressure and makes accidental logging
      // much easier.
      raw: _freezeExtras(json, _snapshotParsedKeys),
    );
  }
}

enum DesktopSessionMessageRole { system, user, assistant, tool, unknown }

class DesktopSessionMessage {
  final String? stableId;
  final int? serverOrdinal;
  final Map<String, dynamic> artifactContainers;
  final DesktopSessionMessageRole role;
  final String rawRole;
  final Object? content;
  final String? text;
  final String? name;
  final String? reasoning;
  final String? reasoningContent;
  final Object? reasoningDetails;
  final Object? codexReasoningItems;
  final Object? context;
  final DateTime? timestamp;
  final String? toolCallId;
  final Object? toolCalls;
  final String? toolName;
  final Object? displayMetadata;
  final Map<String, dynamic> raw;

  const DesktopSessionMessage({
    required this.role,
    required this.rawRole,
    this.stableId,
    this.serverOrdinal,
    this.artifactContainers = const {},
    this.content,
    this.text,
    this.name,
    this.reasoning,
    this.reasoningContent,
    this.reasoningDetails,
    this.codexReasoningItems,
    this.context,
    this.timestamp,
    this.toolCallId,
    this.toolCalls,
    this.toolName,
    this.displayMetadata,
    this.raw = const {},
  });

  static DesktopSessionMessage? tryParse(Object? value, {int? serverOrdinal}) {
    final json = _stringKeyedMap(value);
    if (json == null) return null;
    final rawRole = _nonEmptyString(json['role']);
    if (rawRole == null) return null;
    final normalizedRole = rawRole.toLowerCase();
    final role = switch (normalizedRole) {
      'system' => DesktopSessionMessageRole.system,
      'user' => DesktopSessionMessageRole.user,
      'assistant' => DesktopSessionMessageRole.assistant,
      'tool' => DesktopSessionMessageRole.tool,
      _ => DesktopSessionMessageRole.unknown,
    };
    final content = json.containsKey('content')
        ? _freezeJson(json['content'])
        : _freezeJson(json['text']);
    final text =
        _stringValue(json['text']) ??
        (json['content'] is String ? json['content'] as String : null);
    final name = _nonEmptyString(json['name']);
    return DesktopSessionMessage(
      stableId:
          _stableOpaqueId(json['message_id']) ?? _stableOpaqueId(json['id']),
      serverOrdinal: serverOrdinal != null && serverOrdinal >= 0
          ? serverOrdinal
          : null,
      artifactContainers: _freezeArtifactContainers(json),
      role: role,
      rawRole: rawRole,
      content: content,
      text: text,
      name: name,
      reasoning: _stringValue(json['reasoning']),
      reasoningContent: _stringValue(json['reasoning_content']),
      reasoningDetails: _freezeJson(json['reasoning_details']),
      codexReasoningItems: _freezeJson(json['codex_reasoning_items']),
      context: _freezeJson(json['context']),
      timestamp: _epochSeconds(json['timestamp']),
      toolCallId: _nonEmptyString(json['tool_call_id']),
      toolCalls: _freezeJson(json['tool_calls']),
      toolName:
          _nonEmptyString(json['tool_name']) ??
          (role == DesktopSessionMessageRole.tool ? name : null),
      displayMetadata: _freezeJson(json['display_metadata']),
      raw: _freezeExtras(json, _messageParsedKeys),
    );
  }
}

class DesktopInflightTurn {
  final String? assistant;
  final bool? streaming;
  final String? user;
  final String? error;
  final String? status;
  final bool? recoverable;
  final List<DesktopInflightCorrection> corrections;
  final DateTime? startedAt;
  final DateTime? updatedAt;
  final Map<String, dynamic> raw;

  DesktopInflightTurn({
    this.assistant,
    this.streaming,
    this.user,
    this.error,
    this.status,
    this.recoverable,
    List<DesktopInflightCorrection> corrections = const [],
    this.startedAt,
    this.updatedAt,
    this.raw = const {},
  }) : corrections = List<DesktopInflightCorrection>.unmodifiable(corrections);

  static DesktopInflightTurn? tryParse(Object? value) {
    final json = _stringKeyedMap(value);
    if (json == null) return null;
    final assistant = _stringValue(json['assistant']);
    final streaming = json['streaming'] is bool
        ? json['streaming'] as bool
        : null;
    final user = _stringValue(json['user']);
    final error = _nonEmptyString(json['error']);
    final status = _nonEmptyString(json['status']);
    final recoverable = json['recoverable'] is bool
        ? json['recoverable'] as bool
        : null;
    final corrections = <DesktopInflightCorrection>[];
    final rawCorrections = json['corrections'];
    if (rawCorrections is List) {
      for (final value in rawCorrections) {
        final correction = DesktopInflightCorrection.tryParse(value);
        if (correction != null) corrections.add(correction);
      }
    }
    final terminalStatus = status?.toLowerCase() == 'error';
    if (assistant == null &&
        streaming == null &&
        user == null &&
        error == null &&
        !terminalStatus &&
        corrections.isEmpty) {
      return null;
    }
    return DesktopInflightTurn(
      assistant: assistant,
      streaming: streaming,
      user: user,
      error: error,
      status: status,
      recoverable: recoverable,
      corrections: corrections,
      startedAt: _epochSeconds(json['started_at']),
      updatedAt: _epochSeconds(json['updated_at']),
      raw: _freezeExtras(json, _inflightParsedKeys),
    );
  }
}

class DesktopInflightCorrection {
  final String text;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final Map<String, dynamic> raw;

  DesktopInflightCorrection({
    required this.text,
    this.createdAt,
    this.updatedAt,
    Map<String, dynamic> raw = const {},
  }) : raw = Map<String, dynamic>.unmodifiable(raw);

  static DesktopInflightCorrection? tryParse(Object? value) {
    final plainText = _nonEmptyString(value);
    if (plainText != null) {
      return DesktopInflightCorrection(text: plainText);
    }

    final json = _stringKeyedMap(value);
    if (json == null) return null;
    final text = _nonEmptyString(json['text']);
    if (text == null) return null;
    return DesktopInflightCorrection(
      text: text,
      createdAt: _epochSeconds(json['created_at']),
      updatedAt: _epochSeconds(json['updated_at']),
      raw: _freezeExtras(json, _inflightCorrectionParsedKeys),
    );
  }
}

class DesktopQueuedTurn {
  final String user;
  final Map<String, dynamic> raw;

  const DesktopQueuedTurn({required this.user, this.raw = const {}});

  static DesktopQueuedTurn? tryParse(Object? value) {
    final json = _stringKeyedMap(value);
    if (json == null) return null;
    final user = _nonEmptyString(json['user']);
    if (user == null) return null;
    return DesktopQueuedTurn(
      user: user,
      raw: _freezeExtras(json, _queuedParsedKeys),
    );
  }
}

class DesktopSessionRuntimeInfo {
  final String? model;
  final String? provider;
  final String? reasoningEffort;
  final String? serviceTier;
  final bool? fast;
  final bool? yolo;
  final String? approvalMode;
  final int? toolCount;
  final int? skillCount;
  final String? cwd;
  final String? branch;
  final Map<String, dynamic>? project;
  final String? personality;
  final bool? running;
  final bool? lazy;
  final String? title;
  final String? storedSessionId;
  final int? desktopContract;
  final String? version;
  final String? releaseDate;
  final Object? updateBehind;
  final String? updateCommand;
  final DesktopUsageStats? usage;
  final String? profileName;
  final int? mcpServerCount;
  final String? configWarning;
  final String? credentialWarning;
  final String? installWarning;
  final Map<String, dynamic> raw;

  const DesktopSessionRuntimeInfo({
    this.model,
    this.provider,
    this.reasoningEffort,
    this.serviceTier,
    this.fast,
    this.yolo,
    this.approvalMode,
    this.toolCount,
    this.skillCount,
    this.cwd,
    this.branch,
    this.project,
    this.personality,
    this.running,
    this.lazy,
    this.title,
    this.storedSessionId,
    this.desktopContract,
    this.version,
    this.releaseDate,
    this.updateBehind,
    this.updateCommand,
    this.usage,
    this.profileName,
    this.mcpServerCount,
    this.configWarning,
    this.credentialWarning,
    this.installWarning,
    this.raw = const {},
  });

  factory DesktopSessionRuntimeInfo.fromJson(Object? value) {
    final json = _stringKeyedMap(value);
    if (json == null) return const DesktopSessionRuntimeInfo();
    final project = _stringKeyedMap(json['project']);
    final rawMcpServers = json['mcp_servers'];
    return DesktopSessionRuntimeInfo(
      model: _nonEmptyString(json['model']),
      provider: _nonEmptyString(json['provider']),
      reasoningEffort: _nonEmptyString(json['reasoning_effort']),
      serviceTier: _nonEmptyString(json['service_tier']),
      fast: json['fast'] is bool ? json['fast'] as bool : null,
      yolo: json['yolo'] is bool ? json['yolo'] as bool : null,
      approvalMode: _nonEmptyString(json['approval_mode']),
      // Session info is a hot event. Keep inventory counts, not full tool,
      // skill or MCP payloads; catalogs are loaded explicitly elsewhere.
      toolCount: _nestedCollectionCount(json['tools']),
      skillCount: _collectionCount(json['skills']),
      cwd: _nonEmptyString(json['cwd']),
      branch: _nonEmptyString(json['branch']),
      project: project == null ? null : _freezeMap(project),
      personality: _stringValue(json['personality']),
      running: json['running'] is bool ? json['running'] as bool : null,
      lazy: json['lazy'] is bool ? json['lazy'] as bool : null,
      title: _stringValue(json['title']),
      storedSessionId: _nonEmptyString(json['stored_session_id']),
      desktopContract: _nonNegativeInt(json['desktop_contract']),
      version: _nonEmptyString(json['version']),
      releaseDate: _nonEmptyString(json['release_date']),
      updateBehind: _freezeJson(json['update_behind']),
      updateCommand: _nonEmptyString(json['update_command']),
      usage: json['usage'] is Map
          ? DesktopUsageStats.fromJson(json['usage'])
          : null,
      profileName: _nonEmptyString(json['profile_name']),
      mcpServerCount: rawMcpServers is List ? rawMcpServers.length : null,
      configWarning: _nonEmptyString(json['config_warning']),
      credentialWarning: _nonEmptyString(json['credential_warning']),
      installWarning: _nonEmptyString(json['install_warning']),
      // `system_prompt` is deliberately neither parsed nor retained.
      raw: _freezeExtras(json, _runtimeInfoParsedKeys),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopSessionRuntimeInfo &&
          model == other.model &&
          provider == other.provider &&
          reasoningEffort == other.reasoningEffort &&
          serviceTier == other.serviceTier &&
          fast == other.fast &&
          yolo == other.yolo &&
          approvalMode == other.approvalMode &&
          toolCount == other.toolCount &&
          skillCount == other.skillCount &&
          cwd == other.cwd &&
          branch == other.branch &&
          _deepJsonEquals(project, other.project) &&
          personality == other.personality &&
          running == other.running &&
          lazy == other.lazy &&
          title == other.title &&
          storedSessionId == other.storedSessionId &&
          desktopContract == other.desktopContract &&
          version == other.version &&
          releaseDate == other.releaseDate &&
          _deepJsonEquals(updateBehind, other.updateBehind) &&
          updateCommand == other.updateCommand &&
          usage == other.usage &&
          profileName == other.profileName &&
          mcpServerCount == other.mcpServerCount &&
          configWarning == other.configWarning &&
          credentialWarning == other.credentialWarning &&
          installWarning == other.installWarning &&
          _deepJsonEquals(raw, other.raw);

  @override
  int get hashCode => Object.hashAll([
    model,
    provider,
    reasoningEffort,
    serviceTier,
    fast,
    yolo,
    approvalMode,
    toolCount,
    skillCount,
    cwd,
    branch,
    _deepJsonHash(project),
    personality,
    running,
    lazy,
    title,
    storedSessionId,
    desktopContract,
    version,
    releaseDate,
    _deepJsonHash(updateBehind),
    updateCommand,
    usage,
    profileName,
    mcpServerCount,
    configWarning,
    credentialWarning,
    installWarning,
    _deepJsonHash(raw),
  ]);
}

class DesktopUsageStats {
  final int? calls;
  final int? input;
  final int? output;
  final int? total;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final int? contextUsed;
  final int? contextMax;
  final double? contextPercent;
  final double? costUsd;
  final Map<String, dynamic> raw;

  const DesktopUsageStats({
    this.calls,
    this.input,
    this.output,
    this.total,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.contextUsed,
    this.contextMax,
    this.contextPercent,
    this.costUsd,
    this.raw = const {},
  });

  factory DesktopUsageStats.fromJson(Object? value) {
    final json = _stringKeyedMap(value) ?? const <String, dynamic>{};
    return DesktopUsageStats(
      calls: _nonNegativeInt(json['calls']),
      input: _nonNegativeInt(json['input']),
      output: _nonNegativeInt(json['output']),
      total: _nonNegativeInt(json['total']),
      cacheReadTokens: _nonNegativeInt(json['cache_read_tokens']),
      cacheWriteTokens: _nonNegativeInt(json['cache_write_tokens']),
      contextUsed: _nonNegativeInt(json['context_used']),
      contextMax: _positiveInt(json['context_max']),
      contextPercent: _nonNegativeDouble(json['context_percent']),
      costUsd: _nonNegativeDouble(json['cost_usd']),
      raw: _freezeExtras(json, _usageParsedKeys),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopUsageStats &&
          calls == other.calls &&
          input == other.input &&
          output == other.output &&
          total == other.total &&
          cacheReadTokens == other.cacheReadTokens &&
          cacheWriteTokens == other.cacheWriteTokens &&
          contextUsed == other.contextUsed &&
          contextMax == other.contextMax &&
          contextPercent == other.contextPercent &&
          costUsd == other.costUsd &&
          _deepJsonEquals(raw, other.raw);

  @override
  int get hashCode => Object.hash(
    calls,
    input,
    output,
    total,
    cacheReadTokens,
    cacheWriteTokens,
    contextUsed,
    contextMax,
    contextPercent,
    costUsd,
    _deepJsonHash(raw),
  );
}

String? _stringValue(Object? value) => value is String ? value : null;

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _stableOpaqueId(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,255}$').hasMatch(trimmed)) {
    return null;
  }
  return trimmed;
}

int? _nonNegativeInt(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  final integer = value.toInt();
  return value == integer ? integer : null;
}

int? _positiveInt(Object? value) {
  final parsed = _nonNegativeInt(value);
  return parsed != null && parsed > 0 ? parsed : null;
}

double? _nonNegativeDouble(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  return value.toDouble();
}

DateTime? _epochSeconds(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  try {
    return DateTime.fromMicrosecondsSinceEpoch(
      (value.toDouble() * Duration.microsecondsPerSecond).round(),
      isUtc: true,
    );
  } on RangeError {
    return null;
  }
}

Map<String, dynamic>? _stringKeyedMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is String) result[entry.key as String] = entry.value;
  }
  return result;
}

int? _collectionCount(Object? value) {
  if (value is List) return value.length;
  if (value is Map) return value.length;
  return null;
}

int? _nestedCollectionCount(Object? value) {
  final json = _stringKeyedMap(value);
  if (json == null) return null;
  var count = 0;
  for (final item in json.values) {
    if (item is List) {
      count += item.length;
    } else if (item is Map) {
      count += item.length;
    }
  }
  return count;
}

Map<String, dynamic> _freezeMap(Map<String, dynamic> value) {
  return Map.unmodifiable(
    value.map((key, item) => MapEntry(key, _freezeJson(item))),
  );
}

Map<String, dynamic> _freezeArtifactContainers(Map<String, dynamic> value) {
  final containers = <String, dynamic>{};
  for (final key in _artifactContainerKeys) {
    final item = value[key];
    if (item is Map || item is List) {
      containers[key] = _freezeJson(item);
    }
  }
  return Map.unmodifiable(containers);
}

Object? _freezeJson(Object? value) {
  final map = _stringKeyedMap(value);
  if (map != null) return _freezeMap(map);
  if (value is List) {
    return List<Object?>.unmodifiable(value.map<Object?>(_freezeJson));
  }
  return value;
}

bool _deepJsonEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_deepJsonEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_deepJsonEquals(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

int _deepJsonHash(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return Object.hashAll(
      keys.map((key) => Object.hash(key, _deepJsonHash(value[key]))),
    );
  }
  if (value is List) return Object.hashAll(value.map(_deepJsonHash));
  return value.hashCode;
}

Map<String, dynamic> _freezeExtras(
  Map<String, dynamic> value,
  Set<String> parsedKeys,
) {
  final extras = <String, dynamic>{};
  for (final entry in value.entries) {
    if (parsedKeys.contains(entry.key)) continue;
    // Unknown payload-like fields fail closed. New structural fields remain
    // available for forward compatibility without retaining conversation text,
    // credentials or prompts.
    final normalized = entry.key.toLowerCase();
    if (_payloadKeyFragments.any(normalized.contains)) continue;
    final item = entry.value;
    if (item == null || item is bool || item is num) {
      extras[entry.key] = item;
    } else if (item is String && item.length <= 256) {
      extras[entry.key] = item;
    }
  }
  return Map.unmodifiable(extras);
}

const _payloadKeyFragments = <String>{
  'api_key',
  'auth',
  'content',
  'credential',
  'env',
  'message',
  'password',
  'prompt',
  'reasoning',
  'secret',
  'text',
  'token',
};

const _snapshotParsedKeys = <String>{
  'session_id',
  'stored_session_id',
  'session_key',
  'resumed',
  'messages',
  'message_count',
  'hydrating',
  'inflight',
  'queued',
  'running',
  'status',
  'started_at',
  'info',
  'pending_clarify',
};

const _messageParsedKeys = <String>{
  'message_id',
  'id',
  'role',
  'content',
  'text',
  'name',
  'reasoning',
  'reasoning_content',
  'reasoning_details',
  'codex_reasoning_items',
  'context',
  'timestamp',
  'tool_call_id',
  'tool_calls',
  'tool_name',
  'display_metadata',
  ..._artifactContainerKeys,
};

const _artifactContainerKeys = <String>{
  'attachment',
  'attachments',
  'artifact',
  'artifacts',
  'generated_image',
  'generated_images',
  'tool_result',
  'tool_results',
};

const _inflightParsedKeys = <String>{
  'assistant',
  'corrections',
  'error',
  'recoverable',
  'status',
  'streaming',
  'user',
  'started_at',
  'updated_at',
};

const _inflightCorrectionParsedKeys = <String>{
  'text',
  'created_at',
  'updated_at',
};

const _queuedParsedKeys = <String>{'user'};

const _runtimeInfoParsedKeys = <String>{
  'model',
  'provider',
  'reasoning_effort',
  'service_tier',
  'fast',
  'yolo',
  'approval_mode',
  'tools',
  'skills',
  'cwd',
  'branch',
  'project',
  'personality',
  'running',
  'lazy',
  'title',
  'stored_session_id',
  'desktop_contract',
  'version',
  'release_date',
  'update_behind',
  'update_command',
  'usage',
  'profile_name',
  'mcp_servers',
  'config_warning',
  'credential_warning',
  'install_warning',
  'system_prompt',
};

const _usageParsedKeys = <String>{
  'calls',
  'input',
  'output',
  'total',
  'cache_read_tokens',
  'cache_write_tokens',
  'context_used',
  'context_max',
  'context_percent',
  'cost_usd',
};
