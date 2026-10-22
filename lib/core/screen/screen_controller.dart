/// JSON-RPC call used by [ScreenController].
///
/// The Desktop gateway client implements this with its display allowlist.
typedef DisplayRpc =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

/// Why a display call cannot be shown to the user.
enum ScreenFailureKind { unavailable, unsupported, invalidResponse, readOnly }

/// Failure that carries no server text, path or ticket.
class ScreenControllerException implements Exception {
  /// Creates a failure of [kind].
  const ScreenControllerException(this.kind);

  /// Class of failure the screen can map to a localized message.
  final ScreenFailureKind kind;

  @override
  String toString() => 'ScreenControllerException(${kind.name})';
}

/// Coarse snapshot from `display.status` for the peek poller.
class DisplayState {
  /// Creates a snapshot.
  const DisplayState({
    required this.running,
    required this.installed,
    required this.leaseHolder,
  });

  /// Reads the lenient status shape used by the peek poller.
  factory DisplayState.fromJson(Map<String, dynamic> json) => DisplayState(
    running: json['running'] == true || json['status'] == 'running',
    installed: json['installed'] != false,
    leaseHolder: json['lease'] is Map
        ? (json['lease'] as Map)['holder']?.toString() ?? ''
        : json['lease_holder']?.toString() ?? '',
  );

  /// Whether Xvnc is up.
  final bool running;

  /// Whether the gateway reports a display stack.
  final bool installed;

  /// `agent` or `human` when the payload includes a lease.
  final String leaseHolder;
}

/// One JPEG grab from `display.thumbnail`.
class DisplayFrame {
  /// Creates a frame.
  const DisplayFrame({required this.dataUrl, required this.suppressed});

  /// `data:` URL, or empty when the gateway sent none.
  final String dataUrl;

  /// Suppression reason from the gateway, or empty.
  final String suppressed;

  /// Whether the gateway withheld the frame because a human holds the lease.
  bool get suppressedByHuman => suppressed == 'human_has_control';
}

/// Lease the gateway is willing to show a client.
class DisplayLeaseInfo {
  /// Creates a lease snapshot.
  const DisplayLeaseInfo({
    required this.holder,
    required this.viewerHash,
    required this.epoch,
    required this.reason,
  });

  /// Reads a `DisplayLease` object.
  factory DisplayLeaseInfo.fromJson(Map<String, dynamic> json) =>
      DisplayLeaseInfo(
        holder: json['holder']?.toString() ?? '',
        viewerHash: json['viewer_hash']?.toString() ?? '',
        epoch: (json['epoch'] as num?)?.toInt() ?? 0,
        reason: json['reason']?.toString() ?? '',
      );

  /// Lease used when the gateway omits one.
  static const empty = DisplayLeaseInfo(
    holder: '',
    viewerHash: '',
    epoch: 0,
    reason: '',
  );

  /// `agent` or `human`.
  final String holder;

  /// Hash the holder uses to recognise itself. Empty when absent.
  final String viewerHash;

  /// Monotonic lease generation.
  final int epoch;

  /// Gateway reason string. Not shown in the UI.
  final String reason;

  /// Whether a person, rather than the agent, holds the screen.
  bool get heldByHuman => holder == 'human';
}

/// Whether [lease] means this viewer no longer holds the screen.
///
/// Events older than [ourEpoch] are ignored. A non-human holder of this
/// epoch or a later one always counts. A human holder counts only when both
/// sides have a viewer hash and they differ, which is how the gateway lets
/// the current holder recognise itself.
bool displayLeaseTakenOver(
  DisplayLeaseInfo lease, {
  required String ourViewerHash,
  required int ourEpoch,
}) {
  if (lease.epoch < ourEpoch) return false;
  if (!lease.heldByHuman) return true;
  if (ourViewerHash.isEmpty || lease.viewerHash.isEmpty) return false;
  return lease.viewerHash != ourViewerHash;
}

/// Runtime block returned by `display.status`, `display.start` and observe.
class DisplayRuntime {
  /// Creates a runtime snapshot.
  const DisplayRuntime({
    required this.supported,
    required this.installed,
    required this.running,
    required this.blocker,
    required this.geometry,
    required this.lease,
  });

  /// Reads a `DisplayStatus` or `DisplayObserveResult` object.
  factory DisplayRuntime.fromJson(Map<String, dynamic> json) => DisplayRuntime(
    supported: json['supported'] == true,
    installed: json['installed'] == true,
    running: json['running'] == true,
    blocker: json['blocker']?.toString() ?? '',
    geometry: json['geometry']?.toString() ?? '',
    lease: json['lease'] is Map
        ? DisplayLeaseInfo.fromJson(_stringKeyMap(json['lease'] as Map))
        : DisplayLeaseInfo.empty,
  );

  /// Whether this gateway build can host a display.
  final bool supported;

  /// Whether the display packages are installed.
  final bool installed;

  /// Whether Xvnc is running.
  final bool running;

  /// Non-empty when the gateway refuses to start. Not shown verbatim.
  final String blocker;

  /// Geometry string from the gateway, or empty.
  final String geometry;

  /// Current lease.
  final DisplayLeaseInfo lease;
}

/// Ticketed VNC session from `display.observe`.
class DisplaySession {
  /// Creates a session.
  const DisplaySession({
    required this.ticket,
    required this.path,
    required this.viewerId,
    required this.runtime,
  });

  /// Single-use ticket for `/api/display/ws`.
  final String ticket;

  /// Websocket path, usually `/api/display/ws`.
  final String path;

  /// Server-minted viewer id for `display.lease.acquire`.
  final String viewerId;

  /// Runtime included on the observe result.
  final DisplayRuntime runtime;
}

/// Display RPCs and the websocket URL of a ticketed VNC session.
class ScreenController {
  /// Creates a controller over an existing gateway [rpc] channel.
  ScreenController({
    required this.rpc,
    required this.leasePayloads,
    required this.dashboardBase,
  });

  /// Gateway `display.*` call.
  final DisplayRpc rpc;

  /// Payloads of `display.lease` events.
  final Stream<Map<String, dynamic>> leasePayloads;

  /// Dashboard origin used to build the display websocket.
  final Uri Function() dashboardBase;

  /// `display.lease` events as lease snapshots.
  Stream<DisplayLeaseInfo> watchLease() => leasePayloads.map((payload) {
    final raw = payload['lease'];
    final json = raw is Map ? _stringKeyMap(raw) : payload;
    return DisplayLeaseInfo.fromJson(json);
  });

  /// Websocket URI for [path] authenticated only by [ticket].
  ///
  /// [path] is joined onto the dashboard base the way `/api/ws` is, unless
  /// the gateway already returned a path under that prefix. The dashboard
  /// credential is not copied onto the URI.
  Uri displayWsUri(String path, String ticket) {
    if (ticket.isEmpty) {
      throw const ScreenControllerException(ScreenFailureKind.invalidResponse);
    }
    final base = dashboardBase();
    if (base.host.isEmpty ||
        (base.scheme != 'http' && base.scheme != 'https')) {
      throw const ScreenControllerException(ScreenFailureKind.unavailable);
    }
    final suffix = path.startsWith('/') ? path : '/$path';
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final joined = prefix.isNotEmpty && suffix.startsWith('$prefix/')
        ? suffix
        : '$prefix$suffix';
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: joined,
      queryParameters: {'display_ticket': ticket},
    );
  }

  /// Starts Xvnc for [profile] (`display.start`).
  Future<DisplayRuntime> start({String profile = ''}) =>
      _runtime('display.start', profile);

  /// Reads the strict runtime snapshot (`display.status`).
  Future<DisplayRuntime> status({String profile = ''}) =>
      _runtime('display.status', profile);

  /// Reads the lenient peek snapshot (`display.status`).
  Future<DisplayState> peekStatus({String profile = ''}) async =>
      DisplayState.fromJson(await rpc('display.status', _profile(profile)));

  /// Grabs one frame (`display.thumbnail`).
  Future<DisplayFrame> thumbnail({String profile = ''}) async {
    final result = await rpc('display.thumbnail', _profile(profile));
    return DisplayFrame(
      dataUrl: result['data_url']?.toString() ?? '',
      suppressed: result['suppressed']?.toString() ?? '',
    );
  }

  /// Mints a VNC ticket and viewer id (`display.observe`).
  Future<DisplaySession> observe({String profile = ''}) async {
    final result = await rpc('display.observe', _profile(profile));
    final ticket = result['ticket']?.toString() ?? '';
    final viewerId = result['viewer_id']?.toString() ?? '';
    if (ticket.isEmpty || viewerId.isEmpty) {
      throw const ScreenControllerException(ScreenFailureKind.invalidResponse);
    }
    final path = result['path']?.toString() ?? '';
    return DisplaySession(
      ticket: ticket,
      path: path.isEmpty ? '/api/display/ws' : path,
      viewerId: viewerId,
      runtime: DisplayRuntime.fromJson(result),
    );
  }

  /// Takes the lease for [viewerId] (`display.lease.acquire`).
  Future<DisplayLeaseInfo> acquire(
    String viewerId, {
    String profile = '',
    String reason = 'hermes-console',
  }) async {
    final result = await rpc('display.lease.acquire', {
      ..._profile(profile),
      'viewer_id': viewerId,
      'reason': reason,
    });
    return _lease(result);
  }

  /// Gives the lease back (`display.lease.release`).
  Future<DisplayLeaseInfo> release(
    String viewerId, {
    String profile = '',
  }) async {
    final result = await rpc('display.lease.release', {
      ..._profile(profile),
      'viewer_id': viewerId,
    });
    return _lease(result);
  }

  Future<DisplayRuntime> _runtime(String method, String profile) async =>
      DisplayRuntime.fromJson(await rpc(method, _profile(profile)));

  DisplayLeaseInfo _lease(Map<String, dynamic> result) {
    final lease = result['lease'];
    return lease is Map
        ? DisplayLeaseInfo.fromJson(_stringKeyMap(lease))
        : DisplayLeaseInfo.empty;
  }

  Map<String, dynamic> _profile(String profile) {
    final name = profile.trim();
    if (name.isEmpty) return const {};
    return {'profile': name};
  }
}

Map<String, dynamic> _stringKeyMap(Map raw) => {
  for (final entry in raw.entries)
    if (entry.key is String) entry.key as String: entry.value,
};
