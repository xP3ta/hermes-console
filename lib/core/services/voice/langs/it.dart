part of '../voice_language.dart';

// English speech and command draft pending Phase 4b.
class _ItVoiceLanguage extends VoiceLanguage {
  const _ItVoiceLanguage() : super(
    code: "it",
    whisperLanguage: "it",
    systemSttLocales: const ["it_IT", "it_CH", "it-IT", "it"],
    deviceTtsLocales: const ["it-IT", "it-CH"],
    deviceTtsFallback: "it-IT",
    neuralVoiceId: "it_IT-paola-medium",
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
