import 'dart:async';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/subagent_live_watch.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

const watchTestChild = 'child-stored-1';

DesktopSessionSnapshot watchTestSnapshot(
  String runtime, {
  bool running = true,
  List<Map<String, dynamic>> messages = const [],
}) => DesktopSessionSnapshot.fromJson(
  {
    'session_id': runtime,
    'session_key': watchTestChild,
    'running': running,
    'status': running ? 'streaming' : 'idle',
    'messages': messages,
    'info': {'lazy': true},
  },
  requestedStoredSessionId: watchTestChild,
  created: false,
  method: 'session.resume',
);

/// Records every call so tests can count what reached the wire.
class FakeWatchGateway implements SubagentWatchGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast(sync: true);
  final resumes = <({String childId, String profile})>[];
  final closed = <String>[];
  final retained = <String>[];
  final released = <String>[];
  int _runtimes = 0;

  /// While set, `session.close` stays pending until it completes.
  Completer<void>? closeGate;

  /// When set, `session.close` rejects with it once it answers.
  Object? closeError;

  /// Completes each resume; defaults to a fresh runtime with no history.
  Future<DesktopSessionSnapshot> Function(String runtime)? answer;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  /// Whether anything still listens to the shared event stream.
  bool get hasListeners => _events.hasListener;

  @override
  Future<DesktopSessionSnapshot> resumeWatchSession(
    String childSessionId, {
    required String profile,
  }) {
    resumes.add((childId: childSessionId, profile: profile));
    final runtime = 'watch-${++_runtimes}';
    return answer?.call(runtime) ?? Future.value(watchTestSnapshot(runtime));
  }

  @override
  Future<bool> closeSession(String runtimeSessionId) async {
    closed.add(runtimeSessionId);
    await closeGate?.future;
    final error = closeError;
    if (error != null) throw error;
    return true;
  }

  @override
  void retainSessionRuntime(String runtimeSessionId) =>
      retained.add(runtimeSessionId);

  @override
  void releaseSessionRuntime(String runtimeSessionId) =>
      released.add(runtimeSessionId);

  void emit(String runtime, String type, [Map<String, dynamic>? payload]) =>
      _events.add(
        TuiGatewayEvent(
          type: type,
          sessionId: runtime,
          payload: payload ?? const {},
        ),
      );

  /// `session.events.since` asking [runtime] (and only it) to rehydrate: the
  /// shared socket itself stays healthy.
  void rehydrate(String runtime) => _events.addError(
    TuiGatewayRpcError(
      'session.events.since',
      'Hermes Desktop live subscription requires rehydration',
      failureKind: TuiGatewayRpcFailureKind.connectionLost,
      data: {'session_id': runtime},
    ),
  );

  void drop() => _events.addError(
    const TuiGatewayRpcError(
      'gateway.transport',
      'Hermes Desktop connection lost',
      failureKind: TuiGatewayRpcFailureKind.connectionLost,
    ),
  );
}
