// Voice engines the settings screen no longer offers.
//
// Voice settings follow Hermes Desktop: the voice comes from the Hermes
// server or from this phone. The engines that pointed at a service of the
// user's own (a Kokoro or OpenAI-compatible address, ElevenLabs with its key,
// a custom REST API, a dictation server) can no longer be chosen, so a saved
// choice of one of them is moved, once and without a word, to something the
// screen can show.
//
// Only the choice moves. The engine classes are still compiled and the
// addresses and keys the user stored stay where they were.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection_manager.dart';
import 'conversation/native_voice.dart';
import 'conversation/native_voice_session_configurator.dart';
import 'stt_sherpa.dart';
import 'tts_model_manager.dart';
import 'voice_service.dart';
import 'voice_settings.dart';

abstract final class RemovedVoiceEngines {
  static bool isRemovedSpeech(TtsEngineKind kind) => switch (kind) {
    TtsEngineKind.elevenlabs ||
    TtsEngineKind.streaming ||
    TtsEngineKind.customHttp => true,
    TtsEngineKind.device || TtsEngineKind.onnx => false,
  };

  static bool isRemovedDictation(SttEngineKind kind) =>
      kind == SttEngineKind.server;

  /// Whether [settings] still names an engine that cannot be chosen any more.
  static bool pending(VoiceSettings settings) =>
      isRemovedSpeech(settings.ttsEngine) ||
      isRemovedDictation(settings.sttEngine);

  /// Moves a saved removed engine to one the screen offers and saves it.
  ///
  /// The reply voice becomes a voice already downloaded on this phone, or the
  /// Android voice when there is none. A connection that speaks through the
  /// Hermes server keeps doing so: that choice is stored per connection and
  /// is not touched here.
  ///
  /// Dictation through the user's own server becomes dictation through the
  /// Hermes server when [serverDictation] answers `true`, and a phone engine
  /// when it answers `false`: a downloaded model, or Android's recogniser.
  /// When it answers `null` (the server could not be asked right now) the
  /// dictation choice is left for the next run and keeps working meanwhile.
  ///
  /// Returns whether anything was saved.
  static Future<bool> migrate({
    required VoiceService voice,
    required Future<bool?> Function() serverDictation,
    @visibleForTesting RemovedVoiceEngineDownloads? downloads,
  }) async {
    final before = voice.settings;
    if (!pending(before)) return false;
    final onPhone = downloads ?? RemovedVoiceEngineDownloads.of(voice);

    var speech = before.ttsEngine;
    var neuralVoice = before.onnxVoiceId;
    if (isRemovedSpeech(speech)) {
      final installed = await _installedVoice(onPhone, before.onnxVoiceId);
      speech = installed == null ? TtsEngineKind.device : TtsEngineKind.onnx;
      neuralVoice = installed ?? neuralVoice;
    }

    var dictation = before.sttEngine;
    var dictationModel = before.sherpaModel;
    if (isRemovedDictation(dictation)) {
      final server = await serverDictation();
      if (server == true) {
        dictation = SttEngineKind.hermesServer;
      } else if (server == false) {
        final installed = await _installedDictationModel(
          onPhone,
          before.sherpaModel,
        );
        if (installed != null) {
          dictation = SttEngineKind.sherpaLive;
          dictationModel = installed;
        } else if (await onPhone.whisper()) {
          dictation = SttEngineKind.whisper;
        } else {
          dictation = SttEngineKind.system;
        }
      }
    }

    // The checks above wait on storage and maybe on the network: a choice
    // made meanwhile wins over the migration.
    final now = voice.settings;
    if (now.ttsEngine != before.ttsEngine ||
        now.sttEngine != before.sttEngine) {
      return false;
    }
    if (speech == before.ttsEngine && dictation == before.sttEngine) {
      return false;
    }
    await voice.saveSettings(
      now.copyWith(
        ttsEngine: speech,
        onnxVoiceId: neuralVoice,
        sttEngine: dictation,
        sherpaModel: dictationModel,
      ),
    );
    return true;
  }

  /// Whether [connection] and [profile] may dictate through the Hermes
  /// server: the user already accepted sending audio there and the server
  /// transcribes. `null` when the server gave no conclusive answer.
  static Future<bool?> serverDictationFor({
    required SavedConnection connection,
    required SharedPreferences preferences,
    required String profile,
    NativeVoiceDashboardFactory? dashboardFactory,
  }) async {
    DashboardClient? dashboard;
    try {
      dashboard = (dashboardFactory ?? DashboardClient.lazy)(connection);
      final identity = nativeVoicePreferenceIdentity(
        dashboard.baseUrl,
        profile: profile,
      );
      if (NativeVoiceConsentStore(preferences).read(identity) !=
          NativeVoiceConsent.accepted) {
        return false;
      }
      final status = await dashboard.probeAudioEndpoint(
        'transcribe',
        profile: profile,
      );
      return switch (status) {
        200 || 400 || 422 => true,
        404 || 405 || 501 => false,
        _ => null,
      };
    } catch (_) {
      return null;
    } finally {
      dashboard?.close();
    }
  }

  static Future<String?> _installedVoice(
    RemovedVoiceEngineDownloads onPhone,
    String preferred,
  ) async {
    final chosen = neuralVoiceById(preferred);
    if (chosen != null && await onPhone.voice(chosen)) return chosen.id;
    for (final candidate in kNeuralVoices) {
      if (await onPhone.voice(candidate)) return candidate.id;
    }
    return null;
  }

  static Future<SherpaModelKind?> _installedDictationModel(
    RemovedVoiceEngineDownloads onPhone,
    SherpaModelKind preferred,
  ) async {
    final ordered = [
      ...kSherpaSttModels.where((model) => model.kind == preferred),
      ...kSherpaSttModels.where((model) => model.kind != preferred),
    ];
    for (final model in ordered) {
      if (await onPhone.dictation(model)) return model.kind;
    }
    return null;
  }
}

/// What is already downloaded on this phone, as the migration needs to know
/// it. Production asks [VoiceService]; tests answer without a disk.
class RemovedVoiceEngineDownloads {
  const RemovedVoiceEngineDownloads({
    required this.voice,
    required this.dictation,
    required this.whisper,
  });

  factory RemovedVoiceEngineDownloads.of(VoiceService service) =>
      RemovedVoiceEngineDownloads(
        voice: service.ttsModels.isReady,
        dictation: service.sherpaReady,
        whisper: service.whisperModelReady,
      );

  final Future<bool> Function(NeuralVoice voice) voice;
  final Future<bool> Function(SherpaSttModel model) dictation;
  final Future<bool> Function() whisper;
}
