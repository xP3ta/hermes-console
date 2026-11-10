import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/prompt_client_surface.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/voice/conversation/full_duplex_barge_in_monitor.dart';
import 'package:hermes_android/core/services/voice/conversation/local_voice_conversation_controller.dart';
import 'package:hermes_android/core/services/voice/conversation/voice_turn_latency_log.dart';
import 'package:hermes_android/core/services/voice/hermes_pcm_stream.dart';
import 'package:hermes_android/core/services/voice/hermes_speech_stream.dart';
import 'package:hermes_android/core/services/voice/live/live_audio_environment.dart';
import 'package:hermes_android/core/services/voice/session/voice_care.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/voice_client_direct.dart';
import 'package:hermes_android/core/services/voice/voice_language.dart';
import 'package:hermes_android/core/services/voice/voice_latency_trace.dart';
import 'package:hermes_android/core/services/voice/voice_phase.dart';
import 'package:hermes_android/core/services/voice/voice_server_prefs.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:hermes_android/core/services/voice/voice_stop_phrases.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/desktop_chat_socket.dart';
import '../../support/in_memory_compression_restore_storage.dart';
import '../../support/test_api_client.dart';

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
  bool languageFellBack = false;

  @override
  bool get sttLanguageFellBack => languageFellBack;

  int stopDictationCalls = 0;
  int cancelDictationCalls = 0;
  int stopSpeakingCalls = 0;
  int disposeSttCalls = 0;

  /// What each release of the recogniser asked for: kept loaded or not.
  final List<bool> keepRecognizerWarmRequests = <bool>[];
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
  Object? stopSpeakingError;
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
    final stopError = stopSpeakingError;
    if (stopError != null) throw stopError;
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
  Future<void> disposeSttForVoiceExit({bool keepRecognizerWarm = false}) async {
    keepRecognizerWarmRequests.add(keepRecognizerWarm);
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

/// The chat of the voice controller goes through the Dashboard socket only, as
/// Hermes Desktop does. [counter] answers the stored transcript read and fails the
/// test at tear down if anything asks for the REST run API.
class _FakeGateway {
  _FakeGateway() {
    counter = HostCounter(
      handler: (request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
          return http.Response(
            jsonEncode({
              'data': [
                if (finalText.isNotEmpty)
                  {'role': 'assistant', 'content': finalText},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      },
    );
    addTearDown(socket.close);
  }

  final DesktopChatSocket socket = DesktopChatSocket();
  late final HostCounter counter;
  String finalText = '';

  /// Texts handed to `prompt.submit`, one per turn.
  List<String> get submitTexts => socket.submitTexts;

  /// Number of `session.interrupt` frames.
  int get interrupts => socket.interrupts;

  void token(int turn, String text) => socket.token(turn, text);

  void toolStarted(int turn, String tool, String preview) =>
      socket.toolStarted(turn, tool, context: preview);

  void interim(int turn, String text, {bool alreadyStreamed = false}) =>
      socket.interim(turn, text, alreadyStreamed: alreadyStreamed);

  void toolCompleted(int turn, String tool) => socket.toolCompleted(turn, tool);

  void approval(int turn, {String command = 'rm archivo', String? requestId}) =>
      socket.approval(
        turn,
        requestId: requestId ?? 'approval-$turn',
        command: command,
      );

  Future<void> complete(int turn, String text) async {
    finalText = text;
    socket.complete(turn, text);
  }
}

SavedConnection _connection() => SavedConnection(
  id: 'voice-local-controller',
  label: 'Test',
  host: 'hermes.test',
  port: 8642,
  apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
);

SavedConnection _localOnDeviceConnection() => SavedConnection(
  id: 'voice-local-on-device-controller',
  label: 'Local test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: String.fromCharCodes(const [108, 111, 99, 97, 108]),
  onDeviceLoopback: true,
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

class _FailingVoiceDesktopGateway implements HermesDesktopGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => false;

  @override
  Future<void> connect() async => throw StateError('desktop unavailable');

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => throw StateError('desktop unavailable');

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async =>
      throw StateError('desktop unavailable');

  @override
  Future<void> steer(String runtimeSessionId, String text) async =>
      throw StateError('desktop unavailable');

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
  Future<void> close() => _events.close();
}

class _NoLiveMutationVoiceGateway
    implements
        HermesDesktopGateway,
        HermesDesktopClientSurfacePromptGateway,
        HermesDesktopRedirectGateway,
        HermesDesktopSessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<String> submissions = [];
  final List<Map<String, dynamic>> metadata = [];
  int redirectCalls = 0;
  int steerCalls = 0;

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
    runtimeSessionId: 'runtime-voice-no-live-mutation',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-voice-no-live-mutation',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-voice-no-live-mutation',
    storedSessionId: 'stored-voice-no-live-mutation',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
    metadata.add({});
  }

  @override
  Future<void> submitPromptWithSurface(
    String runtimeSessionId,
    String text,
    PromptClientSurface surface,
  ) async {
    submissions.add(text);
    metadata.add(surface.toParams());
  }

  @override
  Future<void> submitInterruptedPromptWithSurface(
    String runtimeSessionId,
    String text,
    PromptClientSurface surface,
  ) => submitPromptWithSurface(runtimeSessionId, text, surface);

  @override
  Future<void> submitQueuedPromptWithSurface(
    String runtimeSessionId,
    String text,
    PromptClientSurface surface,
  ) => submitPromptWithSurface(runtimeSessionId, text, surface);

  @override
  Future<DesktopTurnAck> submitPromptIdempotentWithSurface(
    String runtimeSessionId,
    String text,
    String clientTurnId,
    PromptClientSurface surface,
  ) async {
    await submitPromptWithSurface(runtimeSessionId, text, surface);
    return DesktopTurnAck.fromJson({
      'accepted': true,
      'client_turn_id': clientTurnId,
      'server_turn_id': 'synthetic',
      'state': 'accepted',
      'duplicate': false,
    }, expectedClientTurnId: clientTurnId);
  }

  @override
  Future<DesktopTurnAck> submitQueuedPromptIdempotentWithSurface(
    String runtimeSessionId,
    String text,
    String clientTurnId,
    PromptClientSurface surface,
  ) => submitPromptIdempotentWithSurface(
    runtimeSessionId,
    text,
    clientTurnId,
    surface,
  );

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    steerCalls++;
  }

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    redirectCalls++;
    return DesktopRedirectDisposition.redirected;
  }

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  void complete(String text) {
    _events.add(
      TuiGatewayEvent(
        type: 'message.complete',
        sessionId: 'runtime-voice-no-live-mutation',
        payload: {'text': text},
      ),
    );
  }

  @override
  Future<void> close() => _events.close();
}

/// Each part was spoken exactly once, in this order.
void _expectSpokenOnceInOrder(List<String> spoken, List<String> parts) {
  final said = spoken.join(' ');
  var from = 0;
  for (final part in parts) {
    expect(
      RegExp(RegExp.escape(part)).allMatches(said),
      hasLength(1),
      reason: '"$part" once in $spoken',
    );
    final at = said.indexOf(part, from);
    expect(at, greaterThanOrEqualTo(0), reason: '"$part" in order: $spoken');
    from = at + part.length;
  }
}

Future<_Harness> _harness({
  FullDuplexBargeInMonitor? fullDuplexMonitor,
  Future<void> Function(String prompt)? onBeforeSend,
  Future<void> Function(Duration delay)? playbackTailDelay,
  bool bargeInEnabled = true,
  bool continueWhenLocked = false,
  bool captureReadyAutomatically = true,
  bool allowTransportFallback = false,
  VoiceTurnLatencyLog? turnLatencyLog,
  Stream<LiveAudioEvent> Function()? audioEvents,
  bool languageFellBack = false,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final voice = _FakeVoice(prefs, bargeInEnabled: bargeInEnabled);
  voice.captureReadyAutomatically = captureReadyAutomatically;
  voice.languageFellBack = languageFellBack;
  if (continueWhenLocked) {
    await voice.acceptVoiceDisclosure(continueWhenLocked: true);
  }
  final gateway = _FakeGateway();
  final service = ActiveChatService(
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final chat = service.attach(
    connection: _connection(),
    sessionId: 'visible-session',
    sessionTitle: 'Voz',
    api: testApiClient(
      baseUrl: 'http://hermes.test:8642',
      httpClient: gateway.counter,
    ),
    desktopGateway: gateway.socket,
  );
  final controller = LocalVoiceConversationController(
    voice,
    fullDuplexMonitor: fullDuplexMonitor,
    playbackTailDelay: playbackTailDelay ?? (_) async {},
    turnLatencyLog: turnLatencyLog,
    audioEvents: audioEvents,
    routeChangeSettle: Duration.zero,
  );
  await controller.enter(
    chat: chat,
    model: 'hermes-agent',
    allowTransportFallback: allowTransportFallback,
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

class _VoiceTicketDashboard extends DashboardClient {
  _VoiceTicketDashboard()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'synthetic',
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({'app_locale': 'es'}));

  for (final requireVoiceMarker in [false, true]) {
    for (final voiceSubmitFails in [false, true]) {
      test(
        '${requireVoiceMarker ? 'voice marker contract' : 'typed negative control'} over real RPC after ${voiceSubmitFails ? 'error' : 'cancel'}',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final sockets = <WebSocket>[];
          final submits = <Map<String, dynamic>>[];
          server.listen((request) async {
            final socket = await WebSocketTransformer.upgrade(request);
            sockets.add(socket);
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'method': 'event',
                'params': {
                  'type': 'gateway.ready',
                  'payload': {'heartbeat': false, 'change_events': true},
                },
              }),
            );
            await for (final raw in socket) {
              final frame = jsonDecode(raw as String) as Map<String, dynamic>;
              final params = (frame['params'] as Map?) ?? const {};
              final method = frame['method'];
              if (method == 'client.capabilities') continue;
              if (method == 'prompt.submit') {
                submits.add(Map<String, dynamic>.from(params));
              }
              if (method == 'prompt.submit' &&
                  voiceSubmitFails &&
                  submits.length == 1) {
                socket.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'id': frame['id'],
                    'error': {
                      'code': 4000,
                      'message': 'Synthetic submit rejection',
                    },
                  }),
                );
                continue;
              }
              final result = switch (method) {
                'gateway.capabilities' => {
                  'per_session_exclusive_submit': true,
                },
                'session.resume' => {
                  'session_id': 'runtime-spoken',
                  'stored_session_id': params['session_id'],
                  'running': false,
                  'status': 'idle',
                },
                'prompt.submit' => {
                  'accepted': true,
                  'client_turn_id': params['client_turn_id'],
                  'server_turn_id': 'turn-${submits.length}',
                  'state': 'accepted',
                  'duplicate': false,
                },
                'session.interrupt' => {'interrupted': true},
                _ => <String, dynamic>{'status': 'ok'},
              };
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': frame['id'],
                  'result': result,
                }),
              );
            }
          });
          final prefs = await SharedPreferences.getInstance();
          final voice = _FakeVoice(prefs, bargeInEnabled: false);
          final connection = SavedConnection(
            id: 'chained-wire',
            label: 'Synthetic',
            host: '127.0.0.1',
            port: 8642,
            apiKey: '',
            dashboardUrl: 'http://127.0.0.1:${server.port}',
            kind: InstanceKind.vps,
          );
          final desktop = TuiGatewayClient(
            connection,
            dashboard: _VoiceTicketDashboard(),
          );
          final service = ActiveChatService(
            compressionRestoreStore: testCompressionRestoreStore(),
          );
          final chat = service.attach(
            connection: connection,
            sessionId: 'stored-spoken',
            sessionTitle: 'Synthetic',
            api: testApiClient(
              baseUrl: 'http://hermes.test:8642',
              httpClient: HostCounter(),
            ),
            desktopGateway: desktop,
            allowUnownedDesktopSnapshotForTesting: true,
            disableForegroundKeepAlive: true,
          );
          final controller = LocalVoiceConversationController(
            voice,
            playbackTailDelay: (_) async {},
          );
          addTearDown(() async {
            await controller.exit();
            controller.dispose();
            service.dispose();
            await desktop.close();
            for (final socket in sockets) {
              await socket.close();
            }
            for (final capture in voice.captures) {
              await capture.close();
            }
            await server.close(force: true);
          });
          await controller.enter(chat: chat, model: 'main-model');
          voice.captures.single.add(
            const SttResult('Spoken synthetic prompt', true),
          );
          await _waitFor(() => submits.isNotEmpty);
          expect(submits.single['text'], 'Spoken synthetic prompt');
          expect(submits.single.containsKey('surface'), isFalse);
          // A rejected voice submit fails asynchronously: its rollback retires
          // the desktop runtime. Typing before that settles races the late
          // failure against the typed turn, so let the rejection finish first.
          if (voiceSubmitFails) await _waitFor(() => !chat.isStreaming);
          await controller.exit();
          chat.cancel();
          await _waitFor(() => !chat.isStreaming);
          await chat.send(
            fullText: 'Typed synthetic prompt',
            model: 'main-model',
            history: chat.buildHistory(),
          );
          await _waitFor(() => submits.length == 2);
          expect(submits.last.containsKey('voice_turn'), isFalse);
          expect(submits.last['text'], 'Typed synthetic prompt');
          if (requireVoiceMarker) expect(submits.first['voice_turn'], isTrue);
        },
      );
    }
  }

  test(
    'Voice encola FIFO sin redirect ni steer y conserva submit idle',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = _FakeVoice(prefs);
      final rest = HostCounter();
      final desktop = _NoLiveMutationVoiceGateway();
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      final chat = service.attach(
        connection: _connection(),
        sessionId: 'remote-voice-no-live-mutation',
        sessionTitle: 'Remote voice queue',
        api: testApiClient(
          baseUrl: 'http://hermes.test:8642',
          httpClient: rest,
        ),
        desktopGateway: desktop,
        allowUnownedDesktopSnapshotForTesting: true,
        disableForegroundKeepAlive: true,
      );
      final controller = LocalVoiceConversationController(
        voice,
        playbackTailDelay: (_) async {},
      );
      await controller.enter(chat: chat, model: 'hermes-agent');

      voice.captures.single.add(const SttResult('Primer turno de voz', true));
      await _waitFor(
        () => desktop.submissions.length == 1,
        diagnostics: () =>
            'idle submissions=${desktop.submissions} phase=${controller.phase}',
      );

      controller.stopAndTalk();
      await _waitFor(
        () => voice.captures.length == 2,
        diagnostics: () =>
            'captures=${voice.captures.length} phase=${controller.phase}',
      );
      voice.captures.last.add(const SttResult('Segundo turno de voz', true));
      await _waitFor(
        () => desktop.redirectCalls > 0 || chat.queuedMessages.isNotEmpty,
        diagnostics: () =>
            'redirect=${desktop.redirectCalls} queue=${chat.queuedMessages} '
            'phase=${controller.phase}',
      );

      expect(desktop.redirectCalls, 0);
      expect(desktop.steerCalls, 0);
      expect(chat.queuedMessages, ['Segundo turno de voz']);
      expect(rest.runsRequests, isEmpty);

      desktop.complete('primero hecho');
      await _waitFor(
        () => desktop.submissions.length == 2,
        diagnostics: () =>
            'drained submissions=${desktop.submissions} queue=${chat.queuedMessages}',
      );
      expect(desktop.metadata, [
        {'voice_turn': true},
        {'voice_turn': true},
      ]);
      expect(desktop.submissions, [
        'Primer turno de voz',
        'Segundo turno de voz',
      ]);
      expect(desktop.redirectCalls, 0);
      expect(desktop.steerCalls, 0);
      expect(rest.runsRequests, isEmpty);

      desktop.complete('segundo hecho');
      await controller.exit();
      controller.dispose();
      service.dispose();
      await desktop.close();
    },
  );

  test(
    'remote voice never falls back to REST when desktop admission fails',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = _FakeVoice(prefs);
      final httpGateway = HostCounter();
      final desktop = _FailingVoiceDesktopGateway();
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      final chat = service.attach(
        connection: _connection(),
        sessionId: 'remote-voice-no-rest',
        sessionTitle: 'Remote voice',
        api: testApiClient(
          baseUrl: 'http://hermes.test:8642',
          httpClient: httpGateway,
        ),
        desktopGateway: desktop,
      );
      final controller = LocalVoiceConversationController(
        voice,
        playbackTailDelay: (_) async {},
      );
      final beforeSend = Completer<void>();
      await controller.enter(
        chat: chat,
        model: 'hermes-agent',
        onBeforeSend: (_) async {
          if (!beforeSend.isCompleted) beforeSend.complete();
        },
      );

      voice.captures.single.add(const SttResult('mensaje remoto', true));
      await beforeSend.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(httpGateway.runsRequests, isEmpty);
      await controller.exit();
      controller.dispose();
      service.dispose();
      await desktop.close();
    },
  );

  test(
    'voice preserves a caller policy that forbids local REST fallback',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = _FakeVoice(prefs);
      final httpGateway = HostCounter();
      final desktop = _FailingVoiceDesktopGateway();
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      final chat = service.attach(
        connection: _localOnDeviceConnection(),
        sessionId: 'local-voice-policy-no-rest',
        sessionTitle: 'Restricted local voice',
        api: testApiClient(
          baseUrl: 'http://127.0.0.1:8642',
          httpClient: httpGateway,
        ),
        desktopGateway: desktop,
      );
      final controller = LocalVoiceConversationController(
        voice,
        playbackTailDelay: (_) async {},
      );
      final beforeSend = Completer<void>();
      await controller.enter(
        chat: chat,
        model: 'hermes-agent',
        allowTransportFallback: false,
        onBeforeSend: (_) async {
          if (!beforeSend.isCompleted) beforeSend.complete();
        },
      );
      expect(controller.debugAllowTransportFallback, isFalse);

      voice.captures.single.add(const SttResult('mensaje restringido', true));
      await beforeSend.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(httpGateway.runsRequests, isEmpty);
      await controller.exit();
      expect(controller.debugAllowTransportFallback, isFalse);
      controller.dispose();
      service.dispose();
      await desktop.close();
    },
  );

  test(
    'voice binds fallback permission only while its owner is active',
    () async {
      final h = await _harness(allowTransportFallback: true);
      expect(h.controller.debugAllowTransportFallback, isTrue);

      await h.close();

      expect(h.controller.debugAllowTransportFallback, isFalse);
    },
  );

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

    expect(h.gateway.submitTexts, isEmpty);
    expect(h.voice.prepareNarrationCalls, 0);
    expect(h.controller.userTranscript, isEmpty);
    await h.close();
  });

  test('una y aislada rearma sin saludo fantasma y sí sigue al chat', () async {
    final h = await _harness();

    h.voice.captures.single.add(const SttResult('Y.', true));
    await _waitFor(() => h.voice.captures.length == 2);

    expect(h.gateway.submitTexts, isEmpty);
    expect(h.controller.phase, VoicePhase.listening);

    h.voice.captures[1].add(const SttResult('sí', true));
    await _waitFor(() => h.gateway.submitTexts.length == 1);

    expect(h.gateway.submitTexts.single, 'sí');
    h.chat.cancel();
    await h.close();
  });

  test('Cállate durante escucha termina sin enviar un turno', () async {
    final h = await _harness();

    h.voice.captures.single.add(const SttResult('Cállate.', true));
    await _waitFor(() => !h.controller.active);

    expect(h.gateway.submitTexts, isEmpty);
    expect(h.service.of(h.chat.connection.id, h.chat.sessionId), same(h.chat));
    expect(h.controller.userTranscript, isEmpty);
    await h.close();
  });

  // voice.stop_phrases, as Desktop applies it to the spoken turn
  // (use-voice-conversation.ts:302 and :523 → voice-stop-word.ts:97-129).
  VoiceStopPhraseConfig stopPhrases(List<String> list) =>
      VoiceStopPhraseConfig.fromServerConfig({
        'voice': {'stop_phrases': list},
      });

  test('a custom stop phrase ends without sending a turn', () async {
    final h = await _harness();
    h.voice.stopPhrases.value = stopPhrases(['отбой']);

    h.voice.captures.single.add(const SttResult('Hermes, отбой!', true));
    await _waitFor(() => !h.controller.active);

    expect(h.gateway.submitTexts, isEmpty);
    expect(h.controller.userTranscript, isEmpty);
    await h.close();
  });

  test('a custom list turns the built-in Stop into a normal turn', () async {
    final h = await _harness();
    h.voice.stopPhrases.value = stopPhrases(['отбой']);

    h.voice.captures.single.add(const SttResult('Stop.', true));
    await _waitFor(() => h.gateway.submitTexts.length == 1);

    expect(h.gateway.submitTexts.single, 'Stop.');
    expect(h.controller.active, isTrue);
    h.chat.cancel();
    await h.close();
  });

  test('an empty stop_phrases list sends Stop as a normal turn', () async {
    final h = await _harness();
    h.voice.stopPhrases.value = stopPhrases(const []);

    h.voice.captures.single.add(const SttResult('Stop.', true));
    await _waitFor(() => h.gateway.submitTexts.length == 1);

    expect(h.gateway.submitTexts.single, 'Stop.');
    expect(h.controller.active, isTrue);
    h.chat.cancel();
    await h.close();
  });

  // Desktop submit.ts:332-357: typing over the spoken reply stops it and the
  // typed turn carries `interrupted`, so Hermes tells the model it was cut.
  test('a typed send over the spoken reply stops it and is the interrupted '
      'turn', () async {
    final h = await _harness();
    expect(h.controller.voicePlaybackActive, isFalse, reason: 'listening');

    h.voice.holdSpeech = true;
    h.voice.captures.single.add(const SttResult('cuéntame algo', true));
    await _waitFor(() => h.gateway.submitTexts.length == 1);
    expect(h.controller.voicePlaybackActive, isFalse, reason: 'thinking');
    h.gateway.token(1, 'Primera frase.');
    await _waitFor(() => h.voice.spoken.length == 1);
    await h.gateway.complete(1, 'Primera frase.');
    await _waitFor(() => !h.chat.isStreaming);
    expect(h.controller.voicePlaybackActive, isTrue, reason: 'speaking');

    final stopsBefore = h.voice.stopSpeakingCalls;
    expect(
      await h.chat.send(
        fullText: 'mejor otra cosa',
        model: 'hermes-agent',
        history: const [],
        voicePlaybackInterrupted: h.controller.voicePlaybackActive,
      ),
      isTrue,
    );
    await _waitFor(() => h.voice.stopSpeakingCalls > stopsBefore);

    expect(h.gateway.socket.submits.last['text'], 'mejor otra cosa');
    expect(h.gateway.socket.submits.last['kind'], 'interrupted');
    await _waitFor(() => !h.controller.voicePlaybackActive);
    h.voice.finishSpeech();
    h.chat.cancel();
    await h.close();
  });

  test(
    'cerrar el ActiveChat propietario termina Voz sin dejar captura',
    () async {
      final h = await _harness();

      h.chat.dispose();
      await _waitFor(() => !h.controller.active);

      expect(h.voice.disposeSttCalls, 1);
      // The microphone goes; the recogniser may stay loaded for a next start.
      expect(h.voice.keepRecognizerWarmRequests, [true]);
      expect(h.voice.disposeTtsCalls, 1);
      expect(h.controller.ownerChat, isNull);
      await h.close();
    },
  );

  test('una frase que contiene stop sigue llegando al agente', () async {
    final h = await _harness();

    h.voice.captures.single.add(const SttResult('stop the container', true));
    await _waitFor(() => h.gateway.submitTexts.length == 1);

    expect(h.gateway.submitTexts.single, 'stop the container');
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      expect(h.controller.userTranscript, 'hola Hermes');

      h.gateway.token(1, 'Hola, estoy aquí.');
      await _waitFor(() => h.voice.spoken.isNotEmpty);
      await h.gateway.complete(1, 'Hola, estoy aquí.');
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(h.voice.spoken, ['Hola, estoy aquí.']);
      expect(h.controller.assistantResponse, 'Hola, estoy aquí.');
      expect(h.gateway.submitTexts, hasLength(1));
      final evidence = jsonEncode([
        h.gateway.counter.requests,
        h.gateway.submitTexts,
      ]);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
    await _waitFor(() => h.gateway.submitTexts.length == 1);
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
    await _waitFor(() => h.gateway.submitTexts.length == 1);

    expect(metadataGate.isCompleted, isFalse);
    expect(h.gateway.submitTexts.single, 'envía sin esperar');
    metadataGate.complete();
    await h.close();
  });

  test('Pause conserva cursor y Play repite como máximo la frase', () async {
    final h = await _harness();
    h.voice.holdSpeech = true;
    h.voice.captures.single.add(const SttResult('cuéntame algo', true));
    await _waitFor(() => h.gateway.submitTexts.isNotEmpty);
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
      // Resume must not pay the recogniser's load again.
      expect(h.voice.keepRecognizerWarmRequests, [true]);
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
      await _waitFor(() => h.gateway.submitTexts.isNotEmpty);
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
      await _waitFor(() => h.gateway.submitTexts.isNotEmpty);
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
      await _waitFor(() => h.gateway.submitTexts.isNotEmpty);
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
    expect(h.gateway.submitTexts, isEmpty);
    await h.close();
  });

  test(
    'la aprobación hablada llama al perfil principal por su nombre',
    () async {
      BotRosterRegistry.shared.publish('voice-local-controller', 'QA', const [
        AgentProfile(
          name: 'default',
          isDefault: true,
          botModeUiMeta: {'title': 'xPeta'},
        ),
      ]);
      addTearDown(
        () => BotRosterRegistry.shared.forget('voice-local-controller'),
      );
      final h = await _harness();
      h.voice.captures.single.add(
        const SttResult('haz una acción sensible', true),
      );
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      h.gateway.approval(1);
      await _waitFor(() => h.controller.phase == VoicePhase.waitingPermission);
      await _waitFor(() => h.voice.localSpoken.length == 1);
      expect(
        h.voice.localSpoken.single,
        'xPeta necesita tu aprobación. Abre la aplicación para revisarla.',
      );
      await h.close();
    },
  );

  test(
    'una aprobación avisa una vez, silencia el micro y solo se resuelve por UI',
    () async {
      final h = await _harness();
      h.voice.captures.single.add(
        const SttResult('haz una acción sensible', true),
      );
      await _waitFor(() => h.gateway.submitTexts.length == 1);

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
      expect(h.gateway.socket.approvals.single.requestId, 'approval-1');
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);

      h.controller.stopAndTalk();
      await _waitFor(() => h.voice.captures.length == 2);
      h.voice.captures.last.add(const SttResult('corrige el enfoque', true));
      await _waitFor(() => h.chat.queuedMessages.isNotEmpty);

      expect(h.chat.isStreaming, isTrue);
      expect(h.chat.queuedMessages, ['corrige el enfoque']);
      expect(h.gateway.submitTexts, hasLength(1));
      await h.gateway.complete(1, 'Parcial conservado.');
      await _waitFor(() => h.gateway.submitTexts.length == 2);
      expect(jsonEncode(h.gateway.submitTexts), isNot(contains('mob-aux-')));

      h.chat.cancel();
      await h.close();
    },
  );

  test('the Stop failure note follows the English app locale', () async {
    SharedPreferences.setMockInitialValues({'app_locale': 'en'});
    final h = await _harness();
    h.voice.captures.single.add(const SttResult('cancellable task', true));
    await _waitFor(() => h.gateway.submitTexts.isNotEmpty);
    h.voice.stopSpeakingError = StateError('audio driver failed');

    h.controller.cancelBackend();
    await _waitFor(() => h.controller.note != null);

    expect(h.controller.note, "Couldn't save Stop safely. Try again.");
    h.voice.stopSpeakingError = null;
    await h.close();
  });

  test('Cancelar detiene backend; X solo libera voz y deja el run', () async {
    final cancelHarness = await _harness();
    cancelHarness.voice.captures.single.add(
      const SttResult('tarea cancelable', true),
    );
    await _waitFor(() => cancelHarness.gateway.submitTexts.isNotEmpty);
    cancelHarness.controller.cancelBackend();
    await _waitFor(() => cancelHarness.gateway.interrupts == 1);
    expect(cancelHarness.chat.isStreaming, isFalse);
    await cancelHarness.close();

    final exitHarness = await _harness();
    exitHarness.voice.captures.single.add(
      const SttResult('tarea que sigue', true),
    );
    await _waitFor(() => exitHarness.gateway.submitTexts.isNotEmpty);
    exitHarness.voice.enableNativeVoice(
      speak: (text) async => {'ok': true},
      transcribe: (dataUrl, mimeType) async => {'ok': true},
    );
    expect(exitHarness.voice.nativeVoiceActive, isTrue);
    await exitHarness.controller.exit();

    expect(exitHarness.chat.isStreaming, isTrue);
    expect(exitHarness.gateway.interrupts, 0);
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
        api: testApiClient(
          baseUrl: 'http://hermes.test:8642',
          httpClient: h.gateway.counter,
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);

      h.gateway.token(1, 'Respuesta ');
      await _waitFor(
        () => socket.sent.any((frame) => frame['text'] == 'Respuesta'),
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
        ['Respuesta', ' fluida.'],
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
    await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      // A lock releases the recogniser for good: nothing stays loaded.
      expect(h.voice.keepRecognizerWarmRequests, [false]);

      // Also the one a pause had kept loaded for Resume.
      final paused = await _harness();
      paused.controller.pauseConversation();
      await _waitFor(() => paused.voice.disposeSttCalls == 1);
      await paused.controller.suspendForPrivacy();
      expect(paused.voice.keepRecognizerWarmRequests, [true, false]);
      await paused.close();
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
          await _waitFor(() => h.gateway.submitTexts.length == 1);
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
        final runsBeforeLock = h.gateway.submitTexts.length;
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
        expect(h.gateway.submitTexts, hasLength(runsBeforeLock));
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
    await _waitFor(() => h.gateway.submitTexts.length == 1);
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
        await _waitFor(() => h.gateway.submitTexts.length == 1);
        // Desktop acknowledges the turn with `message.start` (prompt_turn.py).
        h.gateway.socket.emit('message.start');
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);

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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      h.gateway.token(1, 'Respuesta que ningún TTS aceptará.');
      // The first token batch is painted (and narrated) on the next turn of the
      // event loop, so a rejected attempt may already be recorded here.
      await Future<void>.delayed(const Duration(milliseconds: 20));

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

      final rejectedAttempts = h.voice.spoken.length;
      h.voice.acceptSpeech = true;
      h.controller.pauseConversation();
      await _waitFor(
        () => h.controller.userPaused,
        diagnostics: () => 'pause phase=${h.controller.phase}',
      );
      h.controller.playConversation();
      await _waitFor(
        () => h.voice.spoken.length == rejectedAttempts + 1,
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
      expect(h.voice.spoken.length, rejectedAttempts + 1);
      expect(h.voice.spoken.toSet(), {
        'Respuesta que ningún TTS aceptará.',
      }, reason: 'the same text is retried, never lost or altered');
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
      h = await _harness();
      h.gateway.socket.submitError = StateError('socket lost');
      h.voice.captures.single.add(const SttResult('fallo remoto', true));
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 2);
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
    await _waitFor(() => h.gateway.submitTexts.length == 1);
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

  // Desktop `awaitFallbackSpeech` (use-voice-conversation.ts:703-842, since
  // e39900cc91 in v0.22.0): without PCM, each completed sentence is POSTed
  // while the reply is still being generated, and none twice.
  test(
    'fallback antes de PCM habla cada frase durante la generación',
    () async {
      final h = await _harness();
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);
      h.voice.holdSpeech = true;

      h.voice.captures.single.add(const SttResult('usa el fallback', true));
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      h.gateway.token(1, 'Primera frase.');
      await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));

      await socket.emit(jsonEncode({'type': 'fallback'}));
      await _waitFor(() => h.voice.spoken.isNotEmpty);
      expect(h.chat.isStreaming, isTrue);
      expect(h.voice.spoken, ['Primera frase.']);

      h.gateway.token(1, ' Segunda frase.');
      h.voice.finishSpeech();
      await _waitFor(
        () => h.voice.spoken.join(' ').contains('Segunda frase.'),
        diagnostics: () => 'spoken=${h.voice.spoken}',
      );
      expect(h.chat.isStreaming, isTrue);

      h.gateway.token(1, ' Cola sin cerrar');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.voice.spoken.join(' '), isNot(contains('Cola sin cerrar')));

      await h.gateway.complete(
        1,
        'Primera frase. Segunda frase. Cola sin cerrar',
      );
      await _waitFor(
        () => h.voice.spoken.join(' ').contains('Cola sin cerrar'),
        diagnostics: () => 'spoken=${h.voice.spoken}',
      );
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(sink.writes, isEmpty);
      _expectSpokenOnceInOrder(h.voice.spoken, [
        'Primera frase.',
        'Segunda frase.',
        'Cola sin cerrar',
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      h.gateway.token(1, accepted);
      await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));
      await socket.emit(jsonEncode({'type': 'fallback'}));
      // The accepted sentence is spoken at once, before the final arrives.
      await _waitFor(() => h.voice.spoken.isNotEmpty);
      expect(h.voice.spoken, [accepted]);

      await h.gateway.complete(1, '¡Listo! $accepted Ceuta sigue abierta.');
      await _waitFor(
        () => h.controller.assistantResponse.contains('Ceuta sigue abierta.'),
      );
      h.voice.finishSpeech();
      await _waitFor(
        () => h.voice.spoken.join(' ').contains('Ceuta sigue abierta.'),
        diagnostics: () => 'spoken=${h.voice.spoken}',
      );
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(sink.writes, isEmpty);
      // The final only adds its authoritative tail; the body is not re-read.
      _expectSpokenOnceInOrder(h.voice.spoken, [
        accepted,
        'Ceuta sigue abierta.',
      ]);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      h.gateway.token(1, 'Primera frase. Esta cola forma un único fallback.');
      await _waitFor(() => socket.sent.any((frame) => frame['text'] != null));
      await socket.emit(jsonEncode({'type': 'fallback'}));
      await _waitFor(() => h.voice.spoken.isNotEmpty);
      expect(h.voice.spoken.first, 'Primera frase.');

      await h.gateway.complete(
        1,
        'Primera frase. Esta cola forma un único fallback.',
      );

      h.controller.stopAndTalk();
      await _waitFor(() => h.voice.stopSpeakingCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.voice.captures, hasLength(1));

      h.voice.releaseStopSpeaking();
      await _waitFor(() => h.voice.captures.length == 2);
      expect(
        RegExp('Primera frase').allMatches(h.voice.spoken.join(' ')),
        hasLength(1),
      );
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      expect(h.gateway.submitTexts, hasLength(1));
      expect(sink.stopped, isFalse);
      expect(h.controller.debugBargeCaptureInFlight, isFalse);

      await h.gateway.complete(1, 'Hermes debe terminar esta respuesta.');
      await _waitFor(() => socket.sent.any((frame) => frame['done'] == true));
      await socket.emit(jsonEncode({'type': 'end'}));
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(h.gateway.submitTexts, hasLength(1));
      expect(source.playbackActive, isFalse);
      expect(h.voice.captures, hasLength(2));

      await h.close();
    },
  );

  test('fallback providerUnsupported pre-PCM habla cada frase durante la '
      'generación', () async {
    final h = await _harness();
    final socket = _ControllerSpeechSocket();
    final sink = _ControllerPcmSink();
    _enableStreamingVoice(h.voice, socket, sink, fallbackBeforeReturn: true);

    h.voice.captures.single.add(
      const SttResult('usa el fallback inmediato', true),
    );
    await _waitFor(() => h.gateway.submitTexts.length == 1);
    h.gateway.token(1, 'Primera inmediata.');
    await _waitFor(() => h.voice.spoken.isNotEmpty);
    expect(h.voice.spoken, ['Primera inmediata.']);
    expect(h.chat.isStreaming, isTrue);
    h.gateway.token(1, ' Segunda inmediata.');
    await _waitFor(
      () => h.voice.spoken.join(' ').contains('Segunda inmediata.'),
    );
    expect(h.chat.isStreaming, isTrue);
    await h.gateway.complete(1, 'Primera inmediata. Segunda inmediata.');
    await _waitFor(() => h.controller.phase == VoicePhase.listening);

    expect(sink.writes, isEmpty);
    expect(socket.sent.where((frame) => frame['text'] != null), isEmpty);
    _expectSpokenOnceInOrder(h.voice.spoken, [
      'Primera inmediata.',
      'Segunda inmediata.',
    ]);
    await h.close();
  });

  test(
    'endpoint speak-stream ausente habla cada frase durante la generación',
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      h.gateway.token(1, 'Primera parte.');
      h.gateway.token(1, ' Segunda parte.');
      await _waitFor(
        () => h.voice.spoken.join(' ').contains('Segunda parte.'),
        diagnostics: () => 'spoken=${h.voice.spoken}',
      );
      expect(h.chat.isStreaming, isTrue);

      await h.gateway.complete(1, 'Primera parte. Segunda parte.');
      await _waitFor(() => h.controller.phase == VoicePhase.listening);

      expect(streamAttempts, 1);
      _expectSpokenOnceInOrder(h.voice.spoken, [
        'Primera parte.',
        'Segunda parte.',
      ]);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);

      expect(source.starts, 1);
      expect(source.startGate!.isCompleted, isFalse);
      expect(h.gateway.submitTexts.single, 'envía ya');

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
    await _waitFor(() => h.gateway.submitTexts.length == 1);
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
    await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      await _waitFor(() => monitor.armed);
      h.gateway.token(1, 'Estas son las noticias de hoy.');
      await _waitFor(() => h.voice.spoken.length == 1);
      await _waitFor(() => source.playbackActive);

      await _emitBargeFrames(source, 80, 42);
      await _emitBargeFrames(source, 1800, 27);
      await _waitFor(() => h.controller.debugBargeCaptureInFlight);
      await _waitFor(() => h.voice.stopSpeakingCalls == 1);
      await _emitBargeFrames(source, 0, 60);
      await _waitFor(() => h.gateway.submitTexts.length == 2);

      h.gateway.token(2, 'Ahora mismo hay veintidós grados.');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(h.voice.spoken, [
        'Estas son las noticias de hoy.',
      ], reason: 'el siguiente TTS debe esperar al ACK del drain anterior');

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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.interrupts == 1);

      // La respuesta antigua puede terminar mientras Whisper sigue
      // transcribiendo; sus callbacks ya están invalidados por el barge-in.
      await h.gateway.complete(1, 'Noticias de hoy que el usuario no oyó.');
      source.transcriptionGate!.complete('Y también las de ayer');
      await _waitFor(() => h.gateway.submitTexts.length == 2);

      expect(h.chat.queuedMessages, isEmpty);
      expect(h.gateway.submitTexts, [
        'Dame las noticias de hoy',
        'Y también las de ayer',
      ]);
      expect(h.gateway.interrupts, 1);

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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      await _waitFor(() => monitor.armed);

      await _emitBargeFrames(source, 80, 42);
      await monitor.setPlaybackActive(true);
      await _emitBargeFrames(source, 1800, 27);
      await _waitFor(() => h.controller.debugBargeCaptureInFlight);
      await _emitBargeFrames(source, 0, 60);
      await _waitFor(() => !h.controller.active);

      expect(h.chat.isStreaming, isFalse);
      expect(h.chat.queuedMessages, isEmpty);
      expect(h.gateway.submitTexts, hasLength(1));
      expect(h.gateway.interrupts, 1);

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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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

      expect(h.gateway.submitTexts, hasLength(1));
      expect(h.gateway.interrupts, 0);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
    await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
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
    await _waitFor(() => h.gateway.submitTexts.length == 1);
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
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      await _waitFor(() => monitor.armed);

      await _emitBargeFrames(source, 80, 42);
      await _emitBargeFrames(source, 2600, 10);
      await _waitFor(() => h.controller.debugBargeCaptureInFlight);
      await _waitFor(() => h.gateway.interrupts == 1);
      expect(h.chat.isStreaming, isFalse);

      // Desktop corta el turno en speech_start, sigue capturando y envía la
      // frase como turno normal cuando llega el endpoint de ~1,25 s.
      await _emitBargeFrames(source, 0, 42);
      await _waitFor(() => h.gateway.submitTexts.length == 2);

      expect(h.chat.queuedMessages, isEmpty);
      expect(h.gateway.submitTexts, [
        'Dame las noticias de hoy',
        'Y también las de ayer',
      ]);
      expect(h.gateway.interrupts, 1);

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
    await _waitFor(() => h.gateway.submitTexts.length == 1);
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

  test('client-direct speech narrates each sentence without speak-stream, '
      'like Desktop', () async {
    final h = await _harness();
    var opens = 0;
    h.voice.enableNativeVoice(
      speak: (text) async => <String, dynamic>{'ok': false},
      transcribe: (dataUrl, mimeType) async => <String, dynamic>{'text': ''},
      speechStream: () async {
        opens++;
        throw StateError('client-direct speech must not open speak-stream');
      },
      clientDirectSpeech: true,
    );

    h.voice.captures.single.add(const SttResult('cuéntame algo', true));
    await _waitFor(() => h.gateway.submitTexts.length == 1);
    h.gateway.token(1, 'Primera frase.');
    await _waitFor(() => h.voice.spoken.isNotEmpty);

    expect(h.voice.spoken, ['Primera frase.']);
    expect(opens, 0);
    await h.gateway.complete(1, 'Primera frase.');
    h.chat.cancel();
    await h.close();
  });

  test('relayed server speech without speak-stream also narrates each '
      'sentence as it streams, like Desktop', () async {
    final h = await _harness();
    h.voice.enableNativeVoice(
      speak: (text) async => <String, dynamic>{'ok': false},
      transcribe: (dataUrl, mimeType) async => <String, dynamic>{'text': ''},
    );

    h.voice.captures.single.add(const SttResult('cuéntame algo', true));
    await _waitFor(() => h.gateway.submitTexts.length == 1);
    h.gateway.token(1, 'Primera frase.');
    await _waitFor(() => h.voice.spoken.isNotEmpty);

    expect(h.chat.isStreaming, isTrue);
    expect(h.voice.spoken, ['Primera frase.']);
    await h.gateway.complete(1, 'Primera frase.');
    await _waitFor(() => h.controller.phase == VoicePhase.listening);
    expect(h.voice.spoken, ['Primera frase.']);
    h.chat.cancel();
    await h.close();
  });

  // Desktop speaks a sealed interim bubble while its tool still runs
  // (use-voice-conversation.ts:687-693: `session.flush()` when busy).
  group('interim commentary during a tool, like Desktop', () {
    String sentText(_ControllerSpeechSocket socket) => [
      for (final frame in socket.sent)
        if (frame['text'] is String) frame['text'] as String,
    ].join();

    test('an interim with no final stop is spoken before its tool ends, '
        'and the answer does not repeat it', () async {
      final h = await _harness();
      h.voice.enableNativeVoice(
        speak: (text) async => <String, dynamic>{'ok': false},
        transcribe: (dataUrl, mimeType) async => <String, dynamic>{'text': ''},
        speechStream: () async =>
            throw StateError('client-direct speech never opens speak-stream'),
        clientDirectSpeech: true,
      );

      h.voice.captures.single.add(
        const SttResult('revisa el repositorio', true),
      );
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      h.gateway.token(1, 'Voy a revisar el repositorio');
      h.gateway.interim(
        1,
        'Voy a revisar el repositorio',
        alreadyStreamed: true,
      );
      h.gateway.toolStarted(1, 'terminal', 'git status');

      // Nothing completes the tool before this point.
      await _waitFor(
        () => h.voice.spoken.isNotEmpty && h.controller.activeTool != null,
        diagnostics: () => 'spoken=${h.voice.spoken}',
      );
      expect(
        h.voice.spoken.join(' '),
        contains('Voy a revisar el repositorio'),
      );

      h.gateway.toolCompleted(1, 'terminal');
      h.gateway.token(1, 'Todo está en orden.');
      await h.gateway.complete(1, 'Todo está en orden.');
      await _waitFor(
        () => h.voice.spoken.join(' ').contains('Todo está en orden.'),
        diagnostics: () => 'spoken=${h.voice.spoken}',
      );
      final said = h.voice.spoken.join(' ');
      expect(
        RegExp('Voy a revisar el repositorio').allMatches(said),
        hasLength(1),
      );
      expect(said, isNot(contains('repositorioTodo')));
      h.chat.cancel();
      await h.close();
    });

    test('the QA latency line says the interim played during the tool, '
        'and carries no words', () async {
      final lines = <String>[];
      var micros = 0;
      final h = await _harness(
        turnLatencyLog: VoiceTurnLatencyLog(
          enabled: true,
          nowMicros: () => micros += 1000,
          sink: lines.add,
        ),
      );
      h.voice.enableNativeVoice(
        speak: (text) async => <String, dynamic>{'ok': false},
        transcribe: (dataUrl, mimeType) async => <String, dynamic>{'text': ''},
        speechStream: () async =>
            throw StateError('client-direct speech never opens speak-stream'),
        clientDirectSpeech: true,
      );

      h.voice.captures.single.add(
        const SttResult('revisa el repositorio', true),
      );
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      h.gateway.token(1, 'Voy a revisar el repositorio');
      h.gateway.interim(
        1,
        'Voy a revisar el repositorio',
        alreadyStreamed: true,
      );
      h.gateway.toolStarted(1, 'terminal', 'git status');
      await _waitFor(
        () => h.voice.spoken.isNotEmpty && h.controller.activeTool != null,
        diagnostics: () => 'spoken=${h.voice.spoken}',
      );
      h.gateway.toolCompleted(1, 'terminal');
      h.gateway.token(1, 'Todo está en orden.');
      await h.gateway.complete(1, 'Todo está en orden.');
      await _waitFor(
        () => h.voice.spoken.join(' ').contains('Todo está en orden.'),
      );
      // Printed when the turn closes: the re-arm after the answer, or exit.
      // Every value is a number: audio never precedes the text it reads, and
      // the interim counts as the first reply text even when it reaches the
      // narration before any token event.
      await h.controller.exit();

      expect(lines, hasLength(1));
      expect(
        lines.single,
        matches(
          RegExp(
            r'^\[hermes-voice-latency\] turn=1 '
            r'endpoint_to_token_ms=\d+ endpoint_to_audio_ms=\d+ '
            r'token_to_audio_ms=\d+ audio=queue tool=yes '
            r'audio_during_tool=yes$',
          ),
        ),
      );
      for (final word in ['revisa', 'repositorio', 'orden', 'git']) {
        expect(lines.single, isNot(contains(word)));
      }
      h.chat.cancel();
      await h.close();
    });

    test('a sealed interim reaches speak-stream mid-tool', () async {
      final h = await _harness();
      final socket = _ControllerSpeechSocket();
      final sink = _ControllerPcmSink();
      _enableStreamingVoice(h.voice, socket, sink);

      h.voice.captures.single.add(const SttResult('mira el registro', true));
      await _waitFor(() => h.gateway.submitTexts.length == 1);
      // Sealed without deltas and ending in ':': no stable chunk changes.
      h.gateway.interim(1, 'Miro el registro:');
      h.gateway.toolStarted(1, 'terminal', 'tail app.log');

      await _waitFor(
        () => sentText(socket).contains('Miro el registro:'),
        diagnostics: () => 'sent=${socket.sent}',
      );
      expect(h.controller.activeTool, isNotNull);

      h.gateway.toolCompleted(1, 'terminal');
      h.gateway.token(1, 'Sin errores.');
      await h.gateway.complete(1, 'Sin errores.');
      await _waitFor(() => sentText(socket).contains('Sin errores.'));
      expect(
        RegExp('Miro el registro').allMatches(sentText(socket)),
        hasLength(1),
      );
      expect(sentText(socket), isNot(contains(':Sin')));
      h.chat.cancel();
      await h.close();
    });
  });

  // QA 9709 (the owner): the sound of the voice while the agent works was very
  // uncomfortable. Desktop's ambient blips (`thinking-sound.ts`) played
  // every 0.8-1.2 s from 400 ms on, on the media stream; Console is silent
  // while it works, whatever the profile's `voice.thinking_sound` says.
  test('silent while it works: nothing is played or spoken, even with '
      'voice.thinking_sound on', () async {
    final h = await _harness();
    h.voice.serverVoicePrefs
      ..select('thinking')
      ..apply(
        'thinking',
        const VoiceServerPrefs(thinkingSound: true, beepVolume: 1),
      );
    h.voice.enableNativeVoice(
      speak: (text) async => <String, dynamic>{'ok': false},
      transcribe: (dataUrl, mimeType) async => <String, dynamic>{'text': ''},
      speechStream: () async =>
          throw StateError('client-direct speech never opens speak-stream'),
      clientDirectSpeech: true,
    );
    h.voice.captures.single.add(const SttResult('cuéntame algo', true));
    await _waitFor(() => h.gateway.submitTexts.length == 1);
    h.gateway.toolStarted(1, 'terminal', 'ls');
    await _waitFor(() => h.controller.activeTool != null);
    expect(h.controller.phase, anyOf(VoicePhase.thinking, VoicePhase.toolCall));

    // Longer than the old loop's first blip (400 ms) and its next one
    // (0.8-1.2 s): nothing comes out while the tool runs.
    await Future<void>.delayed(const Duration(milliseconds: 1700));
    expect(h.controller.activeTool, isNotNull);
    expect(h.voice.spoken, isEmpty);
    expect(h.voice.localSpoken, isEmpty);
    expect(h.voice.prewarmed, isEmpty);

    // The reply is what speaks, once it comes.
    h.gateway.token(1, 'Hola.');
    await _waitFor(() => h.voice.spoken.isNotEmpty);
    await h.gateway.complete(1, 'Hola.');
    h.chat.cancel();
    await h.close();
  });

  test('a voice provider rejection is said, not hidden as a mic problem '
      '(REVIEW-R5-B #12)', () async {
    final h = await _harness();
    h.voice.captures.single.addError(
      const VoiceDirectProviderException('STT failed (401): invalid key'),
    );
    await _waitFor(
      () => h.controller.note != null,
      diagnostics: () => 'note=${h.controller.note}',
    );
    expect(h.controller.note, contains('STT failed (401): invalid key'));
    expect(
      h.controller.note,
      isNot(
        isIn([
          for (final language in voiceLanguages.values)
            language.message('microphoneUnclear'),
        ]),
      ),
    );
    await h.close();
  });

  test('a capture with nothing in it tells the user to check the mic '
      '(backlog item 7)', () async {
    final h = await _harness();
    h.voice.captures.single.addError(const SttNoAudioError());
    await _waitFor(() => h.controller.note != null);
    expect(
      h.controller.note,
      isIn([
        for (final language in voiceLanguages.values)
          language.message('noAudioHeard'),
      ]),
    );
    await h.close();
  });
  group('voice care', () {
    // A chat whose Hermes cannot be reached: every send fails.
    Future<
      ({
        _FakeVoice voice,
        LocalVoiceConversationController controller,
        List<String> prompts,
        Future<void> Function() close,
      })
    >
    unreachableChat() async {
      final prefs = await SharedPreferences.getInstance();
      final voice = _FakeVoice(prefs);
      final desktop = _FailingVoiceDesktopGateway();
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      final chat = service.attach(
        connection: _connection(),
        sessionId: 'voice-care-unreachable',
        sessionTitle: 'Voz',
        api: testApiClient(
          baseUrl: 'http://hermes.test:8642',
          httpClient: HostCounter(),
        ),
        desktopGateway: desktop,
      );
      final controller = LocalVoiceConversationController(
        voice,
        playbackTailDelay: (_) async {},
      );
      final prompts = <String>[];
      await controller.enter(
        chat: chat,
        model: 'hermes-agent',
        onBeforeSend: (prompt) async => prompts.add(prompt),
      );
      return (
        voice: voice,
        controller: controller,
        prompts: prompts,
        close: () async {
          await controller.exit();
          controller.dispose();
          service.dispose();
          await desktop.close();
        },
      );
    }

    test('a message that does not reach Hermes is held, not lost', () async {
      final h = await unreachableChat();
      h.voice.captures.single.add(const SttResult('mensaje que falla', true));
      await _waitFor(() => h.controller.heldTurnText != null);

      expect(h.controller.heldTurnText, 'mensaje que falla');
      expect(h.controller.care, VoiceCare.sendFailed);
      expect(h.controller.note, isNotNull);
      expect(h.controller.phase, VoicePhase.idle);
      // Opening the microphone again would clear the notice and the words.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.voice.captures, hasLength(1));

      expect(h.controller.takeHeldTurnText(), 'mensaje que falla');
      expect(h.controller.heldTurnText, isNull);
      expect(h.controller.takeHeldTurnText(), isNull);
      await h.close();
    });

    test('pausing and resuming over a held message does not stall', () async {
      final h = await unreachableChat();
      h.voice.captures.single.add(const SttResult('texto retenido', true));
      await _waitFor(() => h.controller.heldTurnText != null);

      h.controller.pauseConversation();
      await _waitFor(() => h.controller.userPaused);
      h.controller.playConversation();
      await _waitFor(() => h.voice.captures.length == 2);

      // The conversation listens again and keeps rearming after an empty take.
      h.voice.captures[1].add(const SttResult('', true));
      await _waitFor(() => h.voice.captures.length == 3);
      expect(h.controller.takeHeldTurnText(), 'texto retenido');
      await h.close();
    });

    test('Retry sends the same held message again', () async {
      final h = await unreachableChat();
      h.voice.captures.single.add(const SttResult('mismo mensaje', true));
      await _waitFor(() => h.controller.heldTurnText != null);
      expect(h.prompts, ['mismo mensaje']);

      h.controller.retry();
      await _waitFor(
        () => h.prompts.length == 2 && h.controller.heldTurnText != null,
      );

      expect(h.prompts, ['mismo mensaje', 'mismo mensaje']);
      expect(h.voice.captures, hasLength(1));
      await h.close();
    });

    test('a busy microphone gets its own care and Retry reopens it', () async {
      final h = await _harness();
      h.voice.captures.single.addError(
        const SttCaptureFailure(SttCaptureFailureKind.micBusy),
      );
      await _waitFor(() => h.controller.care == VoiceCare.micBusy);
      expect(h.controller.care!.blocking, isTrue);
      expect(h.controller.note, isNotNull);

      h.controller.retry();
      await _waitFor(() => h.voice.captures.length == 2);
      expect(h.controller.care, isNull);
      await h.close();
    });

    test('a transcription that timed out is told apart', () async {
      final h = await _harness();
      h.voice.captures.single.addError(const SttTimeoutError());
      await _waitFor(
        () => h.controller.care == VoiceCare.transcriptionTimedOut,
      );
      expect(h.controller.note, isNotNull);
      await h.close();
    });

    test('a recognizer that needs the network is told apart', () async {
      final h = await _harness();
      h.voice.captures.single.addError(
        const SttCaptureFailure(SttCaptureFailureKind.needsNetwork),
      );
      await _waitFor(() => h.controller.care == VoiceCare.needsNetwork);
      await h.close();
    });

    test(
      'a missing language pack is announced while listening goes on',
      () async {
        final h = await _harness(languageFellBack: true);
        expect(h.controller.phase, VoicePhase.listening);
        expect(h.controller.care, VoiceCare.languageFallback);
        expect(h.controller.care!.blocking, isFalse);

        // It informs about the capture only: the answer's phases get the line
        // back once the words are in.
        h.voice.captures.single.add(const SttResult('hola', true));
        await _waitFor(() => h.controller.care == null);
        await h.close();
      },
    );

    test('the background pause says so and Continue resumes it', () async {
      final h = await _harness();
      await h.controller.onAppBackgrounded();
      expect(h.controller.userPaused, isTrue);
      expect(h.controller.care, VoiceCare.pausedByBackground);

      // Coming back does not resume by itself.
      h.controller.onAppResumed(appUnlocked: true);
      expect(h.controller.userPaused, isTrue);
      expect(h.controller.care, VoiceCare.pausedByBackground);

      h.controller.playConversation();
      await _waitFor(() => !h.controller.userPaused);
      expect(h.controller.care, isNull);
      await h.close();
    });

    test('an App Lock suspension is not worded as the background', () async {
      final h = await _harness();
      await h.controller.suspendForPrivacy();
      expect(h.controller.userPaused, isTrue);
      expect(h.controller.care, isNull);
      await h.close();
    });

    test(
      'a route change while listening reopens the microphone once',
      () async {
        final events = StreamController<LiveAudioEvent>.broadcast();
        addTearDown(events.close);
        final h = await _harness(audioEvents: () => events.stream);
        expect(h.voice.captures, hasLength(1));

        events.add(LiveAudioEvent.focusLost);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(h.voice.captures, hasLength(1));

        events
          ..add(LiveAudioEvent.routeChanged)
          ..add(LiveAudioEvent.routeChanged);
        await _waitFor(() => h.voice.captures.length == 2);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(h.voice.captures, hasLength(2));
        expect(h.controller.care, VoiceCare.routeRestarted);
        await h.close();
      },
    );

    test('a route change while paused leaves the microphone closed', () async {
      final events = StreamController<LiveAudioEvent>.broadcast();
      addTearDown(events.close);
      final h = await _harness(audioEvents: () => events.stream);
      h.controller.pauseConversation();
      await _waitFor(() => h.controller.userPaused);

      events.add(LiveAudioEvent.routeChanged);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.voice.captures, hasLength(1));
      await h.close();
    });
  });
}
