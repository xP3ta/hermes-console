// The background check of a chat turn whose live row is in the tray while the
// app is in the background and its socket is gone.
//
// Android cuts the app's sockets seconds after it leaves the screen, so the
// live row («Pensando…») would keep claiming the last phase it saw until the
// app came back. `HermesLiveTurnCheckWorker` (Kotlin, WorkManager, bounded:
// [LiveTurnCheckPolicy]) wakes the engine that owns the row and asks it here
// what to do: never under App Lock (no chain is even scheduled), one bounded
// authenticated read of the chat's latest durable rows decides whether the
// turn is over. Meanwhile the row keeps the last state the app really saw;
// only reads that fail to reach the server
// [LiveTurnNotifications.offlineAfterFailures] times in a row make it say
// «Sin conexión · reintentando…», and the next read that reaches it brings
// the real state back. A finished turn is announced at once as «xPeta ·
// terminó» (the chat's title only when content may be shown); a failed one
// through the chat's error notice.
// Any doubt keeps checking: a running turn is never announced as finished.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/assistant_content.dart'
    show hasPrivateTranscriptClassifier, finalizedPublicAssistantText;
import '../../utils/chat_turn.dart' show isRealUserTurn;
import '../../utils/session_timestamp.dart';
import '../connection_manager.dart';
import 'live_turn_notifications.dart';
import 'notification_action_drain.dart' show loadConnectionsForActions;
import 'notification_preview.dart';
import 'rich_notifications.dart' show PlatformRichNotifications;
import 'session_attention.dart';

/// How long and how often the background check runs. Dart owns it; the
/// worker only follows `nextDelayMs`.
abstract final class LiveTurnCheckPolicy {
  /// The check never runs longer than this after the app left the screen
  /// (the battery bound: at most a dozen short reads per background period).
  static const Duration window = Duration(minutes: 10);

  /// First run after the app left the screen with a live row: soon enough that the end of a short turn is told within
  /// seconds of it. The app's own socket may still live a few seconds more
  /// (`chatTransportBackgroundGrace`, 30 s); a row its socket already ended
  /// is not in the tray, and one it ends while the read runs is not
  /// announced by the check.
  static const Duration firstDelay = Duration(seconds: 25);

  /// Then 20, 30 and every 45 s until [window].
  static const List<Duration> cadence = [
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(seconds: 45),
  ];

  /// Delay before the run after [attempt] (0 = the first run).
  static Duration delayAfter(int attempt) =>
      cadence[attempt.clamp(0, cadence.length - 1)];

  /// When the next run is due, or null when the chain ends (nothing pending,
  /// or the window would be passed).
  static Duration? next({
    required int attempt,
    required Duration elapsed,
    required int pending,
  }) {
    if (pending <= 0) return null;
    final delay = delayAfter(attempt);
    if (elapsed + delay > window) return null;
    return delay;
  }

  /// How long a read may take (each run, every chat).
  static const Duration readTimeout = Duration(seconds: 10);

  /// How long one run may spend reading, all chats together. The native
  /// worker waits 45 s for the answer and drops a later one without asking
  /// again, so a run answers well before that: chats past the budget are
  /// left for the next run.
  static const Duration runBudget = Duration(seconds: 30);

  /// Bytes one read may carry: the last rows, without inline images.
  static const int readMaxBytes = 256 * 1024;

  /// Rows read from the end of the transcript.
  static const int readRows = 12;

  /// Clock difference tolerated between this phone (the turn's start) and
  /// the server (the rows' timestamps).
  static const Duration skew = Duration(seconds: 5);
}

/// App Lock is on: the check never runs (nothing is scheduled, nothing read).
bool liveTurnAppLocked(SharedPreferences prefs) =>
    prefs.getBool('app_lock_enabled') ?? false;

enum LiveTurnRemoteState {
  /// The durable rows show the turn still open (or not yet saved).
  running,
  finished,
  failed,

  /// The rows cannot say (no read, no timestamps, no prompt in the window).
  unknown,
}

class LiveTurnRemoteOutcome {
  const LiveTurnRemoteOutcome(this.state, {this.preview = '', this.endedAtMs});

  static const unknown = LiveTurnRemoteOutcome(LiveTurnRemoteState.unknown);
  static const running = LiveTurnRemoteOutcome(LiveTurnRemoteState.running);

  final LiveTurnRemoteState state;

  /// First words of the final answer, already redacted ([notificationPreview]).
  final String preview;

  /// Server time of the final row.
  final int? endedAtMs;

  bool get over =>
      state == LiveTurnRemoteState.finished ||
      state == LiveTurnRemoteState.failed;
}

/// Whether the turn that started at [startedAtMs] (this phone's clock) is
/// over, from the latest durable rows of its chat in chronological order
/// (`GET /api/sessions/{id}/messages?order=latest`).
///
/// Over only with affirmative evidence: the newest real user row (event
/// notices and in-flight corrections do not open a turn) is this turn's
/// prompt (not older than its start), and the last assistant or tool row
/// after it is a final answer (no tool calls) or an error stamped no earlier
/// than the turn's start. The [skew] only places the prompt: an answer
/// before the start, or without a time, is the previous turn's (a reply
/// sent seconds after it) and keeps this one running. A prompt not yet
/// saved, a tool still pending or a row without a timestamp keeps it
/// running or unknown, never «finished».
LiveTurnRemoteOutcome liveTurnOutcomeOf(
  Object? messages, {
  required int? startedAtMs,
  Duration skew = LiveTurnCheckPolicy.skew,
}) {
  if (messages is! List || startedAtMs == null) {
    return LiveTurnRemoteOutcome.unknown;
  }
  final rows = [
    for (final row in messages)
      if (row is Map) Map<String, dynamic>.from(row),
  ];
  var user = -1;
  for (var i = rows.length - 1; i >= 0; i--) {
    if (isRealUserTurn(rows[i])) {
      user = i;
      break;
    }
  }
  if (user < 0) return LiveTurnRemoteOutcome.unknown;
  final promptAt = normalizeEpochTimestamp(rows[user]['timestamp']);
  if (promptAt == null) return LiveTurnRemoteOutcome.unknown;
  // The newest saved prompt is older than this turn: the turn's own rows
  // are not saved yet (Hermes writes them as the turn goes or at its end).
  if (promptAt * 1000 < startedAtMs - skew.inMilliseconds) {
    return LiveTurnRemoteOutcome.running;
  }
  Map<String, dynamic>? last;
  for (var i = rows.length - 1; i > user; i--) {
    final role = rows[i]['role'];
    if (role == 'assistant' || role == 'assistant_error' || role == 'tool') {
      last = rows[i];
      break;
    }
  }
  if (last == null || last['role'] == 'tool') {
    return LiveTurnRemoteOutcome.running;
  }
  final calls = last['tool_calls'];
  if (calls is List && calls.isNotEmpty) return LiveTurnRemoteOutcome.running;
  final endedAt = normalizeEpochTimestamp(last['timestamp']);
  // No margin here: within the skew the prompt found may be the previous
  // turn's, and so would be this answer.
  if (endedAt == null || endedAt * 1000 < startedAtMs) {
    return LiveTurnRemoteOutcome.running;
  }
  final failed =
      last['role'] == 'assistant_error' ||
      last['error'] == true ||
      (last['error'] is String && (last['error'] as String).trim().isNotEmpty) ||
      last['error_surface'] is Map ||
      last['is_error'] == true ||
      last['status'] == 'error' ||
      last['status'] == 'failed';
  return LiveTurnRemoteOutcome(
    failed ? LiveTurnRemoteState.failed : LiveTurnRemoteState.finished,
    preview: failed ? '' : _publicPreview(last),
    endedAtMs: (endedAt * 1000).round(),
  );
}

String _publicPreview(Map<String, dynamic> row) {
  if (row['display_kind'] == 'hidden' || hasPrivateTranscriptClassifier(row)) {
    return '';
  }
  final content = row['display_content'] ?? row['content'];
  final text = content is String
      ? content
      : content is List
      ? content
            .whereType<Map>()
            .where(
              (p) =>
                  (p['type'] == 'text' || p['type'] == 'output_text') &&
                  !hasPrivateTranscriptClassifier(Map<String, dynamic>.from(p)),
            )
            .map((p) => p['text'])
            .whereType<String>()
            .join('\n')
      : '';
  return notificationPreview(finalizedPublicAssistantText(text));
}

/// What one run of the check did.
class LiveTurnCheckPass {
  const LiveTurnCheckPass({
    required this.pending,
    this.ended = const [],
    this.reached = const {},
    this.unreachable = const {},
  });

  /// Turns still worth another run.
  final int pending;

  /// Sessions whose read reached the server and found the turn still running
  /// (or could not tell): their rows show the real state again.
  final Set<String> reached;

  /// Sessions whose read failed to reach the server (no network, timeout,
  /// refused). A chat left for the next run (out of budget) is in neither.
  final Set<String> unreachable;

  /// Sessions whose turn this run found over (and announced).
  final List<String> ended;
}

/// One run of the check over the turns whose rows are in the tray.
class LiveTurnBackgroundCheck {
  LiveTurnBackgroundCheck({
    required this.read,
    required this.appLocked,
    required this.deliver,
    this.budget = LiveTurnCheckPolicy.runBudget,
    this.readTimeout = LiveTurnCheckPolicy.readTimeout,
  });

  /// Reading time of one run, all chats together ([LiveTurnCheckPolicy]).
  final Duration budget;

  /// Longest single read.
  final Duration readTimeout;

  /// The chat's latest durable rows (`messages`), or a throw.
  final Future<Object?> Function(LiveTurnSnapshot turn) read;

  /// App Lock is on: nothing is asked of the server.
  final bool Function() appLocked;

  /// Posts the end of a turn (settings, hidden content).
  final Future<void> Function(SessionAttentionSignal signal) deliver;

  /// [attempt] rotates where the run starts, so a chat whose reads always
  /// time out cannot keep the others past the budget run after run.
  Future<LiveTurnCheckPass> run(
    List<LiveTurnSnapshot> turns, {
    int attempt = 0,
  }) async {
    if (turns.isEmpty) return const LiveTurnCheckPass(pending: 0);
    if (appLocked()) {
      // The row's own bounded lifetime ends it. No request is made.
      return const LiveTurnCheckPass(pending: 0);
    }
    var pending = 0;
    final ended = <String>[];
    final reached = <String>{};
    final unreachable = <String>{};
    final clock = Stopwatch()..start();
    final first = attempt <= 0 ? 0 : attempt % turns.length;
    for (var i = 0; i < turns.length; i++) {
      final turn = turns[(first + i) % turns.length];
      final left = budget - clock.elapsed;
      if (left <= Duration.zero) {
        // Out of time this run: the next one reads it.
        pending++;
        continue;
      }
      final limit = left < readTimeout ? left : readTimeout;
      Object? rows;
      try {
        rows = await read(turn).timeout(limit);
      } on Object {
        // No network, refused transport, expired credentials: ask later.
        unreachable.add(turn.sessionId);
        pending++;
        continue;
      }
      final outcome = liveTurnOutcomeOf(rows, startedAtMs: turn.startedAtMs);
      if (!outcome.over) {
        reached.add(turn.sessionId);
        pending++;
        continue;
      }
      final owner = turn.profile.trim().toLowerCase();
      await deliver(
        SessionAttentionSignal(
          kind: outcome.state == LiveTurnRemoteState.failed
              ? SessionAttentionKind.turnError
              : SessionAttentionKind.turnDone,
          connId: turn.connId,
          profile: owner.isEmpty ? 'default' : owner,
          storedSessionId: turn.sessionId,
          title: turn.title,
          preview: outcome.preview,
          endedAtMs: outcome.endedAtMs,
          backgroundCheck: true,
        ),
      );
      ended.add(turn.sessionId);
    }
    return LiveTurnCheckPass(
      pending: pending,
      ended: ended,
      reached: reached,
      unreachable: unreachable,
    );
  }

  /// The production check of the UI engine: saved credentials, one bounded
  /// read per chat (`notificationRead`: TLS, loopback or a live tunnel only).
  static LiveTurnBackgroundCheck platform(
    SharedPreferences prefs, {
    required Future<void> Function(SessionAttentionSignal signal) deliver,
  }) {
    Future<List<SavedConnection>>? connections;
    return LiveTurnBackgroundCheck(
      appLocked: () => liveTurnAppLocked(prefs),
      deliver: deliver,
      read: (turn) async {
        final all = await (connections ??= loadConnectionsForActions(prefs));
        final connection = all.where((c) => c.id == turn.connId).firstOrNull;
        if (connection == null) throw StateError('connection');
        final profile = turn.profile.trim();
        final query = Uri(
          queryParameters: {
            'limit': '${LiveTurnCheckPolicy.readRows}',
            'order': 'latest',
            'inline_images': 'false',
            if (profile.isNotEmpty) 'profile': profile,
          },
        ).query;
        final client = DashboardClient.lazy(connection);
        try {
          final data = await client.notificationRead(
            'sessions/${Uri.encodeComponent(turn.sessionId)}/messages?$query',
            timeout: LiveTurnCheckPolicy.readTimeout,
            maxBytes: LiveTurnCheckPolicy.readMaxBytes,
          );
          return data['messages'] ?? data['data'];
        } finally {
          client.close();
        }
      },
    );
  }
}

/// Schedules the native worker of the background check (faked in tests).
abstract interface class LiveTurnCheckScheduler {
  /// Starts a chain unless one is already pending (first run after [delay]).
  Future<void> schedule(Duration delay);

  /// The app is in front again: the chain ends.
  Future<void> cancel();
}

/// `scheduleLiveTurnCheck` / `cancelLiveTurnCheck` on the rich channel.
class PlatformLiveTurnCheckScheduler implements LiveTurnCheckScheduler {
  const PlatformLiveTurnCheckScheduler();

  static const MethodChannel _channel = MethodChannel(
    PlatformRichNotifications.channelName,
  );

  Future<void> _call(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      // Tests, iOS, an older native side: the row's own lifetime applies.
    } on PlatformException {
      // Best effort, as every rich notification call.
    }
  }

  @override
  Future<void> schedule(Duration delay) =>
      _call('scheduleLiveTurnCheck', {'delayMs': delay.inMilliseconds});

  @override
  Future<void> cancel() => _call('cancelLiveTurnCheck');
}
