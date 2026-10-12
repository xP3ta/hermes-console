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

  test(
    'a failing peer close surfaces failure, disposes and retains retry ownership',
    () async {
      final (transport, peer, channel) = await _open();
      peer.closeError = StateError('platform close failed');
      await expectLater(transport.dispose(), throwsStateError);
      expect(channel.closeCalls, 1);
      expect(peer.closeCalls, 1);
      expect(peer.disposeCalls, 1);
      expect(transport.channelOpen, isFalse);
      expect(transport.send('must not send'), isFalse);
      await expectLater(transport.dispose(), throwsStateError);
      expect(peer.closeCalls, 2);
      expect(peer.disposeCalls, 2);
      peer.closeError = null;
      await transport.dispose();
      await transport.dispose();
      expect(channel.closeCalls, 1);
      expect(peer.closeCalls, 3);
      expect(peer.disposeCalls, 3);
    },
  );

  test(
    'a failing channel close surfaces failure and retries only the retained channel',
    () async {
      final (transport, peer, channel) = await _open();
      channel.closeError = StateError('channel close failed');
      await expectLater(transport.dispose(), throwsStateError);
      expect(channel.closeCalls, 1);
      expect(peer.closeCalls, 1);
      expect(peer.disposeCalls, 1);
      expect(transport.channelOpen, isFalse);
      expect(transport.send('must not send'), isFalse);
      await expectLater(transport.dispose(), throwsStateError);
      expect(channel.closeCalls, 2);
      expect(peer.closeCalls, 1);
      expect(peer.disposeCalls, 1);
      channel.closeError = null;
      await transport.dispose();
      await transport.dispose();
      expect(channel.closeCalls, 3);
      expect(peer.closeCalls, 1);
      expect(peer.disposeCalls, 1);
    },
  );

  test(
    'failed disposal stays fail-closed until explicit retry physically completes',
    () async {
      final (transport, peer, channel) = await _open();
      peer.disposeError = StateError('platform dispose failed');
      await expectLater(transport.dispose(), throwsStateError);
      await expectLater(transport.dispose(), throwsStateError);
      expect(channel.closeCalls, 1);
      expect(peer.closeCalls, 2);
      expect(peer.disposeCalls, 2);
      expect(transport.channelOpen, isFalse);
      expect(transport.send('must not send'), isFalse);
      peer.disposeError = null;
      await transport.dispose();
      await transport.dispose();
      expect(channel.closeCalls, 1);
      expect(peer.closeCalls, 3);
      expect(peer.disposeCalls, 3);
    },
  );
}
