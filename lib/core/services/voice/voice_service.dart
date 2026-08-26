// Orquestador de voz: mantiene los ajustes, construye los motores STT/TTS
// activos y expone una API simple a la UI (dictar / hablar / parar). La clave
// de ElevenLabs vive en el Keystore (SecureStorage app-level).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import '../secure_storage.dart';
import 'conversation/native_voice.dart';
import 'conversation/voice_consent_store.dart';
import 'device_memory_profile.dart';
import 'hermes_speech_stream.dart';
import 'stt_hermes_server.dart';
import 'read_aloud_session.dart';
import 'speech_renderer.dart';
import 'spoken_text.dart';
import 'stt_engine.dart';
import 'stt_remote.dart';
import 'stt_sherpa.dart';
import 'tts_engine.dart';
import 'tts_model_manager.dart';
import 'voice_lang.dart';
import 'voice_settings.dart';

/// Reserva opaca para preparar el Dictado oficial de Hermes.
///
/// El probe de disponibilidad es asíncrono. Esta reserva impide que el
/// resultado tardío de una pantalla anterior sustituya el perfil o el cliente
/// autenticado que ya instaló la pantalla visible.
final class HermesServerDictationPreparation {
  const HermesServerDictationPreparation._(this._owner, this._generation);

  final Object _owner;
  final int _generation;
}

/// Resultado de comprobar si el dictado puede funcionar.
enum SttStatus {
  /// Listo para dictar con [SttCheck.engine].
  ready,

  /// Falta conceder el permiso de micrófono.
  needsMicPermission,

  /// El motor Whisper está elegido pero falta descargar el modelo.
  needsWhisperModel,

  /// El motor en vivo (sherpa) está elegido pero falta descargar su modelo.
  needsSherpaModel,

  /// El motor por servidor está elegido pero falta configurar la URL, o el
  /// servidor no responde (red/token).
  needsServerConfig,

  /// El móvil no tiene reconocedor de voz del sistema (p.ej. sin servicios de
  /// Google) y no hay modelo Whisper para caer. Sugerir Whisper on-device.
  systemUnavailable,
}

/// Comprobación de disponibilidad del dictado y del motor elegido.
///
/// La ruta nunca cambia de motor a escondidas: si el elegido no está listo, la
/// UI recibe un estado accionable para que el usuario decida qué hacer.
class SttCheck {
  final SttStatus status;
  final SttEngineKind engine;
  const SttCheck(this.status, this.engine);
  bool get ready => status == SttStatus.ready;
}

/// La ruta de servidor elegida dejó de poder reproducir la respuesta.
///
/// No incluye el error remoto para no filtrar URLs, credenciales ni detalles
/// del proveedor. La conversación lo traduce a un estado recuperable visible y
/// nunca lo utiliza como permiso para cambiar a un motor local.
class VoiceRouteUnavailableException implements Exception {
  const VoiceRouteUnavailableException();

  @override
  String toString() => 'VoiceRouteUnavailableException';
}

enum VoiceRouteKind { phone, server }

/// Ruta inmutable de una conversación manual.
///
/// Las preferencias pueden cambiar mientras Voz está minimizada, pero esos
/// cambios pertenecen a la próxima entrada. El runtime actual conserva tanto
/// el tipo de ruta como los motores y su configuración no secreta hasta Exit.
@immutable
class VoiceRouteSnapshot {
  final VoiceRouteKind kind;
  final SttEngineKind sttEngine;
  final TtsEngineKind ttsEngine;
  final int createdAtEpoch;
  final VoiceSettings _settings;

  const VoiceRouteSnapshot._({
    required this.kind,
    required this.sttEngine,
    required this.ttsEngine,
    required this.createdAtEpoch,
    required this._settings,
  });
}

/// Identidad opaca de la cola TTS que pertenece a una entrada concreta en
/// modo Voz.
///
/// `Exit` la invalida de forma síncrona, antes de esperar al player, al worker
/// ONNX o al foreground service. Así, un callback viejo que despierte después
/// del teardown no puede volver a encolar el lote que se había precalentado.
@immutable
class VoiceConversationSpeechLease {
  final int _id;

  const VoiceConversationSpeechLease._(this._id);

  @override
  String toString() => 'VoiceConversationSpeechLease($_id)';
}

/// Una construcción TTS terminó después de que la sesión o su ruta quedaran
/// invalidadas. Es cancelación normal: nunca debe mostrarse como fallo de voz.
class _TtsBuildCancelled implements Exception {
  const _TtsBuildCancelled();
}

class _ReadAwaitResult<T> {
  final bool cancelled;
  final T? value;
  final Object? error;
  final StackTrace? stackTrace;

  const _ReadAwaitResult._({
    required this.cancelled,
    this.value,
    this.error,
    this.stackTrace,
  });

  const _ReadAwaitResult.value(T value)
    : this._(cancelled: false, value: value);

  const _ReadAwaitResult.error(Object error, StackTrace stackTrace)
    : this._(cancelled: false, error: error, stackTrace: stackTrace);

  const _ReadAwaitResult.cancelled() : this._(cancelled: true);
}

/// Una frase pendiente en la cola de habla. [local] fuerza el TTS del sistema
/// (on-device, latencia ~0, sin coste) para avisos funcionales que requieren al
/// usuario, como una aprobación. La respuesta real del agente va con [local] en
/// false → motor configurado (premium si lo hay).
class _Utterance {
  final String text;
  final bool local;
  final int generation;
  final bool strictServerRoute;
  final TtsEngineKind responseEngine;
  final VoiceConversationSpeechLease? conversationLease;

  const _Utterance(
    this.text,
    this.local, {
    required this.generation,
    required this.strictServerRoute,
    required this.responseEngine,
    this.conversationLease,
  });
}

abstract interface class VoiceIdleTimer {
  void cancel();
}

typedef VoiceIdleTimerFactory =
    VoiceIdleTimer Function(Duration delay, void Function() callback);

class _DartVoiceIdleTimer implements VoiceIdleTimer {
  final Timer _timer;

  _DartVoiceIdleTimer(Duration delay, void Function() callback)
    : _timer = Timer(delay, callback);

  @override
  void cancel() => _timer.cancel();
}

class VoiceService {
  final SharedPreferences _prefs;
  final SecureStorage _secure;
  final Duration heavyModelIdleTimeout;
  final VoiceIdleTimerFactory _idleTimerFactory;

  static const String _elevenKeyName = 'elevenlabs_key';

  VoiceSettings _settings;
  late final ValueNotifier<bool> bargeInEnabled;
  late final VoiceConsentStore voiceConsent = VoiceConsentStore(_prefs);
  late final StreamingTtsProfile _legacyStreamingTtsProfile;
  final ValueNotifier<bool> speaking = ValueNotifier<bool>(false);
  int _activeTtsPreviews = 0;
  final ReadAloudSession _readAloudSession = ReadAloudSession();

  /// Estado por mensaje de la lectura manual/automática. A diferencia del
  /// booleano histórico [speaking], incluye propietario, cursor, fase y epoch.
  ValueListenable<ReadAloudSnapshot> get readAloud => _readAloudSession.state;

  /// Barrera opcional instalada por la raíz Android antes del primer audio.
  /// Permite adquirir `mediaPlayback` en el único FGS sin acoplar este servicio
  /// a lifecycle, notificaciones ni plugins de plataforma.
  Future<bool> Function()? prepareReadAloudPlayback;

  Completer<void> _readCancelled = Completer<void>();
  Future<void>? _readTask;
  Future<void> _readStopBarrier = Future<void>.value();
  bool _readStopInProgress = false;
  int _legacyReadSequence = 0;
  String? _lastAutoReadKey;

  /// Nivel de micrófono normalizado (0 silencio … 1 fuerte) durante el dictado
  /// con Whisper. La UI lo usa para hacer latir el orbe con la voz. Vale 0
  /// cuando no se está grabando o con el motor del sistema.
  final ValueNotifier<double> micLevel = ValueNotifier<double>(0);
  final ValueNotifier<bool> microphoneCapturing = ValueNotifier<bool>(false);

  /// Gestor de modelos de voz neuronal on-device (descarga/extracción).
  final TtsModelManager ttsModels = TtsModelManager();

  /// Gestor de modelos del STT en vivo (sherpa-onnx): descarga/extracción.
  final SherpaSttModelManager sherpaModels = SherpaSttModelManager();

  TtsEngine? _tts;
  TtsEngine?
  _localTts; // TTS del sistema para avisos funcionales (ver [_Utterance]).
  Future<void>? _ttsDisposalTail;
  Future<TtsEngine>? _ttsBuildInFlight;
  int? _ttsBuildInFlightEpoch;
  int _ttsBuildEpoch = 0;
  SttEngine? _stt;
  // Serializa liberaciones STT. Pause/Stop y X pueden encadenarse antes de que
  // el plugin termine de destruir AudioRecord; la salida debe esperar esa cola
  // antes de liberar las cachés nativas de Sherpa.
  Future<void>? _sttDisposalTail;
  VoiceIdleTimer? _heavyModelIdleTimer;
  // Identidad lógica de la conversación. Mientras siga activa conserva el
  // snapshot de ruta aunque Pause haya soltado todos los recursos acústicos.
  bool _voiceConversationActive = false;
  // Lease efectiva de micrófono/reproducción/modelos. A diferencia de
  // [_voiceConversationActive], Pause puede desactivarla sin convertir Resume
  // en una conversación nueva ni permitir que cambie Phone/Server.
  bool _voiceConversationAudioLeaseActive = false;
  VoiceRouteSnapshot? _voiceRouteSnapshot;
  int _voiceRouteEpoch = 0;
  bool _dictationActive = false;
  int _dictationEpoch = 0;
  bool _memoryPressureEvictionPending = false;
  bool _disposed = false;

  Future<void> _disposeSttEngine(SttEngine? engine, {required String reason}) {
    if (engine == null) {
      return _sttDisposalTail ?? Future<void>.value();
    }
    final previous = _sttDisposalTail;
    final completion = Completer<void>();
    final tail = completion.future;
    _sttDisposalTail = tail;
    unawaited(() async {
      try {
        if (previous != null) await previous;
        await engine.dispose();
      } catch (error) {
        debugPrint('[voice-stab] disposeStt reason=$reason error: $error');
      } finally {
        if (!completion.isCompleted) completion.complete();
        if (identical(_sttDisposalTail, tail)) _sttDisposalTail = null;
      }
    }());
    return tail;
  }

  // Tipo del motor STT cacheado en [_stt]. Permite reportar el motor REAL ya
  // resuelto (incluido el fallback sistema→Whisper) al reutilizarlo entre turnos
  // sin reconstruirlo. Ver [checkStt] (FIX-1, TASK-022).
  SttEngineKind? _sttKind;

  // Binding efímero del Dictado oficial Hermes. Es deliberadamente distinto
  // de `_nativeTranscribe`: este solo cubre voz→texto del composer y nunca
  // activa TTS, snapshot de conversación ni contadores de Modo Voz.
  Object? _hermesDictationOwner;
  HermesTranscribeRequest? _hermesDictationTranscribe;
  VoidCallback? _hermesDictationOnDispose;
  HermesServerDictationPreparation? _hermesDictationPreparation;
  int _hermesDictationPreparationGeneration = 0;

  // Idioma de voz efectivo con el que se construyó [_stt] (spec 031). Si el
  // usuario cambia el idioma de la app, el motor cacheado seguiría dictando en
  // el idioma anterior: [_recycleSttIfLangChanged] lo recicla (contrato I3).
  String? _sttLang;

  /// Idioma de voz efectivo actual ('es'|'en'), derivado del idioma de la app.
  String get voiceLang => effectiveVoiceLang(_prefs);

  /// Recicla el motor STT cacheado si el idioma de voz efectivo cambió desde
  /// que se construyó. El motor por servidor queda fuera: es neutral respecto
  /// al idioma (FR-010) y reciclarlo tiraría su WS persistente sin motivo.
  /// Devuelve el idioma efectivo para que el llamador construya con él.
  String _recycleSttIfLangChanged() {
    final lang = voiceLang;
    if (_stt != null &&
        _sttLang != null &&
        _sttLang != lang &&
        _sttKind != SttEngineKind.server &&
        _sttKind != SttEngineKind.hermesServer) {
      final old = _stt;
      _stt = null;
      _sttKind = null;
      unawaited(_disposeSttEngine(old, reason: 'language_changed'));
    }
    _sttLang = lang;
    return lang;
  }

  /// Inyección de motor STT **solo para tests** (nunca en producción): si está
  /// definida, [_sttEngine] y [checkStt] construyen el motor con ella en vez del
  /// real, que toca plugins de plataforma y el sistema de archivos. Permite
  /// verificar el ciclo reutilizar/parar/liberar sin hardware (FIX-1, TASK-022).
  @visibleForTesting
  SttEngine Function()? debugSttFactory;

  /// Inyección de TTS para pruebas de la sesión sin plugins de plataforma.
  @visibleForTesting
  TtsEngine Function()? debugTtsFactory;

  /// Constructor TTS asíncrono solo para reproducir carreras de inicialización
  /// en tests. Producción siempre usa los constructores reales de [_ttsEngine].
  @visibleForTesting
  Future<TtsEngine> Function()? debugTtsBuilder;

  VoiceService(
    this._prefs,
    this._secure, {
    VoiceSettings? initialSettings,
    this.heavyModelIdleTimeout = const Duration(seconds: 90),
    VoiceIdleTimerFactory? idleTimerFactory,
  }) : _settings = initialSettings ?? VoiceSettings.load(_prefs),
       _idleTimerFactory =
           idleTimerFactory ??
           ((delay, callback) => _DartVoiceIdleTimer(delay, callback)) {
    bargeInEnabled = ValueNotifier<bool>(_settings.bargeInEnabled);
    // El token histórico compartido se atribuye una sola vez al perfil que
    // estaba activo al arrancar. Cambiar de selector después no puede migrarlo
    // accidentalmente al otro proveedor.
    _legacyStreamingTtsProfile = _settings.streamingTtsProfile;
  }

  VoiceSettings get settings => _settings;

  /// Punto de compatibilidad compartido por dictado y conversación antes de
  /// abrir AudioRecord. La captura manual ya no necesita coordinar otro dueño
  /// permanente del micrófono.
  Future<bool> prepareForMicrophoneCapture() => Future<bool>.value(true);

  void _setDictationActive(bool active) {
    _dictationActive = active;
    if (microphoneCapturing.value != active) {
      microphoneCapturing.value = active;
    }
  }

  bool get _heavyModelUseActive {
    final read = _readAloudSession.snapshot;
    return _voiceConversationAudioLeaseActive ||
        _dictationActive ||
        _draining ||
        _speechQueue.isNotEmpty ||
        _activeTtsPreviews > 0 ||
        _readStopInProgress ||
        read.isActive ||
        read.phase == ReadAloudPhase.paused;
  }

  void setVoiceConversationActive(bool active) {
    if (_voiceConversationActive == active) {
      // Una señal tardía de Continue nunca puede recuperar recursos después
      // de Exit. Reconciliar false es idempotente y deja la lease cerrada.
      if (!active) setVoiceConversationAudioLeaseActive(false);
      return;
    }
    if (active) {
      final settings = _settings;
      final onDevice = onDeviceVoiceActive;
      _voiceRouteSnapshot = VoiceRouteSnapshot._(
        kind: nativeVoiceActive ? VoiceRouteKind.server : VoiceRouteKind.phone,
        sttEngine: _resolveConversationSttEngine(settings, onDevice: onDevice),
        ttsEngine: _resolveConversationTtsEngine(settings, onDevice: onDevice),
        createdAtEpoch: ++_voiceRouteEpoch,
        settings: settings,
      );
    } else {
      _voiceRouteSnapshot = null;
      _voiceRouteEpoch++;
    }
    _voiceConversationActive = active;
    setVoiceConversationAudioLeaseActive(active);
  }

  /// Publica si la conversación lógica posee ahora recursos acústicos.
  ///
  /// `false` permite evacuar Sherpa/Whisper y ONNX sin borrar el snapshot de
  /// ruta. `true` solo se acepta mientras exista la conversación, de modo que
  /// un callback stale posterior a Exit no pueda volver a cargar modelos.
  void setVoiceConversationAudioLeaseActive(bool active) {
    final effectiveActive = active && _voiceConversationActive;
    if (_voiceConversationAudioLeaseActive == effectiveActive) return;
    _voiceConversationAudioLeaseActive = effectiveActive;
    if (effectiveActive) {
      _cancelHeavyModelIdleRelease();
    } else {
      _scheduleHeavyModelIdleRelease();
    }
  }

  void _cancelHeavyModelIdleRelease() {
    _heavyModelIdleTimer?.cancel();
    _heavyModelIdleTimer = null;
  }

  bool get _hasEvictableHeavyModel =>
      (effectiveConversationTtsEngine == TtsEngineKind.onnx && _tts != null) ||
      (_stt != null &&
          !_sttNativeVoice &&
          (_sttKind == SttEngineKind.sherpaLive ||
              _sttKind == SttEngineKind.whisper));

  void _scheduleHeavyModelIdleRelease() {
    _cancelHeavyModelIdleRelease();
    if (_disposed || _heavyModelUseActive) return;
    // Preview TTS receives an external, ephemeral engine. Scheduling a 90 s
    // timer when VoiceService owns no heavy model leaks that timer into widget
    // tests and keeps a real app isolate awake for no useful cleanup.
    if (!_hasEvictableHeavyModel) {
      _memoryPressureEvictionPending = false;
      return;
    }
    if (_memoryPressureEvictionPending) {
      _memoryPressureEvictionPending = false;
      unawaited(_evictIdleHeavyModels(reason: 'memory_pressure_deferred'));
      return;
    }
    if (heavyModelIdleTimeout <= Duration.zero) {
      unawaited(_evictIdleHeavyModels(reason: 'idle'));
      return;
    }
    _heavyModelIdleTimer = _idleTimerFactory(heavyModelIdleTimeout, () {
      _heavyModelIdleTimer = null;
      unawaited(_evictIdleHeavyModels(reason: 'idle'));
    });
  }

  Future<void> _evictIdleHeavyModels({required String reason}) async {
    if (_disposed || _heavyModelUseActive) return;
    final releaseTts =
        effectiveConversationTtsEngine == TtsEngineKind.onnx && _tts != null;
    final releaseStt =
        _stt != null &&
        !_sttNativeVoice &&
        (_sttKind == SttEngineKind.sherpaLive ||
            _sttKind == SttEngineKind.whisper);
    if (!releaseTts && !releaseStt) return;
    debugPrint(
      '[voice-stab] idle eviction reason=$reason '
      'tts=$releaseTts stt=$releaseStt',
    );
    await Future.wait<void>([
      if (releaseTts) disposeTtsForVoiceExit(),
      if (releaseStt) disposeSttForVoiceExit(),
    ]);
  }

  /// Sherpa/Whisper y Piper/ONNX reservan cientos de MB cada uno. En móviles
  /// justos de memoria no deben permanecer cargados a la vez: además de
  /// disparar el RSS, la presión convierte el cambio escuchar→hablar en jank o
  /// ANR. En dispositivos con RAM holgada (spec 048/US4) la recarga por turno
  /// era el mayor coste de fluidez medido (3,4-4,4 s por vuelta a escucha), así
  /// que ahí los motores quedan residentes — salvo presión de memoria real,
  /// que reactiva la serialización durante el resto de la sesión de voz.
  bool get serializesHeavyLocalVoiceModels =>
      !nativeVoiceActive &&
      effectiveConversationTtsEngine == TtsEngineKind.onnx &&
      (effectiveConversationSttEngine == SttEngineKind.sherpaLive ||
          effectiveConversationSttEngine == SttEngineKind.whisper) &&
      (!_deviceMemory.residencyEligible || _voiceMemoryPressure);

  // ── Modo de voz nativo Desktop (spec 048/US5) ─────────────────────────
  // Con capacidad del servidor y consentimiento aceptado, la superficie de
  // voz activa este modo: STT/TTS del propio servidor (las voces de Desktop),
  // captura y endpointing locales. La ruta es estricta: si Hermes falla, la
  // sesión conserva STT/TTS de servidor y expone el fallo; nunca cambia a los
  // motores locales sin una elección explícita. Sin consentimiento nadie llama
  // a enableNativeVoice y ningún audio sale del dispositivo.
  bool _onDeviceConversationRoute = false;
  NativeVoiceSession? _nativeVoiceSession;
  HermesSpeakRequest? _nativeSpeak;
  HermesTranscribeRequest? _nativeTranscribe;
  HermesSpeechStreamSessionFactory? _nativeSpeechStreamFactory;
  HermesSpeechStreamSession? _activeNativeSpeechStream;
  int _nativeSpeechStreamEpoch = 0;
  bool _nativeSpeechStreamingDisabled = false;
  bool _sttNativeVoice = false;
  VoidCallback? _nativeVoiceOnDispose;

  /// Reproductor inyectable del TTS nativo (solo tests).
  @visibleForTesting
  TtsAudioPlaybackFactory? debugNativePlaybackFactory;

  bool get nativeVoiceActive =>
      _nativeVoiceSession?.active == true &&
      _nativeSpeak != null &&
      _nativeTranscribe != null;

  bool get hermesServerDictationReady =>
      _hermesDictationTranscribe != null &&
      _settings.sttEngine == SttEngineKind.hermesServer;

  /// Inicia una preparación exclusiva. Comenzar otra invalida la anterior,
  /// aunque su probe HTTP siga en vuelo.
  HermesServerDictationPreparation beginHermesServerDictationPreparation({
    required Object owner,
  }) {
    // Desde este momento la siguiente ruta es la autoritativa. Mantener el
    // binding anterior mientras se comprueba otro perfil permitiría reutilizar
    // audio con una identidad que el usuario ya está sustituyendo.
    disableHermesServerDictation(force: true);
    final preparation = HermesServerDictationPreparation._(
      owner,
      ++_hermesDictationPreparationGeneration,
    );
    _hermesDictationPreparation = preparation;
    return preparation;
  }

  /// Cancela solo esta preparación. Un resultado antiguo nunca puede cancelar
  /// una reserva posterior, aunque ambas procedan del mismo widget.
  bool cancelHermesServerDictationPreparation(
    HermesServerDictationPreparation preparation,
  ) {
    if (!identical(preparation, _hermesDictationPreparation)) return false;
    _hermesDictationPreparation = null;
    _hermesDictationPreparationGeneration++;
    return true;
  }

  /// Instala la transcripción oficial de Hermes para el propietario visible
  /// del dictado. Reemplazar chat/instancia cierra primero el cliente anterior.
  bool enableHermesServerDictation({
    required Object owner,
    required HermesServerDictationPreparation preparation,
    required HermesTranscribeRequest transcribe,
    VoidCallback? onDispose,
  }) {
    if (_disposed ||
        !identical(preparation, _hermesDictationPreparation) ||
        !identical(preparation._owner, owner) ||
        preparation._generation != _hermesDictationPreparationGeneration) {
      return false;
    }
    _hermesDictationPreparation = null;
    final previousDispose = _hermesDictationOnDispose;
    _hermesDictationOwner = owner;
    _hermesDictationTranscribe = transcribe;
    _hermesDictationOnDispose = onDispose;
    final disposal = _invalidateHermesDictationEngine(
      reason: 'hermes_dictation_rebind',
    );
    _releaseHermesDictationResource(previousDispose, after: disposal);
    return true;
  }

  /// Libera solo el binding que pertenece a [owner]. Una pantalla antigua no
  /// puede cerrar el cliente que ya instaló otro chat.
  bool disableHermesServerDictation({Object? owner, bool force = false}) {
    var changed = false;
    final preparation = _hermesDictationPreparation;
    if (preparation != null &&
        (force || owner == null || identical(owner, preparation._owner))) {
      _hermesDictationPreparation = null;
      _hermesDictationPreparationGeneration++;
      changed = true;
    }
    if (!force && owner != null && !identical(owner, _hermesDictationOwner)) {
      return changed;
    }
    if (_hermesDictationTranscribe == null &&
        _hermesDictationOnDispose == null) {
      return changed;
    }
    final release = _hermesDictationOnDispose;
    _hermesDictationOwner = null;
    _hermesDictationTranscribe = null;
    _hermesDictationOnDispose = null;
    final disposal = _invalidateHermesDictationEngine(
      reason: 'hermes_dictation_off',
    );
    _releaseHermesDictationResource(release, after: disposal);
    return true;
  }

  Future<void>? _invalidateHermesDictationEngine({required String reason}) {
    if (_sttKind != SttEngineKind.hermesServer) return null;
    final previous = _stt;
    _stt = null;
    _sttKind = null;
    _sttNativeVoice = false;
    if (previous == null) return null;
    return _disposeSttEngine(previous, reason: reason);
  }

  void _releaseHermesDictationResource(
    VoidCallback? release, {
    required Future<void>? after,
  }) {
    if (after == null) {
      _releaseNativeVoiceResource(release);
      return;
    }
    unawaited(
      after.whenComplete(() => _releaseNativeVoiceResource(release)),
    );
  }

  Future<Map<String, dynamic>> _guardedHermesDictationTranscribe(
    String dataUrl,
    String mimeType,
  ) {
    final transcribe = _hermesDictationTranscribe;
    if (transcribe == null) {
      throw StateError('Dictado de Hermes no configurado.');
    }
    return transcribe(dataUrl, mimeType);
  }

  /// `En este móvil` es una ruta completa de conversación, no un alias de las
  /// preferencias avanzadas. Si estas apuntan a red/nube, Voz conserva esas
  /// preferencias pero usa los equivalentes on-device durante la sesión.
  bool get onDeviceVoiceActive =>
      _onDeviceConversationRoute && !nativeVoiceActive;

  VoiceRouteSnapshot? get activeVoiceRoute => _voiceRouteSnapshot;

  VoiceSettings get _engineSettings =>
      _voiceRouteSnapshot?._settings ?? _settings;

  SttEngineKind _resolveConversationSttEngine(
    VoiceSettings settings, {
    required bool onDevice,
  }) => onDevice
      ? switch (settings.sttEngine) {
          SttEngineKind.whisper => SttEngineKind.whisper,
          SttEngineKind.sherpaLive => SttEngineKind.sherpaLive,
          SttEngineKind.hermesServer => SttEngineKind.sherpaLive,
          SttEngineKind.system ||
          SttEngineKind.server => SttEngineKind.sherpaLive,
        }
      : settings.sttEngine;

  TtsEngineKind _resolveConversationTtsEngine(
    VoiceSettings settings, {
    required bool onDevice,
  }) => onDevice
      ? switch (settings.ttsEngine) {
          TtsEngineKind.device => TtsEngineKind.device,
          TtsEngineKind.onnx => TtsEngineKind.onnx,
          TtsEngineKind.elevenlabs ||
          TtsEngineKind.streaming ||
          TtsEngineKind.customHttp => TtsEngineKind.onnx,
        }
      : settings.ttsEngine;

  SttEngineKind get effectiveConversationSttEngine =>
      _voiceRouteSnapshot?.sttEngine ??
      _resolveConversationSttEngine(_settings, onDevice: onDeviceVoiceActive);

  TtsEngineKind get effectiveConversationTtsEngine =>
      _voiceRouteSnapshot?.ttsEngine ??
      _resolveConversationTtsEngine(_settings, onDevice: onDeviceVoiceActive);

  /// El recorder full-duplex puede reutilizar el STT de servidor seleccionado
  /// o el worker Sherpa local. Otros motores requieren abrir su propio
  /// recorder y por tanto fallan cerrado durante playback.
  bool get fullDuplexTranscriptionAvailable =>
      nativeVoiceActive ||
      effectiveConversationSttEngine == SttEngineKind.sherpaLive;

  bool get nativeSpeechStreamingAvailable =>
      nativeVoiceActive &&
      _nativeSpeechStreamFactory != null &&
      !_nativeSpeechStreamingDisabled;

  /// Activa el modo nativo para la sesión de voz que empieza. Los callbacks
  /// encapsulan el DashboardClient autenticado de la conexión activa.
  bool enableNativeVoice({
    required HermesSpeakRequest speak,
    required HermesTranscribeRequest transcribe,
    HermesSpeechStreamSessionFactory? speechStream,
    VoidCallback? onDispose,
  }) {
    final frozen = _voiceRouteSnapshot;
    if (_voiceConversationActive && frozen != null) {
      debugPrint(
        '[voice-stab] cambio de ruta ignorado durante conversación activa '
        'current=${frozen.kind.name} requested=server',
      );
      return false;
    }
    final previousDispose = _nativeVoiceOnDispose;
    _onDeviceConversationRoute = false;
    _nativeSpeechStreamEpoch += 1;
    unawaited(_cancelNativeSpeechStream());
    _nativeVoiceSession = NativeVoiceSession();
    _nativeSpeak = speak;
    _nativeTranscribe = transcribe;
    _nativeSpeechStreamFactory = speechStream;
    _nativeSpeechStreamingDisabled = false;
    _nativeVoiceOnDispose = onDispose;
    _invalidateEnginesForNativeSwitch(reason: 'native_voice_on');
    _releaseNativeVoiceResource(previousDispose);
    return true;
  }

  /// Activa para la próxima conversación una ruta estrictamente on-device sin
  /// modificar las preferencias persistidas de dictado o lectura.
  bool enableOnDeviceVoice() {
    final frozen = _voiceRouteSnapshot;
    if (_voiceConversationActive && frozen != null) {
      debugPrint(
        '[voice-stab] cambio de ruta ignorado durante conversación activa '
        'current=${frozen.kind.name} requested=phone',
      );
      return false;
    }
    if (onDeviceVoiceActive) return true;
    disableNativeVoice();
    _onDeviceConversationRoute = true;
    _invalidateEnginesForNativeSwitch(reason: 'on_device_voice_on');
    return true;
  }

  /// Limpia cualquier ruta temporal de conversación (rechazo, cambio o salida).
  bool disableNativeVoice({bool force = false}) {
    final frozen = _voiceRouteSnapshot;
    if (!force && _voiceConversationActive && frozen != null) {
      debugPrint(
        '[voice-stab] cierre de ruta ignorado durante conversación activa '
        'current=${frozen.kind.name}',
      );
      return false;
    }
    final hadOnDeviceRoute = _onDeviceConversationRoute;
    _onDeviceConversationRoute = false;
    if (_nativeVoiceSession == null &&
        _nativeSpeak == null &&
        _nativeTranscribe == null &&
        _nativeVoiceOnDispose == null) {
      if (hadOnDeviceRoute) {
        _invalidateEnginesForNativeSwitch(reason: 'on_device_voice_off');
      }
      return hadOnDeviceRoute;
    }
    final release = _nativeVoiceOnDispose;
    _nativeVoiceSession = null;
    _nativeSpeak = null;
    _nativeTranscribe = null;
    _nativeSpeechStreamFactory = null;
    _nativeSpeechStreamingDisabled = false;
    _nativeVoiceOnDispose = null;
    _nativeSpeechStreamEpoch += 1;
    unawaited(_cancelNativeSpeechStream());
    _invalidateEnginesForNativeSwitch(reason: 'native_voice_off');
    _releaseNativeVoiceResource(release);
    return true;
  }

  void _releaseNativeVoiceResource(VoidCallback? release) {
    if (release == null) return;
    try {
      release();
    } catch (error) {
      debugPrint(
        '[voice-stab] cierre de sesión nativa omitido '
        '(${error.runtimeType})',
      );
    }
  }

  /// Abre un único WS/AudioTrack para la respuesta actual.
  ///
  /// Un 404/405/426 de upgrade y el frame oficial `fallback` son concluyentes
  /// durante esta sesión nativa. Red, timeout y auth degradan este turno al
  /// POST legado, pero se pueden reintentar en el siguiente.
  Future<HermesSpeechStreamSession?> startNativeSpeechStream() async {
    final factory = _nativeSpeechStreamFactory;
    if (!nativeSpeechStreamingAvailable || factory == null) {
      debugPrint(
        '[VOICE-PERF] voice.speak_stream.unavailable '
        'native=$nativeVoiceActive factory=${factory != null} '
        'disabled=$_nativeSpeechStreamingDisabled',
      );
      return null;
    }
    final operation = ++_nativeSpeechStreamEpoch;
    debugPrint('[VOICE-PERF] voice.speak_stream.open_attempt');
    await _cancelNativeSpeechStream(invalidate: false);
    if (operation != _nativeSpeechStreamEpoch ||
        !nativeSpeechStreamingAvailable) {
      return null;
    }
    HermesSpeechStreamSession session;
    try {
      session = await factory();
    } catch (error) {
      final endpointUnavailable =
          error is HermesSpeechStreamOpenException && error.endpointUnavailable;
      debugPrint(
        '[VOICE-PERF] voice.speak_stream.open_error '
        'type=${error.runtimeType} '
        'endpoint_unavailable=$endpointUnavailable',
      );
      if (error is HermesSpeechStreamOpenException &&
          error.endpointUnavailable) {
        _nativeSpeechStreamingDisabled = true;
      }
      return null;
    }
    if (operation != _nativeSpeechStreamEpoch ||
        !nativeSpeechStreamingAvailable) {
      await session.cancel();
      return null;
    }
    _activeNativeSpeechStream = session;
    debugPrint('[VOICE-PERF] voice.speak_stream.open_ok');
    unawaited(
      session.done.then((outcome) {
        debugPrint(
          '[VOICE-PERF] voice.speak_stream.done '
          'outcome=${outcome.name} fallback=${session.fallbackKind?.name ?? 'none'}',
        );
        if (identical(_activeNativeSpeechStream, session)) {
          _activeNativeSpeechStream = null;
        }
        if (outcome == HermesSpeechStreamOutcome.fallback &&
            session.fallbackKind ==
                HermesSpeechStreamFallbackKind.providerUnsupported) {
          _nativeSpeechStreamingDisabled = true;
        }
      }),
    );
    return session;
  }

  Future<void> _cancelNativeSpeechStream({bool invalidate = true}) async {
    if (invalidate) _nativeSpeechStreamEpoch += 1;
    final session = _activeNativeSpeechStream;
    _activeNativeSpeechStream = null;
    if (session == null) return;
    try {
      await session.cancel();
    } catch (_) {
      // La generación nativa ya quedó invalidada por cancel().
    }
  }

  void _invalidateEnginesForNativeSwitch({required String reason}) {
    unawaited(_resetTtsEngine());
    final previous = _stt;
    _stt = null;
    _sttKind = null;
    _sttNativeVoice = false;
    if (previous != null) {
      unawaited(_disposeSttEngine(previous, reason: reason));
    }
  }

  Future<Map<String, dynamic>> _guardedNativeTranscribe(
    String dataUrl,
    String mimeType,
  ) async {
    final transcribe = _nativeTranscribe;
    if (transcribe == null) {
      throw StateError('Modo de voz nativo inactivo.');
    }
    try {
      final result = await transcribe(dataUrl, mimeType);
      _nativeVoiceSession?.noteSuccess();
      return result;
    } catch (_) {
      _noteNativeVoiceFailure();
      rethrow;
    }
  }

  /// Transcribes an already captured mono WAV through the consented Hermes
  /// server voice profile. Used by full-duplex pre-roll capture so the first
  /// phoneme is preserved without opening a second recorder.
  Future<String> transcribeNativeWav(Uint8List wavBytes) async {
    if (!nativeVoiceActive || wavBytes.isEmpty) {
      throw StateError('Modo de voz nativo inactivo.');
    }
    final response = await _guardedNativeTranscribe(
      'data:audio/wav;base64,${base64Encode(wavBytes)}',
      'audio/wav',
    );
    if (response['ok'] != true) {
      final detail = response['detail'] ?? response['error'] ?? 'sin detalle';
      throw StateError('El servidor no pudo transcribir: $detail');
    }
    // Hermes Agent considera un transcript vacío una detección válida de
    // silencio. No recortes, amplifiques ni reenvíes el WAV: además de apartarse
    // del contrato oficial, una segunda inferencia añade latencia y puede
    // convertir ruido en una orden falsa.
    return (response['transcript'] ?? '').toString().trim();
  }

  /// Transcribe el PCM que ya capturó el monitor de barge-in sin abrir otro
  /// micrófono. En modo móvil permanece on-device; solo usa Dashboard cuando
  /// la selección explícita de esta sesión activó voz nativa.
  Future<String> transcribeFullDuplexWav(Uint8List wavBytes) async {
    if (nativeVoiceActive) return transcribeNativeWav(wavBytes);
    if (effectiveConversationSttEngine != SttEngineKind.sherpaLive) {
      throw StateError('El STT elegido no admite captura full-duplex.');
    }
    final engine = _sttEngine();
    if (engine is! CapturedWavSttEngine) {
      throw StateError('El STT local no admite el WAV ya capturado.');
    }
    return (engine as CapturedWavSttEngine).transcribeCapturedWav(wavBytes);
  }

  Future<Map<String, dynamic>> _guardedNativeSpeak(String text) async {
    final speak = _nativeSpeak;
    if (speak == null) {
      throw StateError('Modo de voz nativo inactivo.');
    }
    try {
      final result = await speak(text);
      _nativeVoiceSession?.noteSuccess();
      return result;
    } catch (_) {
      _noteNativeVoiceFailure();
      rethrow;
    }
  }

  void _noteNativeVoiceFailure() {
    final session = _nativeVoiceSession;
    if (session == null) return;
    session.noteFailure();
    debugPrint(
      '[voice-stab] fallo de voz Hermes; se conserva la ruta de servidor '
      'consecutive=${session.consecutiveFailures}',
    );
  }

  /// Perfil de memoria del proceso, leído una vez. Inyectable en tests. Solo
  /// Android lee `/proc/meminfo`: en cualquier otra plataforma (tests de
  /// host incluidos) el perfil es "no elegible" y rige la serialización
  /// histórica — el meminfo de una máquina de desarrollo no describe al móvil.
  @visibleForTesting
  DeviceMemoryProfile? debugMemoryProfile;
  DeviceMemoryProfile? _memoryProfile;
  DeviceMemoryProfile get _deviceMemory =>
      debugMemoryProfile ??
      (_memoryProfile ??= Platform.isAndroid
          ? DeviceMemoryProfile.read()
          : const DeviceMemoryProfile(memTotalBytes: 0));

  bool _voiceMemoryPressure = false;

  /// El sistema avisó de presión de memoria (`didHaveMemoryPressure`). Fuerza
  /// la serialización durante la sesión y evacua los modelos locales pesados
  /// inmediatamente si están ociosos. Si hay lease acústica, dictado o una
  /// lectura activa/pausada, la evacuación queda pendiente hasta que ese dueño
  /// libere el recurso. Una conversación lógicamente pausada no bloquea por sí
  /// sola la liberación.
  Future<void> onMemoryPressure() async {
    _voiceMemoryPressure = true;
    _cancelHeavyModelIdleRelease();
    if (_heavyModelUseActive) {
      _memoryPressureEvictionPending = true;
      debugPrint(
        '[voice-stab] presión de memoria: evacuación aplazada por audio activo',
      );
      return;
    }
    _memoryPressureEvictionPending = false;
    debugPrint('[voice-stab] presión de memoria: serialización reactivada');
    await _evictIdleHeavyModels(reason: 'memory_pressure');
  }

  // Niveles de ComponentCallbacks2 (Android). El orden numérico NO ordena
  // severidad: UI_HIDDEN (20) solo informa de que la UI dejó de verse.
  static const int trimMemoryRunningLow = 10;
  static const int trimMemoryRunningCritical = 15;
  static const int trimMemoryUiHidden = 20;

  /// Entrada con nivel real de `onTrimMemory` (MainActivity, canal
  /// `hermes/memory`). La señal binaria `didHaveMemoryPressure` se disparaba
  /// también al ir a background y evacuaba los modelos pesados en cada ida —
  /// cuatro veces en una sesión del Pixel, con 3,4-4,4 s de recarga por turno.
  /// Solo la presión en primer plano (RUNNING_LOW/CRITICAL) o un trim de
  /// background SIN conversación de voz activa evacuan; con la conversación
  /// viva los modelos permanecen residentes porque cada turno los necesita.
  Future<void> onTrimMemory(int level) async {
    if (_disposed || level <= 0 || level == trimMemoryUiHidden) return;
    final foregroundPressure =
        level == trimMemoryRunningLow || level == trimMemoryRunningCritical;
    if (!foregroundPressure && _voiceConversationActive) {
      debugPrint(
        '[voice-stab] trim memory level=$level en background con voz activa: '
        'modelos residentes',
      );
      return;
    }
    await onMemoryPressure();
  }

  bool get voiceDisclosureAccepted => voiceConsent.disclosureAccepted;
  bool get continueVoiceWhenLocked => voiceConsent.continueWhenLocked;
  bool get voiceConversationEnabled => voiceConsent.conversationEnabled;

  Future<void> acceptVoiceDisclosure({required bool continueWhenLocked}) =>
      voiceConsent.acceptDisclosure(continueWhenLocked: continueWhenLocked);

  Future<void> setContinueVoiceWhenLocked(bool value) =>
      voiceConsent.setContinueWhenLocked(value);

  Future<void> setVoiceConversationEnabled(bool value) =>
      voiceConsent.setConversationEnabled(value);

  Future<void> saveSettings(VoiceSettings s) async {
    final prevStt = _settings.sttEngine;
    final prevWhisper = _settings.whisperModel;
    final prevSherpa = _settings.sherpaModel;
    if (_settings.readAloudStopBehavior != s.readAloudStopBehavior ||
        _readAloudSession.snapshot.phase != ReadAloudPhase.idle) {
      // Una preferencia nueva nunca hereda un cursor con semántica antigua, y
      // ningún motor se recicla dejando una lectura aparentemente pausada.
      _invalidateReadOperation(discard: true, stopNative: false);
    }
    _settings = s;
    bargeInEnabled.value = s.bargeInEnabled;
    await s.save(_prefs);
    if (_voiceConversationActive && _voiceRouteSnapshot != null) {
      // La conversación actual conserva su snapshot. Exit ya libera STT/TTS;
      // las preferencias recién guardadas se resolverán en la siguiente entrada.
      debugPrint(
        '[voice-stab] ajustes de motores aplazados hasta la próxima conversación',
      );
      return;
    }
    // Un cambio de voz no puede convivir con el modelo anterior. Invalida cola y
    // lectura, suelta playback+worker y espera la cola de disposals antes de que
    // el siguiente `speak` pueda construir otro modelo nativo.
    await releaseTtsForModelMutation();
    // Reconstruir STT si cambió el motor o cualquiera de sus modelos locales.
    if (prevStt != s.sttEngine ||
        prevWhisper != s.whisperModel ||
        prevSherpa != s.sherpaModel) {
      final oldStt = _stt;
      _stt = null;
      _sttKind = null;
      await _disposeSttEngine(oldStt, reason: 'settings_changed');
    }
  }

  // ── Clave de ElevenLabs (Keystore) ──────────────────────────────────
  Future<String?> elevenKey() => _secure.readAppSecret(_elevenKeyName);
  Future<void> setElevenKey(String key) =>
      _secure.writeAppSecret(_elevenKeyName, key);
  Future<void> clearElevenKey() => _secure.deleteAppSecret(_elevenKeyName);

  // Token del servidor de STT en vivo (faster-whisper). En el Keystore, no en
  // prefs ni en el repo. Cacheamos en memoria para poder construir el motor de
  // forma síncrona (el Keystore es async).
  static const String _serverSttTokenName = 'server_stt_token';
  String _serverTokenCache = '';
  Future<String?> serverSttToken() async {
    final t = await _secure.readAppSecret(_serverSttTokenName);
    _serverTokenCache = t ?? '';
    return t;
  }

  Future<void> setServerSttToken(String token) async {
    _serverTokenCache = token;
    await _secure.writeAppSecret(_serverSttTokenName, token);
  }

  Future<void> clearServerSttToken() async {
    _serverTokenCache = '';
    await _secure.deleteAppSecret(_serverSttTokenName);
  }

  // Token del TTS por streaming (formato OpenAI). Vacío para un Kokoro local sin
  // auth; en la nube (OpenAI/Deepgram) es la API key. En el Keystore, no en prefs.
  static const String _streamTtsTokenName = 'streaming_tts_token';
  static String _streamTtsTokenNameFor(StreamingTtsProfile profile) =>
      '${_streamTtsTokenName}_${profile.id}';

  Future<String?> streamingTtsToken({StreamingTtsProfile? profile}) async {
    final target = profile ?? _settings.streamingTtsProfile;
    final scopedName = _streamTtsTokenNameFor(target);
    final scoped = await _secure.readAppSecret(scopedName);
    if (scoped != null) return scoped;
    if (target != _legacyStreamingTtsProfile) return null;
    final legacy = await _secure.readAppSecret(_streamTtsTokenName);
    if (legacy != null) await _secure.writeAppSecret(scopedName, legacy);
    return legacy;
  }

  Future<void> setStreamingTtsToken(
    String token, {
    StreamingTtsProfile? profile,
  }) async {
    final target = profile ?? _settings.streamingTtsProfile;
    await _secure.writeAppSecret(_streamTtsTokenNameFor(target), token);
    // Mantiene rollback compatible: la clave histórica refleja el perfil que
    // está realmente activo, nunca el formulario inactivo.
    if (target == _settings.streamingTtsProfile) {
      await _secure.writeAppSecret(_streamTtsTokenName, token);
    }
  }

  Future<void> clearStreamingTtsToken({StreamingTtsProfile? profile}) async {
    final target = profile ?? _settings.streamingTtsProfile;
    await _secure.deleteAppSecret(_streamTtsTokenNameFor(target));
    if (target == _settings.streamingTtsProfile) {
      await _secure.deleteAppSecret(_streamTtsTokenName);
    }
  }

  // Credencial de la API TTS REST personalizada. El nombre/prefijo de la
  // cabecera no es secreto y vive en VoiceSettings; solo el valor va al
  // Keystore.
  static const String _customTtsSecretName = 'custom_tts_auth_secret';
  Future<String?> customTtsSecret() =>
      _secure.readAppSecret(_customTtsSecretName);
  Future<void> setCustomTtsSecret(String secret) =>
      _secure.writeAppSecret(_customTtsSecretName, secret);
  Future<void> clearCustomTtsSecret() =>
      _secure.deleteAppSecret(_customTtsSecretName);

  // ── TTS ─────────────────────────────────────────────────────────────
  // Política de motores (local-first, premium opcional):
  //   • LocalNoticeTts  — aprobaciones y preguntas que requieren al usuario.
  //     SIEMPRE TTS del sistema (on-device): latencia ~0, gratis, NUNCA a la
  //     nube. Es [enqueueLocalSpeech] → [_localTtsEngine].
  //   • ResponseTts     — la respuesta real del agente. Motor elegido por el
  //     usuario: sistema, neural on-device o ElevenLabs. Es [enqueueSpeech] →
  //     [_ttsEngine].
  //   • FallbackTts     — siempre el TTS del sistema. Si ResponseTts (típicamente
  //     ElevenLabs: sin red/401/429/timeout/sin clave) falla, [_speakUtterance]
  //     reintenta la frase con el sistema para no quedarnos mudos.
  // El contenido técnico (código/JSON/logs) lo descarta VoiceResponsePolicy antes
  // de encolar, así que nunca llega a ResponseTts ni gasta créditos de nube.
  // Idioma de voz efectivo con el que se construyeron [_tts]/[_localTts]
  // (spec 031): si el idioma de la app cambió, la voz del sistema cacheada
  // seguiría hablando en el idioma anterior (contrato I3).
  String? _ttsLang;

  /// Recicla los TTS cacheados si el idioma de voz efectivo cambió desde que
  /// se construyeron. Devuelve el idioma efectivo para construir con él.
  String _recycleTtsIfLangChanged() {
    final lang = voiceLang;
    if (_ttsLang != null && _ttsLang != lang) {
      // Un builder que todavía resuelva con el idioma anterior no puede
      // publicarse ni convivir con el reemplazo. La epoch lo convierte en un
      // resultado tardío desechable; el single-flight lo deja terminar antes
      // de abrir la siguiente construcción pesada.
      _ttsBuildEpoch++;
      final oldTts = _tts;
      final oldLocal = _localTts;
      _tts = null;
      _localTts = null;
      if (oldTts != null) unawaited(oldTts.dispose());
      if (oldLocal != null) unawaited(oldLocal.dispose());
    }
    _ttsLang = lang;
    return lang;
  }

  Future<TtsEngine> _ttsEngine() async {
    final entryEpoch = _ttsBuildEpoch;
    final pendingDisposal = _ttsDisposalTail;
    if (pendingDisposal != null) await pendingDisposal;
    if (_disposed || entryEpoch != _ttsBuildEpoch) {
      throw const _TtsBuildCancelled();
    }
    final lang = _recycleTtsIfLangChanged();
    final requestEpoch = _ttsBuildEpoch;
    if (_tts != null) return _tts!;

    // Prewarm y speak pueden llegar en el mismo frame. ONNX reserva cientos de
    // MB, por lo que la deduplicación posterior no basta: la construcción debe
    // ser single-flight desde antes de abrir el worker/modelo. Si una ruta o
    // Stop/Exit invalidó el builder en vuelo, el consumidor nuevo espera a que
    // el resultado tardío se destruya y solo entonces reintenta con su epoch.
    final inFlight = _ttsBuildInFlight;
    if (inFlight != null) {
      final inFlightEpoch = _ttsBuildInFlightEpoch;
      try {
        final engine = await inFlight;
        if (requestEpoch != _ttsBuildEpoch || _disposed) {
          throw const _TtsBuildCancelled();
        }
        return engine;
      } catch (error, stackTrace) {
        if (inFlightEpoch != requestEpoch &&
            requestEpoch == _ttsBuildEpoch &&
            !_disposed) {
          return _ttsEngine();
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    }

    late final Future<TtsEngine> build;
    build = _buildAndPublishTtsEngine(requestEpoch, lang).whenComplete(() {
      if (identical(_ttsBuildInFlight, build)) {
        _ttsBuildInFlight = null;
        _ttsBuildInFlightEpoch = null;
      }
    });
    _ttsBuildInFlight = build;
    _ttsBuildInFlightEpoch = requestEpoch;
    return build;
  }

  Future<TtsEngine> _buildAndPublishTtsEngine(
    int buildEpoch,
    String lang,
  ) async {
    final settings = _engineSettings;
    late final TtsEngine built;
    final injectedBuilder = debugTtsBuilder;
    if (injectedBuilder != null) {
      built = await injectedBuilder();
    } else if (debugTtsFactory case final injected?) {
      built = injected();
    } else if (nativeVoiceActive) {
      // Modo nativo Desktop (spec 048/US5): la respuesta se sintetiza en el
      // servidor. Un fallo se propaga como ruta no disponible; nunca habilita
      // un motor del teléfono.
      built = HermesServerTtsEngine(
        synthesize: _guardedNativeSpeak,
        playbackFactory: debugNativePlaybackFactory,
      );
    } else {
      switch (effectiveConversationTtsEngine) {
        case TtsEngineKind.elevenlabs:
          final key = await elevenKey() ?? '';
          built = ElevenLabsTtsEngine(
            apiKey: key,
            voiceId: settings.elevenVoiceId,
            modelId: settings.elevenModelId,
          );
        case TtsEngineKind.streaming:
          final token =
              await streamingTtsToken(profile: settings.streamingTtsProfile) ??
              '';
          built = OpenAiStreamingTtsEngine(
            baseUrl: settings.streamingTtsUrl,
            voice: settings.streamingTtsVoice,
            model: settings.streamingTtsModel,
            apiKey: token,
          );
        case TtsEngineKind.customHttp:
          final secret = await customTtsSecret() ?? '';
          built = CustomHttpTtsEngine(
            url: settings.customTtsUrl,
            voice: settings.customTtsVoice,
            model: settings.customTtsModel,
            bodyTemplate: settings.customTtsBodyTemplate,
            authHeaderName: settings.customTtsAuthMode == CustomTtsAuthMode.none
                ? ''
                : settings.customTtsHeaderName,
            authHeaderPrefix: settings.customTtsHeaderPrefix,
            authSecret: secret,
            autoDetectResponse:
                settings.customTtsResponseKind !=
                CustomTtsResponseKind.jsonBase64,
            responseIsJsonBase64:
                settings.customTtsResponseKind ==
                CustomTtsResponseKind.jsonBase64,
            base64Path: settings.customTtsBase64Path,
            mimeType: settings.customTtsMimeType,
          );
        case TtsEngineKind.onnx:
          built = await _buildOnnxEngine();
        case TtsEngineKind.device:
          // Mudo si el móvil no tiene motor TTS (GrapheneOS): evita el crash.
          built = await systemTtsOrSilent(lang: lang);
      }
    }
    if (buildEpoch != _ttsBuildEpoch || _disposed) {
      await built.dispose();
      throw const _TtsBuildCancelled();
    }
    final concurrent = _tts;
    if (concurrent != null) {
      if (!identical(concurrent, built)) await built.dispose();
      return concurrent;
    }
    _tts = built;
    return built;
  }

  /// Motor local para avisos funcionales que requieren atención, como una
  /// aprobación pendiente. No genera acuses, latidos ni frases de espera.
  ///
  /// Si el motor de respuesta YA es on-device (sistema o neural), el aviso usa
  /// ESE MISMO motor. Es clave: el aviso y la respuesta comparten una cola
  /// SERIAL, así que si el aviso usara un motor distinto que esté MUERTO
  /// (p.ej. el TTS del sistema sin voz instalada en el dispositivo), bloquearía
  /// la cola hasta el timeout y la respuesta —aunque su motor funcione— nunca
  /// llegaría a sonar. Reutilizar el motor de respuesta (que sabemos que suena)
  /// evita ese bloqueo. Solo con ElevenLabs (nube) el aviso cae al sistema,
  /// para no gastar créditos en notificaciones funcionales.
  Future<TtsEngine> _localTtsEngine() async {
    switch (effectiveConversationTtsEngine) {
      case TtsEngineKind.device:
      case TtsEngineKind.onnx:
        return _ttsEngine();
      case TtsEngineKind.streaming:
        // Kokoro local (LAN/Tailscale): gratis y, sobre todo, AUDIBLE. El TTS del
        // sistema puede estar MUDO en móviles sin servicios de Google (p.ej.
        // GrapheneOS): el aviso funcional usa el MISMO motor que la respuesta
        // para garantizar que se oiga. Cuesta ~la latencia de una petición.
        return _ttsEngine();
      case TtsEngineKind.elevenlabs:
      case TtsEngineKind.customHttp:
        // Nube de PAGO: el aviso no debe gastar créditos → TTS del sistema
        // (mudo si el móvil no tiene motor TTS, para no crashear).
        final buildEpoch = _ttsBuildEpoch;
        final lang = _recycleTtsIfLangChanged();
        final existing = _localTts;
        if (existing != null) return existing;
        final built = await systemTtsOrSilent(lang: lang);
        if (buildEpoch != _ttsBuildEpoch || _disposed) {
          await built.dispose();
          throw const _TtsBuildCancelled();
        }
        return _localTts ??= built;
    }
  }

  /// Construye el motor neuronal on-device con la voz elegida. Si el modelo no
  /// está descargado, cae a la voz del sistema (nunca falla en silencio).
  Future<TtsEngine> _buildOnnxEngine() async {
    final voice = neuralVoiceById(_engineSettings.onnxVoiceId);
    if (voice == null || !await ttsModels.isReady(voice)) {
      // Sin modelo neural → TTS del sistema, o mudo si no hay motor (GrapheneOS).
      return await systemTtsOrSilent(lang: voiceLang);
    }
    return OnDeviceNeuralTtsEngine(
      modelPath: await ttsModels.modelPath(voice),
      tokensPath: await ttsModels.tokensPath(voice),
      dataDirPath: await ttsModels.dataDirPath(voice),
    );
  }

  // ── Modelos de voz neuronal on-device ───────────────────────────────
  /// ¿La voz neuronal elegida está lista para usarse?
  Future<bool> onnxVoiceReady() async {
    final voice = neuralVoiceById(_settings.onnxVoiceId);
    if (voice == null) return false;
    return ttsModels.isReady(voice);
  }

  /// Construye un motor neuronal efímero para una voz concreta (para "probar"
  /// sin tocar el motor activo). Devuelve null si la voz no está lista.
  Future<TtsEngine?> buildOnnxPreview(NeuralVoice voice) async {
    if (!await ttsModels.isReady(voice)) return null;
    return OnDeviceNeuralTtsEngine(
      modelPath: await ttsModels.modelPath(voice),
      tokensPath: await ttsModels.tokensPath(voice),
      dataDirPath: await ttsModels.dataDirPath(voice),
    );
  }

  /// Barrera explícita antes de seleccionar, probar o borrar un modelo TTS.
  /// Impide que dos voces ONNX residan a la vez y que Windows/Android intente
  /// borrar ficheros que el worker anterior todavía mantiene abiertos.
  Future<void> releaseTtsForModelMutation() => disposeTtsForVoiceExit();

  /// Handoff escuchar→hablar del modo voz local. Conserva el STT entre turnos
  /// cuando el TTS es ligero/remoto, pero libera modelo y cachés si el siguiente
  /// paso va a cargar Piper/ONNX. En cuanto el paso termina, encadena la
  /// precarga del motor de respuesta (spec 048/US2): la espera de red del
  /// agente absorbe el arranque del worker y la primera frase no lo paga.
  Future<void> prepareForNarration() {
    // App Lock/Exit pueden invalidar TTS mientras el handoff STT todavía está
    // pendiente. Capturar la epoch antes de ese await impide que su completion
    // tardío abra un worker nuevo después de que el teardown ya terminara.
    final prewarmEpoch = _ttsBuildEpoch;
    final handoff = serializesHeavyLocalVoiceModels
        ? _disposeSttAndCaches(reason: 'tts_handoff')
        : stopDictation();
    return handoff.whenComplete(() {
      if (_disposed || prewarmEpoch != _ttsBuildEpoch) return;
      unawaited(prewarmResponseTts());
    });
  }

  /// Precarga best-effort del motor de RESPUESTA. Con [normalizedText] deja
  /// además esa locución (su primera frase) sintetizada en el caché del motor.
  /// Nunca lanza: un fallo aquí se paga como hoy, en `speak`.
  Future<void> prewarmResponseTts([String? normalizedText]) async {
    _cancelHeavyModelIdleRelease();
    try {
      final engine = await _ttsEngine();
      if (engine is PrewarmableTts) {
        await (engine as PrewarmableTts).prewarm(normalizedText);
      }
    } catch (e) {
      debugPrint('[hermes-voice] prewarm silenciado: $e');
    } finally {
      _scheduleHeavyModelIdleRelease();
    }
  }

  /// Pre-síntesis de la siguiente locución (spec 048/US3). Normaliza EXACTO
  /// como [_enqueue] para que la clave de caché coincida con lo que `speak()`
  /// pedirá después. No toca la cola ni el estado de reproducción.
  Future<void> prewarmSpeech(String text) async {
    var t = _responseSpeechText(text);
    if (t.isEmpty) return;
    if (t.length > _maxChunkChars) t = t.substring(0, _maxChunkChars);
    await prewarmResponseTts(t);
  }

  /// Handoff hablar→escuchar. El worker ONNX debe morir antes de volver a cargar
  /// Sherpa/Whisper; así el modo voz nunca mantiene los dos modelos pesados.
  Future<void> releaseTtsForListening() => serializesHeavyLocalVoiceModels
      ? disposeTtsForVoiceExit()
      : Future<void>.value();

  /// Compatibilidad con la API histórica. Las superficies nuevas deben usar
  /// [toggleReadAloud] o [startAutoRead] para aportar identidad estable.
  Future<void> speak(String text) async {
    final task = _startReadAloud(
      messageKey: 'legacy:${++_legacyReadSequence}',
      revision: text.hashCode.toString(),
      markdown: text,
      origin: ReadAloudOrigin.automatic,
    );
    await task;
  }

  /// Alterna la lectura de una burbuja concreta. En el modo por defecto, el
  /// primer toque pausa y el siguiente reanuda en el chunk interrumpido. En el
  /// modo alternativo, el primer toque descarta y el siguiente empieza en cero.
  Future<void> toggleReadAloud({
    required String messageKey,
    required String revision,
    required String markdown,
  }) async {
    final current = _readAloudSession.snapshot;
    final effectiveRevision = _readRevision(revision);
    if (current.owns(messageKey) && current.revision == effectiveRevision) {
      if (current.isActive) {
        _pauseReadAloud(
          discard:
              _settings.readAloudStopBehavior ==
              ReadAloudStopBehavior.stopAndRestart,
        );
        return;
      }
      if (current.isResumable &&
          _settings.readAloudStopBehavior ==
              ReadAloudStopBehavior.pauseAndResume) {
        _resumeReadAloud();
        return;
      }
    }
    _startReadAloud(
      messageKey: messageKey,
      revision: revision,
      markdown: markdown,
      origin: ReadAloudOrigin.manual,
    );
  }

  /// Auto-leer comparte exactamente el mismo propietario y gates que el botón.
  /// Un evento `done` repetido para la misma revisión no duplica la locución.
  Future<void> startAutoRead({
    required String messageKey,
    required String revision,
    required String markdown,
  }) async {
    final effectiveRevision = _readRevision(revision);
    final autoKey = '$messageKey\u0000$effectiveRevision';
    if (_lastAutoReadKey == autoKey) return;
    final current = _readAloudSession.snapshot;
    if (current.owns(messageKey) &&
        current.revision == effectiveRevision &&
        (current.isActive || current.isResumable)) {
      return;
    }
    _lastAutoReadKey = autoKey;
    _startReadAloud(
      messageKey: messageKey,
      revision: revision,
      markdown: markdown,
      origin: ReadAloudOrigin.automatic,
    );
  }

  String _readRevision(String revision) =>
      '$revision|${effectiveConversationTtsEngine.id}|$voiceLang';

  Future<void> _startReadAloud({
    required String messageKey,
    required String revision,
    required String markdown,
    required ReadAloudOrigin origin,
  }) {
    final segments = SpeechRenderer(language: voiceLang).render(markdown);
    final chunks = chunkNarrationSegments(segments);
    if (chunks.isEmpty) return Future.value();

    _cancelHeavyModelIdleRelease();
    final previous = _readAloudSession.snapshot;
    _invalidateReadOperation(
      discard: true,
      stopNative: previous.isActive || previous.isResumable,
    );
    final cancellation = Completer<void>();
    _readCancelled = cancellation;
    final epoch = _readAloudSession.begin(
      messageKey: messageKey,
      revision: _readRevision(revision),
      chunks: chunks,
      origin: origin,
    );
    _syncSpeaking();
    debugPrint(
      '[hermes-read] start epoch=$epoch chunks=${chunks.length} '
      'engine=${effectiveConversationTtsEngine.id} origin=${origin.name}',
    );

    late final Future<void> task;
    task = _driveReadAloud(epoch, cancellation).whenComplete(() {
      if (identical(_readTask, task)) _readTask = null;
      _syncSpeaking();
      _scheduleHeavyModelIdleRelease();
    });
    _readTask = task;
    task.ignore();
    return task;
  }

  void _resumeReadAloud() {
    _cancelHeavyModelIdleRelease();
    final cancellation = Completer<void>();
    _completeReadCancellation();
    _readCancelled = cancellation;
    final epoch = _readAloudSession.resume();
    _syncSpeaking();
    debugPrint(
      '[hermes-read] resume epoch=$epoch '
      'chunk=${_readAloudSession.snapshot.cursor + 1}/'
      '${_readAloudSession.snapshot.chunks.length}',
    );
    late final Future<void> task;
    task = _driveReadAloud(epoch, cancellation).whenComplete(() {
      if (identical(_readTask, task)) _readTask = null;
      _syncSpeaking();
      _scheduleHeavyModelIdleRelease();
    });
    _readTask = task;
    task.ignore();
  }

  void _pauseReadAloud({required bool discard}) {
    // Orden deliberado: epoch/estado visible → speaking=false → despertar las
    // esperas → cleanup nativo. El gesto nunca espera al plugin ni a ONNX.
    _readAloudSession.pause(discard: discard);
    _syncSpeaking();
    _completeReadCancellation();
    final engine = _tts;
    if (engine != null) _stopReadEngineInBackground(engine);
    debugPrint('[hermes-read] ${discard ? 'discard' : 'pause'}');
  }

  void _invalidateReadOperation({
    required bool discard,
    required bool stopNative,
  }) {
    _readAloudSession.pause(discard: discard);
    _syncSpeaking();
    _completeReadCancellation();
    if (stopNative && _tts != null) {
      _stopReadEngineInBackground(_tts!);
    }
  }

  void _completeReadCancellation() {
    if (!_readCancelled.isCompleted) _readCancelled.complete();
  }

  Future<void> _stopReadEngine(TtsEngine engine) async {
    try {
      await engine.stop().timeout(const Duration(milliseconds: 900));
    } catch (error) {
      debugPrint('[hermes-read] cleanup diferido del TTS: $error');
    }
  }

  void _stopReadEngineInBackground(TtsEngine engine) {
    _readStopInProgress = true;
    final previous = _readStopBarrier;
    final stop = _stopReadEngine(engine);
    late final Future<void> joined;
    joined = Future.wait<void>([previous, stop]).then<void>((_) {});
    _readStopBarrier = joined;
    unawaited(
      joined.whenComplete(() {
        if (identical(_readStopBarrier, joined)) {
          _readStopBarrier = Future<void>.value();
          _readStopInProgress = false;
          _scheduleHeavyModelIdleRelease();
        }
      }),
    );
  }

  Future<_ReadAwaitResult<T>> _awaitReadOrCancel<T>(
    Future<T> future,
    Completer<void> cancellation,
  ) async {
    final settled = future.then<_ReadAwaitResult<T>>(
      _ReadAwaitResult<T>.value,
      onError: (Object error, StackTrace stackTrace) =>
          _ReadAwaitResult<T>.error(error, stackTrace),
    );
    final result = await Future.any<_ReadAwaitResult<T>>([
      settled,
      cancellation.future.then((_) => _ReadAwaitResult<T>.cancelled()),
    ]);
    if (result.cancelled) future.ignore();
    return result;
  }

  Future<void> _driveReadAloud(int epoch, Completer<void> cancellation) async {
    try {
      final stopResult = await _awaitReadOrCancel(
        _readStopBarrier,
        cancellation,
      );
      if (stopResult.cancelled || !_readAloudSession.isCurrent(epoch)) return;
      if (stopResult.error != null) {
        Error.throwWithStackTrace(
          stopResult.error!,
          stopResult.stackTrace ?? StackTrace.current,
        );
      }
      final preparePlayback = prepareReadAloudPlayback;
      if (preparePlayback != null) {
        final preparedResult = await _awaitReadOrCancel(
          preparePlayback(),
          cancellation,
        );
        if (preparedResult.cancelled || !_readAloudSession.isCurrent(epoch)) {
          return;
        }
        if (preparedResult.error != null) {
          Error.throwWithStackTrace(
            preparedResult.error!,
            preparedResult.stackTrace ?? StackTrace.current,
          );
        }
        if (preparedResult.value != true) {
          throw StateError('Read aloud playback lease unavailable');
        }
      }
      final engineResult = await _awaitReadOrCancel(_ttsEngine(), cancellation);
      if (engineResult.cancelled || !_readAloudSession.isCurrent(epoch)) return;
      if (engineResult.error != null) {
        Error.throwWithStackTrace(
          engineResult.error!,
          engineResult.stackTrace ?? StackTrace.current,
        );
      }
      final engine = engineResult.value!;

      while (_readAloudSession.isCurrent(epoch)) {
        final chunk = _readAloudSession.currentChunk;
        if (chunk == null) return;
        final index = _readAloudSession.snapshot.cursor;
        _readAloudSession.markPlaying(epoch);
        _syncSpeaking();
        debugPrint(
          '[hermes-read] play epoch=$epoch chunk=${index + 1}/'
          '${_readAloudSession.snapshot.chunks.length}',
        );

        final timeout = Duration(
          milliseconds: (chunk.text.length * 120).clamp(20000, 120000).toInt(),
        );
        final speechResult = await _awaitReadOrCancel(
          engine.speak(chunk.text).timeout(timeout),
          cancellation,
        );
        if (speechResult.cancelled || !_readAloudSession.isCurrent(epoch)) {
          return;
        }
        if (speechResult.error != null) {
          Error.throwWithStackTrace(
            speechResult.error!,
            speechResult.stackTrace ?? StackTrace.current,
          );
        }

        final finished = _readAloudSession.completeChunk(epoch);
        _syncSpeaking();
        if (finished) {
          debugPrint('[hermes-read] complete epoch=$epoch');
          return;
        }

        final delay = chunk.pauseAfter.duration;
        if (delay > Duration.zero) {
          _readAloudSession.markWaitingBoundary(epoch);
          _syncSpeaking();
          final boundary = await _awaitReadOrCancel(
            Future<void>.delayed(delay),
            cancellation,
          );
          if (boundary.cancelled || !_readAloudSession.isCurrent(epoch)) return;
        }
      }
    } catch (error) {
      if (!_readAloudSession.isCurrent(epoch)) return;
      _readAloudSession.fail(epoch, error);
      _syncSpeaking();
      debugPrint(
        '[hermes-read] failed epoch=$epoch '
        'engine=${effectiveConversationTtsEngine.id} '
        'error=${error.runtimeType}',
      );
      final engine = _tts;
      if (engine != null) _stopReadEngineInBackground(engine);
      // Conserva el chunk para que el siguiente toque pueda reintentarlo.
    }
  }

  void _syncSpeaking() {
    if (_disposed) return;
    final value =
        _activeTtsPreviews > 0 ||
        _draining ||
        _readAloudSession.snapshot.isActive;
    if (speaking.value != value) speaking.value = value;
  }

  Future<void> pauseReadAloudFromSystemControl() async {
    if (!_readAloudSession.snapshot.isActive) return;
    _pauseReadAloud(discard: false);
  }

  Future<void> resumeReadAloudFromSystemControl() async {
    if (_readAloudSession.snapshot.phase != ReadAloudPhase.paused) return;
    _resumeReadAloud();
  }

  /// Descarta cualquier lectura manual/automática sin esperar al plugin.
  Future<void> stopAndDiscardReadAloud() async {
    _invalidateReadOperation(discard: true, stopNative: true);
  }

  /// Al cerrar un chat solo descarta su lectura manual. El modo voz global y
  /// una lectura automática ajena no se ven afectados.
  Future<void> stopManualReadAloud({String? messageKeyPrefix}) async {
    final current = _readAloudSession.snapshot;
    if (current.origin != ReadAloudOrigin.manual) return;
    if (messageKeyPrefix != null &&
        !(current.messageKey?.startsWith(messageKeyPrefix) ?? false)) {
      return;
    }
    _invalidateReadOperation(discard: true, stopNative: true);
  }

  // ── Cola de habla en streaming (modo voz fluido) ─────────────────────
  // Permite hablar frase a frase MIENTRAS el agente sigue generando, en vez de
  // esperar a la respuesta completa. Cada frase se reproduce en orden; si una
  // falla, se salta sin romper el turno.
  final List<_Utterance> _speechQueue = [];
  bool _draining = false;
  bool _speechStopped = false;
  int _speechGeneration = 0;
  int _conversationSpeechLeaseSequence = 0;
  VoiceConversationSpeechLease? _activeConversationSpeechLease;
  final List<Completer<void>> _drainWaiters = [];
  Object? _speechFailure;
  StackTrace? _speechFailureStackTrace;

  /// Tope de caracteres por frase encolada: una respuesta larguísima sin signos
  /// de puntuación podría llegar como un único chunk gigante y bloquear el motor.
  /// Límite compartido por los productores de la cola y el drenado TTS. Los
  /// fragmentos semánticos pueden agruparse para evitar silencios entre cortes,
  /// pero ninguna locución debe superar este tamaño ni quedar truncada aquí.
  static const int maxSpeechUtteranceChars = 2000;
  static const int _maxChunkChars = maxSpeechUtteranceChars;

  /// Tope de CARACTERES pendientes en cola (suma de las frases aún sin
  /// reproducir). El presupuesto de voz por turno (~600 chars) ya acota una
  /// respuesta normal muy por debajo de esto; este tope solo frena una
  /// acumulación PATOLÓGICA (p.ej. auto-leer una respuesta gigantesca) sin
  /// descartar nunca el final de una respuesta de tamaño normal.
  ///
  /// Antes esto era un tope de 3 FRASES: con el streaming el modelo genera
  /// mucho más rápido de lo que se habla, así que las frases se acumulaban,
  /// llegaban a 3 y el resto se DESCARTABA → "se cortaba lo que decía" a media
  /// respuesta. Acotar por caracteres (y no por número de frases) mantiene la
  /// protección contra desbordes sin mutilar respuestas legítimas.
  static const int _maxPendingChars = 6000;

  /// Tope de pendientes para un turno de LECTURA COMPLETA (cuento/poema/"léeme":
  /// ver [VoiceResponsePolicy.wantsFullReading]). Ese contenido es legítimo y el
  /// usuario quiere oírlo entero, así que no debe descartarse a los 6000 chars; el
  /// texto pesa poquísimo en memoria (la cola se drena según habla el TTS). Lo
  /// activa quien orquesta el turno poniendo [fullReadingTurn] = true.
  static const int _maxPendingCharsFullReading = 200000;

  /// El turno actual es de lectura completa. Solo afecta al tope de la cola; el
  /// contenido técnico se sigue filtrando.
  bool fullReadingTurn = false;

  // El tope de seguridad por locución de RESPUESTA es dinámico: ver
  // [_responseTimeout] (escala con la longitud porque ahora coalescamos frases).
  // El TTS del sistema (flutter_tts) depende del callback `onDone` de Android,
  // que a veces no llega → sin tope, `speak()` colgaría el modo voz; con el tope,
  // reciclamos el motor y seguimos.

  /// Timeout corto para un aviso funcional. Si no termina en 8 s, el motor del
  /// sistema probablemente está bloqueado o no tiene una voz instalada. Como
  /// comparte la cola serial con la respuesta, se omite para no bloquearla.
  static const Duration _localSpeechTimeout = Duration(seconds: 8);

  /// Encola una frase de la **respuesta** del agente (motor configurado, premium
  /// si lo hay). Arranca el drenado si no está en marcha.
  Future<bool> enqueueSpeech(String text) => _enqueue(text, local: false);

  /// Abre una identidad nueva para la cola TTS de una conversación de Voz.
  /// Una entrada posterior nunca reutiliza la lease de la anterior.
  VoiceConversationSpeechLease beginConversationSpeechLease() {
    final lease = VoiceConversationSpeechLease._(
      ++_conversationSpeechLeaseSequence,
    );
    _activeConversationSpeechLease = lease;
    return lease;
  }

  /// Cierra la lease antes de iniciar el teardown físico. También retira de la
  /// cola cualquier lote suyo que aún no hubiese sido tomado por el drenador;
  /// los lotes ya tomados quedan cercados por [_speechItemIsCurrent].
  bool endConversationSpeechLease(VoiceConversationSpeechLease lease) {
    if (!identical(_activeConversationSpeechLease, lease)) return false;
    _activeConversationSpeechLease = null;
    _speechQueue.removeWhere(
      (item) => identical(item.conversationLease, lease),
    );
    return true;
  }

  /// Permite a adaptadores de test conservar el mismo fence sin usar la cola
  /// real ni plugins de plataforma.
  @visibleForTesting
  bool ownsConversationSpeechLease(VoiceConversationSpeechLease lease) =>
      identical(_activeConversationSpeechLease, lease);

  /// Encola exclusivamente si [lease] sigue perteneciendo a la conversación
  /// visible. La comprobación y la inserción son síncronas entre sí.
  Future<bool> enqueueConversationSpeech(
    VoiceConversationSpeechLease lease,
    String text,
  ) {
    if (!ownsConversationSpeechLease(lease)) return Future<bool>.value(false);
    return _enqueue(text, local: false, conversationLease: lease);
  }

  /// Precalienta únicamente para una lease viva. El prewarm que ya estaba en
  /// FFI puede terminar, pero nunca reproduce y el teardown invalida su builder.
  Future<void> prewarmConversationSpeech(
    VoiceConversationSpeechLease lease,
    String text,
  ) async {
    if (!ownsConversationSpeechLease(lease)) return;
    await prewarmSpeech(text);
  }

  /// Encola un aviso funcional con el TTS del sistema: inmediato y sin coste.
  /// Va por la MISMA cola que la respuesta, así nunca se solapan. Ver
  /// [_localTtsEngine].
  Future<void> enqueueLocalSpeech(String text) async {
    await _enqueue(text, local: true);
  }

  String _responseSpeechText(String text) => SpeechRenderer(
    language: voiceLang,
  ).render(text).map((segment) => segment.text).join(' ').trim();

  Future<bool> _enqueue(
    String text, {
    required bool local,
    VoiceConversationSpeechLease? conversationLease,
  }) async {
    if (conversationLease != null &&
        !ownsConversationSpeechLease(conversationLease)) {
      return false;
    }
    // Quita el Markdown ANTES de hablar: si no, el TTS lee los símbolos
    // ("almohadilla", "asterisco", "guion") y suena a basura. Solo afecta a lo
    // que se habla; el texto en pantalla conserva su formato. Los avisos
    // funcionales ya son prosa limpia, así que para ellos es un no-op inocuo.
    var t = local ? SpokenText.fromMarkdown(text) : _responseSpeechText(text);
    if (t.isEmpty) return false;
    _cancelHeavyModelIdleRelease();
    // Acota el tamaño del chunk (evita bloqueos del motor con textos enormes).
    if (t.length > _maxChunkChars) t = t.substring(0, _maxChunkChars);
    _speechStopped = false;
    // Overflow: solo descartamos si la cola ya acumula una cantidad PATOLÓGICA de
    // texto sin reproducir (suma de chars), y nunca la primera frase (cola vacía)
    // para no cortar el INICIO. Una respuesta de voz normal (presupuesto ~600
    // chars) jamás llega a este tope, así que no se pierde su final.
    final pending = _speechQueue.fold<int>(0, (sum, u) => sum + u.text.length);
    final cap = fullReadingTurn
        ? _maxPendingCharsFullReading
        : _maxPendingChars;
    if (_speechQueue.isNotEmpty && pending + t.length > cap) return false;
    _speechQueue.add(
      _Utterance(
        t,
        local,
        generation: _speechGeneration,
        strictServerRoute: !local && nativeVoiceActive,
        responseEngine: effectiveConversationTtsEngine,
        conversationLease: conversationLease,
      ),
    );
    if (!_draining) {
      _speechFailure = null;
      _speechFailureStackTrace = null;
      _draining = true;
      unawaited(_drainSpeech());
    }
    return true;
  }

  Future<void> _drainSpeech() async {
    speaking.value = true;
    Object? failure;
    StackTrace? failureStackTrace;
    try {
      while (_speechQueue.isNotEmpty && !_speechStopped) {
        try {
          await _speakUtterance(_nextCoalescedUtterance());
        } on _TtsBuildCancelled {
          // Stop/salida/ruta nueva ganó durante la inicialización. Descarta
          // únicamente la cola de la ruta antigua; una locución nueva puede
          // haber entrado mientras el builder terminaba y debe seguir viva.
          _speechQueue.removeWhere((item) => !_speechItemIsCurrent(item));
        }
      }
    } catch (error, stackTrace) {
      failure = error;
      failureStackTrace = stackTrace;
      _speechFailure = error;
      _speechFailureStackTrace = stackTrace;
      _speechQueue.clear();
      debugPrint(
        '[hermes-voice] cola detenida por fallo de ruta '
        'error=${error.runtimeType}',
      );
    } finally {
      _draining = false;
      _syncSpeaking();
      _releaseDrainWaiters(error: failure, stackTrace: failureStackTrace);
      _scheduleHeavyModelIdleRelease();
    }
  }

  /// Junta las frases consecutivas de la cola con el MISMO origen (respuesta vs
  /// aviso) en una sola locución (007-voice-jarvis-fluid). Así el motor de
  /// streaming puede encadenarlas con su PREFETCH interno (gapless) en lugar de
  /// pedir→esperar→reproducir frase a frase, que es lo que dejaba huecos
  /// perceptibles entre frases ("como tonta"). No mezcla respuesta con avisos
  /// (cada uno usa su motor y mantiene el orden) y respeta el tope de chunk para
  /// no pasar un texto patológicamente largo al motor.
  _Utterance _nextCoalescedUtterance() {
    final first = _speechQueue.removeAt(0);
    final buf = StringBuffer(first.text);
    while (_speechQueue.isNotEmpty &&
        _speechQueue.first.local == first.local &&
        _speechQueue.first.generation == first.generation &&
        identical(
          _speechQueue.first.conversationLease,
          first.conversationLease,
        ) &&
        _speechQueue.first.strictServerRoute == first.strictServerRoute &&
        _speechQueue.first.responseEngine == first.responseEngine &&
        buf.length + 1 + _speechQueue.first.text.length <= _maxChunkChars) {
      buf.write(' ');
      buf.write(_speechQueue.removeAt(0).text);
    }
    return _Utterance(
      buf.toString(),
      first.local,
      generation: first.generation,
      strictServerRoute: first.strictServerRoute,
      responseEngine: first.responseEngine,
      conversationLease: first.conversationLease,
    );
  }

  bool _speechItemIsCurrent(_Utterance item) =>
      !_speechStopped &&
      item.generation == _speechGeneration &&
      (item.conversationLease == null ||
          identical(item.conversationLease, _activeConversationSpeechLease)) &&
      (item.local ||
          (item.strictServerRoute == nativeVoiceActive &&
              (item.strictServerRoute ||
                  item.responseEngine == effectiveConversationTtsEngine)));

  /// Tope de seguridad por locución para la RESPUESTA (no avisos). No es el
  /// tiempo esperado: es el umbral para detectar un motor colgado. Como ahora
  /// coalescamos varias frases, escala con la longitud (~120 ms/char) con un
  /// mínimo de 45 s y un máximo prudente, en vez de un fijo de 45 s que se
  /// quedaría corto con texto largo y reciclaría el motor a media respuesta.
  static Duration _responseTimeout(String t) =>
      Duration(milliseconds: (t.length * 120).clamp(45000, 600000));

  /// Reproduce una frase de la cola. Fuera de la ruta Hermes estricta, una
  /// respuesta cuyo motor configurado falla puede usar el TTS on-device como
  /// último recurso. `Servidor Hermes` nunca entra en ese fallback: expone un
  /// fallo de ruta recuperable. El **aviso** (local) ya usa el sistema y, si
  /// falla, no insistimos. El contenido técnico nunca llega aquí.
  Future<void> _speakUtterance(_Utterance item) async {
    if (!_speechItemIsCurrent(item)) return;
    // La elección `Servidor Hermes` empareja STT y TTS. Capturamos la ruta antes
    // de construir el motor para que ni un error tardío ni el fallback de
    // transporte WS→POST puedan convertir esta locución en ONNX/sistema.
    final strictServerRoute = item.strictServerRoute;
    final spoken = await speakOrFallback(
      text: item.text,
      isLocal: item.local,
      allowFallback: !strictServerRoute,
      primary: (t) async {
        try {
          final engine = item.local
              ? await _localTtsEngine()
              : await _ttsEngine();
          if (!_speechItemIsCurrent(item)) return;
          final route = item.local
              ? 'aviso'
              : strictServerRoute
              ? 'servidor-hermes'
              : effectiveConversationTtsEngine.id;
          debugPrint(
            '[hermes-voice] hablando ($route) '
            'chars=${t.runes.length}'
            // Los avisos funcionales son frases NUESTRAS, fijas y sin
            // contenido del usuario ni del agente: registrarlas es seguro y
            // ahorra tener que adivinar qué dijo por su longitud. La respuesta
            // del agente NUNCA se registra.
            '${item.local ? ' texto="$t"' : ''}',
          );
          await engine
              .speak(t)
              .timeout(item.local ? _localSpeechTimeout : _responseTimeout(t));
          debugPrint('[hermes-voice] frase OK');
        } on TimeoutException {
          // El motor se colgó (p.ej. el servicio TextToSpeech de Android se
          // desconectó y su `onDone` nunca llegó). Lo reciclamos; solo las rutas
          // no estrictas pueden intentar después el fallback on-device.
          debugPrint('[hermes-voice] TTS colgado (timeout): reciclando motor');
          await _resetTtsEngine(local: item.local);
          rethrow;
        }
      },
      fallback: (t) async {
        try {
          if (!_speechItemIsCurrent(item)) return;
          debugPrint(
            '[hermes-voice] motor principal falló → fallback a ONNX/sistema',
          );
          final sys =
              await _buildOnnxEngine(); // ONNX si hay modelo instalado, sistema si no
          if (!_speechItemIsCurrent(item)) {
            await sys.dispose();
            return;
          }
          await sys.speak(t).timeout(_responseTimeout(t));
          debugPrint('[hermes-voice] fallback OK');
        } on TimeoutException {
          await _resetTtsEngine(local: true);
          rethrow;
        }
      },
    );
    if (!spoken && strictServerRoute) {
      throw const VoiceRouteUnavailableException();
    }
  }

  /// Habla [text] con [primary]; si lanza y NO es un aviso local, reintenta una
  /// vez con [fallback] (TTS del sistema). Devuelve true si algún motor habló.
  /// Pura y testeable: la política de fallback de ResponseTts vive aquí, separada
  /// de la construcción de motores.
  @visibleForTesting
  static Future<bool> speakOrFallback({
    required Future<void> Function(String) primary,
    required Future<void> Function(String) fallback,
    required String text,
    required bool isLocal,
    bool allowFallback = true,
  }) async {
    try {
      await primary(text);
      return true;
    } catch (e) {
      if (e is _TtsBuildCancelled) rethrow;
      debugPrint(
        '[hermes-voice] excepción silenciada (se continúa sin propagar): $e',
      );
      // El aviso funcional ya es local: si falla, no insistimos. Una respuesta
      // en ruta Hermes estricta tampoco puede saltar a un motor del teléfono.
      if (isLocal || !allowFallback) return false;
      try {
        await fallback(text);
        return true;
      } catch (e) {
        debugPrint(
          '[hermes-voice] excepción silenciada (fallback también falló, ni premium ni sistema): $e',
        );
        return false; // ni premium ni sistema: best-effort, frase perdida.
      }
    }
  }

  /// Desecha el motor TTS activo para que el próximo `speak` lo reconstruya. Se
  /// usa para recuperarse de un motor del sistema que dejó de responder. Con
  /// [local] recicla el motor del sistema usado para avisos funcionales.
  Future<void> _resetTtsEngine({bool local = false}) async {
    _ttsBuildEpoch++;
    final dead = local ? _localTts : _tts;
    if (local) {
      _localTts = null;
    } else {
      _tts = null;
    }
    try {
      await dead?.dispose();
    } catch (_) {
      // El motor estaba muerto: ignorar errores al liberarlo.
    }
  }

  /// Espera a que la cola de habla termine de reproducirse.
  Future<void> waitSpeechDone() {
    if (!_draining && _speechQueue.isEmpty) {
      final failure = _speechFailure;
      final stackTrace = _speechFailureStackTrace;
      _speechFailure = null;
      _speechFailureStackTrace = null;
      if (failure != null) return Future<void>.error(failure, stackTrace);
      return Future.value();
    }
    final c = Completer<void>();
    _drainWaiters.add(c);
    return c.future;
  }

  void _releaseDrainWaiters({Object? error, StackTrace? stackTrace}) {
    final deliveredFailure = error != null && _drainWaiters.isNotEmpty;
    for (final w in _drainWaiters) {
      if (w.isCompleted) continue;
      if (error == null) {
        w.complete();
      } else {
        w.completeError(error, stackTrace);
      }
    }
    _drainWaiters.clear();
    if (deliveredFailure) {
      _speechFailure = null;
      _speechFailureStackTrace = null;
    }
  }

  Future<void> stopSpeaking() async {
    _speechGeneration++;
    _invalidateReadOperation(discard: true, stopNative: false);
    _speechStopped = true;
    _speechQueue.clear();
    _speechFailure = null;
    _speechFailureStackTrace = null;
    final stopStream = _cancelNativeSpeechStream();
    // Si el motor está colgado, su `stop()` también puede bloquearse; con tope
    // corto no dejamos atascado el corte de voz (saltar/cancelar/permiso) y, si
    // no respondió, lo reciclamos para que el próximo turno hable.
    try {
      await Future.wait([
        stopStream.timeout(const Duration(seconds: 3)),
        if (_tts != null) _tts!.stop().timeout(const Duration(seconds: 3)),
        if (_localTts != null)
          _localTts!.stop().timeout(const Duration(seconds: 3)),
      ]);
    } on TimeoutException {
      debugPrint(
        '[hermes-voice] stop() del TTS no respondió: reciclando motor',
      );
      unawaited(_resetTtsEngine());
      unawaited(_resetTtsEngine(local: true));
    } catch (_) {
      // Ignorar: el corte es best-effort.
    }
    _syncSpeaking();
    _releaseDrainWaiters();
  }

  /// Prueba la voz (usado por la pantalla de ajustes) sin permitir que un motor
  /// sin audio o un callback nativo perdido deje la interfaz esperando para
  /// siempre. El motor es efímero y su dueño sigue siendo quien lo construyó.
  Future<void> previewTts(
    TtsEngine engine,
    String text, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    _cancelHeavyModelIdleRelease();
    _activeTtsPreviews++;
    _syncSpeaking();
    try {
      await engine.speak(text).timeout(timeout);
    } on TimeoutException {
      debugPrint('[hermes-voice] la prueba TTS agotó el tiempo de espera');
      try {
        await engine.stop().timeout(const Duration(seconds: 2));
      } catch (_) {
        // El motor ya está colgado; su dueño intentará liberarlo después.
      }
      rethrow;
    } finally {
      if (_activeTtsPreviews > 0) _activeTtsPreviews--;
      _syncSpeaking();
      _scheduleHeavyModelIdleRelease();
    }
  }

  // ── STT (dictado) ───────────────────────────────────────────────────
  /// Modelo Whisper activo según los ajustes (tiny ~75 MB rápido / base ~142 MB).
  WhisperModel get whisperModel =>
      _engineSettings.whisperModel == SttModelSize.tiny
      ? WhisperModel.tiny
      : WhisperModel.base;

  /// Construye un motor Whisper cableado con los ajustes de VAD y el reporte de
  /// nivel de micrófono hacia [micLevel].
  WhisperSttEngine _newWhisperEngine() => WhisperSttEngine(
    model: whisperModel,
    vadEnabled: _engineSettings.vadEnabled,
    onLevel: (v) => micLevel.value = v,
    lang: voiceLang,
  );

  /// Modelo sherpa activo según los ajustes (STT en vivo).
  SherpaSttModel get sherpaModel =>
      sherpaModelByKind(_engineSettings.sherpaModel);

  /// Construye el motor de STT en vivo (sherpa-onnx) cableado con el reporte de
  /// nivel de micrófono hacia [micLevel].
  SherpaSttEngine _newSherpaEngine() => SherpaSttEngine(
    model: sherpaModel,
    manager: sherpaModels,
    onLevel: (v) => micLevel.value = v,
    lang: voiceLang,
  );

  /// Construye el motor de STT por servidor (faster-whisper). Usa el token
  /// cacheado en memoria (el Keystore es async; checkStt lo refresca antes).
  ServerSttEngine _newServerEngine() => ServerSttEngine(
    baseUrl: _engineSettings.serverSttUrl,
    token: _serverTokenCache,
    onLevel: (v) => micLevel.value = v,
  );

  SttEngine _sttEngine() {
    final lang = _recycleSttIfLangChanged();
    final effectiveEngine = effectiveConversationSttEngine;
    // Modo nativo Desktop (spec 048/US5): la escucha usa el clip-engine con
    // transcripción en el servidor, independientemente del motor configurado.
    // La inyección de tests conserva prioridad.
    if (nativeVoiceActive && debugSttFactory == null) {
      if (_stt != null && _sttNativeVoice) return _stt!;
      final previous = _stt;
      if (previous != null) {
        unawaited(_disposeSttEngine(previous, reason: 'native_voice_switch'));
      }
      _stt = buildHermesServerSttEngine(
        transcribeRequest: _guardedNativeTranscribe,
        lang: lang,
        onLevel: (v) => micLevel.value = v,
      );
      _sttKind = SttEngineKind.server;
      _sttNativeVoice = true;
      return _stt!;
    }
    if (_stt != null && _sttNativeVoice && !nativeVoiceActive) {
      // La ruta nativa se desactivó explícitamente: recicla su engine antes de
      // volver a los ajustes independientes o de abrir otra conversación.
      final previous = _stt;
      _stt = null;
      _sttKind = null;
      _sttNativeVoice = false;
      if (previous != null) {
        unawaited(_disposeSttEngine(previous, reason: 'native_voice_off'));
      }
    }
    if (_stt == null) {
      _stt =
          debugSttFactory?.call() ??
          switch (effectiveEngine) {
            SttEngineKind.whisper => _newWhisperEngine(),
            SttEngineKind.sherpaLive => _newSherpaEngine(),
            SttEngineKind.hermesServer => buildHermesServerSttEngine(
              transcribeRequest: _guardedHermesDictationTranscribe,
              lang: lang,
              onLevel: (v) => micLevel.value = v,
            ),
            SttEngineKind.server => _newServerEngine(),
            SttEngineKind.system => SystemSttEngine(lang: lang),
          };
      _sttKind = effectiveEngine;
      _sttNativeVoice = false;
    }
    return _stt!;
  }

  Future<bool> sttAvailable() => _sttEngine().available();

  /// Comprueba si el dictado puede funcionar y **resuelve el motor real** a usar
  /// (deja [_stt] listo). Si el motor del sistema no está disponible —móvil sin
  /// reconocedor de voz, p.ej. GrapheneOS o emuladores— cae automáticamente a
  /// Whisper on-device cuando el modelo ya está descargado. Devuelve un estado
  /// accionable para que la UI guíe al usuario en vez de fallar en silencio.
  Future<SttCheck> checkStt() async {
    _cancelHeavyModelIdleRelease();
    try {
      return await _checkStt();
    } finally {
      _scheduleHeavyModelIdleRelease();
    }
  }

  Future<SttCheck> _checkStt() async {
    // Spec 031: si el idioma de la app cambió, el motor cacheado dicta en el
    // idioma anterior — reciclarlo ANTES de decidir si es reutilizable.
    _recycleSttIfLangChanged();
    // Modo nativo Desktop (spec 048/US5): solo requiere micrófono; el modelo
    // vive en el servidor. El engine se resuelve/reutiliza en _sttEngine().
    if (nativeVoiceActive && debugSttFactory == null) {
      try {
        final ready = await _sttEngine().available();
        return SttCheck(
          ready ? SttStatus.ready : SttStatus.needsMicPermission,
          SttEngineKind.server,
        );
      } catch (e) {
        debugPrint('[voice-stab] checkStt nativo falló: $e');
        return const SttCheck(
          SttStatus.needsServerConfig,
          SttEngineKind.server,
        );
      }
    }
    final effectiveEngine = effectiveConversationSttEngine;
    // FIX-1 (TASK-022): reutiliza el motor STT ya resuelto en vez de destruirlo
    // y reconstruirlo en CADA turno. saveSettings() ya pone _stt=null cuando
    // cambia el motor o el modelo Whisper, así que un _stt no nulo aquí ya es del
    // tipo correcto. Recrear el motor (y con él un AudioRecord nativo + contexto
    // whisper.cpp) turno tras turno provocaba fugas/cuelgues tras varias
    // interacciones. La verificación de disponibilidad sigue corriendo (barata:
    // permiso de micro + modelo presente), pero sin recrear el recorder.
    // El motor SERVER se excluye de la reutilización ordinaria para comprobar
    // de nuevo la conexión antes de cada captura.
    final reusable =
        _stt != null &&
        _sttKind != SttEngineKind.server &&
        _sttKind != SttEngineKind.hermesServer;
    if (reusable) {
      final ok = await _stt!.available();
      final kind = _sttKind ?? effectiveEngine;
      debugPrint('[voice-stab] checkStt reuse engine=${kind.name}');
      return SttCheck(
        ok ? SttStatus.ready : SttStatus.needsMicPermission,
        kind,
      );
    }
    if (_stt != null &&
        (_sttKind == SttEngineKind.server ||
            _sttKind == SttEngineKind.hermesServer)) {
      final oldStt = _stt;
      _stt = null;
      _sttKind = null;
      await _disposeSttEngine(oldStt, reason: 'server_recheck');
    }
    debugPrint('[voice-stab] checkStt create engine=${effectiveEngine.name}');

    // Atajo solo-tests: con un motor inyectado saltamos la resolución real
    // (plugins de plataforma, modelos en disco) y ejercitamos el ciclo de vida.
    if (debugSttFactory != null) {
      _stt = debugSttFactory!();
      _sttKind = effectiveEngine;
      final ok = await _stt!.available();
      return SttCheck(
        ok ? SttStatus.ready : SttStatus.needsMicPermission,
        effectiveEngine,
      );
    }

    if (effectiveEngine == SttEngineKind.whisper) {
      if (!await whisperModelReady()) {
        return const SttCheck(
          SttStatus.needsWhisperModel,
          SttEngineKind.whisper,
        );
      }
      _stt = _newWhisperEngine();
      _sttKind = SttEngineKind.whisper;
      final ok = await _stt!.available();
      return SttCheck(
        ok ? SttStatus.ready : SttStatus.needsMicPermission,
        SttEngineKind.whisper,
      );
    }

    if (effectiveEngine == SttEngineKind.sherpaLive) {
      if (!await sherpaModelReady()) {
        return const SttCheck(
          SttStatus.needsSherpaModel,
          SttEngineKind.sherpaLive,
        );
      }
      _stt = _newSherpaEngine();
      _sttKind = SttEngineKind.sherpaLive;
      final ok = await _stt!.available();
      return SttCheck(
        ok ? SttStatus.ready : SttStatus.needsMicPermission,
        SttEngineKind.sherpaLive,
      );
    }

    if (effectiveEngine == SttEngineKind.hermesServer) {
      final transcribe = _hermesDictationTranscribe;
      if (transcribe == null) {
        return const SttCheck(
          SttStatus.needsServerConfig,
          SttEngineKind.hermesServer,
        );
      }
      final engine = buildHermesServerSttEngine(
        transcribeRequest: _guardedHermesDictationTranscribe,
        lang: voiceLang,
        onLevel: (v) => micLevel.value = v,
      );
      if (!await engine.available()) {
        await engine.dispose();
        return const SttCheck(
          SttStatus.needsMicPermission,
          SttEngineKind.hermesServer,
        );
      }
      _stt = engine;
      _sttKind = SttEngineKind.hermesServer;
      return const SttCheck(SttStatus.ready, SttEngineKind.hermesServer);
    }

    if (effectiveEngine == SttEngineKind.server) {
      if (_engineSettings.serverSttUrl.trim().isEmpty) {
        return const SttCheck(
          SttStatus.needsServerConfig,
          SttEngineKind.server,
        );
      }
      await serverSttToken(); // refresca el token cacheado desde el Keystore
      final engine = _newServerEngine();
      // Sin permiso de micro no podemos dictar aunque el servidor responda.
      if (!await engine.available()) {
        // Distingue "sin micro" (servidor OK) de "servidor no responde".
        final serverOk = await engine.ping();
        await engine.dispose();
        return SttCheck(
          serverOk ? SttStatus.needsMicPermission : SttStatus.needsServerConfig,
          SttEngineKind.server,
        );
      }
      _stt = engine;
      _sttKind = SttEngineKind.server;
      return const SttCheck(SttStatus.ready, SttEngineKind.server);
    }

    // Motor del sistema (default).
    final sys = SystemSttEngine(lang: voiceLang);
    if (await sys.available()) {
      _stt = sys;
      _sttKind = SttEngineKind.system;
      return const SttCheck(SttStatus.ready, SttEngineKind.system);
    }
    // Distinguimos "falta permiso de micro" de "no hay reconocedor": dan
    // mensajes y acciones distintas en la UI.
    final micDenied = !sys.micGranted;
    await sys.dispose();
    if (micDenied) {
      return const SttCheck(SttStatus.needsMicPermission, SttEngineKind.system);
    }

    return const SttCheck(SttStatus.systemUnavailable, SttEngineKind.system);
  }

  /// ¿La ruta elegida graba primero y transcribe al detener?
  ///
  /// Esta consulta alimenta la proyección visual y puede ejecutarse mientras
  /// Hermes todavía está respondiendo. Por eso nunca debe resolver ni construir
  /// un motor STT: hacerlo desde un `build`/`notifyListeners` abría Sherpa antes
  /// de tiempo, solapaba STT y TTS y añadía varios segundos al siguiente turno.
  /// Cuando ya existe un motor usamos su capacidad real (incluido el fallback
  /// sistema→Whisper); antes de la primera escucha inferimos la semántica de la
  /// ruta estrictamente seleccionada.
  bool get sttRecordsThenTranscribes {
    final engine = _stt;
    if (engine != null) return !engine.supportsPartials;
    if (nativeVoiceActive) return true;
    return switch (effectiveConversationSttEngine) {
      SttEngineKind.whisper ||
      SttEngineKind.hermesServer ||
      SttEngineKind.server => true,
      SttEngineKind.sherpaLive || SttEngineKind.system => false,
    };
  }

  /// ¿Está activo el auto-stop por silencio (VAD) para el dictado actual? Solo
  /// aplica a Whisper; el motor del sistema ya hace su propio endpointing.
  bool get vadActive => _engineSettings.vadEnabled && sttRecordsThenTranscribes;

  /// Arranca el dictado. [onSpeechEnd] avisa cuando el VAD decide que dejaste de
  /// hablar y empieza a transcribir (para que la UI cambie a "transcribiendo").
  /// [onCaptureReady] confirma que el motor actual ya adquirió su recorder; la
  /// UI no debe inferirlo de la mera creación del Stream.
  /// [continuous]: dictado del composer (el usuario para con el botón; las pausas
  /// no cierran el turno). En modo conversación de voz se deja en false.
  Stream<SttResult> startDictation({
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
  }) {
    _cancelHeavyModelIdleRelease();
    _setDictationActive(true);
    final epoch = ++_dictationEpoch;
    late final Stream<SttResult> source;
    try {
      source = _sttEngine().listen(
        onSpeechEnd: onSpeechEnd,
        onCaptureReady: onCaptureReady,
        continuous: continuous,
      );
    } catch (_) {
      if (epoch == _dictationEpoch) _setDictationActive(false);
      _scheduleHeavyModelIdleRelease();
      rethrow;
    }
    void finishTracking() {
      if (epoch != _dictationEpoch || !_dictationActive) return;
      _setDictationActive(false);
      _scheduleHeavyModelIdleRelease();
    }

    // `async*` difiere la suscripción a [source]. Los motores STT publican un
    // broadcast y un final inmediato entre `startDictation()` y ese alta se
    // perdería. El controller síncrono se suscribe al source dentro del propio
    // `listen()`, manteniendo además el cierre/cancelación para el idle tracking.
    late final StreamController<SttResult> tracked;
    StreamSubscription<SttResult>? sourceSubscription;
    tracked = StreamController<SttResult>(
      sync: true,
      onListen: () {
        sourceSubscription = source.listen(
          tracked.add,
          onError: tracked.addError,
          onDone: () {
            finishTracking();
            // La fuente ya ha terminado: no dejes que el `onCancel` automático
            // del controller intente cancelar esa misma suscripción mientras
            // todavía está entregando su `done`. Ese ciclo impedía cerrar
            // [tracked] y dejaba el composer atascado en "transcribiendo".
            sourceSubscription = null;
            unawaited(tracked.close());
          },
        );
      },
      onPause: () => sourceSubscription?.pause(),
      onResume: () => sourceSubscription?.resume(),
      onCancel: () async {
        try {
          await sourceSubscription?.cancel();
        } finally {
          finishTracking();
        }
      },
    );
    return tracked.stream;
  }

  /// Para el dictado en curso **conservando** el motor para el siguiente turno
  /// (NO lo libera). Es la parada normal entre escuchas: parar ≠ liberar. Si el
  /// motor ya fue liberado (salida del modo voz) es un no-op, para no resucitar
  /// un AudioRecord nuevo solo para detenerlo. Para liberar de verdad al salir
  /// del modo voz, usa [disposeSttForVoiceExit].
  Future<void> stopDictation() async {
    try {
      if (_stt == null) return;
      debugPrint('[voice-stab] stopDictation');
      await _stt!.stop();
      micLevel.value = 0;
    } finally {
      _setDictationActive(false);
      _scheduleHeavyModelIdleRelease();
    }
  }

  /// Cancela el dictado sin pedir una transcripción final. Se usa cuando el
  /// usuario toca parar sin haber dictado texto: la UI debe volver a idle al
  /// instante, incluso si Whisper/servidor tardarían en cerrar el turno vacío.
  /// El siguiente dictado reconstruye un motor limpio.
  Future<void> cancelDictation() async {
    final engine = _stt;
    micLevel.value = 0;
    if (engine == null) {
      _setDictationActive(false);
      _scheduleHeavyModelIdleRelease();
      return;
    }
    // Residencia (spec 048/US4): cancelar solo cierra el micrófono y descarta
    // el turno; destruir aquí el modelo costaba ~3,5 s de recarga en la
    // siguiente escucha tras cada stop-and-talk/pausa (visto en la validación
    // física). El descarte es seguro: quien cancela ya soltó su suscripción,
    // así que el final que el motor emita al parar no llega a nadie. En
    // dispositivos que serializan (o motores no pesados) se conserva la
    // destrucción histórica.
    if (!serializesHeavyLocalVoiceModels &&
        !_sttNativeVoice &&
        (_sttKind == SttEngineKind.sherpaLive ||
            _sttKind == SttEngineKind.whisper)) {
      debugPrint('[voice-stab] cancelDictation: stop con modelo residente');
      try {
        await engine.stop();
      } catch (_) {
        // Parada best-effort: el turno ya está descartado.
      }
      _setDictationActive(false);
      _scheduleHeavyModelIdleRelease();
      return;
    }
    _stt = null;
    _sttKind = null;
    debugPrint('[voice-stab] disposeStt reason=dictation_cancel');
    await _disposeSttEngine(engine, reason: 'dictation_cancel');
    _setDictationActive(false);
    _scheduleHeavyModelIdleRelease();
  }

  /// Libera el motor STT al **salir** del modo voz: para el dictado, destruye el
  /// AudioRecord nativo + contexto whisper y deja [_stt] en null para no dejar el
  /// micrófono vivo en segundo plano (FIX-1, TASK-022). Usa `dispose()` del motor
  /// (no `stop()`) para abortar la grabación SIN disparar una transcripción al
  /// salir. Idempotente y best-effort: un fallo al liberar nunca tumba la app.
  Future<void> disposeSttForVoiceExit() {
    _cancelHeavyModelIdleRelease();
    _setDictationActive(false);
    ++_dictationEpoch;
    // La presión de memoria es por sesión de voz: al salir se limpia para que
    // la siguiente sesión vuelva a decidir con el perfil del dispositivo.
    _voiceMemoryPressure = false;
    return _disposeSttAndCaches(reason: 'voice_exit');
  }

  Future<void> _disposeSttAndCaches({required String reason}) {
    final engine = _stt;
    _stt = null;
    _sttKind = null;
    micLevel.value = 0;
    if (engine == null) {
      return _sttDisposalTail ?? Future<void>.value();
    }
    debugPrint('[voice-stab] disposeStt reason=$reason');
    return _disposeSttEngine(engine, reason: reason);
  }

  /// Libera ambos motores TTS al salir de conversación. En ONNX, `dispose()`
  /// termina también el isolate worker y su modelo nativo.
  Future<void> disposeTtsForVoiceExit() {
    _cancelHeavyModelIdleRelease();
    _voiceMemoryPressure = false;
    _speechGeneration++;
    final buildInFlight = _ttsBuildInFlight;
    _ttsBuildEpoch++;
    final Future<void>? buildCleanup = buildInFlight == null
        ? null
        : () async {
            try {
              await buildInFlight;
            } catch (_) {
              // La invalidación de epoch obliga al builder a liberar su propio
              // resultado. El error de construcción no convierte el teardown
              // de Voz en un fallo visible.
            }
          }();
    final stopStream = _cancelNativeSpeechStream();
    // `dispose()` forma parte del contrato de cada motor y detiene también su
    // playback. Invalidamos primero el estado Dart y liberamos los waiters; no
    // esperamos a un `stop()` nativo potencialmente colgado antes de destruir
    // el worker/modelo que precisamente puede despertarlo.
    _invalidateReadOperation(discard: true, stopNative: false);
    _speechStopped = true;
    _speechQueue.clear();
    _releaseDrainWaiters();
    final response = _tts;
    final local = _localTts;
    _tts = null;
    _localTts = null;
    _ttsLang = null;
    _syncSpeaking();

    final pending = _ttsDisposalTail;
    if (response == null && local == null) {
      return Future.wait<void>([
        stopStream,
        ?pending,
        ?buildCleanup,
      ]).then<void>((_) {});
    }
    final completion = Completer<void>();
    final tail = completion.future;
    _ttsDisposalTail = tail;
    unawaited(() async {
      try {
        await Future.wait<void>([stopStream, ?pending, ?buildCleanup]);
        if (response != null) {
          try {
            await response.dispose();
          } catch (error) {
            debugPrint('[voice-stab] dispose TTS error: $error');
          }
        }
        if (local != null && !identical(local, response)) {
          try {
            await local.dispose();
          } catch (error) {
            debugPrint('[voice-stab] dispose local TTS error: $error');
          }
        }
      } finally {
        _syncSpeaking();
        if (!completion.isCompleted) completion.complete();
        if (identical(_ttsDisposalTail, tail)) _ttsDisposalTail = null;
      }
    }());
    return tail;
  }

  // ── Modelo Whisper (descarga on-device) ─────────────────────────────
  Future<String> _whisperPath() => WhisperController().getPath(whisperModel);

  Future<bool> whisperModelReady() async =>
      File(await _whisperPath()).existsSync();

  /// Descarga el modelo Whisper con progreso (0..1). Lo guarda donde el plugin
  /// lo espera. Idempotente.
  Future<void> downloadWhisperModel({void Function(double)? onProgress}) async {
    final path = await _whisperPath();
    final file = File(path);
    if (file.existsSync()) {
      onProgress?.call(1);
      return;
    }
    final req = http.Request('GET', whisperModel.modelUri);
    final res = await http.Client().send(req);
    if (res.statusCode != 200) {
      throw Exception('Model download failed (${res.statusCode}).');
    }
    final total = res.contentLength ?? 0;
    var received = 0;
    final tmp = File('$path.part');
    final sink = tmp.openWrite();
    await for (final chunk in res.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }
    await sink.close();
    await tmp.rename(path);
    onProgress?.call(1);
  }

  // ── Modelos del STT en vivo (sherpa-onnx) ───────────────────────────
  /// ¿El modelo sherpa activo (según ajustes) está listo (modelo + VAD)?
  Future<bool> sherpaModelReady() => sherpaModels.isReady(sherpaModel);

  /// ¿Un modelo sherpa concreto está listo?
  Future<bool> sherpaReady(SherpaSttModel m) => sherpaModels.isReady(m);

  /// Descarga (con progreso) un modelo sherpa y su VAD. Idempotente.
  Future<void> downloadSherpaModel(
    SherpaSttModel m, {
    void Function(SherpaPrepProgress)? onProgress,
  }) => sherpaModels.download(m, onProgress: onProgress);

  /// Borra un modelo sherpa descargado (conserva el VAD compartido).
  Future<void> deleteSherpaModel(SherpaSttModel m) async {
    await sherpaModels.delete(m);
    if (_settings.sherpaModel == m.kind) {
      final oldStt = _stt;
      _stt = null;
      _sttKind = null;
      await _disposeSttEngine(oldStt, reason: 'model_deleted');
    }
  }

  Future<void> dispose() async {
    disableHermesServerDictation(force: true);
    disableNativeVoice(force: true);
    _disposed = true;
    _activeConversationSpeechLease = null;
    _cancelHeavyModelIdleRelease();
    _memoryPressureEvictionPending = false;
    prepareReadAloudPlayback = null;
    _invalidateReadOperation(discard: true, stopNative: false);
    await Future.wait([disposeTtsForVoiceExit(), disposeSttForVoiceExit()]);
    _readAloudSession.dispose();
    voiceConsent.dispose();
    bargeInEnabled.dispose();
    speaking.dispose();
    micLevel.dispose();
    microphoneCapturing.dispose();
  }
}
