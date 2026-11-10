// What the voice conversation tells the user to do after something went
// wrong or was paused for them. Typed on purpose: the engines never word it,
// the screen does (in the app language), so the same cause reads the same on
// the line, the capsule and the notification.

/// A situation the user can act on, beyond the plain state of the turn.
enum VoiceCare {
  /// The dictated message did not reach Hermes. The text is held for a retry.
  sendFailed,

  /// Another app or a call holds the microphone.
  micBusy,

  /// The microphone could not be opened.
  micUnavailable,

  /// The recognizer needs a connection and has none.
  needsNetwork,

  /// The transcription of what was said did not finish in time.
  transcriptionTimedOut,

  /// The recognizer has no pack for the voice language and listens in the
  /// system's language. Informational: listening continues.
  languageFallback,

  /// The Hermes server's voice is unavailable; the phone's own voice can take
  /// over, only if the user asks.
  serverUnavailable,

  /// The app went to the background and the conversation paused for the user.
  pausedByBackground,

  /// Headset or Bluetooth changed and the microphone was reopened.
  /// Informational.
  routeRestarted,
}

extension VoiceCareKind on VoiceCare {
  /// The conversation is stopped until the user acts (Retry and the like).
  bool get blocking => switch (this) {
    VoiceCare.sendFailed ||
    VoiceCare.micBusy ||
    VoiceCare.micUnavailable ||
    VoiceCare.needsNetwork ||
    VoiceCare.transcriptionTimedOut ||
    VoiceCare.serverUnavailable => true,
    VoiceCare.languageFallback ||
    VoiceCare.pausedByBackground ||
    VoiceCare.routeRestarted => false,
  };
}
