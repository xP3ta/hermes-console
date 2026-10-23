part of '../voice_language.dart';

// English speech and command draft pending Phase 4b.
class _KoVoiceLanguage extends VoiceLanguage {
  const _KoVoiceLanguage() : super(
    code: "ko",
    whisperLanguage: "ko",
    systemSttLocales: const ["ko_KR", "ko-KR", "ko"],
    deviceTtsLocales: const ["ko-KR"],
    deviceTtsFallback: "ko-KR",
    neuralVoiceId: null,
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
