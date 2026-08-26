import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/conversation/local_voice_conversation_controller.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Spec 048 / US1 — corte selectivo en el controlador
/// (contracts/narration-fence.md): un re-render que solo toca texto por
/// delante del lote sonando no debe cortar la locución ni repetirla. Tras la QA
/// física de 2026-08-08, una reconciliación autoritativa tampoco trunca una
/// locución fallback que el motor ya aceptó: termina ese lote atómico y retoma
/// la revisión nueva desde el cursor reconciliado.
class _FenceVoice extends VoiceService {
  _FenceVoice(SharedPreferences prefs) : super(prefs, SecureStorage());

  final List<StreamController<SttResult>> captures = [];
  final List<String> spoken = [];
  final List<String> prewarmed = [];
  int stopSpeakingCalls = 0;
  bool holdSpeech = false;
  Completer<void> _speechDone = Completer<void>()..complete();

  @override
  Future<SttCheck> checkStt({bool forComposerDictation = false}) async =>
      const SttCheck(SttStatus.ready, SttEngineKind.sherpaLive);

  @override
  bool get sttRecordsThenTranscribes => false;

  @override
  Stream<SttResult> startDictation({
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
    bool forComposerDictation = false,
  }) {
    final capture = StreamController<SttResult>.broadcast();
    captures.add(capture);
    onCaptureReady?.call();
    return capture.stream;
  }

  @override
  Future<void> stopDictation() async {}

  @override
  Future<void> cancelDictation() async {}

  @override
  Future<bool> enqueueSpeech(String text) async {
    spoken.add(text);
    speaking.value = true;
    if (holdSpeech && _speechDone.isCompleted) {
      _speechDone = Completer<void>();
    }
    return true;
  }

  @override
  Future<bool> enqueueConversationSpeech(
    VoiceConversationSpeechLease lease,
    String text,
  ) async {
    if (!ownsConversationSpeechLease(lease)) return false;
    return enqueueSpeech(text);
  }

  @override
  Future<void> enqueueLocalSpeech(String text) async {}

  @override
  Future<void> prewarmSpeech(String text) async {
    prewarmed.add(text);
  }

  @override
  Future<void> waitSpeechDone() async {
    if (holdSpeech) await _speechDone.future;
    speaking.value = false;
  }

  void finishSpeech() {
    holdSpeech = false;
    speaking.value = false;
    if (!_speechDone.isCompleted) _speechDone.complete();
  }

  @override
  Future<void> stopSpeaking() async {
    stopSpeakingCalls++;
    speaking.value = false;
    if (!_speechDone.isCompleted) _speechDone.complete();
  }

  @override
  Future<void> prepareForNarration() async {}

  @override
  Future<void> releaseTtsForListening() async {}

  @override
  Future<void> disposeSttForVoiceExit() async {}

  @override
  Future<void> disposeTtsForVoiceExit() async {}
}

class _FenceGateway extends http.BaseClient {
  final List<Map<String, dynamic>> runBodies = [];
  final Map<String, StreamController<List<int>>> _events = {};
  String finalText = '';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (request.method == 'POST' && path == '/v1/runs') {
      final body =
          jsonDecode(await request.finalize().bytesToString())
              as Map<String, dynamic>;
      runBodies.add(body);
      return _json({'run_id': 'run_${runBodies.length}'});
    }
    final eventMatch = RegExp(r'^/v1/runs/([^/]+)/events$').firstMatch(path);
    if (request.method == 'GET' && eventMatch != null) {
      final controller = StreamController<List<int>>();
      _events[eventMatch.group(1)!] = controller;
      return http.StreamedResponse(
        controller.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (request.method == 'POST' && path.endsWith('/stop')) {
      return _json({'ok': true});
    }
    if (request.method == 'GET' && path.endsWith('/messages')) {
      return _json({
        'data': [
          if (finalText.isNotEmpty) {'role': 'assistant', 'content': finalText},
        ],
      });
    }
    return http.StreamedResponse(Stream.value(utf8.encode('not found')), 404);
  }

  http.StreamedResponse _json(Map<String, dynamic> value) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(value))),
        200,
        headers: {'content-type': 'application/json'},
      );

  void token(int run, String text) {
    _events['run_$run']?.add(
      utf8.encode(
        'data: ${jsonEncode({'event': 'message.delta', 'delta': text})}\n\n',
      ),
    );
  }

  void toolStarted(int run, String tool, String preview) {
    _events['run_$run']?.add(
      utf8.encode(
        'data: ${jsonEncode({'event': 'tool.started', 'tool': tool, 'preview': preview})}\n\n',
      ),
    );
  }

  /// `run.completed` con un output que puede diferir de los deltas: es la
  /// reconciliación Markdown que dispara el re-render observado en producción.
  Future<void> complete(int run, String text) async {
    finalText = text;
    final controller = _events['run_$run'];
    controller?.add(
      utf8.encode(
        'data: ${jsonEncode({'event': 'run.completed', 'output': text})}\n\n',
      ),
    );
    await controller?.close();
  }
}

class _Harness {
  _Harness(this.voice, this.gateway, this.service, this.chat, this.controller);

  final _FenceVoice voice;
  final _FenceGateway gateway;
  final ActiveChatService service;
  final ActiveChat chat;
  final LocalVoiceConversationController controller;

  Future<void> close() async {
    await controller.exit();
    if (chat.isStreaming) chat.cancel();
    controller.dispose();
    service.dispose();
    for (final capture in voice.captures) {
      if (!capture.isClosed) await capture.close();
    }
  }
}

Future<_Harness> _harness() async {
  final prefs = await SharedPreferences.getInstance();
  final voice = _FenceVoice(prefs);
  final gateway = _FenceGateway();
  final service = ActiveChatService();
  final chat = service.attach(
    connection: SavedConnection(
      id: 'voice-fence',
      label: 'Test',
      host: 'hermes.test',
      port: 8642,
      apiKey: 'test-key',
    ),
    sessionId: 'visible-session',
    sessionTitle: 'Voz',
    api: ApiClient(
      baseUrl: 'http://hermes.test:8642',
      apiKey: 'test-key',
      httpClient: gateway,
    ),
  );
  final controller = LocalVoiceConversationController(voice);
  chat.changes.listen(
    (event) => _events.add(
      '$event|"${chat.assistantContent}"|stops=${voice.stopSpeakingCalls}',
    ),
  );
  await controller.enter(chat: chat, model: 'hermes-agent');
  return _Harness(voice, gateway, service, chat, controller);
}

final List<String> _events = [];

Future<void> _waitFor(bool Function() condition, {String? reason}) async {
  for (var attempt = 0; attempt < 200 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({'app_locale': 'es'}));

  test('re-render por delante del lote sonando no corta ni repite', () async {
    final h = await _harness();
    h.voice.holdSpeech = true;
    h.voice.captures.single.add(const SttResult('cuéntame', true));
    await _waitFor(() => h.gateway.runBodies.isNotEmpty);

    h.gateway.token(1, 'Uno. ');
    await _waitFor(() => h.voice.spoken.isNotEmpty);
    expect(h.voice.spoken, ['Uno.']);
    // `started` corta preventivamente antes de sonar nada; el contrato de la
    // US1 se mide desde que el primer lote está comprometido y sonando.
    final stopsWhilePlaying = h.voice.stopSpeakingCalls;

    // Mientras suena "Uno.", la reconciliación reescribe SOLO lo posterior.
    h.gateway.token(1, 'Dos y ');
    await h.gateway.complete(1, 'Uno. Dos cambiado.');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      h.voice.stopSpeakingCalls,
      stopsWhilePlaying,
      reason: 'la locución en curso no debe cortarse; eventos: $_events',
    );

    h.voice.finishSpeech();
    await _waitFor(
      () => h.voice.spoken.join(' ').contains('Dos cambiado.'),
      reason: 'la continuación corregida debe narrarse',
    );
    expect(h.voice.spoken.first, 'Uno.');
    expect(
      h.voice.spoken.join(' '),
      isNot(contains('Uno. Uno.')),
      reason: 'sin repetición de lo ya hablado',
    );
    expect(h.voice.stopSpeakingCalls, stopsWhilePlaying);
    await h.close();
  });

  test(
    'un turno de voz no altera el contexto ni el estilo del agente',
    () async {
      final h = await _harness();
      h.voice.captures.single.add(const SttResult('qué tal el servidor', true));
      await _waitFor(() => h.gateway.runBodies.isNotEmpty);

      final history =
          (h.gateway.runBodies.single['conversation_history'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const <Map<String, dynamic>>[];
      final serialized = history.map((item) => item['content']).join('\n');
      expect(serialized, isNot(contains('POR VOZ')));
      expect(serialized, isNot(contains('BY VOICE')));
      expect(serialized, isNot(contains('2-4 frases')));
      expect(serialized, isNot(contains('2-4 sentences')));
      expect(h.gateway.runBodies.single['input'], 'qué tal el servidor');
      await h.close();
    },
  );

  test('mientras suena el lote N se pre-sintetiza el N+1', () async {
    final h = await _harness();
    h.voice.holdSpeech = true;
    h.voice.captures.single.add(const SttResult('cuéntame', true));
    await _waitFor(() => h.gateway.runBodies.isNotEmpty);

    // El fallback POST publica la primera oración estable y pre-sintetiza la
    // siguiente mientras aún suena la actual.
    final one = 'Uno ${List.filled(15, 'detalle').join(' ')}.';
    final two = 'Dos ${List.filled(15, 'detalle').join(' ')}.';
    final three = 'Tres ${List.filled(15, 'detalle').join(' ')}.';
    final four = 'Cuatro ${List.filled(15, 'detalle').join(' ')}.';
    h.gateway.token(1, '$one\n\n$two\n\n$three\n\n$four ');
    await _waitFor(() => h.voice.spoken.isNotEmpty);
    expect(h.voice.spoken.single, contains('Uno'));
    expect(h.voice.spoken.single, isNot(contains('Dos')));
    await _waitFor(
      () => h.voice.prewarmed.any((text) => text.contains('Dos')),
      reason:
          'el lote siguiente debe pre-sintetizarse mientras suena el actual',
    );

    // En pausa no se pre-sintetiza nada nuevo.
    final prewarmsBeforePause = h.voice.prewarmed.length;
    h.controller.pauseConversation();
    h.gateway.token(1, 'Cuatro. Cinco. ');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(h.voice.prewarmed.length, prewarmsBeforePause);
    await h.close();
  });

  test(
    'Exit durante el lote N descarta el prewarm N+1 sin volver a hablar',
    () async {
      final h = await _harness();
      h.voice.holdSpeech = true;
      h.voice.captures.single.add(const SttResult('cuéntame', true));
      await _waitFor(() => h.gateway.runBodies.isNotEmpty);

      String paragraph(String label) =>
          '$label ${List.filled(15, 'detalle').join(' ')}.';
      h.gateway.token(
        1,
        '${paragraph('Uno')}\n\n'
        '${paragraph('Dos')}\n\n'
        '${paragraph('Tres')}\n\n'
        '${paragraph('Cuatro')} ',
      );
      await _waitFor(() => h.voice.spoken.isNotEmpty);
      await _waitFor(() => h.voice.prewarmed.isNotEmpty);
      final spokenAtExit = h.voice.spoken.length;
      final prewarmsAtExit = h.voice.prewarmed.length;

      await h.controller.exit();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(h.controller.active, isFalse);
      expect(h.voice.stopSpeakingCalls, greaterThan(0));
      expect(h.voice.spoken, hasLength(spokenAtExit));
      expect(h.voice.prewarmed, hasLength(prewarmsAtExit));
      await h.close();
    },
  );

  test(
    'el lote pre-sintetizado conserva su frontera aunque el stream crezca',
    () async {
      final h = await _harness();
      h.voice.holdSpeech = true;
      h.voice.captures.single.add(const SttResult('cuéntame', true));
      await _waitFor(() => h.gateway.runBodies.isNotEmpty);

      String paragraph(String label) =>
          '$label ${List.filled(15, 'detalle').join(' ')}.';
      final one = paragraph('Uno');
      final two = paragraph('Dos');
      final three = paragraph('Tres');
      final four = paragraph('Cuatro');
      final five = paragraph('Cinco');

      h.gateway.token(1, '$one\n\n$two\n\n$three\n\n$four ');
      await _waitFor(() => h.voice.spoken.isNotEmpty);
      await _waitFor(() => h.voice.prewarmed.isNotEmpty);
      final reserved = h.voice.prewarmed.last;
      expect(reserved, contains('Dos'));

      // La quinta frase llega antes de que termine el lote actual. La reserva
      // de la segunda oración no puede crecer ni cambiar de clave.
      h.gateway.token(1, '$five ');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      h.voice.finishSpeech();
      await _waitFor(() => h.voice.spoken.length >= 2);

      expect(
        h.voice.spoken[1],
        reserved,
        reason: 'el audio siguiente debe consumir exactamente lo precalentado',
      );
      await h.close();
    },
  );

  test(
    'herramienta y final autoritativo no cortan el lote que ya está sonando',
    () async {
      final h = await _harness();
      addTearDown(h.close);
      h.voice.holdSpeech = true;
      h.voice.captures.single.add(const SttResult('dame las noticias', true));
      await _waitFor(() => h.gateway.runBodies.isNotEmpty);

      const preview = 'Voy a buscar las noticias de ayer antes de responder.';
      h.gateway.token(1, '$preview ');
      await _waitFor(() => h.voice.spoken.isNotEmpty);
      expect(h.voice.spoken, [preview]);
      final stopsWhilePlaying = h.voice.stopSpeakingCalls;

      h.gateway.toolStarted(1, 'web_search', 'noticias de ayer');
      await h.gateway.complete(
        1,
        'Estas son las noticias verificadas de ayer. Primera noticia. Segunda noticia.',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        h.voice.stopSpeakingCalls,
        stopsWhilePlaying,
        reason:
            'el cambio de herramienta/estado no puede truncar audio ya aceptado; '
            'eventos: $_events',
      );
      expect(h.voice.spoken, [preview]);

      h.voice.finishSpeech();
      await _waitFor(
        () => h.voice.spoken.join(' ').contains('Estas son las noticias'),
        reason: 'después debe continuar con la respuesta autoritativa',
      );
      expect(h.voice.spoken.where((text) => text == preview), hasLength(1));
    },
  );

  test(
    'el final autoritativo se precalienta mientras termina el lote provisional',
    () async {
      final h = await _harness();
      addTearDown(h.close);
      h.voice.holdSpeech = true;
      h.voice.captures.single.add(const SttResult('dame las noticias', true));
      await _waitFor(() => h.gateway.runBodies.isNotEmpty);

      const preview = 'Voy a buscar las noticias antes de responder.';
      const authoritative =
          'Estas son las noticias verificadas. Primera noticia. Segunda noticia.';
      h.gateway.token(1, '$preview ');
      await _waitFor(() => h.voice.spoken.isNotEmpty);
      expect(h.voice.spoken, [preview]);

      h.gateway.toolStarted(1, 'web_search', 'noticias');
      await h.gateway.complete(1, authoritative);
      await _waitFor(
        () => h.voice.prewarmed.contains('Estas son las noticias verificadas.'),
        reason:
            'la primera oración autoritativa debe solaparse con la locución '
            'provisional para no dejar 4–5 s de silencio al cambiar de revisión',
      );

      expect(h.voice.spoken, [preview]);
      h.voice.finishSpeech();
      await _waitFor(() => h.voice.spoken.join(' ').contains(authoritative));
      expect(h.voice.spoken[1], 'Estas son las noticias verificadas.');
    },
  );

  test(
    'el final decorado continúa tras el cuerpo aceptado sin volver a narrarlo',
    () async {
      final h = await _harness();
      addTearDown(h.close);
      h.voice.holdSpeech = true;
      h.voice.captures.single.add(const SttResult('dame las noticias', true));
      await _waitFor(() => h.gateway.runBodies.isNotEmpty);

      const accepted =
          'Aquí van las noticias verificadas con todos los datos necesarios.';
      h.gateway.token(1, '$accepted ');
      await _waitFor(() => h.voice.spoken.isNotEmpty);
      expect(h.voice.spoken.single, accepted);

      await h.gateway.complete(1, '¡Listo! $accepted Ceuta sigue abierta.');
      await _waitFor(
        () => h.voice.prewarmed.contains('Ceuta sigue abierta.'),
        reason:
            'la revisión final debe preparar solo la cola posterior al cuerpo '
            'que ya está sonando',
      );
      expect(h.voice.spoken, [accepted]);

      h.voice.finishSpeech();
      await _waitFor(() => h.voice.spoken.length >= 2);
      expect(h.voice.spoken, [accepted, 'Ceuta sigue abierta.']);
    },
  );

  test(
    're-render que toca lo comprometido termina el lote y re-sincroniza',
    () async {
      final h = await _harness();
      addTearDown(h.close);
      h.voice.holdSpeech = true;
      h.voice.captures.single.add(const SttResult('cuéntame', true));
      await _waitFor(() => h.gateway.runBodies.isNotEmpty);

      h.gateway.token(1, 'Uno. ');
      await _waitFor(() => h.voice.spoken.isNotEmpty);
      final stopsWhilePlaying = h.voice.stopSpeakingCalls;

      // La reconciliación reescribe el chunk QUE ESTÁ SONANDO.
      await h.gateway.complete(1, 'Cero. Dos.');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        h.voice.stopSpeakingCalls,
        stopsWhilePlaying,
        reason: 'la locución ya aceptada debe terminar sin un corte acústico',
      );
      expect(h.voice.spoken, ['Uno.']);

      h.voice.finishSpeech();
      await _waitFor(
        () => h.voice.spoken.join(' ').contains('Cero.'),
        reason: 'tras terminar el lote debe retomar desde el prefijo común',
      );
      expect(h.voice.spoken.where((text) => text == 'Uno.'), hasLength(1));
      expect(h.voice.stopSpeakingCalls, stopsWhilePlaying);
    },
  );
}
