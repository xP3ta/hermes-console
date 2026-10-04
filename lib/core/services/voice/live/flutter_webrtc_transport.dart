// This is the only file that imports flutter_webrtc.
import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'live_rtc_transport.dart';

/// [LiveRtcTransport] over flutter_webrtc. One instance serves one session.
///
/// No ICE servers are configured: the vendor answer carries its own
/// candidates and no third-party endpoint is baked into the app.
class FlutterWebRtcTransport implements LiveRtcTransport {
  final StreamController<void> _remoteAudio =
      StreamController<void>.broadcast();
  final StreamController<LiveRtcConnectionState> _state =
      StreamController<LiveRtcConnectionState>.broadcast();
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<void> _channelClose =
      StreamController<void>.broadcast();

  RTCPeerConnection? _peer;
  RTCDataChannel? _channel;
  MediaStream? _microphone;
  Completer<void>? _iceComplete;
  bool _disposed = false;

  @override
  Stream<void> get onRemoteAudio => _remoteAudio.stream;

  @override
  Stream<LiveRtcConnectionState> get onConnectionState => _state.stream;

  @override
  Stream<String> get onChannelMessage => _messages.stream;

  @override
  Stream<void> get onChannelClose => _channelClose.stream;

  @override
  Future<void> openMicrophone() async {
    try {
      _microphone = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
    } catch (error) {
      // flutter_webrtc reports a refused permission as a DOMException name.
      if (error.toString().contains('NotAllowedError')) {
        throw const LiveMicrophoneDeniedException();
      }
      rethrow;
    }
    if (_disposed) await _stopMicrophone();
  }

  Future<RTCPeerConnection> _ensurePeer() async {
    final existing = _peer;
    if (existing != null) return existing;
    final peer = await createPeerConnection(<String, dynamic>{
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    peer
      ..onTrack = (event) {
        if (event.track.kind == 'audio' && !_remoteAudio.isClosed) {
          _remoteAudio.add(null);
        }
      }
      ..onConnectionState = (state) {
        if (_state.isClosed) return;
        _state.add(switch (state) {
          RTCPeerConnectionState.RTCPeerConnectionStateNew ||
          RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
            LiveRtcConnectionState.connecting,
          RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
            LiveRtcConnectionState.connected,
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
            LiveRtcConnectionState.disconnected,
          RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
            LiveRtcConnectionState.failed,
          RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
            LiveRtcConnectionState.closed,
        });
      }
      ..onIceGatheringState = (state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
          final done = _iceComplete;
          if (done != null && !done.isCompleted) done.complete();
        }
      };
    if (_disposed) {
      await peer.close();
      throw StateError('transport disposed');
    }
    return _peer = peer;
  }

  @override
  Future<void> addMicrophoneTrack() async {
    final peer = await _ensurePeer();
    final stream = _microphone;
    if (stream == null) throw StateError('microphone not open');
    for (final track in stream.getAudioTracks()) {
      await peer.addTrack(track, stream);
    }
  }

  @override
  Future<void> createEventsChannel(String label) async {
    final peer = await _ensurePeer();
    final channel = await peer.createDataChannel(label, RTCDataChannelInit());
    channel
      ..onMessage = (message) {
        if (!message.isBinary && !_messages.isClosed) {
          _messages.add(message.text);
        }
      }
      ..onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelClosed &&
            !_channelClose.isClosed) {
          _channelClose.add(null);
        }
      };
    _channel = channel;
  }

  @override
  Future<String> createOffer() async {
    final peer = await _ensurePeer();
    final offer = await peer.createOffer(<String, dynamic>{});
    return offer.sdp ?? '';
  }

  @override
  Future<void> setLocalDescription(String sdp) async {
    final peer = await _ensurePeer();
    _iceComplete = Completer<void>();
    await peer.setLocalDescription(RTCSessionDescription(sdp, 'offer'));
  }

  @override
  Future<void> waitForIceGatheringComplete() async {
    final peer = await _ensurePeer();
    if (peer.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    await (_iceComplete ??= Completer<void>()).future;
  }

  @override
  Future<String?> localDescriptionSdp() async =>
      (await _peer?.getLocalDescription())?.sdp;

  @override
  Future<void> setRemoteAnswer(String sdp) async {
    final peer = await _ensurePeer();
    await peer.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  @override
  bool get channelOpen =>
      _channel?.state == RTCDataChannelState.RTCDataChannelOpen;

  @override
  bool send(String data) {
    final channel = _channel;
    if (channel == null || !channelOpen) return false;
    unawaited(
      channel.send(RTCDataChannelMessage(data)).catchError((Object _) {}),
    );
    return true;
  }

  @override
  void setMicEnabled(bool enabled) {
    for (final track in _microphone?.getAudioTracks() ?? const []) {
      track.enabled = enabled;
    }
  }

  Future<void> _stopMicrophone() async {
    final stream = _microphone;
    _microphone = null;
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await stream.dispose();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final done = _iceComplete;
    if (done != null && !done.isCompleted) done.complete();
    await _stopMicrophone();
    final channel = _channel;
    _channel = null;
    final peer = _peer;
    _peer = null;
    try {
      await channel?.close();
    } catch (_) {}
    try {
      await peer?.close();
      await peer?.dispose();
    } catch (_) {}
    await Future.wait([
      _remoteAudio.close(),
      _state.close(),
      _messages.close(),
      _channelClose.close(),
    ]);
  }
}
