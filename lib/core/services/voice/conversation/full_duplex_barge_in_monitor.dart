import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../voice_service.dart';

typedef FullDuplexPlaybackSafetyProbe =
    Future<FullDuplexPlaybackSafety> Function();
typedef FullDuplexSpeechStart = void Function();
typedef FullDuplexSpeechAboveThreshold = void Function();
typedef FullDuplexSpeechEndpoint = void Function();
typedef FullDuplexTranscriptionStart = void Function();
typedef FullDuplexTranscript = Future<void> Function(String? transcript);

final class FullDuplexPlaybackSafety {
  const FullDuplexPlaybackSafety({
    required this.aecEnabled,
    required this.privateOutput,
    required this.playbackSafe,
    this.noiseSuppressionEnabled = false,
  });

  /// Diagnostic state only; Android does not report real echo attenuation.
  final bool aecEnabled;
  final bool privateOutput;
  final bool playbackSafe;
  final bool noiseSuppressionEnabled;
}

abstract interface class FullDuplexCaptureSource {
  bool get transcriptionAvailable;
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start();
  Future<void> setPlaybackActive(bool active);
  Future<FullDuplexPlaybackSafety> playbackSafety();
  Future<void> stop();
  Future<String> transcribe(Uint8List wavBytes);
  Future<void> dispose();
}

final class _FullDuplexCaptureCancelled implements Exception {
  const _FullDuplexCaptureCancelled();
}

final class _NativeFullDuplexCapture {
  _NativeFullDuplexCapture({required this.operation, required this.generation});

  final int operation;
  final int generation;
  final Completer<void> ready = Completer<void>();
  final StreamController<Object?> events = StreamController<Object?>();
  StreamSubscription<Object?>? nativeSubscription;
  bool readyConfirmed = false;
  bool eventsClosed = false;
}

final class VoiceServiceFullDuplexCaptureSource
    implements FullDuplexCaptureSource {
  factory VoiceServiceFullDuplexCaptureSource(
    VoiceService voice, {
    MethodChannel method = const MethodChannel('hermes/full_duplex_capture'),
    EventChannel events = const EventChannel(
      'hermes/full_duplex_capture_events',
    ),
    Duration readyTimeout = const Duration(seconds: 3),
  }) => VoiceServiceFullDuplexCaptureSource._(
    voice,
    method,
    events,
    readyTimeout,
  );

  VoiceServiceFullDuplexCaptureSource._(
    this.voice,
    this._method,
    this._events,
    this._readyTimeout,
  );

  final VoiceService voice;
  final MethodChannel _method;
  final EventChannel _events;
  final Duration _readyTimeout;
  int _epoch = 0;
  int? _pendingStartOperation;
  _NativeFullDuplexCapture? _capture;
  bool _disposed = false;

  @override
  bool get transcriptionAvailable => voice.fullDuplexTranscriptionAvailable;

  @override
  Future<bool> hasPermission() async =>
      await _method.invokeMethod<bool>('hasPermission') == true;

  @override
  Future<Stream<Uint8List>> start() async {
    if (_disposed) {
      throw StateError('La captura full-duplex ya fue cerrada.');
    }
    if (_pendingStartOperation != null || _capture != null) await stop();

    final operation = ++_epoch;
    _pendingStartOperation = operation;
    Map<String, Object?>? result;
    try {
      result = await _method
          .invokeMapMethod<String, Object?>('start')
          .timeout(_readyTimeout);
    } on TimeoutException {
      final stillCurrent =
          !_disposed &&
          operation == _epoch &&
          _pendingStartOperation == operation;
      if (stillCurrent) {
        _pendingStartOperation = null;
        await _stopNative(null);
      }
      rethrow;
    } catch (_) {
      if (_pendingStartOperation == operation) {
        _pendingStartOperation = null;
      }
      rethrow;
    }
    final generation = (result?['generation'] as num?)?.toInt();
    if (generation == null || generation <= 0) {
      if (_pendingStartOperation == operation) {
        _pendingStartOperation = null;
      }
      throw StateError('Android did not start full-duplex capture.');
    }
    if (_disposed || operation != _epoch) {
      await _stopNative(generation);
      throw const _FullDuplexCaptureCancelled();
    }

    final capture = _NativeFullDuplexCapture(
      operation: operation,
      generation: generation,
    );
    _pendingStartOperation = null;
    _capture = capture;
    capture.nativeSubscription = _events
        .receiveBroadcastStream(<String, Object?>{'generation': generation})
        .listen(
          (event) => _onNativeEvent(capture, event),
          onError: (Object error, StackTrace stackTrace) {
            _onNativeError(capture, error, stackTrace);
          },
          onDone: () => _onNativeDone(capture),
          cancelOnError: false,
        );

    try {
      await capture.ready.future.timeout(_readyTimeout);
      if (!_owns(capture) || !capture.readyConfirmed) {
        throw const _FullDuplexCaptureCancelled();
      }
      return _nativePcm(capture);
    } catch (_) {
      await _teardownCapture(capture, stopNative: true);
      rethrow;
    }
  }

  void _onNativeEvent(_NativeFullDuplexCapture owner, Object? event) {
    if (!_owns(owner) || event is! Map) return;
    final generation = (event['generation'] as num?)?.toInt();
    if (generation != owner.generation) return;
    if (event['type'] == 'ready') {
      owner.readyConfirmed = true;
      if (!owner.ready.isCompleted) owner.ready.complete();
      return;
    }
    if (event['type'] != 'pcm') return;
    if (!owner.readyConfirmed) {
      if (!owner.ready.isCompleted) {
        owner.ready.completeError(
          StateError('Android delivered PCM before confirming capture.'),
        );
      }
      return;
    }
    if (!owner.eventsClosed) owner.events.add(event);
  }

  void _onNativeError(
    _NativeFullDuplexCapture owner,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!_owns(owner)) return;
    if (!owner.readyConfirmed) {
      if (!owner.ready.isCompleted) {
        owner.ready.completeError(error, stackTrace);
      }
      return;
    }
    if (!owner.eventsClosed) owner.events.addError(error, stackTrace);
  }

  void _onNativeDone(_NativeFullDuplexCapture owner) {
    if (!_owns(owner)) return;
    if (!owner.readyConfirmed && !owner.ready.isCompleted) {
      owner.ready.completeError(
        StateError('Android closed the capture before confirming it.'),
      );
    }
    _closeEvents(owner);
  }

  Stream<Uint8List> _nativePcm(_NativeFullDuplexCapture owner) async* {
    await for (final event in owner.events.stream) {
      if (event is! Map) continue;
      final eventGeneration = (event['generation'] as num?)?.toInt();
      if (eventGeneration != owner.generation || event['type'] != 'pcm') {
        continue;
      }
      final sequence = (event['sequence'] as num?)?.toInt();
      final pcm = event['pcm'];
      if (sequence == null || pcm is! Uint8List || pcm.isEmpty) continue;
      try {
        yield pcm;
      } finally {
        try {
          await _method.invokeMethod<void>('ack', <String, Object?>{
            'generation': owner.generation,
            'sequence': sequence,
          });
        } catch (_) {
          // A cancelled generation is already invalidated natively.
        }
      }
    }
  }

  @override
  Future<void> setPlaybackActive(bool active) async {
    await _method.invokeMethod<void>('setPlaybackActive', <String, Object?>{
      'active': active,
    });
  }

  @override
  Future<FullDuplexPlaybackSafety> playbackSafety() async {
    final result = await _method.invokeMapMethod<String, Object?>(
      'getPlaybackSafety',
    );
    final privateOutput = result?['privateOutput'] == true;
    return FullDuplexPlaybackSafety(
      aecEnabled: result?['aecEnabled'] == true,
      privateOutput: privateOutput,
      // Defense in depth: Android AEC is diagnostic, never proof that speaker
      // echo is attenuated. Even a stale native verdict must fail closed unless
      // the exact TTS AudioTrack reports a private routed device.
      playbackSafe: privateOutput && result?['playbackSafe'] == true,
      noiseSuppressionEnabled: result?['noiseSuppressionEnabled'] == true,
    );
  }

  @override
  Future<void> stop() async {
    final hadPendingStart = _pendingStartOperation != null;
    _pendingStartOperation = null;
    ++_epoch;
    final capture = _capture;
    _capture = null;
    if (capture != null) {
      if (!capture.ready.isCompleted) {
        capture.ready.completeError(const _FullDuplexCaptureCancelled());
      }
      await _teardownCapture(capture, stopNative: true);
    } else if (hadPendingStart) {
      await _stopNative(null);
    }
  }

  @override
  Future<String> transcribe(Uint8List wavBytes) =>
      voice.transcribeFullDuplexWav(wavBytes);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    try {
      await _method.invokeMethod<void>('dispose');
    } catch (_) {
      // Activity teardown is the final native ownership boundary.
    }
  }

  bool _owns(_NativeFullDuplexCapture owner) =>
      !_disposed && identical(_capture, owner) && owner.operation == _epoch;

  Future<void> _teardownCapture(
    _NativeFullDuplexCapture owner, {
    required bool stopNative,
  }) async {
    if (identical(_capture, owner)) _capture = null;
    final subscription = owner.nativeSubscription;
    owner.nativeSubscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      // The native generation is invalidated explicitly below.
    }
    _closeEvents(owner);
    if (stopNative) await _stopNative(owner.generation);
  }

  void _closeEvents(_NativeFullDuplexCapture owner) {
    if (owner.eventsClosed) return;
    owner.eventsClosed = true;
    unawaited(owner.events.close());
  }

  Future<void> _stopNative(int? generation) async {
    try {
      await _method.invokeMethod<void>('stop', <String, Object?>{
        'generation': ?generation,
      });
    } catch (_) {
      // Native generations make a late stop harmless.
    }
  }
}

/// PCM full-duplex detector aligned with Hermes' generation/playback monitor.
///
/// A quiet-room calibration is followed by Desktop's 300 ms / 80% majority
/// gate. One capture stays live for the complete agent turn: generation and
/// playback. Up to 5 s of pre-roll plus the rest of the utterance is retained
/// until ~1.25 s of silence and then sent to the explicitly selected STT.
///
/// Desktop's WebAudio levels are converted to PCM16 RMS with the same
/// normalization. The only Android-specific boundary is playback safety:
/// speaker barge-in requires a live AEC bound to the recorder session or a
/// private output route. Because Android's AEC enabled bit does not prove real
/// attenuation, residual speaker echo is filtered by the transcript/TTS
/// similarity guard (upstream 0.20.3 `is_tts_echo` parity) fed with
/// [noteSpokenText]. Generation-phase barge-in stays independent of the route.
final class FullDuplexBargeInMonitor {
  FullDuplexBargeInMonitor({
    required this.source,
    FullDuplexPlaybackSafetyProbe? playbackSafetyProbe,
  }) : _playbackSafetyProbe = playbackSafetyProbe ?? source.playbackSafety;

  static const int sampleRate = 16000;
  static const int _frameSamples = 480; // 30 ms
  static const int _frameBytes = _frameSamples * 2;
  static const int _calibrationFrames = 14; // 420 ms, Desktop >=400 ms
  static const int _majorityWindow = 10; // 300 ms
  static const int _majorityRequired = 8;
  static const int _preRollFrames = 167; // ~5 s, Hermes Desktop parity
  static const int _endpointFrames = 42; // 1.26 s, Hermes Desktop parity
  static const int _maxCaptureFrames = 1000; // 30 s after onset
  static const int _graceFrames = 17; // ~500 ms
  static const int _playbackGapFrames = 34; // > 1 s
  static const int _ambientFrames = 100; // ~3 s
  // WebAudio computes level = byte-domain RMS / 42. A centered byte sample is
  // PCM16 / 256, hence one Desktop level unit equals 42 * 256 PCM16 RMS.
  static const double _webAudioLevelToPcm16Rms = 10752;
  static const double _minimumTriggerRms =
      0.075 * _webAudioLevelToPcm16Rms; // 806.4
  static const double _minimumPlaybackRms =
      0.14 * _webAudioLevelToPcm16Rms; // 1505.28
  static const double _triggerCeilingRms =
      0.37 * _webAudioLevelToPcm16Rms; // 3978.24
  static const double _thresholdMultiplier = 3.5;

  // Guard anti-eco TTS→STT (paridad upstream 0.20.3 `is_tts_echo`): un
  // transcript de barge-in con similitud >= 0.6 (SequenceMatcher + ventana
  // deslizante) contra el TTS recién hablado es auto-captura del altavoz.
  static const int _echoMinTranscriptChars = 10;
  static const double _echoSimilarityThreshold = 0.6;
  static const int _spokenTailMaxChars = 4096;

  final FullDuplexCaptureSource source;
  final FullDuplexPlaybackSafetyProbe _playbackSafetyProbe;

  StreamSubscription<Uint8List>? _subscription;
  Future<void> _operationTail = Future<void>.value();
  FullDuplexSpeechStart? _onSpeechStart;
  FullDuplexSpeechAboveThreshold? _onSpeechAboveThreshold;
  FullDuplexSpeechEndpoint? _onSpeechEndpoint;
  FullDuplexTranscriptionStart? _onTranscriptionStart;
  FullDuplexTranscript? _onTranscript;
  final List<Uint8List> _preRoll = <Uint8List>[];
  final List<bool> _onsetWindow = <bool>[];
  final List<double> _ambient = <double>[];
  BytesBuilder? _captured;
  Uint8List _carry = Uint8List(0);
  int _epoch = 0;
  int _calibrationCount = 0;
  int _silentFrames = 0;
  int _captureFrames = 0;
  double _noiseFloor = 0;
  int _graceRemaining = 0;
  int _blocksSincePlayback = 10000;
  bool _wantArmed = false;
  bool _armed = false;
  bool _speechStarted = false;
  bool _finishing = false;
  bool _playbackActive = false;
  bool _playbackSeen = false;
  bool _floorLocked = false;
  bool _playbackSafe = false;
  bool _playbackUnsafeLatched = false;
  bool _disposed = false;
  int _levelLogFrames = 0;
  double _levelPeakRms = 0;
  String _spokenTail = '';

  bool get active => _wantArmed || _armed;
  bool get armed => _armed;
  bool get playbackActive => _playbackActive;
  bool get playbackSafe => _playbackSafe;
  bool get playbackUnsafeLatched => _playbackUnsafeLatched;

  /// Opens a new assistant-response ownership boundary.
  ///
  /// Fragment gaps call [setPlaybackActive] with `false`, so they must not
  /// clear an unsafe speaker verdict on their own; the controller marks each
  /// genuinely new turn here. Every new turn re-probes the route anyway
  /// ([setPlaybackActive] and [_arm] both probe), so the latch is only a
  /// per-response suppression of repeated failing probes, never a sticky
  /// session verdict. The echo reference also resets: barge-in transcripts of
  /// this turn can only be echo of THIS response's narration.
  void beginResponseTurn() {
    if (_disposed || _playbackActive) return;
    _playbackUnsafeLatched = false;
    _spokenTail = '';
  }

  /// Feeds the anti-echo guard with TTS text committed to playback.
  ///
  /// Kept as a bounded normalized tail; upstream 0.20.3 compares each barge-in
  /// transcript against the recently spoken TTS with a sliding window.
  void noteSpokenText(String text) {
    if (_disposed) return;
    final normalized = _normalizeEchoText(text);
    if (normalized.isEmpty) return;
    _spokenTail = _spokenTail.isEmpty ? normalized : '$_spokenTail $normalized';
    if (_spokenTail.length > _spokenTailMaxChars) {
      _spokenTail = _spokenTail.substring(
        _spokenTail.length - _spokenTailMaxChars,
      );
    }
  }

  Future<bool> arm({
    required FullDuplexSpeechStart onSpeechStart,
    FullDuplexSpeechAboveThreshold? onSpeechAboveThreshold,
    FullDuplexSpeechEndpoint? onSpeechEndpoint,
    FullDuplexTranscriptionStart? onTranscriptionStart,
    required FullDuplexTranscript onTranscript,
  }) {
    if (_disposed || !source.transcriptionAvailable) {
      debugPrint(
        '[VOICE-PERF] voice.barge.arm skipped '
        'disposed=$_disposed transcription=${source.transcriptionAvailable}',
      );
      return Future<bool>.value(false);
    }
    _onSpeechStart = onSpeechStart;
    _onSpeechAboveThreshold = onSpeechAboveThreshold;
    _onSpeechEndpoint = onSpeechEndpoint;
    _onTranscriptionStart = onTranscriptionStart;
    _onTranscript = onTranscript;
    if (_wantArmed || _armed) return Future<bool>.value(true);

    _wantArmed = true;
    final operation = ++_epoch;
    return _serialize(() => _arm(operation));
  }

  Future<bool> setPlaybackActive(bool active) async {
    if (_disposed) return false;
    final wasActive = _playbackActive;
    _playbackActive = active;
    if (!active && wasActive) {
      _blocksSincePlayback = 0;
      // El latch no es pegajoso: al parar la reproducción se suelta y el
      // próximo intento vuelve a sondear la ruta. Mientras la narración sigue
      // en vuelo, el controller evita el churn de re-sondeos por fragmento.
      _playbackUnsafeLatched = false;
    }
    if (!_wantArmed && !_armed) {
      // An unsafe route disarms the capture while playback remains active. The
      // terminal false still has to reach native code; otherwise its latch
      // stays true and rejects the next generation before playback begins.
      if (!active && wasActive) {
        try {
          await source.setPlaybackActive(false);
        } catch (_) {
          return false;
        }
      }
      return true;
    }

    if (active) {
      // Probe before toggling the native playback latch. On an unsafe speaker
      // route Kotlin would otherwise terminate EventChannel first and surface
      // a PlatformException for a transition that Dart already knows must fail
      // closed.
      final safety = await _safePlaybackProbe();
      _playbackSafe = safety.playbackSafe;
      debugPrint(
        '[VOICE-PERF] voice.barge.playback active=$active '
        'aec=${safety.aecEnabled} ns=${safety.noiseSuppressionEnabled} '
        'private=${safety.privateOutput} '
        'safe=$_playbackSafe',
      );
      if (!_playbackSafe) {
        _playbackUnsafeLatched = true;
        debugPrint(
          '[voice-stab] barge.unsafe_playback_route '
          'aec=${safety.aecEnabled} ns=${safety.noiseSuppressionEnabled} '
          'private=${safety.privateOutput} action=disarm_until_playback_stop',
        );
        await disarm();
        return false;
      }
    }

    try {
      await source.setPlaybackActive(active);
    } catch (_) {
      if (active) {
        _playbackUnsafeLatched = true;
        await disarm();
        return false;
      }
    }
    if (!active) return true;

    _playbackUnsafeLatched = false;
    if (!_floorLocked) _lockFloor();
    if (!wasActive &&
        (!_playbackSeen || _blocksSincePlayback >= _playbackGapFrames)) {
      _graceRemaining = _graceFrames;
      _clearOnsetWindows();
    }
    _playbackSeen = true;
    return true;
  }

  Future<void> disarm() {
    _wantArmed = false;
    _armed = false;
    final operation = ++_epoch;
    final cancellation = source.stop();
    return _serialize(() async {
      try {
        await cancellation;
      } catch (_) {
        // Epoch invalidation already prevents a stale ready ACK from arming.
      }
      await _stop(operation);
    });
  }

  Future<bool> _arm(int operation) async {
    if (!_isCurrent(operation) || !source.transcriptionAvailable) {
      _wantArmed = false;
      return false;
    }
    // Sin latch pegajoso: cada intento vuelve a sondear la ruta tras abrir la
    // captura. El latch solo documenta el último veredicto para el controller.
    try {
      await _stopCapture();
      if (!_isCurrent(operation) || !await source.hasPermission()) {
        debugPrint('[VOICE-PERF] voice.barge.arm denied_or_stale');
        _wantArmed = false;
        return false;
      }

      _resetDetector();
      final audio = await source.start();
      if (!_isCurrent(operation)) {
        await source.stop();
        return false;
      }
      final safety = await _safePlaybackProbe();
      if (!_isCurrent(operation)) {
        await source.stop();
        return false;
      }
      _playbackSafe = safety.playbackSafe;
      if (_playbackActive && !_playbackSafe) {
        _playbackUnsafeLatched = true;
        _wantArmed = false;
        debugPrint(
          '[voice-stab] barge.unsafe_playback_route '
          'aec=${safety.aecEnabled} ns=${safety.noiseSuppressionEnabled} '
          'private=${safety.privateOutput} action=arm_aborted',
        );
        await source.stop();
        return false;
      }
      if (_playbackActive) {
        await source.setPlaybackActive(true);
        _lockFloor();
        _graceRemaining = _graceFrames;
        _playbackSeen = true;
      }
      _subscription = audio.listen(
        (chunk) => _onAudio(operation, chunk),
        onError: (Object error, StackTrace stackTrace) {
          if (_playbackActive) _playbackUnsafeLatched = true;
          debugPrint(
            '[VOICE-PERF] voice.barge.capture_error '
            'error=${error.runtimeType}',
          );
          unawaited(disarm());
        },
        onDone: () {
          if (_isCurrent(operation) && !_finishing) {
            if (_playbackActive) _playbackUnsafeLatched = true;
            debugPrint('[VOICE-PERF] voice.barge.capture_done_unexpected');
            unawaited(disarm());
          }
        },
        cancelOnError: false,
      );
      _armed = true;
      debugPrint(
        '[VOICE-PERF] voice.barge.armed playback=$_playbackActive '
        'aec=${safety.aecEnabled} ns=${safety.noiseSuppressionEnabled} '
        'private=${safety.privateOutput} '
        'policy=desktop_parity_v2 calibration_ms=420 '
        'sustained_ms=300 majority=0.8 pre_roll_ms=5010 '
        'endpoint_ms=1260 trigger_rms=806 playback_rms=1505',
      );
      return true;
    } catch (error) {
      if (_playbackActive) _playbackUnsafeLatched = true;
      debugPrint(
        '[VOICE-PERF] voice.barge.arm_failed error=${error.runtimeType}',
      );
      _wantArmed = false;
      _armed = false;
      await source.stop();
      return false;
    }
  }

  Future<FullDuplexPlaybackSafety> _safePlaybackProbe() async {
    try {
      return await _playbackSafetyProbe();
    } catch (_) {
      return const FullDuplexPlaybackSafety(
        aecEnabled: false,
        privateOutput: false,
        playbackSafe: false,
      );
    }
  }

  void _onAudio(int operation, Uint8List bytes) {
    if (!_isCurrent(operation) || bytes.isEmpty || _finishing) return;
    final merged = _carry.isEmpty
        ? bytes
        : (Uint8List(_carry.length + bytes.length)
            ..setRange(0, _carry.length, _carry)
            ..setRange(_carry.length, _carry.length + bytes.length, bytes));
    var offset = 0;
    while (merged.length - offset >= _frameBytes) {
      final frame = Uint8List.fromList(
        Uint8List.sublistView(merged, offset, offset + _frameBytes),
      );
      _processFrame(operation, frame);
      offset += _frameBytes;
      if (!_isCurrent(operation) || _finishing) break;
    }
    _carry = offset >= merged.length
        ? Uint8List(0)
        : Uint8List.fromList(Uint8List.sublistView(merged, offset));
  }

  void _processFrame(int operation, Uint8List frame) {
    final rms = _pcm16Rms(frame);
    _pushPreRoll(frame);
    if (_playbackActive) {
      _blocksSincePlayback = 0;
    } else {
      _blocksSincePlayback++;
    }

    if (!_floorLocked) {
      if (_playbackActive) {
        _lockFloor();
      } else {
        _pushAmbient(rms);
        _calibrationCount++;
        if (_calibrationCount >= _calibrationFrames) _lockFloor();
      }
      return;
    }

    if (!_speechStarted) {
      var threshold = math.max(
        _minimumTriggerRms,
        _noiseFloor * _thresholdMultiplier,
      );
      if (_playbackActive) {
        threshold = math.min(
          math.max(threshold, _minimumPlaybackRms),
          _triggerCeilingRms,
        );
      }

      var above = rms >= threshold;
      if (_graceRemaining > 0) {
        above = false;
        _graceRemaining--;
      }
      final majorityVotes = _onsetWindow.where((value) => value).length;
      _levelLogFrames++;
      _levelPeakRms = math.max(_levelPeakRms, rms);
      if (_levelLogFrames >= _playbackGapFrames) {
        debugPrint(
          '[VOICE-PERF] voice.barge.level '
          'rms=${rms.toStringAsFixed(0)} '
          'peak=${_levelPeakRms.toStringAsFixed(0)} '
          'floor=${_noiseFloor.toStringAsFixed(0)} '
          'threshold=${threshold.toStringAsFixed(0)} '
          'playback=$_playbackActive grace=$_graceRemaining '
          'votes=$majorityVotes',
        );
        _levelLogFrames = 0;
        _levelPeakRms = 0;
      }
      _onsetWindow.add(above);
      if (_onsetWindow.length > _majorityWindow) _onsetWindow.removeAt(0);
      if (!_playbackActive && rms < threshold) {
        _pushAmbient(rms);
        _noiseFloor = _ambientMedian();
      }
      final majorityOnset =
          _onsetWindow.length == _majorityWindow &&
          above &&
          _onsetWindow.where((value) => value).length >= _majorityRequired;
      if (majorityOnset) {
        debugPrint(
          '[VOICE-PERF] voice.barge.speech_start '
          'rms=${rms.toStringAsFixed(0)} '
          'floor=${_noiseFloor.toStringAsFixed(0)} '
          'threshold=${threshold.toStringAsFixed(0)} '
          'playback=$_playbackActive gate=desktop_majority',
        );
        _speechStarted = true;
        _captured = BytesBuilder(copy: false);
        for (final buffered in _preRoll) {
          _captured!.add(buffered);
        }
        _captureFrames = 0;
        _silentFrames = 0;
        _onSpeechStart?.call();
        _onSpeechAboveThreshold?.call();
      }
      return;
    }

    _captured?.add(frame);
    _captureFrames++;
    if (rms < _minimumTriggerRms) {
      _silentFrames++;
    } else {
      _silentFrames = 0;
      _onSpeechAboveThreshold?.call();
    }
    if (_silentFrames >= _endpointFrames ||
        _captureFrames >= _maxCaptureFrames) {
      debugPrint(
        '[VOICE-PERF] voice.barge.endpoint frames=$_captureFrames '
        'silence_frames=$_silentFrames',
      );
      _onSpeechEndpoint?.call();
      _finishing = true;
      unawaited(_finishInterjection(operation));
    }
  }

  Future<void> _finishInterjection(int operation) async {
    _wantArmed = false;
    _armed = false;
    final pcm = _captured?.takeBytes() ?? Uint8List(0);
    await _stopCapture();
    if (_disposed || operation != _epoch) return;

    String? transcript;
    if (pcm.isNotEmpty) {
      try {
        _onTranscriptionStart?.call();
        final text = await source
            .transcribe(_pcm16Wav(pcm))
            .timeout(const Duration(seconds: 90));
        transcript = text.trim().isEmpty ? null : text.trim();
      } catch (_) {
        transcript = null;
      }
    }
    if (transcript != null && isTtsEcho(transcript, _spokenTail)) {
      // Auto-captura del altavoz: sin AEC efectivo el TTS cruza el VAD y el
      // STT lo devuelve casi literal. Descartarlo rompe el bucle TTS→STT→TTS.
      debugPrint(
        '[voice-stab] barge.echo_guard drop '
        'transcript_chars=${transcript.length} '
        'spoken_tail_chars=${_spokenTail.length}',
      );
      transcript = null;
    }
    debugPrint(
      '[VOICE-PERF] voice.barge.transcribed has_text=${transcript != null}',
    );
    if (_disposed || operation != _epoch) return;
    await _onTranscript?.call(transcript);
  }

  void _pushPreRoll(Uint8List frame) {
    _preRoll.add(frame);
    if (_preRoll.length > _preRollFrames) _preRoll.removeAt(0);
  }

  void _clearOnsetWindows() {
    _onsetWindow.clear();
  }

  void _pushAmbient(double rms) {
    _ambient.add(rms);
    if (_ambient.length > _ambientFrames) _ambient.removeAt(0);
  }

  double _ambientMedian() {
    if (_ambient.isEmpty) return 0;
    final sorted = List<double>.of(_ambient)..sort();
    return sorted[sorted.length >> 1];
  }

  void _lockFloor() {
    _noiseFloor = _ambientMedian();
    _floorLocked = true;
  }

  void _resetDetector() {
    _preRoll.clear();
    _clearOnsetWindows();
    _ambient.clear();
    _captured = null;
    _carry = Uint8List(0);
    _calibrationCount = 0;
    _noiseFloor = 0;
    _graceRemaining = 0;
    _blocksSincePlayback = 10000;
    _silentFrames = 0;
    _captureFrames = 0;
    _speechStarted = false;
    _finishing = false;
    _floorLocked = false;
    _playbackSeen = false;
    _levelLogFrames = 0;
    _levelPeakRms = 0;
  }

  Future<void> _stop(int operation) async {
    await _stopCapture();
    if (_disposed || operation != _epoch) return;
    _resetDetector();
    _playbackSafe = false;
  }

  Future<void> _stopCapture() async {
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      // Recorder ownership is released below even if cancellation failed.
    }
    await source.stop();
  }

  bool _isCurrent(int operation) =>
      !_disposed && _wantArmed && operation == _epoch;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _operationTail;
    _operationTail = () async {
      try {
        await previous;
      } catch (_) {
        // Each operation reports through its own returned future.
      }
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _wantArmed = false;
    _armed = false;
    ++_epoch;
    final cancellation = source.stop();
    await _serialize(() async {
      try {
        await cancellation;
      } catch (_) {
        // Disposal still owns the final source teardown below.
      }
      await _stopCapture();
      await source.dispose();
    });
  }

  /// Guard anti-eco (paridad upstream 0.20.3 `is_tts_echo`): true cuando el
  /// transcript normalizado tiene al menos [_echoMinTranscriptChars] caracteres
  /// y alguna ventana deslizante de su mismo tamaño sobre el TTS recién
  /// hablado alcanza una similitud SequenceMatcher >= [_echoSimilarityThreshold].
  /// La cola se acota a lo pronunciado más recientemente: el eco físico solo
  /// puede pertenecer a lo que aún suena o acaba de terminar.
  @visibleForTesting
  static bool isTtsEcho(String transcript, String spokenTail) {
    final heard = _normalizeEchoText(transcript);
    if (heard.length < _echoMinTranscriptChars || spokenTail.isEmpty) {
      return false;
    }
    final tailLimit = heard.length * 3 + 32;
    final tail = spokenTail.length > tailLimit
        ? spokenTail.substring(spokenTail.length - tailLimit)
        : spokenTail;
    if (tail.length < heard.length) {
      return similarityRatio(heard, tail) >= _echoSimilarityThreshold;
    }
    for (var start = 0; start + heard.length <= tail.length; start++) {
      final window = tail.substring(start, start + heard.length);
      if (similarityRatio(heard, window) >= _echoSimilarityThreshold) {
        return true;
      }
    }
    return false;
  }

  /// `difflib.SequenceMatcher.ratio` sin autojunk: 2·M/T sobre los bloques
  /// coincidentes recursivos (Gestalt pattern matching).
  @visibleForTesting
  static double similarityRatio(String a, String b) {
    final total = a.length + b.length;
    if (total == 0) return 1;
    var matched = 0;
    for (final size in _matchingBlockSizes(a, b)) {
      matched += size;
    }
    return 2 * matched / total;
  }

  static String _normalizeEchoText(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[.,!?;:…"«»()\[\]¿¡]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static List<int> _matchingBlockSizes(String a, String b) {
    final b2j = <int, List<int>>{};
    for (var j = 0; j < b.length; j++) {
      b2j.putIfAbsent(b.codeUnitAt(j), () => <int>[]).add(j);
    }
    final sizes = <int>[];
    final queue = <(int, int, int, int)>[(0, a.length, 0, b.length)];
    while (queue.isNotEmpty) {
      final (alo, ahi, blo, bhi) = queue.removeLast();
      final (matchI, matchJ, matchSize) = _longestMatch(
        a,
        b2j,
        alo,
        ahi,
        blo,
        bhi,
      );
      if (matchSize <= 0) continue;
      sizes.add(matchSize);
      if (alo < matchI && blo < matchJ) {
        queue.add((alo, matchI, blo, matchJ));
      }
      if (matchI + matchSize < ahi && matchJ + matchSize < bhi) {
        queue.add((matchI + matchSize, ahi, matchJ + matchSize, bhi));
      }
    }
    return sizes;
  }

  static (int, int, int) _longestMatch(
    String a,
    Map<int, List<int>> b2j,
    int alo,
    int ahi,
    int blo,
    int bhi,
  ) {
    var bestI = alo;
    var bestJ = blo;
    var bestSize = 0;
    var j2len = <int, int>{};
    for (var i = alo; i < ahi; i++) {
      final newJ2len = <int, int>{};
      final bucket = b2j[a.codeUnitAt(i)];
      if (bucket != null) {
        for (final j in bucket) {
          if (j < blo) continue;
          if (j >= bhi) break;
          final length = (j2len[j - 1] ?? 0) + 1;
          newJ2len[j] = length;
          if (length > bestSize) {
            bestI = i - length + 1;
            bestJ = j - length + 1;
            bestSize = length;
          }
        }
      }
      j2len = newJ2len;
    }
    return (bestI, bestJ, bestSize);
  }

  static double _pcm16Rms(Uint8List bytes) {
    if (bytes.length < 2) return 0;
    var sumSquares = 0.0;
    var samples = 0;
    final data = ByteData.sublistView(bytes);
    for (var offset = 0; offset + 1 < bytes.length; offset += 2) {
      final sample = data.getInt16(offset, Endian.little).toDouble();
      sumSquares += sample * sample;
      samples++;
    }
    return samples == 0 ? 0 : math.sqrt(sumSquares / samples);
  }

  static Uint8List _pcm16Wav(Uint8List pcm) {
    const headerBytes = 44;
    final wav = Uint8List(headerBytes + pcm.length);
    final data = ByteData.sublistView(wav);

    void ascii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        wav[offset + i] = value.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, pcm.length, Endian.little);
    wav.setRange(headerBytes, wav.length, pcm);
    return wav;
  }
}
