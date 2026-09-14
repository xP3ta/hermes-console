import 'package:shared_preferences/shared_preferences.dart';

import '../../connection_manager.dart';
import '../hermes_pcm_stream.dart';
import '../hermes_speech_stream.dart';
import '../server_voice_config.dart';
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
}) async {
  assert(dashboardClient == null || dashboardFactory == null);
  HermesServerDictationConfigurationResult unavailableOrSuperseded() {
    return voice.cancelHermesServerDictationPreparation(preparation)
        ? HermesServerDictationConfigurationResult.unavailable
        : HermesServerDictationConfigurationResult.superseded;
  }

  if (voice.settings.sttEngine != SttEngineKind.hermesServer) {
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
      return unavailableOrSuperseded();
    }
    final available = await probeHermesTranscription(
      statusOf: (endpoint) =>
          dashboard.probeAudioEndpoint(endpoint, profile: profile),
    );
    if (!available) {
      return unavailableOrSuperseded();
    }
    // Motor y consentimiento pueden cambiar mientras responde el probe. No
    // transfieras el cliente con una elección ya retirada.
    if (voice.settings.sttEngine != SttEngineKind.hermesServer ||
        NativeVoiceConsentStore(preferences).read(identity) !=
            NativeVoiceConsent.accepted) {
      return unavailableOrSuperseded();
    }
    transferredToVoice = voice.enableHermesServerDictation(
      owner: owner,
      preparation: preparation,
      transcribe: (dataUrl, mimeType) => dashboard.transcribeAudio(
        dataUrl,
        mimeType: mimeType,
        profile: profile,
      ),
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
      sinkFactory: sinkFactory ?? MethodChannelHermesPcmStreamSink.new,
    );
    transferredToVoice = voice.enablePreparedNativeVoice(
      owner: configurationOwner,
      preparation: reservation,
      speak: (text) => dashboard.synthesizeSpeech(text, profile: profile),
      transcribe: (dataUrl, mimeType) => dashboard.transcribeAudio(
        dataUrl,
        mimeType: mimeType,
        profile: profile,
      ),
      speechStream: speechStream.open,
      onDispose: dashboard.close,
    );
    return transferredToVoice;
  } finally {
    if (!transferredToVoice) {
      voice.cancelNativeVoicePreparation(reservation);
      dashboard.close();
    }
  }
}
