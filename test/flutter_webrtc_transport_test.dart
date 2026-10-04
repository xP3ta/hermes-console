import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hermes_android/core/services/voice/live/flutter_webrtc_transport.dart';

class _FakeChannel implements RTCDataChannel {
  int closeCalls = 0;
  Object? closeError;

  @override
  Future<void> close() async {
    closeCalls++;
    final error = closeError;
    if (error != null) throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakePeer implements RTCPeerConnection {
  _FakePeer(this.channel);

  final _FakeChannel channel;
  int closeCalls = 0;
  int disposeCalls = 0;
  Object? closeError;
  Object? disposeError;

  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit dataChannelDict,
  ) async => channel;

  @override
  Future<void> close() async {
    closeCalls++;
    final error = closeError;
    if (error != null) throw error;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    final error = disposeError;
    if (error != null) throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<(FlutterWebRtcTransport, _FakePeer, _FakeChannel)> _open() async {
  final channel = _FakeChannel();
  final peer = _FakePeer(channel);
  final transport = FlutterWebRtcTransport(peerFactory: (_) async => peer);
  await transport.createEventsChannel('oai-events');
  return (transport, peer, channel);
}

void main() {
  test('dispose releases the channel, closes and disposes the peer', () async {
    final (transport, peer, channel) = await _open();
    await transport.dispose();
    expect(channel.closeCalls, 1);
    expect(peer.closeCalls, 1);
    expect(peer.disposeCalls, 1);
  });

  test('a failing peer close still disposes the peer', () async {
    final (transport, peer, _) = await _open();
    peer.closeError = StateError('platform close failed');
    await transport.dispose();
    expect(peer.closeCalls, 1);
    expect(peer.disposeCalls, 1);
  });

  test('a failing channel close still closes and disposes the peer', () async {
    final (transport, peer, channel) = await _open();
    channel.closeError = StateError('channel close failed');
    await transport.dispose();
    expect(peer.closeCalls, 1);
    expect(peer.disposeCalls, 1);
  });

  test(
    'a failing dispose does not throw and a second dispose is a no-op',
    () async {
      final (transport, peer, _) = await _open();
      peer.disposeError = StateError('platform dispose failed');
      await transport.dispose();
      await transport.dispose();
      expect(peer.closeCalls, 1);
      expect(peer.disposeCalls, 1);
    },
  );
}
