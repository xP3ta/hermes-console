// Live view of one delegated subagent through a lazy "watch" session.
//
// The child runs inside its parent's turn. Hermes mirrors its activity as
// native stream events on a watch runtime opened with `session.resume
// {lazy: true}` for the child's stored id (scoped to the parent's profile).
// This controller owns that runtime for as long as the detail page is
// visible: it renders the stored history, applies the mirrored events and
// closes the runtime exactly once. It never submits prompts and never opens a
// socket: it borrows the parent chat's own gateway.
//
// Privacy: reasoning deltas, tool arguments and previews are dropped; only
// public text and public tool names reach [SubagentLiveWatchView].
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/desktop_session_snapshot.dart';
import '../utils/assistant_content.dart';
import 'tui_gateway_client.dart' show TuiGatewayEvent, TuiGatewayRpcError;

/// Minimal gateway surface the watch needs. Deliberately has no prompt
/// submission: a watch session is read-only.
abstract interface class SubagentWatchGateway {
  Stream<TuiGatewayEvent> get events;

  /// `session.resume` of the child's stored id as a lazy watch runtime.
  Future<DesktopSessionSnapshot> resumeWatchSession(
    String childSessionId, {
    required String profile,
  });

  Future<bool> closeSession(String runtimeSessionId);

  void retainSessionRuntime(String runtimeSessionId);

  void releaseSessionRuntime(String runtimeSessionId);
}

/// What a chat lends to a watch of one of its children: its own gateway (the
/// connection's shared socket), the profile that owns the chat, and a check
/// that the runtime and session it was lent for are still the bound ones.
final class SubagentWatchLease {
  const SubagentWatchLease({
    required this.gateway,
    required this.profile,
    required this.isCurrent,
  });

  final SubagentWatchGateway gateway;
  final String profile;
  final bool Function() isCurrent;
}

enum SubagentLiveWatchStatus {
  idle,
  opening,
  live,
  reconnecting,
  finished,

  /// The watch cannot be used (old server, rejected resume, stale owner): the
  /// caller falls back to the polled tail.
  unavailable,
}

@immutable
final class SubagentLiveWatchView {
  final SubagentLiveWatchStatus status;

  /// Public text of the child so far: stored history plus mirrored deltas.
  final String text;

  const SubagentLiveWatchView({
    this.status = SubagentLiveWatchStatus.idle,
    this.text = '',
  });
}

class SubagentLiveWatch extends ValueNotifier<SubagentLiveWatchView> {
  SubagentLiveWatch({
    required this.gateway,
    required this.childSessionId,
    required this.profile,
    required this.isCurrent,
    this.childIsLive = _never,
    this.invalidation,
  }) : super(const SubagentLiveWatchView());

  /// Upper bound of raw mirrored text kept in memory. The stored transcript
  /// has the rest; the page only ever shows the tail.
  static const int maxLiveChars = 262144;

  final SubagentWatchGateway gateway;
  final String childSessionId;

  /// Profile of the parent chat, never the globally active one.
  final String profile;

  /// False once the owner (chat runtime, active profile) moved on.
  final bool Function() isCurrent;

  /// Whether the parent's own roster still reports the child as working.
  final bool Function() childIsLive;

  /// Notifies when something that [isCurrent] reads may have changed (the
  /// active profile, the owning chat), so a watch that receives no event still
  /// notices it is stale.
  final Listenable? invalidation;

  static bool _never() => false;

  StreamSubscription<TuiGatewayEvent>? _subscription;
  bool _started = false;
  bool _closed = false;
  bool _retained = false;

  /// Runtime of the current watch session; null while none is bound.
  String? _runtime;

  /// Bumped by every resume attempt and by [close], so an answer that lost
  /// the race is recognised and discarded.
  int _generation = 0;
  String _history = '';
  String _liveRaw = '';

  /// Only the mirrored deltas, without the tool lines: what the closing
  /// summary repeats.
  String _deltaText = '';

  @visibleForTesting
  int get deltaCharsForTesting => _deltaText.length;

  @visibleForTesting
  int get liveRawCharsForTesting => _liveRaw.length;

  @visibleForTesting
  String get deltaTextForTesting => _deltaText;

  /// Opens the watch. Idempotent; the caller is the page that became visible.
  void start() {
    if (_started || _closed) return;
    _started = true;
    _subscription = gateway.events.listen(_onEvent, onError: _onTransportError);
    invalidation?.addListener(_onInvalidated);
    _open(SubagentLiveWatchStatus.opening);
  }

  /// Leaves the watch: releases the runtime and sends one `session.close`.
  /// Idempotent; nothing is painted or notified afterwards.
  Future<void> close() async {
    _closed = true;
    _generation++;
    invalidation?.removeListener(_onInvalidated);
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    await _closeRuntime();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  void _open(SubagentLiveWatchStatus status) {
    final generation = ++_generation;
    _publish(status);
    Future<DesktopSessionSnapshot>.sync(
      () => gateway.resumeWatchSession(childSessionId, profile: profile),
    ).then(
      (snapshot) => _onResumed(generation, snapshot),
      onError: (Object _) {
        // Old server (-32601) or any refusal: the polled tail takes over.
        if (!_closed && generation == _generation) _giveUp();
      },
    );
  }

  void _onResumed(int generation, DesktopSessionSnapshot snapshot) {
    final runtime = snapshot.runtimeSessionId;
    if (_closed || generation != _generation) {
      // Late answer: nobody reads this runtime, free it.
      unawaited(_closeRemote(runtime));
      return;
    }
    if (!isCurrent()) {
      unawaited(_closeRemote(runtime));
      _giveUp();
      return;
    }
    _history = _publicHistory(snapshot.messages);
    _liveRaw = '';
    _deltaText = '';
    if (!snapshot.running && !childIsLive()) {
      // Nothing is mirrored for a finished child: read once, keep nothing.
      unawaited(_closeRemote(runtime));
      _stopListening();
      _publish(SubagentLiveWatchStatus.finished);
      return;
    }
    _runtime = runtime;
    _retained = true;
    gateway.retainSessionRuntime(runtime);
    _publish(SubagentLiveWatchStatus.live);
  }

  void _onEvent(TuiGatewayEvent event) {
    final runtime = _runtime;
    if (_closed || runtime == null || event.sessionId != runtime) return;
    if (!isCurrent()) {
      _giveUp();
      return;
    }
    final payload = event.payload;
    switch (event.type) {
      case 'message.delta':
        final text = payload['text'];
        if (text is String) {
          _deltaText += _take(text, maxLiveChars - _deltaText.length);
          _appendRaw(text);
        }
      case 'tool.start':
        final name = _publicToolName(payload['name']);
        if (name != null) {
          // A tool line splits the streamed text: keep that boundary as a
          // line break so the summary is compared with the same spacing.
          if (_deltaText.isNotEmpty && !_deltaText.endsWith('\n')) {
            _deltaText += _take('\n', maxLiveChars - _deltaText.length);
          }
          _appendRaw('${_onNewLine(_liveRaw)}› $name\n');
        }
      case 'message.complete':
        final summary = finalizedPublicAssistantText(
          payload['text'] is String ? payload['text'] as String : '',
        ).trim();
        if (summary.isNotEmpty && !_alreadyShown(summary)) {
          _appendRaw('${_onNewLine(_liveRaw)}$summary');
        }
        _stopListening();
        _publish(SubagentLiveWatchStatus.finished);
        unawaited(_closeRuntime());
      // `reasoning.delta` is private by policy; `message.start` and
      // `tool.complete` carry nothing public to render.
    }
  }

  void _onInvalidated() {
    if (_closed || isCurrent()) return;
    _giveUp();
  }

  void _onTransportError(Object error, [StackTrace? stackTrace]) {
    if (_closed || _runtime == null) return;
    // The shared socket also reports rehydrations that name one runtime: only
    // this watch's own, or a loss of the whole transport, concerns it.
    if (error is TuiGatewayRpcError) {
      final named = error.data['session_id'];
      if (named is String && named.isNotEmpty && named != _runtime) return;
    }
    // The socket died with its runtime: nothing to close on the old one. A
    // fresh lazy resume rebuilds history from storage, so the live buffer is
    // dropped instead of being appended to.
    final lost = _runtime!;
    _runtime = null;
    if (_retained) {
      _retained = false;
      gateway.releaseSessionRuntime(lost);
    }
    _open(SubagentLiveWatchStatus.reconnecting);
  }

  void _giveUp() {
    _stopListening();
    _publish(SubagentLiveWatchStatus.unavailable);
    unawaited(_closeRuntime());
  }

  void _stopListening() {
    invalidation?.removeListener(_onInvalidated);
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
  }

  Future<void> _closeRuntime() async {
    final runtime = _runtime;
    if (runtime == null) return;
    _runtime = null;
    if (_retained) {
      _retained = false;
      // Release first so frames still in flight are dropped by the client.
      gateway.releaseSessionRuntime(runtime);
    }
    await _closeRemote(runtime);
  }

  Future<void> _closeRemote(String runtime) async {
    try {
      await gateway.closeSession(runtime);
    } catch (_) {
      // The runtime is reaped by Hermes when the socket goes away.
    }
  }

  void _appendRaw(String text) {
    final kept = _take(text, maxLiveChars - _liveRaw.length);
    if (kept.isEmpty) return;
    _liveRaw += kept;
    _publish(value.status);
  }

  /// The summary the child closes with usually repeats what was streamed.
  /// Only the line-ending flavour and the ends are normalized: line breaks and
  /// indentation are meaning in Markdown, so a summary that restructures the
  /// text is a correction and is kept.
  bool _alreadyShown(String summary) {
    String norm(String text) => text.replaceAll('\r\n', '\n').trim();
    final wanted = norm(summary);
    final streamed = norm(
      projectPublicAssistantText(_deltaText, streaming: false).text,
    );
    return streamed.endsWith(wanted) || norm(_publicLive).endsWith(wanted);
  }

  /// At most [room] code units of [text], never ending in half a surrogate
  /// pair.
  static String _take(String text, int room) {
    if (room <= 0) return '';
    if (text.length <= room) return text;
    var end = room;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return text.substring(0, end);
  }

  String get _publicLive =>
      projectPublicAssistantText(_liveRaw, streaming: true).text;

  void _publish(SubagentLiveWatchStatus status) {
    if (_closed) return;
    final live = _publicLive;
    value = SubagentLiveWatchView(
      status: status,
      text: [_history, live].where((part) => part.isNotEmpty).join('\n'),
    );
  }

  static String _onNewLine(String text) =>
      text.isEmpty || text.endsWith('\n') ? '' : '\n';

  /// Public assistant text of the stored child conversation. The first user
  /// row is the delegated goal prompt and stays out of the live log.
  static String _publicHistory(List<DesktopSessionMessage> messages) {
    final parts = <String>[];
    for (final message in messages) {
      if (message.role != DesktopSessionMessageRole.assistant ||
          !message.publiclyRenderable) {
        continue;
      }
      final raw =
          message.text ??
          (message.content is String ? message.content as String : '');
      final text = finalizedPublicAssistantText(raw).trim();
      if (text.isNotEmpty) parts.add(text);
    }
    return parts.join('\n');
  }

  /// A tool's public name only; arguments and previews never reach the view.
  static String? _publicToolName(Object? raw) {
    if (raw is! String) return null;
    final name = raw.trim();
    if (name.isEmpty ||
        name.length > 80 ||
        name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return null;
    }
    return name;
  }
}
