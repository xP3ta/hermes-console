import 'dart:async';
import 'dart:convert';

import 'package:hermes_android/core/services/voice/live/live_rtc_transport.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_api.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_protocol.dart';

/// Scripted [LiveRtcTransport]. Every call is appended to [log] (shared with
/// [FakeVoiceLiveApi] so tests can assert the cross-component order).
class FakeLiveRtcTransport implements LiveRtcTransport {
  FakeLiveRtcTransport({List<String>? log}) : log = log ?? <String>[];

  final List<String> log;
  final _remoteAudio = StreamController<void>.broadcast(sync: true);
  final _state = StreamController<LiveRtcConnectionState>.broadcast(sync: true);
  final _messages = StreamController<String>.broadcast(sync: true);
  final _channelClose = StreamController<void>.broadcast(sync: true);

  /// Offer SDP with the CRLF line endings the vendor parser needs.
  String offerSdp = 'v=0\r\no=- 1 2 IN IP4 0.0.0.0\r\ns=-\r\n';
  String localSdp =
      'v=0\r\no=- 1 2 IN IP4 0.0.0.0\r\ns=-\r\na=ice-complete\r\n';
  Completer<void> iceGathering = Completer<void>()..complete();
  @override
  bool channelOpen = true;
  bool micEnabled = true;
  bool micOpen = false;
  int disposeCalls = 0;
  Object? openMicrophoneError;
  final List<Map<String, dynamic>> sent = [];
  String? remoteAnswer;

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
    log.add('openMicrophone');
    final error = openMicrophoneError;
    if (error != null) throw error;
    micOpen = true;
  }

  @override
  Future<void> addMicrophoneTrack() async => log.add('addMicrophoneTrack');

  @override
  Future<void> createEventsChannel(String label) async =>
      log.add('createEventsChannel:$label');

  @override
  Future<String> createOffer() async {
    log.add('createOffer');
    return offerSdp;
  }

  @override
  Future<void> setLocalDescription(String sdp) async =>
      log.add('setLocalDescription');

  @override
  Future<void> waitForIceGatheringComplete() {
    log.add('waitForIce');
    return iceGathering.future;
  }

  @override
  Future<String?> localDescriptionSdp() async => localSdp;

  @override
  Future<void> setRemoteAnswer(String sdp) async {
    log.add('setRemoteAnswer');
    remoteAnswer = sdp;
  }

  @override
  bool send(String data) {
    if (!channelOpen) return false;
    sent.add(jsonDecode(data) as Map<String, dynamic>);
    return true;
  }

  @override
  void setMicEnabled(bool enabled) {
    micEnabled = enabled;
    log.add('mic:$enabled');
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    micOpen = false;
    micEnabled = false;
    log.add('dispose');
    await _remoteAudio.close();
    await _state.close();
    await _messages.close();
    await _channelClose.close();
  }

  // ---- test drivers ----
  void emitState(LiveRtcConnectionState state) {
    if (!_state.isClosed) _state.add(state);
  }

  void emitEvent(Map<String, dynamic> event) {
    if (!_messages.isClosed) _messages.add(jsonEncode(event));
  }

  void emitRaw(String raw) {
    if (!_messages.isClosed) _messages.add(raw);
  }

  void emitChannelClose() {
    if (!_channelClose.isClosed) _channelClose.add(null);
  }

  void emitRemoteAudio() {
    if (!_remoteAudio.isClosed) _remoteAudio.add(null);
  }

  List<String> get sentTypes =>
      sent.map((e) => e['type'] as String).toList(growable: false);
}

/// Scripted [VoiceLiveApi]; records every call.
class FakeVoiceLiveApi implements VoiceLiveApi {
  FakeVoiceLiveApi({List<String>? log}) : log = log ?? <String>[];

  final List<String> log;
  VoiceLiveStatus? status = const VoiceLiveStatus(
    mode: VoiceLiveMode.chained,
    available: true,
  );
  Object? statusError;
  Completer<VoiceLiveStatus?>? statusGate;

  /// One gate per status read, consumed in call order when [statusGate] is
  /// not set.
  final List<Completer<VoiceLiveStatus?>> statusGateQueue = [];
  int statusCalls = 0;
  final List<String> statusProfiles = [];
  final List<({String sdp, List<Map<String, dynamic>> history, String profile})>
  createCalls = [];
  Completer<VoiceLiveSessionAnswer>? createGate;
  Object? createError;
  VoiceLiveSessionAnswer answer = const VoiceLiveSessionAnswer(
    sdp: 'v=0\r\nanswer\r\n',
    sessionId: 'sess_1',
  );

  int closeCalls = 0;

  @override
  void close() => closeCalls++;

  @override
  Future<VoiceLiveStatus?> fetchStatus({String profile = ''}) async {
    statusCalls++;
    statusProfiles.add(profile);
    final gate = statusGate;
    if (gate != null) return gate.future;
    if (statusGateQueue.isNotEmpty) return statusGateQueue.removeAt(0).future;
    final error = statusError;
    if (error != null) throw error;
    return status;
  }

  @override
  Future<VoiceLiveSessionAnswer> createSession({
    required String sdp,
    List<Map<String, dynamic>> history = const [],
    String profile = '',
  }) async {
    log.add('createSession');
    createCalls.add((sdp: sdp, history: history, profile: profile));
    final error = createError;
    if (error != null) throw error;
    final gate = createGate;
    if (gate != null) return gate.future;
    return answer;
  }
}
