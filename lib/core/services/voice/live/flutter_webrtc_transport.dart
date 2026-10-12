// This is the only file that imports flutter_webrtc.
import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'live_rtc_transport.dart';

/// [LiveRtcTransport] over flutter_webrtc. One instance serves one session.
///
/// No ICE servers are configured: the vendor answer carries its own
/// candidates and no third-party endpoint is baked into the app.
class FlutterWebRtcTransport implements LiveRtcTransport {
  /// [peerFactory] exists for tests; production uses `createPeerConnection`.
  FlutterWebRtcTransport({
    Future<RTCPeerConnection> Function(Map<String, dynamic> configuration)?
    peerFactory,
  }) : _peerFactory = peerFactory ?? createPeerConnection;

  final Future<RTCPeerConnection> Function(Map<String, dynamic> configuration)
  _peerFactory;
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
  Future<void>? _disposeInFlight;
  final Set<Future<void>> _nativePending = {};

  Future<T> _nativeOperation<T>(Future<T> Function() operation) {
    final result = operation();
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _nativePending.add(settled);
    unawaited(
      settled.then<void>((_) {
        _nativePending.remove(settled);
      }),
    );
    return result;
  }

  @override
  Stream<void> get onRemoteAudio => _remoteAudio.stream;

  @override
  Stream<LiveRtcConnectionState> get onConnectionState => _state.stream;

  @override
  Stream<String> get onChannelMessage => _messages.stream;

  @override
  Stream<void> get onChannelClose => _channelClose.stream;

  @override
  Future<void> openMicrophone() => _nativeOperation(_openMicrophone);

  Future<void> _openMicrophone() async {
    if (_disposed) throw StateError('transport disposed');
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
    // Disposal owns late acquisitions too; its lease waits for this operation.
  }

  Future<RTCPeerConnection> _ensurePeer() => _nativeOperation(_createPeer);

  Future<RTCPeerConnection> _createPeer() async {
    if (_disposed) throw StateError('transport disposed');
    final existing = _peer;
    if (existing != null) return existing;
    final peer = await _peerFactory(<String, dynamic>{
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
    // A late peer is owned by the already-running disposal, not adopted.
    _peer = peer;
    if (_disposed) throw StateError('transport disposed');
    return peer;
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
  Future<void> createEventsChannel(String label) =>
      _nativeOperation(() => _createEventsChannel(label));

  Future<void> _createEventsChannel(String label) async {
    final peer = await _ensurePeer();
    if (_disposed) return;
    final channel = await peer.createDataChannel(label, RTCDataChannelInit());
    if (_disposed) {
      _channel = channel;
      return;
    }
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
      !_disposed && _channel?.state == RTCDataChannelState.RTCDataChannelOpen;

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
    if (stream == null) return;
    bool failed = false;
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {
        failed = true;
      }
    }
    try {
      await stream.dispose();
    } catch (_) {
      failed = true;
    }
    if (failed) throw StateError('microphone cleanup incomplete');
    if (identical(_microphone, stream)) _microphone = null;
  }

  @override
  Future<void> dispose() => _disposeInFlight ??= _dispose().whenComplete(() {
    _disposeInFlight = null;
  });

  Future<void> _dispose() async {
    _disposed = true;
    final done = _iceComplete;
    if (done != null && !done.isCompleted) done.complete();
    // Attempt every independent native cleanup. Failed handles stay owned for
    // explicit retry, and no failure is mistaken for physical completion.
    bool failed = false;
    final initialMicrophone = _microphone;
    try {
      await _stopMicrophone();
    } catch (_) {
      failed = true;
    }
    // No native acquisition admitted before privacy may outlive this lease.
    // Settled operations may have supplied late handles; clean those here.
    await Future.wait(_nativePending.toList());
    if (_microphone != null && !identical(_microphone, initialMicrophone)) {
      try {
        await _stopMicrophone();
      } catch (_) {
        failed = true;
      }
    }
    final channel = _channel;
    try {
      await channel?.close();
      if (identical(_channel, channel)) _channel = null;
    } catch (_) {
      failed = true;
    }
    final peer = _peer;
    bool peerFailed = false;
    try {
      await peer?.close();
    } catch (_) {
      peerFailed = true;
    }
    try {
      await peer?.dispose();
    } catch (_) {
      peerFailed = true;
    }
    if (peerFailed) {
      failed = true;
    } else if (identical(_peer, peer)) {
      _peer = null;
    }
    await Future.wait([
      _remoteAudio.close(),
      _state.close(),
      _messages.close(),
      _channelClose.close(),
    ]);
    if (failed) throw StateError('RTC cleanup incomplete');
  }
}
