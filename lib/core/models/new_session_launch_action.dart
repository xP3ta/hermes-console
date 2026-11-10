/// Versioned, secret-free action shared by the Android shortcut and widget.
///
/// This is an internal app contract, not a public deep link. The parser only
/// accepts the fields required to open a blank mobile draft.
enum NewSessionLaunchSource { shortcut, widget, assistant, internalTest }

enum NewSessionLaunchKind { newSession, openApp, openSession, openSetup }

enum NewSessionLaunchTarget { composer, camera, gallery, voice }

class NewSessionLaunchAction {
  static const int supportedContractVersion = 1;
  static final RegExp _opaqueIdPattern = RegExp(r'^[A-Za-z0-9._:-]+$');

  final int contractVersion;
  final NewSessionLaunchKind kind;
  final NewSessionLaunchSource source;
  final String nativeEventId;
  final String? requestedInstanceId;
  final String? sessionId;
  final NewSessionLaunchTarget target;
  final int receivedElapsedMs;

  const NewSessionLaunchAction({
    this.contractVersion = supportedContractVersion,
    this.kind = NewSessionLaunchKind.newSession,
    required this.source,
    required this.nativeEventId,
    this.requestedInstanceId,
    this.sessionId,
    this.target = NewSessionLaunchTarget.composer,
    required this.receivedElapsedMs,
  });

  /// Parses the allowlisted native DTO. Unknown fields are deliberately
  /// ignored; credentials, URLs, prompts and model identifiers are never read.
  static NewSessionLaunchAction? tryParse(Object? payload) {
    if (payload is! Map) return null;

    final version = payload['contract_version'];
    if (version is! int || version != supportedContractVersion) return null;

    final kind = switch (payload['kind']) {
      'new_session' || null => NewSessionLaunchKind.newSession,
      'open_app' => NewSessionLaunchKind.openApp,
      'open_session' => NewSessionLaunchKind.openSession,
      'open_setup' => NewSessionLaunchKind.openSetup,
      _ => null,
    };
    if (kind == null) return null;

    final source = switch (payload['source']) {
      'shortcut' => NewSessionLaunchSource.shortcut,
      'widget' => NewSessionLaunchSource.widget,
      'assistant' => NewSessionLaunchSource.assistant,
      'internal_test' => NewSessionLaunchSource.internalTest,
      _ => null,
    };
    if (source == null) return null;

    final eventId = payload['native_event_id'];
    if (!_isSafeOpaqueId(eventId, maxLength: 128)) return null;

    final requested = payload['requested_instance_id'];
    if (requested != null && !_isSafeOpaqueId(requested, maxLength: 256)) {
      return null;
    }
    final sessionId = payload['session_id'];
    if (sessionId != null && !_isSafeOpaqueId(sessionId, maxLength: 256)) {
      return null;
    }
    if (kind == NewSessionLaunchKind.openSession && sessionId == null) {
      return null;
    }

    final target = switch (payload['target']) {
      'composer' || null => NewSessionLaunchTarget.composer,
      'camera' => NewSessionLaunchTarget.camera,
      'gallery' => NewSessionLaunchTarget.gallery,
      'voice' => NewSessionLaunchTarget.voice,
      _ => null,
    };
    if (target == null) return null;
    // The digital assistant only ever opens a new chat with the voice ready.
    if (source == NewSessionLaunchSource.assistant &&
        (kind != NewSessionLaunchKind.newSession ||
            target != NewSessionLaunchTarget.voice)) {
      return null;
    }

    final elapsed = payload['received_elapsed_ms'];
    if (elapsed is! int || elapsed < 0) return null;

    return NewSessionLaunchAction(
      contractVersion: version,
      kind: kind,
      source: source,
      nativeEventId: eventId as String,
      requestedInstanceId: requested as String?,
      sessionId: sessionId as String?,
      target: target,
      receivedElapsedMs: elapsed,
    );
  }

  static bool _isSafeOpaqueId(Object? value, {required int maxLength}) {
    return value is String &&
        value.isNotEmpty &&
        value.length <= maxLength &&
        _opaqueIdPattern.hasMatch(value);
  }

  /// Dedupe intentionally ignores source: shortcut and widget must converge on
  /// exactly the same action while navigation is already in flight.
  String get dedupeFingerprint =>
      '${kind.name}:${target.name}:${requestedInstanceId ?? ''}:${sessionId ?? ''}';
}

enum InstanceResolutionKind {
  resolved,
  needsSelection,
  needsOnboarding,
  invalidAction,
}

enum InstanceResolutionReason {
  requested,
  active,
  defaultConnection,
  onlyConnection,
}

class InstanceResolution {
  final InstanceResolutionKind kind;
  final String? connectionId;
  final InstanceResolutionReason? reason;
  final List<String> candidateIds;
  final String? errorCode;

  const InstanceResolution.resolved(
    String this.connectionId,
    InstanceResolutionReason this.reason,
  ) : kind = InstanceResolutionKind.resolved,
      candidateIds = const [],
      errorCode = null;

  const InstanceResolution.needsSelection(List<String> ids)
    : kind = InstanceResolutionKind.needsSelection,
      candidateIds = ids,
      connectionId = null,
      reason = null,
      errorCode = null;

  const InstanceResolution.needsOnboarding()
    : kind = InstanceResolutionKind.needsOnboarding,
      candidateIds = const [],
      connectionId = null,
      reason = null,
      errorCode = null;

  const InstanceResolution.invalid(String code)
    : kind = InstanceResolutionKind.invalidAction,
      errorCode = code,
      candidateIds = const [],
      connectionId = null,
      reason = null;
}

/// Pure, deterministic instance resolution. It does no network or secure
/// storage work and only sees opaque connection identifiers.
InstanceResolution resolveNewSessionInstance({
  required NewSessionLaunchAction action,
  required Iterable<String> connectionIds,
  String? activeConnectionId,
  String? defaultConnectionId,
}) {
  if (action.contractVersion !=
          NewSessionLaunchAction.supportedContractVersion ||
      (action.kind != NewSessionLaunchKind.newSession &&
          action.kind != NewSessionLaunchKind.openSession)) {
    return const InstanceResolution.invalid('LAUNCH_INVALID_ACTION');
  }

  final ids = connectionIds.where((id) => id.isNotEmpty).toSet().toList();
  if (ids.isEmpty) return const InstanceResolution.needsOnboarding();

  final requested = action.requestedInstanceId;
  if (requested != null && ids.contains(requested)) {
    return InstanceResolution.resolved(
      requested,
      InstanceResolutionReason.requested,
    );
  }
  if (activeConnectionId != null && ids.contains(activeConnectionId)) {
    return InstanceResolution.resolved(
      activeConnectionId,
      InstanceResolutionReason.active,
    );
  }
  if (defaultConnectionId != null && ids.contains(defaultConnectionId)) {
    return InstanceResolution.resolved(
      defaultConnectionId,
      InstanceResolutionReason.defaultConnection,
    );
  }
  if (ids.length == 1) {
    return InstanceResolution.resolved(
      ids.single,
      InstanceResolutionReason.onlyConnection,
    );
  }
  return InstanceResolution.needsSelection(List.unmodifiable(ids));
}
