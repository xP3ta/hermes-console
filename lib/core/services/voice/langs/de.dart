part of '../voice_language.dart';

// English speech and command draft pending Phase 4b.
class _DeVoiceLanguage extends VoiceLanguage {
  const _DeVoiceLanguage() : super(
    code: "de",
    whisperLanguage: "de",
    systemSttLocales: const ["de_DE", "de_AT", "de_CH", "de-DE", "de"],
    deviceTtsLocales: const ["de-DE", "de-AT", "de-CH"],
    deviceTtsFallback: "de-DE",
    neuralVoiceId: "de_DE-thorsten-medium",
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
