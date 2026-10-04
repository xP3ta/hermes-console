import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/prompt_client_surface.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

SavedConnection _connection() => SavedConnection(
  id: 'surface-conn',
  label: 'Surface test',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

ActiveChat _chat(HermesDesktopGateway gateway) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: _connection(),
  sessionId: 'session-surface',
  sessionTitle: 'Surface',
  notifications: null,
  onTerminal: () {},
  desktopGateway: gateway,
  initialStoredSessionId: 'session-surface',
  turnIdempotencyCapability: () async => true,
)..state = ChatPipelineState.idle;

/// Records every submit with the metadata the gateway would put on the wire.
class _SurfaceGateway
    implements
        HermesDesktopGateway,
        HermesDesktopInterruptedPromptGateway,
        HermesDesktopIdempotentGateway,
        HermesDesktopQueuedPromptGateway,
        HermesDesktopClientSurfacePromptGateway {
  final StreamController<TuiGatewayEvent> controller =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<Map<String, Object?>> submits = [];

  @override
  Stream<TuiGatewayEvent> get events => controller.stream;
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
    runtimeSessionId: 'runtime-surface',
    storedSessionId: storedSessionId,
    created: false,
  );

  void _record(String path, String text, PromptClientSurface? surface) {
    submits.add({
      'path': path,
      'text': text,
      if (surface != null) ...surface.toParams(),
    });
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async =>
      _record('plain', text, null);

  @override
  Future<void> submitPromptWithSurface(
    String runtimeSessionId,
    String text,
    PromptClientSurface surface,
  ) async => _record('plain', text, surface);

  @override
  Future<void> submitInterruptedPrompt(
    String runtimeSessionId,
    String text,
  ) async => _record('interrupted', text, null);

  @override
  Future<void> submitInterruptedPromptWithSurface(
    String runtimeSessionId,
    String text,
    PromptClientSurface surface,
  ) async => _record('interrupted', text, surface);

  @override
  Future<void> submitQueuedPrompt(String runtimeSessionId, String text) async =>
      _record('queued', text, null);

  @override
  Future<void> submitQueuedPromptWithSurface(
    String runtimeSessionId,
    String text,
    PromptClientSurface surface,
  ) async => _record('queued', text, surface);

  @override
  Future<DesktopTurnAck> submitQueuedPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    _record('queued-idempotent', text, null);
    return _ack(clientTurnId);
  }

  @override
  Future<DesktopTurnAck> submitQueuedPromptIdempotentWithSurface(
    String runtimeSessionId,
    String text,
    String clientTurnId,
    PromptClientSurface surface,
  ) async {
    _record('queued-idempotent', text, surface);
    return _ack(clientTurnId);
  }

  DesktopTurnAck _ack(String clientTurnId) => DesktopTurnAck(
    accepted: true,
    clientTurnId: clientTurnId,
    serverTurnId: 'server-$clientTurnId',
    state: DesktopTurnState.accepted,
    duplicate: false,
  );

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    _record('idempotent', text, null);
    return _ack(clientTurnId);
  }

  @override
  Future<DesktopTurnAck> submitPromptIdempotentWithSurface(
    String runtimeSessionId,
    String text,
    String clientTurnId,
    PromptClientSurface surface,
  ) async {
    _record('idempotent', text, surface);
    return _ack(clientTurnId);
  }

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String runtimeSessionId,
    String clientTurnId,
  ) async => DesktopTurnStatus(
    known: true,
    clientTurnId: clientTurnId,
    serverTurnId: 'server-$clientTurnId',
    state: DesktopTurnState.running,
  );

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}
  @override
  Future<void> interrupt(String runtimeSessionId) async {}
  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}
  @override
  Future<void> close() => controller.close();
}

class _MemoryOutbox implements TurnOutboxPersistence {
  @override
  Future<void> save(PreparedTurn turn) async {}
  @override
  Future<void> delete(PreparedTurn turn) async {}
}

ActiveTurnDelivery _delivery(String id, String text, {bool queued = false}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return ActiveTurnDelivery(
    prepared: PreparedTurn(
      connectionId: 'surface-conn',
      sessionId: 'session-surface',
      clientTurnId: id,
      createdAtMs: now,
      updatedAtMs: now,
      text: text,
      fullText: text,
      desktopText: text,
      attachments: const [],
      model: 'hermes-agent',
      profile: '',
      queued: queued,
    ),
    store: _MemoryOutbox(),
  );
}

const _voiceLive = PromptClientSurface.voiceLive(
  voiceContext: 'User: hola\nVoice assistant: dime',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(const {}));
  late _SurfaceGateway gateway;
  late ActiveChat chat;

  setUp(() {
    gateway = _SurfaceGateway();
    chat = _chat(gateway);
  });
  tearDown(() async {
    chat.dispose();
    await gateway.close();
  });

  test('plain submit carries surface and voice_context', () async {
    await chat.send(
      fullText: 'abre el calendario',
      model: 'hermes-agent',
      history: const [],
      clientSurface: _voiceLive,
    );
    expect(gateway.submits, [
      {
        'path': 'plain',
        'text': 'abre el calendario',
        'surface': 'voice-live',
        'voice_context': 'User: hola\nVoice assistant: dime',
      },
    ]);
  });

  test('idempotent submit carries surface and voice_context', () async {
    await chat.send(
      fullText: 'abre el calendario',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('turn-1', 'abre el calendario'),
      clientSurface: _voiceLive,
    );
    expect(gateway.submits, [
      {
        'path': 'idempotent',
        'text': 'abre el calendario',
        'surface': 'voice-live',
        'voice_context': 'User: hola\nVoice assistant: dime',
      },
    ]);
  });

  test('queued submit carries surface and voice_context', () async {
    await chat.send(
      fullText: 'abre el calendario',
      model: 'hermes-agent',
      history: const [],
      queued: true,
      clientSurface: _voiceLive,
    );
    expect(gateway.submits, [
      {
        'path': 'queued',
        'text': 'abre el calendario',
        'surface': 'voice-live',
        'voice_context': 'User: hola\nVoice assistant: dime',
      },
    ]);
  });

  test('queued idempotent submit carries surface and voice_context', () async {
    await chat.send(
      fullText: 'abre el calendario',
      model: 'hermes-agent',
      history: const [],
      queued: true,
      delivery: _delivery('turn-q', 'abre el calendario', queued: true),
      clientSurface: _voiceLive,
    );
    expect(gateway.submits, [
      {
        'path': 'queued-idempotent',
        'text': 'abre el calendario',
        'surface': 'voice-live',
        'voice_context': 'User: hola\nVoice assistant: dime',
      },
    ]);
  });

  test('typed sends never carry surface metadata on any path', () async {
    for (final send in <Future<bool> Function()>[
      () => chat.send(fullText: 'plain', model: 'm', history: const []),
      () => chat.send(
        fullText: 'interrupted',
        model: 'm',
        history: const [],
        voicePlaybackInterrupted: true,
      ),
      () => chat.send(
        fullText: 'queued',
        model: 'm',
        history: const [],
        queued: true,
      ),
      () => chat.send(
        fullText: 'queued idempotent',
        model: 'm',
        history: const [],
        queued: true,
        delivery: _delivery('turn-t', 'queued idempotent', queued: true),
      ),
    ]) {
      await send();
    }
    expect(gateway.submits, [
      {'path': 'plain', 'text': 'plain'},
      {'path': 'interrupted', 'text': 'interrupted'},
      {'path': 'queued', 'text': 'queued'},
      {'path': 'queued-idempotent', 'text': 'queued idempotent'},
    ]);
  });

  test('interrupted submit carries surface and voice_context', () async {
    await chat.send(
      fullText: 'abre el calendario',
      model: 'hermes-agent',
      history: const [],
      voicePlaybackInterrupted: true,
      clientSurface: _voiceLive,
    );
    expect(gateway.submits, [
      {
        'path': 'interrupted',
        'text': 'abre el calendario',
        'surface': 'voice-live',
        'voice_context': 'User: hola\nVoice assistant: dime',
      },
    ]);
  });

  test('a gateway without session lifecycle keeps the surface under a '
      'non-default profile', () {
    // Without the lifecycle capability a profile turn goes through the
    // profile dispatch, which probes the bridge before degrading to the
    // gateway; the metadata must survive that detour.
    fakeAsync((async) {
      unawaited(
        chat.send(
          fullText: 'abre el calendario',
          model: 'hermes-agent',
          history: const [],
          profile: 'ops',
          clientSurface: _voiceLive,
        ),
      );
      async.elapse(const Duration(seconds: 10));
      expect(gateway.submits, [
        {
          'path': 'plain',
          'text': 'abre el calendario',
          'surface': 'voice-live',
          'voice_context': 'User: hola\nVoice assistant: dime',
        },
      ]);
    });
  });

  test('typed submits never carry surface or voice_context', () async {
    await chat.send(
      fullText: 'texto escrito',
      model: 'hermes-agent',
      history: const [],
    );
    chat.state = ChatPipelineState.idle;
    await chat.send(
      fullText: 'texto idempotente',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('turn-2', 'texto idempotente'),
    );
    chat.state = ChatPipelineState.idle;
    await chat.send(
      fullText: 'texto tras barge-in',
      model: 'hermes-agent',
      history: const [],
      voicePlaybackInterrupted: true,
    );
    expect(gateway.submits, [
      {'path': 'plain', 'text': 'texto escrito'},
      {'path': 'idempotent', 'text': 'texto idempotente'},
      {'path': 'interrupted', 'text': 'texto tras barge-in'},
    ]);
  });

  test('empty voice context sends only the surface key', () {
    expect(const PromptClientSurface.voiceLive(voiceContext: '  ').toParams(), {
      'surface': 'voice-live',
    });
    expect(const PromptClientSurface.voiceLive().toParams(), {
      'surface': 'voice-live',
    });
  });

  test('voice_context is clamped to 6000 characters', () {
    final params = PromptClientSurface.voiceLive(
      voiceContext: 'x' * 7000,
    ).toParams();
    expect((params['voice_context'] as String).length, 6000);
  });
}
