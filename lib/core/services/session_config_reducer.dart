import '../models/desktop_session_config.dart';
import '../models/desktop_session_snapshot.dart';

enum SessionConfigChangeStatus {
  sending,
  accepted,
  confirmed,
  rejected,
  timedOut,
  superseded,
  confirmRequired,
}

enum SessionConfigFailureKind {
  unsupported,
  rejected,
  busy,
  initialization,
  transport,
  timeout,
  invalidResponse,
  unsupportedMethod,
}

extension SessionConfigChangeLifecycle on SessionConfigChangeStatus {
  bool get awaitsAuthoritativeInfo =>
      this == SessionConfigChangeStatus.sending ||
      this == SessionConfigChangeStatus.accepted ||
      this == SessionConfigChangeStatus.timedOut;

  bool get canBeSuperseded =>
      awaitsAuthoritativeInfo ||
      this == SessionConfigChangeStatus.confirmRequired;
}

final class SessionConfigScope {
  final String connectionId;
  final String storedSessionId;
  final String runtimeSessionId;
  final String profileName;
  final int sessionEpoch;

  factory SessionConfigScope({
    required String connectionId,
    required String storedSessionId,
    required String runtimeSessionId,
    required String profileName,
    required int sessionEpoch,
  }) {
    if (!_isOpaqueId(connectionId) ||
        !_isOpaqueId(storedSessionId) ||
        !_isOpaqueId(runtimeSessionId) ||
        !_isOpaqueId(profileName)) {
      throw const FormatException('Invalid session config scope');
    }
    _validateEpoch(sessionEpoch, 'session');
    return SessionConfigScope._(
      connectionId: connectionId,
      storedSessionId: storedSessionId,
      runtimeSessionId: runtimeSessionId,
      profileName: profileName,
      sessionEpoch: sessionEpoch,
    );
  }

  const SessionConfigScope._({
    required this.connectionId,
    required this.storedSessionId,
    required this.runtimeSessionId,
    required this.profileName,
    required this.sessionEpoch,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionConfigScope &&
          connectionId == other.connectionId &&
          storedSessionId == other.storedSessionId &&
          runtimeSessionId == other.runtimeSessionId &&
          profileName == other.profileName &&
          sessionEpoch == other.sessionEpoch;

  @override
  int get hashCode => Object.hash(
    connectionId,
    storedSessionId,
    runtimeSessionId,
    profileName,
    sessionEpoch,
  );

  @override
  String toString() => 'SessionConfigScope(epoch: $sessionEpoch)';
}

sealed class SessionConfigValue {
  const SessionConfigValue();

  DesktopSessionConfigKey get key;
}

final class SessionModelConfigValue extends SessionConfigValue {
  final String modelId;
  final String? providerSlug;

  factory SessionModelConfigValue.requested(DesktopModelSelection selection) =>
      SessionModelConfigValue._(
        modelId: selection.modelId,
        providerSlug: selection.providerSlug,
      );

  factory SessionModelConfigValue.effective({
    required String modelId,
    String? providerSlug,
  }) => SessionModelConfigValue._(
    modelId: _requiredInfoValue(modelId, 'model', 256),
    providerSlug: _optionalInfoValue(providerSlug, 128),
  );

  const SessionModelConfigValue._({
    required this.modelId,
    required this.providerSlug,
  });

  @override
  DesktopSessionConfigKey get key => DesktopSessionConfigKey.model;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionModelConfigValue &&
          modelId == other.modelId &&
          providerSlug == other.providerSlug;

  @override
  int get hashCode => Object.hash(modelId, providerSlug);

  @override
  String toString() => 'SessionModelConfigValue(<bounded>)';
}

final class SessionReasoningConfigValue extends SessionConfigValue {
  final String effort;

  factory SessionReasoningConfigValue.requested(
    DesktopReasoningEffort effort,
  ) => SessionReasoningConfigValue._(effort.wire);

  factory SessionReasoningConfigValue.effective(String effort) =>
      SessionReasoningConfigValue._(
        _requiredInfoValue(effort, 'reasoning effort', 64),
      );

  const SessionReasoningConfigValue._(this.effort);

  @override
  DesktopSessionConfigKey get key => DesktopSessionConfigKey.reasoning;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionReasoningConfigValue && effort == other.effort;

  @override
  int get hashCode => effort.hashCode;

  @override
  String toString() => 'SessionReasoningConfigValue(<bounded>)';
}

final class SessionFastConfigValue extends SessionConfigValue {
  final bool enabled;

  const SessionFastConfigValue(this.enabled);

  factory SessionFastConfigValue.requested(DesktopFastMode mode) =>
      SessionFastConfigValue(mode == DesktopFastMode.fast);

  @override
  DesktopSessionConfigKey get key => DesktopSessionConfigKey.fast;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionFastConfigValue && enabled == other.enabled;

  @override
  int get hashCode => enabled.hashCode;

  @override
  String toString() => 'SessionFastConfigValue($enabled)';
}

/// Proyección estricta de `session.info`. No conserva el payload ni sus extras.
final class SessionConfigAuthoritativeInfo {
  final String? model;
  final String? provider;
  final String? reasoningEffort;
  final bool? fast;

  factory SessionConfigAuthoritativeInfo({
    String? model,
    String? provider,
    String? reasoningEffort,
    bool? fast,
  }) => SessionConfigAuthoritativeInfo._(
    model: _optionalInfoValue(model, 256),
    provider: _optionalInfoValue(provider, 128),
    reasoningEffort: _optionalInfoValue(reasoningEffort, 64),
    fast: fast,
  );

  const SessionConfigAuthoritativeInfo._({
    this.model,
    this.provider,
    this.reasoningEffort,
    this.fast,
  });

  factory SessionConfigAuthoritativeInfo.fromRuntimeInfo(
    DesktopSessionRuntimeInfo info,
  ) => SessionConfigAuthoritativeInfo._(
    model: _optionalInfoValue(info.model, 256),
    provider: _optionalInfoValue(info.provider, 128),
    reasoningEffort: _optionalInfoValue(info.reasoningEffort, 64),
    fast: info.fast,
  );

  bool reports(DesktopSessionConfigKey key) => switch (key) {
    DesktopSessionConfigKey.model => model != null,
    DesktopSessionConfigKey.reasoning => reasoningEffort != null,
    DesktopSessionConfigKey.fast => fast != null,
  };

  SessionConfigValue? valueFor(DesktopSessionConfigKey key) => switch (key) {
    DesktopSessionConfigKey.model when model != null =>
      SessionModelConfigValue.effective(
        modelId: model!,
        providerSlug: provider,
      ),
    DesktopSessionConfigKey.reasoning when reasoningEffort != null =>
      SessionReasoningConfigValue.effective(reasoningEffort!),
    DesktopSessionConfigKey.fast when fast != null => SessionFastConfigValue(
      fast!,
    ),
    _ => null,
  };
}

final class SessionEffectiveConfig {
  final String? model;
  final String? provider;
  final String? reasoningEffort;
  final bool? fast;

  const SessionEffectiveConfig({
    this.model,
    this.provider,
    this.reasoningEffort,
    this.fast,
  });

  SessionConfigValue? valueFor(DesktopSessionConfigKey key) => switch (key) {
    DesktopSessionConfigKey.model when model != null =>
      SessionModelConfigValue.effective(
        modelId: model!,
        providerSlug: provider,
      ),
    DesktopSessionConfigKey.reasoning when reasoningEffort != null =>
      SessionReasoningConfigValue.effective(reasoningEffort!),
    DesktopSessionConfigKey.fast when fast != null => SessionFastConfigValue(
      fast!,
    ),
    _ => null,
  };

  SessionEffectiveConfig merge(
    SessionConfigAuthoritativeInfo info, {
    required bool acceptModel,
    required bool acceptReasoning,
    required bool acceptFast,
  }) => SessionEffectiveConfig(
    model: acceptModel && info.model != null ? info.model : model,
    provider: acceptModel && info.provider != null ? info.provider : provider,
    reasoningEffort: acceptReasoning && info.reasoningEffort != null
        ? info.reasoningEffort
        : reasoningEffort,
    fast: acceptFast && info.fast != null ? info.fast : fast,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionEffectiveConfig &&
          model == other.model &&
          provider == other.provider &&
          reasoningEffort == other.reasoningEffort &&
          fast == other.fast;

  @override
  int get hashCode => Object.hash(model, provider, reasoningEffort, fast);

  @override
  String toString() => 'SessionEffectiveConfig(<bounded>)';
}

final class PendingSessionConfigChange {
  final SessionConfigScope scope;
  final DesktopSessionConfigKey key;
  final SessionConfigValue requestedValue;
  final SessionConfigValue? previousEffectiveValue;
  final int requestEpoch;
  final SessionConfigChangeStatus status;
  final SessionConfigFailureKind? failureKind;
  final String? warning;
  final String? confirmMessage;
  final SessionConfigValue? authoritativeValue;
  final Set<SessionConfigValue> supersededRequestedValues;

  PendingSessionConfigChange._({
    required this.scope,
    required this.key,
    required this.requestedValue,
    required this.previousEffectiveValue,
    required this.requestEpoch,
    required this.status,
    this.failureKind,
    this.warning,
    this.confirmMessage,
    this.authoritativeValue,
    Set<SessionConfigValue> supersededRequestedValues = const {},
  }) : supersededRequestedValues = Set.unmodifiable(supersededRequestedValues);

  SessionConfigValue? get displayValue => switch (status) {
    SessionConfigChangeStatus.sending ||
    SessionConfigChangeStatus.accepted => requestedValue,
    SessionConfigChangeStatus.confirmed => authoritativeValue,
    SessionConfigChangeStatus.rejected ||
    SessionConfigChangeStatus.timedOut ||
    SessionConfigChangeStatus.superseded ||
    SessionConfigChangeStatus.confirmRequired => previousEffectiveValue,
  };

  bool? get requestedWasApplied =>
      status == SessionConfigChangeStatus.confirmed &&
          authoritativeValue != null
      ? authoritativeValue == requestedValue
      : null;

  PendingSessionConfigChange _transition({
    required SessionConfigChangeStatus status,
    SessionConfigFailureKind? failureKind,
    String? warning,
    String? confirmMessage,
    SessionConfigValue? authoritativeValue,
  }) => PendingSessionConfigChange._(
    scope: scope,
    key: key,
    requestedValue: requestedValue,
    previousEffectiveValue: previousEffectiveValue,
    requestEpoch: requestEpoch,
    status: status,
    failureKind: failureKind,
    warning: warning,
    confirmMessage: confirmMessage,
    authoritativeValue: authoritativeValue,
    supersededRequestedValues: supersededRequestedValues,
  );

  @override
  String toString() =>
      'PendingSessionConfigChange(key: ${key.wire}, epoch: $requestEpoch, '
      'status: ${status.name})';
}

final class SessionConfigSessionState {
  final SessionEffectiveConfig effective;
  final Map<DesktopSessionConfigKey, PendingSessionConfigChange> changes;
  final int latestRequestEpoch;
  final int latestInfoEpoch;
  final bool isSuperseded;

  const SessionConfigSessionState.empty()
    : effective = const SessionEffectiveConfig(),
      changes = const {},
      latestRequestEpoch = -1,
      latestInfoEpoch = -1,
      isSuperseded = false;

  SessionConfigSessionState._({
    required this.effective,
    required Map<DesktopSessionConfigKey, PendingSessionConfigChange> changes,
    required this.latestRequestEpoch,
    required this.latestInfoEpoch,
    required this.isSuperseded,
  }) : changes = Map.unmodifiable(changes);

  PendingSessionConfigChange? operator [](DesktopSessionConfigKey key) =>
      changes[key];

  SessionConfigSessionState _copyWith({
    SessionEffectiveConfig? effective,
    Map<DesktopSessionConfigKey, PendingSessionConfigChange>? changes,
    int? latestRequestEpoch,
    int? latestInfoEpoch,
    bool? isSuperseded,
  }) => SessionConfigSessionState._(
    effective: effective ?? this.effective,
    changes: changes ?? this.changes,
    latestRequestEpoch: latestRequestEpoch ?? this.latestRequestEpoch,
    latestInfoEpoch: latestInfoEpoch ?? this.latestInfoEpoch,
    isSuperseded: isSuperseded ?? this.isSuperseded,
  );
}

final class SessionConfigReducerState {
  final Map<SessionConfigScope, SessionConfigSessionState> sessions;

  const SessionConfigReducerState.empty() : sessions = const {};

  SessionConfigReducerState._(
    Map<SessionConfigScope, SessionConfigSessionState> sessions,
  ) : sessions = Map.unmodifiable(sessions);

  SessionConfigSessionState? operator [](SessionConfigScope scope) =>
      sessions[scope];

  PendingSessionConfigChange? changeFor(
    SessionConfigScope scope,
    DesktopSessionConfigKey key,
  ) => sessions[scope]?[key];

  @override
  String toString() => 'SessionConfigReducerState(scopes: ${sessions.length})';
}

sealed class SessionConfigEvent {
  final SessionConfigScope scope;

  const SessionConfigEvent(this.scope);
}

final class SessionConfigSendStarted extends SessionConfigEvent {
  final SessionConfigValue requestedValue;
  final int requestEpoch;

  factory SessionConfigSendStarted({
    required SessionConfigScope scope,
    required SessionConfigValue requestedValue,
    required int requestEpoch,
  }) {
    _validateEpoch(requestEpoch, 'config request');
    return SessionConfigSendStarted._(
      scope: scope,
      requestedValue: requestedValue,
      requestEpoch: requestEpoch,
    );
  }

  const SessionConfigSendStarted._({
    required SessionConfigScope scope,
    required this.requestedValue,
    required this.requestEpoch,
  }) : super(scope);
}

final class SessionConfigRpcAccepted extends SessionConfigEvent {
  final int requestEpoch;
  final DesktopConfigSetResult result;

  factory SessionConfigRpcAccepted({
    required SessionConfigScope scope,
    required int requestEpoch,
    required DesktopConfigSetResult result,
  }) {
    _validateEpoch(requestEpoch, 'config request');
    return SessionConfigRpcAccepted._(
      scope: scope,
      requestEpoch: requestEpoch,
      result: result,
    );
  }

  const SessionConfigRpcAccepted._({
    required SessionConfigScope scope,
    required this.requestEpoch,
    required this.result,
  }) : super(scope);
}

final class SessionConfigRpcRejected extends SessionConfigEvent {
  final DesktopSessionConfigKey key;
  final int requestEpoch;
  final SessionConfigFailureKind failureKind;

  factory SessionConfigRpcRejected({
    required SessionConfigScope scope,
    required DesktopSessionConfigKey key,
    required int requestEpoch,
    required SessionConfigFailureKind failureKind,
  }) {
    _validateEpoch(requestEpoch, 'config request');
    return SessionConfigRpcRejected._(
      scope: scope,
      key: key,
      requestEpoch: requestEpoch,
      failureKind: failureKind,
    );
  }

  const SessionConfigRpcRejected._({
    required SessionConfigScope scope,
    required this.key,
    required this.requestEpoch,
    required this.failureKind,
  }) : super(scope);
}

final class SessionConfigTimedOut extends SessionConfigEvent {
  final DesktopSessionConfigKey key;
  final int requestEpoch;

  factory SessionConfigTimedOut({
    required SessionConfigScope scope,
    required DesktopSessionConfigKey key,
    required int requestEpoch,
  }) {
    _validateEpoch(requestEpoch, 'config request');
    return SessionConfigTimedOut._(
      scope: scope,
      key: key,
      requestEpoch: requestEpoch,
    );
  }

  const SessionConfigTimedOut._({
    required SessionConfigScope scope,
    required this.key,
    required this.requestEpoch,
  }) : super(scope);
}

final class SessionConfigRequestSuperseded extends SessionConfigEvent {
  final DesktopSessionConfigKey key;
  final int requestEpoch;

  factory SessionConfigRequestSuperseded({
    required SessionConfigScope scope,
    required DesktopSessionConfigKey key,
    required int requestEpoch,
  }) {
    _validateEpoch(requestEpoch, 'config request');
    return SessionConfigRequestSuperseded._(
      scope: scope,
      key: key,
      requestEpoch: requestEpoch,
    );
  }

  const SessionConfigRequestSuperseded._({
    required SessionConfigScope scope,
    required this.key,
    required this.requestEpoch,
  }) : super(scope);
}

final class SessionConfigScopeSuperseded extends SessionConfigEvent {
  const SessionConfigScopeSuperseded(super.scope);
}

final class SessionConfigInfoObserved extends SessionConfigEvent {
  final int infoEpoch;
  final int observedRequestEpoch;
  final SessionConfigAuthoritativeInfo info;

  factory SessionConfigInfoObserved({
    required SessionConfigScope scope,
    required int infoEpoch,
    required int observedRequestEpoch,
    required SessionConfigAuthoritativeInfo info,
  }) {
    _validateEpoch(infoEpoch, 'session info');
    _validateEpoch(observedRequestEpoch, 'observed config request');
    return SessionConfigInfoObserved._(
      scope: scope,
      infoEpoch: infoEpoch,
      observedRequestEpoch: observedRequestEpoch,
      info: info,
    );
  }

  const SessionConfigInfoObserved._({
    required SessionConfigScope scope,
    required this.infoEpoch,
    required this.observedRequestEpoch,
    required this.info,
  }) : super(scope);
}

abstract final class SessionConfigReducer {
  static SessionConfigReducerState reduce(
    SessionConfigReducerState state,
    SessionConfigEvent event,
  ) => switch (event) {
    SessionConfigSendStarted() => _start(state, event),
    SessionConfigRpcAccepted() => _accept(state, event),
    SessionConfigRpcRejected() => _reject(state, event),
    SessionConfigTimedOut() => _timeOut(state, event),
    SessionConfigRequestSuperseded() => _supersedeRequest(state, event),
    SessionConfigScopeSuperseded() => _supersedeScope(state, event),
    SessionConfigInfoObserved() => _observeInfo(state, event),
  };

  static SessionConfigReducerState _start(
    SessionConfigReducerState state,
    SessionConfigSendStarted event,
  ) {
    final session =
        state[event.scope] ?? const SessionConfigSessionState.empty();
    if (session.isSuperseded) return state;
    if (event.requestEpoch < session.latestRequestEpoch) return state;
    final current = session[event.requestedValue.key];
    if (event.requestEpoch == session.latestRequestEpoch) {
      if (current?.requestEpoch == event.requestEpoch &&
          current?.status == SessionConfigChangeStatus.sending &&
          current?.requestedValue == event.requestedValue) {
        return state;
      }
      return state;
    }

    final change = PendingSessionConfigChange._(
      scope: event.scope,
      key: event.requestedValue.key,
      requestedValue: event.requestedValue,
      previousEffectiveValue: session.effective.valueFor(
        event.requestedValue.key,
      ),
      requestEpoch: event.requestEpoch,
      status: SessionConfigChangeStatus.sending,
      supersededRequestedValues: {
        ...?current?.supersededRequestedValues,
        if (current?.status.canBeSuperseded == true) current!.requestedValue,
      },
    );
    final changes = Map<DesktopSessionConfigKey, PendingSessionConfigChange>.of(
      session.changes,
    );
    changes[change.key] = change;
    return _replaceSession(
      state,
      event.scope,
      session._copyWith(
        changes: changes,
        latestRequestEpoch: event.requestEpoch,
      ),
    );
  }

  static SessionConfigReducerState _accept(
    SessionConfigReducerState state,
    SessionConfigRpcAccepted event,
  ) {
    final key = event.result.key;
    final current = state.changeFor(event.scope, key);
    if (current == null || current.requestEpoch != event.requestEpoch) {
      return state;
    }
    if (current.status != SessionConfigChangeStatus.sending) return state;

    final warning = _optionalInfoValue(event.result.warning, 512);
    final confirmMessage = _optionalInfoValue(event.result.confirmMessage, 512);
    if (_optionalInfoValue(event.result.value, 512) == null ||
        (event.result.confirmRequired && confirmMessage == null)) {
      return _replaceChange(
        state,
        event.scope,
        current._transition(
          status: SessionConfigChangeStatus.rejected,
          failureKind: SessionConfigFailureKind.invalidResponse,
        ),
      );
    }

    final next = event.result.confirmRequired
        ? current._transition(
            status: SessionConfigChangeStatus.confirmRequired,
            warning: warning,
            confirmMessage: confirmMessage,
          )
        : current._transition(
            status: SessionConfigChangeStatus.accepted,
            warning: warning,
          );
    return _replaceChange(state, event.scope, next);
  }

  static SessionConfigReducerState _reject(
    SessionConfigReducerState state,
    SessionConfigRpcRejected event,
  ) {
    final current = state.changeFor(event.scope, event.key);
    if (current == null ||
        current.requestEpoch != event.requestEpoch ||
        current.status != SessionConfigChangeStatus.sending) {
      return state;
    }
    return _replaceChange(
      state,
      event.scope,
      current._transition(
        status: SessionConfigChangeStatus.rejected,
        failureKind: event.failureKind,
      ),
    );
  }

  static SessionConfigReducerState _timeOut(
    SessionConfigReducerState state,
    SessionConfigTimedOut event,
  ) {
    final current = state.changeFor(event.scope, event.key);
    if (current == null || current.requestEpoch != event.requestEpoch) {
      return state;
    }
    if (current.status != SessionConfigChangeStatus.sending &&
        current.status != SessionConfigChangeStatus.accepted) {
      return state;
    }
    return _replaceChange(
      state,
      event.scope,
      current._transition(
        status: SessionConfigChangeStatus.timedOut,
        failureKind: SessionConfigFailureKind.timeout,
      ),
    );
  }

  static SessionConfigReducerState _supersedeRequest(
    SessionConfigReducerState state,
    SessionConfigRequestSuperseded event,
  ) {
    final current = state.changeFor(event.scope, event.key);
    if (current == null ||
        current.requestEpoch != event.requestEpoch ||
        !current.status.canBeSuperseded) {
      return state;
    }
    return _replaceChange(
      state,
      event.scope,
      current._transition(status: SessionConfigChangeStatus.superseded),
    );
  }

  static SessionConfigReducerState _supersedeScope(
    SessionConfigReducerState state,
    SessionConfigScopeSuperseded event,
  ) {
    final session = state[event.scope];
    if (session == null) return state;
    if (session.isSuperseded) return state;
    Map<DesktopSessionConfigKey, PendingSessionConfigChange>? changed;
    for (final entry in session.changes.entries) {
      if (!entry.value.status.canBeSuperseded) continue;
      changed ??= Map.of(session.changes);
      changed[entry.key] = entry.value._transition(
        status: SessionConfigChangeStatus.superseded,
      );
    }
    return _replaceSession(
      state,
      event.scope,
      session._copyWith(
        changes: changed ?? session.changes,
        isSuperseded: true,
      ),
    );
  }

  static SessionConfigReducerState _observeInfo(
    SessionConfigReducerState state,
    SessionConfigInfoObserved event,
  ) {
    final session =
        state[event.scope] ?? const SessionConfigSessionState.empty();
    if (session.isSuperseded) return state;
    if (event.infoEpoch <= session.latestInfoEpoch) return state;

    bool accepts(DesktopSessionConfigKey key) {
      final change = session[key];
      if (change == null || !change.status.awaitsAuthoritativeInfo) return true;
      if (event.observedRequestEpoch < change.requestEpoch) return false;
      final reported = event.info.valueFor(key);
      if (reported == null ||
          _sameReportedValue(reported, change.requestedValue)) {
        return true;
      }
      if (change.previousEffectiveValue case final previous?) {
        if (_sameReportedValue(reported, previous)) return false;
      }
      return !change.supersededRequestedValues.any(
        (value) => _sameReportedValue(reported, value),
      );
    }

    final acceptModel = accepts(DesktopSessionConfigKey.model);
    final acceptReasoning = accepts(DesktopSessionConfigKey.reasoning);
    final acceptFast = accepts(DesktopSessionConfigKey.fast);
    final effective = session.effective.merge(
      event.info,
      acceptModel: acceptModel,
      acceptReasoning: acceptReasoning,
      acceptFast: acceptFast,
    );
    final changes = Map<DesktopSessionConfigKey, PendingSessionConfigChange>.of(
      session.changes,
    );
    var changesUpdated = false;
    for (final key in DesktopSessionConfigKey.values) {
      final current = changes[key];
      if (current == null ||
          !current.status.awaitsAuthoritativeInfo ||
          !accepts(key) ||
          !event.info.reports(key)) {
        continue;
      }
      final authoritative = effective.valueFor(key);
      if (authoritative == null) continue;
      changes[key] = current._transition(
        status: SessionConfigChangeStatus.confirmed,
        warning: current.warning,
        authoritativeValue: authoritative,
      );
      changesUpdated = true;
    }

    return _replaceSession(
      state,
      event.scope,
      session._copyWith(
        effective: effective,
        changes: changesUpdated ? changes : session.changes,
        latestInfoEpoch: event.infoEpoch,
      ),
    );
  }

  static SessionConfigReducerState _replaceChange(
    SessionConfigReducerState state,
    SessionConfigScope scope,
    PendingSessionConfigChange change,
  ) {
    final session = state[scope];
    if (session == null) return state;
    final changes = Map<DesktopSessionConfigKey, PendingSessionConfigChange>.of(
      session.changes,
    );
    changes[change.key] = change;
    return _replaceSession(state, scope, session._copyWith(changes: changes));
  }

  static SessionConfigReducerState _replaceSession(
    SessionConfigReducerState state,
    SessionConfigScope scope,
    SessionConfigSessionState session,
  ) {
    final sessions = Map<SessionConfigScope, SessionConfigSessionState>.of(
      state.sessions,
    );
    sessions[scope] = session;
    return SessionConfigReducerState._(sessions);
  }
}

bool _isOpaqueId(String value) =>
    value.trim().isNotEmpty && value.runes.length <= 256;

void _validateEpoch(int value, String label) {
  if (value < 0) throw FormatException('Invalid $label epoch');
}

String _requiredInfoValue(String value, String label, int maxLength) {
  final parsed = _optionalInfoValue(value, maxLength);
  if (parsed == null) throw FormatException('Invalid $label value');
  return parsed;
}

String? _optionalInfoValue(String? value, int maxLength) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty ||
      trimmed.runes.length > maxLength ||
      trimmed.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    return null;
  }
  return trimmed;
}

bool _sameReportedValue(SessionConfigValue reported, SessionConfigValue value) {
  if (reported is SessionModelConfigValue && value is SessionModelConfigValue) {
    return reported.modelId == value.modelId &&
        (reported.providerSlug == null ||
            reported.providerSlug == value.providerSlug);
  }
  return reported == value;
}
