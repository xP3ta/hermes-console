// A connection prompt the agent raises mid-turn (`connection.request`),
// its updates (`connection.update`) and the snapshot a resume carries
// (`pending_connection`). Rules ported from Hermes Desktop's connection
// request store:
//
//  * a payload without op id, tool call id, a positive deadline or at least
//    one named target is dropped; unknown kinds read as a generic row,
//    unknown states as pending;
//  * every frame carries the FULL target snapshot; a frame of another
//    operation, with a seq that is not higher than the held one, or arriving
//    after the request settled, changes nothing;
//  * state comes only from the backend: nothing here sets a target state.
//
// Privacy: `required_env` is never read (no credential is typed on the
// phone) and the authorization link is only kept when it is a plain `https`
// URL; it is never part of [toString].

enum ConnectionTargetKind { connector, mcp, plugin, skill, other }

enum ConnectionTargetState {
  pending,
  initiated,
  connected,
  skipped,
  failed,
  expired,
  notConnected,
}

final class ConnectionTarget {
  final String name;
  final ConnectionTargetKind kind;
  final ConnectionTargetState state;

  /// Wire action (`authorize`, `connect`, `enable`, `install`, `reconnect`).
  final String? action;
  final String? detail;
  final String? instructions;
  final String? hint;

  /// The authorization link, https only.
  final Uri? connectUrl;

  const ConnectionTarget({
    required this.name,
    this.kind = ConnectionTargetKind.other,
    this.state = ConnectionTargetState.pending,
    this.action,
    this.detail,
    this.instructions,
    this.hint,
    this.connectUrl,
  });

  static String? _text(Object? value, int max) {
    if (value is! String) return null;
    final clean = value.trim();
    if (clean.isEmpty) return null;
    return clean.length > max ? clean.substring(0, max) : clean;
  }

  static Uri? _httpsLink(Object? value) {
    final raw = _text(value, 4096);
    final uri = raw == null ? null : Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }

  static ConnectionTarget? tryParse(Object? json) {
    if (json is! Map) return null;
    final name = _text(json['name'], 120);
    if (name == null) return null;
    return ConnectionTarget(
      name: name,
      kind: switch (json['kind']) {
        'connector' => ConnectionTargetKind.connector,
        'mcp' => ConnectionTargetKind.mcp,
        'plugin' => ConnectionTargetKind.plugin,
        'skill' => ConnectionTargetKind.skill,
        _ => ConnectionTargetKind.other,
      },
      state: switch (json['state']) {
        'initiated' => ConnectionTargetState.initiated,
        'connected' => ConnectionTargetState.connected,
        'skipped' => ConnectionTargetState.skipped,
        'failed' => ConnectionTargetState.failed,
        'expired' => ConnectionTargetState.expired,
        'not_connected' => ConnectionTargetState.notConnected,
        _ => ConnectionTargetState.pending,
      },
      action: _text(json['action'], 40),
      detail: _text(json['detail'], 400),
      instructions: _text(json['instructions'], 400),
      hint: _text(json['hint'], 400),
      connectUrl: _httpsLink(json['connect_url']),
    );
  }

  /// `null` when [rows] is not a list or any row is unusable.
  static List<ConnectionTarget>? parseAll(Object? rows) {
    if (rows is! List || rows.isEmpty || rows.length > 40) return null;
    final out = <ConnectionTarget>[];
    for (final row in rows) {
      final target = tryParse(row);
      if (target == null) return null;
      out.add(target);
    }
    return List.unmodifiable(out);
  }
}

final class ConnectionRequest {
  final String opId;
  final int seq;

  /// Backend-owned deadline, unix seconds.
  final double deadlineAt;
  final double timeoutSeconds;
  final String toolCallId;
  final List<ConnectionTarget> targets;
  final bool settled;
  final String settledBy;

  const ConnectionRequest({
    required this.opId,
    required this.seq,
    required this.deadlineAt,
    required this.toolCallId,
    required this.targets,
    this.timeoutSeconds = 0,
    this.settled = false,
    this.settledBy = '',
  });

  ConnectionRequest _next({
    required int seq,
    required double deadlineAt,
    required List<ConnectionTarget> targets,
    required bool settled,
    required String settledBy,
  }) => ConnectionRequest(
    opId: opId,
    seq: seq,
    deadlineAt: deadlineAt,
    timeoutSeconds: timeoutSeconds,
    toolCallId: toolCallId,
    targets: targets,
    settled: settled,
    settledBy: settledBy,
  );

  @override
  String toString() =>
      'ConnectionRequest(op: $opId, seq: $seq, targets: ${targets.length}, '
      'settled: $settled)';
}

String? _id(Object? value) {
  if (value is! String) return null;
  final clean = value.trim();
  return clean.isEmpty || clean.length > 200 ? null : clean;
}

int? _seq(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncate()) {
    return value.toInt();
  }
  return null;
}

double? _positive(Object? value) =>
    value is num && value.isFinite && value > 0 ? value.toDouble() : null;

/// The request a `connection.request` frame (or a resume snapshot) describes,
/// or null when it cannot be bound to a tool row.
ConnectionRequest? normalizeConnectionRequest(Object? payload) {
  if (payload is! Map) return null;
  final opId = _id(payload['op_id']);
  final toolCallId = _id(payload['tool_call_id']);
  final deadline = _positive(payload['deadline_at']);
  final targets = ConnectionTarget.parseAll(payload['targets']);
  if (opId == null ||
      toolCallId == null ||
      deadline == null ||
      targets == null) {
    return null;
  }
  final timeout = payload['timeout_seconds'];
  return ConnectionRequest(
    opId: opId,
    seq: _seq(payload['seq']) ?? 0,
    deadlineAt: deadline,
    timeoutSeconds: timeout is num && timeout.isFinite && timeout > 0
        ? timeout.toDouble()
        : 0,
    toolCallId: toolCallId,
    targets: targets,
    settled: payload['settled'] == true,
    settledBy: _id(payload['settled_by']) ?? '',
  );
}

/// Folds a status frame (`connection.update` or `connectors.operation.status`)
/// into [current]. Returns [current] itself when the frame changes nothing.
ConnectionRequest applyConnectionUpdate(
  ConnectionRequest current,
  Map<String, dynamic> frame,
) {
  if (current.settled) return current;
  if (_id(frame['op_id']) != current.opId) return current;
  final seq = _seq(frame['seq']);
  if (seq == null || seq <= current.seq) return current;
  final settled = frame['settled'] == true;
  return current._next(
    seq: seq,
    deadlineAt: _positive(frame['deadline_at']) ?? current.deadlineAt,
    targets: ConnectionTarget.parseAll(frame['targets']) ?? current.targets,
    settled: settled,
    settledBy: settled ? (_id(frame['settled_by']) ?? '') : '',
  );
}

ConnectionRequest applyOperationStatus(
  ConnectionRequest current,
  Map<String, dynamic> status,
) => applyConnectionUpdate(current, status);

/// The one open request of a runtime session plus the operations that
/// already settled (so a late request or resume snapshot cannot revive them).
final class ConnectionCardState {
  final ConnectionRequest? request;
  final Set<String> settledOps;

  const ConnectionCardState({this.request, this.settledOps = const {}});

  ConnectionCardState _with(ConnectionRequest? request) {
    final settled = request != null && request.settled
        ? {...settledOps, request.opId}
        : settledOps;
    return ConnectionCardState(request: request, settledOps: settled);
  }

  ConnectionCardState onRequest(ConnectionRequest incoming) {
    if (settledOps.contains(incoming.opId)) return this;
    final held = request;
    if (held != null && held.opId == incoming.opId) {
      if (incoming.seq <= held.seq) return this;
    }
    return _with(incoming);
  }

  ConnectionCardState onUpdate(Map<String, dynamic> frame) {
    final held = request;
    if (held == null) return this;
    final next = applyConnectionUpdate(held, frame);
    return identical(next, held) ? this : _with(next);
  }

  /// A resume snapshot. [heldAtStart] is the request held when the resume
  /// began: an absent snapshot clears only that card, never one that arrived
  /// by event while the resume was in flight.
  ConnectionCardState onResume({
    required ConnectionRequest? pending,
    required ConnectionRequest? heldAtStart,
  }) {
    final held = request;
    if (pending == null) {
      if (held != null &&
          heldAtStart != null &&
          held.opId == heldAtStart.opId) {
        return ConnectionCardState(settledOps: settledOps);
      }
      return this;
    }
    if (settledOps.contains(pending.opId)) return this;
    if (held == null || held.settled) return _with(pending);
    if (held.opId == pending.opId && pending.seq > held.seq) {
      return _with(pending);
    }
    return this;
  }
}
