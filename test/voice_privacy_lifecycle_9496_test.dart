import 'dart:async';
import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hermes_android/core/services/voice/live/flutter_webrtc_transport.dart';

import 'package:flutter_test/flutter_test.dart';

class _Channel implements RTCDataChannel {
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Peer implements RTCPeerConnection {
  final channel = Completer<RTCDataChannel>();
  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit init,
  ) => channel.future;
  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test(
    'RTC channel completing after privacy disposal is closed, never adopted',
    () async {
      final peer = _Peer();
      final transport = FlutterWebRtcTransport(peerFactory: (_) async => peer);
      final opening = transport.createEventsChannel('events');
      await Future<void>.delayed(Duration.zero);
      final disposing = transport.dispose();
      final channel = _Channel();
      peer.channel.complete(channel);
      await opening;
      await disposing;
      expect(channel.closes, 1);
      expect(transport.channelOpen, isFalse);
    },
  );
  // The host used to stop GPT-Live on every background, opt-in or not. By
  // owner decision the lock-screen opt-in now covers an open GPT-Live
  // session; the host still cannot decide that by itself: the coordinator
  // answers, from the live engine and the policy it was built with.
  test('host background opt-in reaches GPT-Live only through the visibility '
      'policy', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('voiceConvo.requiresForegroundVisibility ||'));
    expect(source, contains('voiceConvo.onAppResumed(appUnlocked: true)'));
    final liveFactory = source.substring(
      source.indexOf('liveFactory: () => GptLiveVoiceConversationController('),
      source.indexOf('modes: VoiceChatModeStore('),
    );
    expect(
      liveFactory,
      contains('continueWhenHidden: () => liveVoiceMayContinueHidden('),
    );
    expect(
      liveFactory,
      contains('continueWhenLocked: voice.continueVoiceWhenLocked,'),
    );
    expect(
      liveFactory,
      contains(
        '_foregroundAudioOwner == ForegroundAudioOwner.voiceConversation,',
      ),
      reason: 'the microphone is only kept open under the voice service',
    );
    expect(
      liveFactory,
      contains('viewAttached: _appLifecycle != AppLifecycleState.detached,'),
    );
    // No GPT-Live start unless the app is on screen.
    expect(
      source,
      contains(
        'appVisible: () =>\n'
        '            _appLifecycle == AppLifecycleState.resumed ||\n'
        '            _appLifecycle == AppLifecycleState.inactive,',
      ),
    );
    final lifecycle = source.substring(
      source.indexOf(
        'void didChangeAppLifecycleState(AppLifecycleState state)',
      ),
      source.indexOf('void _syncBackgroundCronConnections()'),
    );
    // Every step away from the front reaches the coordinator, which is what
    // fences any start until the app is back.
    expect(
      lifecycle,
      contains('unawaited(voiceConvo.suspendFullDuplexForAppBackground());'),
    );
    expect(
      lifecycle.indexOf('_appLifecycle = state;'),
      lessThan(lifecycle.indexOf('voiceConvo.suspendFullDuplex')),
      reason: 'the policy reads the state the step just set',
    );
  });
}
