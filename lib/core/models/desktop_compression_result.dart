import 'desktop_session_snapshot.dart';

/// The exact non-error replies emitted by `session.compress`.
///
/// `lockHeld` deliberately has no wire `status`: the server emits
/// `{compressed:false, lock_held:true}` for that branch. Keeping it in this
/// enum prevents callers from treating a missing status as a successful
/// compression.
enum DesktopCompressionStatus {
  compressed,
  noOp,
  aborted,
  pending,
  lockHeld;

  bool get isTerminal =>
      this == DesktopCompressionStatus.compressed ||
      this == DesktopCompressionStatus.noOp ||
      this == DesktopCompressionStatus.aborted;

  bool get isSuccess =>
      this == DesktopCompressionStatus.compressed ||
      this == DesktopCompressionStatus.noOp;
}

/// Typed, fail-closed result of `session.compress` (Hermes Desktop 0.19).
///
/// Terminal compute-host replies may contain only a subset of the in-process
/// transcript fields. Those fields are therefore nullable rather than being
/// synthesized as empty values. In particular, `pending` and `lockHeld` never
/// manufacture a transcript, summary, usage, or session identity.
final class DesktopCompressionResult {
  final DesktopCompressionStatus outcome;
  final int? removed;
  final int? beforeMessages;
  final int? afterMessages;
  final int? beforeTokens;
  final int? afterTokens;
  final DesktopCompressionSummary? summary;
  final DesktopUsageStats? usage;
  final DesktopSessionRuntimeInfo? info;
  final List<DesktopSessionMessage>? messages;
  final bool turnIsolation;

  const DesktopCompressionResult._({
    required this.outcome,
    this.removed,
    this.beforeMessages,
    this.afterMessages,
    this.beforeTokens,
    this.afterTokens,
    this.summary,
    this.usage,
    this.info,
    this.messages,
    this.turnIsolation = false,
  });

  /// String form retained for existing callers. `lockHeld` has no wire status.
  String? get status => switch (outcome) {
    DesktopCompressionStatus.compressed => 'compressed',
    DesktopCompressionStatus.noOp => 'compressed',
    DesktopCompressionStatus.aborted => 'aborted',
    DesktopCompressionStatus.pending => 'pending',
    DesktopCompressionStatus.lockHeld => null,
  };

  DesktopCompressionStatus get kind => outcome;
  bool get isSuccess => outcome.isSuccess;
  bool get isTerminal => outcome.isTerminal;
  bool get hasAuthoritativeTranscript => messages != null;

  /// A filtered model-context projection does not prove full display history.
  bool get hasFilteredTranscript =>
      messages != null &&
      afterMessages != null &&
      messages!.length < afterMessages!;
  bool get hasAuthoritativeSessionInfo => info != null;
  bool get isAuthoritativeNoProgress =>
      outcome == DesktopCompressionStatus.noOp &&
      removed == 0 &&
      (beforeMessages == null || afterMessages == beforeMessages) &&
      (beforeTokens == null || afterTokens == beforeTokens) &&
      summary?.noop == true &&
      summary?.aborted != true;

  factory DesktopCompressionResult.fromJson(Map<String, dynamic> response) {
    final json = _strictStringKeyedMap(response);
    if (json == null) _invalidResponse();

    if (!json.containsKey('status')) {
      return _parseLockHeld(json);
    }

    final status = json['status'];
    if (status is! String) _invalidResponse();
    return switch (status) {
      'compressed' => _parseTerminal(json, DesktopCompressionStatus.compressed),
      'aborted' => _parseTerminal(json, DesktopCompressionStatus.aborted),
      'pending' => _parsePending(json),
      _ => _invalidResponse(),
    };
  }

  static DesktopCompressionResult _parsePending(Map<String, dynamic> json) {
    if (!_containsOnly(json, _pendingFields) ||
        json['turn_isolation'] != true ||
        json['message'] is! String ||
        (json['message'] as String).trim().isEmpty) {
      _invalidResponse();
    }
    return const DesktopCompressionResult._(
      outcome: DesktopCompressionStatus.pending,
      turnIsolation: true,
    );
  }

  static DesktopCompressionResult _parseLockHeld(Map<String, dynamic> json) {
    if (!_containsOnly(json, _lockHeldFields) ||
        json['compressed'] is! bool ||
        json['compressed'] != false ||
        json['lock_held'] != true ||
        json['message'] is! String ||
        (json['message'] as String).trim().isEmpty) {
      _invalidResponse();
    }
    return const DesktopCompressionResult._(
      outcome: DesktopCompressionStatus.lockHeld,
    );
  }

  static DesktopCompressionResult _parseTerminal(
    Map<String, dynamic> json,
    DesktopCompressionStatus outcome,
  ) {
    if (!_containsOnly(json, _terminalFields)) _invalidResponse();

    final turnIsolation = json['turn_isolation'];
    if (turnIsolation != null && turnIsolation != true) _invalidResponse();
    if (json.containsKey('host_ack') &&
        _strictStringKeyedMap(json['host_ack']) == null) {
      _invalidResponse();
    }

    final removed = _optionalNonNegativeInt(json, 'removed');
    final beforeMessages = _optionalNonNegativeInt(json, 'before_messages');
    final afterMessages = _optionalNonNegativeInt(json, 'after_messages');
    final beforeTokens = _optionalNonNegativeInt(json, 'before_tokens');
    final afterTokens = _optionalNonNegativeInt(json, 'after_tokens');

    if ((beforeMessages == null) != (afterMessages == null) ||
        (beforeTokens == null) != (afterTokens == null)) {
      _invalidResponse();
    }
    if (beforeMessages != null &&
        afterMessages != null &&
        (afterMessages > beforeMessages ||
            (removed != null && removed != beforeMessages - afterMessages))) {
      _invalidResponse();
    }

    final messages = _parseMessages(json);

    DesktopCompressionSummary? summary;
    if (json.containsKey('summary')) {
      final rawSummary = _strictStringKeyedMap(json['summary']);
      if (rawSummary == null) _invalidResponse();
      summary = DesktopCompressionSummary.fromJson(rawSummary);
    }
    if (outcome == DesktopCompressionStatus.aborted) {
      if (summary?.aborted != true) _invalidResponse();
    } else if (summary?.aborted == true) {
      _invalidResponse();
    }
    // `after_messages` counts model-context rows, whereas `messages` is
    // _history_to_messages(history): hidden scaffolding and empty tool-call
    // rows are filtered by Hermes. A smaller display projection is valid for
    // every terminal outcome, not just no-op. It is not a timeout or success
    // heuristic: status, counts, summary and each projected row stay validated.
    if (afterMessages != null &&
        (messages == null || messages.length > afterMessages)) {
      _invalidResponse();
    }

    DesktopUsageStats? usage;
    if (json.containsKey('usage')) {
      final rawUsage = _strictStringKeyedMap(json['usage']);
      if (rawUsage == null) _invalidResponse();
      _validateUsage(rawUsage);
      usage = DesktopUsageStats.fromJson(rawUsage);
    }

    DesktopSessionRuntimeInfo? info;
    if (json.containsKey('info')) {
      final rawInfo = _strictStringKeyedMap(json['info']);
      if (rawInfo == null) _invalidResponse();
      _validateExactInfoIdentity(rawInfo);
      info = DesktopSessionRuntimeInfo.fromJson(rawInfo);
    }

    final semanticOutcome =
        outcome == DesktopCompressionStatus.compressed &&
            removed == 0 &&
            (beforeMessages == null || afterMessages == beforeMessages) &&
            (beforeTokens == null || afterTokens == beforeTokens) &&
            summary?.noop == true &&
            summary?.aborted != true
        ? DesktopCompressionStatus.noOp
        : outcome;

    return DesktopCompressionResult._(
      outcome: semanticOutcome,
      removed: removed,
      beforeMessages: beforeMessages,
      afterMessages: afterMessages,
      beforeTokens: beforeTokens,
      afterTokens: afterTokens,
      summary: summary,
      usage: usage,
      info: info,
      messages: messages == null ? null : List.unmodifiable(messages),
      turnIsolation: turnIsolation == true,
    );
  }

  static List<DesktopSessionMessage>? _parseMessages(
    Map<String, dynamic> json,
  ) {
    if (!json.containsKey('messages')) return null;
    final rawMessages = json['messages'];
    if (rawMessages is! List) _invalidResponse();
    final messages = <DesktopSessionMessage>[];
    for (var index = 0; index < rawMessages.length; index++) {
      final message = DesktopSessionMessage.tryParse(
        rawMessages[index],
        serverOrdinal: index,
      );
      if (message == null || !message.identityAliasesConsistent) {
        _invalidTranscript();
      }
      messages.add(message);
    }
    return messages;
  }

  static int? _optionalNonNegativeInt(Map<String, dynamic> json, String key) {
    if (!json.containsKey(key)) return null;
    final value = json[key];
    // `bool` must never cross an integer/count boundary, even on platforms
    // where a permissive decoder could otherwise coerce it.
    if (value is! int || value < 0) _invalidResponse();
    return value;
  }

  static void _validateExactInfoIdentity(Map<String, dynamic> info) {
    const rootAliases = <String>[
      '_lineage_root_id',
      'lineage_root_id',
      'lineage_root',
    ];
    String? root;
    for (final key in const <String>[
      'stored_session_id',
      'session_id',
      'session_key',
      ...rootAliases,
    ]) {
      if (!info.containsKey(key)) continue;
      final value = info[key];
      if (value is! String || value.isEmpty || value != value.trim()) {
        _invalidResponse();
      }
      if (rootAliases.contains(key)) {
        if (root != null && root != value) _invalidResponse();
        root = value;
      }
    }
  }

  static void _validateUsage(Map<String, dynamic> usage) {
    for (final key in const <String>[
      'calls',
      'input',
      'output',
      'total',
      'cache_read_tokens',
      'cache_write_tokens',
      'context_used',
      'context_max',
      // This is the native completion boundary used to reconcile a pending
      // compute-host compression. It must be a real count too, never a
      // truthy/falsey transport coercion.
      'compressions',
    ]) {
      if (!usage.containsKey(key)) continue;
      final value = usage[key];
      if (value is! int || value < 0 || (key == 'context_max' && value == 0)) {
        _invalidResponse();
      }
    }
    for (final key in const <String>['context_percent', 'cost_usd']) {
      if (!usage.containsKey(key)) continue;
      final value = usage[key];
      if (value is! num || !value.isFinite || value < 0) _invalidResponse();
    }
  }
}

final class DesktopCompressionSummary {
  /// Compute-host acknowledgements can preserve only the human summary text.
  /// Do not manufacture a `false` value when their structured result omitted
  /// the in-process `noop` flag.
  final bool? noop;
  final bool? aborted;
  final bool? refusedWouldGrow;
  final bool? fallbackUsed;
  final String? headline;
  final String? tokenLine;
  final String? note;

  const DesktopCompressionSummary({
    this.noop,
    this.aborted,
    this.refusedWouldGrow,
    this.fallbackUsed,
    this.headline,
    this.tokenLine,
    this.note,
  });

  factory DesktopCompressionSummary.fromJson(Map<String, dynamic> json) {
    if (!_containsOnly(json, _summaryFields)) _invalidResponse();
    final noop = json['noop'];
    if (!_optionalBool(json, 'noop') ||
        !_optionalBool(json, 'aborted') ||
        !_optionalBool(json, 'refused_would_grow') ||
        !_optionalBool(json, 'fallback_used') ||
        !_optionalString(json, 'headline') ||
        !_optionalString(json, 'token_line') ||
        !_optionalString(json, 'note')) {
      _invalidResponse();
    }
    return DesktopCompressionSummary(
      noop: noop as bool?,
      aborted: json['aborted'] as bool?,
      refusedWouldGrow: json['refused_would_grow'] as bool?,
      fallbackUsed: json['fallback_used'] as bool?,
      headline: json['headline'] as String?,
      tokenLine: json['token_line'] as String?,
      note: json['note'] as String?,
    );
  }
}

const _terminalFields = <String>{
  'status',
  'turn_isolation',
  'host_ack',
  'removed',
  'before_messages',
  'after_messages',
  'before_tokens',
  'after_tokens',
  'summary',
  'usage',
  'info',
  'messages',
};

const _pendingFields = <String>{'status', 'turn_isolation', 'message'};
const _lockHeldFields = <String>{'compressed', 'lock_held', 'message'};
const _summaryFields = <String>{
  'noop',
  'aborted',
  'refused_would_grow',
  'fallback_used',
  'headline',
  'token_line',
  'note',
};

bool _containsOnly(Map<String, dynamic> json, Set<String> allowed) =>
    json.keys.every(allowed.contains);

bool _optionalBool(Map<String, dynamic> json, String key) =>
    !json.containsKey(key) || json[key] is bool;

bool _optionalString(Map<String, dynamic> json, String key) =>
    !json.containsKey(key) || json[key] == null || json[key] is String;

Map<String, dynamic>? _strictStringKeyedMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

Never _invalidResponse() =>
    throw const FormatException('invalid session.compress response');

Never _invalidTranscript() =>
    throw const FormatException('invalid compressed transcript');
