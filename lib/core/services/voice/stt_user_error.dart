/// A speech-to-text failure whose own text is for the user (a provider's
/// rejection, already without secrets). The engine passes it through
/// instead of its generic failure, as Desktop shows the provider's reply
/// (`notifyError(error, …)`).
abstract interface class SttUserFacingError implements Exception {}

/// The take had nothing in it: shorter than 0.3 s or with no energy (a car or
/// headset microphone that delivers nothing). It is never sent; the user is
/// told to check the microphone.
final class SttNoAudioError implements SttUserFacingError {
  const SttNoAudioError();

  @override
  String toString() => 'SttNoAudioError';
}

/// The transcription of a take did not finish in time. It names the stage
/// that failed (the transcription, not the microphone) and a retry records
/// again.
final class SttTimeoutError implements SttUserFacingError {
  const SttTimeoutError();

  @override
  String toString() => 'SttTimeoutError';
}

/// Why a capture could not run, in the few kinds the user can act on. Anything
/// else (no match, a timeout of silence) is not a failure of the microphone and
/// never becomes one.
enum SttCaptureFailureKind {
  /// Another app, a call or another recorder holds the microphone.
  micBusy,

  /// The audio input failed to open or to deliver audio.
  micUnavailable,

  /// The recognizer needs a connection and there is none (or it timed out).
  needsNetwork,

  /// The recognizer has no pack for the chosen language.
  languageUnavailable,
}

/// A capture failure with a kind the user can act on. The conversation words
/// it ("microphone busy", "needs the network") and offers Retry.
final class SttCaptureFailure implements SttUserFacingError {
  const SttCaptureFailure(this.kind);

  final SttCaptureFailureKind kind;

  @override
  String toString() => 'SttCaptureFailure(${kind.name})';
}

/// The kind of failure a platform recognizer or recorder message names, or
/// null when it names none the user can act on. Matches the Android
/// recognizer's `error_*` codes and the browser-style names a WebRTC capture
/// reports (`NotReadableError`: the device is in use).
SttCaptureFailureKind? classifySttCaptureFailure(String message) {
  final text = message.toLowerCase();
  if (text.contains('error_busy') ||
      text.contains('notreadableerror') ||
      text.contains('already in use') ||
      text.contains('device or resource busy')) {
    return SttCaptureFailureKind.micBusy;
  }
  if (text.contains('error_audio')) {
    return SttCaptureFailureKind.micUnavailable;
  }
  if (text.contains('error_network') ||
      text.contains('error_server_disconnected') ||
      text.contains('error_server')) {
    return SttCaptureFailureKind.needsNetwork;
  }
  if (text.contains('error_language')) {
    return SttCaptureFailureKind.languageUnavailable;
  }
  return null;
}
