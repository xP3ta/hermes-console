// STT en vivo por SERVIDOR (faster-whisper en GPU, estilo Jarvis pleno). Abre el
// micrófono en streaming y manda PCM por WebSocket a tu servidor Hermes-STT; este
// devuelve transcripción PARCIAL mientras hablas y un FINAL al detectar fin de
// frase. Es la opción rápida (~0,2–0,5 s con GPU) pero NO privada-on-device: el
// audio sale del teléfono hacia TU servidor (por Tailscale/LAN). La alternativa
// 100% privada es el motor en vivo on-device (sherpa) — ver SherpaSttEngine.
//
// Protocolo (lo sirve hermes_stt_server.py):
//   conexión  ws://HOST:PUERTO (spec H003 C8: SIN token en la query — se
//             manda como primer mensaje, ver auth abajo; fallback legacy con
//             ?token=TOKEN si el servidor no lo reconoce)
//   app → srv : primer mensaje de texto {"type":"auth","token":TOKEN} (si hay
//             token); luego frames binarios PCM16LE 16 kHz mono; texto
//             {"type":"reset"|"eof"}
//   srv → app : {"type":"ready"|"partial"|"endpoint"|"final"|"error", ...}
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../../utils/transport_privacy.dart';
import 'stt_engine.dart';
import 'voice_latency_trace.dart';

@visibleForTesting
String serverSttPublicErrorMessage(Object? _) =>
    'Server speech recognition failed.';

@visibleForTesting
Map<String, double>? serverSttPublicMeta(Object? raw) {
  if (raw is! Map) return null;
  final safe = <String, double>{};
  for (final key in const ['voiced_secs', 'avg_logprob', 'no_speech_prob']) {
    final value = raw[key];
    if (value is num && value.isFinite) safe[key] = value.toDouble();
  }
  return safe.isEmpty ? null : safe;
}

/// Resultado de [ServerSttEngine._connectWithAuth]: el canal (para escribir)
/// más el stream de LECTURA correcto para el resto de la sesión (broadcast
/// si hubo sondeo de auth, o el propio `channel.stream` si no) y el primer
/// mensaje ya recibido durante el sondeo, si lo hubo (para no perderlo).
typedef _SttChannel = ({
  WebSocketChannel channel,
  Stream<dynamic> stream,
  dynamic firstMessage,
});

/// Grabador inyectable para probar cancelación durante el arranque.
abstract class ServerSttRecorder {
  Future<bool> hasPermission();

  Future<Stream<Uint8List>> startStream(RecordConfig config);

  Future<void> stop();

  Future<void> dispose();
}

class _PluginServerSttRecorder implements ServerSttRecorder {
  final AudioRecorder _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) =>
      _recorder.startStream(config);

  @override
  Future<void> stop() => _recorder.stop();

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Sesión WebSocket inyectable; el token y el fallback legacy siguen resueltos
/// por el conector productivo antes de construir esta frontera.
abstract class ServerSttSession {
  dynamic get firstMessage;

  Stream<dynamic> get messages;

  void add(Object data);

  Future<void> close();
}

class _WebSocketServerSttSession implements ServerSttSession {
  _WebSocketServerSttSession(this._connection);

  final _SttChannel _connection;

  @override
  dynamic get firstMessage => _connection.firstMessage;

  @override
  Stream<dynamic> get messages => _connection.stream;

  @override
  void add(Object data) => _connection.channel.sink.add(data);

  @override
  Future<void> close() =>
      _connection.channel.sink.close(ws_status.normalClosure);
}

class _ServerListenOperation {
  _ServerListenOperation(this.generation, this.controller, this.latencyTurn);

  final int generation;
  final StreamController<SttResult> controller;
  final VoiceLatencyTurn? latencyTurn;
  bool cancelled = false;
  bool started = false;
  bool endpointObserved = false;
  bool finalReceived = false;
  bool audioSent = false;
  bool eofSent = false;
  int connectionRetries = 0;
  Completer<bool>? readiness;
}

class ServerSttEngine implements SttEngine {
  /// Base del WebSocket, p.ej. `ws://192.168.1.10:9123`. Sin el `?token`.
  final String baseUrl;

  /// Token del servidor (se añade como `?token=`). Puede ir vacío.
  final String token;

  /// Reporta el nivel de micrófono normalizado (0..1) para el orbe.
  final void Function(double level)? onLevel;

  /// Gate de energía anti-alucinación del CLIENTE (ver comentario junto a
  /// [_speechPeakThreshold]): con `true` (default, comportamiento intacto del
  /// pipeline viejo turn-based) el `final` con pico de voz insuficiente se
  /// descarta. Con `false` no se evalúa — pensado para el pipeline nuevo
  /// (spec 025) cuando el VAD local ya decide el turno y no hace falta este
  /// filtro heurístico por energía.
  final bool enableGhostGate;

  /// Con `true`, el mensaje `endpoint` del servidor NO dispara
  /// `onSpeechEnd` (spec 025 F2): el cliente manda el fin de turno con su
  /// propio VAD local (ver [endTurn]) en vez de fiarse del endpointing del
  /// servidor. Default `false` = comportamiento actual intacto.
  final bool ignoreServerEndpoint;

  ServerSttEngine({
    required String baseUrl,
    this.token = '',
    this.onLevel,
    this.enableGhostGate = true,
    this.ignoreServerEndpoint = false,
    ServerSttRecorder Function()? recorderFactory,
    Future<ServerSttSession> Function(Uri uri)? connector,
  }) : baseUrl = TransportPrivacy.requireAllowed(baseUrl.trim()),
       _recorderFactory = recorderFactory ?? _PluginServerSttRecorder.new {
    _connector =
        connector ??
        (_) async => _WebSocketServerSttSession(
          await _connectWithAuth(const Duration(seconds: 6)),
        );
  }

  static const int _sampleRate = 16000;

  // Recorder POR SESIÓN: el engine se reusa entre dictados (checkStt), pero
  // reusar el mismo AudioRecorder hacía que el 2º startStream fallara y el turno
  // se cerrara solo. Creamos uno nuevo en cada listen y lo desechamos al cerrar.
  final ServerSttRecorder Function() _recorderFactory;
  late final Future<ServerSttSession> Function(Uri uri) _connector;
  ServerSttRecorder? _recorder;
  // Red de seguridad de stop(): si no se cancela al iniciar otro dictado, su
  // _finish() tardío cerraba el SIGUIENTE turno (engine reusado) → el 2º dictado
  // moría a los pocos segundos.
  Timer? _safetyTimer;
  ServerSttSession? _session;
  StreamSubscription? _wsSub;
  StreamSubscription<Uint8List>? _audioSub;
  StreamController<SttResult>? _controller;
  void Function()? _onSpeechEnd;
  bool _closing = false;
  int _generation = 0;
  _ServerListenOperation? _operation;
  Future<void> _startupTail = Future<void>.value();
  Future<void> _stopTail = Future<void>.value();
  bool _disposed = false;
  Future<void>? _disposeFuture;

  // ── Tap de audio en el punto de captura (spec 025 F2) ────────────────────
  // Broadcast SIN buffer: si nadie escucha, `.add()` es un no-op barato (solo
  // recorre una lista de listeners vacía) — sin coste real para el pipeline
  // viejo, que no la usa. Vive por la vida del engine (no por sesión/turno):
  // el motor se reusa entre dictados (ver comentario de `_recorder` arriba),
  // así que un StreamController por turno perdería suscriptores externos al
  // reconectar. Emite CADA chunk que llega del micro, incluso con
  // `muteToServer=true`: el VAD local necesita ver audio aunque ese chunk no
  // se mande al servidor (silencio selectivo del modo continuo, spec 024 v5).
  final StreamController<Uint8List> _audioTapController =
      StreamController<Uint8List>.broadcast();

  /// Copia de cada chunk PCM16LE del micro, EN EL PUNTO DE CAPTURA (antes del
  /// posible `muteToServer`). Pensado para que un VAD local (spec 025) oiga
  /// el audio real aunque el pipeline viejo esté silenciando el envío al
  /// servidor. Sin suscriptores no cuesta nada.
  Stream<Uint8List> get audioTap => _audioTapController.stream;

  @override
  bool get supportsPartials => true;

  /// Dictado (hold): pide al servidor que NO cierre la frase por silencio; el
  /// turno termina con eof (stop manual). Así las pausas no cortan y el botón de
  /// parar no desaparece. Se activa solo para el dictado del composer.
  bool _hold = false;

  // Capacidad interna del transporte remoto. El modo de voz público no la usa;
  // conserva el comportamiento por turnos con `persistent=false`.
  bool _persistent = false;

  /// True si el WS sigue vivo y puede recibir audio sin reconectar.
  /// Solo tiene sentido para consumidores internos que pidan persistencia.
  bool get isSessionAlive => _session != null && !_closing;

  // ── Gate de energía anti-alucinación ─────────────────────────────────────
  // faster-whisper alucina frases plausibles ("hola", "¿puedes buscar las
  // noticias más importantes del día?") sobre ruido ambiente o silencio, y el
  // servidor no puede distinguirlo. El cliente sí: si el pico RMS del turno
  // nunca llegó a nivel de VOZ real, el 'final' del servidor se descarta (se
  // emite vacío, que el bucle de voz trata como "no te oí"). El umbral es
  // conservador: hablando a distancia normal del móvil el pico supera 0.10 de
  // sobra (escala 0..1 de _rms, que ya lleva ganancia ×4); ruido de fondo,
  // teclado o TV lejana quedan por debajo. El pico se loguea SIEMPRE en el
  // final para poder recalibrar con datos reales.
  static const double _speechPeakThreshold = 0.10;
  double _turnPeakLevel = 0;

  /// Última llegada de audio del micro (cualquier chunk, con o sin voz). El
  /// recorder emite continuamente mientras está vivo: si esto envejece >10 s,
  /// el stream murió en silencio (visto en vivo 2026-07-01: FGS baja tras el
  /// TTS y el orbe queda "escuchando" sin oír). Lo vigila el watchdog del modo
  /// continuo (spec 024 T027) para reconectar solo.
  DateTime? lastAudioAt;

  /// Silencio selectivo hacia el servidor (spec 024 v5): con el altavoz
  /// sonando, el eco del TTS entraba, se transcribia deformado y esquivaba el
  /// filtro semantico (el asistente conversaba consigo mismo, 2026-07-02).
  /// true = el recorder sigue VIVO (lastAudioAt/nivel siguen) pero los bytes
  /// NO se envían al servidor. Lo gobierna el modo voz mientras el TTS habla,
  /// para impedir que Hermes se transcriba y se responda a sí mismo.
  bool muteToServer = false;

  /// URI SIN token (spec H003 C8): el token ya no viaja en la query — se
  /// manda como primer mensaje de texto (ver [_connectWithAuth]) para que no
  /// quede en la URL (logs de proxy/servidor, historial si el servidor tiene
  /// panel web).
  Uri get _uri {
    final u = Uri.parse(baseUrl.trim());
    final qp = <String, String>{...u.queryParameters, if (_hold) 'hold': '1'};
    return u.replace(queryParameters: qp.isEmpty ? null : qp);
  }

  /// URI legacy CON el token en la query (comportamiento previo a H003 C8).
  /// Solo se usa como fallback si un servidor legacy cierra la conexión al
  /// no reconocer el mensaje de auth como primer intercambio.
  Uri get _legacyUri {
    final u = Uri.parse(baseUrl.trim());
    final qp = <String, String>{
      ...u.queryParameters,
      if (token.isNotEmpty) 'token': token,
      if (_hold) 'hold': '1',
    };
    return u.replace(queryParameters: qp.isEmpty ? null : qp);
  }

  /// Solo el primer frame del handshake moderno puede autorizar el downgrade.
  /// Un error posterior a `ready` pertenece a una sesión ya negociada y nunca
  /// debe volver a exponer el token en la query.
  static bool _isLegacyAuthRejection(dynamic raw) {
    if (raw is! String) return false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['type'] != 'error') return false;
      final code = (decoded['code'] ?? '').toString().toLowerCase();
      final message = (decoded['message'] ?? '').toString().toLowerCase();
      final signal = '$code $message';

      final mentionsAuth =
          signal.contains('auth') ||
          signal.contains('token') ||
          signal.contains('credential') ||
          signal.contains('forbidden') ||
          signal.contains('access denied');
      final rejectsHandshakeShape =
          signal.contains('unknown message') ||
          signal.contains('unsupported message') ||
          signal.contains('message unsupported') ||
          signal.contains('message type unsupported') ||
          signal.contains('message type not supported') ||
          signal.contains('unrecognized message') ||
          signal.contains('protocol unsupported') ||
          signal.contains('unsupported protocol');
      return mentionsAuth || rejectsHandshakeShape;
    } catch (_) {
      return false;
    }
  }

  Future<_SttChannel> _connectLegacy(Duration readyTimeout) async {
    final legacy = WebSocketChannel.connect(_legacyUri);
    await legacy.ready.timeout(readyTimeout);
    return (channel: legacy, stream: legacy.stream, firstMessage: null);
  }

  Future<void> _closeQuietly(WebSocketChannel channel) async {
    try {
      await channel.sink.close(ws_status.normalClosure);
    } catch (_) {}
  }

  /// Conecta el WS de STT remoto (spec H003 C8). Nuevo protocolo: abre el
  /// socket SIN token en la query y lo manda como PRIMER mensaje de texto
  /// `{"type":"auth","token":…}` justo después de que el socket esté listo.
  /// Para confirmar que el servidor lo aceptó (y no cerró la conexión al no
  /// reconocerlo — servidor legacy) se convierte el stream en broadcast y se
  /// espera un primer evento con timeout corto; ese primer mensaje se
  /// devuelve en `firstMessage` para que el caller lo procese (nadie lo
  /// pierde). Si el socket se cierra/erroriza/no dice nada en ese plazo, se
  /// reintenta UNA vez con el token en la query (comportamiento anterior a
  /// este cambio) — fallback documentado para servidores viejos.
  Future<_SttChannel> _connectWithAuth(Duration readyTimeout) async {
    final ch = WebSocketChannel.connect(_uri);
    try {
      await ch.ready.timeout(readyTimeout);
    } catch (_) {
      await _closeQuietly(ch);
      rethrow;
    }
    if (token.isEmpty) {
      // Sin token no hay nada que autenticar: comportamiento igual que
      // antes, sin handshake extra.
      return (channel: ch, stream: ch.stream, firstMessage: null);
    }
    ch.sink.add(jsonEncode({'type': 'auth', 'token': token}));
    final bcast = ch.stream.asBroadcastStream();
    dynamic first;
    try {
      first = await bcast.first.timeout(readyTimeout);
    } catch (_) {
      await _closeQuietly(ch);
      return _connectLegacy(readyTimeout);
    }
    if (_isLegacyAuthRejection(first)) {
      await _closeQuietly(ch);
      return _connectLegacy(readyTimeout);
    }
    return (channel: ch, stream: bcast, firstMessage: first);
  }

  /// Conecta, espera `ready` y cierra. Sirve para validar config/red en Ajustes
  /// y en checkStt antes de abrir el micrófono.
  Future<bool> ping({Duration timeout = const Duration(seconds: 4)}) async {
    if (baseUrl.trim().isEmpty) return false;
    WebSocketChannel? ch;
    try {
      final conn = await _connectWithAuth(timeout);
      ch = conn.channel;
      final first =
          conn.firstMessage ?? await conn.stream.first.timeout(timeout);
      final msg = jsonDecode(first as String) as Map<String, dynamic>;
      return msg['type'] == 'ready';
    } catch (_) {
      return false;
    } finally {
      await ch?.sink.close(ws_status.normalClosure);
    }
  }

  @override
  Future<bool> available() async {
    // Recorder temporal solo para comprobar permiso (el de la sesión se crea en
    // listen). Así available no depende de un recorder persistente.
    if (_disposed) return false;
    final probe = _recorderFactory();
    bool hasMic;
    try {
      hasMic = await probe.hasPermission();
    } finally {
      await probe.dispose();
    }
    if (!hasMic) return false;
    if (_disposed) return false;
    return ping();
  }

  bool _isCurrent(_ServerListenOperation operation) =>
      !_disposed &&
      !operation.cancelled &&
      identical(_operation, operation) &&
      operation.generation == _generation;

  @override
  Stream<SttResult> listen({
    String localeId = 'es_ES',
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    // continuous=dictado del composer → modo hold en el servidor (no auto-cierra
    // por silencio). El usuario para con el botón. En modo voz queda en false.
    bool continuous = false,
    // `persistent` queda como capacidad interna del transporte remoto. El modo
    // de voz público no la activa: su contrato es por turnos.
    bool persistent = false,
  }) {
    _persistent = persistent;
    // Cerrar el controller anterior si todavía está abierto (evitar fuga en
    // pausa/resume: cada listen() crea un controller nuevo; el viejo quedaría
    // huérfano si no se cierra aquí).
    final previous = _operation;
    if (previous != null) {
      previous.cancelled = true;
      if (!previous.controller.isClosed) unawaited(previous.controller.close());
    }
    final controller = StreamController<SttResult>();
    final operation = _ServerListenOperation(
      ++_generation,
      controller,
      VoiceLatencyTrace.current.currentTurn,
    );
    _operation = operation;
    _controller = controller;
    _onSpeechEnd = onSpeechEnd;
    _hold = continuous;
    _closing = false;
    _turnPeakLevel = 0;
    lastAudioAt = null;
    if (!persistent) muteToServer = false;
    final stopBeforeStart = _stopTail;
    _startupTail = _startupTail.then(
      (_) async {
        await stopBeforeStart;
        await _startOperation(operation, onCaptureReady);
      },
      onError: (_) async {
        await stopBeforeStart;
        await _startOperation(operation, onCaptureReady);
      },
    );
    return controller.stream;
  }

  static const RecordConfig _streamConfig = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: _sampleRate,
    numChannels: 1,
    // El recorder debe sobrevivir a la pérdida de audio focus provocada por
    // TTS; el antieco sigue siendo muteToServer (spec 024 v6).
    audioInterruption: AudioInterruptionMode.none,
  );

  Future<void> _startOperation(
    _ServerListenOperation operation,
    void Function()? onCaptureReady,
  ) async {
    final controller = operation.controller;
    ServerSttRecorder? recorder;
    ServerSttSession? session;
    StreamSubscription? wsSub;
    try {
      if (!_isCurrent(operation)) return;
      _safetyTimer?.cancel();
      _safetyTimer = null;
      await _audioSub?.cancel();
      if (!_isCurrent(operation)) return;
      _audioSub = null;

      if (_persistent && isSessionAlive) {
        try {
          await _recorder?.dispose();
        } catch (_) {}
        if (!_isCurrent(operation)) return;
        recorder = _recorderFactory();
        _recorder = recorder;
        if (!await recorder.hasPermission()) {
          if (_isCurrent(operation)) {
            controller.addError(Exception('No microphone permission.'));
            await controller.close();
          }
          return;
        }
        if (!_isCurrent(operation)) return;
        session = _session;
        session?.add(jsonEncode({'type': 'reset'}));
        final stream = await recorder.startStream(_streamConfig);
        if (!_isCurrent(operation)) {
          await _discardLate(recorder: recorder);
          if (identical(_recorder, recorder)) _recorder = null;
          return;
        }
        operation.started = true;
        operation.latencyTurn?.mark(VoiceLatencyPoint.sttStarted);
        onCaptureReady?.call();
        _listenToAudio(operation, stream);
        return;
      }

      await _wsSub?.cancel();
      if (!_isCurrent(operation)) return;
      _wsSub = null;
      try {
        await _session?.close();
      } catch (_) {}
      if (!_isCurrent(operation)) return;
      _session = null;
      try {
        await _recorder?.dispose();
      } catch (_) {}
      if (!_isCurrent(operation)) return;

      recorder = _recorderFactory();
      _recorder = recorder;
      if (!await recorder.hasPermission()) {
        if (_isCurrent(operation)) {
          controller.addError(Exception('No microphone permission.'));
          await controller.close();
        }
        return;
      }
      if (!_isCurrent(operation)) return;
      if (baseUrl.trim().isEmpty) {
        controller.addError(
          Exception('Set the STT server URL in Settings › Voice.'),
        );
        await controller.close();
        return;
      }

      while (_isCurrent(operation)) {
        try {
          session = await _connector(_uri);
        } catch (_) {
          if (!_isCurrent(operation)) return;
          if (operation.connectionRetries++ == 0) continue;
          rethrow;
        }
        if (!_isCurrent(operation)) {
          await _discardLate(recorder: recorder, session: session);
          if (identical(_recorder, recorder)) _recorder = null;
          return;
        }
        _session = session;
        final ready = Completer<bool>();
        operation.readiness = ready;
        var disconnectedHandled = false;
        void receive(dynamic raw) {
          if (!_isCurrent(operation)) return;
          if (raw is String) {
            try {
              if ((jsonDecode(raw) as Map)['type'] == 'ready' &&
                  !ready.isCompleted) {
                ready.complete(true);
              }
            } catch (_) {}
          }
          _onServerMessage(operation, raw);
        }

        void disconnected() {
          if (!_isCurrent(operation) ||
              (operation.finalReceived && !_persistent) ||
              _closing ||
              disconnectedHandled) {
            return;
          }
          disconnectedHandled = true;
          _session = null;
          if (!ready.isCompleted) {
            ready.complete(false);
          } else if (!operation.audioSent &&
              !operation.eofSent &&
              operation.connectionRetries++ == 0) {
            operation.started = false;
            _startupTail = _startupTail.then(
              (_) => _startOperation(operation, onCaptureReady),
            );
          } else {
            _failTurn(
              'Server closed before transcription finished. Please retry.',
            );
          }
        }

        wsSub = session.messages.listen(
          receive,
          onError: (Object _) => disconnected(),
          onDone: disconnected,
        );
        _wsSub = wsSub;
        if (session.firstMessage != null) receive(session.firstMessage);
        final isReady = await ready.future.timeout(
          const Duration(seconds: 6),
          onTimeout: () => false,
        );
        if (!_isCurrent(operation) || _closing) return;
        if (isReady) break;
        await wsSub.cancel();
        await session.close();
        if (operation.connectionRetries++ > 0) {
          _failTurn(
            'Server closed before speech recognition was ready. Please retry.',
          );
          return;
        }
      }
      if (!_isCurrent(operation) || session == null) return;
      session.add(jsonEncode({'type': 'reset'}));
      final stream = await recorder.startStream(_streamConfig);
      if (!_isCurrent(operation)) {
        await wsSub?.cancel();
        if (identical(_wsSub, wsSub)) _wsSub = null;
        await _discardLate(recorder: recorder, session: session);
        if (identical(_recorder, recorder)) _recorder = null;
        if (identical(_session, session)) _session = null;
        return;
      }
      operation.started = true;
      operation.latencyTurn?.mark(VoiceLatencyPoint.sttStarted);
      onCaptureReady?.call();
      _listenToAudio(operation, stream);
    } catch (_) {
      if (_isCurrent(operation)) {
        _failTurn(
          _persistent
              ? 'Could not resume server STT.'
              : 'Could not start server STT.',
        );
      }
    } finally {
      if (!_isCurrent(operation) && !controller.isClosed) {
        await controller.close();
      }
    }
  }

  void _listenToAudio(
    _ServerListenOperation operation,
    Stream<Uint8List> stream,
  ) {
    _audioSub = stream.listen(
      (bytes) {
        if (!_isCurrent(operation)) return;
        lastAudioAt = DateTime.now();
        _audioTapController.add(bytes);
        final level = _rms(bytes);
        if (level > _turnPeakLevel) _turnPeakLevel = level;
        onLevel?.call(level);
        final session = _session;
        if (session != null && !_closing && !muteToServer) {
          try {
            session.add(bytes);
            if (bytes.isNotEmpty) operation.audioSent = true;
          } catch (_) {
            _failTurn('Server connection error. Please retry.');
            return;
          }
          // `speechLastAboveThreshold` describe la última muestra de voz que
          // cruzó realmente la frontera de red de ESTA operación. PCM vacío,
          // silenciado o que no alcanzó el servidor nunca rellena la marca.
          if (bytes.length >= 2 &&
              bytes.length.isEven &&
              level >= _speechPeakThreshold) {
            operation.latencyTurn?.observeSpeechAboveThreshold();
          }
        }
      },
      onError: (Object _) {
        if (_isCurrent(operation)) _failTurn('Microphone capture failed.');
      },
    );
  }

  Future<void> _discardLate({
    ServerSttRecorder? recorder,
    ServerSttSession? session,
  }) async {
    try {
      await recorder?.stop();
    } catch (_) {}
    try {
      await recorder?.dispose();
    } catch (_) {}
    try {
      await session?.close();
    } catch (_) {}
  }

  void _onServerMessage(_ServerListenOperation operation, dynamic raw) {
    if (!_isCurrent(operation)) return;
    final controller = operation.controller;
    if (controller.isClosed) return;
    if (raw is! String) return; // el servidor solo manda texto JSON
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'partial':
        controller.add(
          SttResult((msg['text'] as String?)?.trim() ?? '', false),
        );
        break;
      case 'endpoint':
        operation.endpointObserved = true;
        operation.latencyTurn?.mark(VoiceLatencyPoint.speechEndpoint);
        // El transporte STT ya quedó iniciado cuando el recorder empezó a
        // alimentar el WebSocket. Este frame server-authored fija únicamente
        // el endpoint, no vuelve a etiquetar el inicio del reconocimiento.
        // ignoreServerEndpoint (spec 025 F2): con el VAD local al mando, el
        // endpointing del servidor no debe cerrar el turno — solo queda como
        // referencia en el log del servidor. Con false (default) se comporta
        // como siempre.
        if (!ignoreServerEndpoint) _onSpeechEnd?.call();
        break;
      case 'final':
        if (operation.finalReceived && !_persistent) return;
        operation.finalReceived = true;
        // Turn-based: cerrar todo (WS + recorder + controller).
        // Persistente: solo emitir SttResult(isFinal:true); el controller
        // PERMANECE ABIERTO toda la sesión WS. Cerrarlo aquí terminaba una
        // captura persistente después de un solo turno.
        final text = (msg['text'] as String?)?.trim() ?? '';
        if (!operation.endpointObserved) {
          operation.latencyTurn?.mark(
            VoiceLatencyPoint.speechEndpointUnavailable,
          );
        }
        operation.latencyTurn?.mark(VoiceLatencyPoint.sttFinal);
        final peak = _turnPeakLevel;
        _turnPeakLevel = 0; // siguiente turno (persistente) parte de cero
        // Gate de energía: texto sin voz real detrás = alucinación del server.
        // enableGhostGate=false (spec 025 F2): el pipeline nuevo trae su
        // propio VAD/gate local y no evalúa este filtro heurístico.
        final ghost =
            enableGhostGate && text.isNotEmpty && peak < _speechPeakThreshold;
        // meta (servidor v1.1, spec 024): voiced_secs/avg_logprob/no_speech_prob
        // del gate server-side. Antes solo se logueaba; ahora también viaja en
        // SttResult.meta (spec 025 F2) para que un consumidor (p.ej. el VAD
        // local o un futuro adaptador) lo use sin reimplementar el parseo.
        if (_persistent) operation.eofSent = false;
        final meta = serverSttPublicMeta(msg['meta']);
        debugPrint(
          '[VOICE] stt-server final len=${text.length}'
          ' peak=${peak.toStringAsFixed(3)}'
          '${meta != null ? ' voiced=${meta['voiced_secs']}'
                    ' logprob=${meta['avg_logprob']}'
                    ' nospeech=${meta['no_speech_prob']}' : ''}'
          '${ghost ? ' → DESCARTADO (pico < $_speechPeakThreshold: sin voz'
                    ' real, alucinación probable)' : ''}',
        );
        controller.add(SttResult(ghost ? '' : text, true, meta: meta));
        if (!_persistent) {
          unawaited(_finish(expected: _operation));
        }
        // Persistente: no tocar el controller; el WS sigue vivo para el
        // siguiente turno.
        break;
      case 'error':
        _failTurn(serverSttPublicErrorMessage(msg));
        break;
    }
  }

  /// PCM16LE → nivel RMS 0..1 para el orbe.
  static double _rms(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    if (n == 0) return 0;
    final bd = ByteData.sublistView(bytes);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
    }
    return (math.sqrt(sum / n) * 4).clamp(0.0, 1.0);
  }

  void _failTurn(String message) {
    final readiness = _operation?.readiness;
    if (readiness != null && !readiness.isCompleted) readiness.complete(false);
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      controller.addError(Exception(message));
    }
    unawaited(_finish(expected: _operation));
  }

  /// Cierra solo el StreamController del turno actual, sin tocar WS ni recorder.
  /// Usado en modo persistente para marcar fin de turno sin desconectar.
  void _endTurn() {
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
    _controller = null;
    _operation = null;
    onLevel?.call(0);
  }

  /// Cierra micro + WS sin tocar el controller (ya cerrado por quien llama).
  Future<void> _finish({_ServerListenOperation? expected}) async {
    bool stillExpected() => expected == null || identical(_operation, expected);
    if (!stillExpected()) return;
    if (_closing) return;
    _closing = true;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    onLevel?.call(0);
    await _audioSub?.cancel();
    if (!stillExpected()) return;
    _audioSub = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    if (!stillExpected()) return;
    try {
      await _recorder?.dispose();
    } catch (_) {}
    if (!stillExpected()) return;
    _recorder = null;
    try {
      await _session?.close();
    } catch (_) {}
    if (!stillExpected()) return;
    _session = null;
    await _wsSub?.cancel();
    if (!stillExpected()) return;
    _wsSub = null;
    final c = _controller;
    _controller = null;
    if (c != null && !c.isClosed) await c.close();
    if (identical(_operation, expected)) _operation = null;
  }

  @override
  Future<void> stop() {
    final operation = _operation;
    final wasStarting = operation != null && !operation.started;
    if (operation != null && operation.started) {
      _markLocalEndpoint(operation);
    }
    final controller = operation?.controller;
    final recorder = _recorder;
    final session = _session;
    final audioSub = _audioSub;
    final wsSub = _wsSub;
    final persistent = _persistent;
    if (wasStarting) {
      final readiness = operation.readiness;
      if (readiness != null && !readiness.isCompleted) {
        readiness.complete(false);
      }
      operation.cancelled = true;
      _operation = null;
      _generation++;
      if (identical(_controller, controller)) _controller = null;
      if (!controller!.isClosed) unawaited(controller.close());
    }
    final previousStop = _stopTail;
    final result = () async {
      await previousStop;
      await _stopOperation(
        operation: operation,
        wasStarting: wasStarting,
        recorder: recorder,
        session: session,
        audioSub: audioSub,
        wsSub: wsSub,
        persistent: persistent,
      );
    }();
    _stopTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _stopOperation({
    required _ServerListenOperation? operation,
    required bool wasStarting,
    required ServerSttRecorder? recorder,
    required ServerSttSession? session,
    required StreamSubscription<Uint8List>? audioSub,
    required StreamSubscription? wsSub,
    required bool persistent,
  }) async {
    if (wasStarting) {
      _safetyTimer?.cancel();
      _safetyTimer = null;
      await audioSub?.cancel();
      if (identical(_audioSub, audioSub)) _audioSub = null;
      await wsSub?.cancel();
      if (identical(_wsSub, wsSub)) _wsSub = null;
      if (identical(_recorder, recorder)) _recorder = null;
      if (identical(_session, session)) _session = null;
      await _discardLate(recorder: recorder, session: session);
      onLevel?.call(0);
      return;
    }
    // Parar manual (tap): pide al servidor cerrar la frase en curso y espera su
    // final. Si no llega pronto, cerramos igualmente.
    if (session != null &&
        !_closing &&
        operation != null &&
        !operation.eofSent) {
      operation.eofSent = true;
      try {
        session.add(jsonEncode({'type': 'eof'}));
      } catch (_) {}
    }
    // Deja de mandar audio ya.
    await audioSub?.cancel();
    if (identical(_audioSub, audioSub)) _audioSub = null;
    try {
      await recorder?.stop();
    } catch (_) {}
    onLevel?.call(0);
    if (!identical(_operation, operation)) return;
    // Red de seguridad: si el final no llega en 4 s, cierra el turno.
    // En modo persistente solo cerramos el controller (no el WS).
    _safetyTimer?.cancel();
    final expected = operation;
    _safetyTimer = Timer(const Duration(seconds: 4), () {
      if (!identical(_operation, expected)) return;
      if (persistent) {
        _endTurn();
      } else if (!_closing) {
        _failTurn('Server transcription timed out. Please retry.');
      }
    });
  }

  /// Cierre de turno decidido por un VAD LOCAL (spec 025 F2): manda `eof` al
  /// servidor para que corte la frase y devuelva su `final` ya, sin tocar el
  /// micrófono ni el WebSocket — a diferencia de [stop()], que además para el
  /// grabador y arma la red de seguridad de 4 s. Pensado para el modo
  /// persistente: el micro sigue abierto para el turno siguiente y el
  /// hangover del servidor (spec 024) queda como red de seguridad si este
  /// mensaje se pierde. Idempotente: si no hay WS abierto (o el engine se
  /// está cerrando) no hace nada.
  Future<void> endTurn() async {
    final operation = _operation;
    if (operation != null && _isCurrent(operation)) {
      _markLocalEndpoint(operation);
    }
    final c = _session;
    if (c == null || _closing || operation == null || operation.eofSent) return;
    operation.eofSent = true;
    try {
      c.add(jsonEncode({'type': 'eof'}));
    } catch (error) {
      // Si el eof no sale, el cierre del turno depende del hangover del
      // servidor — deja rastro para diagnosticarlo (A-032, spec 028).
      debugPrint('[stt] eof send failed (${error.runtimeType})');
    }
  }

  void _markLocalEndpoint(_ServerListenOperation operation) {
    if (operation.endpointObserved) return;
    operation.endpointObserved = true;
    operation.latencyTurn?.mark(VoiceLatencyPoint.speechEndpoint);
  }

  @override
  Future<void> dispose() async {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    final operation = _operation;
    if (operation != null) operation.cancelled = true;
    _generation++;
    _disposeFuture = () async {
      await _stopTail;
      await _startupTail;
      await _finish();
      if (!_audioTapController.isClosed) await _audioTapController.close();
    }();
    return _disposeFuture!;
  }
}
