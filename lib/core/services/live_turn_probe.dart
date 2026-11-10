import 'package:flutter/foundation.dart';

import '../bots/data/gateway_socket_meter.dart' show kNetMeterEnabled;
import '../models/desktop_active_session.dart';

/// How long a live turn may go without a session event before its backend is
/// asked whether it is still running. Desktop: `LIVE_TURN_EVENT_SILENCE_MS`
/// (apps/desktop/src/store/session-states.ts:347). Silence alone proves
/// nothing (a foreground tool emits nothing between start and complete, a
/// local model can prefill for minutes): only the backend decides.
const liveTurnEventSilence = Duration(seconds: 45);

/// Bound on the status request itself; past it the check counts as
/// unanswered. Desktop: `LIVE_TURN_PROBE_TIMEOUT_MS`
/// (apps/desktop/src/store/session-states.ts:349).
const liveTurnProbeTimeout = Duration(seconds: 15);

/// What one `session.active_list` answer says about a runtime's turn.
enum LiveTurnVerdict { ended, running, unknown }

/// Desktop `liveTurnVerdict` (apps/desktop/src/store/session-states.ts:
/// 397-418): a runtime missing from a well-formed list, or listed `idle`, has
/// ended; `starting`/`waiting`/`working` (and Hermes' other busy words) are
/// running; anything else is unknown. A list with rows Console could not read
/// cannot prove a runtime absent: it is unknown (the stricter reading the
/// fanout roster probe already uses, tui_gateway_client.dart
/// `_probeQuarantinedRoster`).
LiveTurnVerdict liveTurnVerdictFor(
  DesktopActiveSessionList? list,
  String runtimeSessionId,
) {
  final runtime = runtimeSessionId.trim();
  if (list == null || runtime.isEmpty) return LiveTurnVerdict.unknown;
  final rows = list.sessions
      .where((row) => row.runtimeSessionId.trim() == runtime)
      .toList(growable: false);
  if (rows.isEmpty) {
    return list.hasMalformedRows
        ? LiveTurnVerdict.unknown
        : LiveTurnVerdict.ended;
  }
  if (rows.length > 1) return LiveTurnVerdict.unknown;
  final status = rows.single.status?.trim().toLowerCase();
  if (status == null || status.isEmpty || status == 'idle') {
    return LiveTurnVerdict.ended;
  }
  return _runningStatuses.contains(status)
      ? LiveTurnVerdict.running
      : LiveTurnVerdict.unknown;
}

const _runningStatuses = <String>{
  'starting',
  'waiting',
  'working',
  'running',
  'busy',
  'thinking',
  'executing',
  'streaming',
  'compacting',
};

/// Content-free trace of the turn state machinery (`[turn-registry]`): only
/// state names, verdicts and sites, never message text or identifiers.
///
/// REVISION-4 BAJO 7 (DISENO-REGISTRO §5): written only in QA builds with
/// the network meter (`kNetMeterEnabled`, like `[QA-NET]`) and in debug/test
/// builds, never in a store release.
void turnRegistryTrace(String event, [Map<String, Object?> fields = const {}]) {
  if (kReleaseMode && !kNetMeterEnabled) return;
  final buffer = StringBuffer('[turn-registry] ')..write(event);
  fields.forEach((key, value) => buffer.write(' $key=$value'));
  debugPrint(buffer.toString());
}
