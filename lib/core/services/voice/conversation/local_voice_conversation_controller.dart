import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../active_chat_service.dart';
import '../session/voice_ui_surface.dart';
import '../hermes_speech_stream.dart';
import '../spoken_text.dart';
import '../stt_engine.dart';
import '../voice_latency_trace.dart';
import '../voice_phase.dart';
import '../voice_service.dart';
import '../voice_settings.dart';
import 'full_duplex_barge_in_monitor.dart';
import 'streaming_narration_queue.dart';
import 'voice_conversation_runtime.dart';

const int _maxVoicePublicCommentaryRunes = 160;

String _voicePublicCommentary(String raw) {
  final clean = SpokenText.fromMarkdown(
    raw,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = clean.runes.toList(growable: false);
  if (runes.length <= _maxVoicePublicCommentaryRunes) return clean;
  return '${String.fromCharCodes(runes.take(_maxVoicePublicCommentaryRunes - 1)).trimRight()}…';
}

@visibleForTesting
bool voiceConversationMustSuspendFullDuplexInBackground({
  required bool continueWhenLocked,
}) => !continueWhenLocked;

/// Conversación local por turnos alineada con el chat visible:
/// STT APK → `ActiveChat.send/steer/enqueue` → respuesta visible → TTS APK.
///
/// No crea sesiones, talkers ni acuses auxiliares. Toda operación asíncrona
/// captura [_epoch]; Pausa, Stop, Cancel y X la rotan antes de tocar plugins.
class LocalVoiceConversationController extends ChangeNotifier
    implements VoiceUiSurface {
  LocalVoiceConversationController(
    this.voice, {
    FullDuplexBargeInMonitor? fullDuplexMonitor,
    Future<void> Function(Duration delay)? playbackTailDelay,
  }) : _fullDuplex = fullDuplexMonitor,
       _playbackTailDelay =
           playbackTailDelay ?? ((delay) => Future<void>.delayed(delay)) {
    voice.bargeInEnabled.addListener(_onBargeInPreferenceChanged);
  }

  final VoiceService voice;
  static const Duration _nativeSpeechFeedCadence = Duration(milliseconds: 150);
  // Desktop drains WebAudio plus 100 ms, requests AEC/NS and separately ignores
  // the first 500 ms after playback onset in its full-duplex VAD. Android cannot
  // treat an AudioTrack/MediaPlayer completion ACK as proof that loudspeaker
  // energy has disappeared from the physical microphone, so the half-duplex
  // handoff keeps this conservative Android acoustic-tail fence. Pixel QA owns
  // any later reduction; it is an adaptation of the Desktop guarantees, not a
  // claim that PLAYBACK_GRACE_MS is itself a post-playback timer upstream.
  static const Duration _playbackTailGuard = Duration(milliseconds: 500);
  final Future<void> Function(Duration delay) _playbackTailDelay;
  final StreamController<SttCheck> _unavailable =
      StreamController<SttCheck>.broadcast();

  ActiveChat? _chat;
  StreamSubscription<ActiveChatEvent>? _chatSub;
  StreamSubscription<SttResult>? _sttSub;
  Future<void>? _narrationTask;
  bool _narrationDriveRequested = false;
  Future<void>? _playbackTailGuardTask;
  int? _playbackTailGuardEpoch;
  Future<void>? _nativeSpeechPauseTask;
  Future<void>? _speechStopTask;
  StreamingNarrationQueue? _narration;
  VoiceConversationSpeechLease? _conversationSpeechLease;
  HermesSpeechStreamSession? _nativeSpeechStream;
  Timer? _nativeSpeechFeedTimer;
  int _nativeSpeechStreamSentRawLength = 0;
  int _nativeSpeechStreamSentCursor = 0;
  int _nativeSpeechStreamRevision = -1;
  bool _nativeSpeechStreamFallbackForTurn = false;
  bool _nativeSpeechStreamFinishRequested = false;
  Future<void>? _modelHandoff;
  Future<void>? _exitInFlight;
  FullDuplexBargeInMonitor? _fullDuplex;

  String _model = '';
  String _profile = '';
  Future<void> Function(String prompt)? _onBeforeSend;
  String _partialTranscript = '';
  String _userTranscript = '';
  int _epoch = 0;
  bool _captureFinalAccepted = false;
  bool _disposed = false;
  bool _listeningScheduled = false;
  int? _normalCaptureStartOperation;
  String? _announcedPendingInputKey;
  int _pendingInputAudioGeneration = 0;
  int _prewarmRevision = -1;
  int _prewarmStart = -1;
  int _prewarmEnd = -1;
  String? _prewarmText;
  int _bargeGeneration = 0;
  bool _bargeCaptureInFlight = false;
  bool _bargeTurnSubmitting = false;
  bool _bargeInterruptedPlayback = false;
  Future<void>? _bargeInterruptTask;
  Future<void>? _manualInterruptTask;
  bool _manualInterruptedPlayback = false;
  Future<void>? _userPauseReleaseTask;
  bool _sttReleasedForPause = false;
  bool _ttsReleasedForPause = false;
  Future<void>? _privacyPauseTask;
  bool _privacyCleanupInFlight = false;
  bool _fullDuplexPrivacySuspended = false;
  bool _privacyHardPaused = false;
  bool _privacyReleaseRequested = false;
  bool _fullDuplexLifecycleSuspended = false;
  VoiceLatencyTurn? _latencyTurn;
  String _latencyAssistantBaseline = '';
  int _latencyNarrationBaselineLength = 0;
  Object? _lastNotifiedUiProjection;
  final VoiceConversationRuntime _runtime = VoiceConversationRuntime();
  VoiceTurnBinding? _turnBinding;
  VoiceRuntimeToken? _normalCaptureToken;
  VoiceRuntimeToken? _bargeRuntimeToken;
  VoiceRuntimeToken? _playbackRuntimeToken;

  @override
  bool active = false;

  /// True only while Android audio resources are needed or their release is
  /// still awaiting a physical/plugin ACK. A logical paused conversation stays
  /// [active] without retaining the microphone/media FGS or local models.
  bool get audioLeaseRequired =>
      active &&
      (!userPaused || _userPauseReleaseTask != null || _privacyCleanupInFlight);

  bool get _fullDuplexCaptureSuspended =>
      _fullDuplexPrivacySuspended ||
      (_fullDuplexLifecycleSuspended &&
          voiceConversationMustSuspendFullDuplexInBackground(
            continueWhenLocked: voice.continueVoiceWhenLocked,
          ));

  @override
  VoicePhase get phase => _runtime.state.phase;

  @override
  String? note;

  @override
  String? activeTool;

  @override
  bool responding = false;

  @override
  bool paused = false;

  @override
  bool overlayMinimized = false;

  @override
  bool userPaused = false;

  @override
  bool get whisper => voice.sttRecordsThenTranscribes;

  @override
  String get partialTranscript => _partialTranscript;

  @override
  String get userTranscript => _userTranscript;

  @override
  String get assistantResponse => _chat?.assistantContent ?? '';

  @override
  String get publicCommentary {
    final commentaryEligible = switch (phase) {
      VoicePhase.thinking || VoicePhase.toolCall || VoicePhase.speaking => true,
      VoicePhase.listening ||
      VoicePhase.transcribing ||
      VoicePhase.waitingPermission ||
      VoicePhase.idle => false,
    };
    if (!active || !commentaryEligible) return '';
    final raw = _chat?.assistantPublicCommentary ?? '';
    if (raw.isEmpty) return '';
    return _voicePublicCommentary(raw);
  }

  @override
  bool get backendActive => _chat?.isStreaming ?? false;

  @override
  bool get spokenInterruptionArmed =>
      active &&
      voice.bargeInEnabled.value &&
      voice.fullDuplexTranscriptionAvailable &&
      !_fullDuplexCaptureSuspended &&
      !userPaused &&
      !paused &&
      (_fullDuplex?.armed ?? false);

  @override
  Stream<SttCheck> get unavailable => _unavailable.stream;

  String? get sessionId => active ? _chat?.serverSessionId : null;

  @visibleForTesting
  int get debugEpoch => _epoch;

  @visibleForTesting
  int get debugNarrationCursor => _narration?.cursor ?? 0;

  @visibleForTesting
  int get debugNarrationRevision => _narration?.revision ?? 0;

  @visibleForTesting
  bool get debugBargeCaptureInFlight => _bargeCaptureInFlight;

  @override
  bool ownsChat(ActiveChat chat) => active && identical(chat, _chat);

  @override
  ActiveChat? get ownerChat => active ? _chat : null;

  @override
  Future<void> enter({
    required ActiveChat chat,
    required String model,
    String profile = '',
    Future<void> Function(String prompt)? onBeforeSend,
  }) async {
    final pendingExit = _exitInFlight;
    if (pendingExit != null) await pendingExit;
    if (active || _disposed) return;
    final operation = ++_epoch;
    final ownerProfile = chat.bindSessionProfile(profile);
    active = true;
    _turnBinding = _runtime.start(
      backendRunning: chat.isStreaming,
      identity: _voiceIdentity(chat, ownerProfile),
    );
    _normalCaptureToken = null;
    _bargeRuntimeToken = null;
    _playbackRuntimeToken = null;
    _conversationSpeechLease = voice.beginConversationSpeechLease();
    note = null;
    activeTool = null;
    responding = chat.assistantNarrationContent.trim().isNotEmpty;
    paused = false;
    overlayMinimized = false;
    userPaused = false;
    _chat = chat;
    _model = model;
    _profile = ownerProfile;
    _onBeforeSend = onBeforeSend;
    _partialTranscript = '';
    _userTranscript = '';
    _modelHandoff = null;
    _prewarmRevision = -1;
    _prewarmStart = -1;
    _prewarmEnd = -1;
    _prewarmText = null;
    _nativeSpeechStream = null;
    _nativeSpeechPauseTask = null;
    _cancelNativeSpeechFeed();
    _nativeSpeechStreamSentRawLength = 0;
    _nativeSpeechStreamSentCursor = 0;
    _nativeSpeechStreamRevision = -1;
    _nativeSpeechStreamFallbackForTurn = false;
    _nativeSpeechStreamFinishRequested = false;
    _narrationDriveRequested = false;
    _bargeCaptureInFlight = false;
    _bargeTurnSubmitting = false;
    _bargeInterruptedPlayback = false;
    _bargeInterruptTask = null;
    _manualInterruptTask = null;
    _manualInterruptedPlayback = false;
    _userPauseReleaseTask = null;
    _sttReleasedForPause = false;
    _ttsReleasedForPause = false;
    _privacyCleanupInFlight = false;
    _bargeGeneration++;
    _latencyTurn = null;
    _narration = StreamingNarrationQueue(language: voice.voiceLang);
    _chatSub = chat.changes.listen(
      _onChatEvent,
      onDone: () => _onOwnerChatClosed(chat),
    );
    _notify();

    // Una aprobación ya visible no necesita abrir ni siquiera preparar el
    // micrófono. Además de ahorrar el recorder/modelo, evita que una captura se
    // cuele entre la entrada y la tarjeta de permiso. Cuando el backend resuelva
    // la aprobación, el final del turno volverá a programar la escucha normal.
    if (chat.pendingApproval != null) {
      if (chat.isStreaming) {
        _narration!.observe(chat.assistantNarrationContent);
      }
      _pauseForPendingApproval();
      return;
    }

    if (chat.isStreaming) {
      _narration!.observe(chat.assistantNarrationContent);
      unawaited(_armFullDuplexForTurn(beginResponseTurn: true));
      _driveNarrationIfNeeded();
      _notify();
      return;
    }
    await _openListening(operation);
  }

  Future<void> _openListening(
    int operation, {
    VoiceRuntimeToken? claimedCaptureToken,
  }) async {
    if (!_isCurrent(operation) ||
        userPaused ||
        _bargeCaptureInFlight ||
        (_normalCaptureStarting && claimedCaptureToken == null) ||
        _chat?.needsInput == true) {
      return;
    }
    await _disarmFullDuplex();
    if (!_isCurrent(operation) || userPaused || _bargeCaptureInFlight) return;

    final handoff = _modelHandoff;
    if (handoff != null) {
      await handoff;
      if (identical(_modelHandoff, handoff)) _modelHandoff = null;
      if (!_isCurrent(operation) || userPaused) return;
    }
    await voice.releaseTtsForListening();
    if (!_isCurrent(operation) || userPaused) return;

    final check = await voice.checkStt();
    if (!_isCurrent(operation)) return;
    if (!check.ready) {
      _runtime.pauseByUser();
      userPaused = true;
      note = _sttUnavailableNote(check);
      _unavailable.add(check);
      _notify();
      return;
    }
    if (!await voice.prepareForMicrophoneCapture()) {
      if (!_isCurrent(operation)) return;
      _runtime.pauseByUser();
      userPaused = true;
      note = _isEnglish
          ? 'The microphone is still being released.'
          : 'El micrófono todavía se está liberando.';
      _notify();
      return;
    }

    await _sttSub?.cancel();
    if (!_isCurrent(operation)) return;
    _sttSub = null;
    _captureFinalAccepted = false;
    _partialTranscript = '';
    // El final anterior solo se conserva durante la respuesta de Hermes. Al
    // abrir una captura nueva empieza otro turno y no debe confundirse con lo
    // que el recognizer está oyendo ahora.
    _userTranscript = '';
    note = null;
    activeTool = null;
    final captureToken = claimedCaptureToken ?? _runtime.claimNormalCapture();
    if (captureToken == null) return;
    _normalCaptureToken = captureToken;
    // El Future/Stream de un plugin solo confirma que se solicitó la captura.
    // Hasta el ACK causal del motor no proyectamos «Escuchando» ni permitimos
    // que un terminal duplicado abra un segundo recorder.
    _normalCaptureStartOperation = operation;
    _notify();

    _beginVoiceLatencyTurn(VoiceLatencyScenario.normal);
    try {
      final stream = voice.startDictation(
        onCaptureReady: () {
          if (!_isCurrent(operation) ||
              _normalCaptureStartOperation != operation) {
            return;
          }
          _normalCaptureStartOperation = null;
          if (!_runtime.confirmNormalCapture(captureToken)) return;
          _notify();
        },
        onSpeechEnd: () {
          if (!_isCurrent(operation) ||
              _captureFinalAccepted ||
              _normalCaptureStartOperation == operation) {
            return;
          }
          if (!_runtime.beginNormalTranscription(captureToken)) return;
          _latencyTurn?.mark(VoiceLatencyPoint.speechEndpoint);
          _notify();
        },
      );
      _sttSub = stream.listen(
        (result) => _onSttResult(operation, captureToken, result),
        onError: (Object error, StackTrace stack) {
          if (!_isCurrent(operation)) return;
          if (_normalCaptureStartOperation == operation) {
            _normalCaptureStartOperation = null;
          }
          if (identical(_normalCaptureToken, captureToken)) {
            _normalCaptureToken = null;
          }
          if (!_runtime.failNormalCapture(captureToken)) {
            _runtime.failTranscription(captureToken, rearm: false);
          }
          note = _isEnglish
              ? 'I could not understand the microphone.'
              : 'No pude entender el micrófono.';
          _notify();
        },
        onDone: () {
          if (!_isCurrent(operation) || _captureFinalAccepted) return;
          if (_normalCaptureStartOperation == operation) {
            _normalCaptureStartOperation = null;
          }
          if (identical(_normalCaptureToken, captureToken)) {
            _normalCaptureToken = null;
          }
          final finished =
              _runtime.finishNormalSilence(captureToken) ||
              _runtime.failTranscription(captureToken);
          if (!finished) return;
          note = _isEnglish ? 'I did not hear you.' : 'No te he oído.';
          _notify();
          _scheduleListening();
        },
      );
    } catch (error) {
      if (!_isCurrent(operation)) return;
      if (_normalCaptureStartOperation == operation) {
        _normalCaptureStartOperation = null;
      }
      if (identical(_normalCaptureToken, captureToken)) {
        _normalCaptureToken = null;
      }
      _runtime.failNormalCapture(captureToken);
      note = _isEnglish
          ? 'The microphone could not be started.'
          : 'No se pudo iniciar el micrófono.';
      _notify();
    }
  }

  void _onSttResult(
    int captureEpoch,
    VoiceRuntimeToken captureToken,
    SttResult result,
  ) {
    if (!_isCurrent(captureEpoch) || _captureFinalAccepted) return;
    _partialTranscript = result.text;
    if (!result.isFinal) return;
    _captureFinalAccepted = true;
    final text = result.text.trim();
    final subscription = _sttSub;
    _sttSub = null;
    unawaited(subscription?.cancel());
    _latencyTurn?.mark(VoiceLatencyPoint.sttFinal);
    if (text.isEmpty || isSpuriousIsolatedTranscript(text)) {
      // El endpoint idle de 12 s es mantenimiento del recorder, no un turno
      // del usuario. Una emisión aislada `y` observada en el Pixel se trata del
      // mismo modo: no subimos VAD ni bloqueamos respuestas reales `sí`/`no`.
      final finished =
          _runtime.state.transcriptionOwner == VoiceTranscriptionOwner.normal
          ? _runtime.finishNormalTranscription(captureToken, '') == null &&
                _runtime.state.transcriptionOwner ==
                    VoiceTranscriptionOwner.none
          : _runtime.finishNormalSilence(captureToken);
      if (!finished) return;
      if (identical(_normalCaptureToken, captureToken)) {
        _normalCaptureToken = null;
      }
      _normalCaptureStartOperation = null;
      _userTranscript = '';
      _partialTranscript = '';
      note = null;
      _notify();
      _scheduleListening();
      return;
    }
    if (isExactVoiceStopPhrase(text)) {
      unawaited(exit());
      return;
    }
    if (_runtime.state.transcriptionOwner != VoiceTranscriptionOwner.normal &&
        !_runtime.beginNormalTranscription(captureToken)) {
      return;
    }
    final turn = _runtime.finishNormalTranscription(captureToken, text);
    if (turn == null) return;
    _turnBinding = turn;
    if (identical(_normalCaptureToken, captureToken)) {
      _normalCaptureToken = null;
    }
    _normalCaptureStartOperation = null;
    final interruptTask = _manualInterruptTask;
    final interruptedPlayback = _manualInterruptedPlayback;
    _manualInterruptTask = null;
    _manualInterruptedPlayback = false;
    final submitEpoch = ++_epoch;
    _userTranscript = text;
    _partialTranscript = text;
    _notify();
    _modelHandoff = voice.prepareForNarration();
    if (interruptTask != null) _bargeTurnSubmitting = true;
    final submission = _submitTranscript(
      submitEpoch,
      turn,
      text,
      voicePlaybackInterrupted: interruptedPlayback,
      interruptTask: interruptTask,
    );
    unawaited(
      submission.whenComplete(() {
        if (interruptTask != null) {
          _bargeTurnSubmitting = false;
          if (_runtime.state.rearmReady) _scheduleListening();
        }
      }),
    );
  }

  Future<void> _submitTranscript(
    int operation,
    VoiceTurnBinding turn,
    String text, {
    bool voicePlaybackInterrupted = false,
    Future<void>? interruptTask,
  }) async {
    if (!_isCurrent(operation) || turn != _turnBinding) return;
    if (text.isEmpty) {
      note = _isEnglish ? 'I did not hear you.' : 'No te he oído.';
      _scheduleListening();
      return;
    }

    try {
      if (interruptTask != null) {
        await interruptTask;
        if (!_isCurrent(operation)) return;
      }
      // El autotítulo es metadato local best-effort. Esperar SharedPreferences
      // y SessionArchive aquí mantenía la UI en «Transcribiendo tu voz…» y
      // retrasaba el envío aunque el transcript ya fuese definitivo.
      final metadataPerf = Stopwatch()..start();
      try {
        final metadataTask = _onBeforeSend?.call(text);
        if (metadataTask != null) {
          unawaited(
            metadataTask.then<void>(
              (_) => debugPrint(
                '[VOICE-PERF] voice.metadata.ready_ms='
                '${metadataPerf.elapsedMilliseconds}',
              ),
              onError: (Object error, StackTrace stackTrace) {
                debugPrint(
                  '[VOICE-PERF] voice.metadata.failed_ms='
                  '${metadataPerf.elapsedMilliseconds} '
                  'error=${error.runtimeType}',
                );
              },
            ),
          );
        }
      } catch (error) {
        debugPrint(
          '[VOICE-PERF] voice.metadata.failed_sync '
          'error=${error.runtimeType}',
        );
      }
      if (!_isCurrent(operation)) return;
      final chat = _chat;
      if (chat == null) return;
      responding = false;
      note = null;
      _latencyTurn?.mark(VoiceLatencyPoint.clientOptimistic);
      _notify();

      if (!voicePlaybackInterrupted && chat.isStreaming) {
        _latencyTurn?.mark(VoiceLatencyPoint.submitStarted);
        try {
          // Hermes Desktop corrige un run vivo con `session.redirect`. Cancelar
          // y enviar inmediatamente abría una carrera con el drenaje del run:
          // el backend aceptaba el stop, pero podía perder el reemplazo.
          await chat.steer(text);
          if (!_isCurrent(operation) || turn != _turnBinding) return;
          _runtime.markBackendRunning(turn);
          _markLatencySubmitAccepted(chat, lifecycleAcknowledged: true);
          // `session.redirect` conserva el mismo run, así que no llegará un
          // `started` que reinicie la cola. Omite lo ya visible antes de la
          // interrupción y narra solo la continuación posterior.
          _narration?.resumeFromVisibleEnd();
        } catch (error) {
          if (!_isCurrent(operation) || turn != _turnBinding) return;
          // Gateways sin redirect conservan el texto en la cola. Nunca hacemos
          // cancel -> send sin esperar: el siguiente turno se drena cuando el
          // run actual termina y la corrección no se pierde.
          chat.enqueue(text);
          _runtime.markSubmissionQueued(turn);
        }
        _notify();
        // El monitor consume una captura por interjección. Rearmarlo después
        // de redirect/cola permite otra corrección en el mismo run.
        unawaited(_armFullDuplexForTurn(beginResponseTurn: true));
        return;
      }

      // Barge-in es una mejora opcional y su AudioRecord puede tardar en abrir
      // en algunos Android. El prompt debe salir en cuanto el transcript es
      // definitivo; el monitor termina de armarse en paralelo.
      unawaited(_armFullDuplexForTurn(beginResponseTurn: true));
      _latencyTurn?.mark(VoiceLatencyPoint.submitStarted);
      final accepted = await chat.send(
        fullText: text,
        model: _model,
        // Voz y teclado comparten exactamente el mismo contexto. El modo voz
        // no añade instrucciones ocultas de brevedad ni cambia la personalidad
        // del agente; su única diferencia es entrada/salida de audio.
        history: chat.buildHistory(),
        profile: _profile,
        voicePlaybackInterrupted: voicePlaybackInterrupted,
      );
      if (!_isCurrent(operation) || turn != _turnBinding) return;
      if (accepted) {
        _runtime.markBackendRunning(turn);
        _markLatencySubmitAccepted(chat);
      } else {
        _runtime.failSubmission(turn);
        _scheduleListening();
      }
    } catch (error) {
      if (!_isCurrent(operation) || turn != _turnBinding) return;
      _runtime.failSubmission(turn);
      note = _isEnglish
          ? 'The message could not be sent.'
          : 'No se pudo enviar el mensaje.';
      _notify();
      _scheduleListening();
    }
  }

  Future<void> _armFullDuplexForTurn({bool beginResponseTurn = false}) async {
    if (!active ||
        _disposed ||
        !voice.bargeInEnabled.value ||
        userPaused ||
        paused ||
        _fullDuplexCaptureSuspended ||
        _bargeCaptureInFlight ||
        (!beginResponseTurn &&
            _fullDuplex?.playbackUnsafeLatched == true &&
            _narrationAudioInFlight) ||
        !voice.fullDuplexTranscriptionAvailable ||
        _chat?.needsInput == true) {
      return;
    }
    final monitor = _fullDuplex ??= FullDuplexBargeInMonitor(
      source: VoiceServiceFullDuplexCaptureSource(voice),
    );
    if (beginResponseTurn) monitor.beginResponseTurn();
    final turn = _turnBinding;
    if (turn == null) return;
    final currentToken = _bargeRuntimeToken;
    if (currentToken != null &&
        currentToken.turn == turn &&
        (_runtime.state.captureOwner == VoiceCaptureOwner.fullDuplexStarting ||
            _runtime.state.captureOwner == VoiceCaptureOwner.fullDuplex)) {
      return;
    }
    final runtimeToken = _runtime.requestBargeMonitor(turn);
    if (runtimeToken == null) return;
    _bargeRuntimeToken = runtimeToken;
    final generation = ++_bargeGeneration;
    var armed = false;
    try {
      armed = await monitor.arm(
        // Hermes Desktop mantiene un solo monitor durante el turno completo:
        // generación y playback comparten detector, pre-roll y callbacks.
        onSpeechStart: () => _onFullDuplexSpeechStart(generation, runtimeToken),
        onSpeechAboveThreshold: () {
          _latencyTurn?.observeSpeechAboveThreshold();
        },
        onSpeechEndpoint: () {
          _latencyTurn?.mark(VoiceLatencyPoint.speechEndpoint);
        },
        onTranscriptionStart: () =>
            _onFullDuplexTranscriptionStart(generation, runtimeToken),
        onTranscript: (text) =>
            _onFullDuplexTranscript(generation, runtimeToken, text),
      );
    } catch (_) {
      // Full-duplex es una mejora opcional. Un Android/servidor antiguo o un
      // canal nativo ausente jamás puede impedir el envío normal del turno.
      armed = false;
    }
    if (armed) {
      armed = _runtime.confirmBargeMonitor(runtimeToken);
      if (!armed) {
        await monitor.disarm();
      }
    } else {
      _runtime.releaseBargeMonitor(runtimeToken);
    }
    if (!armed && generation == _bargeGeneration) {
      // Barge-in is optional and fail-closed. Normal turn-taking remains live.
      _bargeCaptureInFlight = false;
      if (identical(_bargeRuntimeToken, runtimeToken)) {
        _bargeRuntimeToken = null;
      }
    }
    if (generation == _bargeGeneration) {
      _notify();
      // `send=false` o un terminal pueden ganar la carrera mientras el
      // recorder full-duplex termina de abrir. El monitor ya no tiene un turno
      // que vigilar: ciérralo y honra la solicitud de rearme normal.
      if (_runtimeMayScheduleListening) _scheduleListening();
    }
  }

  void _onFullDuplexSpeechStart(
    int generation,
    VoiceRuntimeToken runtimeToken,
  ) {
    final chat = _chat;
    final backendWasActive = chat?.isStreaming ?? false;
    final playbackWasActive =
        (_fullDuplex?.playbackActive ?? false) ||
        _narrationAudioInFlight ||
        phase == VoicePhase.speaking;
    if (generation != _bargeGeneration ||
        !active ||
        _disposed ||
        userPaused ||
        paused ||
        chat == null ||
        (!backendWasActive && !playbackWasActive) ||
        !_runtime.beginBargeSpeech(runtimeToken)) {
      return;
    }
    final playbackDrainToken = _playbackRuntimeToken;
    _beginVoiceLatencyTurn(VoiceLatencyScenario.bargeIn);
    _bargeCaptureInFlight = true;
    // Hermes Desktop trata speech_start como una interrupción del turno
    // completo: si el backend aún genera, usa inmediatamente la misma costura
    // que Stop aunque el primer bloque TTS todavía no haya empezado.
    _bargeInterruptedPlayback = playbackWasActive || backendWasActive;
    _bargeInterruptTask = backendWasActive
        ? _interruptBackendForCapture(chat, runtimeToken.turn)
        : null;
    if (playbackWasActive) {
      _invalidateNarrationPlayback(playbackDrainToken: playbackDrainToken);
    }
    // La voz ya detectada manda también durante «Pensando». Silenciar la cola
    // evita que un delta tardío arranque TTS mientras termina la captura.
    _narration?.silence();
    activeTool = null;
    note = null;
    _notify();
    // Paridad Desktop: el VAD corta reproducción y turno antes de esperar al
    // STT; la transcripción se envía después como el siguiente prompt.
  }

  void _onFullDuplexTranscriptionStart(
    int generation,
    VoiceRuntimeToken runtimeToken,
  ) {
    if (generation != _bargeGeneration ||
        !active ||
        _disposed ||
        userPaused ||
        paused ||
        !_bargeCaptureInFlight ||
        !_runtime.beginBargeTranscription(runtimeToken)) {
      return;
    }
    // Desktop conserva thinking/speaking mientras el usuario aún habla. Solo
    // publica transcribing después del endpoint, con el recorder ya cerrado y
    // justo antes de iniciar STT sobre el WAV capturado.
    _latencyTurn?.mark(VoiceLatencyPoint.sttStarted);
    note = null;
    _notify();
  }

  Future<void> _onFullDuplexTranscript(
    int generation,
    VoiceRuntimeToken runtimeToken,
    String? transcript,
  ) async {
    if (generation != _bargeGeneration ||
        !active ||
        _disposed ||
        userPaused ||
        paused ||
        !identical(_bargeRuntimeToken, runtimeToken)) {
      return;
    }
    _bargeCaptureInFlight = false;
    final interruptedPlayback = _bargeInterruptedPlayback;
    final interruptTask = _bargeInterruptTask;
    _bargeInterruptedPlayback = false;
    _bargeInterruptTask = null;
    final text = transcript?.trim() ?? '';
    _latencyTurn?.mark(VoiceLatencyPoint.sttFinal);
    if (text.isEmpty || isSpuriousIsolatedTranscript(text)) {
      _runtime.finishBargeTranscription(runtimeToken, '');
      if (_runtime.state.transcriptionOwner != VoiceTranscriptionOwner.none) {
        return;
      }
      _bargeRuntimeToken = null;
      note = _isEnglish ? 'I did not hear you.' : 'No te he oído.';
      _notify();
      _scheduleListening();
      return;
    }
    if (isExactVoiceStopPhrase(text)) {
      await exit();
      return;
    }
    final turn = _runtime.finishBargeTranscription(runtimeToken, text);
    if (turn == null) return;
    _bargeRuntimeToken = null;
    _turnBinding = turn;
    _userTranscript = text;
    _bargeTurnSubmitting = true;
    final operation = ++_epoch;
    try {
      await _submitTranscript(
        operation,
        turn,
        text,
        voicePlaybackInterrupted: interruptedPlayback,
        interruptTask: interruptTask,
      );
    } finally {
      _bargeTurnSubmitting = false;
      if (active &&
          !backendActive &&
          phase == VoicePhase.idle &&
          _chat?.needsInput != true) {
        _scheduleListening();
      }
    }
  }

  Future<void> _disarmFullDuplex() async {
    final monitor = _fullDuplex;
    final runtimeToken = _bargeRuntimeToken;
    if (monitor == null) {
      if (runtimeToken != null) {
        _runtime.releaseBargeMonitor(runtimeToken);
        if (identical(_bargeRuntimeToken, runtimeToken)) {
          _bargeRuntimeToken = null;
        }
      }
      return;
    }
    final wasArmed = spokenInterruptionArmed;
    try {
      await monitor.disarm();
    } catch (_) {
      // A native generation is already fenced even if teardown reports late.
    }
    if (runtimeToken != null) {
      _runtime.releaseBargeMonitor(runtimeToken);
      if (identical(_bargeRuntimeToken, runtimeToken)) {
        _bargeRuntimeToken = null;
      }
    }
    if (wasArmed || spokenInterruptionArmed) _notify();
  }

  void _onBargeInPreferenceChanged() {
    if (_disposed) return;
    if (!voice.bargeInEnabled.value) {
      _bargeGeneration++;
      _bargeCaptureInFlight = false;
      _bargeTurnSubmitting = false;
      _bargeInterruptedPlayback = false;
      _bargeInterruptTask = null;
      _notify();
      unawaited(_disarmFullDuplex());
      return;
    }
    if (active &&
        !userPaused &&
        !paused &&
        !_fullDuplexCaptureSuspended &&
        (_chat?.isStreaming == true || phase == VoicePhase.speaking)) {
      unawaited(_armFullDuplexForTurn());
    }
  }

  static bool isExactVoiceStopPhrase(String transcript) {
    // Conserva el matcher cerrado de Desktop y añade únicamente la orden local
    // inequívoca documentada para la sesión española. Sigue siendo coincidencia
    // del utterance completo: «cállate y dime otra cosa» nunca se consume.
    final normalized = _normalizeVoiceUtterance(transcript);
    if (normalized.isEmpty) return false;
    var withoutAddress = normalized;
    for (final prefix in const <String>['hermes', 'ok', 'okay', 'hey']) {
      if (normalized != prefix && normalized.startsWith('$prefix ')) {
        withoutAddress = normalized.substring(prefix.length + 1).trim();
        break;
      }
    }
    const phrases = <String>{
      'stop',
      'stop listening',
      'stop it',
      'stop please',
      'please stop',
      'stop stop',
      'that is all',
      "that's all",
      'never mind',
      'nevermind',
      'end conversation',
      'end the conversation',
      'goodbye',
      'good bye',
      'bye',
      'cancel',
      'cállate',
      'callate',
    };
    return phrases.contains(normalized) || phrases.contains(withoutAddress);
  }

  /// Pixel QA observed ambient noise being finalized as the isolated Spanish
  /// conjunction `y`. Reject only that exact normalized utterance: raising the
  /// VAD threshold would also lose quiet real speech, while broader short-text
  /// filters would incorrectly discard valid `sí` and `no` answers.
  @visibleForTesting
  static bool isSpuriousIsolatedTranscript(String transcript) =>
      _normalizeVoiceUtterance(transcript) == 'y';

  static String _normalizeVoiceUtterance(String transcript) => transcript
      .toLowerCase()
      .replaceAll(RegExp(r'[.,!?;:…]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  VoiceLatencyRoute get _voiceLatencyRoute =>
      voice.activeVoiceRoute?.kind == VoiceRouteKind.server
      ? VoiceLatencyRoute.server
      : VoiceLatencyRoute.phone;

  VoiceSttTopology _voiceSttTopology(VoiceLatencyScenario scenario) {
    if (scenario == VoiceLatencyScenario.bargeIn || voice.nativeVoiceActive) {
      return VoiceSttTopology.recordThenTranscribe;
    }
    return switch (voice.effectiveConversationSttEngine) {
      SttEngineKind.system ||
      SttEngineKind.server => VoiceSttTopology.streaming,
      SttEngineKind.whisper ||
      SttEngineKind.hermesServer ||
      SttEngineKind.sherpaLive => VoiceSttTopology.recordThenTranscribe,
    };
  }

  VoiceLatencyAvailability get _voiceLastAboveAvailability =>
      voice.effectiveConversationSttEngine == SttEngineKind.system
      ? VoiceLatencyAvailability.unavailable
      : VoiceLatencyAvailability.measured;

  void _beginVoiceLatencyTurn(VoiceLatencyScenario scenario) {
    _latencyTurn = VoiceLatencyTrace.current.beginTurn(
      route: _voiceLatencyRoute,
      scenario: scenario,
      sttTopology: _voiceSttTopology(scenario),
      lastAboveAvailability: _voiceLastAboveAvailability,
    );
    _latencyAssistantBaseline = _chat?.assistantContent ?? '';
    _latencyNarrationBaselineLength = _narration?.rawObserved.length ?? 0;
  }

  void _markLatencySubmitAccepted(
    ActiveChat chat, {
    bool lifecycleAcknowledged = false,
  }) {
    if (_latencyTurn?.mark(VoiceLatencyPoint.submitAccepted) != true) return;
    // Anything observed while the submit/redirect was still pending belongs
    // to the previous response and cannot seed the new turn's latency.
    _latencyAssistantBaseline = chat.assistantContent;
    _latencyNarrationBaselineLength = _narration?.rawObserved.length ?? 0;
    if (lifecycleAcknowledged) {
      _latencyTurn?.mark(VoiceLatencyPoint.backendAccepted);
      _latencyTurn?.mark(VoiceLatencyPoint.backendLifecycleAck);
    } else {
      _markFirstBackendLifecycle(chat);
    }
  }

  void _markFirstBackendLifecycle(ActiveChat chat) {
    // `started` is an optimistic local UI event. Desktop is acknowledged only
    // after message.start/session.info running; REST only after a real run id.
    if (chat.desktopTurnStartedAt == null && chat.currentRunId == null) return;
    _latencyTurn?.mark(VoiceLatencyPoint.backendAccepted);
    _latencyTurn?.mark(VoiceLatencyPoint.backendLifecycleAck);
  }

  void _markFirstAcceptedBackendText(ActiveChatEvent event, ActiveChat chat) {
    final mayCarryAssistantText =
        event == ActiveChatEvent.token ||
        event == ActiveChatEvent.done ||
        event == ActiveChatEvent.error ||
        event == ActiveChatEvent.cancelled;
    if (!mayCarryAssistantText) return;
    final content = chat.assistantContent;
    final acceptedSuffix = content.startsWith(_latencyAssistantBaseline)
        ? content.substring(_latencyAssistantBaseline.length)
        : content;
    if (acceptedSuffix.trim().isEmpty) return;
    // Un primer texto server-authored prueba aceptación aunque el transporte
    // no publique un ACK lifecycle separado.
    _latencyTurn?.mark(VoiceLatencyPoint.backendAccepted);
    _latencyTurn?.mark(VoiceLatencyPoint.firstAcceptedText);
    _latencyTurn?.mark(VoiceLatencyPoint.backendTextAccepted);
  }

  void _markFirstRawSpeechSuffix(
    StreamingNarrationQueue narration,
    int previousRawLength,
    VoiceLatencySample? appendLatency,
  ) {
    if (narration.rawObserved.length <= previousRawLength ||
        narration.rawObserved.length <= _latencyNarrationBaselineLength) {
      return;
    }
    appendLatency?.accept();
    _latencyTurn?.mark(VoiceLatencyPoint.firstRawSpeechSuffix);
    // Hermes Agent does not currently expose its first synthesizable chunk as
    // an observable protocol signal. Preserve that gap explicitly.
    _latencyTurn?.mark(VoiceLatencyPoint.firstSynthesizableChunkUnavailable);
  }

  void _markFirstTtsFeed() =>
      _latencyTurn?.mark(VoiceLatencyPoint.ttsFirstFeed);

  void _onChatEvent(ActiveChatEvent event) {
    if (!active) return;
    // A context-metrics refresh has no conversational or audio meaning.
    if (event == ActiveChatEvent.responseMetrics) return;
    final chat = _chat;
    final narration = _narration;
    if (chat == null || narration == null) return;

    _markFirstBackendLifecycle(chat);
    _markFirstAcceptedBackendText(event, chat);

    switch (event) {
      case ActiveChatEvent.started:
        // Una cola puede iniciar el turno siguiente mientras todavía termina
        // una frase del anterior. Invalida esa reproducción antes de reutilizar
        // la misma cola para que nunca se mezclen dos respuestas. `started`
        // llega de forma síncrona dentro de `chat.send()`: no puede rotar la
        // operación que está esperando ese mismo ACK o su resultado se trataría
        // como stale y el runtime quedaría atascado en `submitting`.
        if (_narrationAudioInFlight) {
          _invalidateNarrationPlayback(invalidateOperation: false);
        }
        narration.reset();
        _cancelNativeSpeechFeed();
        _nativeSpeechStreamSentRawLength = 0;
        _nativeSpeechStreamSentCursor = 0;
        _nativeSpeechStreamRevision = -1;
        _nativeSpeechStreamFallbackForTurn = false;
        _nativeSpeechStreamFinishRequested = false;
        if (userPaused) narration.pause();
        responding = false;
        activeTool = null;
        final startedTurn = _turnBinding;
        if (startedTurn != null) {
          _runtime.markBackendRunning(startedTurn);
          _runtime.markToolActive(startedTurn, active: false);
        }
        if (!userPaused) {
          unawaited(_armFullDuplexForTurn(beginResponseTurn: true));
        }
      case ActiveChatEvent.token:
        responding = true;
        _resumeAfterApprovalIfResolved();
        final tokenRawBefore = narration.rawObserved.length;
        final tokenAppendLatency = _latencyTurn?.beginSuffixAppendLatency();
        final update = narration.observe(chat.assistantNarrationContent);
        _markFirstRawSpeechSuffix(
          narration,
          tokenRawBefore,
          tokenAppendLatency,
        );
        _reconcileNarrationRevision(update);
        _driveNarrationIfNeeded();
        _maybePrewarmNextBatch();
      case ActiveChatEvent.toolProgress:
      case ActiveChatEvent.subagentActivity:
        _resumeAfterApprovalIfResolved();
        final hasActiveSubagent = chat.subagentActivities.any(
          (activity) => !activity.isTerminal,
        );
        final liveToolLabel =
            chat.activeVoiceToolLabel ??
            (hasActiveSubagent ? 'delegate_task' : null);
        activeTool = liveToolLabel;
        final progressRawBefore = narration.rawObserved.length;
        final progressAppendLatency = _latencyTurn?.beginSuffixAppendLatency();
        final progressUpdate = narration.observe(
          chat.assistantNarrationContent,
        );
        _markFirstRawSpeechSuffix(
          narration,
          progressRawBefore,
          progressAppendLatency,
        );
        if (progressUpdate.queueChanged) {
          responding = true;
          _reconcileNarrationRevision(progressUpdate);
          _driveNarrationIfNeeded();
          _maybePrewarmNextBatch();
        }
        if (chat.needsInput) {
          // Una aprobación/pregunta pendiente manda sobre cualquier progreso
          // tardío de la herramienta. En el Pixel esos eventos devolvían la
          // superficie a toolCall y ocultaban "Revisar".
          _pauseForPendingApproval();
        } else if (!userPaused && phase != VoicePhase.waitingPermission) {
          // Android conserva visible la categoría que Desktop deja en el chat;
          // la voz queda reservada al comentario assistant público y al final.
          final toolTurn = _turnBinding;
          if (toolTurn != null) {
            _runtime.markBackendRunning(toolTurn);
            _runtime.markToolActive(toolTurn, active: liveToolLabel != null);
          }
        }
      case ActiveChatEvent.approvalRequest:
      case ActiveChatEvent.interactiveRequest:
        _pauseForPendingApproval();
      case ActiveChatEvent.done:
        activeTool = null;
        final doneTurn = _turnBinding;
        if (doneTurn != null && !_bargeTurnSubmitting) {
          _runtime.markToolActive(doneTurn, active: false);
          _runtime.markBackendTerminal(doneTurn);
        }
        final doneRawBefore = narration.rawObserved.length;
        final doneAppendLatency = _latencyTurn?.beginSuffixAppendLatency();
        final update = narration.observe(
          _terminalNarrationContent(chat),
          terminal: true,
        );
        _markFirstRawSpeechSuffix(narration, doneRawBefore, doneAppendLatency);
        _reconcileNarrationRevision(update);
        _driveNarrationIfNeeded();
        _maybePrewarmNextBatch();
        if (!narration.hasPending && narration.silenced) {
          _scheduleListening();
        }
      case ActiveChatEvent.error:
        activeTool = null;
        final errorTurn = _turnBinding;
        if (errorTurn != null && !_bargeTurnSubmitting) {
          _runtime.markToolActive(errorTurn, active: false);
          _runtime.markBackendTerminal(errorTurn);
        }
        if (chat.assistantContent.trim().isEmpty) {
          note = _isEnglish
              ? 'The response was interrupted.'
              : 'La respuesta se interrumpió.';
        }
        final errorRawBefore = narration.rawObserved.length;
        final errorAppendLatency = _latencyTurn?.beginSuffixAppendLatency();
        final update = narration.observe(
          _terminalNarrationContent(chat),
          terminal: true,
        );
        _markFirstRawSpeechSuffix(
          narration,
          errorRawBefore,
          errorAppendLatency,
        );
        _reconcileNarrationRevision(update);
        _driveNarrationIfNeeded();
        _maybePrewarmNextBatch();
        if (!narration.hasPending) _scheduleListening();
      case ActiveChatEvent.cancelled:
        activeTool = null;
        final cancelledTurn = _turnBinding;
        if (cancelledTurn != null && !_bargeTurnSubmitting) {
          _runtime.markToolActive(cancelledTurn, active: false);
          _runtime.markBackendTerminal(cancelledTurn);
        }
        final cancelledRawBefore = narration.rawObserved.length;
        final cancelledAppendLatency = _latencyTurn?.beginSuffixAppendLatency();
        narration.observe(chat.assistantNarrationContent, terminal: true);
        _markFirstRawSpeechSuffix(
          narration,
          cancelledRawBefore,
          cancelledAppendLatency,
        );
        if (!_bargeCaptureInFlight) _scheduleListening();
      case ActiveChatEvent.connected:
      case ActiveChatEvent.waiting:
        _resumeAfterApprovalIfResolved();
        if (chat.needsInput) {
          _pauseForPendingApproval();
        } else if (!userPaused && phase != VoicePhase.speaking) {
          final waitingTurn = _turnBinding;
          if (waitingTurn != null && chat.isStreaming) {
            _runtime.markBackendRunning(waitingTurn);
          }
        }
      case ActiveChatEvent.queueChanged:
      case ActiveChatEvent.messagesHydrated:
      case ActiveChatEvent.earlierMessagesLoaded:
      case ActiveChatEvent.responseMetrics:
      case ActiveChatEvent.sessionInfo:
        break;
    }
    _notify();
  }

  void _reconcileNarrationRevision(StreamingNarrationUpdate update) {
    if (!update.revisionChanged || !_narrationAudioInFlight) return;
    final nativeStream = _nativeSpeechStream;
    if (nativeStream != null) {
      // Un speak-stream ya recibió texto incremental y no expone una frontera
      // textual audible para reconciliarlo sin duplicar. Conserva aquí el stop
      // seguro existente. El fallback por locuciones sí conoce su lote atómico:
      // termina el que el motor ya aceptó y continúa después con la revisión
      // autoritativa desde el cursor que calculó StreamingNarrationQueue.
      _invalidateNarrationPlayback();
      return;
    }
    // La revisión nueva ya no conserva la valla del lote provisional que aún
    // suena: su siguiente trabajo empieza exactamente en `cursor`. Sintetízalo
    // durante ese audio viejo para que el cambio herramienta→final no pague la
    // petición TTS completa en silencio cuando termine la locución aceptada.
    final narration = _narration;
    if (narration != null) {
      _reserveNarrationPrewarm(narration, narration.cursor);
    }
  }

  void _onOwnerChatClosed(ActiveChat owner) {
    if (!active || _disposed || !identical(_chat, owner)) return;
    unawaited(exit());
  }

  void _driveNarrationIfNeeded() {
    if (!active || userPaused || paused) return;
    final narration = _narration;
    if (narration == null || narration.silenced) return;
    if (_narrationTask != null) {
      // Conserva únicamente una petición causal llegada mientras el driver
      // estaba ocupado. Un owner de playback en `draining` no es trabajo
      // nuevo: relanzarlo desde su propio finally crea un bucle de microtareas
      // que impide que llegue precisamente el ACK nativo que lo desbloquea.
      _narrationDriveRequested = true;
      return;
    }
    _narrationDriveRequested = false;
    if (voice.nativeSpeechStreamingAvailable &&
        !_nativeSpeechStreamFallbackForTurn) {
      // Hermes Desktop abre un único speak-stream para toda la respuesta y
      // entrega sufijos crudos conforme llegan. El servidor es quien corta y
      // limpia cada frase; esperar aquí a la puntuación añadía TTFA móvil.
      final hasRawDelta =
          narration.rawObserved.length > _nativeSpeechStreamSentRawLength;
      final mustFinish =
          narration.terminal &&
          _nativeSpeechStream != null &&
          !_nativeSpeechStreamFinishRequested;
      if (_nativeSpeechStream == null || narration.terminal) {
        _cancelNativeSpeechFeed();
        if (hasRawDelta || mustFinish) _driveNativeSpeechStreamIfNeeded();
      } else if (hasRawDelta) {
        _scheduleNativeSpeechFeed();
      } else if (mustFinish) {
        _driveNativeSpeechStreamIfNeeded();
      }
      if (!hasRawDelta &&
          !mustFinish &&
          narration.terminal &&
          !backendActive &&
          !_narrationAudioInFlight) {
        _scheduleListening();
      }
      return;
    }
    // Desktop no convierte la ausencia de PCM del speak-stream en una sucesión
    // de POST por frases: conserva el turno, espera `message.complete` y habla
    // la respuesta pública pendiente una sola vez. Esto cubre tanto el frame
    // oficial `fallback` como un endpoint WS ausente/deshabilitado. Las rutas
    // locales mantienen su dispatcher incremental.
    if (_usesNativeTerminalFallback && (!narration.terminal || backendActive)) {
      return;
    }
    if (!narration.hasPending) {
      if (narration.terminal && !backendActive) _scheduleListening();
      return;
    }
    final operation = _epoch;
    late final Future<void> task;
    task = _driveNarration(operation).whenComplete(() {
      if (identical(_narrationTask, task)) _narrationTask = null;
      final driveRequested = _narrationDriveRequested;
      _narrationDriveRequested = false;
      // Pause/reconciliación rotan la epoch mientras stopSpeaking despierta la
      // espera vieja. Play puede llegar antes de este finally: al quedar libre
      // el propietario, la petición causal retenida vuelve a evaluar la epoch
      // ACTUAL sin convertir un drain pendiente en polling infinito.
      if (!active || _disposed || userPaused || paused) return;
      if (driveRequested && (_narration?.hasPending ?? false)) {
        _driveNarrationIfNeeded();
      } else if (_narration?.terminal == true &&
          !backendActive &&
          !(_narration?.hasPending ?? false)) {
        _scheduleListening();
      } else if (backendActive && phase == VoicePhase.speaking) {
        final turn = _turnBinding;
        if (turn != null) {
          _runtime.markBackendRunning(turn);
          _runtime.markToolActive(turn, active: activeTool != null);
        }
        _notify();
      }
    });
    _narrationTask = task;
  }

  bool get _usesNativeTerminalFallback =>
      voice.nativeVoiceActive &&
      (_nativeSpeechStreamFallbackForTurn ||
          !voice.nativeSpeechStreamingAvailable);

  String _terminalNarrationContent(ActiveChat chat) {
    if (!_usesNativeTerminalFallback) return chat.assistantNarrationContent;
    final authoritative = chat.assistantContent.trim();
    return authoritative.isEmpty
        ? chat.assistantNarrationContent
        : authoritative;
  }

  void _scheduleNativeSpeechFeed() {
    if (_nativeSpeechFeedTimer != null) return;
    late final Timer timer;
    timer = Timer(_nativeSpeechFeedCadence, () {
      if (identical(_nativeSpeechFeedTimer, timer)) {
        _nativeSpeechFeedTimer = null;
      }
      if (!active || _disposed || userPaused || paused) return;
      _driveNativeSpeechStreamIfNeeded();
    });
    _nativeSpeechFeedTimer = timer;
  }

  void _cancelNativeSpeechFeed() {
    _nativeSpeechFeedTimer?.cancel();
    _nativeSpeechFeedTimer = null;
  }

  void _driveNativeSpeechStreamIfNeeded() {
    if (_narrationTask != null) return;
    final operation = _epoch;
    late final Future<void> task;
    task = _driveNativeSpeechStream(operation).whenComplete(() {
      if (identical(_narrationTask, task)) _narrationTask = null;
      final driveRequested = _narrationDriveRequested;
      _narrationDriveRequested = false;
      if (!active || _disposed || userPaused || paused) return;
      final narration = _narration;
      if (narration == null) return;
      if (driveRequested) {
        _driveNarrationIfNeeded();
      } else if (_nativeSpeechStreamFallbackForTurn && narration.hasPending) {
        _driveNarrationIfNeeded();
      } else if (_nativeSpeechStream != null &&
          (_nativeSpeechStreamSentRawLength < narration.rawObserved.length ||
              (narration.terminal && !_nativeSpeechStreamFinishRequested))) {
        _driveNarrationIfNeeded();
      }
    });
    _narrationTask = task;
  }

  Future<void> _driveNativeSpeechStream(int operation) async {
    final narration = _narration;
    if (narration == null || !_isCurrent(operation)) return;
    var session = _nativeSpeechStream;
    var playbackToken = _playbackRuntimeToken;
    if (session == null) {
      playbackToken ??= _preparePlaybackForCurrentTurn();
      if (playbackToken == null) return;
      final handoff = _modelHandoff ??= voice.prepareForNarration();
      await handoff;
      if (!_isCurrent(operation) || userPaused || paused) {
        _failPlaybackPreparation(playbackToken, rearm: false);
        return;
      }
      session = await voice.startNativeSpeechStream();
      if (!_isCurrent(operation) || userPaused || paused) {
        await session?.cancel();
        _failPlaybackPreparation(playbackToken, rearm: false);
        return;
      }
      if (session == null) {
        _failPlaybackPreparation(playbackToken, rearm: false);
        _nativeSpeechStreamFallbackForTurn = true;
        return;
      }
      _nativeSpeechStream = session;
      _nativeSpeechStreamFinishRequested = false;
      _nativeSpeechStreamSentCursor = narration.cursor;
      _nativeSpeechStreamRevision = narration.revision;
      unawaited(
        session.firstPcmAccepted.then((accepted) {
          if (!accepted ||
              !_isCurrent(operation) ||
              !identical(_nativeSpeechStream, session) ||
              userPaused ||
              paused) {
            return;
          }
          if (!_runtime.confirmPlayback(playbackToken!)) return;
          _notify();
        }),
      );
      unawaited(
        session.done.then(
          (outcome) => _onNativeSpeechStreamDone(
            operation,
            session!,
            playbackToken!,
            outcome,
          ),
        ),
      );
      session.setPlaybackFence(() async {
        if (!_isCurrent(operation) ||
            !identical(_nativeSpeechStream, session) ||
            userPaused ||
            paused) {
          return;
        }
        final monitor = _fullDuplex;
        if (monitor?.active ?? false) {
          await monitor!.setPlaybackActive(true);
        }
      });
    }
    if (!identical(_nativeSpeechStream, session) ||
        !_isCurrent(operation) ||
        narration.revision != _nativeSpeechStreamRevision) {
      return;
    }

    final raw = narration.rawObserved;
    while (_nativeSpeechStreamSentRawLength < raw.length &&
        !userPaused &&
        !paused) {
      final start = _nativeSpeechStreamSentRawLength;
      final end = _speechStreamDeltaEnd(raw, start);
      final appended = await session.append(raw.substring(start, end));
      if (appended) {
        _markFirstTtsFeed();
        // El guard anti-eco también cubre el speak-stream nativo: el texto ya
        // entregado al servidor es lo que el altavoz puede estar devolviendo.
        _fullDuplex?.noteSpokenText(raw.substring(start, end));
      }
      if (!_isCurrent(operation) ||
          !identical(_nativeSpeechStream, session) ||
          narration.revision != _nativeSpeechStreamRevision ||
          userPaused ||
          paused) {
        return;
      }
      _nativeSpeechStreamSentRawLength = end;
      // Si el stream falla después de PCM, todo texto ya entregado se salta en
      // el fallback para garantizar que nunca se repita audio audible.
      _nativeSpeechStreamSentCursor = narration.chunks.length;
      narration.markPlaybackThrough(_nativeSpeechStreamSentCursor);
    }
    if (narration.terminal &&
        identical(_nativeSpeechStream, session) &&
        !_nativeSpeechStreamFallbackForTurn &&
        !_nativeSpeechStreamFinishRequested &&
        !userPaused &&
        !paused) {
      _nativeSpeechStreamFinishRequested = true;
      unawaited(session.finish().then<void>((_) {}));
    }
  }

  static int _speechStreamDeltaEnd(String text, int start) {
    var end = start + HermesSpeechStreamSession.maxTextDeltaChars;
    if (end >= text.length) return text.length;
    // Dart indexa String en unidades UTF-16. No cortes un par sustituto: un
    // emoji partido entre dos frames dejaría texto inválido en el chunker TTS.
    final previous = text.codeUnitAt(end - 1);
    final next = text.codeUnitAt(end);
    if (previous >= 0xD800 &&
        previous <= 0xDBFF &&
        next >= 0xDC00 &&
        next <= 0xDFFF) {
      end -= 1;
    }
    return end;
  }

  Future<void> _onNativeSpeechStreamDone(
    int operation,
    HermesSpeechStreamSession session,
    VoiceRuntimeToken playbackToken,
    HermesSpeechStreamOutcome outcome,
  ) async {
    if (!identical(_nativeSpeechStream, session)) return;
    _nativeSpeechStream = null;
    _nativeSpeechStreamFinishRequested = false;
    _cancelNativeSpeechFeed();
    unawaited(_fullDuplex?.setPlaybackActive(false));
    final narration = _narration;
    if (narration == null || !_isCurrent(operation)) return;

    switch (outcome) {
      case HermesSpeechStreamOutcome.fallback:
        // No llegó PCM: el cursor sigue intacto y el pipeline probado por POST
        // puede narrar exactamente el mismo texto una sola vez.
        _failPlaybackPreparation(playbackToken, rearm: false);
        _nativeSpeechStreamFallbackForTurn = true;
        _nativeSpeechStreamSentCursor = narration.cursor;
        // Los frames de texto enviados al WS eran solo provisionales: sin un
        // primer PCM no hay audio aceptado. Retira también la valla para que un
        // `message.complete` autoritativo pueda corregir o anteponer texto sin
        // que la reconciliación lo confunda con contenido ya reproducido.
        narration.markPlaybackThrough(narration.cursor);
        _driveNarrationIfNeeded();
        return;
      case HermesSpeechStreamOutcome.played:
      case HermesSpeechStreamOutcome.partial:
        if (_runtime.state.playbackOwner == VoicePlaybackOwner.preparing) {
          _runtime.confirmPlayback(playbackToken);
        }
        await _finishPlaybackAfterPhysicalDrain(
          operation,
          playbackToken,
          acousticTail: narration.terminal && !backendActive,
        );
        if (!_isCurrent(operation) || userPaused || paused) return;
        // Tras PCM parcial no hay fallback ni repetición. Todo texto entregado
        // al socket se considera consumido; puede perderse una cola remota aún
        // no audible, pero nunca se duplica audio ya escuchado.
        while (narration.cursor < _nativeSpeechStreamSentCursor) {
          if (!narration.completeCurrent(_nativeSpeechStreamRevision)) break;
        }
        _nativeSpeechStreamFallbackForTurn =
            outcome == HermesSpeechStreamOutcome.partial;
        if (narration.hasPending) {
          _driveNarrationIfNeeded();
        } else if (narration.terminal && !backendActive) {
          _scheduleListening();
        } else if (backendActive && phase == VoicePhase.speaking) {
          final turn = _turnBinding;
          if (turn != null) {
            _runtime.markBackendRunning(turn);
            _runtime.markToolActive(turn, active: activeTool != null);
          }
          _notify();
        }
        return;
      case HermesSpeechStreamOutcome.cancelled:
        if (_runtime.abortPlayback(playbackToken)) {
          _runtime.finishPlaybackDrain(playbackToken);
        }
        if (identical(_playbackRuntimeToken, playbackToken)) {
          _playbackRuntimeToken = null;
        }
        return;
    }
  }

  Future<void> _driveNarration(int operation) async {
    final narration = _narration;
    if (narration == null) return;
    final handoff = _modelHandoff ??= voice.prepareForNarration();
    await handoff;
    if (!_isCurrent(operation) || userPaused || paused) return;
    while (_isCurrent(operation) && !userPaused && !paused) {
      if (narration.current == null) return;
      final playbackToken = _preparePlaybackForCurrentTurn();
      if (playbackToken == null) return;
      final revision = narration.revision;
      final batchStart = narration.cursor;
      final (batchEnd, batchText) = _usesNativeTerminalFallback
          ? (
              narration.chunks.length,
              _batchText(narration, batchStart, narration.chunks.length),
            )
          : _composePlaybackBatch(narration, batchStart);
      await _fullDuplex?.setPlaybackActive(true);
      if (!_isCurrent(operation) || userPaused || paused) return;
      // Compromete el lote con la cola ANTES de sonar: solo una divergencia
      // por debajo de esta valla debe invalidar la reproducción (spec 048/US1).
      narration.markPlaybackThrough(batchEnd);
      // Referencia del guard anti-eco: un barge-in cuyo transcript coincide
      // con este lote es auto-captura del altavoz, no voz del usuario.
      _fullDuplex?.noteSpokenText(batchText);
      // Los trozos internos de una misma unidad semántica no llevan pausa. Se
      // entregan juntos al motor para evitar un hueco de generación/reproducción
      // entre cada corte de 160 caracteres.
      try {
        final speechLease = _conversationSpeechLease;
        if (speechLease == null) {
          _failPlaybackPreparation(playbackToken, rearm: false);
          return;
        }
        final accepted = await voice.enqueueConversationSpeech(
          speechLease,
          batchText,
        );
        if (accepted) {
          _runtime.confirmPlayback(
            playbackToken,
            owner: VoicePlaybackOwner.fallback,
          );
          _markFirstTtsFeed();
          _notify();
        } else {
          // Una cola que rechaza el lote no lo ha aceptado ni reproducido. La
          // valla era provisional: vuelve al cursor para que Pause/Play (o una
          // petición causal posterior) pueda reintentar exactamente el mismo
          // texto sin etiquetarlo como audio entregado.
          narration.markPlaybackThrough(batchStart);
          _failPlaybackPreparation(playbackToken, rearm: false);
          return;
        }
        // Mientras suena este lote, la siguiente unidad estable se sintetiza en
        // paralelo hacia el caché del motor (spec 048/US3). Si la revisión se
        // invalida antes de sonar, ese trabajo simplemente se descarta.
        if (_isCurrent(operation)) _maybePrewarmNextBatch();
        await voice.waitSpeechDone();
      } on VoiceRouteUnavailableException {
        if (!_isCurrent(operation)) return;
        if (!_runtime.failPlaybackPreparation(playbackToken, rearm: false) &&
            _runtime.abortPlayback(playbackToken)) {
          _runtime.finishPlaybackDrain(playbackToken);
        }
        if (identical(_playbackRuntimeToken, playbackToken)) {
          _playbackRuntimeToken = null;
        }
        narration.pause();
        _runtime.pauseByUser();
        userPaused = true;
        note = _isEnglish
            ? 'Hermes server voice is unavailable. Voice was paused.'
            : 'La voz del servidor Hermes no está disponible. Voz se ha pausado.';
        _notify();
        return;
      } finally {
        await _fullDuplex?.setPlaybackActive(false);
      }
      if (!_isCurrent(operation) || userPaused || paused) {
        return;
      }
      final revisionStillCurrent = narration.revision == revision;
      if (_runtime.state.playbackOwner != VoicePlaybackOwner.none) {
        await _finishPlaybackAfterPhysicalDrain(
          operation,
          playbackToken,
          acousticTail:
              revisionStillCurrent &&
              narration.terminal &&
              batchEnd >= narration.chunks.length,
        );
        if (!_isCurrent(operation) || userPaused || paused) return;
      }
      // La reconciliación puede haber sustituido la cola mientras sonaba este
      // lote. El audio aceptado ya terminó y su owner quedó drenado; no avances
      // la revisión vieja. El request retenido por _driveNarrationIfNeeded
      // retomará la cola autoritativa sin un stop acústico a mitad de frase.
      if (narration.revision != revision) return;
      for (var index = batchStart; index < batchEnd; index++) {
        if (!narration.completeCurrent(revision)) return;
      }
      // The neural engine already renders punctuation and paragraph prosody.
      // Extra 120–400 ms gaps after every streamed unit made speech sound
      // chopped and delayed preparation of the next sentence. Keep only a
      // short terminal settle before reopening the microphone.
      final completedTerminalTail =
          narration.terminal && narration.cursor >= narration.chunks.length;
      if (completedTerminalTail && !_runtime.state.rearmReady) return;
    }
  }

  VoiceRuntimeToken? _preparePlaybackForCurrentTurn() {
    final existing = _playbackRuntimeToken;
    if (existing != null) {
      final owner = _runtime.state.playbackOwner;
      if (owner == VoicePlaybackOwner.preparing) return existing;
      if (owner != VoicePlaybackOwner.none) return null;
      // El runtime ya confirmó que no conserva ningún owner. El token local
      // solo puede ser un callback stale de una operación anterior.
      _playbackRuntimeToken = null;
    }
    final turn = _turnBinding;
    if (turn == null) return null;
    final token = _runtime.preparePlayback(turn);
    if (token != null) _playbackRuntimeToken = token;
    return token;
  }

  void _failPlaybackPreparation(
    VoiceRuntimeToken token, {
    required bool rearm,
  }) {
    _runtime.failPlaybackPreparation(token, rearm: rearm);
    if (identical(_playbackRuntimeToken, token)) {
      _playbackRuntimeToken = null;
    }
  }

  Future<void> _finishPlaybackAfterPhysicalDrain(
    int operation,
    VoiceRuntimeToken token, {
    required bool acousticTail,
  }) async {
    if (!_runtime.beginPlaybackDrain(token) &&
        _runtime.state.playbackOwner != VoicePlaybackOwner.draining) {
      return;
    }
    if (acousticTail) {
      await _waitForPlaybackTail(operation);
      if (!_isCurrent(operation) || userPaused || paused) return;
    }
    _runtime.finishPlaybackDrain(token);
    if (identical(_playbackRuntimeToken, token)) {
      _playbackRuntimeToken = null;
    }
    _notify();
  }

  Future<void> _waitForPlaybackTail(int operation) async {
    if (!_isCurrent(operation)) return;
    final existing = _playbackTailGuardTask;
    if (existing != null && _playbackTailGuardEpoch == operation) {
      await existing;
      return;
    }
    debugPrint(
      '[VOICE-PERF] voice.playback.tail_guard_ms='
      '${_playbackTailGuard.inMilliseconds}',
    );
    late final Future<void> task;
    task = _playbackTailDelay(_playbackTailGuard);
    _playbackTailGuardEpoch = operation;
    _playbackTailGuardTask = task;
    try {
      await task;
    } finally {
      if (identical(_playbackTailGuardTask, task)) {
        _playbackTailGuardTask = null;
        _playbackTailGuardEpoch = null;
      }
    }
  }

  /// Pre-síntesis de la siguiente unidad (spec 048/US3). Se dispara al encolar
  /// un lote y cada vez que la cola crece durante el streaming: el lote N
  /// suele empezar a sonar antes de que el N+1 exista. La primera composición
  /// estable queda reservada: si el stream añade más texto antes de que termine
  /// N, N+1 reproduce exactamente la clave ya sintetizada en vez de reagruparla
  /// y volver a pagar varios segundos de ONNX en silencio.
  void _maybePrewarmNextBatch() {
    final narration = _narration;
    if (narration == null || !active || userPaused || paused) return;
    if (_usesNativeTerminalFallback) return;
    if (_narrationTask == null) return;
    final fence = narration.playbackFence;
    if (fence <= narration.cursor || fence >= narration.chunks.length) return;
    _reserveNarrationPrewarm(narration, fence);
  }

  void _reserveNarrationPrewarm(StreamingNarrationQueue narration, int start) {
    if (!active || userPaused || paused) return;
    if (start < 0 || start >= narration.chunks.length) return;
    if (_reservedPrewarmMatches(narration, start)) {
      return;
    }
    final (nextEnd, nextText) = _composeBatch(narration, start);
    _prewarmRevision = narration.revision;
    _prewarmStart = start;
    _prewarmEnd = nextEnd;
    _prewarmText = nextText;
    debugPrint(
      '[VOICE-PERF] voice.narration.prewarm_reserved '
      'revision=${narration.revision} start=$start end=$nextEnd '
      'policy=gapless_v2',
    );
    final speechLease = _conversationSpeechLease;
    if (speechLease == null) return;
    unawaited(voice.prewarmConversationSpeech(speechLease, nextText));
  }

  (int, String) _composePlaybackBatch(
    StreamingNarrationQueue narration,
    int start,
  ) {
    if (_reservedPrewarmMatches(narration, start)) {
      debugPrint(
        '[VOICE-PERF] voice.narration.prewarm_hit '
        'revision=${narration.revision} start=$start end=$_prewarmEnd '
        'policy=gapless_v2',
      );
      return (_prewarmEnd, _prewarmText!);
    }
    return _composeBatch(narration, start);
  }

  bool _reservedPrewarmMatches(StreamingNarrationQueue narration, int start) {
    final text = _prewarmText;
    if (_prewarmRevision != narration.revision ||
        _prewarmStart != start ||
        _prewarmEnd <= start ||
        _prewarmEnd > narration.chunks.length ||
        text == null) {
      return false;
    }
    return _batchText(narration, start, _prewarmEnd) == text;
  }

  static String _batchText(
    StreamingNarrationQueue narration,
    int start,
    int end,
  ) => narration.chunks
      .getRange(start, end)
      .map((chunk) => chunk.text)
      .join(' ');

  /// Une, desde [start], únicamente los cortes internos de UNA oración.
  ///
  /// [StreamingNarrationQueue] parte una oración larga en chunks defensivos de
  /// 160 caracteres. Esos cortes no deben crear voces ni silencios distintos,
  /// pero una oración que ya termina en puntuación sí debe salir al TTS local
  /// sin esperar a que termine la respuesta completa. El fallback nativo de
  /// Servidor Hermes no usa este corte: replica Desktop con un único one-shot
  /// terminal mediante [_usesNativeTerminalFallback].
  ///
  /// Devuelve el fin EXCLUSIVO del lote y su texto. La misma composición se
  /// reutiliza para narrar y para pre-sintetizar, evitando que el caché agrupe
  /// algo distinto de lo que acabará reproduciéndose.
  static (int, String) _composeBatch(
    StreamingNarrationQueue narration,
    int start,
  ) {
    final chunks = narration.chunks;
    final first = chunks[start];
    final parts = <String>[first.text];
    var index = start;
    var characters = first.text.length;
    while (index + 1 < chunks.length) {
      if (_endsAtSpokenSentenceBoundary(chunks[index].text)) break;
      final next = chunks[index + 1];
      final joinedLength = characters + 1 + next.text.length;
      if (joinedLength > VoiceService.maxSpeechUtteranceChars) {
        break;
      }
      parts.add(next.text);
      index += 1;
      characters = joinedLength;
    }
    return (index + 1, parts.join(' '));
  }

  static bool _endsAtSpokenSentenceBoundary(String text) {
    var end = text.length;
    while (end > 0 && _isTrailingSentenceWrapper(text[end - 1])) {
      end--;
    }
    if (end == 0) return false;
    return const {'.', '!', '?', '…'}.contains(text[end - 1]);
  }

  static bool _isTrailingSentenceWrapper(String character) => const {
    ' ',
    '\n',
    '\t',
    '"',
    "'",
    '”',
    '’',
    '»',
    ')',
    ']',
    '}',
  }.contains(character);

  void _pauseForPendingApproval() {
    final chat = _chat;
    _bargeGeneration++;
    _bargeCaptureInFlight = false;
    _bargeTurnSubmitting = false;
    _bargeInterruptedPlayback = false;
    _bargeInterruptTask = null;
    final pendingKey = _pendingInputKey(chat);
    // Un aviso por EPISODIO de espera, no por petición: en el Pixel el
    // servidor emitió tres approval.request seguidas (ids distintos) y la voz
    // repitió el mismo aviso tres veces. Mientras siga sin resolverse, se
    // avisa una sola vez; al resolverse, el episodio se cierra y un permiso
    // nuevo vuelve a avisar (lo hace _resumeAfterApprovalIfResolved).
    final announce = pendingKey != null && _announcedPendingInputKey == null;
    if (!announce &&
        pendingKey != null &&
        phase == VoicePhase.waitingPermission) {
      activeTool = _latestToolLabel(chat);
      _notify();
      return;
    }
    if (announce) _announcedPendingInputKey = pendingKey;
    final announceApproval = chat?.pendingApproval != null;
    final audioGeneration = ++_pendingInputAudioGeneration;
    final narration = _narration;
    final turn = _turnBinding;
    VoicePendingInputClaim? inputClaim;
    if (turn != null) {
      inputClaim = _runtime.waitForInput(turn);
      if (inputClaim != null) {
        _turnBinding = inputClaim.binding;
      }
    }
    _normalCaptureToken = null;
    _bargeRuntimeToken = null;
    _playbackRuntimeToken = inputClaim?.playbackDrainToken;
    unawaited(_disarmFullDuplex());
    _detachNativeSpeechStreamForStop();
    ++_epoch;
    narration?.pause();
    activeTool = _latestToolLabel(_chat);
    _notify();
    final subscription = _sttSub;
    _sttSub = null;
    unawaited(subscription?.cancel());
    unawaited(voice.cancelDictation());
    unawaited(
      _silenceAndAnnouncePendingInput(
        audioGeneration,
        announce: announce,
        approval: announceApproval,
        playbackDrainToken: inputClaim?.playbackDrainToken,
      ),
    );
  }

  Future<void> _silenceAndAnnouncePendingInput(
    int generation, {
    required bool announce,
    required bool approval,
    required VoiceRuntimeToken? playbackDrainToken,
  }) async {
    await voice.stopSpeaking();
    if (playbackDrainToken != null) {
      _runtime.finishPlaybackDrain(playbackDrainToken);
      if (identical(_playbackRuntimeToken, playbackDrainToken)) {
        _playbackRuntimeToken = null;
      }
      _notify();
      if (active && !userPaused && !paused && _chat?.needsInput != true) {
        _driveNarrationIfNeeded();
      }
    }
    if (!announce ||
        !active ||
        _disposed ||
        generation != _pendingInputAudioGeneration ||
        phase != VoicePhase.waitingPermission ||
        _chat?.needsInput != true ||
        userPaused) {
      return;
    }
    final message = approval
        ? (_isEnglish
              ? 'Hermes needs your approval. Open the app to review it.'
              : 'Hermes necesita tu aprobación. Abre la aplicación para revisarla.')
        : (_isEnglish
              ? 'Hermes needs your response. Open the app to continue.'
              : 'Hermes necesita tu respuesta. Abre la aplicación para continuar.');
    await voice.enqueueLocalSpeech(message);
  }

  void _resumeAfterApprovalIfResolved() {
    if (_runtime.state.backendState != VoiceBackendState.waitingInput ||
        _chat?.needsInput == true) {
      return;
    }
    final turn = _turnBinding;
    if (turn == null ||
        !_runtime.resolveInput(
          turn,
          backendRunning:
              backendActive || (_chat?.queuedMessages.isNotEmpty ?? false),
        )) {
      return;
    }
    _announcedPendingInputKey = null;
    _pendingInputAudioGeneration++;
    if (userPaused) {
      return;
    }
    paused = false;
    _narration?.resume();
    _driveNarrationIfNeeded();
  }

  void _invalidateNarrationPlayback({
    VoiceRuntimeToken? playbackDrainToken,
    bool invalidateOperation = true,
  }) {
    final token = playbackDrainToken ?? _playbackRuntimeToken;
    if (token != null) _runtime.abortPlayback(token);
    unawaited(_fullDuplex?.setPlaybackActive(false));
    _detachNativeSpeechStreamForStop();
    if (invalidateOperation) ++_epoch;
    unawaited(_stopPlaybackForDrain(token));
  }

  void _detachNativeSpeechStreamForStop() {
    _cancelNativeSpeechFeed();
    final session = _nativeSpeechStream;
    _nativeSpeechStreamFinishRequested = false;
    if (session == null) return;
    _nativeSpeechStream = null;
    final narration = _narration;
    if (session.receivedPcm && narration != null) {
      // Un Stop terminal no conoce el offset textual exacto del AudioTrack.
      // Saltar lo ya entregado evita que un callback tardío repita el inicio.
      narration.resumeFromVisibleEnd();
      _nativeSpeechStreamSentRawLength = narration.rawObserved.length;
    } else {
      // Si todavía no hubo PCM, nada fue audible: Play debe poder abrir una
      // sesión nueva y reenviar la respuesta retenida desde el principio.
      _nativeSpeechStreamSentRawLength = 0;
    }
    _nativeSpeechStreamSentCursor = narration?.cursor ?? 0;
    _nativeSpeechStreamRevision = narration?.revision ?? -1;
  }

  Future<void> _stopPlaybackForDrain(VoiceRuntimeToken? playbackDrainToken) {
    final previous = _speechStopTask;
    late final Future<void> task;
    task =
        (() async {
          if (previous != null) {
            try {
              await previous;
            } catch (_) {
              // The new causal stop must still run and settle its own drain token.
            }
          }
          await voice.stopSpeaking();
          if (playbackDrainToken != null) {
            _runtime.finishPlaybackDrain(playbackDrainToken);
            if (identical(_playbackRuntimeToken, playbackDrainToken)) {
              _playbackRuntimeToken = null;
            }
            _notify();
            if (active && !userPaused && !paused) {
              // El ACK físico, no un finally recursivo, despierta cualquier
              // respuesta nueva que llegó mientras este owner drenaba.
              _driveNarrationIfNeeded();
              if (_runtime.state.rearmReady) _scheduleListening();
            }
          }
        })().whenComplete(() {
          if (identical(_speechStopTask, task)) _speechStopTask = null;
        });
    _speechStopTask = task;
    return task;
  }

  @override
  void pauseConversation() {
    if (!active || userPaused) return;
    final nativeSession = _nativeSpeechStream;
    final preservePlayback =
        nativeSession != null && _playbackRuntimeToken != null;
    final pauseClaim = _runtime.pauseByUser(preservePlayback: preservePlayback);
    if (pauseClaim == null) return;
    _turnBinding = pauseClaim.binding;
    _normalCaptureToken = null;
    _bargeRuntimeToken = null;
    if (!pauseClaim.playbackPreserved) {
      _playbackRuntimeToken = pauseClaim.playbackDrainToken;
    }
    _bargeGeneration++;
    _bargeCaptureInFlight = false;
    _bargeTurnSubmitting = false;
    _bargeInterruptedPlayback = false;
    _bargeInterruptTask = null;
    _cancelNativeSpeechFeed();
    userPaused = true;
    _narration?.pause();
    note = null;
    final subscription = _sttSub;
    _sttSub = null;
    final microphoneCleanup = _disarmFullDuplex();
    final subscriptionCleanup = subscription?.cancel();
    final releaseLocalModels = !voice.nativeVoiceActive;
    final sttCleanup = releaseLocalModels
        ? voice.disposeSttForVoiceExit()
        : null;
    _sttReleasedForPause = sttCleanup != null;

    // El stream de VoiceService envuelve al stream real del motor. Algunos
    // motores completan `cancel()` solo después de que `dispose()` cierre el
    // recorder/source, mientras ese cierre puede entregar antes `done` al
    // wrapper. Esperar ambos en el mismo Future.wait crea un abrazo que deja
    // Pause/Play bloqueado aunque el micrófono físico ya se haya soltado.
    // Cuando existe un dispose autoritativo, su ACK gobierna la lease; la
    // cancelación queda cercada por epoch y drena best-effort en paralelo.
    if (subscriptionCleanup != null && sttCleanup != null) {
      unawaited(_ignorePrivacyCleanup(subscriptionCleanup));
    }

    final cleanups = <Future<void>>[
      _ignorePrivacyCleanup(microphoneCleanup),
      if (subscriptionCleanup != null && sttCleanup == null)
        _ignorePrivacyCleanup(subscriptionCleanup),
      if (sttCleanup != null) _ignorePrivacyCleanup(sttCleanup),
    ];

    if (nativeSession != null && pauseClaim.playbackPreserved) {
      // Pause real: conserva esta misma respuesta, WebSocket y AudioTrack. No
      // toca el cursor textual porque `markPlaybackThrough` solo significa
      // enviado al TTS, nunca necesariamente oído.
      late final Future<void> pauseTask;
      pauseTask = nativeSession.pause().whenComplete(() {
        if (identical(_nativeSpeechPauseTask, pauseTask)) {
          _nativeSpeechPauseTask = null;
        }
      });
      _nativeSpeechPauseTask = pauseTask;
      cleanups.add(_ignorePrivacyCleanup(pauseTask));
    } else {
      _detachNativeSpeechStreamForStop();
      ++_epoch;
      cleanups.add(
        _ignorePrivacyCleanup(
          _stopPlaybackForDrain(pauseClaim.playbackDrainToken),
        ),
      );
      if (releaseLocalModels) {
        _ttsReleasedForPause = true;
        cleanups.add(_ignorePrivacyCleanup(voice.disposeTtsForVoiceExit()));
      }
    }

    late final Future<void> releaseTask;
    releaseTask = Future.wait<void>(cleanups).whenComplete(() {
      if (identical(_userPauseReleaseTask, releaseTask)) {
        _userPauseReleaseTask = null;
        _notify();
      }
    });
    _userPauseReleaseTask = releaseTask;
    _notify();
    unawaited(releaseTask);
  }

  @override
  void playConversation() {
    unawaited(_resumeConversation());
  }

  Future<void> _resumeConversation() async {
    if (!active || !userPaused || _fullDuplexPrivacySuspended) {
      return;
    }
    final pendingRelease = _userPauseReleaseTask;
    if (pendingRelease != null) {
      await _ignorePrivacyCleanup(pendingRelease);
      if (!active || !userPaused || _fullDuplexPrivacySuspended) return;
    }
    _sttReleasedForPause = false;
    _ttsReleasedForPause = false;
    final nativeSession = _nativeSpeechStream;
    if (nativeSession != null) {
      note = null;
      _notify();
      await _play(_epoch, nativeSession: nativeSession);
      return;
    }
    final operation = ++_epoch;
    note = null;
    _notify();
    await _play(operation);
  }

  Future<void> _play(
    int operation, {
    HermesSpeechStreamSession? nativeSession,
  }) async {
    if (nativeSession != null) {
      final pendingPause = _nativeSpeechPauseTask;
      if (pendingPause != null) {
        try {
          await pendingPause;
        } catch (_) {
          // La propia sesión convierte un fallo nativo en resultado terminal.
        }
      }
      if (!_isCurrent(operation) || !userPaused || paused) return;
      if (identical(_nativeSpeechStream, nativeSession)) {
        await nativeSession.resume();
      } else {
        return;
      }
      if (!_isCurrent(operation) || !userPaused || paused) return;
      _runtime.resumeByUser(resumePlayback: true);
      _turnBinding = _runtime.state.currentTurn;
      userPaused = false;
      _narration?.resume();
      note = null;
      _notify();
    }
    final pendingStop = _speechStopTask;
    if (pendingStop != null) {
      try {
        await pendingStop;
      } catch (_) {
        // VoiceService already degrades a failed stop safely. Resume still gets
        // a chance to rebuild playback from the retained narration cursor.
      }
      if (!_isCurrent(operation) || paused) return;
    }
    if (userPaused) {
      final resumedBinding = _runtime.resumeByUser();
      if (resumedBinding == null) return;
      _turnBinding = resumedBinding;
      userPaused = false;
      _narration?.resume();
      note = null;
      _notify();
    }
    if (_chat?.pendingApproval != null) {
      // Una aprobación siempre gana sobre Play: sigue siendo táctil y no se
      // reactiva ni el micro ni el TTS hasta que el chat la resuelva.
      userPaused = false;
      _narration?.pause();
      final turn = _turnBinding;
      if (turn != null) {
        final claim = _runtime.waitForInput(turn);
        if (claim != null) {
          _turnBinding = claim.binding;
          _playbackRuntimeToken = claim.playbackDrainToken;
        }
      }
      _notify();
      return;
    }
    if (_narration?.hasPending ?? false) {
      _driveNarrationIfNeeded();
    } else if (backendActive || (_chat?.queuedMessages.isNotEmpty ?? false)) {
      final turn = _turnBinding;
      if (turn != null) _runtime.markBackendRunning(turn);
      unawaited(_armFullDuplexForTurn());
      _notify();
    } else {
      await _openListening(operation);
    }
  }

  @override
  void stopAndTalk() {
    if (!active) return;
    final chat = _chat;
    final turn = _turnBinding;
    if (chat == null || turn == null) return;
    final claim = _runtime.requestManualInterruptionCapture(turn);
    if (claim == null) return;
    _turnBinding = claim.binding;
    _normalCaptureToken = claim.captureToken;
    _bargeRuntimeToken = null;
    _playbackRuntimeToken = claim.playbackDrainToken;
    _manualInterruptedPlayback = claim.cancelledPlayback;
    _manualInterruptTask = claim.shouldInterruptBackend
        ? _interruptBackendForCapture(chat, claim.binding)
        : null;
    final stopTrace = VoiceLatencyTrace.current.beginTurn(
      route: _voiceLatencyRoute,
      scenario: VoiceLatencyScenario.stop,
    );
    _latencyTurn = stopTrace;
    stopTrace.mark(VoiceLatencyPoint.stopRequested);
    _bargeGeneration++;
    _bargeCaptureInFlight = false;
    _bargeTurnSubmitting = false;
    _bargeInterruptedPlayback = false;
    _bargeInterruptTask = null;
    _detachNativeSpeechStreamForStop();
    final operation = ++_epoch;
    userPaused = false;
    paused = false;
    _narration?.silence();
    note = null;
    _notify();
    final subscription = _sttSub;
    _sttSub = null;
    unawaited(
      _stopAndRestartCapture(operation, subscription, stopTrace, claim),
    );
  }

  Future<void> _interruptBackendForCapture(
    ActiveChat chat,
    VoiceTurnBinding binding,
  ) async {
    try {
      await chat.interruptForVoiceBarge();
      _runtime.settleBackendInterrupt(
        binding,
        backendRunning: chat.isStreaming,
      );
    } catch (_) {
      _runtime.failBackendInterrupt(binding);
    } finally {
      _notify();
      if (_runtime.state.rearmReady) {
        _scheduleListening();
      } else if (active && backendActive && !userPaused && !paused) {
        unawaited(_armFullDuplexForTurn());
      }
    }
  }

  Future<void> _stopAndRestartCapture(
    int operation,
    StreamSubscription<SttResult>? subscription,
    VoiceLatencyTurn stopTrace,
    VoiceManualInterruptionClaim claim,
  ) async {
    final stopSpeaking = _stopPlaybackForDrain(claim.playbackDrainToken);
    await _disarmFullDuplex();
    await subscription?.cancel();
    await stopSpeaking;
    stopTrace.mark(VoiceLatencyPoint.audioStopped);
    stopTrace.finish();
    if (!_isCurrent(operation)) return;
    await _restartCapture(operation, claimedCaptureToken: claim.captureToken);
  }

  @override
  void finishListening() {
    if (!active || userPaused || phase != VoicePhase.listening) return;
    final captureToken = _normalCaptureToken;
    if (captureToken == null ||
        !_runtime.beginNormalTranscription(captureToken)) {
      return;
    }
    _latencyTurn?.mark(VoiceLatencyPoint.speechEndpoint);
    _notify();
    unawaited(voice.stopDictation());
  }

  @override
  void retry() {
    if (!active) return;
    final captureToken = _normalCaptureToken;
    if (captureToken != null) {
      _runtime.failNormalCapture(captureToken);
      _normalCaptureToken = null;
      _normalCaptureStartOperation = null;
    }
    if (userPaused) {
      final resumed = _runtime.resumeByUser();
      if (resumed != null) _turnBinding = resumed;
    }
    _runtime.requestRearmAfterFailure();
    final operation = ++_epoch;
    userPaused = false;
    paused = false;
    note = null;
    _notify();
    unawaited(_restartCapture(operation));
  }

  Future<void> _restartCapture(
    int operation, {
    VoiceRuntimeToken? claimedCaptureToken,
  }) async {
    await voice.cancelDictation();
    if (!_isCurrent(operation)) return;
    await _openListening(operation, claimedCaptureToken: claimedCaptureToken);
  }

  @override
  void cancelBackend() {
    final chat = _chat;
    if (!active || chat == null || !chat.isStreaming) return;
    final turn = _turnBinding;
    if (turn != null) _runtime.markBackendInterrupting(turn);
    final operation = ++_epoch;
    final playbackToken = _playbackRuntimeToken;
    if (playbackToken != null) _runtime.abortPlayback(playbackToken);
    _detachNativeSpeechStreamForStop();
    _narration?.silence();
    activeTool = null;
    _notify();
    unawaited(_cancelBackendDurably(chat, operation, playbackToken));
  }

  Future<void> _cancelBackendDurably(
    ActiveChat chat,
    int operation,
    VoiceRuntimeToken? playbackToken,
  ) async {
    try {
      // Ambas operaciones empiezan ya: un audio driver colgado nunca puede
      // impedir que el tombstone y el Stop del backend avancen.
      await Future.wait<void>([
        _stopPlaybackForDrain(playbackToken),
        chat.cancel(),
      ]);
    } catch (_) {
      if (!_isCurrent(operation)) return;
      paused = true;
      note = 'No se pudo guardar Stop de forma segura. Reinténtalo.';
      _notify();
      return;
    }
    if (_isCurrent(operation)) _scheduleListening();
  }

  @override
  void onOrbTap() {
    if (!active) return;
    if (userPaused) {
      playConversation();
      return;
    }
    switch (phase) {
      case VoicePhase.listening:
        finishListening();
      case VoicePhase.transcribing:
        break;
      case VoicePhase.waitingPermission:
        pauseForApproval();
      case VoicePhase.thinking:
      case VoicePhase.speaking:
      case VoicePhase.toolCall:
        stopAndTalk();
      case VoicePhase.idle:
        retry();
    }
  }

  @override
  void pauseForApproval() {
    if (!active) return;
    paused = true;
    overlayMinimized = true;
    _notify();
  }

  @override
  void minimizeOverlay() {
    if (!active || overlayMinimized) return;
    overlayMinimized = true;
    _notify();
  }

  @override
  void resumeOverlay() {
    if (!active) return;
    overlayMinimized = false;
    paused = false;
    _notify();
  }

  Future<void> pauseFromSystemControl() async => pauseConversation();

  Future<void> resumeFromSystemControl() async {
    if (_fullDuplexPrivacySuspended) {
      if (!_privacyReleaseRequested) return;
      final pendingPrivacyPause = _privacyPauseTask;
      if (pendingPrivacyPause != null) {
        await _ignorePrivacyCleanup(pendingPrivacyPause);
      }
      if (_fullDuplexPrivacySuspended) {
        if (!_privacyReleaseRequested) return;
        _releasePrivacyFence();
      }
    }
    await _resumeConversation();
  }

  Future<void> onAppBackgrounded() => suspendForPrivacy();

  void onAppResumed({required bool appUnlocked}) {
    if (_disposed || !appUnlocked || _privacyPauseTask != null) return;
    // Volver visible solo retira la valla que impedía Play. `userPaused` sigue
    // intacto: ni el micrófono ni el TTS se reanudan sin intención del usuario.
    _releasePrivacyFence();
  }

  Future<void> _suspendFullDuplexNow() async {
    _bargeGeneration++;
    _bargeCaptureInFlight = false;
    _bargeTurnSubmitting = false;
    _bargeInterruptedPlayback = false;
    _bargeInterruptTask = null;
    await _disarmFullDuplex();
  }

  /// Suspensión dura para App Lock y pérdida de privacidad del proceso.
  ///
  /// A diferencia de [pauseConversation], no conserva el WebSocket ni el
  /// AudioTrack de speak-stream. Invalida primero todos los callbacks del
  /// turno y después libera recorder, STT, TTS y modelos, incluso si el usuario
  /// ya había pulsado Pause. El desbloqueo solo retira la valla; nunca llama a
  /// Play ni abre de nuevo el micrófono por sí solo.
  Future<void> suspendForPrivacy() async {
    if (_disposed) return;
    _privacyReleaseRequested = false;
    _fullDuplexPrivacySuspended = true;
    _runtime.hardPauseForPrivacy();
    _turnBinding = _runtime.state.currentTurn;
    _normalCaptureToken = null;
    _bargeRuntimeToken = null;
    _playbackRuntimeToken = null;
    final pending = _privacyPauseTask;
    if (pending != null) {
      await pending;
      return;
    }
    if (_privacyHardPaused) return;
    _privacyHardPaused = true;
    _privacyCleanupInFlight = true;

    late final Future<void> task;
    task = _suspendForPrivacyNow().whenComplete(() {
      if (identical(_privacyPauseTask, task)) {
        _privacyPauseTask = null;
        _privacyCleanupInFlight = false;
        _notify();
      }
    });
    _privacyPauseTask = task;
    await task;
  }

  Future<void> _suspendForPrivacyNow() async {
    final pendingUserPauseRelease = _userPauseReleaseTask;
    if (pendingUserPauseRelease != null) {
      await _ignorePrivacyCleanup(pendingUserPauseRelease);
    }
    final subscription = _sttSub;
    _sttSub = null;
    _modelHandoff = null;
    _nativeSpeechPauseTask = null;
    _pendingInputAudioGeneration++;
    ++_epoch;
    _cancelNativeSpeechFeed();
    _detachNativeSpeechStreamForStop();
    userPaused = true;
    _narration?.pause();
    note = null;
    _notify();

    final fullDuplexStop = _suspendFullDuplexNow();
    final stopSpeaking = voice.stopSpeaking();
    final sttCleanup = _sttReleasedForPause
        ? Future<void>.value()
        : voice.disposeSttForVoiceExit();
    final ttsCleanup = _ttsReleasedForPause
        ? Future<void>.value()
        : voice.disposeTtsForVoiceExit();
    _sttReleasedForPause = true;
    _ttsReleasedForPause = true;
    final subscriptionCleanup = subscription?.cancel();
    if (subscriptionCleanup != null) {
      unawaited(_ignorePrivacyCleanup(subscriptionCleanup));
    }
    await Future.wait<void>([
      _ignorePrivacyCleanup(fullDuplexStop),
      _ignorePrivacyCleanup(stopSpeaking),
      _ignorePrivacyCleanup(sttCleanup),
      _ignorePrivacyCleanup(ttsCleanup),
    ]);
  }

  static Future<void> _ignorePrivacyCleanup(Future<void> cleanup) async {
    try {
      await cleanup;
    } catch (_) {
      // La valla y la epoch ya están aplicadas. Un plugin que falle al soltar
      // recursos no puede convertir App Lock en una reanudación tardía.
    }
  }

  /// Cierra siempre la captura full-duplex al activar App Lock. Ningún opt-in
  /// exterior puede atravesar esta frontera de privacidad.
  Future<void> suspendFullDuplexCapture() async {
    if (_disposed) return;
    _privacyReleaseRequested = false;
    _fullDuplexPrivacySuspended = true;
    await _suspendFullDuplexNow();
  }

  /// Al perder foreground, una conversación conserva barge-in solo si el
  /// usuario aceptó continuar con la pantalla bloqueada. App Lock continúa
  /// ganando siempre.
  Future<void> suspendFullDuplexForAppBackground() async {
    if (_disposed) return;
    _fullDuplexLifecycleSuspended = true;
    if (!voiceConversationMustSuspendFullDuplexInBackground(
      continueWhenLocked: voice.continueVoiceWhenLocked,
    )) {
      return;
    }
    await _suspendFullDuplexNow();
  }

  /// Rearma la interrupción solo al volver visible y desbloqueado, y solo si
  /// todavía existe una fase en la que interrumpir tiene sentido.
  Future<void> resumeFullDuplexCaptureIfNeeded() async {
    if (_disposed) return;
    _privacyReleaseRequested = true;
    final pendingPrivacyPause = _privacyPauseTask;
    if (pendingPrivacyPause != null) await pendingPrivacyPause;
    if (_disposed) return;
    if (_fullDuplexPrivacySuspended) {
      if (!_privacyReleaseRequested) return;
      _releasePrivacyFence();
    }
    final shouldArm =
        active &&
        !userPaused &&
        !paused &&
        _chat?.needsInput != true &&
        (backendActive ||
            (_chat?.queuedMessages.isNotEmpty ?? false) ||
            phase == VoicePhase.thinking ||
            phase == VoicePhase.toolCall ||
            phase == VoicePhase.speaking);
    if (!shouldArm) return;
    await _armFullDuplexForTurn();
    if (_fullDuplexCaptureSuspended || !active || userPaused || paused) return;
    if (phase == VoicePhase.speaking ||
        (_nativeSpeechStream?.receivedPcm ?? false)) {
      await _fullDuplex?.setPlaybackActive(true);
    }
  }

  void _releasePrivacyFence() {
    _runtime.releasePrivacyFence();
    _turnBinding = _runtime.state.currentTurn;
    _fullDuplexPrivacySuspended = false;
    _privacyHardPaused = false;
    _privacyCleanupInFlight = false;
    _privacyReleaseRequested = false;
    _fullDuplexLifecycleSuspended = false;
  }

  @override
  Future<void> exit() async {
    final pendingExit = _exitInFlight;
    if (pendingExit != null) {
      await pendingExit;
      return;
    }
    if (!active) return;
    final pendingPauseRelease = _userPauseReleaseTask;
    final exitTrace = VoiceLatencyTrace.current.beginTurn(
      route: _voiceLatencyRoute,
      scenario: VoiceLatencyScenario.exit,
    );
    _latencyTurn = exitTrace;
    exitTrace.mark(VoiceLatencyPoint.exitRequested);
    _bargeGeneration++;
    _bargeCaptureInFlight = false;
    _bargeTurnSubmitting = false;
    _bargeInterruptedPlayback = false;
    _bargeInterruptTask = null;
    _manualInterruptTask = null;
    _manualInterruptedPlayback = false;
    ++_epoch;
    final exitFence = _runtime.beginExit();
    if (exitFence == null) return;
    _turnBinding = exitFence;
    final speechLease = _conversationSpeechLease;
    _conversationSpeechLease = null;
    if (speechLease != null) {
      voice.endConversationSpeechLease(speechLease);
    }
    _normalCaptureToken = null;
    _bargeRuntimeToken = null;
    _playbackRuntimeToken = null;
    _narrationDriveRequested = false;
    active = false;
    paused = false;
    overlayMinimized = false;
    userPaused = false;
    responding = false;
    activeTool = null;
    note = null;
    _partialTranscript = '';
    _announcedPendingInputKey = null;
    _pendingInputAudioGeneration++;
    _cancelNativeSpeechFeed();
    _narration?.silence();
    _prewarmRevision = -1;
    _prewarmStart = -1;
    _prewarmEnd = -1;
    _prewarmText = null;
    _notify();

    final chatSub = _chatSub;
    final sttSub = _sttSub;
    final fullDuplex = _fullDuplex;
    _fullDuplex = null;
    _chatSub = null;
    _sttSub = null;
    _modelHandoff = null;
    _chat = null;
    _onBeforeSend = null;
    // Invalida y empieza a liberar los motores antes de esperar cancelaciones
    // de streams. Algunos plugins completan `StreamSubscription.cancel()` solo
    // cuando se destruye el recorder; iniciar ambos lados evita el abrazo y hace
    // que X corte audio de forma inmediata incluso si la pantalla se desmonta.
    // Pedir `stop()` antes de soltar el motor garantiza que la acción terminal
    // de la notificación corte el AudioTrack ya en reproducción; `dispose()`
    // sigue arrancando en paralelo para no serializar el teardown de ONNX.
    final stopSpeaking = voice.stopSpeaking();
    final sttCleanup = _sttReleasedForPause
        ? (pendingPauseRelease ?? Future<void>.value())
        : voice.disposeSttForVoiceExit();
    final ttsCleanup = _ttsReleasedForPause
        ? (pendingPauseRelease ?? Future<void>.value())
        : voice.disposeTtsForVoiceExit();
    // El enrutado al STT/TTS de Hermes pertenece exclusivamente a esta sesión
    // de conversación. Al cerrar la X, el dictado del compositor y la lectura
    // de burbujas deben volver a los motores elegidos en Ajustes.
    voice.disableNativeVoice();
    final audioCleanup = Future.wait<void>([stopSpeaking, ttsCleanup])
        .then<void>((_) {
          exitTrace.mark(VoiceLatencyPoint.audioStopped);
        });
    final sttSubscriptionCleanup = sttSub?.cancel();
    if (sttSubscriptionCleanup != null) {
      // [sttCleanup] es el ACK físico autoritativo; no reintroduzcas el ciclo
      // cancel-stream <-> dispose-engine durante Exit.
      unawaited(_ignorePrivacyCleanup(sttSubscriptionCleanup));
    }
    final microphoneCleanup =
        Future.wait<void>([
          sttCleanup,
          if (fullDuplex != null) fullDuplex.dispose(),
        ]).then<void>((_) {
          exitTrace.mark(VoiceLatencyPoint.micReleased);
        });
    final cleanup = Future.wait<void>([
      ?pendingPauseRelease,
      if (chatSub != null) chatSub.cancel(),
      audioCleanup,
      microphoneCleanup,
    ]);
    _exitInFlight = cleanup;
    try {
      await cleanup;
    } finally {
      _runtime.finishExit(exitFence);
      _turnBinding = null;
      _userPauseReleaseTask = null;
      _sttReleasedForPause = false;
      _ttsReleasedForPause = false;
      _privacyCleanupInFlight = false;
      if (identical(_exitInFlight, cleanup)) _exitInFlight = null;
      // El listener global reconcilia después el FGS. Esta segunda proyección
      // ocurre tras los ACK reales de audio/mic y permite que main.dart marque
      // leaseReleased o unavailable sin adelantarse al teardown.
      _notify();
    }
  }

  void _scheduleListening() {
    if (!active ||
        userPaused ||
        paused ||
        _rearmBlocked ||
        !_runtimeMayScheduleListening ||
        _normalCaptureStarting ||
        phase == VoicePhase.listening ||
        _listeningScheduled) {
      return;
    }
    final chat = _chat;
    if (chat == null ||
        chat.needsInput ||
        chat.isStreaming ||
        chat.queuedMessages.isNotEmpty) {
      if (chat?.needsInput ?? false) {
        final turn = _turnBinding;
        if (turn != null) _runtime.waitForInput(turn);
      } else if (chat?.isStreaming ?? false) {
        final turn = _turnBinding;
        if (turn != null) _runtime.markBackendRunning(turn);
      }
      return;
    }
    _listeningScheduled = true;
    scheduleMicrotask(() async {
      _listeningScheduled = false;
      if (!active ||
          userPaused ||
          paused ||
          _rearmBlocked ||
          !_runtimeMayScheduleListening ||
          _normalCaptureStarting ||
          backendActive ||
          _chat?.needsInput == true) {
        return;
      }
      await _disarmFullDuplex();
      if (!active ||
          userPaused ||
          paused ||
          _rearmBlocked ||
          !_runtime.state.rearmReady ||
          _normalCaptureStarting ||
          backendActive ||
          _chat?.needsInput == true) {
        return;
      }
      _refreshVoiceIdentityIfSafe();
      final operation = ++_epoch;
      await _openListening(operation);
    });
  }

  bool _isCurrent(int operation) => active && !_disposed && operation == _epoch;

  bool get _normalCaptureStarting =>
      _normalCaptureStartOperation != null &&
      _normalCaptureStartOperation == _epoch;

  /// A terminal turn may still own the full-duplex recorder that watched it.
  /// That owner must be allowed into the teardown step, but normal capture is
  /// not eligible until [_disarmFullDuplex] acknowledges its release.
  bool get _runtimeMayScheduleListening {
    final state = _runtime.state;
    final captureCanBeReleased =
        state.captureOwner == VoiceCaptureOwner.none ||
        state.captureOwner == VoiceCaptureOwner.fullDuplexStarting ||
        state.captureOwner == VoiceCaptureOwner.fullDuplex;
    return state.lifecycle == VoiceRuntimeLifecycle.running &&
        state.rearmRequested &&
        captureCanBeReleased &&
        state.transcriptionOwner == VoiceTranscriptionOwner.none &&
        state.playbackOwner == VoicePlaybackOwner.none &&
        state.backendState == VoiceBackendState.idle &&
        !state.bargeSpeechActive;
  }

  VoiceConversationIdentity _voiceIdentity(
    ActiveChat chat,
    String ownerProfile,
  ) => VoiceConversationIdentity(
    connectionId: chat.connection.id,
    ownerProfile: ownerProfile,
    storedSessionId: chat.storedSessionId ?? chat.logicalSessionId,
    runtimeSessionId: chat.desktopRuntimeSessionId ?? '',
  );

  void _refreshVoiceIdentityIfSafe() {
    final chat = _chat;
    final binding = _turnBinding;
    if (chat == null || binding == null) return;
    final rebound = _runtime.rebindIdentity(
      binding,
      _voiceIdentity(chat, _profile),
    );
    if (rebound != null) _turnBinding = rebound;
  }

  bool get _isEnglish => voice.voiceLang.toLowerCase().startsWith('en');

  String _sttUnavailableNote(SttCheck check) => _isEnglish
      ? 'Voice recognition is not ready (${check.status.name}).'
      : 'El reconocimiento de voz no está listo (${check.status.name}).';

  static String? _pendingInputKey(ActiveChat? chat) {
    if (chat == null) return null;
    final approval = chat.pendingApproval;
    if (approval != null) {
      final requestId =
          approval['request_id'] ?? approval['approval_id'] ?? approval['id'];
      if (requestId != null && requestId.toString().isNotEmpty) {
        return 'approval:${requestId.toString()}';
      }
      return 'approval:${[approval['command'], approval['tool'], approval['description'], approval['pattern_key']].map((value) => value?.toString() ?? '').join('\u0000')}';
    }
    final prompt = chat.pendingInteractivePrompt;
    if (prompt == null) return null;
    return 'interactive:${prompt.key.runtimeSessionId}:${prompt.key.requestId}';
  }

  /// ¿Está sonando (o encolada) la respuesta real del asistente?
  bool get _narrationAudioInFlight =>
      _narrationTask != null || _nativeSpeechStream != null;

  /// A terminal backend event cannot reopen normal STT while another voice
  /// owner is still capturing, submitting or draining audible narration.
  bool get _rearmBlocked =>
      _bargeCaptureInFlight ||
      _bargeTurnSubmitting ||
      _narrationAudioInFlight ||
      (_playbackTailGuardTask != null && _playbackTailGuardEpoch == _epoch);

  static String? _latestToolLabel(ActiveChat? chat) =>
      chat?.activeVoiceToolLabel;

  Object get _uiProjection => (
    active: active,
    sessionId: sessionId,
    ownerTitle: ownerChat?.sessionTitle,
    phase: phase,
    note: note,
    activeTool: activeTool,
    publicCommentary: publicCommentary,
    responding: responding,
    paused: paused,
    overlayMinimized: overlayMinimized,
    userPaused: userPaused,
    audioLeaseRequired: audioLeaseRequired,
    backendActive: backendActive,
    spokenInterruptionArmed: spokenInterruptionArmed,
    whisper: whisper,
  );

  void _notify() {
    if (_disposed) return;
    final projection = _uiProjection;
    // El chat ya publica cada delta mediante su ValueNotifier estrecho. Voz no
    // consume `assistantResponse`, así que un token que no cambia fase,
    // herramienta o controles no debe reconstruir ChatScreen ni
    // volver a sincronizar la notificación FGS.
    if (projection == _lastNotifiedUiProjection) return;
    _lastNotifiedUiProjection = projection;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    voice.bargeInEnabled.removeListener(_onBargeInPreferenceChanged);
    ++_epoch;
    _runtime.exit();
    _turnBinding = null;
    final speechLease = _conversationSpeechLease;
    _conversationSpeechLease = null;
    if (speechLease != null) {
      voice.endConversationSpeechLease(speechLease);
    }
    _normalCaptureToken = null;
    _bargeRuntimeToken = null;
    _playbackRuntimeToken = null;
    _pendingInputAudioGeneration++;
    active = false;
    _bargeGeneration++;
    _bargeCaptureInFlight = false;
    _bargeTurnSubmitting = false;
    _bargeInterruptedPlayback = false;
    _bargeInterruptTask = null;
    _cancelNativeSpeechFeed();
    _narration?.silence();
    final fullDuplex = _fullDuplex;
    _fullDuplex = null;
    if (fullDuplex != null) unawaited(fullDuplex.dispose());
    unawaited(_chatSub?.cancel());
    unawaited(_sttSub?.cancel());
    _chatSub = null;
    _sttSub = null;
    _modelHandoff = null;
    _chat = null;
    _disposed = true;
    unawaited(_unavailable.close());
    super.dispose();
  }
}
