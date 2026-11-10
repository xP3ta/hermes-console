// Client-direct voice on the server voice route: the consent it needs and the
// STT/TTS callbacks that try the provider first, like Hermes Desktop.
//
// Desktop's ladder (voice-client-direct.ts, voice-playback.ts):
// - STT: direct when `voice-config` says so; no config, a relay verdict or an
//   older server → the relay. A provider rejection is shown, never retried on
//   the relay (use-prompt-actions/index.ts:714-731).
// - TTS: direct first; a direct synthesis that fails before its audio plays
//   → the relay with the same text (voice-playback.ts:278-287, 760-790).
//
// Console asks before using it: the server-voice consent says the audio goes
// to the user's own server, and with direct voice it goes to the provider.

import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../connection_manager.dart';
import 'stt_hermes_server.dart';
import 'tts_engine.dart';
import 'voice_client_direct.dart';

enum ClientDirectVoiceConsent { pending, accepted, rejected }

/// The answer to the direct-voice consent, per server identity. The key
/// carries the version of the consent text: a new text asks again.
class ClientDirectVoiceConsentStore {
  ClientDirectVoiceConsentStore(this._prefs);

  final SharedPreferences _prefs;

  static String storageKey(String identity) =>
      'voice_client_direct_consent_v1::$identity';

  ClientDirectVoiceConsent read(String identity) =>
      switch (_prefs.getString(storageKey(identity))) {
        'accepted' => ClientDirectVoiceConsent.accepted,
        'rejected' => ClientDirectVoiceConsent.rejected,
        _ => ClientDirectVoiceConsent.pending,
      };

  Future<void> write(String identity, ClientDirectVoiceConsent value) =>
      _prefs.setString(storageKey(identity), value.name);
}

typedef VoiceClientConfigLoader = Future<VoiceClientConfig?> Function();

/// The server offers direct voice in at least one direction. With
/// `voice.client_direct: false`, an older server or only server-host
/// providers it does not, and nothing is asked.
bool clientDirectVoiceOffered(VoiceClientConfig? config) =>
    config != null && (config.stt != null || config.tts != null);

/// `GET /api/audio/voice-config` of [dashboard] for [profile], through the
/// shared 60 s cache.
VoiceClientConfigLoader dashboardVoiceClientConfigLoader(
  DashboardClient dashboard,
  String? profile, {
  VoiceClientConfigCache? cache,
}) {
  final held = cache ?? VoiceClientConfigCache.shared;
  final scope = VoiceClientConfigCache.scopeKey(dashboard.baseUrl, profile);
  return () => held.load(
    scope,
    () => dashboard.getVoiceClientConfig(profile: profile),
  );
}

/// Whether direct voice may be used for [identity], asking once when the
/// server offers it and nobody has answered yet. A decline is kept; closing
/// the question decides nothing and it is asked again next time. Keys
/// fetched only to decide are dropped unless the answer is yes.
Future<bool> resolveClientDirectVoiceConsent({
  required ClientDirectVoiceConsentStore store,
  required String identity,
  required VoiceClientConfigLoader loadConfig,
  required Future<bool?> Function() ask,
  VoiceClientConfigCache? cache,
}) async {
  switch (store.read(identity)) {
    case ClientDirectVoiceConsent.accepted:
      return true;
    case ClientDirectVoiceConsent.rejected:
      return false;
    case ClientDirectVoiceConsent.pending:
      break;
  }
  final held = cache ?? VoiceClientConfigCache.shared;
  VoiceClientConfig? config;
  try {
    config = await loadConfig();
  } catch (_) {
    config = null;
  }
  if (!clientDirectVoiceOffered(config)) {
    held.clear();
    return false;
  }
  final answer = await ask();
  if (answer == true) {
    await store.write(identity, ClientDirectVoiceConsent.accepted);
    return true;
  }
  held.clear();
  if (answer == false) {
    await store.write(identity, ClientDirectVoiceConsent.rejected);
  }
  return false;
}

final RegExp _dataUrl = RegExp(
  r'^data:([^;,]+)[^,]*;base64,(.*)$',
  dotAll: true,
);

/// STT callback that transcribes at the provider when the profile's config
/// is direct and relays otherwise. A provider rejection propagates.
HermesTranscribeRequest clientDirectTranscribe({
  required HermesTranscribeRequest relay,
  required VoiceClientConfigLoader loadConfig,
  VoiceClientDirect? direct,
}) {
  final client = direct ?? VoiceClientDirect();
  return (dataUrl, mimeType) async {
    VoiceClientConfig? config;
    try {
      config = await loadConfig();
    } catch (_) {
      config = null;
    }
    final stt = config?.stt;
    final match = _dataUrl.firstMatch(dataUrl);
    final Uint8List audio;
    try {
      audio = match == null
          ? Uint8List(0)
          : base64Decode(match.group(2)!.trim());
    } on FormatException {
      return relay(dataUrl, mimeType);
    }
    if (stt == null || audio.isEmpty) return relay(dataUrl, mimeType);
    final transcript = await client.transcribe(
      stt,
      audio,
      mimeType: mimeType,
    );
    return {'ok': true, 'transcript': transcript, 'provider': stt.provider};
  };
}

/// TTS callback that synthesizes at the provider when the profile's config
/// is direct; any direct failure speaks the same text through the relay.
HermesSpeakRequest clientDirectSpeak({
  required HermesSpeakRequest relay,
  required VoiceClientConfigLoader loadConfig,
  VoiceClientDirect? direct,
}) {
  final client = direct ?? VoiceClientDirect();
  return (text) async {
    VoiceClientConfig? config;
    try {
      config = await loadConfig();
    } catch (_) {
      config = null;
    }
    final tts = config?.tts;
    if (tts == null) return relay(text);
    final Uint8List audio;
    try {
      audio = await client.synthesize(
        tts,
        text,
        // The bound Console already gives the same synthesis on the relay.
        timeout: DashboardClient.audioSpeakRequestTimeout(text),
      );
    } catch (_) {
      return relay(text);
    }
    return {
      'ok': true,
      'data_url': 'data:audio/mpeg;base64,${base64Encode(audio)}',
      'mime_type': 'audio/mpeg',
      'provider': tts.provider,
    };
  };
}
