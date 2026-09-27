import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../connection_manager.dart';
import 'hermes_pcm_stream.dart';
import 'voice_latency_trace.dart';

enum HermesSpeechStreamState {
  connecting,
  awaitingStart,
  streaming,
  draining,
  ended,
  fallback,
  cancelled,
  failedBeforeAudio,
  failedAfterAudio,
}

enum HermesSpeechStreamOutcome { played, fallback, partial, cancelled }

/// Motivo suficiente para no volver a probar el WS durante esta sesión nativa.
///
/// Solo el frame oficial `fallback` es concluyente: un 401, timeout o corte de
/// red no debe cachearse como "este Hermes no soporta streaming".
enum HermesSpeechStreamFallbackKind { providerUnsupported, transport, protocol }

/// Evidencia efímera de PCM realmente aceptado por AudioTrack.
///
/// Se conserva solo durante este proceso y se separa por identidad de
/// Dashboard/perfil/firma TTS. Reiniciar la app o cambiar la configuración
/// vuelve al estado honesto "se comprobará al hablar"; una configuración o un
/// handshake nunca marcan evidencia.
class HermesSpeechStreamEvidence {
  static final Map<String, Set<String?>> _observed = <String, Set<String?>>{};

  static String _key(String dashboardBaseUrl, String? profile) {
    final base = dashboardBaseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final normalizedProfile = profile?.trim();
    final profileKey =
        normalizedProfile == null ||
            normalizedProfile.isEmpty ||
            normalizedProfile == 'default'
        ? 'default'
        : normalizedProfile;
    return '$base::$profileKey';
  }

  static bool pcmObserved(
    String dashboardBaseUrl, {
    String? profile,
    String? ttsConfigurationSignature,
  }) =>
      _observed[_key(dashboardBaseUrl, profile)]?.contains(
        ttsConfigurationSignature,
      ) ??
      false;

  static void notePcmObserved(
    String dashboardBaseUrl, {
    String? profile,
    String? ttsConfigurationSignature,
  }) {
    _observed
        .putIfAbsent(_key(dashboardBaseUrl, profile), () => <String?>{})
        .add(ttsConfigurationSignature);
  }

  static void debugClear() => _observed.clear();
}

/// Fallo durante el upgrade WebSocket, antes de crear una sesión reproducible.
///
/// [endpointUnavailable] solo es true para respuestas HTTP concluyentes del
/// servidor/proxy. Red, timeout y autenticación siguen siendo transitorios.
class HermesSpeechStreamOpenException implements Exception {
  HermesSpeechStreamOpenException(Object cause)
    : cause = cause,
      endpointUnavailable = _isEndpointUnavailable(cause);

  final Object cause;
  final bool endpointUnavailable;

  static bool _isEndpointUnavailable(Object error) {
    final message = error.toString();
    final match = RegExp(
      r'(?:http\s+status(?:\s+code)?|status\s+code)\s*:?\s*(\d{3})',
      caseSensitive: false,
    ).firstMatch(message);
    final status = int.tryParse(match?.group(1) ?? '');
    return status == 404 || status == 405 || status == 426;
  }

  @override
  String toString() => 'HermesSpeechStreamOpenException: $cause';
}

abstract interface class HermesSpeechSocket {
  Future<void> get ready;
  Stream<dynamic> get frames;
  void send(String frame);
  Future<void> close();
}

class _WebSocketHermesSpeechSocket implements HermesSpeechSocket {
  _WebSocketHermesSpeechSocket(this.channel);

  final WebSocketChannel channel;

  @override
  Future<void> get ready => channel.ready;

  @override
  Stream<dynamic> get frames => channel.stream;

  @override
  void send(String frame) => channel.sink.add(frame);

  @override
  Future<void> close() => channel.sink.close(1000, 'client_dispose');
}

typedef HermesSpeechSocketConnector =
    HermesSpeechSocket Function(Uri uri, Map<String, dynamic> headers);

/// Cliente autenticado del endpoint que usa Hermes Desktop en `main`.
///
/// La última release estable puede no publicar el endpoint. En ese caso
/// [open] falla antes del primer PCM y el controlador conserva el POST
/// `/api/audio/speak` como fallback.
class HermesSpeechStreamClient {
  HermesSpeechStreamClient({
    required this.dashboardBaseUrl,
    required this.auth,
    required this.sinkFactory,
    this.profile,
    this.ttsConfigurationSignature,
    HermesSpeechSocketConnector? connector,
    this.connectTimeout = const Duration(seconds: 12),
    this.finishTimeout = const Duration(minutes: 3),
  }) : _connector =
           connector ??
           ((uri, headers) => _WebSocketHermesSpeechSocket(
             IOWebSocketChannel.connect(
               uri,
               headers: headers,
               pingInterval: const Duration(seconds: 20),
               connectTimeout: connectTimeout,
             ),
           ));

  final String dashboardBaseUrl;
  final Future<DashboardWebSocketAuth> Function() auth;
  final String? profile;
  final String? ttsConfigurationSignature;
  final HermesPcmStreamSinkFactory sinkFactory;
  final Duration connectTimeout;
  final Duration finishTimeout;
  final HermesSpeechSocketConnector _connector;

  Uri buildUri(DashboardWebSocketAuth credentials) {
    final base = Uri.parse(dashboardBaseUrl);
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final normalizedProfile = profile?.trim() ?? '';
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '$basePath/api/audio/speak-stream',
      queryParameters: {
        ...base.queryParameters,
        credentials.queryName: credentials.credential,
        if (normalizedProfile.isNotEmpty && normalizedProfile != 'default')
          'profile': normalizedProfile,
      },
    );
  }

  Future<HermesSpeechStreamSession> open() async {
    final credentials = await auth();
    final uri = buildUri(credentials);
    final socket = _connector(uri, credentials.headers);
    final session = HermesSpeechStreamSession(
      socket: socket,
      sink: sinkFactory(),
      finishTimeout: finishTimeout,
      latencyTurn: VoiceLatencyTrace.current.currentTurn,
      onPcmAccepted: () => HermesSpeechStreamEvidence.notePcmObserved(
        dashboardBaseUrl,
        profile: profile,
        ttsConfigurationSignature: ttsConfigurationSignature,
      ),
    );
    try {
      await session.open().timeout(connectTimeout);
      return session;
    } catch (error, stackTrace) {
      await session.cancel();
      Error.throwWithStackTrace(
        HermesSpeechStreamOpenException(error),
        stackTrace,
      );
    }
  }
}

typedef HermesSpeechStreamSessionFactory =
    Future<HermesSpeechStreamSession> Function();
typedef HermesSpeechPlaybackFence = Future<void> Function();

/// Una conexión, un AudioTrack y una generación por respuesta del agente.
class HermesSpeechStreamSession {
  factory HermesSpeechStreamSession({
    required HermesSpeechSocket socket,
    required HermesPcmStreamSink sink,
    Duration finishTimeout = const Duration(minutes: 3),
    void Function()? onPcmAccepted,
    VoiceLatencyTurn? latencyTurn,
  }) => HermesSpeechStreamSession._(
    socket,
    sink,
    finishTimeout,
    onPcmAccepted,
    latencyTurn,
  );

  HermesSpeechStreamSession._(
    this._socket,
    this._sink,
    this.finishTimeout,
    this._onPcmAccepted,
    this._latencyTurn,
  );

  static const int maxTextDeltaChars = 16 * 1024;
  static const int maxPcmFrameBytes = 1024 * 1024;
  static const int maxTotalPcmBytes = 128 * 1024 * 1024;
  static const int playbackWriteChunkBytes = 4 * 1024;

  final HermesSpeechSocket _socket;
  final HermesPcmStreamSink _sink;
  final Duration finishTimeout;
  final void Function()? _onPcmAccepted;
  final VoiceLatencyTurn? _latencyTurn;

  final Completer<HermesSpeechStreamOutcome> _outcome =
      Completer<HermesSpeechStreamOutcome>();
  final Completer<bool> _firstPcmReceived = Completer<bool>();
  final Completer<bool> _firstPcmPossiblyWritten = Completer<bool>();
  final Completer<bool> _firstPcmAccepted = Completer<bool>();

  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _resumeGate;
  Future<void> _playbackControlTail = Future<void>.value();
  Timer? _finishTimer;
  HermesSpeechStreamState _state = HermesSpeechStreamState.connecting;
  HermesSpeechStreamFallbackKind? _fallbackKind;
  Uint8List? _oddCarry;
  int _totalPcmBytes = 0;
  bool _receivedPcm = false;
  bool _pcmConfirmed = false;
  bool _opened = false;
  bool _finishRequested = false;
  bool _finishSent = false;
  bool _pauseRequested = false;
  bool _sinkPaused = false;
  bool _stopping = false;
  HermesSpeechPlaybackFence? _playbackFence;

  HermesSpeechStreamState get state => _state;
  HermesSpeechStreamFallbackKind? get fallbackKind => _fallbackKind;
  bool get receivedPcm => _receivedPcm;
  bool get pcmConfirmed => _pcmConfirmed;
  bool get paused => _pauseRequested || _sinkPaused;

  /// Primer bloque PCM válido recibido del wire, antes de esperar al sink.
  /// Es TTFA de transporte; por sí solo nunca bloquea el fallback anti-replay.
  Future<bool> get firstPcmReceived => _firstPcmReceived.future;

  /// Primer bloque que pudo haber alcanzado el sink. Conserva la semántica
  /// anti-replay: ante un fallo no tipado puede ser `true` aunque Android no
  /// haya confirmado cuántos bytes aceptó.
  Future<bool> get firstPcmPossiblyWritten => _firstPcmPossiblyWritten.future;

  /// Alias compatible con consumidores anteriores. Las métricas nuevas deben
  /// elegir explícitamente received, possibly-written o accepted.
  Future<bool> get firstPcm => firstPcmPossiblyWritten;

  /// Primer write confirmado por telemetría nativa (o por retorno completo del
  /// sink). Nunca se resuelve como `true` por un fallo no tipado.
  Future<bool> get firstPcmAccepted => _firstPcmAccepted.future;
  Future<HermesSpeechStreamOutcome> get done => _outcome.future;

  bool setPlaybackFence(HermesSpeechPlaybackFence fence) {
    if (_receivedPcm ||
        _totalPcmBytes > 0 ||
        _outcome.isCompleted ||
        _stopping) {
      return false;
    }
    _playbackFence = fence;
    return true;
  }

  Future<void> _queuePlaybackControl(Future<void> Function() operation) {
    final previous = _playbackControlTail;
    final current = previous.then<void>((_) => operation());
    _playbackControlTail = current.then<void>((_) {}, onError: (_, _) {});
    return current;
  }

  Future<void> _waitUntilPlaybackResumed() async {
    // Resume puede haberse solicitado mientras el pause nativo aún espera al
    // write actual. El gate permanece hasta que AudioTrack ya volvió a `play`;
    // mirar solo `_pauseRequested` permitiría que el tail adelantase Resume.
    while ((_pauseRequested || _resumeGate != null) &&
        !_stopping &&
        !_outcome.isCompleted) {
      final gate = _resumeGate ??= Completer<void>();
      await gate.future;
    }
  }

  void _releaseResumeGate() {
    final gate = _resumeGate;
    _resumeGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void _armFinishTimer() {
    _finishTimer?.cancel();
    _finishTimer = null;
    if (!_finishSent || _pauseRequested || _outcome.isCompleted || _stopping) {
      return;
    }
    _finishTimer = Timer(finishTimeout, () {
      unawaited(_fail(HermesSpeechStreamFallbackKind.transport));
    });
  }

  /// Congela feed, frame PCM actual y AudioTrack sin cerrar esta respuesta.
  ///
  /// `asyncMap` mantiene como máximo su callback actual (cuyo frame está
  /// limitado por [maxPcmFrameBytes]); pausar la suscripción propaga
  /// backpressure al WebSocket/TCP y evita construir una cola PCM Dart.
  Future<void> pause() {
    if (_outcome.isCompleted || _stopping) return Future<void>.value();
    if (_pauseRequested) return _playbackControlTail;
    _pauseRequested = true;
    _resumeGate ??= Completer<void>();
    _subscription?.pause();
    _finishTimer?.cancel();
    _finishTimer = null;
    return _queuePlaybackControl(() async {
      if (_outcome.isCompleted || _stopping) return;
      if (_sinkPaused ||
          (_state != HermesSpeechStreamState.streaming &&
              _state != HermesSpeechStreamState.draining)) {
        return;
      }
      try {
        await _sink.pause();
        _sinkPaused = true;
      } catch (_) {
        await _fail(HermesSpeechStreamFallbackKind.protocol);
      }
    });
  }

  /// Reanuda primero el mismo AudioTrack y después libera red/PCM retenidos.
  Future<void> resume() {
    if (_outcome.isCompleted || _stopping) {
      _pauseRequested = false;
      _releaseResumeGate();
      return Future<void>.value();
    }
    if (!_pauseRequested && !_sinkPaused) return _playbackControlTail;
    _pauseRequested = false;
    return _queuePlaybackControl(() async {
      if (_outcome.isCompleted || _stopping) {
        _releaseResumeGate();
        return;
      }
      // Una segunda Pause llegada mientras este Resume esperaba gana sin
      // producir un destello audible ni liberar el frame retenido.
      if (_pauseRequested) return;
      if (_sinkPaused) {
        try {
          await _sink.resume();
          _sinkPaused = false;
        } catch (_) {
          await _fail(HermesSpeechStreamFallbackKind.protocol);
          return;
        }
      }
      if (_pauseRequested || _outcome.isCompleted || _stopping) return;
      _releaseResumeGate();
      _subscription?.resume();
      _armFinishTimer();
    });
  }

  Future<void> open() async {
    if (_opened) return;
    _opened = true;
    await _socket.ready;
    if (_stopping) return;
    _state = HermesSpeechStreamState.awaitingStart;
    _subscription = _socket.frames
        .asyncMap<void>(_handleFrame)
        .listen(
          null,
          onError: (Object _, StackTrace _) {
            unawaited(_fail(HermesSpeechStreamFallbackKind.transport));
          },
          onDone: () {
            if (!_outcome.isCompleted && !_stopping) {
              unawaited(_fail(HermesSpeechStreamFallbackKind.transport));
            }
          },
          cancelOnError: false,
        );
  }

  Future<bool> append(String text) async {
    if (text.isEmpty || _finishRequested || _outcome.isCompleted || _stopping) {
      return false;
    }
    if (text.length > maxTextDeltaChars) {
      throw ArgumentError.value(
        text.length,
        'text.length',
        'Speech deltas are bounded to $maxTextDeltaChars characters',
      );
    }
    await _waitUntilPlaybackResumed();
    if (_finishRequested || _outcome.isCompleted || _stopping) return false;
    try {
      _socket.send(jsonEncode({'text': text}));
      return true;
    } catch (_) {
      await _fail(HermesSpeechStreamFallbackKind.transport);
      return false;
    }
  }

  Future<HermesSpeechStreamOutcome> finish() {
    if (_outcome.isCompleted) return done;
    if (!_finishRequested && !_stopping) {
      _finishRequested = true;
      if (_pauseRequested) {
        unawaited(_sendFinishWhenResumed());
      } else {
        _sendFinishFrame();
      }
    }
    return done;
  }

  Future<void> _sendFinishWhenResumed() async {
    await _waitUntilPlaybackResumed();
    _sendFinishFrame();
  }

  void _sendFinishFrame() {
    if (_finishSent || _outcome.isCompleted || _stopping) return;
    _finishSent = true;
    _state = _state == HermesSpeechStreamState.streaming
        ? HermesSpeechStreamState.draining
        : _state;
    try {
      _socket.send(jsonEncode({'done': true}));
    } catch (_) {
      unawaited(_fail(HermesSpeechStreamFallbackKind.transport));
      return;
    }
    _armFinishTimer();
  }

  Future<void> _handleFrame(dynamic frame) async {
    if (_outcome.isCompleted || _stopping) return;
    if (frame is String) {
      await _handleControl(frame);
      return;
    }
    final bytes = switch (frame) {
      Uint8List value => value,
      List<int> value => Uint8List.fromList(value),
      _ => null,
    };
    if (bytes == null) {
      await _fail(HermesSpeechStreamFallbackKind.protocol);
      return;
    }
    await _handlePcm(bytes);
  }

  Future<void> _handleControl(String raw) async {
    Map<String, dynamic> frame;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException();
      frame = Map<String, dynamic>.from(decoded);
    } catch (_) {
      await _fail(HermesSpeechStreamFallbackKind.protocol);
      return;
    }
    switch (frame['type']) {
      case 'start':
        if (_state != HermesSpeechStreamState.awaitingStart) {
          await _fail(HermesSpeechStreamFallbackKind.protocol);
          return;
        }
        final sampleRate = frame['sample_rate'];
        final channels = frame['channels'];
        if (sampleRate is! num || channels is! num) {
          await _fail(HermesSpeechStreamFallbackKind.protocol);
          return;
        }
        final format = HermesPcmFormat(
          sampleRate: sampleRate.toInt(),
          channels: channels.toInt(),
        );
        if (!format.isSupported) {
          await _fail(HermesSpeechStreamFallbackKind.protocol);
          return;
        }
        try {
          await _sink.configure(format);
        } catch (_) {
          await _fail(HermesSpeechStreamFallbackKind.protocol);
          return;
        }
        if (!_stopping && !_outcome.isCompleted) {
          _state = HermesSpeechStreamState.streaming;
        }
      case 'end':
        await _waitUntilPlaybackResumed();
        if (_outcome.isCompleted || _stopping) return;
        if (_state != HermesSpeechStreamState.streaming &&
            _state != HermesSpeechStreamState.draining) {
          await _fail(HermesSpeechStreamFallbackKind.protocol);
          return;
        }
        if (_oddCarry != null) {
          await _fail(HermesSpeechStreamFallbackKind.protocol);
          return;
        }
        try {
          await _sink.finish();
        } catch (_) {
          await _fail(HermesSpeechStreamFallbackKind.protocol);
          return;
        }
        _state = HermesSpeechStreamState.ended;
        await _settle(
          _receivedPcm
              ? HermesSpeechStreamOutcome.played
              : HermesSpeechStreamOutcome.fallback,
        );
      case 'fallback':
        _fallbackKind = HermesSpeechStreamFallbackKind.providerUnsupported;
        _state = HermesSpeechStreamState.fallback;
        try {
          await _sink.stop();
        } catch (_) {}
        await _settle(
          _receivedPcm
              ? HermesSpeechStreamOutcome.partial
              : HermesSpeechStreamOutcome.fallback,
        );
      default:
        await _fail(HermesSpeechStreamFallbackKind.protocol);
    }
  }

  Future<void> _handlePcm(Uint8List incoming) async {
    if (_state != HermesSpeechStreamState.streaming &&
        _state != HermesSpeechStreamState.draining) {
      await _fail(HermesSpeechStreamFallbackKind.protocol);
      return;
    }
    if (incoming.isEmpty || incoming.length > maxPcmFrameBytes) {
      await _fail(HermesSpeechStreamFallbackKind.protocol);
      return;
    }
    var bytes = incoming;
    final carry = _oddCarry;
    if (carry != null) {
      final joined = Uint8List(carry.length + bytes.length)
        ..setAll(0, carry)
        ..setAll(carry.length, bytes);
      bytes = joined;
      _oddCarry = null;
    }
    final usableLength = bytes.length - (bytes.length % 2);
    if (usableLength != bytes.length) {
      _oddCarry = Uint8List.fromList(bytes.sublist(usableLength));
    }
    if (usableLength == 0) return;
    _totalPcmBytes += usableLength;
    if (_totalPcmBytes > maxTotalPcmBytes) {
      await _fail(HermesSpeechStreamFallbackKind.protocol);
      return;
    }
    final payload = Uint8List.fromList(bytes.sublist(0, usableLength));
    final pcmAcceptLatency = _latencyTurn?.beginPcmAcceptLatency();
    _markPcmReceivedFromWire();
    final playbackFence = _playbackFence;
    _playbackFence = null;
    if (playbackFence != null) {
      try {
        await playbackFence();
      } catch (_) {
        // Barge-in es opcional: su valla nunca inutiliza el TTS principal.
      }
    }
    var offset = 0;
    while (offset < payload.length) {
      await _waitUntilPlaybackResumed();
      if (_stopping || _outcome.isCompleted) return;
      final remaining = payload.length - offset;
      final length = remaining > playbackWriteChunkBytes
          ? playbackWriteChunkBytes
          : remaining;
      final end = offset + length;
      final block = Uint8List.sublistView(payload, offset, end);
      try {
        await _sink.write(block);
        if (_stopping || _outcome.isCompleted) return;
        pcmAcceptLatency?.accept();
        _markPcmPossiblyWritten(confirmed: true);
      } on HermesPcmWriteException catch (error) {
        // El canal nativo distingue un rechazo previo al primer byte de un
        // write parcialmente aceptado. Solo el primero permite repetir por
        // POST; tras cualquier bloque previo el resultado siempre es parcial.
        if (error.acceptedAny) {
          pcmAcceptLatency?.accept();
          _markPcmPossiblyWritten(confirmed: true);
        }
        await _fail(HermesSpeechStreamFallbackKind.protocol);
        return;
      } catch (_) {
        // Un sink ajeno sin telemetría puede haber escrito parte del bloque
        // antes de fallar. Se conserva la política anti-duplicado sin convertir
        // esa incertidumbre en evidencia de PCM comprobado.
        _markPcmPossiblyWritten(confirmed: false);
        await _fail(HermesSpeechStreamFallbackKind.protocol);
        return;
      }
      offset = end;
    }
  }

  void _markPcmReceivedFromWire() {
    if (!_firstPcmReceived.isCompleted) {
      _latencyTurn?.mark(VoiceLatencyPoint.pcmFirstReceived);
      _firstPcmReceived.complete(true);
    }
  }

  void _markPcmPossiblyWritten({required bool confirmed}) {
    _receivedPcm = true;
    if (!_firstPcmPossiblyWritten.isCompleted) {
      _firstPcmPossiblyWritten.complete(true);
    }
    if (confirmed && !_pcmConfirmed) {
      _pcmConfirmed = true;
      if (!_firstPcmAccepted.isCompleted) {
        _latencyTurn?.mark(VoiceLatencyPoint.pcmFirstAccepted);
        // AudioTrack currently exposes no stable callback at the first
        // playback-head advance. Keep audible explicitly unavailable rather
        // than relabelling enqueue/write acceptance as sound heard.
        _latencyTurn?.mark(VoiceLatencyPoint.pcmAudibleUnavailable);
        _firstPcmAccepted.complete(true);
      }
      try {
        _onPcmAccepted?.call();
      } catch (_) {
        // La telemetría local de capacidad nunca interrumpe el audio.
      }
    }
  }

  Future<void> _fail(HermesSpeechStreamFallbackKind kind) async {
    if (_outcome.isCompleted || _stopping) return;
    _fallbackKind ??= kind;
    _state = _receivedPcm
        ? HermesSpeechStreamState.failedAfterAudio
        : HermesSpeechStreamState.failedBeforeAudio;
    try {
      await _sink.stop();
    } catch (_) {
      // La generación queda invalidada incluso si Android ya había liberado.
    }
    await _settle(
      _receivedPcm
          ? HermesSpeechStreamOutcome.partial
          : HermesSpeechStreamOutcome.fallback,
    );
  }

  Future<void> cancel() async {
    if (_outcome.isCompleted || _stopping) return;
    _stopping = true;
    _pauseRequested = false;
    _releaseResumeGate();
    _state = HermesSpeechStreamState.cancelled;
    try {
      _socket.send(jsonEncode({'stop': true}));
    } catch (_) {
      // El cierre del socket sigue siendo la cancelación autoritativa.
    }
    try {
      await _sink.stop();
    } catch (_) {}
    await _settle(HermesSpeechStreamOutcome.cancelled);
  }

  Future<void> _settle(HermesSpeechStreamOutcome outcome) async {
    if (_outcome.isCompleted) return;
    _pauseRequested = false;
    _sinkPaused = false;
    _releaseResumeGate();
    _finishTimer?.cancel();
    _finishTimer = null;
    if (!_firstPcmReceived.isCompleted) _firstPcmReceived.complete(false);
    if (!_firstPcmPossiblyWritten.isCompleted) {
      _firstPcmPossiblyWritten.complete(false);
    }
    if (!_firstPcmAccepted.isCompleted) _firstPcmAccepted.complete(false);
    _outcome.complete(outcome);
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((_) {}));
    }
    try {
      await _socket.close();
    } catch (_) {}
  }
}
