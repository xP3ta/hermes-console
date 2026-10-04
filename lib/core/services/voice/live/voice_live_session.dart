import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'live_rtc_transport.dart';
import 'voice_live_api.dart';
import 'voice_live_protocol.dart';

/// The session could not be brought up (microphone, ICE failure, ...). The
/// transport is already torn down when this is thrown.
final class VoiceLiveStartException implements Exception {
  final String message;

  const VoiceLiveStartException(this.message);

  @override
  String toString() => 'VoiceLiveStartException($message)';
}

typedef VoiceLiveDelegationHandler =
    void Function(String delegationId, List<VoiceLiveFragment> context);

/// Called exactly once when the session ends. `close_requested` means the
/// caller asked for it; anything else is unexpected. [usageSeconds] is the
/// vendor-reported session time when it was sent.
typedef VoiceLiveClosedHandler =
    void Function(String reason, int? usageSeconds);

/// One GPT-Live WebRTC session (port of Hermes Desktop's `VoiceLiveSession`).
///
/// The server creates the vendor session; this class negotiates the media path
/// through [LiveRtcTransport], speaks the `oai-events` protocol and guarantees
/// that every exit goes through a single idempotent teardown.
class VoiceLiveSession {
  static const String channelLabel = 'oai-events';
  static const Duration iceGatherTimeout = Duration(seconds: 10);
  static const Duration closeTimeout = Duration(seconds: 15);

  static const int _maxClientContent = 1400;
  static const int _transcriptCap = 2000;
  static const int _transcriptKeep = 1500;
  static const int _contextMaxFragments = 80;
  static const int _contextWindowMs = 5 * 60 * 1000;

  VoiceLiveSession({
    required this._transport,
    required this._api,
    this.profile = '',
    this.history = const [],
    required this.onDelegation,
    required this.onClosed,
    this.onNotice,
    this.onTranscript,
  });

  final LiveRtcTransport _transport;
  final VoiceLiveApi _api;
  final String profile;
  final List<Map<String, dynamic>> history;

  final VoiceLiveDelegationHandler onDelegation;
  final VoiceLiveClosedHandler onClosed;

  /// Non-fatal vendor notice (`error` events other than the ignorable one).
  final void Function(String message)? onNotice;

  /// Every transcript fragment as it arrives.
  final void Function(VoiceLiveFragment fragment)? onTranscript;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  final List<VoiceLiveFragment> _fragments = [];
  Completer<void>? _iceWait;
  Timer? _closeTimer;
  bool _finished = false;
  bool _closing = false;
  bool _negotiated = false;
  bool _started = false;
  bool _remoteAudioAttached = false;
  String? _sessionId;
  String? _activeDelegationId;
  int _eventCounter = 0;

  /// `session.started` was received.
  bool get started => _started;
  bool get finished => _finished;
  String? get sessionId => _sessionId;
  String? get activeDelegationId => _activeDelegationId;
  bool get remoteAudioAttached => _remoteAudioAttached;

  @visibleForTesting
  int get transcriptLength => _fragments.length;

  /// Brings the session up (Desktop `start`, order matters). Throws after a
  /// full teardown if any step fails. Returns normally without applying the
  /// answer when the session was closed while the request was in flight.
  Future<void> start() async {
    try {
      await _start();
    } catch (_) {
      _teardown();
      rethrow;
    }
  }

  Future<void> _start() async {
    _subscriptions
      ..add(_transport.onRemoteAudio.listen((_) => _remoteAudioAttached = true))
      ..add(_transport.onConnectionState.listen(_onConnectionState))
      ..add(_transport.onChannelMessage.listen(_onMessage))
      ..add(_transport.onChannelClose.listen((_) => _onChannelClosed()));

    await _transport.openMicrophone();
    if (_finished) return;
    await _transport.addMicrophoneTrack();
    if (_finished) return;
    // The channel must exist before the offer so its m-line is negotiated.
    await _transport.createEventsChannel(channelLabel);
    if (_finished) return;
    final offer = await _transport.createOffer();
    if (_finished) return;
    await _transport.setLocalDescription(offer);
    if (_finished) return;
    await _waitForIce();
    if (_finished) return;
    // The vendor's SDP parser needs the offer byte-exact: never trim it.
    final sdp = await _transport.localDescriptionSdp() ?? offer;
    if (_finished) return;
    final answer = await _api.createSession(
      sdp: sdp,
      history: history,
      profile: profile,
    );
    if (_finished) return;
    _sessionId = answer.sessionId ?? _sessionId;
    await _transport.setRemoteAnswer(answer.sdp);
    _negotiated = true;
  }

  /// Waits for ICE gathering or [iceGatherTimeout]; a timeout is not an error
  /// (trickle ICE is fine) but a connection failure while waiting is.
  Future<void> _waitForIce() async {
    final done = Completer<void>();
    _iceWait = done;
    final timer = Timer(iceGatherTimeout, () {
      if (!done.isCompleted) done.complete();
    });
    unawaited(
      _transport.waitForIceGatheringComplete().then<void>(
        (_) {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
      ),
    );
    try {
      await done.future;
    } finally {
      timer.cancel();
      _iceWait = null;
    }
  }

  void _onConnectionState(LiveRtcConnectionState state) {
    if (_finished) return;
    if (state != LiveRtcConnectionState.failed &&
        state != LiveRtcConnectionState.disconnected) {
      return;
    }
    final wait = _iceWait;
    if (wait != null) {
      if (!wait.isCompleted) {
        wait.completeError(
          const VoiceLiveStartException(
            'connection failed during ICE gathering',
          ),
        );
      }
      return;
    }
    if (_negotiated) _finish('connection_lost', null);
  }

  void _onChannelClosed() {
    if (!_finished) _finish('connection_lost', null);
  }

  void _onMessage(String raw) {
    if (_finished) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    switch (decoded['type']) {
      case 'session.started':
        _started = true;
        final id = _idOf(decoded['session']);
        if (id != null) _sessionId = id;
      case 'session.input_transcript.delta':
        _appendFragment(VoiceLiveSpeaker.user, decoded);
      case 'session.output_transcript.delta':
        _appendFragment(VoiceLiveSpeaker.assistant, decoded);
      case 'session.delegation.created':
        final id = _idOf(decoded['delegation']);
        if (id == null) return;
        _activeDelegationId = id;
        onDelegation(id, _contextWindow());
      case 'error':
        final error = decoded['error'];
        if (error is! Map) return;
        // Late appends after close are expected and harmless.
        if (error['code'] == 'context_injection_incomplete') return;
        final message = error['message'];
        onNotice?.call(message is String ? message : '');
      case 'session.closed':
        final reason = decoded['reason'];
        final usage = decoded['usage'];
        final seconds = usage is Map ? usage['seconds'] : null;
        _finish(
          reason is String && reason.isNotEmpty ? reason : 'closed',
          seconds is num ? seconds.toInt() : null,
        );
    }
  }

  static String? _idOf(Object? holder) {
    if (holder is! Map) return null;
    final id = holder['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  void _appendFragment(VoiceLiveSpeaker speaker, Map<Object?, Object?> event) {
    final delta = event['delta'];
    if (delta is! String || delta.isEmpty) return;
    final start = event['start_ms'];
    final end = event['end_ms'];
    final fragment = VoiceLiveFragment(
      speaker: speaker,
      text: delta,
      startMs: start is num ? start.toInt() : 0,
      endMs: end is num ? end.toInt() : 0,
    );
    _fragments.add(fragment);
    if (_fragments.length > _transcriptCap) {
      _fragments.removeRange(0, _fragments.length - _transcriptKeep);
    }
    onTranscript?.call(fragment);
  }

  List<VoiceLiveFragment> _contextWindow() {
    if (_fragments.isEmpty) return const [];
    final threshold = _fragments.last.endMs - _contextWindowMs;
    final recent = _fragments
        .where((fragment) => fragment.endMs >= threshold)
        .toList(growable: false);
    return recent.length > _contextMaxFragments
        ? recent.sublist(recent.length - _contextMaxFragments)
        : recent;
  }

  // ---- client -> server ----

  String _nextId(String prefix) => '${prefix}_${++_eventCounter}';

  static String _clamp(String text) => text.length > _maxClientContent
      ? text.substring(0, _maxClientContent)
      : text;

  bool _send(Map<String, Object?> event) {
    if (_finished) return false;
    return _transport.send(jsonEncode(event));
  }

  /// Quiet progress context for the voice model (tool names only).
  bool think(String? delegationId, String content) {
    if (content.isEmpty) return false;
    return _send({
      'type': 'session.thinking.append',
      'delegation_id': delegationId,
      'event_id': _nextId('think'),
      'content': _clamp(content),
    });
  }

  /// One chunk of the answer for the voice to paraphrase; see
  /// [chunkForCommentary].
  bool commentary(String? delegationId, String chunk) {
    if (chunk.isEmpty) return false;
    return _send({
      'type': 'session.commentary.append',
      'delegation_id': delegationId,
      'event_id': _nextId('say'),
      'content': _clamp(chunk),
    });
  }

  bool instruct(String content) {
    if (content.isEmpty) return false;
    return _send({
      'type': 'session.instructions.append',
      'delegation_id': null,
      'event_id': _nextId('instr'),
      'content': _clamp(content),
    });
  }

  /// Mutes/unmutes the microphone locally and on the vendor side.
  void setMuted(bool muted) {
    if (_finished) return;
    _transport.setMicEnabled(!muted);
    _send({
      'type': muted ? 'session.input_audio.mute' : 'session.input_audio.unmute',
      'event_id': _nextId('mute'),
    });
  }

  /// Asks the vendor to close and finishes on `session.closed` or after
  /// [closeTimeout]. No-op once finished or already closing.
  Future<void> close() async {
    if (_finished || _closing) return;
    if (!_send({'type': 'session.close'})) {
      _finish('close_requested', null);
      return;
    }
    _closing = true;
    _closeTimer = Timer(closeTimeout, () => _finish('close_requested', null));
  }

  /// Idempotent end of the session: every exit funnels here.
  void _finish(String reason, int? usageSeconds) {
    if (_finished) return;
    _teardown();
    onClosed(reason, usageSeconds);
  }

  /// Releases everything without reporting; shared by [_finish] and failed
  /// starts (which report by throwing).
  void _teardown() {
    if (_finished) return;
    _finished = true;
    _closeTimer?.cancel();
    _closeTimer = null;
    final wait = _iceWait;
    if (wait != null && !wait.isCompleted) wait.complete();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _fragments.clear();
    _activeDelegationId = null;
    unawaited(_transport.dispose().catchError((Object _) {}));
  }
}
