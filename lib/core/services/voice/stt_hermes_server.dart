// STT nativo Desktop (spec 048/US5): captura y endpointing 100 % LOCALES —
// exactamente el contrato de Hermes Desktop— y solo el clip WAV del turno
// viaja al PROPIO servidor Hermes (`POST /api/audio/transcribe`, auditado en
// contracts/native-voice.md). Reutiliza entero el motor de clip endurecido
// (WhisperSttEngine: VAD por amplitud, carreras de arranque/parada, epochs)
// sustituyendo únicamente el paso de transcripción por la llamada al servidor.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'stt_engine.dart';

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

/// POST autenticado a `/api/audio/transcribe` del Dashboard de la conexión.
/// Respuesta esperada: `{"ok": true, "transcript": "…", "provider": "…"}`.
typedef HermesTranscribeRequest =
    Future<Map<String, dynamic>> Function(String dataUrl, String mimeType);

/// Runtime de [WhisperSttEngine] cuyo paso de transcripción es el servidor
/// Hermes. La grabación es la misma que la local (WAV 16 kHz mono) y ningún
/// audio sale del dispositivo hasta que el turno cierra y hay consentimiento.
class HermesServerSttRuntime implements WhisperSttRuntime {
  HermesServerSttRuntime({
    required this.transcribeRequest,
    AudioRecorder? recorder,
  }) : _injectedRecorder = recorder;

  final HermesTranscribeRequest transcribeRequest;
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

  @override
  Future<void> start(String path) =>
      _recorder.start(kHermesServerSttRecordConfig, path: path);

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      _recorder.onAmplitudeChanged(interval);

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<String> transcribe({
    required WhisperModel model,
    required String audioPath,
    required String lang,
    required int threads,
  }) async {
    final file = File(audioPath);
    if (!file.existsSync()) return '';
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return '';
    final response = await transcribeRequest(
      'data:audio/wav;base64,${base64Encode(bytes)}',
      'audio/wav',
    );
    if (response['ok'] != true) {
      final detail = response['detail'] ?? response['error'] ?? 'sin detalle';
      throw Exception('The server could not transcribe: $detail');
    }
    return (response['transcript'] ?? '').toString().trim();
  }

  @override
  Future<void> dispose() async {
    final recorder = _injectedRecorder ?? _lazyRecorder;
    if (recorder == null) return;
    try {
      await recorder.dispose();
    } catch (_) {
      // Liberación best-effort: sin plugin (tests/host) no hay nada que soltar.
    }
  }
}

/// Motor STT del modo nativo: el clip-engine local con el runtime de servidor.
WhisperSttEngine buildHermesServerSttEngine({
  required HermesTranscribeRequest transcribeRequest,
  required String lang,
  void Function(double level)? onLevel,
  AudioRecorder? recorder,
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
  onLevel: onLevel,
  lang: lang,
  runtime: HermesServerSttRuntime(
    transcribeRequest: transcribeRequest,
    recorder: recorder,
  ),
);
