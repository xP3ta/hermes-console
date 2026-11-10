// STT nativo Desktop (spec 048/US5): captura y endpointing 100 % LOCALES —
// exactamente el contrato de Hermes Desktop— y solo el clip WAV del turno
// viaja al PROPIO servidor Hermes (`POST /api/audio/transcribe`, auditado en
// contracts/native-voice.md). Reutiliza entero el motor de clip endurecido
// (WhisperSttEngine: VAD por amplitud, carreras de arranque/parada, epochs)
// sustituyendo únicamente el paso de transcripción por la llamada al servidor.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'hermes_dictation_stream.dart';
import 'hermes_stt_lease.dart';
import 'stt_engine.dart';
import 'voice_microphone.dart';

/// Captura principal del Modo Voz en Android.
///
/// Desktop solicita `echoCancellation` y `noiseSuppression` al abrir el micro.
/// El barge-in nativo de Android ya usa `VOICE_RECOGNITION`; mantener el turno
/// normal en la fuente genérica `MIC` dejaba precisamente la frase que se envía
/// a `/api/audio/transcribe` sin el mismo acondicionamiento acústico.
@visibleForTesting
const kHermesServerSttRecordConfig = RecordConfig(
  encoder: AudioEncoder.wav,
  sampleRate: 16000,
  numChannels: 1,
  echoCancel: true,
  noiseSuppress: true,
  androidConfig: AndroidRecordConfig(
    audioSource: AndroidAudioSource.voiceRecognition,
  ),
);

/// The same capture as [kHermesServerSttRecordConfig], as raw PCM: live
/// dictation needs the samples while the user speaks (Desktop taps the same
/// microphone, `use-mic-recorder.ts:242-262`). The recording is then written
/// as the same 16 kHz mono WAV, so the fallback upload does not change.
@visibleForTesting
const kHermesServerLiveSttRecordConfig = RecordConfig(
  encoder: AudioEncoder.pcm16bits,
  sampleRate: 16000,
  numChannels: 1,
  echoCancel: true,
  noiseSuppress: true,
  androidConfig: AndroidRecordConfig(
    audioSource: AndroidAudioSource.voiceRecognition,
  ),
);

/// Longest the HTTP call to `/api/audio/transcribe` may take. It is shorter
/// than the engine's own budget for the whole transcription (a take of
/// [kVoiceTurnMaxDuration] plus 45 s), so the call is the one that gives up and
/// aborts, instead of staying alive behind a turn that already failed.
const Duration kHermesServerTranscribeTimeout = Duration(seconds: 90);

/// POST autenticado a `/api/audio/transcribe` del Dashboard de la conexión.
/// Respuesta esperada: `{"ok": true, "transcript": "…", "provider": "…"}`.
typedef HermesTranscribeRequest =
    Future<Map<String, dynamic>> Function(String dataUrl, String mimeType);

/// Runtime de [WhisperSttEngine] cuyo paso de transcripción es el servidor
/// Hermes. La grabación es la misma que la local (WAV 16 kHz mono) y ningún
/// audio sale del dispositivo hasta que el turno cierra y hay consentimiento.
/// Exception: with live dictation on (`stt.streaming`), the composer
/// dictation also streams to that same server while the user speaks.
class HermesServerSttRuntime
    implements WhisperSttRuntime, LiveCaptureSttRuntime {
  HermesServerSttRuntime({
    required this.transcribeRequest,
    AudioRecorder? recorder,
    this.liveDictation,
    this.sttLease,
    this.warmupWait = const Duration(seconds: 10),
    this.microphone,
  }) : _injectedRecorder = recorder;

  final HermesTranscribeRequest transcribeRequest;

  /// The live dictation of the current binding, or null when the host does
  /// not serve it (`stt.streaming` off or no live wire). Read per capture.
  final HermesLiveDictationOpener? Function()? liveDictation;

  /// The STT warm-up lease of the current binding, read per capture.
  final HermesSttLease? Function()? sttLease;

  /// How long a transcription waits for the warm-up. Desktop waits for it
  /// with no bound, but nothing bounds its transcription either; here the
  /// engine's budget would run out behind a lease left hanging by a dropped
  /// network, and the turn would fail instead of transcribing.
  final Duration warmupWait;

  /// The microphone setting, read per capture (backlog 1.4.x item 7).
  final VoiceMicrophone Function()? microphone;

  /// The lease the last capture acquired: it is released by that same one
  /// (Desktop `stt-lease.ts:29-31`).
  HermesSttLease? _heldLease;
  Future<void> _warmup = Future<void>.value();
  bool _continuousCapture = false;
  // Perezoso: construir AudioRecorder ya toca el canal nativo, y transcribir
  // un clip existente (o testear) no necesita grabador.
  final AudioRecorder? _injectedRecorder;
  AudioRecorder? _lazyRecorder;
  AudioRecorder get _recorder =>
      _injectedRecorder ?? (_lazyRecorder ??= AudioRecorder());

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  /// No hay modelo local que descargar: el servidor pone la transcripción.
  @override
  Future<bool> modelReady(WhisperModel model) async => true;

  @override
  Future<String> createAudioPath() async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/native_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
  }

  _PreparedLiveCapture? _prepared;
  _LiveDictationTake? _take;

  @override
  void prepareCapture({
    required bool continuous,
    required void Function(String text) onPartial,
  }) {
    // Desktop streams the composer dictation only (use-voice-recorder.ts:
    // 214-215); the conversation loop keeps the recording.
    _prepared = null;
    _continuousCapture = continuous;
    final opener = continuous ? liveDictation?.call() : null;
    if (opener != null) _prepared = _PreparedLiveCapture(opener, onPartial);
  }

  @override
  Future<void> start(String path) async {
    // Desktop acquires when the mic opens, for dictation and for every
    // listening start of a conversation (use-voice-recorder.ts:189,
    // use-voice-conversation.ts:408).
    final lease = sttLease?.call();
    if (lease != null) {
      _heldLease = lease;
      _warmup = lease.sync(true);
    }
    final prepared = _prepared;
    _prepared = null;
    final choice = microphone?.call() ?? VoiceMicrophone.automatic;
    if (prepared == null) {
      return _recorder.start(
        await _configFor(kHermesServerSttRecordConfig, choice),
        path: path,
      );
    }
    _take?.discard();
    final take = _LiveDictationTake(
      path: path,
      opener: prepared.opener,
      onPartial: prepared.onPartial,
    );
    _take = take;
    final config = await _configFor(kHermesServerLiveSttRecordConfig, choice);
    final audio = await _recorder.startStream(config);
    take.listen(audio);
    // Desktop opens the socket once the PCM tap reports its rate
    // (use-voice-recorder.ts:179-183, 212-227).
    take.open(config.sampleRate);
  }

  Future<RecordConfig> _configFor(
    RecordConfig base,
    VoiceMicrophone choice,
  ) async {
    if (choice == VoiceMicrophone.automatic) return base;
    InputDevice? builtIn;
    try {
      builtIn = builtInMicrophoneOf(await _recorder.listInputDevices());
    } catch (_) {
      // Without the list, «phone» still keeps Bluetooth SCO off.
    }
    return recordConfigForMicrophone(base, choice, builtIn: builtIn);
  }

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      _recorder.onAmplitudeChanged(interval);

  @override
  Future<String?> stop() async {
    final take = _take;
    if (take == null || take.recorded) return _recorder.stop();
    take.recorded = true;
    await _recorder.stop();
    // `record` closes the stream on stop; the bound only keeps a plugin that
    // never does from holding the take.
    await take.drained.timeout(_drainTimeout, onTimeout: () {});
    await File(take.path).writeAsBytes(pcm16MonoWav(take.pcm), flush: true);
    return take.path;
  }

  static const Duration _drainTimeout = Duration(seconds: 2);

  @override
  void discardCapture(String? audioPath) {
    // A dictation releases its lease when its take is over
    // (use-voice-recorder.ts:166); a conversation keeps it until it ends.
    if (_continuousCapture) unawaited(_heldLease?.sync(false));
    _prepared = null;
    final take = _take;
    if (take == null || (audioPath != null && take.path != audioPath)) {
      return;
    }
    _take = null;
    take.discard();
  }

  @override
  Future<String> transcribe({
    required WhisperModel model,
    required String audioPath,
    required String lang,
    required int threads,
  }) async {
    // Readiness first: the warm-up settles before the clip is handed to
    // transcription (use-voice-recorder.ts:108-112). It never fails.
    await _warmup.timeout(warmupWait, onTimeout: () {});
    // Desktop `use-voice-recorder.ts:118-119`: the live final, else the
    // recording exactly as before.
    final take = _take;
    if (take != null && take.path == audioPath) {
      _take = null;
      final live = await take.finish();
      if (live != null) return live;
    }
    final file = File(audioPath);
    if (!file.existsSync()) return '';
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return '';
    final response = await transcribeRequest(
      'data:audio/wav;base64,${base64Encode(bytes)}',
      'audio/wav',
    );
    if (response['ok'] != true) {
      throw Exception('Server transcription failed.');
    }
    return (response['transcript'] ?? '').toString().trim();
  }

  @override
  Future<void> dispose() async {
    discardCapture(null);
    // The session is over: drop the lease to the binding that acquired it
    // (use-voice-conversation.ts:195, :989).
    final released = _heldLease?.sync(false);
    _heldLease = null;
    final recorder = _injectedRecorder ?? _lazyRecorder;
    if (recorder != null) {
      try {
        await recorder.dispose();
      } catch (_) {
        // Liberación best-effort: sin plugin (tests/host) no hay nada que
        // soltar.
      }
    }
    // The Dashboard client closes after this; let the release go first.
    await released?.timeout(_leaseReleaseWait, onTimeout: () {});
  }

  static const Duration _leaseReleaseWait = Duration(seconds: 5);
}

/// Motor STT del modo nativo: el clip-engine local con el runtime de servidor.
WhisperSttEngine buildHermesServerSttEngine({
  required HermesTranscribeRequest transcribeRequest,
  required String lang,
  void Function(double level)? onLevel,
  AudioRecorder? recorder,
  HermesLiveDictationOpener? Function()? liveDictation,
  Duration Function()? silenceTimeoutOf,
  HermesSttLease? Function()? sttLease,
  VoiceMicrophone Function()? microphone,
}) => WhisperSttEngine(
  // El modelo es un parámetro de la interfaz, no un requisito: modelReady
  // del runtime de servidor es true incondicional.
  model: WhisperModel.tiny,
  // `VOICE_RECOGNITION` del Pixel puede elevar ambiente sostenido hasta
  // ~-23 dBFS después de calibrar. La voz física medida alcanza -17..-7 dBFS:
  // este suelo evita churn del recorder sin perder el onset conversacional.
  speechOnsetDb: -18,
  // Un timeout en silencio no debe subir el WAV ambiental: algunos modelos
  // pueden alucinar texto válido y crear un turno fantasma.
  discardAutomaticTurnWithoutSpeechOnset: true,
  rejectSilentCapture: true,
  onLevel: onLevel,
  lang: lang,
  silenceTimeoutOf: silenceTimeoutOf,
  runtime: HermesServerSttRuntime(
    transcribeRequest: transcribeRequest,
    recorder: recorder,
    liveDictation: liveDictation,
    sttLease: sttLease,
    microphone: microphone,
  ),
);

class _PreparedLiveCapture {
  const _PreparedLiveCapture(this.opener, this.onPartial);

  final HermesLiveDictationOpener opener;
  final void Function(String text) onPartial;
}

/// One dictation take on the live socket, copied from Desktop's
/// `liveStream` (`use-voice-recorder.ts:203-238`): chunks captured before
/// the socket opens are buffered (bounded) and flushed, so the first words
/// reach the provider too. Every chunk also goes into the recording, which
/// stays the fallback.
class _LiveDictationTake {
  _LiveDictationTake({
    required this.path,
    required this.opener,
    required this.onPartial,
  });

  /// Desktop `use-voice-recorder.ts:232` (`buffered.length < 64`).
  static const int maxBufferedChunks = 64;

  final String path;
  final HermesLiveDictationOpener opener;
  final void Function(String text) onPartial;

  final BytesBuilder _recording = BytesBuilder();
  final List<Uint8List> _buffered = <Uint8List>[];
  final Completer<void> _drained = Completer<void>();
  StreamSubscription<Uint8List>? _audio;
  HermesDictationStreamSession? _session;
  Future<HermesDictationStreamSession?>? _opening;
  bool _settled = false;
  bool _discarded = false;

  /// Audio reached the recording but not the socket: the live text lacks
  /// part of the take.
  bool _overflowed = false;

  /// The recorder stopped and the WAV was written.
  bool recorded = false;

  Uint8List get pcm => _recording.toBytes();

  /// The recorder's stream ended: every chunk is in [pcm].
  Future<void> get drained => _drained.future;

  void listen(Stream<Uint8List> audio) {
    _audio = audio.listen(_push, onError: (Object _) {}, onDone: _markDrained);
  }

  void _markDrained() {
    if (!_drained.isCompleted) _drained.complete();
  }

  void _push(Uint8List chunk) {
    if (_discarded) return;
    _recording.add(chunk);
    final session = _session;
    if (session != null) {
      session.pushAudio(chunk);
    } else if (!_settled) {
      if (_buffered.length < maxBufferedChunks) {
        _buffered.add(chunk);
      } else {
        _overflowed = true;
      }
    }
  }

  void open(int sampleRate) {
    _opening = () async {
      HermesDictationStreamSession? opened;
      try {
        opened = await opener(
          sampleRate: sampleRate,
          onPartial: (text) {
            if (!_discarded) onPartial(text);
          },
        );
      } catch (_) {
        opened = null;
      }
      if (_discarded) {
        opened?.cancel();
        opened = null;
      }
      if (opened != null) {
        for (final chunk in _buffered) {
          opened.pushAudio(chunk);
        }
      }
      _buffered.clear();
      _settled = true;
      _session = opened;
      return opened;
    }();
  }

  /// Desktop `liveTranscript` (`use-voice-recorder.ts:143-157`): null to
  /// transcribe the recording instead (no session, a failure, or an empty
  /// final over a take the recorder kept).
  Future<String?> finish() async {
    final opening = _opening;
    final session = opening == null ? null : await opening;
    if (session == null || _discarded) return null;
    if (_overflowed) {
      // Desktop keeps the same 64-chunk window and speaks what it got; a
      // take that lost its middle is transcribed from the recording
      // instead (REVIEW-R5-B #13).
      session.cancel();
      return null;
    }
    try {
      final text = await session.stop();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    } finally {
      // Desktop `finish` (use-voice-recorder.ts:165): nothing stays open.
      session.cancel();
    }
  }

  void discard() {
    if (_discarded) return;
    _discarded = true;
    _buffered.clear();
    final audio = _audio;
    _audio = null;
    unawaited(audio?.cancel());
    _session?.cancel();
    _session = null;
    _markDrained();
  }
}

/// 16-bit PCM mono samples as a WAV file.
@visibleForTesting
Uint8List pcm16MonoWav(Uint8List pcm, {int sampleRate = 16000}) {
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
