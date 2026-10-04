// Ajustes de voz (persistidos en SharedPreferences). La clave de ElevenLabs NO
// vive aquí: va en el Keystore (SecureStorage app-level) — ver VoiceService.
import 'package:shared_preferences/shared_preferences.dart';

import 'stt_sherpa.dart' show SherpaModelKind;
import 'voice_lang.dart';

/// Motor de reconocimiento de voz (voz → texto).
enum SttEngineKind {
  /// Reconocedor del sistema Android (speech_to_text). Rápido; según el móvil
  /// puede usar Google (nube). No funciona en móviles sin Google (GrapheneOS).
  system('system'),

  /// Whisper on-device clásico (privado, sin nube). Graba y transcribe al
  /// terminar; sin parciales. Requiere descargar un modelo.
  whisper('whisper'),

  /// STT en vivo on-device con sherpa-onnx (privado, sin nube). VAD + modelo
  /// offline: transcribe frase a frase mientras hablas. Funciona en GrapheneOS.
  sherpaLive('sherpa_live'),

  /// STT oficial de la instancia Hermes activa. Captura WAV 16 kHz mono en el
  /// teléfono y envía únicamente el clip terminado a
  /// `POST /api/audio/transcribe`. Es una ruta distinta de [server], que sigue
  /// representando un faster-whisper personalizado por el usuario.
  hermesServer('hermes_server'),

  /// STT en vivo por SERVIDOR (faster-whisper en GPU, estilo Jarvis). El audio
  /// sale del teléfono hacia TU servidor (Tailscale/LAN): rápido pero no privado
  /// on-device. Requiere URL del servidor (el token va en el Keystore).
  server('server');

  const SttEngineKind(this.id);
  final String id;

  static SttEngineKind from(String? v) => values.firstWhere(
    (e) => e.id == v,
    orElse: () => SttEngineKind.sherpaLive,
  );
}

/// Tamaño del modelo Whisper on-device. tiny = más rápido (~75 MB, algo menos
/// preciso); base = equilibrio calidad/velocidad (~142 MB).
enum SttModelSize {
  tiny('tiny'),
  base('base');

  const SttModelSize(this.id);
  final String id;

  static SttModelSize from(String? v) =>
      values.firstWhere((e) => e.id == v, orElse: () => SttModelSize.base);
}

/// Motor de síntesis de voz (texto → voz).
enum TtsEngineKind {
  /// Voz del sistema (flutter_tts): on-device, privada, gratis.
  device('device'),

  /// Voz neuronal on-device (sherpa-onnx + modelo Piper): privada, sin nube,
  /// requiere descargar un modelo.
  onnx('onnx'),

  /// ElevenLabs: voz neuronal en la nube (con tu API key).
  elevenlabs('elevenlabs'),

  /// TTS por streaming con formato OpenAI (`/v1/audio/speech`). Sirve tanto para
  /// un servidor autoalojado (Kokoro-FastAPI en tu red, gratis y privado) como
  /// para la nube (OpenAI, Deepgram… con tu key). Un solo cliente, URL
  /// conmutable: empieza a sonar en cuanto llega el audio de la primera frase.
  streaming('streaming'),

  /// API TTS HTTP/REST configurable por el usuario. Envía JSON a una URL
  /// completa y acepta audio binario o audio base64 dentro de una respuesta
  /// JSON. El secreto de autenticación vive en Keystore.
  customHttp('custom_http');

  const TtsEngineKind(this.id);
  final String id;

  static TtsEngineKind from(String? v) =>
      values.firstWhere((e) => e.id == v, orElse: () => TtsEngineKind.onnx);
}

/// Qué significa tocar de nuevo el altavoz mientras una respuesta se está
/// leyendo. Es una preferencia explícita: el progreso de la lectura nunca se
/// persiste, solo esta elección de comportamiento.
enum ReadAloudStopBehavior {
  pauseAndResume('pause_and_resume'),
  stopAndRestart('stop_and_restart');

  const ReadAloudStopBehavior(this.id);
  final String id;

  static ReadAloudStopBehavior from(String? value) => values.firstWhere(
    (item) => item.id == value,
    orElse: () => ReadAloudStopBehavior.pauseAndResume,
  );
}

/// Presentación guiada del motor compatible con OpenAI. Los dos perfiles usan
/// el mismo contrato; Kokoro añade autocompletado y descubrimiento de voces.
enum StreamingTtsProfile {
  kokoro('kokoro'),
  openAiCompatible('openai_compatible');

  const StreamingTtsProfile(this.id);
  final String id;

  static StreamingTtsProfile from(String? value) => values.firstWhere(
    (item) => item.id == value,
    orElse: () => StreamingTtsProfile.kokoro,
  );
}

enum CustomTtsAuthMode {
  none('none'),
  bearer('bearer'),
  apiKey('api_key'),
  custom('custom');

  const CustomTtsAuthMode(this.id);
  final String id;

  static CustomTtsAuthMode from(String? value) => values.firstWhere(
    (item) => item.id == value,
    orElse: () => CustomTtsAuthMode.none,
  );
}

enum CustomTtsResponseKind {
  auto('auto'),
  binary('binary'),
  jsonBase64('json_base64');

  const CustomTtsResponseKind(this.id);
  final String id;

  static CustomTtsResponseKind from(String? value) => values.firstWhere(
    (item) => item.id == value,
    orElse: () => CustomTtsResponseKind.auto,
  );
}

class VoiceSettings {
  final SttEngineKind sttEngine;
  final TtsEngineKind ttsEngine;

  /// Leer automáticamente las respuestas del asistente al completarse.
  final bool autoSpeak;

  /// Permite interrumpir automáticamente la locución hablando por encima.
  /// Se mantiene opt-in: durante playback exige una salida privada confirmada;
  /// con altavoz falla cerrado y el corte táctil continúa disponible.
  final bool bargeInEnabled;

  /// Local opt-in to the GPT-Live conversation (experimental). It is the only
  /// gate of the feature: the server mode is informational and never starts a
  /// billed session on the phone. Off by default.
  final bool gptLiveEnabled;

  /// Pausar y continuar es el comportamiento por defecto. Quien prefiera una
  /// lectura nueva en cada toque puede elegir detener y reiniciar.
  final ReadAloudStopBehavior readAloudStopBehavior;

  /// VAD (Voice Activity Detection): en dictado/modo voz con Whisper, parar de
  /// grabar automáticamente al detectar silencio sostenido (en vez de exigir un
  /// toque). El reconocedor del sistema ya hace su propio endpointing, así que
  /// esto sólo afecta a Whisper on-device. Por defecto activado.
  final bool vadEnabled;

  /// ElevenLabs: voz y modelo. La API key va en el Keystore.
  final String elevenVoiceId;
  final String elevenModelId;

  /// Voz neuronal on-device elegida (id del catálogo en tts_model_manager).
  final String onnxVoiceId;

  /// Tamaño del modelo Whisper (dictado on-device).
  final SttModelSize whisperModel;

  /// Modelo elegido para el STT en vivo (sherpa-onnx): Whisper base/small o
  /// Parakeet v3. Solo aplica cuando [sttEngine] == sherpaLive.
  final SherpaModelKind sherpaModel;

  /// URL del servidor de STT en vivo (faster-whisper), p.ej.
  /// `ws://192.168.1.10:9123`. El token va en el Keystore, no aquí. Solo aplica
  /// cuando [sttEngine] == server.
  final String serverSttUrl;

  /// Perfil de ayuda para el contrato OpenAI. No cambia el protocolo de red.
  final StreamingTtsProfile streamingTtsProfile;

  /// Configuración independiente de Kokoro. Mantenerla separada evita que al
  /// visitar el formulario OpenAI se copie o sobrescriba una instalación local.
  final String kokoroTtsUrl;
  final String kokoroTtsVoice;
  final String kokoroTtsModel;

  /// Configuración independiente de cualquier API compatible con OpenAI.
  final String openAiTtsUrl;
  final String openAiTtsVoice;
  final String openAiTtsModel;

  /// Configuración activa consumida por el motor. Estos getters conservan la
  /// API histórica de [VoiceSettings] sin volver a mezclar ambos perfiles.
  String get streamingTtsUrl =>
      streamingTtsProfile == StreamingTtsProfile.kokoro
      ? kokoroTtsUrl
      : openAiTtsUrl;
  String get streamingTtsVoice =>
      streamingTtsProfile == StreamingTtsProfile.kokoro
      ? kokoroTtsVoice
      : openAiTtsVoice;
  String get streamingTtsModel =>
      streamingTtsProfile == StreamingTtsProfile.kokoro
      ? kokoroTtsModel
      : openAiTtsModel;

  /// Configuración no secreta de una API TTS HTTP/REST personalizada.
  final String customTtsUrl;
  final String customTtsVoice;
  final String customTtsModel;
  final String customTtsBodyTemplate;
  final CustomTtsAuthMode customTtsAuthMode;
  final String customTtsHeaderName;
  final String customTtsHeaderPrefix;
  final CustomTtsResponseKind customTtsResponseKind;
  final String customTtsBase64Path;
  final String customTtsMimeType;

  const VoiceSettings({
    // El dictado predeterminado es local y privado. Puede producir parciales
    // internos, pero el compositor solo aplica texto al parar o recibir final.
    this.sttEngine = SttEngineKind.sherpaLive,
    this.ttsEngine = TtsEngineKind.onnx,
    this.autoSpeak = false,
    this.bargeInEnabled = false,
    this.gptLiveEnabled = false,
    this.readAloudStopBehavior = ReadAloudStopBehavior.pauseAndResume,
    this.vadEnabled = true,
    this.elevenVoiceId = '21m00Tcm4TlvDq8ikWAM', // "Rachel" (default público)
    this.elevenModelId = 'eleven_multilingual_v2',
    this.onnxVoiceId = 'es_ES-davefx-medium',
    this.whisperModel = SttModelSize.base,
    this.sherpaModel = SherpaModelKind.whisperBase,
    this.serverSttUrl = '',
    String? streamingTtsUrl,
    String? streamingTtsVoice,
    String? streamingTtsModel,
    this.streamingTtsProfile = StreamingTtsProfile.kokoro,
    String? kokoroTtsUrl,
    String? kokoroTtsVoice,
    String? kokoroTtsModel,
    String? openAiTtsUrl,
    String? openAiTtsVoice,
    String? openAiTtsModel,
    this.customTtsUrl = '',
    this.customTtsVoice = '',
    this.customTtsModel = '',
    this.customTtsBodyTemplate =
        '{"text":"{{text}}","voice":"{{voice}}","model":"{{model}}"}',
    this.customTtsAuthMode = CustomTtsAuthMode.none,
    this.customTtsHeaderName = 'Authorization',
    this.customTtsHeaderPrefix = 'Bearer',
    this.customTtsResponseKind = CustomTtsResponseKind.auto,
    this.customTtsBase64Path = 'audio',
    this.customTtsMimeType = 'audio/mpeg',
  }) : kokoroTtsUrl =
           kokoroTtsUrl ??
           (streamingTtsProfile == StreamingTtsProfile.kokoro
               ? streamingTtsUrl ?? ''
               : ''),
       kokoroTtsVoice =
           kokoroTtsVoice ??
           (streamingTtsProfile == StreamingTtsProfile.kokoro
               ? streamingTtsVoice ?? 'em_santa'
               : 'em_santa'),
       kokoroTtsModel =
           kokoroTtsModel ??
           (streamingTtsProfile == StreamingTtsProfile.kokoro
               ? streamingTtsModel ?? 'kokoro'
               : 'kokoro'),
       openAiTtsUrl =
           openAiTtsUrl ??
           (streamingTtsProfile == StreamingTtsProfile.openAiCompatible
               ? streamingTtsUrl ?? ''
               : ''),
       openAiTtsVoice =
           openAiTtsVoice ??
           (streamingTtsProfile == StreamingTtsProfile.openAiCompatible
               ? streamingTtsVoice ?? 'alloy'
               : 'alloy'),
       openAiTtsModel =
           openAiTtsModel ??
           (streamingTtsProfile == StreamingTtsProfile.openAiCompatible
               ? streamingTtsModel ?? 'tts-1'
               : 'tts-1');

  VoiceSettings copyWith({
    SttEngineKind? sttEngine,
    TtsEngineKind? ttsEngine,
    bool? autoSpeak,
    bool? bargeInEnabled,
    bool? gptLiveEnabled,
    ReadAloudStopBehavior? readAloudStopBehavior,
    bool? vadEnabled,
    String? elevenVoiceId,
    String? elevenModelId,
    String? onnxVoiceId,
    SttModelSize? whisperModel,
    SherpaModelKind? sherpaModel,
    String? serverSttUrl,
    String? streamingTtsUrl,
    String? streamingTtsVoice,
    String? streamingTtsModel,
    StreamingTtsProfile? streamingTtsProfile,
    String? kokoroTtsUrl,
    String? kokoroTtsVoice,
    String? kokoroTtsModel,
    String? openAiTtsUrl,
    String? openAiTtsVoice,
    String? openAiTtsModel,
    String? customTtsUrl,
    String? customTtsVoice,
    String? customTtsModel,
    String? customTtsBodyTemplate,
    CustomTtsAuthMode? customTtsAuthMode,
    String? customTtsHeaderName,
    String? customTtsHeaderPrefix,
    CustomTtsResponseKind? customTtsResponseKind,
    String? customTtsBase64Path,
    String? customTtsMimeType,
  }) {
    final nextProfile = streamingTtsProfile ?? this.streamingTtsProfile;
    return VoiceSettings(
      sttEngine: sttEngine ?? this.sttEngine,
      ttsEngine: ttsEngine ?? this.ttsEngine,
      autoSpeak: autoSpeak ?? this.autoSpeak,
      bargeInEnabled: bargeInEnabled ?? this.bargeInEnabled,
      gptLiveEnabled: gptLiveEnabled ?? this.gptLiveEnabled,
      readAloudStopBehavior:
          readAloudStopBehavior ?? this.readAloudStopBehavior,
      vadEnabled: vadEnabled ?? this.vadEnabled,
      elevenVoiceId: elevenVoiceId ?? this.elevenVoiceId,
      elevenModelId: elevenModelId ?? this.elevenModelId,
      onnxVoiceId: onnxVoiceId ?? this.onnxVoiceId,
      whisperModel: whisperModel ?? this.whisperModel,
      sherpaModel: sherpaModel ?? this.sherpaModel,
      serverSttUrl: serverSttUrl ?? this.serverSttUrl,
      streamingTtsProfile: nextProfile,
      kokoroTtsUrl:
          kokoroTtsUrl ??
          (nextProfile == StreamingTtsProfile.kokoro && streamingTtsUrl != null
              ? streamingTtsUrl
              : this.kokoroTtsUrl),
      kokoroTtsVoice:
          kokoroTtsVoice ??
          (nextProfile == StreamingTtsProfile.kokoro &&
                  streamingTtsVoice != null
              ? streamingTtsVoice
              : this.kokoroTtsVoice),
      kokoroTtsModel:
          kokoroTtsModel ??
          (nextProfile == StreamingTtsProfile.kokoro &&
                  streamingTtsModel != null
              ? streamingTtsModel
              : this.kokoroTtsModel),
      openAiTtsUrl:
          openAiTtsUrl ??
          (nextProfile == StreamingTtsProfile.openAiCompatible &&
                  streamingTtsUrl != null
              ? streamingTtsUrl
              : this.openAiTtsUrl),
      openAiTtsVoice:
          openAiTtsVoice ??
          (nextProfile == StreamingTtsProfile.openAiCompatible &&
                  streamingTtsVoice != null
              ? streamingTtsVoice
              : this.openAiTtsVoice),
      openAiTtsModel:
          openAiTtsModel ??
          (nextProfile == StreamingTtsProfile.openAiCompatible &&
                  streamingTtsModel != null
              ? streamingTtsModel
              : this.openAiTtsModel),
      customTtsUrl: customTtsUrl ?? this.customTtsUrl,
      customTtsVoice: customTtsVoice ?? this.customTtsVoice,
      customTtsModel: customTtsModel ?? this.customTtsModel,
      customTtsBodyTemplate:
          customTtsBodyTemplate ?? this.customTtsBodyTemplate,
      customTtsAuthMode: customTtsAuthMode ?? this.customTtsAuthMode,
      customTtsHeaderName: customTtsHeaderName ?? this.customTtsHeaderName,
      customTtsHeaderPrefix:
          customTtsHeaderPrefix ?? this.customTtsHeaderPrefix,
      customTtsResponseKind:
          customTtsResponseKind ?? this.customTtsResponseKind,
      customTtsBase64Path: customTtsBase64Path ?? this.customTtsBase64Path,
      customTtsMimeType: customTtsMimeType ?? this.customTtsMimeType,
    );
  }

  static const _kStt = 'voice_stt_engine';
  static const _kTts = 'voice_tts_engine';
  static const _kAuto = 'voice_auto_speak';
  // La clave versionada evita resucitar el experimento retirado que usó
  // `voice_barge_in_enabled` en builds antiguas.
  static const _kBargeIn = 'voice_barge_in_enabled_v2';
  static const _kGptLive = 'voice_gpt_live_enabled_v1';
  static const _kReadAloudStopBehavior = 'voice_read_aloud_stop_behavior';
  static const _kVad = 'voice_vad_enabled';
  static const _kVoice = 'voice_eleven_voice_id';
  static const _kModel = 'voice_eleven_model_id';
  static const _kOnnxVoice = 'voice_onnx_voice_id';
  static const _kWhisperModel = 'voice_whisper_model';
  static const _kSherpaModel = 'voice_sherpa_model';
  static const _kServerUrl = 'voice_server_stt_url';
  static const _kStreamUrl = 'voice_streaming_tts_url';
  static const _kStreamVoice = 'voice_streaming_tts_voice';
  static const _kStreamModel = 'voice_streaming_tts_model';
  static const _kStreamProfile = 'voice_streaming_tts_profile';
  static const _kKokoroUrl = 'voice_streaming_tts_kokoro_url';
  static const _kKokoroVoice = 'voice_streaming_tts_kokoro_voice';
  static const _kKokoroModel = 'voice_streaming_tts_kokoro_model';
  static const _kOpenAiUrl = 'voice_streaming_tts_openai_url';
  static const _kOpenAiVoice = 'voice_streaming_tts_openai_voice';
  static const _kOpenAiModel = 'voice_streaming_tts_openai_model';
  static const _kCustomUrl = 'voice_custom_tts_url';
  static const _kCustomVoice = 'voice_custom_tts_voice';
  static const _kCustomModel = 'voice_custom_tts_model';
  static const _kCustomBody = 'voice_custom_tts_body_template';
  static const _kCustomAuth = 'voice_custom_tts_auth_mode';
  static const _kCustomHeader = 'voice_custom_tts_header_name';
  static const _kCustomPrefix = 'voice_custom_tts_header_prefix';
  static const _kCustomResponse = 'voice_custom_tts_response_kind';
  static const _kCustomBase64Path = 'voice_custom_tts_base64_path';
  static const _kCustomMime = 'voice_custom_tts_mime_type';

  /// Voz neuronal propuesta cuando el usuario nunca eligió (spec 031). En
  /// español es la histórica (regresión cero); en inglés, Amy (en el catálogo).
  static String defaultOnnxVoiceFor(String lang) =>
      lang == 'en' ? 'en_US-amy-medium' : 'es_ES-davefx-medium';

  /// Voz del TTS por streaming cuando el usuario nunca eligió (spec 031). En
  /// Kokoro `em_santa` es la voz española histórica; `af_heart` la insignia
  /// americana.
  static String defaultStreamingVoiceFor(String lang) =>
      lang == 'en' ? 'af_heart' : 'em_santa';

  static VoiceSettings load(SharedPreferences prefs) {
    const d = VoiceSettings();
    // Rollback de la integración TTS del servidor: las instalaciones QA que
    // llegaron a seleccionar `hermes_server` vuelven a la voz neuronal local.
    // Se conserva el modelo on-device ya descargado y no se toca el servidor.
    final storedTtsEngine = prefs.getString(_kTts);
    final migratedTtsEngine = storedTtsEngine == 'hermes_server'
        ? TtsEngineKind.onnx
        : TtsEngineKind.from(storedTtsEngine);
    if (storedTtsEngine == 'hermes_server') {
      prefs.setString(_kTts, TtsEngineKind.onnx.id);
    }
    // Spec 031: los defaults de voz dependientes de idioma solo aplican cuando
    // el usuario nunca eligió (clave AUSENTE); una clave presente se respeta
    // siempre, valga lo que valga (contrato I2 — nada de migraciones aquí).
    final lang = effectiveVoiceLang(prefs);
    final legacyStreamUrl = prefs.getString(_kStreamUrl);
    final legacyStreamVoice = prefs.getString(_kStreamVoice);
    final legacyStreamModel = prefs.getString(_kStreamModel);
    final storedStreamProfile = prefs.getString(_kStreamProfile);
    final streamProfile = storedStreamProfile == null
        ? _inferLegacyStreamingProfile(
            url: legacyStreamUrl,
            voice: legacyStreamVoice,
            model: legacyStreamModel,
          )
        : StreamingTtsProfile.from(storedStreamProfile);
    // Migración compatible: el antiguo trío compartido pertenece únicamente al
    // perfil que estaba seleccionado. El otro empieza con sus propios defaults,
    // evitando atribuir una URL/voz/modelo de Kokoro a OpenAI o al revés.
    final kokoroUrl =
        prefs.getString(_kKokoroUrl) ??
        (streamProfile == StreamingTtsProfile.kokoro
            ? legacyStreamUrl ?? ''
            : '');
    final kokoroVoice =
        prefs.getString(_kKokoroVoice) ??
        (streamProfile == StreamingTtsProfile.kokoro
            ? legacyStreamVoice ?? defaultStreamingVoiceFor(lang)
            : defaultStreamingVoiceFor(lang));
    final kokoroModel =
        prefs.getString(_kKokoroModel) ??
        (streamProfile == StreamingTtsProfile.kokoro
            ? legacyStreamModel ?? 'kokoro'
            : 'kokoro');
    final openAiUrl =
        prefs.getString(_kOpenAiUrl) ??
        (streamProfile == StreamingTtsProfile.openAiCompatible
            ? legacyStreamUrl ?? ''
            : '');
    final openAiVoice =
        prefs.getString(_kOpenAiVoice) ??
        (streamProfile == StreamingTtsProfile.openAiCompatible
            ? legacyStreamVoice ?? 'alloy'
            : 'alloy');
    final openAiModel =
        prefs.getString(_kOpenAiModel) ??
        (streamProfile == StreamingTtsProfile.openAiCompatible
            ? legacyStreamModel ?? 'tts-1'
            : 'tts-1');
    return VoiceSettings(
      sttEngine: SttEngineKind.from(prefs.getString(_kStt)),
      ttsEngine: migratedTtsEngine,
      autoSpeak: prefs.getBool(_kAuto) ?? false,
      bargeInEnabled: prefs.getBool(_kBargeIn) ?? false,
      gptLiveEnabled: prefs.getBool(_kGptLive) ?? false,
      readAloudStopBehavior: ReadAloudStopBehavior.from(
        prefs.getString(_kReadAloudStopBehavior),
      ),
      vadEnabled: prefs.getBool(_kVad) ?? true,
      elevenVoiceId: prefs.getString(_kVoice) ?? d.elevenVoiceId,
      elevenModelId: prefs.getString(_kModel) ?? d.elevenModelId,
      onnxVoiceId: prefs.getString(_kOnnxVoice) ?? defaultOnnxVoiceFor(lang),
      whisperModel: SttModelSize.from(prefs.getString(_kWhisperModel)),
      sherpaModel: SherpaModelKind.from(prefs.getString(_kSherpaModel)),
      serverSttUrl: prefs.getString(_kServerUrl) ?? '',
      streamingTtsProfile: streamProfile,
      kokoroTtsUrl: kokoroUrl,
      kokoroTtsVoice: kokoroVoice,
      kokoroTtsModel: kokoroModel,
      openAiTtsUrl: openAiUrl,
      openAiTtsVoice: openAiVoice,
      openAiTtsModel: openAiModel,
      customTtsUrl: prefs.getString(_kCustomUrl) ?? d.customTtsUrl,
      customTtsVoice: prefs.getString(_kCustomVoice) ?? d.customTtsVoice,
      customTtsModel: prefs.getString(_kCustomModel) ?? d.customTtsModel,
      customTtsBodyTemplate:
          prefs.getString(_kCustomBody) ?? d.customTtsBodyTemplate,
      customTtsAuthMode: CustomTtsAuthMode.from(prefs.getString(_kCustomAuth)),
      customTtsHeaderName:
          prefs.getString(_kCustomHeader) ?? d.customTtsHeaderName,
      customTtsHeaderPrefix:
          prefs.getString(_kCustomPrefix) ?? d.customTtsHeaderPrefix,
      customTtsResponseKind: CustomTtsResponseKind.from(
        prefs.getString(_kCustomResponse),
      ),
      customTtsBase64Path:
          prefs.getString(_kCustomBase64Path) ?? d.customTtsBase64Path,
      customTtsMimeType: prefs.getString(_kCustomMime) ?? d.customTtsMimeType,
    );
  }

  static StreamingTtsProfile _inferLegacyStreamingProfile({
    required String? url,
    required String? voice,
    required String? model,
  }) {
    if (url == null && voice == null && model == null) {
      return StreamingTtsProfile.kokoro;
    }
    final normalizedUrl = (url ?? '').toLowerCase();
    final normalizedVoice = (voice ?? '').toLowerCase();
    final normalizedModel = (model ?? '').toLowerCase();
    final kokoroVoice = RegExp(
      r'^(?:af|am|bf|bm|ef|em|ff|hf|hm|if|im|jf|jm|pf|pm|zf|zm)_',
    ).hasMatch(normalizedVoice);
    if (normalizedModel == 'kokoro' ||
        normalizedUrl.contains('kokoro') ||
        kokoroVoice) {
      return StreamingTtsProfile.kokoro;
    }
    return StreamingTtsProfile.openAiCompatible;
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(_kStt, sttEngine.id);
    await prefs.setString(_kTts, ttsEngine.id);
    await prefs.setBool(_kAuto, autoSpeak);
    await prefs.setBool(_kBargeIn, bargeInEnabled);
    await prefs.setBool(_kGptLive, gptLiveEnabled);
    await prefs.setString(_kReadAloudStopBehavior, readAloudStopBehavior.id);
    await prefs.setBool(_kVad, vadEnabled);
    await prefs.setString(_kVoice, elevenVoiceId);
    await prefs.setString(_kModel, elevenModelId);
    await prefs.setString(_kOnnxVoice, onnxVoiceId);
    await prefs.setString(_kWhisperModel, whisperModel.id);
    await prefs.setString(_kSherpaModel, sherpaModel.id);
    await prefs.setString(_kServerUrl, serverSttUrl);
    await prefs.setString(_kStreamUrl, streamingTtsUrl);
    await prefs.setString(_kStreamVoice, streamingTtsVoice);
    await prefs.setString(_kStreamModel, streamingTtsModel);
    await prefs.setString(_kStreamProfile, streamingTtsProfile.id);
    await prefs.setString(_kKokoroUrl, kokoroTtsUrl);
    await prefs.setString(_kKokoroVoice, kokoroTtsVoice);
    await prefs.setString(_kKokoroModel, kokoroTtsModel);
    await prefs.setString(_kOpenAiUrl, openAiTtsUrl);
    await prefs.setString(_kOpenAiVoice, openAiTtsVoice);
    await prefs.setString(_kOpenAiModel, openAiTtsModel);
    await prefs.setString(_kCustomUrl, customTtsUrl);
    await prefs.setString(_kCustomVoice, customTtsVoice);
    await prefs.setString(_kCustomModel, customTtsModel);
    await prefs.setString(_kCustomBody, customTtsBodyTemplate);
    await prefs.setString(_kCustomAuth, customTtsAuthMode.id);
    await prefs.setString(_kCustomHeader, customTtsHeaderName);
    await prefs.setString(_kCustomPrefix, customTtsHeaderPrefix);
    await prefs.setString(_kCustomResponse, customTtsResponseKind.id);
    await prefs.setString(_kCustomBase64Path, customTtsBase64Path);
    await prefs.setString(_kCustomMime, customTtsMimeType);
  }
}
