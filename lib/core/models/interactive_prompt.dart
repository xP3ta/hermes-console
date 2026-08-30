/// Typed projection of the Hermes Desktop blocking request events.
///
/// Requests are kept in memory only. In particular, sudo passwords and secret
/// values are response data and never belong in these models.
enum InteractivePromptKind { clarify, sudo, secret, terminalRead }

extension InteractivePromptKindGatewayType on InteractivePromptKind {
  static InteractivePromptKind? tryParse(String type) => switch (type) {
    'clarify.request' => InteractivePromptKind.clarify,
    'sudo.request' => InteractivePromptKind.sudo,
    'secret.request' => InteractivePromptKind.secret,
    'terminal.read.request' => InteractivePromptKind.terminalRead,
    _ => null,
  };
}

enum InteractivePromptStatus {
  pending,
  responding,
  responded,
  cancelled,
  expired,
}

extension InteractivePromptStatusLifecycle on InteractivePromptStatus {
  bool get isTerminal =>
      this == InteractivePromptStatus.responded ||
      this == InteractivePromptStatus.cancelled ||
      this == InteractivePromptStatus.expired;
}

/// Opaque identity of one blocking request inside one live Desktop runtime.
///
/// Request IDs are only unique inside their runtime, so neither component may
/// be dropped when parking or resolving a prompt.
final class InteractivePromptKey {
  final String runtimeSessionId;
  final String requestId;

  factory InteractivePromptKey({
    required String runtimeSessionId,
    required String requestId,
  }) {
    if (runtimeSessionId.trim().isEmpty) {
      throw const FormatException('Missing runtime session id');
    }
    if (requestId.trim().isEmpty) {
      throw const FormatException('Missing interactive request id');
    }
    return InteractivePromptKey._(runtimeSessionId, requestId);
  }

  const InteractivePromptKey._(this.runtimeSessionId, this.requestId);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InteractivePromptKey &&
          runtimeSessionId == other.runtimeSessionId &&
          requestId == other.requestId;

  @override
  int get hashCode => Object.hash(runtimeSessionId, requestId);

  @override
  String toString() =>
      'InteractivePromptKey(runtime: $runtimeSessionId, request: $requestId)';
}

enum InteractivePromptFailureScope { exactKey, runtimeKind, transport }

enum InteractivePromptFailureCode { malformedPayload, runtimeUnavailable }

enum InteractivePromptParseSource { ordinaryEvent, authoritativeKindSlot }

/// Sanitized result of interpreting one recognized interactive protocol field.
///
/// Failures retain only validated identity/discriminator data. They never keep
/// the source map, parse exception, question text, choices, answers, or values.
sealed class InteractivePromptParseOutcome {
  final InteractivePromptKind kind;

  const InteractivePromptParseOutcome(this.kind);

  static InteractivePromptParseOutcome? tryFromGatewayEvent({
    required String type,
    required Object? runtimeSessionId,
    required Object? payload,
    InteractivePromptParseSource source =
        InteractivePromptParseSource.ordinaryEvent,
  }) {
    final kind = InteractivePromptKindGatewayType.tryParse(type);
    if (kind == null) return null;
    final runtimeId = _nonEmptyString(runtimeSessionId);
    if (runtimeId == null) {
      return InteractivePromptParseFailure._transport(kind);
    }

    final requestId = payload is Map
        ? _nonEmptyString(payload['request_id'])
        : null;
    final key = requestId == null
        ? null
        : InteractivePromptKey(
            runtimeSessionId: runtimeId,
            requestId: requestId,
          );
    final normalized = _strictStringKeyedMap(payload);
    if (normalized == null) {
      return _malformed(kind, runtimeId, key, source);
    }
    try {
      return InteractivePromptParsed(
        InteractivePromptRequest.fromGatewayEvent(
          type: type,
          runtimeSessionId: runtimeId,
          payload: normalized,
        ),
      );
    } on FormatException {
      return _malformed(kind, runtimeId, key, source);
    }
  }

  static InteractivePromptParseFailure _malformed(
    InteractivePromptKind kind,
    String runtimeSessionId,
    InteractivePromptKey? key,
    InteractivePromptParseSource source,
  ) {
    if (source == InteractivePromptParseSource.authoritativeKindSlot ||
        key == null) {
      return InteractivePromptParseFailure._runtimeKind(kind, runtimeSessionId);
    }
    return InteractivePromptParseFailure._exact(kind, key);
  }
}

final class InteractivePromptParsed extends InteractivePromptParseOutcome {
  final InteractivePromptRequest request;

  InteractivePromptParsed(this.request) : super(request.kind);

  @override
  String toString() => 'InteractivePromptParsed(kind: ${kind.name})';
}

final class InteractivePromptParseFailure
    extends InteractivePromptParseOutcome {
  final InteractivePromptFailureScope scope;
  final InteractivePromptFailureCode code;
  final InteractivePromptKey? key;
  final String? runtimeSessionId;

  InteractivePromptParseFailure._({
    required InteractivePromptKind kind,
    required this.scope,
    required this.code,
    this.key,
    this.runtimeSessionId,
  }) : super(kind);

  InteractivePromptParseFailure._exact(
    InteractivePromptKind kind,
    InteractivePromptKey key,
  ) : this._(
        kind: kind,
        scope: InteractivePromptFailureScope.exactKey,
        code: InteractivePromptFailureCode.malformedPayload,
        key: key,
        runtimeSessionId: key.runtimeSessionId,
      );

  InteractivePromptParseFailure._runtimeKind(
    InteractivePromptKind kind,
    String runtimeSessionId,
  ) : this._(
        kind: kind,
        scope: InteractivePromptFailureScope.runtimeKind,
        code: InteractivePromptFailureCode.malformedPayload,
        runtimeSessionId: runtimeSessionId,
      );

  InteractivePromptParseFailure._transport(InteractivePromptKind kind)
    : this._(
        kind: kind,
        scope: InteractivePromptFailureScope.transport,
        code: InteractivePromptFailureCode.runtimeUnavailable,
      );

  @override
  String toString() =>
      'InteractivePromptParseFailure(kind: ${kind.name}, '
      'scope: ${scope.name}, code: ${code.name})';
}

sealed class InteractivePromptRequest {
  final InteractivePromptKey key;

  const InteractivePromptRequest({required this.key});

  InteractivePromptKind get kind;

  /// Parses only the documented fields and never retains the source map.
  ///
  /// Unknown event types and malformed identities fail closed. This keeps a
  /// future gateway payload from becoming an accidental secret container.
  static InteractivePromptRequest fromGatewayEvent({
    required String type,
    required String runtimeSessionId,
    required Map<String, dynamic> payload,
  }) => switch (type) {
    'clarify.request' => ClarifyPromptRequest.fromGatewayEvent(
      runtimeSessionId: runtimeSessionId,
      payload: payload,
    ),
    'sudo.request' => SudoPromptRequest.fromGatewayEvent(
      runtimeSessionId: runtimeSessionId,
      payload: payload,
    ),
    'secret.request' => SecretPromptRequest.fromGatewayEvent(
      runtimeSessionId: runtimeSessionId,
      payload: payload,
    ),
    'terminal.read.request' => TerminalReadPromptRequest.fromGatewayEvent(
      runtimeSessionId: runtimeSessionId,
      payload: payload,
    ),
    _ => throw FormatException('Unsupported interactive event type: $type'),
  };

  /// Safe request metadata only. Response passwords/values cannot enter this
  /// representation because no request type has a field for them.
  Map<String, Object?> toJson();

  @override
  String toString() => '$runtimeType(key: $key)';
}

final class ClarifyQuestion {
  final String qid;
  final String question;
  final List<String> choices;
  final bool multiSelect;

  const ClarifyQuestion({
    required this.qid,
    required this.question,
    this.choices = const [],
    this.multiSelect = false,
  });

  factory ClarifyQuestion._fromJson(Object? value) {
    final json = _stringKeyedMap(value);
    if (json == null) {
      throw const FormatException('Invalid clarify question');
    }
    final qid = _nonEmptyString(json['qid']);
    final question = _nonEmptyString(json['question']);
    if (qid == null || question == null) {
      throw const FormatException('Missing clarify question id or text');
    }
    final choices = _parseClarifyChoices(json);
    final multiSelect = _parseClarifyMultiSelect(json, choices);
    return ClarifyQuestion(
      qid: qid,
      question: question,
      choices: choices,
      multiSelect: multiSelect,
    );
  }

  @override
  String toString() => 'ClarifyQuestion(<redacted>)';
}

final class ClarifyPromptRequest extends InteractivePromptRequest {
  final String question;
  final List<String> choices;
  final bool multiSelect;
  final List<ClarifyQuestion> questions;
  final Map<String, String> lockedAnswers;

  ClarifyPromptRequest({
    required super.key,
    this.question = '',
    List<String> choices = const [],
    this.multiSelect = false,
    List<ClarifyQuestion> questions = const [],
    Map<String, String> lockedAnswers = const {},
  }) : choices = List.unmodifiable(choices),
       questions = List.unmodifiable(questions),
       lockedAnswers = Map.unmodifiable(lockedAnswers);

  bool get isBatch => questions.isNotEmpty;

  ClarifyPromptRequest copyWith({Map<String, String>? lockedAnswers}) =>
      ClarifyPromptRequest(
        key: key,
        question: question,
        choices: choices,
        multiSelect: multiSelect,
        questions: questions,
        lockedAnswers: lockedAnswers ?? this.lockedAnswers,
      );

  factory ClarifyPromptRequest.fromGatewayEvent({
    required String runtimeSessionId,
    required Map<String, dynamic> payload,
  }) {
    final key = _requestKey(runtimeSessionId, payload);
    final hasBatch = payload.containsKey('questions');
    final questions = hasBatch
        ? _normalizeClarifyQuestions(payload['questions'])
        : const <ClarifyQuestion>[];
    final lockedAnswers = _parseLockedAnswers(payload);
    if (hasBatch) {
      if (questions.isEmpty) {
        throw const FormatException('Empty clarify batch');
      }
      final qids = questions.map((question) => question.qid).toSet();
      if (lockedAnswers.keys.any((qid) => !qids.contains(qid))) {
        throw const FormatException('Clarify answer references unknown qid');
      }
      return ClarifyPromptRequest(
        key: key,
        questions: questions,
        lockedAnswers: lockedAnswers,
      );
    }
    final question = _nonEmptyString(payload['question']) ?? '';
    if (question.isEmpty) {
      throw const FormatException('Missing or invalid clarify question');
    }
    if (lockedAnswers.isNotEmpty) {
      throw const FormatException(
        'Legacy clarify cannot contain batch answers',
      );
    }
    final choices = _parseClarifyChoices(payload);
    final multiSelect = _parseClarifyMultiSelect(payload, choices);
    if (multiSelect) {
      throw const FormatException('Legacy clarify cannot use multi_select');
    }
    return ClarifyPromptRequest(
      key: key,
      question: question,
      choices: choices,
      multiSelect: false,
      lockedAnswers: lockedAnswers,
    );
  }

  @override
  InteractivePromptKind get kind => InteractivePromptKind.clarify;

  @override
  Map<String, Object?> toJson() {
    final base = <String, Object?>{
      'type': 'clarify.request',
      'runtime_session_id': key.runtimeSessionId,
      'request_id': key.requestId,
    };
    if (isBatch) {
      base['questions'] = questions
          .map(
            (q) => <String, Object?>{
              'qid': q.qid,
              'question': q.question,
              if (q.choices.isNotEmpty) 'choices': q.choices,
              if (q.multiSelect) 'multi_select': true,
            },
          )
          .toList(growable: false);
    } else {
      base['question'] = question;
      if (choices.isNotEmpty) base['choices'] = choices;
      if (multiSelect) base['multi_select'] = true;
    }
    if (lockedAnswers.isNotEmpty) {
      base['answers'] = Map<String, Object?>.of(lockedAnswers);
    }
    return base;
  }
}

/// A sudo challenge. The password is deliberately not representable here.
final class SudoPromptRequest extends InteractivePromptRequest {
  const SudoPromptRequest({required super.key});

  factory SudoPromptRequest.fromGatewayEvent({
    required String runtimeSessionId,
    required Map<String, dynamic> payload,
  }) => SudoPromptRequest(key: _requestKey(runtimeSessionId, payload));

  @override
  InteractivePromptKind get kind => InteractivePromptKind.sudo;

  @override
  Map<String, Object?> toJson() => {
    'type': 'sudo.request',
    'runtime_session_id': key.runtimeSessionId,
    'request_id': key.requestId,
  };
}

/// A named secret challenge. The submitted value is deliberately absent.
///
/// Gateway `metadata` is not retained: it is an open-ended map and therefore
/// cannot be proven safe to log, serialize, or keep after disconnect.
final class SecretPromptRequest extends InteractivePromptRequest {
  final String envVar;
  final String prompt;

  const SecretPromptRequest({
    required super.key,
    required this.envVar,
    required this.prompt,
  });

  factory SecretPromptRequest.fromGatewayEvent({
    required String runtimeSessionId,
    required Map<String, dynamic> payload,
  }) => SecretPromptRequest(
    key: _requestKey(runtimeSessionId, payload),
    envVar: _requiredString(payload, 'env_var'),
    prompt: _requiredString(payload, 'prompt'),
  );

  @override
  InteractivePromptKind get kind => InteractivePromptKind.secret;

  @override
  Map<String, Object?> toJson() => {
    'type': 'secret.request',
    'runtime_session_id': key.runtimeSessionId,
    'request_id': key.requestId,
    'env_var': envVar,
    'prompt': prompt,
  };

  @override
  String toString() => 'SecretPromptRequest(key: $key, envVar: $envVar)';
}

final class TerminalReadPromptRequest extends InteractivePromptRequest {
  final int? start;
  final int? count;

  const TerminalReadPromptRequest({required super.key, this.start, this.count});

  factory TerminalReadPromptRequest.fromGatewayEvent({
    required String runtimeSessionId,
    required Map<String, dynamic> payload,
  }) => TerminalReadPromptRequest(
    key: _requestKey(runtimeSessionId, payload),
    start: _optionalInt(payload['start'], 'start'),
    count: _optionalInt(payload['count'], 'count'),
  );

  @override
  InteractivePromptKind get kind => InteractivePromptKind.terminalRead;

  @override
  Map<String, Object?> toJson() => {
    'type': 'terminal.read.request',
    'runtime_session_id': key.runtimeSessionId,
    'request_id': key.requestId,
    if (start != null) 'start': start,
    if (count != null) 'count': count,
  };
}

/// Mobile policy for a gateway terminal read when the app owns no managed
/// terminal pane. This is intentionally a constant empty response: it must not
/// inspect clipboard, files, process output, logs, or any ambient shell state.
abstract final class TerminalReadResponsePolicy {
  static const String noOwnedTerminalText = '';
}

/// One-use holder for a sudo password or secret response value.
///
/// Dart strings cannot be zeroed in place. `redact` and `dispose` therefore
/// clear this holder's reference as soon as possible; callers must likewise
/// avoid retaining the value returned by [take]. The value never appears in
/// serialization or diagnostics.
final class EphemeralSensitiveValue {
  String? _value;
  bool _disposed = false;

  EphemeralSensitiveValue(String value) : _value = value;

  bool get hasValue => !_disposed && _value != null;
  bool get isDisposed => _disposed;

  String take() {
    if (_disposed) {
      throw StateError('Sensitive value holder is disposed');
    }
    final value = _value;
    if (value == null) {
      throw StateError('Sensitive value has already been redacted');
    }
    _value = null;
    return value;
  }

  void redact() {
    _value = null;
  }

  void dispose() {
    if (_disposed) return;
    redact();
    _disposed = true;
  }

  Map<String, Object?> toJson() => const {'value': '<redacted>'};

  @override
  String toString() => 'EphemeralSensitiveValue(<redacted>)';
}

InteractivePromptKey _requestKey(
  String runtimeSessionId,
  Map<String, dynamic> payload,
) => InteractivePromptKey(
  runtimeSessionId: runtimeSessionId,
  requestId: _requiredString(payload, 'request_id'),
);

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Missing or invalid $key');
  }
  return value;
}

int? _optionalInt(Object? value, String key) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.toInt()) {
    return value.toInt();
  }
  throw FormatException('Invalid $key');
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  return value.trim().isEmpty ? null : value;
}

Map<String, dynamic>? _stringKeyedMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) continue;
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, dynamic>? _strictStringKeyedMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<String> _parseClarifyChoices(Map<String, dynamic> json) {
  if (!json.containsKey('choices')) return const [];
  final value = json['choices'];
  if (value is! List) {
    throw const FormatException('Invalid clarify choices');
  }
  final result = <String>[];
  final seen = <String>{};
  for (final item in value) {
    if (item is! String) {
      throw const FormatException('Invalid clarify choice');
    }
    if (item.trim().isEmpty ||
        item.contains('\n') ||
        item.contains('\r') ||
        !seen.add(item)) {
      throw const FormatException('Invalid clarify choice');
    }
    result.add(item);
  }
  return List.unmodifiable(result);
}

bool _parseClarifyMultiSelect(Map<String, dynamic> json, List<String> choices) {
  if (!json.containsKey('multi_select')) return false;
  final value = json['multi_select'];
  if (value is! bool) {
    throw const FormatException('Invalid clarify multi_select');
  }
  if (value && choices.isEmpty) {
    throw const FormatException('multi_select requires choices');
  }
  return value;
}

List<ClarifyQuestion> _normalizeClarifyQuestions(Object? value) {
  if (value is! List) {
    throw const FormatException('Invalid clarify questions');
  }
  final result = <ClarifyQuestion>[];
  final seen = <String>{};
  for (final item in value) {
    final question = ClarifyQuestion._fromJson(item);
    if (!seen.add(question.qid)) {
      throw const FormatException('Duplicate qid in clarify batch');
    }
    result.add(question);
  }
  return List.unmodifiable(result);
}

Map<String, String> _parseLockedAnswers(Map<String, dynamic> payload) {
  if (!payload.containsKey('answers')) return const {};
  final value = payload['answers'];
  if (value is! Map) {
    throw const FormatException('Invalid clarify answers');
  }
  final result = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw const FormatException('Invalid clarify answer qid');
    }
    final qid = _nonEmptyString(entry.key);
    final answer = _nonEmptyString(entry.value);
    if (qid == null || answer == null || result.containsKey(qid)) {
      throw const FormatException('Invalid clarify answer');
    }
    result[qid] = answer;
  }
  return Map.unmodifiable(result);
}
