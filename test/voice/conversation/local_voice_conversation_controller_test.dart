import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/conversation/full_duplex_barge_in_monitor.dart';
import 'package:hermes_android/core/services/voice/conversation/local_voice_conversation_controller.dart';
import 'package:hermes_android/core/services/voice/hermes_pcm_stream.dart';
import 'package:hermes_android/core/services/voice/hermes_speech_stream.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/voice_latency_trace.dart';
import 'package:hermes_android/core/services/voice/voice_phase.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class _FakeVoice extends VoiceService {
  _FakeVoice(SharedPreferences prefs, {bool bargeInEnabled = true})
    : super(
        prefs,
        SecureStorage(),
        initialSettings: VoiceSettings(bargeInEnabled: bargeInEnabled),
      );

  final List<StreamController<SttResult>> captures = [];
  final List<VoidCallback?> captureReadyCallbacks = [];
  final List<String> spoken = [];
  final List<String> prewarmed = [];
  final List<String> localSpoken = [];
  int stopDictationCalls = 0;
  int cancelDictationCalls = 0;
  int stopSpeakingCalls = 0;
  int disposeSttCalls = 0;
  int disposeTtsCalls = 0;
  final List<String> voiceExitCalls = [];
  int prepareNarrationCalls = 0;
  int releaseTtsForListeningCalls = 0;
  bool holdSpeech = false;
  bool acceptSpeech = true;
  bool holdStopSpeaking = false;
  bool releaseSpeechBeforeStopCompletes = false;
  bool captureReadyAutomatically = true;
  Object? waitSpeechError;
  Completer<void>? disposeSttGate;
  Completer<void>? disposeTtsGate;
  Completer<void>? _stopSpeakingGate;
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
    captureReadyCallbacks.add(onCaptureReady);
    if (captureReadyAutomatically) onCaptureReady?.call();
    return capture.stream;
  }

  void confirmCaptureReady(int index) {
    final callback = captureReadyCallbacks[index];
    captureReadyCallbacks[index] = null;
    callback?.call();
  }

  @override
  Future<void> stopDictation() async {
    stopDictationCalls++;
  }

  @override
  Future<void> cancelDictation() async {
    cancelDictationCalls++;
  }

  @override
  Future<bool> enqueueSpeech(String text) async {
    spoken.add(text);
    if (!acceptSpeech) return false;
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
  Future<void> prewarmConversationSpeech(
    VoiceConversationSpeechLease lease,
    String text,
  ) async {
    if (ownsConversationSpeechLease(lease)) prewarmed.add(text);
  }

  @override
  bool endConversationSpeechLease(VoiceConversationSpeechLease lease) {
    voiceExitCalls.add('endSpeechLease');
    return super.endConversationSpeechLease(lease);
  }

  @override
  Future<void> enqueueLocalSpeech(String text) async {
    localSpoken.add(text);
  }

  @override
  Future<void> waitSpeechDone() async {
    if (holdSpeech) await _speechDone.future;
    speaking.value = false;
    final error = waitSpeechError;
    waitSpeechError = null;
    if (error != null) throw error;
  }

  void finishSpeech() {
    holdSpeech = false;
    _interruptSpeech();
  }

  void _interruptSpeech() {
    speaking.value = false;
    if (!_speechDone.isCompleted) _speechDone.complete();
  }

  void releaseStopSpeaking() {
    final gate = _stopSpeakingGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> stopSpeaking() async {
    stopSpeakingCalls++;
    voiceExitCalls.add('stopSpeaking');
    if (nativeSpeechStreamingAvailable) {
      await super.stopSpeaking();
    }
    if (releaseSpeechBeforeStopCompletes) _interruptSpeech();
    if (holdStopSpeaking) {
      _stopSpeakingGate ??= Completer<void>();
      await _stopSpeakingGate!.future;
      holdStopSpeaking = false;
      _stopSpeakingGate = null;
    }
    _interruptSpeech();
  }

  @override
  Future<void> prepareForNarration() async {
    prepareNarrationCalls++;
  }

  @override
  Future<void> releaseTtsForListening() async {
    releaseTtsForListeningCalls++;
  }

  @override
  Future<void> disposeSttForVoiceExit() async {
    disposeSttCalls++;
    voiceExitCalls.add('disposeStt');
    await disposeSttGate?.future;
  }

  @override
  Future<void> disposeTtsForVoiceExit() async {
    disposeTtsCalls++;
    voiceExitCalls.add('disposeTts');
    await disposeTtsGate?.future;
  }
}

class _ControllerSpeechSocket implements HermesSpeechSocket {
  _ControllerSpeechSocket({this.timeline, this.rejectTextFrames = false});

  final List<String>? timeline;
  final bool rejectTextFrames;
  final StreamController<dynamic> controller = StreamController<dynamic>();
  final List<Map<String, dynamic>> sent = [];

  @override
  Stream<dynamic> get frames => controller.stream;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  void send(String frame) {
    final decoded = Map<String, dynamic>.from(jsonDecode(frame) as Map);
    if (rejectTextFrames && decoded['text'] != null) {
      throw StateError('speech text rejected');
    }
    sent.add(decoded);
    if (decoded['text'] != null) timeline?.add('text:${decoded['text']}');
    if (decoded['done'] == true) timeline?.add('done');
    if (decoded['stop'] == true) timeline?.add('stop');
  }

  @override
  Future<void> close() async {}

  Future<void> emit(dynamic frame) async {
    controller.add(frame);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> fail() async {
    controller.addError(StateError('socket dropped'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }
}

class _ControllerPcmSink implements HermesPcmStreamSink {
  _ControllerPcmSink({this.timeline});

  final List<String>? timeline;
  @override
  final int generation = 101;

  final List<Uint8List> writes = [];
  int pauses = 0;
  int resumes = 0;
  int finishes = 0;
  bool stopped = false;
  Completer<void>? finishGate;

  @override
  Future<void> configure(HermesPcmFormat format) async {}

  @override
  Future<void> write(Uint8List pcm16le) async {
    writes.add(Uint8List.fromList(pcm16le));
    timeline?.add('pcm:${pcm16le.first}');
  }

  @override
  Future<void> pause() async {
    pauses++;
    timeline?.add('pause');
  }

  @override
  Future<void> resume() async {
    resumes++;
    timeline?.add('resume');
  }

  @override
  Future<void> finish() async {
    finishes++;
    await finishGate?.future;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

class _ControllerFullDuplexSource implements FullDuplexCaptureSource {
  final audio = StreamController<Uint8List>.broadcast();
  int starts = 0;
  int stops = 0;
  String transcript = '';
  bool playbackActive = false;
  Completer<void>? startGate;
  Completer<void>? playbackGate;
  Completer<String>? transcriptionGate;
  FullDuplexPlaybackSafety safety = const FullDuplexPlaybackSafety(
    aecEnabled: true,
    privateOutput: true,
    playbackSafe: true,
  );

  @override
  bool get transcriptionAvailable => true;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    await startGate?.future;
    return audio.stream;
  }

  @override
  Future<void> setPlaybackActive(bool active) async {
    playbackActive = active;
    if (active) await playbackGate?.future;
  }

  @override
  Future<FullDuplexPlaybackSafety> playbackSafety() async => safety;

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<String> transcribe(Uint8List wavBytes) async =>
      transcriptionGate == null ? transcript : transcriptionGate!.future;

  @override
  Future<void> dispose() async {
    if (!audio.isClosed) await audio.close();
  }
}

Uint8List _bargePcmFrame(int amplitude) {
  const samples = 480;
  final bytes = Uint8List(samples * 2);
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < samples; index++) {
    data.setInt16(
      index * 2,
      index.isEven ? amplitude : -amplitude,
      Endian.little,
    );
  }
  return bytes;
}

Future<void> _emitBargeFrames(
  _ControllerFullDuplexSource source,
  int amplitude,
  int count,
) async {
  for (var index = 0; index < count; index++) {
    source.audio.add(_bargePcmFrame(amplitude));
  }
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void _enableStreamingVoice(
  _FakeVoice voice,
  _ControllerSpeechSocket socket,
  _ControllerPcmSink sink, {
  bool fallbackBeforeReturn = false,
  void Function()? onOpen,
}) {
  voice.enableNativeVoice(
    speak: (text) async => <String, dynamic>{'ok': false},
    transcribe: (dataUrl, mimeType) async => <String, dynamic>{'text': ''},
    speechStream: () async {
      onOpen?.call();
      final session = HermesSpeechStreamSession(
        socket: socket,
        sink: sink,
        finishTimeout: const Duration(seconds: 2),
        latencyTurn: VoiceLatencyTrace.current.currentTurn,
      );
      await session.open();
      if (fallbackBeforeReturn) {
        await socket.emit(jsonEncode({'type': 'fallback'}));
      }
      return session;
    },
  );
}

class _FakeGateway extends http.BaseClient {
  _FakeGateway({this.rejectRuns = false});

  final bool rejectRuns;
  final List<Map<String, dynamic>> runBodies = [];
  final List<String> hits = [];
  final Map<String, StreamController<List<int>>> _events = {};
  String finalText = '';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    hits.add('${request.method} $path');
    if (request.method == 'POST' && path == '/v1/runs') {
      final body =
          jsonDecode(await request.finalize().bytesToString())
              as Map<String, dynamic>;
      runBodies.add(body);
      if (rejectRuns) {
        return http.StreamedResponse(
          Stream.value(utf8.encode('unavailable')),
          503,
        );
      }
      final id = 'run_${runBodies.length}';
      return _json({'run_id': id});
    }
    final eventMatch = RegExp(r'^/v1/runs/([^/]+)/events$').firstMatch(path);
    if (request.method == 'GET' && eventMatch != null) {
      final id = eventMatch.group(1)!;
      final controller = StreamController<List<int>>();
      _events[id] = controller;
      return http.StreamedResponse(
        controller.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (request.method == 'POST' && path.endsWith('/stop')) {
      return _json({'ok': true});
    }
    if (request.method == 'POST' && path.endsWith('/approval')) {
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

  void approval(int run, {String command = 'rm archivo'}) {
    _events['run_$run']?.add(
      utf8.encode(
        'data: ${jsonEncode({'event': 'approval.request', 'command': command, 'pattern_key': 'rm'})}\n\n',
      ),
    );
  }

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

SavedConnection _connection() => SavedConnection(
  id: 'voice-local-controller',
  label: 'Test',
  host: 'hermes.test',
  port: 8642,
  apiKey: 'test-key',
);

class _Harness {
  _Harness(this.voice, this.gateway, this.service, this.chat, this.controller);

  final _FakeVoice voice;
  final _FakeGateway gateway;
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

Future<_Harness> _harness({
  FullDuplexBargeInMonitor? fullDuplexMonitor,
  Future<void> Function(String prompt)? onBeforeSend,
  Future<void> Function(Duration delay)? playbackTailDelay,
  bool bargeInEnabled = true,
  bool continueWhenLocked = false,
  bool rejectRuns = false,
  bool captureReadyAutomatically = true,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final voice = _FakeVoice(prefs, bargeInEnabled: bargeInEnabled);
  voice.captureReadyAutomatically = captureReadyAutomatically;
  if (continueWhenLocked) {
    await voice.acceptVoiceDisclosure(continueWhenLocked: true);
  }
  final gateway = _FakeGateway(rejectRuns: rejectRuns);
  final service = ActiveChatService();
  final chat = service.attach(
    connection: _connection(),
    sessionId: 'visible-session',
    sessionTitle: 'Voz',
    api: ApiClient(
      baseUrl: 'http://hermes.test:8642',
      apiKey: 'test-key',
      httpClient: gateway,
    ),
  );
  final controller = LocalVoiceConversationController(
    voice,
    fullDuplexMonitor: fullDuplexMonitor,
    playbackTailDelay: playbackTailDelay ?? (_) async {},
  );
  await controller.enter(
    chat: chat,
    model: 'hermes-agent',
    onBeforeSend: onBeforeSend,
  );
  return _Harness(voice, gateway, service, chat, controller);
}

Future<void> _waitFor(
  bool Function() condition, {
  String Function()? diagnostics,
}) async {
  for (var attempt = 0; attempt < 200 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: diagnostics?.call());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({'app_locale': 'es'}));

  test('full-duplex exterior exige continuidad manual', () {
    expect(
      voiceConversationMustSuspendFullDuplexInBackground(
        continueWhenLocked: false,
      ),
      isTrue,
    );
    expect(
      voiceConversationMustSuspendFullDuplexInBackground(
        continueWhenLocked: true,
      ),
      isFalse,
    );
  });

  test('stop phrases preserve Desktop plus exact Spanish silence', () {
    expect(
      LocalVoiceConversationController.isExactVoiceStopPhrase('Stop.'),
      isTrue,
    );
    expect(
      LocalVoiceConversationController.isExactVoiceStopPhrase('¡Para!'),
      isFalse,
    );
    for (final phrase in const <String>[
      'Cállate.',
      'Callate',
      'Hermes, cállate.',
    ]) {
      expect(
        LocalVoiceConversationController.isExactVoiceStopPhrase(phrase),
        isTrue,
        reason: phrase,
      );
    }
    for (final phrase in const <String>[
      'Goodbye!',
      'Good bye',
      'Bye',
      'Cancel',
      'Stop listening',
      'Stop it',
      'Stop please',
      'Please stop',
      'Stop stop',
      'That is all',
      "That's all",
      'Never mind',
      'Nevermind',
      'End conversation',
      'End the conversation',
      'Hermes, stop.',
      'Ok, please stop.',
    ]) {
      expect(
        LocalVoiceConversationController.isExactVoiceStopPhrase(phrase),
        isTrue,
        reason: phrase,
      );
    }
    for (final ambiguous in const <String>[
      'para',
      'ya está',
      'end',
      'finish',
      'silencio',
      'basta',
      'cierra',
      'Hermes',
      'Cállate ya.',
      'Deja de hablar',
      '¡Cancela!',
      'Termina',
      'Cierra la conversación.',
      'Shut up',
      'Stop talking',
    ]) {
      expect(
        LocalVoiceConversationController.isExactVoiceStopPhrase(ambiguous),
        isFalse,
        reason: ambiguous,
      );
    }
    expect(
      LocalVoiceConversationController.isExactVoiceStopPhrase(
        'stop the container',
      ),
      isFalse,
    );
    expect(
      LocalVoiceConversationController.isExactVoiceStopPhrase(
        'how do I stop a running process',
      ),
      isFalse,
    );
    expect(
      LocalVoiceConversationController.isExactVoiceStopPhrase(
        'okay stop the container',
      ),
      isFalse,
    );
    expect(
      LocalVoiceConversationController.isExactVoiceStopPhrase(
        'para el servidor',
      ),
      isFalse,
    );
    expect(
      LocalVoiceConversationController.isExactVoiceStopPhrase(
        'callate y dime otra cosa',
      ),
      isFalse,
    );
    for (final prompt in const <String>[
      'dile adiós al problema',
      'cancela el cron de mañana',
      'termina la explicación',
      'cancel the reminder',
      'end the current task',
      'shut up and tell me something else',
    ]) {
      expect(
        LocalVoiceConversationController.isExactVoiceStopPhrase(prompt),
        isFalse,
        reason: prompt,
      );
    }
  });

  test('solo la emisión aislada y se considera espuria', () {
    for (final transcript in const <String>['y', 'Y.', ' y… ']) {
      expect(
        LocalVoiceConversationController.isSpuriousIsolatedTranscript(
          transcript,
        ),
        isTrue,
        reason: transcript,
      );
    }
    for (final transcript in const <String>['sí', 'Si', 'no', 'y ahora']) {
      expect(
        LocalVoiceConversationController.isSpuriousIsolatedTranscript(
          transcript,
        ),
        isFalse,
        reason: transcript,
      );
    }
  });

  test(
    'minimizar solo oculta la superficie y conserva la conversación',
    () async {
      final h = await _harness();
      final phaseBefore = h.controller.phase;

      h.controller.minimizeOverlay();

      expect(h.controller.active, isTrue);
      expect(h.controller.overlayMinimized, isTrue);
      expect(h.controller.userPaused, isFalse);
      expect(h.controller.phase, phaseBefore);
      expect(h.controller.ownsChat(h.chat), isTrue);

      h.controller.resumeOverlay();
      expect(h.controller.overlayMinimized, isFalse);
      expect(h.controller.active, isTrue);
      await h.close();
    },
  );

  test('Stop exacto durante escucha termina sin enviar un turno', () async {
    final h = await _harness();

    h.voice.captures.single.add(const SttResult('Stop.', true));
    await _waitFor(() => !h.controller.active);

    expect(h.gateway.runBodies, isEmpty);
    expect(h.voice.prepareNarrationCalls, 0);
    expect(h.controller.userTranscript, isEmpty);
    await h.close();
  });

  test('una y aislada rearma sin saludo fantasma y sí sigue al chat', () async {
    final h = await _harness();

    h.voice.captures.single.add(const SttResult('Y.', true));
    await _waitFor(() => h.voice.captures.length == 2);

    expect(h.gateway.runBodies, isEmpty);
    expect(h.controller.phase, VoicePhase.listening);

    h.voice.captures[1].add(const SttResult('sí', true));
    await _waitFor(() => h.gateway.runBodies.length == 1);

    expect(h.gateway.runBodies.single['input'], 'sí');
    h.chat.cancel();
    await h.close();
  });

  test('Cállate durante escucha termina sin enviar un turno', () async {
    final h = await _harness();

    h.voice.captures.single.add(const SttResult('Cállate.', true));
    await _waitFor(() => !h.controller.active);

    expect(h.gateway.runBodies, isEmpty);
    expect(h.service.of(h.chat.connection.id, h.chat.sessionId), same(h.chat));
    expect(h.controller.userTranscript, isEmpty);
    await h.close();
  });

  test(
    'cerrar el ActiveChat propietario termina Voz sin dejar captura',
    () async {
      final h = await _harness();

      h.chat.dispose();
      await _waitFor(() => !h.controller.active);

      expect(h.voice.disposeSttCalls, 1);
      expect(h.voice.disposeTtsCalls, 1);
      expect(h.controller.ownerChat, isNull);
      await h.close();
    },
  );

  test('una frase que contiene stop sigue llegando al agente', () async {
    final h = await _harness();

    h.voice.captures.single.add(const SttResult('stop the container', true));
    await _waitFor(() => h.gateway.runBodies.length == 1);

    final body = h.gateway.runBodies.single;
    expect(body['input'], 'stop the container');
    await h.close();
  });

  test(
    'parcial visible, un final, un submit y cero rutas auxiliares',
    () async {
      final h = await _harness();
      expect(h.controller.phase, VoicePhase.listening);

      h.voice.captures.single.add(const SttResult('hola par', false));
      await Future<void>.delayed(Duration.zero);
      expect(h.controller.partialTranscript, 'hola par');

      h.voice.captures.single.add(const SttResult('hola Hermes', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      expect(h.controller.userTranscript, 'hola Hermes');

      h.gateway.token(1, 'Hola, estoy aquí.');
      await _waitFor(() => h.voice.spoken.isNotEmpty);
      await h.gateway.complete(1, 'Hola, estoy aquí.');
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(h.voice.spoken, ['Hola, estoy aquí.']);
      expect(h.controller.assistantResponse, 'Hola, estoy aquí.');
      expect(h.gateway.runBodies, hasLength(1));
      final evidence = jsonEncode([h.gateway.hits, h.gateway.runBodies]);
      expect(evidence, isNot(contains('mob-aux-')));
      expect(evidence, isNot(contains('/v1/chat/completions')));

      await h.close();
    },
  );

  test(
    'la captura normal no publica listening antes del ACK causal del motor',
    () async {
      final h = await _harness(captureReadyAutomatically: false);

      expect(h.voice.captures, hasLength(1));
      expect(h.controller.phase, VoicePhase.idle);

      h.voice.confirmCaptureReady(0);
      expect(h.controller.phase, VoicePhase.listening);

      await h.close();
    },
  );

  test(
    'ACK normal stale, fallido o posterior a Exit no rearma la UI',
    () async {
      final stale = await _harness(captureReadyAutomatically: false);
      stale.controller.retry();
      await _waitFor(() => stale.voice.captures.length == 2);

      stale.voice.confirmCaptureReady(0);
      expect(stale.controller.phase, VoicePhase.idle);
      stale.voice.confirmCaptureReady(1);
      expect(stale.controller.phase, VoicePhase.listening);
      await stale.close();

      final failed = await _harness(captureReadyAutomatically: false);
      failed.voice.captures.single.addError(StateError('recorder unavailable'));
      await Future<void>.delayed(Duration.zero);
      expect(failed.controller.phase, VoicePhase.idle);
      failed.voice.confirmCaptureReady(0);
      expect(failed.controller.phase, VoicePhase.idle);
      await failed.close();

      final cancelled = await _harness(captureReadyAutomatically: false);
      await cancelled.controller.exit();
      cancelled.voice.confirmCaptureReady(0);
      expect(cancelled.controller.active, isFalse);
      expect(cancelled.controller.phase, VoicePhase.idle);
      await cancelled.close();
    },
  );

  test(
    'los parciales actualizan el estado sin notificar la superficie de Voz',
    () async {
      final h = await _harness();
      expect(h.controller.phase, VoicePhase.listening);

      var notifications = 0;
      void countNotification() => notifications++;
      h.controller.addListener(countNotification);

      h.voice.captures.single.add(const SttResult('hola', false));
      await Future<void>.delayed(Duration.zero);
      expect(h.controller.partialTranscript, 'hola');
      expect(notifications, 0);

      h.voice.captures.single.add(const SttResult('hola par', false));
      await Future<void>.delayed(Duration.zero);
      expect(h.controller.partialTranscript, 'hola par');
      expect(notifications, 0);

      h.voice.captures.single.add(const SttResult('hola Hermes', true));
      await _waitFor(() => notifications > 0);
      expect(h.controller.userTranscript, 'hola Hermes');
      expect(h.controller.phase, isNot(VoicePhase.listening));

      h.controller.removeListener(countNotification);
      await h.close();
    },
  );

  test(
    'los tokens posteriores no notifican de nuevo la superficie de Voz',
    () async {
      final h = await _harness();
      h.voice.captures.single.add(const SttResult('hola Hermes', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      var notifications = 0;
      void countNotification() => notifications++;
      h.controller.addListener(countNotification);

      h.gateway.token(1, 'Hola');
      await _waitFor(() => h.chat.assistantContent == 'Hola');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final afterFirstToken = notifications;
      expect(afterFirstToken, greaterThan(0));

      h.gateway.token(1, ' mundo');
      await _waitFor(() => h.chat.assistantContent == 'Hola mundo');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(notifications, afterFirstToken);
      h.controller.removeListener(countNotification);
      await h.close();
    },
  );

  test(
    'un fallo de voz Hermes pausa y muestra error sin reabrir STT',
    () async {
      final h = await _harness();
      h.voice.waitSpeechError = const VoiceRouteUnavailableException();

      h.voice.captures.single.add(const SttResult('hola Hermes', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Respuesta del servidor.');
      await _waitFor(() => h.controller.userPaused);

      expect(h.controller.phase, VoicePhase.idle);
      expect(h.controller.note, contains('servidor Hermes'));
      expect(h.voice.captures, hasLength(1));
      await h.close();
    },
  );

  test(
    'el segundo terminal del mismo turno no reinicia una escucha ya activa',
    () async {
      final h = await _harness();

      h.voice.captures.single.add(const SttResult('hola Hermes', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Te escucho.');
      await h.gateway.complete(1, 'Te escucho.');
      await _waitFor(() => h.voice.captures.length == 2);

      // ActiveChat proyecta `completed` y, 800 ms después, `idle` mediante un
      // segundo `done`. Ese terminal es idempotente para Voz: la captura que
      // ya está escuchando no puede volver a abrir AudioRecord.
      await Future<void>.delayed(const Duration(milliseconds: 950));

      expect(h.controller.phase, VoicePhase.listening);
      expect(h.voice.captures, hasLength(2));
      await h.close();
    },
  );

  test(
    'el micro espera la cola acústica Android y tolera terminal duplicado',
    () async {
      final tailGate = Completer<void>();
      Duration? requestedDelay;
      final h = await _harness(
        playbackTailDelay: (delay) {
          requestedDelay = delay;
          return tailGate.future;
        },
      );

      h.voice.captures.single.add(const SttResult('hola Hermes', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await h.gateway.complete(1, 'Te escucho.');
      await _waitFor(() => requestedDelay != null);

      expect(requestedDelay, const Duration(milliseconds: 500));
      expect(h.voice.captures, hasLength(1));

      // ActiveChat emite el backstop completed -> idle unos 800 ms después.
      // Ese segundo terminal no puede saltarse la valla acústica pendiente.
      await Future<void>.delayed(const Duration(milliseconds: 950));
      expect(h.voice.captures, hasLength(1));

      tailGate.complete();
      await _waitFor(() => h.voice.captures.length == 2);
      expect(h.controller.phase, VoicePhase.listening);
      await h.close();
    },
  );

  test('Exit durante la cola acústica impide un rearme tardío', () async {
    final tailGate = Completer<void>();
    var guardStarted = false;
    final h = await _harness(
      playbackTailDelay: (_) {
        guardStarted = true;
        return tailGate.future;
      },
    );

    h.voice.captures.single.add(const SttResult('hola Hermes', true));
    await _waitFor(() => h.gateway.runBodies.length == 1);
    await h.gateway.complete(1, 'Te escucho.');
    await _waitFor(() => guardStarted);

    await h.controller.exit();
    tailGate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(h.controller.active, isFalse);
    expect(h.voice.captures, hasLength(1));
    await h.close();
  });

  test('una escucha que termina vacía sí rearma el micrófono', () async {
    final h = await _harness();

    await h.voice.captures.single.close();
    await _waitFor(() => h.voice.captures.length == 2);

    expect(h.controller.phase, VoicePhase.listening);
    await h.close();
  });

  test('un final idle vacío rearma sin mostrar Transcribiendo', () async {
    final h = await _harness();
    final projectedPhases = <VoicePhase>[];
    h.controller.addListener(() {
      projectedPhases.add(h.controller.phase);
    });

    h.voice.captures.single.add(const SttResult('', true));
    await _waitFor(() => h.voice.captures.length == 2);

    expect(projectedPhases, isNot(contains(VoicePhase.transcribing)));
    expect(h.controller.phase, VoicePhase.listening);
    expect(h.controller.note, isNull);
    expect(h.voice.prepareNarrationCalls, 0);
    await h.close();
  });

  test('el envío de voz no espera al autotítulo local', () async {
    final metadataGate = Completer<void>();
    final h = await _harness(onBeforeSend: (_) => metadataGate.future);

    h.voice.captures.single.add(const SttResult('envía sin esperar', true));
    await _waitFor(() => h.gateway.runBodies.length == 1);

    expect(metadataGate.isCompleted, isFalse);
    expect(h.gateway.runBodies.single['input'], 'envía sin esperar');
    metadataGate.complete();
    await h.close();
  });

  test('Pause conserva cursor y Play repite como máximo la frase', () async {
    final h = await _harness();
    h.voice.holdSpeech = true;
    h.voice.captures.single.add(const SttResult('cuéntame algo', true));
    await _waitFor(() => h.gateway.runBodies.isNotEmpty);
    h.gateway.token(1, 'Primera frase.');
    await _waitFor(() => h.voice.spoken.length == 1);
    expect(h.controller.debugNarrationCursor, 0);

    h.controller.pauseConversation();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(h.controller.userPaused, isTrue);
    expect(h.controller.debugNarrationCursor, 0);

    h.voice.holdSpeech = true;
    h.controller.playConversation();
    await _waitFor(() => h.voice.spoken.length == 2);
    expect(h.voice.spoken, ['Primera frase.', 'Primera frase.']);

    h.voice.finishSpeech();
    await h.gateway.complete(1, 'Primera frase.');
    await h.close();
  });

  test(
    'Pause local libera lease y modelos sin perder conversación ni ruta',
    () async {
      final h = await _harness();
      final owner = h.controller.ownerChat;
      expect(h.controller.audioLeaseRequired, isTrue);
      expect(h.controller.phase, VoicePhase.listening);

      h.controller.pauseConversation();
      await _waitFor(
        () =>
            h.voice.disposeSttCalls == 1 &&
            h.voice.disposeTtsCalls == 1 &&
            !h.controller.audioLeaseRequired,
      );

      expect(h.controller.active, isTrue);
      expect(h.controller.userPaused, isTrue);
      expect(h.controller.ownerChat, same(owner));
      expect(h.voice.captures, hasLength(1));

      h.controller.playConversation();
      await _waitFor(() => h.voice.captures.length == 2);

      expect(h.controller.active, isTrue);
      expect(h.controller.userPaused, isFalse);
      expect(h.controller.audioLeaseRequired, isTrue);
      expect(h.controller.ownerChat, same(owner));
      expect(h.controller.phase, VoicePhase.listening);
      await h.close();
    },
  );

  test(
    'los cortes internos sin pausa llegan al TTS como una sola locución',
    () async {
      final h = await _harness();
      final response =
          '${List.generate(90, (index) => 'palabra$index').join(' ')}.';
      expect(response.length, greaterThan(480));

      h.voice.captures.single.add(const SttResult('respuesta larga', true));
      await _waitFor(() => h.gateway.runBodies.isNotEmpty);
      await h.gateway.complete(1, response);
      await _waitFor(() => h.voice.spoken.isNotEmpty);

      expect(h.voice.spoken, [response]);
      await h.close();
    },
  );

  test(
    'fallback POST narra cada oración en orden antes del terminal',
    () async {
      final h = await _harness();
      const response =
          'Primera frase. Segunda frase. Una última frase sin puntuación';

      h.voice.captures.single.add(const SttResult('lee los párrafos', true));
      await _waitFor(() => h.gateway.runBodies.isNotEmpty);
      h.gateway.token(1, 'Primera frase. ');
      await _waitFor(() => h.voice.spoken.length == 1);
      expect(h.voice.spoken, ['Primera frase.']);

      h.gateway.token(1, 'Segunda frase. ');
      await _waitFor(() => h.voice.spoken.length == 2);
      expect(h.voice.spoken, ['Primera frase.', 'Segunda frase.']);

      h.gateway.token(1, 'Una última frase sin puntuación');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.voice.spoken, hasLength(2));

      await h.gateway.complete(1, response);
      await _waitFor(() => h.voice.spoken.length == 3);
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(h.voice.spoken, [
        'Primera frase.',
        'Segunda frase.',
        'Una última frase sin puntuación.',
      ]);
      await h.close();
    },
  );

  test(
    'Play inmediato no se pierde mientras el stop TTS sigue pendiente',
    () async {
      final h = await _harness();
      h.voice.holdSpeech = true;
      h.voice.holdStopSpeaking = true;
      h.voice.captures.single.add(const SttResult('respuesta con pausa', true));
      await _waitFor(() => h.gateway.runBodies.isNotEmpty);
      h.gateway.token(1, 'Frase interrumpida.');
      await _waitFor(() => h.voice.spoken.length == 1);

      h.controller.pauseConversation();
      h.controller.playConversation();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.voice.spoken, hasLength(1));

      h.voice.releaseStopSpeaking();
      await _waitFor(() => h.voice.spoken.length == 2);
      expect(h.voice.spoken, ['Frase interrumpida.', 'Frase interrumpida.']);

      h.voice.finishSpeech();
      await h.gateway.complete(1, 'Frase interrumpida.');
      await h.close();
    },
  );

  test('parciales y final tardíos tras Pause son no-op', () async {
    final h = await _harness();
    final staleCapture = h.voice.captures.single;
    h.controller.pauseConversation();

    staleCapture.add(const SttResult('texto tardío', false));
    staleCapture.add(const SttResult('envío tardío', true));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(h.controller.partialTranscript, isNot('texto tardío'));
    expect(h.controller.userTranscript, isEmpty);
    expect(h.gateway.runBodies, isEmpty);
    await h.close();
  });

  test(
    'una aprobación avisa una vez, silencia el micro y solo se resuelve por UI',
    () async {
      final h = await _harness();
      h.voice.captures.single.add(
        const SttResult('haz una acción sensible', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);

      h.gateway.toolStarted(1, 'web_search', 'noticias de hoy');
      await _waitFor(() => h.controller.phase == VoicePhase.toolCall);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        h.voice.localSpoken,
        isEmpty,
        reason:
            'el progreso de herramientas debe ser visual, como en Desktop y Play',
      );

      h.gateway.approval(1);
      await _waitFor(() => h.controller.phase == VoicePhase.waitingPermission);
      await _waitFor(() => h.voice.localSpoken.length == 1);
      expect(
        h.voice.localSpoken.single,
        'Hermes necesita tu aprobación. Abre la aplicación para revisarla.',
      );
      expect(h.voice.cancelDictationCalls, greaterThanOrEqualTo(1));
      expect(h.voice.captures, hasLength(1));

      // Un reenvío idéntico del gateway no duplica el aviso ni reabre STT.
      h.gateway.approval(1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.voice.localSpoken, hasLength(1));
      expect(h.voice.captures, hasLength(1));

      // Un progreso tardío tampoco oculta la aprobación ni vuelve a hablar.
      h.gateway.toolStarted(1, 'execute_code', '');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.controller.phase, VoicePhase.waitingPermission);
      expect(h.voice.localSpoken, hasLength(1));

      // La decisión sigue siendo explícita/táctil: la resuelve ActiveChat, no
      // una transcripción que contenga "sí" o "aprobar".
      await h.chat.resolveApproval('once');
      await _waitFor(() => h.chat.pendingApproval == null);
      expect(h.controller.phase, isNot(VoicePhase.waitingPermission));

      await h.gateway.complete(1, 'Acción completada.');
      await _waitFor(() => h.voice.captures.length == 2);
      await h.close();
    },
  );

  test(
    'Stop-and-talk conserva el run y encola en el mismo ActiveChat',
    () async {
      final h = await _harness();
      h.voice.captures.single.add(const SttResult('haz una tarea', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);

      h.controller.stopAndTalk();
      await _waitFor(() => h.voice.captures.length == 2);
      h.voice.captures.last.add(const SttResult('corrige el enfoque', true));
      await _waitFor(() => h.chat.queuedMessages.isNotEmpty);

      expect(h.chat.isStreaming, isTrue);
      expect(h.chat.queuedMessages, ['corrige el enfoque']);
      expect(h.gateway.runBodies, hasLength(1));
      await h.gateway.complete(1, 'Parcial conservado.');
      await _waitFor(() => h.gateway.runBodies.length == 2);
      expect(jsonEncode(h.gateway.runBodies), isNot(contains('mob-aux-')));

      h.chat.cancel();
      await h.close();
    },
  );

  test('Cancelar detiene backend; X solo libera voz y deja el run', () async {
    final cancelHarness = await _harness();
    cancelHarness.voice.captures.single.add(
      const SttResult('tarea cancelable', true),
    );
    await _waitFor(() => cancelHarness.gateway.runBodies.isNotEmpty);
    cancelHarness.controller.cancelBackend();
    await _waitFor(
      () => cancelHarness.gateway.hits.any((hit) => hit.endsWith('/stop')),
    );
    expect(cancelHarness.chat.isStreaming, isFalse);
    await cancelHarness.close();

    final exitHarness = await _harness();
    exitHarness.voice.captures.single.add(
      const SttResult('tarea que sigue', true),
    );
    await _waitFor(() => exitHarness.gateway.runBodies.isNotEmpty);
    exitHarness.voice.enableNativeVoice(
      speak: (text) async => {'ok': true},
      transcribe: (dataUrl, mimeType) async => {'ok': true},
    );
    expect(exitHarness.voice.nativeVoiceActive, isTrue);
    await exitHarness.controller.exit();

    expect(exitHarness.chat.isStreaming, isTrue);
    expect(
      exitHarness.gateway.hits.where((hit) => hit.endsWith('/stop')),
      isEmpty,
    );
    expect(exitHarness.voice.disposeSttCalls, 1);
    expect(exitHarness.voice.disposeTtsCalls, 1);
    expect(
      exitHarness.voice.nativeVoiceActive,
      isFalse,
      reason:
          'el modo servidor pertenece a la sesión de conversación, no al STT '
          'independiente ni a la lectura de burbujas',
    );
    await exitHarness.close();
  });

  test(
    'cambiar de chat espera el teardown completo antes de abrir otro micro',
    () async {
      final h = await _harness();
      final sttGate = Completer<void>();
      final ttsGate = Completer<void>();
      h.voice.disposeSttGate = sttGate;
      h.voice.disposeTtsGate = ttsGate;
      final secondChat = h.service.attach(
        connection: _connection(),
        sessionId: 'second-visible-session',
        sessionTitle: 'Segundo chat',
        api: ApiClient(
          baseUrl: 'http://hermes.test:8642',
          apiKey: 'test-key',
          httpClient: h.gateway,
        ),
      );

      final exiting = h.controller.exit();
      await Future<void>.delayed(Duration.zero);
      final entering = h.controller.enter(
        chat: secondChat,
        model: 'hermes-agent',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(h.controller.active, isFalse);
      expect(h.voice.captures, hasLength(1));

      sttGate.complete();
      ttsGate.complete();
      await exiting;
      await entering;

      expect(h.controller.ownsChat(secondChat), isTrue);
      expect(h.voice.captures, hasLength(2));
      await h.close();
    },
  );

  test(
    'salir corta el TTS antes del teardown y espera el corte solicitado',
    () async {
      final h = await _harness();
      h.voice.voiceExitCalls.clear();
      h.voice.holdStopSpeaking = true;

      final exiting = h.controller.exit();
      await Future<void>.delayed(Duration.zero);

      expect(h.controller.active, isFalse);
      expect(h.voice.stopSpeakingCalls, 1);
      expect(h.voice.voiceExitCalls.take(4), [
        'endSpeechLease',
        'stopSpeaking',
        'disposeStt',
        'disposeTts',
      ]);

      var completed = false;
      exiting.whenComplete(() => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      h.voice.releaseStopSpeaking();
      await exiting;
      expect(completed, isTrue);
      await h.close();
    },
  );

  test(
    'Servidor Hermes alimenta speak-stream sin esperar puntuación',
    () async {
      final h = await _harness();
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      var streamOpens = 0;
      _enableStreamingVoice(h.voice, socket, sink, onOpen: () => streamOpens++);

      h.voice.captures.single.add(const SttResult('respuesta inmediata', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);

      h.gateway.token(1, 'Respuesta ');
      await _waitFor(
        () => socket.sent.any((frame) => frame['text'] == 'Respuesta '),
      );
      h.gateway.token(1, 'fluida.');
      await _waitFor(
        () => socket.sent.where((frame) => frame['text'] != null).length == 2,
      );

      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      await socket.emit(Uint8List.fromList([1, 0]));
      await h.gateway.complete(1, 'Respuesta fluida.');
      await _waitFor(() => socket.sent.any((frame) => frame['done'] == true));
      await socket.emit(jsonEncode({'type': 'end'}));
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(
        socket.sent
            .where((frame) => frame['text'] != null)
            .map((frame) => frame['text']),
        ['Respuesta ', 'fluida.'],
      );
      expect(streamOpens, 1, reason: 'todo el turno comparte un speak-stream');
      await h.close();
    },
  );

  test(
    'Servidor Hermes coalesce deltas y vacía la cola antes de finish',
    () async {
      final h = await _harness();
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(const SttResult('respuesta eficiente', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Uno');
      await _waitFor(
        () => socket.sent.where((frame) => frame['text'] != null).length == 1,
      );

      h.gateway.token(1, ' dos');
      h.gateway.token(1, ' tres.');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(socket.sent.where((frame) => frame['text'] != null), hasLength(1));

      await h.gateway.complete(1, 'Uno dos tres.');
      await _waitFor(() => socket.sent.any((frame) => frame['done'] == true));
      expect(
        socket.sent
            .where((frame) => frame['text'] != null)
            .map((frame) => frame['text']),
        ['Uno', ' dos tres.'],
      );
      final doneIndex = socket.sent.indexWhere(
        (frame) => frame['done'] == true,
      );
      final tailIndex = socket.sent.lastIndexWhere(
        (frame) => frame['text'] != null,
      );
      expect(doneIndex, greaterThan(tailIndex));

      await h.close();
    },
  );

  test('Stop-and-talk cancela el feed pendiente de speak-stream', () async {
    final h = await _harness();
    final socket = _ControllerSpeechSocket();
    final sink = _ControllerPcmSink();
    _enableStreamingVoice(h.voice, socket, sink);

    h.voice.captures.single.add(const SttResult('respuesta cortable', true));
    await _waitFor(() => h.gateway.runBodies.length == 1);
    h.gateway.token(1, 'Primero');
    await _waitFor(
      () => socket.sent.where((frame) => frame['text'] != null).length == 1,
    );
    h.gateway.token(1, ' que ya no debe sonar.');

    h.controller.stopAndTalk();
    await _waitFor(() => socket.sent.any((frame) => frame['stop'] == true));
    await Future<void>.delayed(const Duration(milliseconds: 220));

    expect(
      socket.sent
          .where((frame) => frame['text'] != null)
          .map((frame) => frame['text']),
      ['Primero'],
    );
    h.chat.cancel();
    await h.close();
  });

  test(
    'Pause antes de PCM conserva el mismo speak-stream y el texto retenido',
    () async {
      final h = await _harness();
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      var opens = 0;
      h.voice.enableNativeVoice(
        speak: (text) async => <String, dynamic>{'ok': false},
        transcribe: (dataUrl, mimeType) async => <String, dynamic>{'text': ''},
        speechStream: () async {
          opens++;
          final session = HermesSpeechStreamSession(
            socket: socket,
            sink: sink,
            finishTimeout: const Duration(seconds: 2),
          );
          await session.open();
          return session;
        },
      );

      h.voice.captures.single.add(const SttResult('continúa después', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Texto retenido.');
      await _waitFor(
        () => socket.sent.any((frame) => frame['text'] == 'Texto retenido.'),
      );

      h.controller.pauseConversation();
      await _waitFor(() => h.controller.userPaused);
      expect(socket.sent.any((frame) => frame['stop'] == true), isFalse);
      h.controller.playConversation();
      await _waitFor(() => !h.controller.userPaused);

      expect(opens, 1);
      expect(
        socket.sent
            .where((frame) => frame['text'] != null)
            .map((frame) => frame['text']),
        ['Texto retenido.'],
      );
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      await socket.emit(Uint8List.fromList([1, 0]));
      await h.gateway.complete(1, 'Texto retenido.');
      await _waitFor(() => socket.sent.any((frame) => frame['done'] == true));
      await socket.emit(jsonEncode({'type': 'end'}));
      h.chat.cancel();
      await h.close();
    },
  );

  test(
    'Pause post-PCM reanuda el tail exacto en el mismo WS y AudioTrack',
    () async {
      final h = await _harness();
      final timeline = <String>[];
      final socket = _ControllerSpeechSocket(timeline: timeline);
      final sink = _ControllerPcmSink(timeline: timeline);
      var opens = 0;
      h.voice.enableNativeVoice(
        speak: (text) async => <String, dynamic>{'ok': false},
        transcribe: (dataUrl, mimeType) async => <String, dynamic>{'text': ''},
        speechStream: () async {
          opens++;
          final session = HermesSpeechStreamSession(
            socket: socket,
            sink: sink,
            finishTimeout: const Duration(seconds: 2),
          );
          await session.open();
          return session;
        },
      );

      h.voice.captures.single.add(const SttResult('respuesta con pausa', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Primera parte.');
      await _waitFor(
        () => socket.sent.any((frame) => frame['text'] == 'Primera parte.'),
      );
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      await socket.emit(Uint8List.fromList([1, 0]));
      await _waitFor(() => sink.writes.length == 1);

      final epochBeforePause = h.controller.debugEpoch;
      h.controller.pauseConversation();
      await _waitFor(
        () => sink.pauses == 1 && !h.controller.audioLeaseRequired,
      );
      expect(h.controller.debugEpoch, epochBeforePause);
      expect(h.voice.disposeSttCalls, 0);
      expect(h.voice.disposeTtsCalls, 0);
      socket.controller.add(Uint8List.fromList([2, 0]));
      h.gateway.token(1, ' Cola final.');
      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(sink.writes.map((bytes) => bytes.toList()), [
        [1, 0],
      ]);
      expect(socket.sent.where((frame) => frame['text'] != null), hasLength(1));

      h.controller.playConversation();
      await _waitFor(
        () =>
            sink.resumes == 1 &&
            sink.writes.length == 2 &&
            socket.sent.where((frame) => frame['text'] != null).length == 2,
      );
      expect(h.controller.audioLeaseRequired, isTrue);

      final retainedPcm = timeline.indexOf('pcm:2');
      final resumedText = timeline.indexOf('text: Cola final.');
      expect(retainedPcm, isNonNegative);
      expect(resumedText, greaterThan(retainedPcm));
      expect(opens, 1);
      expect(socket.sent.any((frame) => frame['stop'] == true), isFalse);

      await socket.emit(Uint8List.fromList([3, 0]));
      await h.gateway.complete(1, 'Primera parte. Cola final.');
      await _waitFor(() => socket.sent.any((frame) => frame['done'] == true));
      await socket.emit(jsonEncode({'type': 'end'}));

      expect(sink.writes.map((bytes) => bytes.toList()), [
        [1, 0],
        [2, 0],
        [3, 0],
      ]);
      expect(
        socket.sent
            .where((frame) => frame['text'] != null)
            .map((frame) => frame['text']),
        ['Primera parte.', ' Cola final.'],
      );
      await h.close();
    },
  );

  test(
    'App Lock conserva la lease hasta los ACK reales y la libera al terminar',
    () async {
      final h = await _harness();
      h.voice.disposeSttGate = Completer<void>();
      h.voice.disposeTtsGate = Completer<void>();

      final suspending = h.controller.suspendForPrivacy();
      await Future<void>.delayed(Duration.zero);

      expect(h.controller.active, isTrue);
      expect(h.controller.userPaused, isTrue);
      expect(h.controller.audioLeaseRequired, isTrue);

      h.voice.disposeSttGate!.complete();
      h.voice.disposeTtsGate!.complete();
      await suspending;

      expect(h.controller.active, isTrue);
      expect(h.controller.userPaused, isTrue);
      expect(h.controller.audioLeaseRequired, isFalse);
      await h.close();
    },
  );

  test(
    'App Lock endurece incluso Pause y unlock nunca reanuda por si solo',
    () async {
      final source = _ControllerFullDuplexSource();
      final monitor = FullDuplexBargeInMonitor(source: source);
      final h = await _harness(fullDuplexMonitor: monitor);
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(const SttResult('respuesta privada', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await _waitFor(() => monitor.armed);
      h.gateway.token(1, 'Audio privado.');
      await _waitFor(
        () => socket.sent.any((frame) => frame['text'] == 'Audio privado.'),
      );
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      await socket.emit(Uint8List.fromList([1, 0]));
      await _waitFor(() => sink.writes.length == 1);

      final staleCapture = h.voice.captures.single;
      h.controller.pauseConversation();
      await _waitFor(() => sink.pauses == 1);
      final epochAfterNormalPause = h.controller.debugEpoch;
      final capturesAfterNormalPause = h.voice.captures.length;

      await h.controller.suspendForPrivacy();

      expect(h.controller.userPaused, isTrue);
      expect(h.controller.debugEpoch, greaterThan(epochAfterNormalPause));
      expect(source.stops, greaterThanOrEqualTo(1));
      expect(monitor.active, isFalse);
      expect(socket.sent.any((frame) => frame['stop'] == true), isTrue);
      expect(sink.stopped, isTrue);
      expect(h.voice.stopSpeakingCalls, greaterThanOrEqualTo(1));
      expect(h.voice.disposeSttCalls, 1);
      expect(h.voice.disposeTtsCalls, 1);

      final startsAfterLock = source.starts;
      final textFramesAfterLock = socket.sent
          .where((frame) => frame['text'] != null)
          .length;
      staleCapture.add(const SttResult('callback privado', true));
      source.audio.add(_bargePcmFrame(2200));
      h.gateway.token(1, ' Delta privado.');
      await socket.emit(Uint8List.fromList([9, 0]));

      await h.controller.resumeFromSystemControl();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.controller.userPaused, isTrue);
      expect(sink.resumes, 0);
      expect(h.voice.captures, hasLength(capturesAfterNormalPause));

      h.controller.onAppResumed(appUnlocked: true);
      await h.controller.resumeFullDuplexCaptureIfNeeded();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.controller.userPaused, isTrue);
      expect(sink.resumes, 0);
      expect(h.voice.captures, hasLength(capturesAfterNormalPause));
      expect(source.starts, startsAfterLock);
      expect(monitor.active, isFalse);
      expect(sink.writes, hasLength(1));
      expect(
        socket.sent.where((frame) => frame['text'] != null),
        hasLength(textFramesAfterLock),
      );

      h.chat.cancel();
      await h.close();
    },
  );

  test(
    'cinco ciclos App Lock dejan listening thinking y speaking inertes',
    () async {
      const stages = <VoicePhase>[
        VoicePhase.listening,
        VoicePhase.thinking,
        VoicePhase.speaking,
        VoicePhase.listening,
        VoicePhase.thinking,
      ];

      for (var cycle = 0; cycle < stages.length; cycle++) {
        SharedPreferences.setMockInitialValues({'app_locale': 'es'});
        final expectedStage = stages[cycle];
        final source = _ControllerFullDuplexSource();
        final monitor = FullDuplexBargeInMonitor(source: source);
        final h = await _harness(fullDuplexMonitor: monitor);
        final socket = _ControllerSpeechSocket();
        final sink = _ControllerPcmSink();
        _enableStreamingVoice(h.voice, socket, sink);
        final staleCapture = h.voice.captures.single;

        if (expectedStage != VoicePhase.listening) {
          staleCapture.add(SttResult('turno privado $cycle', true));
          await _waitFor(() => h.gateway.runBodies.length == 1);
          await _waitFor(() => h.controller.phase == VoicePhase.thinking);
          await _waitFor(() => monitor.armed);
        }
        if (expectedStage == VoicePhase.speaking) {
          h.gateway.token(1, 'Respuesta privada.');
          await _waitFor(
            () => socket.sent.any(
              (frame) => frame['text'] == 'Respuesta privada.',
            ),
          );
          await socket.emit(
            jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
          );
          await socket.emit(Uint8List.fromList([cycle + 1, 0]));
          await _waitFor(() => h.controller.phase == VoicePhase.speaking);
        }
        expect(
          h.controller.phase,
          expectedStage,
          reason: 'fase previa del ciclo ${cycle + 1}',
        );

        final epochBeforeLock = h.controller.debugEpoch;
        final capturesBeforeLock = h.voice.captures.length;
        final startsBeforeLock = source.starts;
        final stopsBeforeLock = source.stops;
        final runsBeforeLock = h.gateway.runBodies.length;
        final spokenBeforeLock = h.voice.spoken.length;
        final localSpokenBeforeLock = h.voice.localSpoken.length;
        final stopSpeakingBeforeLock = h.voice.stopSpeakingCalls;
        final disposeSttBeforeLock = h.voice.disposeSttCalls;
        final disposeTtsBeforeLock = h.voice.disposeTtsCalls;
        final writesBeforeLock = sink.writes.length;
        final textFramesBeforeLock = socket.sent
            .where((frame) => frame['text'] != null)
            .length;

        await h.controller.suspendForPrivacy();

        expect(h.controller.userPaused, isTrue, reason: 'ciclo ${cycle + 1}');
        expect(
          h.controller.debugEpoch,
          greaterThan(epochBeforeLock),
          reason: 'ciclo ${cycle + 1}',
        );
        expect(monitor.active, isFalse, reason: 'ciclo ${cycle + 1}');
        expect(
          source.stops,
          greaterThan(stopsBeforeLock),
          reason: 'ciclo ${cycle + 1}',
        );
        expect(
          h.voice.stopSpeakingCalls,
          stopSpeakingBeforeLock + 1,
          reason: 'ciclo ${cycle + 1}',
        );
        expect(
          h.voice.disposeSttCalls,
          disposeSttBeforeLock + 1,
          reason: 'ciclo ${cycle + 1}',
        );
        expect(
          h.voice.disposeTtsCalls,
          disposeTtsBeforeLock + 1,
          reason: 'ciclo ${cycle + 1}',
        );
        if (expectedStage == VoicePhase.speaking) {
          expect(sink.stopped, isTrue, reason: 'ciclo ${cycle + 1}');
          expect(
            socket.sent.any((frame) => frame['stop'] == true),
            isTrue,
            reason: 'ciclo ${cycle + 1}',
          );
        }

        // Simula callbacks ya encolados de STT, AudioRecord/full-duplex,
        // backend y TTS. El desbloqueo real publica foreground y reevalúa el
        // monitor, pero no equivale a una acción visible Start/Play.
        staleCapture.add(SttResult('stale privado $cycle', true));
        source.audio.add(_bargePcmFrame(2400));
        if (runsBeforeLock > 0) {
          h.gateway.token(1, ' Callback privado.');
        }
        await socket.emit(Uint8List.fromList([90 + cycle, 0]));
        h.controller.onAppResumed(appUnlocked: true);
        await h.controller.resumeFullDuplexCaptureIfNeeded();
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(h.controller.userPaused, isTrue, reason: 'ciclo ${cycle + 1}');
        expect(h.voice.captures, hasLength(capturesBeforeLock));
        expect(source.starts, startsBeforeLock, reason: 'ciclo ${cycle + 1}');
        expect(monitor.active, isFalse, reason: 'ciclo ${cycle + 1}');
        expect(h.gateway.runBodies, hasLength(runsBeforeLock));
        expect(h.voice.spoken, hasLength(spokenBeforeLock));
        expect(h.voice.localSpoken, hasLength(localSpokenBeforeLock));
        expect(sink.writes, hasLength(writesBeforeLock));
        expect(
          socket.sent.where((frame) => frame['text'] != null),
          hasLength(textFramesBeforeLock),
          reason: 'ciclo ${cycle + 1}',
        );

        if (h.chat.isStreaming) h.chat.cancel();
        await h.close();
      }
    },
  );

  test('speak-stream acota deltas largos sin partir Unicode', () async {
    final h = await _harness();
    final socket = _ControllerSpeechSocket();
    final sink = _ControllerPcmSink();
    _enableStreamingVoice(h.voice, socket, sink);
    final text =
        '${List.filled(HermesSpeechStreamSession.maxTextDeltaChars - 1, 'a').join()}🙂final.';

    h.voice.captures.single.add(const SttResult('respuesta larga', true));
    await _waitFor(() => h.gateway.runBodies.length == 1);
    h.gateway.token(1, text);
    await _waitFor(
      () => socket.sent.where((frame) => frame['text'] != null).length == 2,
    );

    final deltas = socket.sent
        .where((frame) => frame['text'] != null)
        .map((frame) => frame['text']! as String)
        .toList();
    expect(deltas.every((delta) => delta.length <= 16 * 1024), isTrue);
    expect(deltas.join(), text);
    expect(deltas.first.endsWith('🙂'), isFalse);

    h.chat.cancel();
    await h.close();
  });

  test(
    'métricas separan lifecycle, texto, feed y PCM recibido/aceptado',
    () async {
      final records = <VoiceLatencyRecord>[];
      var nowMicros = 1000;
      final trace = VoiceLatencyTrace.testing(
        runId: '0123456789abcdef',
        nowMicros: () => ++nowMicros,
        onRecord: records.add,
      );
      late _Harness h;
      await trace.runScoped(() async {
        h = await _harness();
        final socket = _ControllerSpeechSocket();
        final sink = _ControllerPcmSink();
        _enableStreamingVoice(h.voice, socket, sink);

        h.voice.captures.single.add(const SttResult('mide este turno', true));
        await _waitFor(() => h.gateway.runBodies.length == 1);
        await _waitFor(
          () => records.any(
            (record) => record.point == VoiceLatencyPoint.backendLifecycleAck,
          ),
          diagnostics: () => records.map((record) => record.point).join(', '),
        );

        final points = records.map((record) => record.point).toList();
        final acceptedIndex = points.indexOf(VoiceLatencyPoint.submitAccepted);
        final lifecycleIndex = points.indexOf(
          VoiceLatencyPoint.backendLifecycleAck,
        );
        expect(acceptedIndex, isNonNegative);
        expect(lifecycleIndex, greaterThan(acceptedIndex));
        expect(
          points.where(
            (point) => point == VoiceLatencyPoint.backendLifecycleAck,
          ),
          hasLength(1),
        );
        expect(points, isNot(contains(VoiceLatencyPoint.backendTextAccepted)));

        h.gateway.toolStarted(1, 'search', 'sin contenido assistant');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          records.map((record) => record.point),
          isNot(contains(VoiceLatencyPoint.backendTextAccepted)),
        );

        h.gateway.token(1, 'Respuesta medible.');
        await _waitFor(
          () =>
              records.any(
                (record) =>
                    record.point == VoiceLatencyPoint.backendTextAccepted,
              ) &&
              records.any(
                (record) => record.point == VoiceLatencyPoint.ttsFirstFeed,
              ) &&
              socket.sent.any((frame) => frame['text'] != null),
          diagnostics: () => records.map((record) => record.point).join(', '),
        );
        expect(
          records.map((record) => record.point),
          isNot(contains(VoiceLatencyPoint.pcmFirstAccepted)),
        );
        expect(
          records.map((record) => record.point),
          isNot(contains(VoiceLatencyPoint.pcmFirstReceived)),
        );

        await socket.emit(
          jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
        );
        await socket.emit(Uint8List.fromList([1, 0, 2, 0]));
        await _waitFor(
          () => records.any(
            (record) => record.point == VoiceLatencyPoint.pcmFirstAccepted,
          ),
          diagnostics: () => records.map((record) => record.point).join(', '),
        );

        final orderedPoints = <VoiceLatencyPoint>[
          VoiceLatencyPoint.submitAccepted,
          VoiceLatencyPoint.backendLifecycleAck,
          VoiceLatencyPoint.backendTextAccepted,
          VoiceLatencyPoint.ttsFirstFeed,
          VoiceLatencyPoint.pcmFirstReceived,
          VoiceLatencyPoint.pcmFirstAccepted,
        ];
        final orderedIndexes = orderedPoints
            .map(
              (point) => records.indexWhere((record) => record.point == point),
            )
            .toList();
        expect(orderedIndexes, orderedEquals(orderedIndexes.toList()..sort()));
        for (final index in orderedIndexes) {
          expect(index, isNonNegative);
        }
        for (final point in orderedPoints) {
          expect(
            records.where((record) => record.point == point),
            hasLength(1),
          );
        }
        expect(
          records.map((record) => record.point),
          contains(VoiceLatencyPoint.pcmAudibleUnavailable),
        );

        h.gateway.token(1, ' Segundo tramo.');
        await socket.emit(Uint8List.fromList([3, 0]));
        await Future<void>.delayed(const Duration(milliseconds: 180));
        for (final point in orderedPoints) {
          expect(
            records.where((record) => record.point == point),
            hasLength(1),
          );
        }

        await h.gateway.complete(1, 'Respuesta medible. Segundo tramo.');
        await _waitFor(() => socket.sent.any((frame) => frame['done'] == true));
        await socket.emit(jsonEncode({'type': 'end'}));
        await _waitFor(
          () =>
              h.controller.phase == VoicePhase.listening &&
              records.any(
                (record) =>
                    record.turn == 1 &&
                    record.point == VoiceLatencyPoint.suffixAppendLatency,
              ) &&
              records.any(
                (record) =>
                    record.turn == 1 &&
                    record.point == VoiceLatencyPoint.pcmAcceptLatency,
              ),
          diagnostics: () => records
              .map((record) => '${record.turn}:${record.point.name}')
              .join(', '),
        );

        final firstTurn = records.where((record) => record.turn == 1).toList();
        expect(firstTurn, isNotEmpty);
        for (final record in firstTurn) {
          expect(record.arguments['stt_topology'], 'record_then_transcribe');
          expect(record.arguments['last_above'], 'measured');
        }
        final suffixSummary = firstTurn.singleWhere(
          (record) => record.point == VoiceLatencyPoint.suffixAppendLatency,
        );
        final pcmSummary = firstTurn.singleWhere(
          (record) => record.point == VoiceLatencyPoint.pcmAcceptLatency,
        );
        expect(suffixSummary.arguments['count'], greaterThanOrEqualTo(2));
        expect(suffixSummary.arguments['dropped'], 0);
        expect(pcmSummary.arguments['count'], 2);
        expect(pcmSummary.arguments['dropped'], 0);
      });
      addTearDown(h.close);
    },
  );

  test('feed TTS local no finge PCM aceptado ni audio audible', () async {
    final records = <VoiceLatencyRecord>[];
    var nowMicros = 1000;
    final trace = VoiceLatencyTrace.testing(
      runId: 'fedcba9876543210',
      nowMicros: () => ++nowMicros,
      onRecord: records.add,
    );
    late _Harness h;
    await trace.runScoped(() async {
      h = await _harness();
      h.voice.captures.single.add(const SttResult('respuesta local', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);

      h.gateway.token(1, 'Respuesta local.');
      await _waitFor(() => h.voice.spoken.singleOrNull == 'Respuesta local.');

      final points = records.map((record) => record.point).toList();
      final firstTextIndex = points.indexOf(
        VoiceLatencyPoint.backendTextAccepted,
      );
      final firstFeedIndex = points.indexOf(VoiceLatencyPoint.ttsFirstFeed);
      expect(firstTextIndex, isNonNegative);
      expect(firstFeedIndex, greaterThan(firstTextIndex));
      expect(points, isNot(contains(VoiceLatencyPoint.pcmFirstReceived)));
      expect(points, isNot(contains(VoiceLatencyPoint.pcmFirstAccepted)));
      expect(points, isNot(contains(VoiceLatencyPoint.pcmAudibleUnavailable)));

      await h.gateway.complete(1, 'Respuesta local.');
      await _waitFor(() => h.controller.phase == VoicePhase.listening);
    });
    addTearDown(h.close);
  });

  test('un feed TTS rechazado no se etiqueta como aceptado', () async {
    final records = <VoiceLatencyRecord>[];
    var nowMicros = 1000;
    final trace = VoiceLatencyTrace.testing(
      runId: '76543210fedcba98',
      nowMicros: () => ++nowMicros,
      onRecord: records.add,
    );
    late _Harness h;
    await trace.runScoped(() async {
      h = await _harness();
      h.voice.acceptSpeech = false;
      final socket = _ControllerSpeechSocket(rejectTextFrames: true);
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(
        const SttResult('prueba un feed rechazado', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Respuesta que ningún TTS aceptará.');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.voice.spoken, isEmpty);

      await h.gateway.complete(1, 'Respuesta que ningún TTS aceptará.');
      await _waitFor(
        () => h.voice.spoken.isNotEmpty,
        diagnostics: () => records.map((record) => record.point).join(', '),
      );
      expect(h.controller.debugNarrationCursor, 0);

      final points = records.map((record) => record.point).toList();
      expect(points, contains(VoiceLatencyPoint.backendTextAccepted));
      expect(points, contains(VoiceLatencyPoint.firstRawSpeechSuffix));
      expect(points, isNot(contains(VoiceLatencyPoint.ttsFirstFeed)));
      expect(points, isNot(contains(VoiceLatencyPoint.pcmFirstReceived)));
      expect(points, isNot(contains(VoiceLatencyPoint.pcmFirstAccepted)));

      h.voice.acceptSpeech = true;
      h.controller.pauseConversation();
      await _waitFor(
        () => h.controller.userPaused,
        diagnostics: () => 'pause phase=${h.controller.phase}',
      );
      h.controller.playConversation();
      await _waitFor(
        () => h.voice.spoken.length == 2,
        diagnostics: () =>
            'retry spoken=${h.voice.spoken} phase=${h.controller.phase} '
            'paused=${h.controller.userPaused} '
            'cursor=${h.controller.debugNarrationCursor}',
      );
      await _waitFor(
        () => h.controller.phase == VoicePhase.listening,
        diagnostics: () =>
            'rearm phase=${h.controller.phase} spoken=${h.voice.spoken} '
            'cursor=${h.controller.debugNarrationCursor}',
      );
      expect(h.voice.spoken, [
        'Respuesta que ningún TTS aceptará.',
        'Respuesta que ningún TTS aceptará.',
      ]);
    });
    addTearDown(h.close);
  });

  test('send=false no se etiqueta como submit aceptado', () async {
    final records = <VoiceLatencyRecord>[];
    var nowMicros = 1000;
    final trace = VoiceLatencyTrace.testing(
      runId: '0011223344556677',
      nowMicros: () => ++nowMicros,
      onRecord: records.add,
    );
    late _Harness h;
    await trace.runScoped(() async {
      h = await _harness(rejectRuns: true);
      h.voice.captures.single.add(const SttResult('fallo remoto', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await _waitFor(() => h.controller.phase == VoicePhase.listening);
    });
    addTearDown(h.close);

    final points = records.map((record) => record.point);
    expect(points, contains(VoiceLatencyPoint.submitStarted));
    expect(points, isNot(contains(VoiceLatencyPoint.submitAccepted)));
    expect(points, isNot(contains(VoiceLatencyPoint.backendLifecycleAck)));
  });

  test('un barge-in no hereda texto anterior al submit aceptado', () async {
    final records = <VoiceLatencyRecord>[];
    var nowMicros = 1000;
    final trace = VoiceLatencyTrace.testing(
      runId: '89abcdef01234567',
      nowMicros: () => ++nowMicros,
      onRecord: records.add,
    );
    late _Harness h;
    late _ControllerFullDuplexSource source;
    await trace.runScoped(() async {
      source = _ControllerFullDuplexSource()
        ..transcriptionGate = Completer<String>();
      final monitor = FullDuplexBargeInMonitor(source: source);
      h = await _harness(fullDuplexMonitor: monitor);

      h.voice.captures.single.add(
        const SttResult('Dame las noticias de hoy', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await _waitFor(() => monitor.armed);
      h.gateway.token(1, 'Respuesta antigua visible.');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await _emitBargeFrames(source, 80, 42);
      await _emitBargeFrames(source, 1800, 27);
      await _waitFor(() => h.controller.debugBargeCaptureInFlight);

      // Este delta pertenece todavía al turno interrumpido. Llega después de
      // abrir el trace de barge-in, pero antes de que su submit sea aceptado.
      h.gateway.token(1, ' Cola antigua anterior al submit.');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var bargePoints = records
          .where((record) => record.scenario == VoiceLatencyScenario.bargeIn)
          .map((record) => record.point)
          .toList();
      expect(
        bargePoints,
        isNot(contains(VoiceLatencyPoint.backendTextAccepted)),
      );
      expect(bargePoints, isNot(contains(VoiceLatencyPoint.ttsFirstFeed)));

      await _emitBargeFrames(source, 0, 60);
      source.transcriptionGate!.complete('Y también las de ayer');
      await _waitFor(() => h.gateway.runBodies.length == 2);
      await _waitFor(
        () => records.any(
          (record) =>
              record.scenario == VoiceLatencyScenario.bargeIn &&
              record.point == VoiceLatencyPoint.submitAccepted,
        ),
      );

      bargePoints = records
          .where((record) => record.scenario == VoiceLatencyScenario.bargeIn)
          .map((record) => record.point)
          .toList();
      expect(
        bargePoints,
        isNot(contains(VoiceLatencyPoint.backendTextAccepted)),
      );
      expect(bargePoints, isNot(contains(VoiceLatencyPoint.ttsFirstFeed)));

      h.gateway.token(2, 'Respuesta nueva medible.');
      await _waitFor(
        () => records.any(
          (record) =>
              record.scenario == VoiceLatencyScenario.bargeIn &&
              record.point == VoiceLatencyPoint.backendTextAccepted,
        ),
      );
      final finalBargePoints = records
          .where((record) => record.scenario == VoiceLatencyScenario.bargeIn)
          .map((record) => record.point)
          .toList();
      expect(
        finalBargePoints.indexOf(VoiceLatencyPoint.backendTextAccepted),
        greaterThan(finalBargePoints.indexOf(VoiceLatencyPoint.submitAccepted)),
      );
      expect(
        finalBargePoints.where(
          (point) => point == VoiceLatencyPoint.backendTextAccepted,
        ),
        hasLength(1),
      );
      h.chat.cancel();
    });
    addTearDown(h.close);
  });

  test('streaming PCM completa el turno sin invocar el TTS legado', () async {
    final h = await _harness();
    final socket = _ControllerSpeechSocket();
    final sink = _ControllerPcmSink();
    _enableStreamingVoice(h.voice, socket, sink);

    h.voice.captures.single.add(
      const SttResult('respuesta en streaming', true),
    );
    await _waitFor(() => h.gateway.runBodies.length == 1);
    h.gateway.token(1, 'Respuesta fluida.');
    await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));

    await socket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );
    await socket.emit(Uint8List.fromList([1, 0, 2, 0]));
    await _waitFor(() => sink.writes.length == 1);

    await h.gateway.complete(1, 'Respuesta fluida.');
    await _waitFor(() => socket.sent.any((frame) => frame['done'] == true));
    await socket.emit(jsonEncode({'type': 'end'}));
    await _waitFor(() => h.controller.phase == VoicePhase.listening);

    expect(
      socket.sent
          .where((frame) => frame['text'] != null)
          .map((frame) => frame['text']),
      ['Respuesta fluida.'],
    );
    expect(sink.writes.single, Uint8List.fromList([1, 0, 2, 0]));
    expect(h.voice.spoken, isEmpty);
    await h.close();
  });

  test(
    'fallback antes de PCM espera terminal y hace un solo POST ordenado',
    () async {
      final h = await _harness();
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);
      h.voice.holdSpeech = true;

      h.voice.captures.single.add(const SttResult('usa el fallback', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Primera frase.');
      await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));

      await socket.emit(jsonEncode({'type': 'fallback'}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.chat.isStreaming, isTrue);
      expect(h.voice.spoken, isEmpty);

      h.gateway.token(1, ' Segunda frase.');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.voice.spoken, isEmpty);

      h.gateway.token(1, ' Cola sin cerrar');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.voice.spoken, isEmpty);

      await h.gateway.complete(
        1,
        'Primera frase. Segunda frase. Cola sin cerrar',
      );
      await _waitFor(() => h.voice.spoken.length == 1);
      h.voice.finishSpeech();
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(sink.writes, isEmpty);
      expect(h.voice.spoken, [
        'Primera frase. Segunda frase. Cola sin cerrar.',
      ]);
      await h.close();
    },
  );

  test(
    'fallback sin PCM respeta el final autoritativo sin repetir el cuerpo',
    () async {
      final h = await _harness();
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);
      h.voice.holdSpeech = true;
      const accepted =
          'Aquí van las noticias verificadas con todos los datos necesarios.';

      h.voice.captures.single.add(
        const SttResult('corrige el final sin repetir', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, accepted);
      await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));
      await socket.emit(jsonEncode({'type': 'fallback'}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.voice.spoken, isEmpty);

      await h.gateway.complete(1, '¡Listo! $accepted Ceuta sigue abierta.');
      await _waitFor(
        () => h.controller.assistantResponse.contains('Ceuta sigue abierta.'),
      );
      await _waitFor(() => h.voice.spoken.length == 1);
      h.voice.finishSpeech();
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(sink.writes, isEmpty);
      expect(h.voice.spoken, ['¡Listo! $accepted Ceuta sigue abierta.']);
      await h.close();
    },
  );

  test(
    'Stop-and-talk durante fallback POST espera el ACK antes de rearmar',
    () async {
      final h = await _harness();
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);
      h.voice.holdSpeech = true;
      h.voice.holdStopSpeaking = true;

      h.voice.captures.single.add(
        const SttResult('interrumpe el fallback', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Primera frase. Esta cola forma un único fallback.');
      await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));
      await socket.emit(jsonEncode({'type': 'fallback'}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.voice.spoken, isEmpty);

      await h.gateway.complete(
        1,
        'Primera frase. Esta cola forma un único fallback.',
      );
      await _waitFor(() => h.voice.spoken.length == 1);

      h.controller.stopAndTalk();
      await _waitFor(() => h.voice.stopSpeakingCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.voice.captures, hasLength(1));

      h.voice.releaseStopSpeaking();
      await _waitFor(() => h.voice.captures.length == 2);
      expect(h.voice.spoken, [
        'Primera frase. Esta cola forma un único fallback.',
      ]);
      await h.close();
    },
  );

  test(
    'terminal duplicado espera drain PCM y cola acústica antes de escuchar',
    () async {
      final source = _ControllerFullDuplexSource();
      final monitor = FullDuplexBargeInMonitor(source: source);
      final tailGate = Completer<void>();
      Duration? requestedDelay;
      final h = await _harness(
        fullDuplexMonitor: monitor,
        playbackTailDelay: (delay) {
          requestedDelay = delay;
          return tailGate.future;
        },
      );
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink()..finishGate = Completer<void>();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(
        const SttResult('respuesta con drain protegido', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Audio que debe terminar completo.');
      await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      await socket.emit(Uint8List.fromList([1, 0, 2, 0]));
      await _waitFor(() => sink.writes.length == 1);
      await _waitFor(() => h.controller.phase == VoicePhase.speaking);

      await h.gateway.complete(1, 'Audio que debe terminar completo.');
      await _waitFor(() => socket.sent.any((frame) => frame['done'] == true));
      await socket.emit(jsonEncode({'type': 'end'}));
      await _waitFor(() => sink.finishes == 1);

      // ActiveChat proyecta otro terminal al pasar completed -> idle. Mientras
      // sink.finish siga bloqueado, ese callback no puede desarmar full-duplex
      // ni abrir el recorder normal encima del AudioTrack todavía activo.
      await Future<void>.delayed(const Duration(milliseconds: 950));
      expect(h.controller.phase, VoicePhase.speaking);
      expect(h.voice.captures, hasLength(1));
      expect(source.playbackActive, isTrue);
      expect(monitor.active, isTrue);

      sink.finishGate!.complete();
      await _waitFor(() => requestedDelay != null);
      expect(requestedDelay, const Duration(milliseconds: 500));
      expect(h.voice.captures, hasLength(1));

      // El backstop terminal puede llegar mientras la cola física ya drenó
      // pero el altavoz aún no es seguro para el recorder normal.
      await Future<void>.delayed(const Duration(milliseconds: 950));
      expect(h.voice.captures, hasLength(1));

      tailGate.complete();
      await _waitFor(() => h.controller.phase == VoicePhase.listening);
      expect(h.voice.captures, hasLength(2));
      expect(source.playbackActive, isFalse);

      await h.close();
    },
  );

  test(
    'Server no rearma por completed-idle durante la cola post-drain',
    () async {
      final source = _ControllerFullDuplexSource();
      final monitor = FullDuplexBargeInMonitor(source: source);
      final tailGate = Completer<void>();
      Duration? requestedDelay;
      final h = await _harness(
        fullDuplexMonitor: monitor,
        playbackTailDelay: (delay) {
          requestedDelay = delay;
          return tailGate.future;
        },
      );
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(const SttResult('prueba server', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Audio server con cola física.');
      await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      await socket.emit(Uint8List.fromList([1, 0, 2, 0]));
      await h.gateway.complete(1, 'Audio server con cola física.');
      await _waitFor(() => socket.sent.any((frame) => frame['done'] == true));
      await socket.emit(jsonEncode({'type': 'end'}));
      await _waitFor(() => requestedDelay != null);

      // El segundo done de ActiveChat llega a los 800 ms, ya después del drain.
      // Debe seguir bloqueado por la valla acústica, no abrir AudioRecord.
      await Future<void>.delayed(const Duration(milliseconds: 950));
      expect(h.voice.captures, hasLength(1));

      tailGate.complete();
      await _waitFor(() => h.voice.captures.length == 2);
      await h.close();
    },
  );

  test(
    'el eco del altavoz con AEC nominal no corta ni crea otro turno',
    () async {
      final source = _ControllerFullDuplexSource()
        ..safety = const FullDuplexPlaybackSafety(
          aecEnabled: true,
          privateOutput: false,
          playbackSafe: false,
        );
      final monitor = FullDuplexBargeInMonitor(source: source);
      final h = await _harness(fullDuplexMonitor: monitor);
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(
        const SttResult('respuesta inmune a su propio eco', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await _waitFor(() => monitor.armed);
      h.gateway.token(1, 'Hermes debe terminar esta respuesta.');
      await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      await socket.emit(Uint8List.fromList([1, 0, 2, 0]));
      await _waitFor(() => sink.writes.length == 1);
      await _waitFor(() => !monitor.active);

      // Reproduce los dos picos físicos que antes cruzaban el VAD. La captura
      // ya está cerrada, por lo que ni se transcriben ni cortan el AudioTrack.
      await _emitBargeFrames(source, 7381, 10);
      await _emitBargeFrames(source, 3064, 10);
      expect(h.gateway.runBodies, hasLength(1));
      expect(sink.stopped, isFalse);
      expect(h.controller.debugBargeCaptureInFlight, isFalse);

      await h.gateway.complete(1, 'Hermes debe terminar esta respuesta.');
      await _waitFor(() => socket.sent.any((frame) => frame['done'] == true));
      await socket.emit(jsonEncode({'type': 'end'}));
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(h.gateway.runBodies, hasLength(1));
      expect(source.playbackActive, isFalse);
      expect(h.voice.captures, hasLength(2));

      await h.close();
    },
  );

  test(
    'fallback providerUnsupported pre-PCM espera terminal y hace un solo POST',
    () async {
      final h = await _harness();
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink, fallbackBeforeReturn: true);

      h.voice.captures.single.add(
        const SttResult('usa el fallback inmediato', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Primera inmediata.');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.voice.spoken, isEmpty);
      expect(h.chat.isStreaming, isTrue);
      h.gateway.token(1, ' Segunda inmediata.');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.voice.spoken, isEmpty);
      await h.gateway.complete(1, 'Primera inmediata. Segunda inmediata.');
      await _waitFor(() => h.voice.spoken.length == 1);
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(sink.writes, isEmpty);
      expect(socket.sent.where((frame) => frame['text'] != null), isEmpty);
      expect(h.voice.spoken, ['Primera inmediata. Segunda inmediata.']);
      await h.close();
    },
  );

  test(
    'endpoint speak-stream ausente espera terminal y hace un solo POST',
    () async {
      final h = await _harness();
      var streamAttempts = 0;
      h.voice.enableNativeVoice(
        speak: (text) async => <String, dynamic>{'ok': false},
        transcribe: (dataUrl, mimeType) async => <String, dynamic>{'text': ''},
        speechStream: () async {
          streamAttempts++;
          throw HermesSpeechStreamOpenException(
            StateError('HTTP status code: 404'),
          );
        },
      );

      h.voice.captures.single.add(
        const SttResult('usa el fallback compatible', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Primera parte.');
      h.gateway.token(1, ' Segunda parte.');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(h.chat.isStreaming, isTrue);
      expect(h.voice.spoken, isEmpty);

      await h.gateway.complete(1, 'Primera parte. Segunda parte.');
      await _waitFor(() => h.voice.spoken.length == 1);
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(streamAttempts, 1);
      expect(h.voice.spoken, ['Primera parte. Segunda parte.']);
      await h.close();
    },
  );

  test(
    'fallo tras el primer PCM nunca repite por el pipeline legado',
    () async {
      final h = await _harness();
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(const SttResult('respuesta parcial', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      h.gateway.token(1, 'Audio ya audible. Cola remota pendiente.');
      await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));

      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      await socket.emit(Uint8List.fromList([7, 0]));
      await socket.fail();
      await _waitFor(() => sink.stopped);

      await h.gateway.complete(1, 'Audio ya audible. Cola remota pendiente.');
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(sink.writes, hasLength(1));
      expect(h.voice.spoken, isEmpty);
      await h.close();
    },
  );

  test(
    'el envío de voz no espera a que termine de abrirse el monitor barge-in',
    () async {
      final source = _ControllerFullDuplexSource()
        ..startGate = Completer<void>();
      final monitor = FullDuplexBargeInMonitor(source: source);
      final h = await _harness(fullDuplexMonitor: monitor);
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(const SttResult('envía ya', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);

      expect(source.starts, 1);
      expect(source.startGate!.isCompleted, isFalse);
      expect(h.gateway.runBodies.single['input'], 'envía ya');

      source.startGate!.complete();
      await _waitFor(() => monitor.armed);
      expect(
        h.controller.spokenInterruptionArmed,
        isTrue,
        reason: 'la UI solo puede prometer barge-in tras el arm real',
      );
      h.chat.cancel();
      await h.close();
    },
  );

  test('barge-in apagado no arma el micrófono full-duplex', () async {
    final source = _ControllerFullDuplexSource();
    final monitor = FullDuplexBargeInMonitor(source: source);
    final h = await _harness(fullDuplexMonitor: monitor, bargeInEnabled: false);
    final socket = _ControllerSpeechSocket();
    final sink = _ControllerPcmSink();
    _enableStreamingVoice(h.voice, socket, sink);

    h.voice.captures.single.add(const SttResult('sin interrupciones', true));
    await _waitFor(() => h.gateway.runBodies.length == 1);
    h.gateway.token(1, 'La respuesta continúa sin abrir otro micrófono.');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(source.starts, 0);
    expect(monitor.armed, isFalse);
    expect(h.controller.spokenInterruptionArmed, isFalse);
    h.chat.cancel();
    await h.close();
  });

  test('apagar barge-in durante un turno desarma inmediatamente', () async {
    final source = _ControllerFullDuplexSource();
    final monitor = FullDuplexBargeInMonitor(source: source);
    final h = await _harness(fullDuplexMonitor: monitor);
    final socket = _ControllerSpeechSocket();
    final sink = _ControllerPcmSink();
    _enableStreamingVoice(h.voice, socket, sink);

    h.voice.captures.single.add(const SttResult('turno interrumpible', true));
    await _waitFor(() => h.gateway.runBodies.length == 1);
    await _waitFor(() => monitor.armed);

    await h.voice.saveSettings(
      h.voice.settings.copyWith(bargeInEnabled: false),
    );
    await _waitFor(() => !monitor.active);

    expect(source.stops, greaterThanOrEqualTo(1));
    h.chat.cancel();
    await h.close();
  });

  test(
    'barge-in no bloquea el event loop mientras drena el playback anterior',
    () async {
      final source = _ControllerFullDuplexSource()
        ..transcript = 'Y ahora dime el tiempo';
      final monitor = FullDuplexBargeInMonitor(source: source);
      final h = await _harness(fullDuplexMonitor: monitor);
      h.voice.holdSpeech = true;
      h.voice.holdStopSpeaking = true;
      h.voice.releaseSpeechBeforeStopCompletes = true;

      h.voice.captures.single.add(
        const SttResult('Dime las noticias de hoy', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await _waitFor(() => monitor.armed);
      h.gateway.token(1, 'Estas son las noticias de hoy.');
      await _waitFor(() => h.voice.spoken.length == 1);
      await _waitFor(() => source.playbackActive);

      await _emitBargeFrames(source, 80, 42);
      await _emitBargeFrames(source, 1800, 27);
      await _waitFor(() => h.controller.debugBargeCaptureInFlight);
      await _waitFor(() => h.voice.stopSpeakingCalls == 1);
      await _emitBargeFrames(source, 0, 60);
      await _waitFor(() => h.gateway.runBodies.length == 2);

      h.gateway.token(2, 'Ahora mismo hay veintidós grados.');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(
        h.voice.spoken,
        ['Estas son las noticias de hoy.'],
        reason: 'el siguiente TTS debe esperar al ACK del drain anterior',
      );

      h.voice.releaseStopSpeaking();
      await _waitFor(() => h.voice.spoken.length == 2);
      expect(h.voice.spoken.last, 'Ahora mismo hay veintidós grados.');

      h.voice.finishSpeech();
      h.chat.cancel();
      await h.close();
    },
  );

  test(
    'hoy → y ayer corta el turno antes de una STT lenta y conserva el contexto',
    () async {
      final source = _ControllerFullDuplexSource()
        ..transcript = 'Y también las de ayer'
        ..transcriptionGate = Completer<String>();
      final monitor = FullDuplexBargeInMonitor(source: source);
      final h = await _harness(fullDuplexMonitor: monitor);
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(
        const SttResult('Dame las noticias de hoy', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await _waitFor(() => monitor.armed);

      await _emitBargeFrames(source, 80, 42);
      await monitor.setPlaybackActive(true);
      await _emitBargeFrames(source, 1800, 27);
      await _waitFor(() => h.controller.debugBargeCaptureInFlight);
      expect(
        h.controller.phase,
        isNot(VoicePhase.transcribing),
        reason: 'speech_start todavía está capturando la frase del usuario',
      );
      await _emitBargeFrames(source, 0, 60);
      await _waitFor(() => h.controller.phase == VoicePhase.transcribing);
      await _waitFor(() => h.gateway.hits.any((hit) => hit.endsWith('/stop')));

      // La respuesta antigua puede terminar mientras Whisper sigue
      // transcribiendo; sus callbacks ya están invalidados por el barge-in.
      await h.gateway.complete(1, 'Noticias de hoy que el usuario no oyó.');
      source.transcriptionGate!.complete('Y también las de ayer');
      await _waitFor(() => h.gateway.runBodies.length == 2);

      expect(h.chat.queuedMessages, isEmpty);
      expect(h.gateway.runBodies[1]['input'], 'Y también las de ayer');
      expect(
        jsonEncode(h.gateway.runBodies[1]['conversation_history']),
        contains('Dame las noticias de hoy'),
      );
      expect(
        h.gateway.hits.where((hit) => hit.endsWith('/stop')),
        hasLength(1),
      );

      h.chat.cancel();
      await h.close();
    },
  );

  test(
    'Never mind durante TTS corta el turno y cierra voz sin reenviar',
    () async {
      final source = _ControllerFullDuplexSource()..transcript = 'Never mind.';
      final monitor = FullDuplexBargeInMonitor(source: source);
      final h = await _harness(fullDuplexMonitor: monitor);
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(const SttResult('cuéntame algo', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await _waitFor(() => monitor.armed);

      await _emitBargeFrames(source, 80, 42);
      await monitor.setPlaybackActive(true);
      await _emitBargeFrames(source, 1800, 27);
      await _waitFor(() => h.controller.debugBargeCaptureInFlight);
      await _emitBargeFrames(source, 0, 60);
      await _waitFor(() => !h.controller.active);

      expect(h.chat.isStreaming, isFalse);
      expect(h.chat.queuedMessages, isEmpty);
      expect(h.gateway.runBodies, hasLength(1));
      expect(
        h.gateway.hits.where((hit) => hit.endsWith('/stop')),
        hasLength(1),
      );

      await h.close();
    },
  );

  test(
    'Cállate durante playback terminal cierra voz sin interrumpir servidor',
    () async {
      final source = _ControllerFullDuplexSource()..transcript = 'Cállate.';
      final monitor = FullDuplexBargeInMonitor(source: source);
      final h = await _harness(fullDuplexMonitor: monitor);
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(
        const SttResult('Dame una respuesta breve', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await _waitFor(() => monitor.armed);
      h.gateway.token(1, 'Respuesta ya generada.');
      await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      await socket.emit(Uint8List.fromList([1, 0, 2, 0]));
      await _waitFor(() => source.playbackActive);
      await h.gateway.complete(1, 'Respuesta ya generada.');
      await _waitFor(() => !h.chat.isStreaming);

      await _emitBargeFrames(source, 1800, 27);
      await _waitFor(() => h.controller.debugBargeCaptureInFlight);
      await _emitBargeFrames(source, 0, 60);
      await _waitFor(() => !h.controller.active);

      expect(h.gateway.runBodies, hasLength(1));
      expect(h.gateway.hits.where((hit) => hit.endsWith('/stop')), isEmpty);
      await h.close();
    },
  );

  test(
    'App Lock bloquea rearmes tardíos y foreground explícito recupera barge-in',
    () async {
      final source = _ControllerFullDuplexSource();
      final monitor = FullDuplexBargeInMonitor(source: source);
      final h = await _harness(fullDuplexMonitor: monitor);
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(const SttResult('turno privado', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      expect(source.starts, 1);

      await h.controller.suspendFullDuplexCapture();
      final startsWhilePrivate = source.starts;
      expect(source.stops, greaterThanOrEqualTo(1));

      h.gateway.token(1, 'El chat sigue generando.');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(source.starts, startsWhilePrivate);

      await h.controller.resumeFullDuplexCaptureIfNeeded();
      await _waitFor(() => source.starts == startsWhilePrivate + 1);

      // El timeout de App Lock puede decidir bloquear justo después de que
      // lifecycle publique resumed. La última orden de privacidad debe ganar.
      await h.controller.suspendFullDuplexCapture();
      final resume = h.controller.resumeFullDuplexCaptureIfNeeded();
      final lock = h.controller.suspendFullDuplexCapture();
      await Future.wait<void>([resume, lock]);
      expect(monitor.active, isFalse);

      h.chat.cancel();
      await h.close();
    },
  );

  test('sin opt-in segundo plano desarma la conversación manual', () async {
    final source = _ControllerFullDuplexSource();
    final monitor = FullDuplexBargeInMonitor(source: source);
    final h = await _harness(fullDuplexMonitor: monitor);
    _enableStreamingVoice(
      h.voice,
      _ControllerSpeechSocket(),
      _ControllerPcmSink(),
    );

    h.voice.captures.single.add(const SttResult('turno manual', true));
    await _waitFor(() => h.gateway.runBodies.length == 1);
    await _waitFor(() => monitor.armed);

    await h.controller.suspendFullDuplexForAppBackground();
    final startsWhileBackground = source.starts;
    expect(source.stops, greaterThanOrEqualTo(1));
    expect(monitor.active, isFalse);

    h.gateway.token(1, 'El chat sigue generando.');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(source.starts, startsWhileBackground);

    h.chat.cancel();
    await h.close();
  });

  test(
    'continuidad manual conserva barge-in con la pantalla bloqueada',
    () async {
      final source = _ControllerFullDuplexSource();
      final monitor = FullDuplexBargeInMonitor(source: source);
      final h = await _harness(
        fullDuplexMonitor: monitor,
        continueWhenLocked: true,
      );
      _enableStreamingVoice(
        h.voice,
        _ControllerSpeechSocket(),
        _ControllerPcmSink(),
      );

      h.voice.captures.single.add(const SttResult('turno manual', true));
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await _waitFor(() => monitor.armed);
      final stopsBeforeBackground = source.stops;

      await h.controller.suspendFullDuplexForAppBackground();

      expect(monitor.armed, isTrue);
      expect(monitor.active, isTrue);
      expect(source.stops, stopsBeforeBackground);

      h.gateway.token(1, 'La conversación continúa fuera de la app.');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(monitor.armed, isTrue);

      h.chat.cancel();
      await h.close();
    },
  );

  test('ruido bajo el umbral Desktop no interrumpe mientras piensa', () async {
    final source = _ControllerFullDuplexSource();
    final monitor = FullDuplexBargeInMonitor(source: source);
    final h = await _harness(fullDuplexMonitor: monitor);
    final socket = _ControllerSpeechSocket();
    final sink = _ControllerPcmSink();
    _enableStreamingVoice(h.voice, socket, sink);

    h.voice.captures.single.add(const SttResult('trabajo importante', true));
    await _waitFor(() => h.gateway.runBodies.length == 1);
    expect(h.chat.isStreaming, isTrue);

    await _emitBargeFrames(source, 497, 42);
    // El NoiseSuppressor nativo entrega aquí el residuo ya procesado. Con
    // suelo 497, Desktop exige 1739,5 RMS durante generación.
    await _emitBargeFrames(source, 1700, 12);
    expect(h.controller.debugBargeCaptureInFlight, isFalse);
    expect(h.chat.isStreaming, isTrue);
    expect(h.chat.queuedMessages, isEmpty);

    h.chat.cancel();
    await h.close();
  });

  test(
    'hablar mientras piensa interrumpe el run y abre el siguiente turno',
    () async {
      final source = _ControllerFullDuplexSource()
        ..transcript = 'Y también las de ayer';
      final monitor = FullDuplexBargeInMonitor(source: source);
      final h = await _harness(fullDuplexMonitor: monitor);

      h.voice.captures.single.add(
        const SttResult('Dame las noticias de hoy', true),
      );
      await _waitFor(() => h.gateway.runBodies.length == 1);
      await _waitFor(() => monitor.armed);

      await _emitBargeFrames(source, 80, 42);
      await _emitBargeFrames(source, 2600, 10);
      await _waitFor(() => h.controller.debugBargeCaptureInFlight);
      await _waitFor(() => h.gateway.hits.any((hit) => hit.endsWith('/stop')));
      expect(h.chat.isStreaming, isFalse);

      // Desktop corta el turno en speech_start, sigue capturando y envía la
      // frase como turno normal cuando llega el endpoint de ~1,25 s.
      await _emitBargeFrames(source, 0, 42);
      await _waitFor(() => h.gateway.runBodies.length == 2);

      expect(h.chat.queuedMessages, isEmpty);
      expect(h.gateway.runBodies[1]['input'], 'Y también las de ayer');
      expect(
        jsonEncode(h.gateway.runBodies[1]['conversation_history']),
        contains('Dame las noticias de hoy'),
      );
      expect(
        h.gateway.hits.where((hit) => hit.endsWith('/stop')),
        hasLength(1),
      );

      h.chat.cancel();
      await h.close();
    },
  );

  test('el primer delta PCM espera la valla de salida privada', () async {
    final source = _ControllerFullDuplexSource();
    final monitor = FullDuplexBargeInMonitor(source: source);
    final h = await _harness(fullDuplexMonitor: monitor);
    final socket = _ControllerSpeechSocket();
    final sink = _ControllerPcmSink();
    _enableStreamingVoice(h.voice, socket, sink);

    h.voice.captures.single.add(const SttResult('respuesta protegida', true));
    await _waitFor(() => h.gateway.runBodies.length == 1);
    expect(monitor.armed, isTrue);

    source.playbackGate = Completer<void>();
    h.gateway.token(1, 'Audio protegido.');
    await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));

    await socket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );
    unawaited(socket.emit(Uint8List.fromList([1, 0, 2, 0])));
    await _waitFor(() => source.playbackActive);
    expect(sink.writes, isEmpty);
    source.playbackGate!.complete();
    await _waitFor(() => sink.writes.length == 1);

    h.chat.cancel();
    await h.close();
  });
}
