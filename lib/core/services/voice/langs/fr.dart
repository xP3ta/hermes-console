part of '../voice_language.dart';

// English speech and command draft pending Phase 4b.
class _FrVoiceLanguage extends VoiceLanguage {
  const _FrVoiceLanguage() : super(
    code: "fr",
    whisperLanguage: "fr",
    systemSttLocales: const ["fr_FR", "fr_CA", "fr_BE", "fr-CH", "fr-FR", "fr"],
    deviceTtsLocales: const ["fr-FR", "fr-CA", "fr-BE", "fr-CH"],
    deviceTtsFallback: "fr-FR",
    neuralVoiceId: "fr_FR-siwis-medium",
    streamingVoiceId: "af_heart",
    transcript: _enTranscriptGrammar,
    messages: _enVoiceMessages,
    commands: _enVoiceCommands,
    speech: const _EnSpeechGrammar(),
    isDraft: true,
  );

  @override
  LocalVoiceCommand? semanticCommand(String text) =>
      const _EnVoiceLanguage().semanticCommand(text);
}
