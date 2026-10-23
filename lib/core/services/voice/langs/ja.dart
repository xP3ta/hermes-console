part of '../voice_language.dart';

// English speech and command draft pending Phase 4b.
class _JaVoiceLanguage extends VoiceLanguage {
  const _JaVoiceLanguage() : super(
    code: "ja",
    whisperLanguage: "ja",
    systemSttLocales: const ["ja_JP", "ja-JP", "ja"],
    deviceTtsLocales: const ["ja-JP"],
    deviceTtsFallback: "ja-JP",
    neuralVoiceId: null,
    systemTtsOnly: true,
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
