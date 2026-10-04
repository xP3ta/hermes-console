import 'dart:async';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/prompt_client_surface.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

/// Desktop gateway double that records every submit with the surface metadata
/// and lets a test script the server events of the owner chat.
class RecordingDesktopGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopInterruptedPromptGateway,
        HermesDesktopClientSurfacePromptGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  /// Every `prompt.submit` and `session.interrupt`, in order.
  final List<Map<String, Object?>> calls = [];
  bool completeInterrupts = true;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;
  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-live',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-live',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-live',
    storedSessionId: 'session-live',
    created: true,
  );

  void _submit(String text, PromptClientSurface? surface, {String? kind}) {
    calls.add({
      'call': 'submit',
      'text': text,
      'kind': ?kind,
      if (surface != null) ...surface.toParams(),
    });
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async =>
      _submit(text, null);

  @override
  Future<void> submitPromptWithSurface(
    String runtimeSessionId,
    String text,
    PromptClientSurface surface,
  ) async => _submit(text, surface);

  @override
  Future<void> submitInterruptedPrompt(
    String runtimeSessionId,
    String text,
  ) async => _submit(text, null, kind: 'interrupted');

  @override
  Future<void> submitInterruptedPromptWithSurface(
    String runtimeSessionId,
    String text,
    PromptClientSurface surface,
  ) async => _submit(text, surface, kind: 'interrupted');

  @override
  Future<DesktopTurnAck> submitPromptIdempotentWithSurface(
    String runtimeSessionId,
    String text,
    String clientTurnId,
    PromptClientSurface surface,
  ) => throw UnimplementedError('idempotent path is not used here');

  @override
  Future<void> submitQueuedPromptWithSurface(
    String runtimeSessionId,
    String text,
    PromptClientSurface surface,
  ) async => _submit(text, surface, kind: 'queued');

  @override
  Future<DesktopTurnAck> submitQueuedPromptIdempotentWithSurface(
    String runtimeSessionId,
    String text,
    String clientTurnId,
    PromptClientSurface surface,
  ) => throw UnimplementedError('idempotent path is not used here');

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    calls.add({'call': 'interrupt'});
    if (completeInterrupts) {
      emit('message.complete', {'text': 'Operation interrupted.'});
    }
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    if (_events.isClosed) return;
    _events.add(
      TuiGatewayEvent(type: type, sessionId: 'runtime-live', payload: payload),
    );
  }

  List<Map<String, Object?>> get submits =>
      calls.where((c) => c['call'] == 'submit').toList(growable: false);

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}
