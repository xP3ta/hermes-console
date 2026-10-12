/// Peer-connection state as far as GPT-Live cares about it.
enum LiveRtcConnectionState {
  connecting,
  connected,
  disconnected,
  failed,
  closed,
}

/// The user denied the microphone permission while the session was starting.
final class LiveMicrophoneDeniedException implements Exception {
  const LiveMicrophoneDeniedException();

  @override
  String toString() => 'LiveMicrophoneDeniedException';
}

/// What `VoiceLiveSession` needs from a WebRTC stack, and nothing more.
///
/// The production adapter (`FlutterWebRtcTransport`) is the only file that
/// imports `flutter_webrtc`; tests use a fake. One transport serves exactly
/// one session: after [dispose] it must not be reused.
abstract interface class LiveRtcTransport {
  /// A remote audio track arrived (the platform plays it by itself).
  Stream<void> get onRemoteAudio;

  Stream<LiveRtcConnectionState> get onConnectionState;

  /// Text frames received on the events data channel.
  Stream<String> get onChannelMessage;

  /// The events data channel closed.
  Stream<void> get onChannelClose;

  /// Opens the microphone with echo cancellation, noise suppression and
  /// automatic gain control.
  Future<void> openMicrophone();

  Future<void> addMicrophoneTrack();

  /// Creates the events data channel. Must happen before [createOffer] so the
  /// channel's m-line is negotiated.
  Future<void> createEventsChannel(String label);

  /// Creates the offer and returns its SDP.
  Future<String> createOffer();

  Future<void> setLocalDescription(String sdp);

  /// Completes when ICE gathering is complete. The caller bounds the wait.
  Future<void> waitForIceGatheringComplete();

  /// The local description's SDP, byte-exact as the stack holds it.
  Future<String?> localDescriptionSdp();

  Future<void> setRemoteAnswer(String sdp);

  /// Whether the events channel is currently open.
  bool get channelOpen;

  /// Sends a text frame on the events channel; `false` if it is not open.
  bool send(String data);

  /// Enables or disables the local microphone track.
  void setMicEnabled(bool enabled);

  /// Stops every microphone track and closes the channel and the peer
  /// connection. Idempotent.
  Future<void> dispose();
}
