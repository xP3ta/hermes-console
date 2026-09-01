import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/voice/conversation/local_voice_conversation_controller.dart';
import 'package:hermes_android/core/services/voice/device_memory_profile.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';
import 'package:hermes_android/core/services/voice/voice_phase.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _VoiceProbe {
  final List<_ProbeStt> sttEngines = [];
  final List<StreamController<SttResult>> captures = [];
  final List<_ProbeTts> ttsEngines = [];
  final List<String> spoken = [];

  bool holdSpeech = false;
  bool heavyModelOverlapObserved = false;
  Completer<void>? sttStopGate;

  _ProbeStt createStt() {
    if (ttsEngines.any((engine) => engine.disposeCount == 0)) {
      heavyModelOverlapObserved = true;
    }
    final engine = _ProbeStt(captures, stopGate: sttStopGate);
    sttEngines.add(engine);
    return engine;
  }

  _ProbeTts createTts() {
    if (sttEngines.any((engine) => engine.disposeCount == 0)) {
      heavyModelOverlapObserved = true;
    }
    final engine = _ProbeTts(this);
    ttsEngines.add(engine);
    return engine;
  }

  int get stopSpeakingCalls =>
      ttsEngines.fold(0, (total, engine) => total + engine.stopCount);
}

class _ProbeStt implements SttEngine {
  _ProbeStt(this._allCaptures, {this.stopGate});

  final List<StreamController<SttResult>> _allCaptures;
  final Completer<void>? stopGate;
  final List<StreamController<SttResult>> _ownedCaptures = [];

  int listenCount = 0;
  int stopCount = 0;
  int disposeCount = 0;
  bool _disposed = false;

  @override
  Future<bool> available() async => !_disposed;

  @override
  Stream<SttResult> listen({
    String localeId = 'es_ES',
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
  }) {
    listenCount++;
    final capture = StreamController<SttResult>.broadcast();
    _ownedCaptures.add(capture);
    _allCaptures.add(capture);
    onCaptureReady?.call();
    return capture.stream;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    final gate = stopGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    _disposed = true;
    for (final capture in _ownedCaptures) {
      if (!capture.isClosed) await capture.close();
    }
  }

  @override
  bool get supportsPartials => true;
}

class _ProbeTts implements TtsEngine {
  _ProbeTts(this.probe);

  final _VoiceProbe probe;
  final List<Completer<void>> _pending = [];

  int stopCount = 0;
  int disposeCount = 0;

  @override
  Future<void> speak(String text) {
    probe.spoken.add(text);
    if (!probe.holdSpeech) return Future<void>.value();
    final completion = Completer<void>();
    _pending.add(completion);
    return completion.future;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _releasePending();
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    _releasePending();
  }

  void _releasePending() {
    for (final completion in _pending) {
      if (!completion.isCompleted) completion.complete();
    }
    _pending.clear();
  }
}

class _DesktopGatewayProbe implements HermesDesktopGateway {
  _DesktopGatewayProbe(this.runtimeSessionId);

  final String runtimeSessionId;
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  bool _connected = false;
  int submittedCount = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    _connected = true;
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: runtimeSessionId,
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submittedCount++;
  }

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

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: runtimeSessionId,
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    _connected = false;
    if (!_events.isClosed) await _events.close();
  }
}

class _RuntimeHarness {
  _RuntimeHarness({
    required this.probe,
    required this.voice,
    required this.gateway,
    required this.chat,
    required this.controller,
  });

  final _VoiceProbe probe;
  final VoiceService voice;
  final _DesktopGatewayProbe gateway;
  final ActiveChat chat;
  final LocalVoiceConversationController controller;

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await controller.exit();
    if (chat.isStreaming) chat.cancel();
    controller.dispose();
    chat.dispose();
    await gateway.close();
    await voice.dispose();
  }
}

SavedConnection _connection(String suffix) => SavedConnection(
  id: 'voice-p0-$suffix',
  label: 'Voice P0',
  host: 'example.invalid',
  port: 443,
  apiKey: 'test-only',
  useHttps: true,
  kind: InstanceKind.vps,
);

ActiveChat _chatFor(_DesktopGatewayProbe gateway, String suffix) => ActiveChat(
  connection: _connection(suffix),
  sessionId: 'stored-$suffix',
  sessionTitle: 'Voice P0',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'test-only',
    httpClient: MockClient((_) async => http.Response('unused', 500)),
  ),
  desktopGateway: gateway,
  terminalReconcileBudget: Duration.zero,
);

Future<VoiceService> _voiceFor(_VoiceProbe probe) async {
  final prefs = await SharedPreferences.getInstance();
  final voice = VoiceService(prefs, SecureStorage());
  voice.debugSttFactory = probe.createStt;
  voice.debugTtsFactory = probe.createTts;
  return voice;
}

Future<_RuntimeHarness> _harness(String suffix, {_VoiceProbe? probe}) async {
  final resolvedProbe = probe ?? _VoiceProbe();
  final voice = await _voiceFor(resolvedProbe);
  final gateway = _DesktopGatewayProbe('runtime-$suffix');
  final chat = _chatFor(gateway, suffix);
  final controller = LocalVoiceConversationController(voice);
  await controller.enter(chat: chat, model: 'hermes-agent');
  return _RuntimeHarness(
    probe: resolvedProbe,
    voice: voice,
    gateway: gateway,
    chat: chat,
    controller: controller,
  );
}

Future<void> _waitFor(
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

Future<void> _submitFromMic(_RuntimeHarness harness, String text) async {
  final before = harness.gateway.submittedCount;
  harness.probe.captures.last.add(SttResult(text, true));
  await _waitFor(
    () => harness.gateway.submittedCount == before + 1,
    reason: 'el transcript final debe atravesar ActiveChat.submitPrompt',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'app_locale': 'es'});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('background pausa y resume nunca reabre el micro sin Play', () async {
    final harness = await _harness('lifecycle');
    addTearDown(harness.close);

    expect(harness.controller.phase, VoicePhase.listening);
    expect(harness.probe.sttEngines, hasLength(1));
    expect(harness.probe.captures, hasLength(1));

    await harness.controller.onAppBackgrounded();
    await _waitFor(
      () => harness.probe.sttEngines.single.disposeCount == 1,
      reason: 'background debe liberar la captura activa',
    );
    expect(harness.controller.userPaused, isTrue);

    final enginesAfterBackground = harness.probe.sttEngines.length;
    final capturesAfterBackground = harness.probe.captures.length;
    harness.controller.onAppResumed(appUnlocked: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(harness.controller.userPaused, isTrue);
    expect(harness.probe.sttEngines, hasLength(enginesAfterBackground));
    expect(harness.probe.captures, hasLength(capturesAfterBackground));

    harness.controller.playConversation();
    await _waitFor(
      () => harness.probe.captures.length == capturesAfterBackground + 1,
      reason: 'solo Play explícito puede crear otra captura',
    );
    expect(harness.controller.userPaused, isFalse);
    expect(harness.controller.phase, VoicePhase.listening);
  });

  test(
    'App Lock y Exit invalidan el prewarm aunque el handoff STT termine tarde',
    () async {
      for (final boundary in const ['app-lock', 'exit']) {
        final stopGate = Completer<void>();
        final probe = _VoiceProbe()..sttStopGate = stopGate;
        final harness = await _harness('late-prewarm-$boundary', probe: probe);
        // Determinista en CI: con memoria holgada el handoff usa stop(), que
        // retenemos hasta después de que la frontera haya liberado TTS.
        harness.voice.debugMemoryProfile = const DeviceMemoryProfile(
          memTotalBytes: 16 * 1024 * 1024 * 1024,
        );

        try {
          await _submitFromMic(harness, 'respuesta antes de $boundary');
          await _waitFor(
            () => probe.sttEngines.single.stopCount == 1,
            reason: 'el handoff STT debe quedar retenido antes de $boundary',
          );

          if (boundary == 'app-lock') {
            await harness.controller.suspendForPrivacy().timeout(
              const Duration(seconds: 1),
            );
          } else {
            await harness.controller.exit().timeout(const Duration(seconds: 1));
          }
          expect(probe.ttsEngines, isEmpty);

          stopGate.complete();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(
            probe.ttsEngines,
            isEmpty,
            reason: '$boundary no puede dejar arrancar un TTS post-teardown',
          );
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
          await harness.close();
        }
      }
    },
  );

  test(
    'las herramientas actualizan la fase visual sin hablar automáticamente',
    () async {
      final harness = await _harness('tool-status');
      addTearDown(harness.close);

      await _submitFromMic(harness, 'revisa el proyecto');
      harness.gateway.emit('tool.start', const {
        'name': 'browser',
        'preview': 'https://example.invalid/private',
      });
      await _waitFor(
        () => harness.controller.phase == VoicePhase.toolCall,
        reason: 'la herramienta debe seguir visible en la superficie de voz',
      );
      expect(harness.controller.activeTool, 'browser');
      expect(harness.probe.spoken, isEmpty);

      harness.gateway.emit('tool.progress', const {
        'name': 'browser',
        'preview': '/home/private/project',
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        harness.probe.spoken,
        isEmpty,
        reason:
            'Desktop mantiene el progreso en pantalla y reserva la voz al '
            'comentario assistant público',
      );

      harness.gateway.emit('tool.complete', const {
        'name': 'browser',
        'preview': '/home/private/project',
      });
      await _waitFor(
        () =>
            harness.controller.activeTool == null &&
            harness.controller.phase == VoicePhase.thinking,
        reason: 'una herramienta completada no puede seguir pareciendo activa',
      );

      harness.gateway.emit('tool.start', const {
        'name': 'execute_code',
        'preview': 'secret-command --token private',
      });
      await _waitFor(
        () => harness.controller.activeTool == 'execute_code',
        reason: 'la segunda herramienta debe entrar en la fase visual',
      );
      harness.gateway.emit('tool.complete', const {
        'name': 'execute_code',
        'error': 'fallo interno privado',
      });
      await _waitFor(
        () =>
            harness.controller.activeTool == null &&
            harness.controller.phase == VoicePhase.thinking,
        reason: 'una herramienta fallida tampoco puede quedar activa',
      );
      expect(harness.controller.publicCommentary, isEmpty);
      expect(harness.probe.spoken, isEmpty);
    },
  );

  test(
    'un subagente activo se proyecta como coordinación y termina limpio',
    () async {
      final harness = await _harness('subagent-status');
      addTearDown(harness.close);

      await _submitFromMic(harness, 'coordina una revisión');
      harness.gateway.emit('subagent.start', const {
        'subagent_id': 'child-safe',
        'status': 'running',
      });
      await _waitFor(
        () =>
            harness.controller.activeTool == 'delegate_task' &&
            harness.controller.phase == VoicePhase.toolCall,
        reason: 'la delegación viva debe tener una categoría visual estable',
      );
      expect(harness.probe.spoken, isEmpty);

      harness.gateway.emit('subagent.complete', const {
        'subagent_id': 'child-safe',
        'status': 'completed',
        'summary': 'detalle técnico que Voz no debe proyectar',
      });
      await _waitFor(
        () =>
            harness.controller.activeTool == null &&
            harness.controller.phase == VoicePhase.thinking,
        reason: 'la coordinación terminada debe abandonar toolCall',
      );
      expect(harness.controller.publicCommentary, isEmpty);
      expect(harness.probe.spoken, isEmpty);
    },
  );

  test(
    'dos herramientas homónimas siguen activas hasta el segundo terminal',
    () async {
      final harness = await _harness('concurrent-tools');
      addTearDown(harness.close);

      await _submitFromMic(harness, 'compara dos páginas');
      final starts = harness.chat.changes
          .where((event) => event == ActiveChatEvent.toolProgress)
          .take(2)
          .toList();
      harness.gateway.emit('tool.start', const {'name': 'browser'});
      harness.gateway.emit('tool.start', const {'name': 'browser'});
      await starts.timeout(const Duration(seconds: 1));
      expect(harness.controller.activeTool, 'browser');
      expect(harness.controller.phase, VoicePhase.toolCall);

      final firstTerminal = harness.chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.toolProgress,
      );
      harness.gateway.emit('tool.complete', const {'name': 'browser'});
      await firstTerminal.timeout(const Duration(seconds: 1));
      expect(harness.controller.activeTool, 'browser');
      expect(harness.controller.phase, VoicePhase.toolCall);

      harness.gateway.emit('tool.complete', const {'name': 'browser'});
      await _waitFor(
        () =>
            harness.controller.activeTool == null &&
            harness.controller.phase == VoicePhase.thinking,
        reason: 'el segundo terminal limpia la última llamada abierta',
      );
    },
  );

  test(
    'ids fuertes deduplican starts y cierran herramientas fuera de orden',
    () async {
      final harness = await _harness('tool-call-ids');
      addTearDown(harness.close);

      await _submitFromMic(harness, 'revisa y ejecuta en paralelo');
      harness.gateway.emit('tool.start', const {
        'name': 'browser',
        'tool_call_id': 'call-browser',
      });
      // Retransmisión del mismo start: no representa otra invocación.
      harness.gateway.emit('tool.start', const {
        'name': 'browser',
        'tool_call_id': 'call-browser',
      });
      harness.gateway.emit('tool.start', const {
        'name': 'execute_code',
        'tool_call_id': 'call-exec',
      });
      await _waitFor(
        () => harness.controller.activeTool == 'execute_code',
        reason: 'la invocación viva más reciente debe gobernar la categoría',
      );

      harness.gateway.emit('tool.complete', const {
        'name': 'browser',
        'tool_call_id': 'call-browser',
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(harness.controller.activeTool, 'execute_code');
      expect(harness.controller.phase, VoicePhase.toolCall);

      harness.gateway.emit('tool.complete', const {
        'name': 'execute_code',
        'tool_call_id': 'call-exec',
      });
      await _waitFor(
        () =>
            harness.controller.activeTool == null &&
            harness.controller.phase == VoicePhase.thinking,
        reason: 'cada terminal fuerte debe retirar solo su propia invocación',
      );
    },
  );

  test(
    'reasoning interim queda fuera y el comentario público se acota',
    () async {
      final probe = _VoiceProbe()..holdSpeech = true;
      final harness = await _harness('public-commentary-safety', probe: probe);
      addTearDown(harness.close);

      await _submitFromMic(harness, 'revisa con cuidado');
      harness.gateway.emit('tool.start', const {
        'name': 'read_file',
        'preview': '/home/private/secret.txt',
      });
      harness.gateway.emit('message.interim', const {
        'text': 'RAZONAMIENTO PRIVADO QUE NO DEBE APARECER',
        'reasoning': true,
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(harness.controller.publicCommentary, isEmpty);
      expect(probe.spoken, isEmpty);

      final longPublic =
          '**Comentario público:** '
          '${List<String>.filled(40, 'estoy revisando cada detalle').join(' ')}';
      harness.gateway.emit('message.interim', {'text': longPublic});
      await _waitFor(
        () => harness.controller.publicCommentary.isNotEmpty,
        reason: 'el interim público debe llegar a la única línea de Voz',
      );

      final commentary = harness.controller.publicCommentary;
      expect(commentary, startsWith('Comentario público:'));
      expect(commentary, isNot(contains('**')));
      expect(commentary, isNot(contains('RAZONAMIENTO PRIVADO')));
      expect(commentary, isNot(contains('/home/private')));
      expect(commentary.runes.length, lessThanOrEqualTo(160));
      expect(commentary, endsWith('…'));
    },
  );

  test('el texto público gana y tool/subagent no añaden otro aviso', () async {
    final probe = _VoiceProbe()..holdSpeech = true;
    final harness = await _harness('visual-events', probe: probe);
    addTearDown(harness.close);

    await _submitFromMic(harness, 'revisa el proyecto');
    harness.gateway.emit('message.delta', const {
      'text': 'Esta respuesta sí pertenece al asistente.',
    });
    await _waitFor(
      () => probe.spoken.length == 1,
      reason: 'la respuesta normal debe llegar al TTS real de VoiceService',
    );
    expect(harness.voice.speaking.value, isTrue);
    final stopsBeforeVisualEvents = probe.stopSpeakingCalls;

    harness.gateway.emit('tool.start', const {
      'name': 'browser',
      'preview': 'consultando',
    });
    harness.gateway.emit('subagent.start', const {
      'subagent_id': 'child-p0',
      'status': 'running',
    });
    harness.gateway.emit('subagent.progress', const {
      'subagent_id': 'child-p0',
      'task_index': 1,
      'task_count': 2,
    });
    harness.gateway.emit('message.interim', const {
      'text': 'Avance natural que debe narrarse.',
    });
    await _waitFor(
      () =>
          harness.chat.subagentActivities.isNotEmpty &&
          harness.chat.messages.any(
            (message) => message['_desktopInterim'] == true,
          ),
      reason: 'los eventos visuales deben quedar proyectados en ActiveChat',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(probe.spoken, ['Esta respuesta sí pertenece al asistente.']);
    expect(probe.stopSpeakingCalls, stopsBeforeVisualEvents);
    expect(harness.voice.speaking.value, isTrue);
    expect(harness.controller.phase, VoicePhase.toolCall);

    probe.holdSpeech = false;
    await probe.ttsEngines.single.stop();
    await _waitFor(
      () => probe.spoken.length == 2,
      reason: 'el interim natural debe continuar detrás del audio aceptado',
    );
    expect(probe.spoken, [
      'Esta respuesta sí pertenece al asistente.',
      'Avance natural que debe narrarse.',
    ]);
    expect(
      harness.controller.publicCommentary,
      'Avance natural que debe narrarse.',
    );
    expect(probe.spoken.join(' '), isNot(contains('browser')));
    expect(probe.spoken.join(' '), isNot(contains('consultando')));
    expect(harness.controller.publicCommentary, isNot(contains('browser')));
    expect(harness.controller.publicCommentary, isNot(contains('consultando')));
  });

  test(
    'al volver a escuchar no conserva el comentario del turno anterior',
    () async {
      final harness = await _harness('commentary-turn-boundary');
      addTearDown(harness.close);

      await _submitFromMic(harness, 'comprueba el estado');
      harness.gateway.emit('message.interim', const {
        'text': 'Voy a comprobar el estado.',
      });
      await _waitFor(
        () =>
            harness.controller.publicCommentary == 'Voy a comprobar el estado.',
        reason: 'el comentario público debe proyectarse durante el turno',
      );

      harness.gateway.emit('message.complete', const {
        'text': 'Voy a comprobar el estado. Todo está correcto.',
      });
      await _waitFor(
        () => harness.controller.phase == VoicePhase.listening,
        reason: 'el loop debe volver a escucha tras narrar el final',
      );

      expect(
        harness.controller.publicCommentary,
        isEmpty,
        reason:
            'la nueva escucha no puede parecer congelada en el turno anterior',
      );
    },
  );

  test('una respuesta de más de 1000 caracteres llega completa al TTS', () async {
    final harness = await _harness('long-response');
    addTearDown(harness.close);
    await _submitFromMic(harness, 'dame una explicación extensa');

    final response = List.generate(
      18,
      (index) =>
          'Sección ${index + 1}: esta explicación conserva cada detalle útil, '
          'mantiene el orden de las ideas y termina sin recortar ninguna frase.',
    ).join(' ');
    expect(response.length, greaterThan(1000));

    harness.gateway.emit('message.delta', {'text': response});
    await _waitFor(
      () => harness.probe.spoken.join(' ') == response,
      reason: 'controller + VoiceService deben narrar también el tramo final',
      timeout: const Duration(seconds: 10),
    );

    final rendered = harness.probe.spoken.join(' ');
    expect(rendered.length, greaterThan(1000));
    expect(rendered, startsWith('Sección 1:'));
    expect(rendered, endsWith('sin recortar ninguna frase.'));
    expect(
      harness.probe.spoken,
      everyElement(
        hasLength(lessThanOrEqualTo(VoiceService.maxSpeechUtteranceChars)),
      ),
    );
  });

  test('entrar durante streaming narra antes de crear ningún STT', () async {
    final probe = _VoiceProbe();
    final voice = await _voiceFor(probe);
    final gateway = _DesktopGatewayProbe('runtime-already-streaming');
    final chat = _chatFor(gateway, 'already-streaming');
    final controller = LocalVoiceConversationController(voice);

    addTearDown(() async {
      await controller.exit();
      controller.dispose();
      if (chat.isStreaming) chat.cancel();
      chat.dispose();
      await gateway.close();
      await voice.dispose();
    });

    final accepted = await chat.send(
      fullText: 'continúa la respuesta',
      model: 'hermes-agent',
      history: const [],
    );
    expect(accepted, isTrue);
    gateway.emit('message.delta', const {
      'text': 'Respuesta que ya estaba llegando.',
    });
    await _waitFor(
      () => chat.assistantContent.isNotEmpty,
      reason: 'el chat debe estar emitiendo antes de entrar en modo voz',
    );

    await controller.enter(chat: chat, model: 'hermes-agent');
    await _waitFor(
      () => probe.spoken.isNotEmpty,
      reason: 'la respuesta visible debe narrarse al entrar',
    );
    expect(probe.sttEngines, isEmpty);
    expect(probe.ttsEngines, hasLength(1));

    gateway.emit('message.complete', const {
      'text': 'Respuesta que ya estaba llegando.',
    });
    await _waitFor(
      () => probe.sttEngines.length == 1,
      reason: 'el STT solo debe crearse al terminar la respuesta',
    );
    expect(probe.ttsEngines.single.disposeCount, 1);
    expect(probe.heavyModelOverlapObserved, isFalse);
  });

  test(
    'cinco ciclos App Lock cortan listening/thinking/speaking/Pause sin auto-reanudar',
    () async {
      final probe = _VoiceProbe();
      final voice = await _voiceFor(probe);
      final controller = LocalVoiceConversationController(voice);
      final chats = <ActiveChat>[];
      final gateways = <_DesktopGatewayProbe>[];
      const stages = <String>[
        'listening',
        'thinking',
        'speaking',
        'paused',
        'thinking',
      ];

      addTearDown(() async {
        await controller.exit();
        controller.dispose();
        for (final chat in chats) {
          if (chat.isStreaming) chat.cancel();
          chat.dispose();
        }
        for (final gateway in gateways) {
          await gateway.close();
        }
        await voice.dispose();
      });

      for (var cycle = 0; cycle < stages.length; cycle++) {
        final stage = stages[cycle];
        final gateway = _DesktopGatewayProbe('runtime-lock-$cycle');
        final chat = _chatFor(gateway, 'lock-$cycle');
        gateways.add(gateway);
        chats.add(chat);

        final capturesBeforeEnter = probe.captures.length;
        await controller.enter(chat: chat, model: 'hermes-agent');
        await _waitFor(
          () => probe.captures.length == capturesBeforeEnter + 1,
          reason: 'App Lock ciclo $cycle debe partir de una captura única',
        );
        final cycleStt = probe.sttEngines.last;

        if (stage == 'thinking' || stage == 'speaking') {
          probe.captures.last.add(SttResult('turno privado $cycle', true));
          await _waitFor(
            () => gateway.submittedCount == 1,
            reason: 'el ciclo $cycle debe alcanzar thinking',
          );
          expect(controller.phase, VoicePhase.thinking);
        }
        if (stage == 'speaking') {
          probe.holdSpeech = true;
          gateway.emit('message.delta', const {
            'text': 'Respuesta privada retenida.',
          });
          await _waitFor(
            () => controller.phase == VoicePhase.speaking,
            reason: 'el ciclo speaking debe tener playback vivo',
          );
          expect(voice.speaking.value, isTrue);
        } else if (stage == 'paused') {
          controller.pauseConversation();
          await _waitFor(
            () => cycleStt.disposeCount == 1,
            reason: 'Pause previo debe liberar su STT',
          );
          expect(controller.userPaused, isTrue);
        } else {
          expect(controller.phase, VoicePhase.values.byName(stage));
        }

        final capturesBeforeLock = probe.captures.length;
        final enginesBeforeLock = probe.sttEngines.length;
        final ttsBeforeLock = probe.ttsEngines.length;
        final cycleTts = ttsBeforeLock == 0 ? null : probe.ttsEngines.last;
        await controller.suspendForPrivacy();

        expect(controller.active, isTrue);
        expect(controller.userPaused, isTrue);
        expect(voice.microphoneCapturing.value, isFalse);
        expect(cycleStt.disposeCount, 1);
        if (stage == 'speaking') {
          expect(cycleTts, isNotNull);
          expect(cycleTts!.stopCount, greaterThanOrEqualTo(1));
          expect(cycleTts.disposeCount, 1);
          expect(voice.speaking.value, isFalse);
        }

        controller.onAppResumed(appUnlocked: false);
        controller.onAppResumed(appUnlocked: true);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(controller.userPaused, isTrue);
        expect(probe.captures, hasLength(capturesBeforeLock));
        expect(probe.sttEngines, hasLength(enginesBeforeLock));
        expect(probe.ttsEngines, hasLength(ttsBeforeLock));

        probe.holdSpeech = false;
        await controller.exit();
        expect(controller.active, isFalse);
        if (chat.isStreaming) chat.cancel();
      }

      expect(
        probe.sttEngines.map((engine) => engine.disposeCount),
        everyElement(1),
      );
      expect(
        probe.ttsEngines.map((engine) => engine.disposeCount),
        everyElement(1),
      );
      expect(probe.heavyModelOverlapObserved, isFalse);
    },
  );

  test(
    'cinco ciclos enter/pause/play/stop/exit conservan un único dueño',
    () async {
      final probe = _VoiceProbe();
      final voice = await _voiceFor(probe);
      final controller = LocalVoiceConversationController(voice);
      final chats = <ActiveChat>[];
      final gateways = <_DesktopGatewayProbe>[];

      addTearDown(() async {
        await controller.exit();
        controller.dispose();
        for (final chat in chats) {
          if (chat.isStreaming) chat.cancel();
          chat.dispose();
        }
        for (final gateway in gateways) {
          await gateway.close();
        }
        await voice.dispose();
      });

      for (var cycle = 0; cycle < 5; cycle++) {
        final gateway = _DesktopGatewayProbe('runtime-soak-$cycle');
        final chat = _chatFor(gateway, 'soak-$cycle');
        gateways.add(gateway);
        chats.add(chat);

        final capturesBeforeEnter = probe.captures.length;
        await controller.enter(chat: chat, model: 'hermes-agent');
        await _waitFor(
          () => probe.captures.length == capturesBeforeEnter + 1,
          reason: 'enter del ciclo $cycle debe abrir una captura',
        );

        probe.captures.last.add(SttResult('turno $cycle', true));
        await _waitFor(
          () => gateway.submittedCount == 1,
          reason: 'el ciclo $cycle debe enviar exactamente un turno',
        );
        gateway.emit('message.delta', {
          'text': 'Respuesta controlada del ciclo $cycle.',
        });
        await _waitFor(
          () => probe.spoken.length == cycle + 1,
          reason: 'el ciclo $cycle debe crear una locución',
        );
        await _waitFor(
          () => !voice.speaking.value,
          reason: 'la locución inmediata del ciclo $cycle debe drenar',
        );

        final engineBeforePause = probe.sttEngines.last;
        controller.pauseConversation();
        await _waitFor(
          () => engineBeforePause.disposeCount == 1,
          reason: 'Pause del ciclo $cycle debe liberar su STT',
        );

        final enginesBeforePlay = probe.sttEngines.length;
        controller.playConversation();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          probe.sttEngines,
          hasLength(enginesBeforePlay),
          reason: 'Play no debe precargar STT mientras el backend responde',
        );

        final capturesBeforeStop = probe.captures.length;
        controller.stopAndTalk();
        await _waitFor(
          () => probe.captures.length == capturesBeforeStop + 1,
          reason: 'Stop-and-talk del ciclo $cycle debe reabrir escucha',
        );
        expect(probe.sttEngines, hasLength(enginesBeforePlay + 1));
        final engineBeforeExit = probe.sttEngines.last;

        await controller.exit();
        final sttDisposeAfterFirstExit = engineBeforeExit.disposeCount;
        final ttsDisposeAfterFirstExit = probe.ttsEngines.last.disposeCount;
        await controller.exit();

        expect(sttDisposeAfterFirstExit, 1);
        expect(engineBeforeExit.disposeCount, sttDisposeAfterFirstExit);
        expect(ttsDisposeAfterFirstExit, 1);
        expect(probe.ttsEngines.last.disposeCount, ttsDisposeAfterFirstExit);
        expect(controller.active, isFalse);

        if (chat.isStreaming) chat.cancel();
      }

      expect(probe.sttEngines, hasLength(10));
      expect(
        probe.sttEngines.map((engine) => engine.disposeCount),
        everyElement(1),
      );
      expect(probe.ttsEngines, hasLength(5));
      expect(
        probe.ttsEngines.map((engine) => engine.disposeCount),
        everyElement(1),
      );
      expect(probe.heavyModelOverlapObserved, isFalse);
      expect(probe.spoken, hasLength(5));
    },
  );
}
