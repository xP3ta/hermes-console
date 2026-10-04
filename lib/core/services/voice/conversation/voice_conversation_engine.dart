import '../session/voice_ui_surface.dart';

/// What the app shell (`main.dart`) drives besides the chat screen's
/// [VoiceUiSurface]: foreground-service ownership, privacy and background
/// handling, and the notification controls.
abstract interface class VoiceConversationLifecycle {
  /// Hermes session the conversation is attached to, for notification dedupe.
  String? get sessionId;

  /// Android audio resources (microphone, foreground service) are needed now.
  bool get audioLeaseRequired;

  Future<void> suspendForPrivacy();
  Future<void> resumeFullDuplexCaptureIfNeeded();
  Future<void> suspendFullDuplexForAppBackground();
  Future<void> onAppBackgrounded();
  void onAppResumed({required bool appUnlocked});
  Future<void> pauseFromSystemControl();
  Future<void> resumeFromSystemControl();

  /// Releases the engine for good (app shutdown).
  void dispose();
}

/// A voice conversation engine: the chained local one or GPT-Live.
abstract interface class VoiceConversationEngine
    implements VoiceUiSurface, VoiceConversationLifecycle {}
