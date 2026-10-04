import 'dart:async';

import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

/// Gateway fake that records the side-agent and branch RPCs it receives.
///
/// Every call is stored as `(method, params)` with the wire names, so tests
/// assert the exact body the server would see.
class FakeTurnSideGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopTurnSideGateway {
  FakeTurnSideGateway({this.runtimeId = 'runtime-side'});

  final String runtimeId;
  final StreamController<TuiGatewayEvent> controller =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<String> submissions = [];
  final List<String> interrupts = [];
  final List<({String method, Map<String, Object?> params})> calls = [];

  /// Failures handed out, in order, to the next side-agent or branch call.
  final List<Object> failures = [];

  /// When set, the next branch call waits for it before answering.
  Completer<void>? branchGate;
  int branchCount = 0;
  bool connected = true;
  int connectCalls = 0;
  @override
  bool turnSideKnownUnsupported = false;
  @override
  bool turnBranchKnownUnsupported = false;

  List<({String method, Map<String, Object?> params})> callsTo(
    String method,
  ) => calls.where((call) => call.method == method).toList(growable: false);

  void emit(String type, Map<String, dynamic> payload, {String? sessionId}) {
    controller.add(
      TuiGatewayEvent(
        type: type,
        sessionId: sessionId ?? runtimeId,
        payload: payload,
      ),
    );
  }

  @override
  Stream<TuiGatewayEvent> get events => controller.stream;
  @override
  bool get isConnected => connected;
  @override
  Future<void> connect() async {
    connectCalls++;
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: runtimeId,
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionBinding> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) => resumeSession(storedSessionId, profile: profile);

  @override
  Future<DesktopSessionBinding> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => resumeSession('session-side', profile: profile);

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interrupts.add(runtimeSessionId);
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> close() => controller.close();

  void _takeFailure() {
    if (failures.isEmpty) return;
    final failure = failures.removeAt(0);
    if (failure is DesktopControlFailure &&
        failure.kind == DesktopControlFailureKind.unsupported) {
      turnSideKnownUnsupported = true;
    }
    throw failure;
  }

  @override
  Future<String> askSideQuestion(String runtimeSessionId, String text) async {
    calls.add((
      method: 'prompt.btw',
      params: {'session_id': runtimeSessionId, 'text': text},
    ));
    _takeFailure();
    return 'btw-task-${calls.length}';
  }

  @override
  Future<String> startBackgroundPrompt(
    String runtimeSessionId,
    String text,
  ) async {
    calls.add((
      method: 'prompt.background',
      params: {'session_id': runtimeSessionId, 'text': text},
    ));
    _takeFailure();
    return 'bg-task-${calls.length}';
  }

  Future<DesktopBranchResult> _branch(
    String method,
    Map<String, Object?> params,
  ) async {
    calls.add((method: method, params: params));
    final gate = branchGate;
    if (gate != null) await gate.future;
    if (failures.isNotEmpty) {
      final failure = failures.removeAt(0);
      if (failure is DesktopControlFailure &&
          failure.kind == DesktopControlFailureKind.unsupported &&
          method == 'session.branch') {
        turnBranchKnownUnsupported = true;
      }
      throw failure;
    }
    branchCount++;
    return DesktopBranchResult(
      runtimeSessionId: 'runtime-child-$branchCount',
      storedSessionId: 'stored-child-$branchCount',
      title: 'Child $branchCount',
      messageCount: 2,
    );
  }

  @override
  Future<DesktopBranchResult> branchSession(
    String runtimeSessionId, {
    int? count,
    String? name,
    required String idempotencyKey,
  }) => _branch('session.branch', {
    'session_id': runtimeSessionId,
    'count': ?count,
    'name': ?name,
    'idempotency_key': idempotencyKey,
  });

  @override
  Future<DesktopBranchResult> branchWholeSession(
    String runtimeSessionId, {
    String? name,
    required String idempotencyKey,
  }) => _branch('session.branch_whole', {
    'session_id': runtimeSessionId,
    'name': ?name,
    'idempotency_key': idempotencyKey,
  });
}
