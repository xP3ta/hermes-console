// Live view of one delegated subagent through a lazy "watch" session.
//
// The child runs inside its parent's turn. Hermes mirrors its activity as
// native stream events on a watch runtime opened with `session.resume
// {lazy: true}` for the child's stored id (scoped to the parent's profile).
// This controller owns that runtime for as long as the detail page is
// visible: it renders the stored history, applies the mirrored events and
// closes the runtime exactly once. It never submits prompts and never opens a
// socket: it borrows the parent chat's own gateway.
//
// Privacy: reasoning deltas, tool arguments and previews are dropped; only
// public text and public tool names reach [SubagentLiveWatchView].
import 'package:flutter/foundation.dart';

import '../models/desktop_session_snapshot.dart';
import 'tui_gateway_client.dart' show TuiGatewayEvent;

/// Minimal gateway surface the watch needs. Deliberately has no prompt
/// submission: a watch session is read-only.
abstract interface class SubagentWatchGateway {
  Stream<TuiGatewayEvent> get events;

  /// `session.resume` of the child's stored id as a lazy watch runtime.
  Future<DesktopSessionSnapshot> resumeWatchSession(
    String childSessionId, {
    required String profile,
  });

  Future<bool> closeSession(String runtimeSessionId);

  void retainSessionRuntime(String runtimeSessionId);

  void releaseSessionRuntime(String runtimeSessionId);
}

enum SubagentLiveWatchStatus {
  idle,
  opening,
  live,
  reconnecting,
  finished,

  /// The watch cannot be used (old server, rejected resume, stale owner): the
  /// caller falls back to the polled tail.
  unavailable,
}

@immutable
final class SubagentLiveWatchView {
  final SubagentLiveWatchStatus status;

  /// Public text of the child so far: stored history plus mirrored deltas.
  final String text;

  const SubagentLiveWatchView({
    this.status = SubagentLiveWatchStatus.idle,
    this.text = '',
  });
}

class SubagentLiveWatch extends ValueNotifier<SubagentLiveWatchView> {
  SubagentLiveWatch({
    required this.gateway,
    required this.childSessionId,
    required this.profile,
    required this.isCurrent,
  }) : super(const SubagentLiveWatchView());

  final SubagentWatchGateway gateway;
  final String childSessionId;

  /// Profile of the parent chat, never the globally active one.
  final String profile;

  /// False once the owner (chat runtime, active profile) moved on.
  final bool Function() isCurrent;

  void start() {}

  Future<void> close() async {}
}
