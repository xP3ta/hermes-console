part of '../voice_language.dart';

// English speech and command draft pending Phase 4b.
class _ZhVoiceLanguage extends VoiceLanguage {
  const _ZhVoiceLanguage() : super(
    code: "zh",
    whisperLanguage: "zh",
    systemSttLocales: const ["zh_CN", "zh_TW", "zh_HK", "zh-CN", "zh"],
    deviceTtsLocales: const ["zh-CN", "zh-TW", "zh-HK"],
    deviceTtsFallback: "zh-CN",
    neuralVoiceId: "zh_CN-huayan-medium",
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
