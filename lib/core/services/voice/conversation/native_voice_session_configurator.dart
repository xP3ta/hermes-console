import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../connection_manager.dart';
import '../client_direct_voice_routes.dart';
import '../hermes_dictation_stream.dart';
import '../hermes_pcm_stream.dart';
import '../hermes_speech_stream.dart';
import '../pcm_level_sink.dart';
import '../server_voice_config.dart';
import '../stt_hermes_server.dart';
import '../tts_engine.dart';
import '../voice_client_direct.dart';
import '../voice_service.dart';
import '../voice_settings.dart';
import 'native_voice.dart';

typedef NativeVoiceDashboardFactory =
    DashboardClient Function(SavedConnection connection);

enum HermesServerDictationConfigurationResult {
  configured,
  unavailable,
  superseded,
}

/// Positive transcription-probe verdicts per Dashboard identity, so a
/// dictation tap does not pay an extra round trip before the microphone
/// opens. Only a confirmed endpoint is remembered, for [maxAge]; a negative or
/// inconclusive answer is always probed again. Any change that withdraws the
/// choice (engine or consent) drops the entry at the next tap.
class HermesDictationProbeCache {
  HermesDictationProbeCache._();

  static const Duration maxAge = Duration(minutes: 10);
  static final Map<String, DateTime> _confirmedAt = {};
  static DateTime Function() _now = DateTime.now;

  static bool isConfirmed(String identity) {
    final at = _confirmedAt[identity];
    if (at == null) return false;
    if (_now().difference(at) < maxAge) return true;
    _confirmedAt.remove(identity);
    return false;
  }

  static void confirm(String identity) => _confirmedAt[identity] = _now();

  static void forget(String identity) => _confirmedAt.remove(identity);

  static void clear() => _confirmedAt.clear();

  @visibleForTesting
  static void resetForTesting({DateTime Function()? now}) {
    _confirmedAt.clear();
    _now = now ?? DateTime.now;
  }
}

/// Vincula el Dictado del chat al STT oficial de la instancia Hermes activa.
///
/// La selección vive en [VoiceSettings.sttEngine], no en
/// [NativeVoiceModeStore]. Solo reutiliza el consentimiento por identidad,
/// porque en ambos casos autoriza enviar audio a ese mismo servidor. El probe
/// toca exclusivamente `/api/audio/transcribe` y nunca activa TTS.
Future<HermesServerDictationConfigurationResult>
configureHermesServerDictation({
  required VoiceService voice,
  required Object owner,
  required HermesServerDictationPreparation preparation,
  required SavedConnection connection,
  required SharedPreferences preferences,
  required String profile,
  DashboardClient? dashboardClient,
  NativeVoiceDashboardFactory? dashboardFactory,
  VoiceClientDirect? clientDirect,
  VoiceClientConfigCache? clientDirectCache,
  HermesDictationSocketConnector? liveSocketConnector,
}) async {
  assert(dashboardClient == null || dashboardFactory == null);
  HermesServerDictationConfigurationResult unavailableOrSuperseded() {
    return voice.cancelHermesServerDictationPreparation(preparation)
        ? HermesServerDictationConfigurationResult.unavailable
        : HermesServerDictationConfigurationResult.superseded;
  }

  if (voice.settings.sttEngine != SttEngineKind.hermesServer) {
    HermesDictationProbeCache.clear();
    return unavailableOrSuperseded();
  }
  final createDashboard =
      dashboardFactory ?? (connection) => DashboardClient.lazy(connection);
  final dashboard = dashboardClient ?? createDashboard(connection);
  var transferredToVoice = false;
  try {
    final identity = nativeVoicePreferenceIdentity(
      dashboard.baseUrl,
      profile: profile,
    );
    if (NativeVoiceConsentStore(preferences).read(identity) !=
        NativeVoiceConsent.accepted) {
      HermesDictationProbeCache.forget(identity);
      return unavailableOrSuperseded();
    }
    final directAccepted =
        ClientDirectVoiceConsentStore(preferences).read(identity) ==
        ClientDirectVoiceConsent.accepted;
    final loadVoiceConfig = dashboardVoiceClientConfigLoader(
      dashboard,
      profile,
      cache: clientDirectCache,
    );
    // Resolved beside the probe; it never throws.
    final liveOffered = hermesLiveDictationOffered(
      identity: identity,
      clientDirectAccepted: directAccepted,
      loadVoiceConfig: loadVoiceConfig,
      loadServerConfig: () => dashboard.getServerConfig(profile: profile),
    );
    if (!HermesDictationProbeCache.isConfirmed(identity)) {
      final available = await probeHermesTranscription(
        statusOf: (endpoint) =>
            dashboard.probeAudioEndpoint(endpoint, profile: profile),
      );
      if (!available) {
        HermesDictationProbeCache.forget(identity);
        return unavailableOrSuperseded();
      }
      HermesDictationProbeCache.confirm(identity);
    }
    final live = await liveOffered;
    // Motor y consentimiento pueden cambiar mientras responde el probe. No
    // transfieras el cliente con una elección ya retirada.
    if (voice.settings.sttEngine != SttEngineKind.hermesServer ||
        NativeVoiceConsentStore(preferences).read(identity) !=
            NativeVoiceConsent.accepted) {
      return unavailableOrSuperseded();
    }
    HermesTranscribeRequest transcribe = (dataUrl, mimeType) =>
        dashboard.transcribeAudio(
          dataUrl,
          mimeType: mimeType,
          profile: profile,
          timeout: kHermesServerTranscribeTimeout,
        );
    // Dictation never asks: it uses direct voice only once the user accepted
    // its consent for this server.
    if (directAccepted) {
      transcribe = clientDirectTranscribe(
        relay: transcribe,
        loadConfig: loadVoiceConfig,
        direct: clientDirect,
      );
    }
    // Live dictation goes to this same server (keys stay there); the
    // recording above stays the fallback (Desktop use-voice-recorder.ts:119).
    final liveDictation = live
        ? HermesDictationStreamClient(
            dashboardBaseUrl: connection.effectiveDashboardUrl,
            auth: dashboard.webSocketAuth,
            profile: profile,
            connector: liveSocketConnector,
          ).open
        : null;
    transferredToVoice = voice.enableHermesServerDictation(
      owner: owner,
      preparation: preparation,
      transcribe: transcribe,
      liveDictation: liveDictation,
      sttLease: (lease, active) =>
          dashboard.setSttLease(lease, active: active, profile: profile),
      onDispose: dashboard.close,
    );
    return transferredToVoice
        ? HermesServerDictationConfigurationResult.configured
        : HermesServerDictationConfigurationResult.superseded;
  } finally {
    if (!transferredToVoice) {
      voice.cancelHermesServerDictationPreparation(preparation);
      dashboard.close();
    }
  }
}

/// Whether the host serves live dictation for this profile.
///
/// Desktop reads `stt.streaming` from `GET /api/audio/voice-config`
/// (`use-voice-recorder.ts:214-215`; the host fills it with
/// `streaming_available()`, `voice_client_config.py:248-254`). That answer
/// can carry the provider key, and Console only requests it once the user
/// accepted direct voice. Without that consent the same `stt.streaming` key
/// is read from `GET /api/config`; a provider without a live wire then
/// answers the socket with `error` (`audio.py:548-552`) and the recording
/// is transcribed, as in Desktop. The `/api/config` verdict is held 60 s
/// like Desktop's voice-config cache; a failed read means no live dictation.
@visibleForTesting
Future<bool> hermesLiveDictationOffered({
  required String identity,
  required bool clientDirectAccepted,
  required VoiceClientConfigLoader loadVoiceConfig,
  required Future<Map<String, dynamic>> Function() loadServerConfig,
}) async {
  try {
    if (clientDirectAccepted) {
      return (await loadVoiceConfig())?.sttStreaming ?? false;
    }
    final held = HermesLiveDictationGateCache.read(identity);
    if (held != null) return held;
    final offered = hermesLiveDictationEnabledInConfig(
      await loadServerConfig(),
    );
    HermesLiveDictationGateCache.store(identity, offered);
    return offered;
  } catch (_) {
    return false;
  }
}

/// Activa la voz que ofrece Hermes Agent únicamente cuando el usuario ya dio
/// consentimiento para esta identidad de Dashboard y la capacidad está
/// confirmada. No muestra UI: una detección en segundo plano nunca puede crear
/// un diálogo ni ampliar el consentimiento.
///
/// Una conversación conserva un único [DashboardClient] autenticado. Las
/// cookies del Dashboard rotan en ese cliente y no se repite el login por cada
/// STT/TTS; al terminar, reemplazar o cerrar la sesión, [VoiceService] lo cierra.
Future<bool> configureAcceptedNativeVoiceSession({
  required VoiceService voice,
  required SavedConnection connection,
  required SharedPreferences preferences,
  required String profile,
  Object? owner,
  NativeVoicePreparation? preparation,
  bool Function()? isStillCurrent,
  DashboardClient? dashboardClient,
  NativeVoiceDashboardFactory? dashboardFactory,
  HermesPcmStreamSinkFactory? sinkFactory,
  VoiceClientDirect? clientDirect,
  VoiceClientConfigCache? clientDirectCache,
}) async {
  assert(dashboardClient == null || dashboardFactory == null);
  assert(preparation == null || owner != null);
  final createDashboard =
      dashboardFactory ?? (connection) => DashboardClient.lazy(connection);
  final dashboard = dashboardClient ?? createDashboard(connection);
  final configurationOwner = owner ?? Object();
  final reservation =
      preparation ??
      voice.beginNativeVoicePreparation(owner: configurationOwner);
  if (reservation == null) {
    dashboard.close();
    return false;
  }
  var transferredToVoice = false;
  try {
    final identity = nativeVoicePreferenceIdentity(
      dashboard.baseUrl,
      profile: profile,
    );
    if (NativeVoiceModeStore(preferences).read(identity) !=
        NativeVoiceMode.server) {
      return false;
    }
    if (NativeVoiceConsentStore(preferences).read(identity) !=
        NativeVoiceConsent.accepted) {
      return false;
    }

    final capabilityStore = NativeVoiceCapabilityStore(preferences);
    var capability = capabilityStore.read(identity);
    if (capability == null || !capabilityStore.isFresh(capability)) {
      capability = await probeNativeVoiceCapability(
        statusOf: (endpoint) =>
            dashboard.probeAudioEndpoint(endpoint, profile: profile),
      );
      if (capability.conclusive) {
        await capabilityStore.write(identity, capability);
      }
    }
    if (!capability.ok) {
      return false;
    }

    String? ttsConfigurationSignature;
    try {
      final schema = await dashboard.getServerConfigSchema(profile: profile);
      final config = sanitizeHermesServerVoiceConfig(
        await dashboard.getServerConfig(profile: profile),
        schema,
      );
      ttsConfigurationSignature = hermesServerTtsConfigurationSignature(config);
    } catch (_) {
      // La firma mejora la invalidación del stream, pero POST /audio/speak
      // sigue siendo el fallback autoritativo si esta lectura falla.
    }

    HermesSpeakRequest speak = (text) =>
        dashboard.synthesizeSpeech(text, profile: profile);
    HermesTranscribeRequest transcribe = (dataUrl, mimeType) =>
        dashboard.transcribeAudio(
          dataUrl,
          mimeType: mimeType,
          profile: profile,
          timeout: kHermesServerTranscribeTimeout,
        );
    var clientDirectSpeech = false;
    // Client-direct voice only behind its own consent: without it no key is
    // fetched and the route stays exactly as it was.
    if (ClientDirectVoiceConsentStore(preferences).read(identity) ==
        ClientDirectVoiceConsent.accepted) {
      final loadConfig = dashboardVoiceClientConfigLoader(
        dashboard,
        profile,
        cache: clientDirectCache,
      );
      final directConfig = await loadConfig();
      clientDirectSpeech = directConfig?.tts != null;
      speak = clientDirectSpeak(
        relay: speak,
        loadConfig: loadConfig,
        direct: clientDirect,
      );
      transcribe = clientDirectTranscribe(
        relay: transcribe,
        loadConfig: loadConfig,
        direct: clientDirect,
      );
    }

    // La elección puede revocarse mientras responden el probe o las lecturas de
    // configuración. La comprobación inicial no autoriza instalar callbacks
    // después de esos awaits.
    if (NativeVoiceModeStore(preferences).read(identity) !=
            NativeVoiceMode.server ||
        NativeVoiceConsentStore(preferences).read(identity) !=
            NativeVoiceConsent.accepted ||
        !(isStillCurrent?.call() ?? true)) {
      return false;
    }

    final speechStream = HermesSpeechStreamClient(
      dashboardBaseUrl: connection.effectiveDashboardUrl,
      auth: dashboard.webSocketAuth,
      profile: profile,
      ttsConfigurationSignature: ttsConfigurationSignature,
      // QA 9709: what plays also says how loud it is, for the wave.
      sinkFactory: () => LevelReportingPcmSink(
        (sinkFactory ?? MethodChannelHermesPcmStreamSink.new)(),
        voice.playbackLevel,
      ),
    );
    transferredToVoice = voice.enablePreparedNativeVoice(
      owner: configurationOwner,
      preparation: reservation,
      speak: speak,
      transcribe: transcribe,
      speechStream: speechStream.open,
      ttsLease: (lease, active) =>
          dashboard.setTtsLease(lease, active: active, profile: profile),
      sttLease: (lease, active) =>
          dashboard.setSttLease(lease, active: active, profile: profile),
      onDispose: dashboard.close,
      clientDirectSpeech: clientDirectSpeech,
    );
    return transferredToVoice;
  } finally {
    if (!transferredToVoice) {
      voice.cancelNativeVoicePreparation(reservation);
      dashboard.close();
    }
  }
}
