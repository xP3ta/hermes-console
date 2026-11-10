// The live row of a running chat turn (Android 16 Live Update, an ongoing
// row with a bar below it).
//
// One row per chat while its turn runs: who works, the conversation, a timer,
// one activity line in plain words, a rail and the counts the turn has. It is
// silent; what makes sound is a request for the user or a failure, which are
// their own cards. Dart owns the copy, the lock-screen redaction and when the
// row exists; Kotlin (`HermesRichNotifications.postLiveUpdate`) only draws it.
import 'dart:async';
import 'dart:convert';

import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/session_live_status.dart';
import '../../models/tool_label.dart';
import 'notification_service.dart';
import 'notification_strings.dart';
import 'rich_notifications.dart';

/// What a running turn is doing, in the closed vocabulary of the row.
enum LiveTurnPhase {
  thinking,

  /// A tool runs. Its wording is the shared labeller's ([liveToolLine]).
  usingTool,
  responding,
  compacting,
  waitingForYou,
  waitingForApproval,
  needsClarification,

  /// The turn runs but nothing says what it does (only the background
  /// listener is alive, or another surface owns the detail).
  working,
}

/// A running tool in the words every other surface uses for it
/// (`tool_label.dart`, Desktop's phrases): «Ejecutando comando», never a
/// tool id and never a wording of this file. A skill is shown by its name.
String liveToolLine(NotifL10n t, String tool, {bool isSkill = false}) {
  final name = tool.trim();
  if (isSkill) return name;
  return toolOrSkillStepTitle(
    lookupStrings(Locale(t.lang)),
    name,
    running: true,
  );
}

/// The row's phase for a chat's own live status. [approvalPending] and
/// [clarifyPending] say what kind of answer a waiting turn needs.
LiveTurnPhase liveTurnPhaseOf(
  SessionLiveStatus status, {
  bool approvalPending = false,
  bool clarifyPending = false,
}) => switch (status.phase) {
  SessionLivePhase.waitingForUser =>
    approvalPending
        ? LiveTurnPhase.waitingForApproval
        : clarifyPending
        ? LiveTurnPhase.needsClarification
        : LiveTurnPhase.waitingForYou,
  SessionLivePhase.runningTool => LiveTurnPhase.usingTool,
  SessionLivePhase.responding => LiveTurnPhase.responding,
  SessionLivePhase.thinking => LiveTurnPhase.thinking,
  SessionLivePhase.compacting => LiveTurnPhase.compacting,
  _ => LiveTurnPhase.working,
};

/// Live row copy from the language catalogs, resolved without BuildContext like [NotifL10n].
extension LiveTurnCopy on NotifL10n {
  /// The activity line: one phase in plain words. A running tool whose name
  /// is known is worded by [liveToolLine] instead.
  String livePhase(LiveTurnPhase phase) => switch (phase) {
    LiveTurnPhase.thinking => message('livePhase'),
    LiveTurnPhase.responding => message('livePhase2'),
    LiveTurnPhase.compacting => message('livePhase3'),
    LiveTurnPhase.waitingForYou => message('livePhase4'),
    LiveTurnPhase.waitingForApproval => message('livePhase5'),
    LiveTurnPhase.needsClarification => message('livePhase6'),
    LiveTurnPhase.usingTool || LiveTurnPhase.working => message('livePhase7'),
  };

  /// The status-bar chip: at most seven characters, or Android cuts it.
  String liveChip(LiveTurnPhase phase) => switch (phase) {
    LiveTurnPhase.thinking => message('liveChip'),
    LiveTurnPhase.responding => message('liveChip2'),
    LiveTurnPhase.compacting => message('liveChip3'),
    LiveTurnPhase.waitingForYou => message('liveChip4'),
    LiveTurnPhase.waitingForApproval => message('liveChip5'),
    LiveTurnPhase.needsClarification => message('liveChip6'),
    LiveTurnPhase.usingTool || LiveTurnPhase.working => message('liveChip7'),
  };

  String liveTasks(int done, int total) =>
      message('liveTasks', {'done': done, 'total': total});
  String liveSubagents(int n) =>
      n == 1 ? message('liveSubagents') : message('liveSubagents2', {'n': n});
  String liveTools(int n) =>
      n == 1 ? message('liveTools') : message('liveTools2', {'n': n});

  /// Title when nothing may name the conversation (lock screen, hidden
  /// content).
  String liveWorkingTitle(String who) =>
      message('liveWorkingTitle', {'who': who});

  /// The background check could not reach the server several times in a
  /// row ([LiveTurnNotifications.offlineAfterFailures]): the row no longer
  /// claims a phase it cannot see, and says it keeps trying.
  String get liveOffline => message('liveOffline');

  /// Status-bar chip of [liveOffline]: at most seven characters.
  String get liveOfflineChip => message('liveOfflineChip');
}

/// How far the rail is while no task list measures the turn (out of 100).
int liveTurnRail(LiveTurnPhase phase) => switch (phase) {
  LiveTurnPhase.thinking || LiveTurnPhase.compacting => 30,
  LiveTurnPhase.usingTool || LiveTurnPhase.working => 52,
  LiveTurnPhase.waitingForYou ||
  LiveTurnPhase.waitingForApproval ||
  LiveTurnPhase.needsClarification => 62,
  LiveTurnPhase.responding => 78,
};

/// Everything the row shows about one running turn.
@immutable
class LiveTurnSnapshot {
  const LiveTurnSnapshot({
    required this.connId,
    required this.profile,
    required this.sessionId,
    required this.title,
    required this.phase,
    this.surface = NotificationChatSurface.normal,
    this.tasksDone = 0,
    this.tasksTotal = 0,
    this.subagents = 0,
    this.tools = 0,
    this.tool,
    this.toolIsSkill = false,
    this.startedAtMs,
    this.runId,
    this.readOnly = false,
    this.detailed = true,
  });

  final String connId;
  final String profile;

  /// The persisted identity of the chat (what an open of the row targets).
  final String sessionId;
  final String title;
  final NotificationChatSurface surface;
  final LiveTurnPhase phase;
  final int tasksDone;
  final int tasksTotal;
  final int subagents;
  final int tools;

  /// The tool running now, as the gateway registered it (a skill's own name
  /// when [toolIsSkill]).
  final String? tool;
  final bool toolIsSkill;
  final int? startedAtMs;

  /// Run id when the turn travels over the REST runs API.
  final String? runId;
  final bool readOnly;

  /// False when only the fact that the turn runs is known.
  final bool detailed;

  bool get hasTasks => tasksTotal > 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveTurnSnapshot &&
          connId == other.connId &&
          profile == other.profile &&
          sessionId == other.sessionId &&
          title == other.title &&
          surface == other.surface &&
          phase == other.phase &&
          tasksDone == other.tasksDone &&
          tasksTotal == other.tasksTotal &&
          subagents == other.subagents &&
          tools == other.tools &&
          tool == other.tool &&
          toolIsSkill == other.toolIsSkill &&
          startedAtMs == other.startedAtMs &&
          runId == other.runId &&
          readOnly == other.readOnly &&
          detailed == other.detailed;

  @override
  int get hashCode => Object.hash(
    connId,
    profile,
    sessionId,
    title,
    surface,
    phase,
    tasksDone,
    tasksTotal,
    subagents,
    tools,
    tool,
    toolIsSkill,
    startedAtMs,
    runId,
    readOnly,
    detailed,
  );
}

/// Tray address of a chat's rows: the live row and, when the turn ends, its
/// result share the tag, so one takes the other's place.
String liveTurnTag(LiveTurnSnapshot turn) {
  if (turn.surface == NotificationChatSurface.bot) {
    return RichNotificationIds.botTag(turn.connId, turn.profile);
  }
  // The owner as the chat's cards spell it, so they share the address.
  final owner = turn.profile.trim().toLowerCase();
  return RichNotificationIds.chatTag(
    turn.connId,
    owner.isEmpty ? 'default' : owner,
    turn.sessionId,
  );
}

/// Pure builder of the `postLiveUpdate` arguments of a chat turn.
///
/// [offline]: the background check failed to reach the server
/// [LiveTurnNotifications.offlineAfterFailures] times in a row, so the row
/// says so instead of repeating the last phase. A check that is only
/// pending (the socket was cut, the next read is due) keeps the last real
/// state: the phase, the counts and the elapsed time.
Map<String, Object?> liveTurnArgs(
  NotifL10n t,
  LiveTurnSnapshot turn, {
  required String who,
  String? iconPath,
  bool hideSensitive = false,
  bool offline = false,
  Duration timeout = LiveTurnNotifications.rowLifetime,
}) {
  final tool = turn.tool?.trim() ?? '';
  final running = turn.phase == LiveTurnPhase.usingTool && tool.isNotEmpty;
  final phase = running
      ? liveToolLine(t, tool, isSkill: turn.toolIsSkill)
      : t.livePhase(turn.phase);
  // Last known counts would read as current: an offline row shows none.
  final counts = offline
      ? const <String>[]
      : <String>[
          if (turn.hasTasks) t.liveTasks(turn.tasksDone, turn.tasksTotal),
          if (turn.subagents > 0) t.liveSubagents(turn.subagents),
          if (turn.tools > 0) t.liveTools(turn.tools),
        ];
  // Counts are numbers only: they are as safe on the lock screen as the phase.
  final line = offline ? t.liveOffline : [phase, ...counts].join(' · ');
  // The lock screen says that it works, not which tool, connector or skill.
  final publicLine = offline
      ? t.liveOffline
      : [t.livePhase(turn.phase), ...counts].join(' · ');
  final named = turn.detailed && !hideSensitive && turn.title.trim().isNotEmpty;
  // Nothing but "it runs" is known: the name alone, not a sentence that only
  // repeats the line below it.
  // Offline, «X is working» would claim what the app can no longer see.
  final anonymous = turn.detailed && !offline ? t.liveWorkingTitle(who) : who;
  final open = NotificationOpen(
    connId: turn.connId,
    sessionId: turn.sessionId,
    title: turn.title,
    profile: turn.profile.isEmpty || turn.profile == 'default'
        ? null
        : turn.profile,
    surface: turn.surface,
  );
  final stop = turn.readOnly
      ? null
      : NotificationActionPayload(
          route: NotificationActionRoute.session,
          connId: turn.connId,
          profile: turn.profile.isEmpty ? null : turn.profile,
          sessionId: turn.sessionId,
          runId: turn.runId,
        );
  return {
    'id': RichNotificationIds.live,
    'tag': liveTurnTag(turn),
    // Which chat the row is about, also for a bot row whose tag names only
    // the bot: the background check finds the row's chat by it natively.
    'sessionId': turn.sessionId,
    'title': named ? plainNotificationText(turn.title, max: 80) : anonymous,
    // With content hidden the row is as discreet as its lock-screen version.
    'text': hideSensitive ? publicLine : line,
    'bigText': hideSensitive ? publicLine : line,
    'subText': ?(named ? who : null),
    'shortText': offline ? t.liveOfflineChip : t.liveChip(turn.phase),
    'startedAtMs': ?turn.startedAtMs,
    // A list measures the turn: one segment per task. Without one the rail
    // only follows the phase.
    'progressMax': turn.hasTasks ? turn.tasksTotal : 100,
    'progress': turn.hasTasks
        ? turn.tasksDone.clamp(0, turn.tasksTotal)
        : liveTurnRail(turn.phase),
    // More tasks than fit as segments: one continuous bar, still exact.
    if (turn.hasTasks && turn.tasksTotal <= 12) 'segments': turn.tasksTotal,
    // Bound to this engine: nobody else can update or end it.
    'ownerBound': true,
    'largeIconPath': ?iconPath,
    'trackerIconPath': ?iconPath,
    'stopLabel': ?(stop == null ? null : t.actStopTurn),
    'actionPayload': ?stop?.encode(),
    'openPayload': open.toPayload(),
    'timeoutMs': timeout.inMilliseconds,
    'accent': RichAccent.working,
    // A tap on Stop already changed the row: do not draw over it.
    'yieldToActions': true,
    // Lock screen: who and the state, never the conversation.
    'publicTitle': anonymous,
    'publicText': publicLine,
  };
}

/// Posts, updates and withdraws the live rows of this process's chat turns.
///
/// Rows are posted only when they change, never more often than
/// [minInterval] per chat (Android drops faster updates), and renewed when
/// an event arrives after [renewAfter] so a row whose process died expires
/// on its own instead of claiming work forever.
class LiveTurnNotifications {
  LiveTurnNotifications({
    required this.sink,
    required this.strings,
    this.whoFor,
    this.iconFor,
    Duration minInterval = const Duration(seconds: 5),
    this.renewAfter = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : minInterval = minInterval < const Duration(seconds: 5)
           ? const Duration(seconds: 5)
           : minInterval,
       _now = now ?? DateTime.now;

  /// A row left without updates for this long is withdrawn by Android.
  static const Duration rowLifetime = Duration(minutes: 30);

  /// Background checks in a row that must fail to reach the server before
  /// the row says «Sin conexión · reintentando…». One failure is a blip (a
  /// radio waking up, a slow tunnel); until then the row shows the last
  /// state the app really saw.
  static const int offlineAfterFailures = 2;

  /// Lifetime of a row posted while the app is in the background. There the
  /// socket is parked (or cut by Android within seconds) and no event renews
  /// the row: it lives a bounded while longer than the background check
  /// (`LiveTurnCheckPolicy.window`) and then leaves on its own, even if the
  /// process is frozen and the check could not end it.
  static const Duration backgroundRowLifetime = Duration(minutes: 12);

  final RichNotificationSink sink;
  final NotifL10n Function() strings;

  /// Display name of the agent of a turn (the Bot, or the brand).
  final String Function(LiveTurnSnapshot turn)? whoFor;

  /// Face of the agent of a turn; null draws the neutral mark.
  final Future<String?> Function(LiveTurnSnapshot turn)? iconFor;
  final Duration minInterval;
  final Duration renewAfter;
  final DateTime Function() _now;

  final Map<String, _LiveRow> _rows = {};

  /// Keys with a row currently in the tray.
  Set<String> get shownKeys => {
    for (final e in _rows.entries)
      if (e.value.postedTag != null) e.key,
  };

  /// The turns whose row is in the tray now.
  List<LiveTurnSnapshot> get shownTurns => [
    for (final row in _rows.values)
      if (row.postedTag != null && row.turn != null) row.turn!,
  ];

  /// The turn of [key] changed (null: it is not running any more).
  /// [show] is the tray policy for it right now; [hideSensitive] redacts;
  /// [background]: the app is in the background (bounded row lifetime).
  Future<void> update(
    String key,
    LiveTurnSnapshot? turn, {
    required bool show,
    bool hideSensitive = false,
    bool background = false,
  }) async {
    if (turn == null) {
      final row = _rows.remove(key);
      row?.timer?.cancel();
      await _withdraw(row);
      return;
    }
    final row = _rows.putIfAbsent(key, _LiveRow.new);
    final previous = row.turn;
    // A changed turn is news from the socket: the row sees the turn again.
    if (previous != null && previous != turn) {
      row
        ..offline = false
        ..failedChecks = 0;
    }
    // Another turn of the chat began: what ended the old one does not apply.
    if (row.settled && turn.startedAtMs != row.settledStartedAtMs) {
      row
        ..settled = false
        ..settledStartedAtMs = null;
    } else if (row.settled &&
        previous != null &&
        _liveTurnProgressed(previous, turn)) {
      // The same turn moved on (a new phase, another tool or task, the chat's
      // new id after a compression): the chat's socket sees it running, so
      // what ended it was wrong (a stale notice, the old id's end). It is
      // drawn again.
      row
        ..settled = false
        ..settledStartedAtMs = null;
    }
    row
      ..turn = turn
      ..show = show
      ..hideSensitive = hideSensitive
      ..background = background;
    await _apply(key, row);
  }

  /// The tray policy changed (app sent to the background, another chat on
  /// screen): every row is posted or withdrawn again. [policy] answers
  /// whether the row of a turn may be shown. Back in the foreground the
  /// chats reconcile their sockets, so no row stays marked offline.
  Future<void> refresh(
    bool Function(LiveTurnSnapshot turn) policy, {
    bool hideSensitive = false,
    bool background = false,
  }) async {
    for (final entry in _rows.entries.toList()) {
      final row = entry.value;
      final turn = row.turn;
      if (turn == null) continue;
      row
        ..show = policy(turn)
        ..hideSensitive = hideSensitive
        ..background = background;
      if (!background) {
        row
          ..offline = false
          ..failedChecks = 0;
      }
      await _apply(entry.key, row);
    }
  }

  /// Something other than the chat's own socket (the background check)
  /// says the turn of [sessionId] is over: its row leaves the tray
  /// and that same turn is not posted again, even if the chat, still
  /// unaware, reports it unchanged. [endedAtMs] (when the end was stamped)
  /// keeps a late notice from ending a turn that began after it. Returns
  /// how many rows were withdrawn.
  Future<int> settle(String sessionId, {int? endedAtMs}) async {
    final id = sessionId.trim();
    if (id.isEmpty) return 0;
    var withdrawn = 0;
    for (final row in _rows.values.toList()) {
      final turn = row.turn;
      if (turn == null || turn.sessionId != id) continue;
      final started = turn.startedAtMs;
      // Only a turn that began before the end: no tolerance, so the end of
      // one turn never takes the row of the next one, even a second later
      // (a turn lasts seconds; phone and server clocks differ by less).
      if (endedAtMs != null && started != null && started >= endedAtMs) {
        continue;
      }
      row
        ..settled = true
        ..settledStartedAtMs = started
        ..failedChecks = 0;
      row.timer?.cancel();
      row.timer = null;
      if (row.postedTag != null) withdrawn++;
      await _withdraw(row);
    }
    return withdrawn;
  }

  /// A background check could not reach the server about the turn of
  /// [sessionId] (no network, timeout, refused). The row keeps its last real
  /// state until this happened [offlineAfterFailures] times in a row; then
  /// it says «Sin conexión · reintentando…», at once. Returns how many rows
  /// turned offline now.
  Future<int> checkFailed(String sessionId) async {
    var marked = 0;
    for (final entry in _rows.entries.toList()) {
      final row = entry.value;
      if (!_checkedRow(row, sessionId)) continue;
      row.failedChecks++;
      if (row.offline || row.failedChecks < offlineAfterFailures) continue;
      row.offline = true;
      marked++;
      await _apply(entry.key, row);
    }
    return marked;
  }

  /// A background check reached the server about the turn of [sessionId]
  /// and found it still running (or could not tell): the failure count
  /// starts again and an offline row returns to its last real state, at
  /// once. Returns how many rows came back.
  Future<int> checkReached(String sessionId) async {
    var restored = 0;
    for (final entry in _rows.entries.toList()) {
      final row = entry.value;
      if (!_checkedRow(row, sessionId)) continue;
      row.failedChecks = 0;
      if (!row.offline) continue;
      row.offline = false;
      restored++;
      await _apply(entry.key, row);
    }
    return restored;
  }

  bool _checkedRow(_LiveRow row, String sessionId) {
    final id = sessionId.trim();
    return id.isNotEmpty &&
        row.turn?.sessionId == id &&
        row.postedTag != null &&
        !row.settled;
  }

  /// Withdraws every row (the service is going away).
  Future<void> clear() async {
    final rows = _rows.values.toList();
    _rows.clear();
    for (final row in rows) {
      row.timer?.cancel();
      await _withdraw(row);
    }
  }

  Future<void> _apply(String key, _LiveRow row) async {
    final turn = row.turn;
    if (turn == null) return;
    // A turn known to be over is never drawn as running again.
    if (!row.show || row.settled) {
      row.timer?.cancel();
      row.timer = null;
      await _withdraw(row);
      return;
    }
    final t = strings();
    final who = whoFor?.call(turn) ?? t.brand;
    final args = liveTurnArgs(
      t,
      turn,
      who: who,
      hideSensitive: row.hideSensitive,
      offline: row.offline,
      timeout: row.background ? backgroundRowLifetime : rowLifetime,
    );
    // Compare what Android draws, plus actions and destination. The title in
    // openPayload is navigation metadata; a hidden title is not presentation.
    final destination = jsonDecode(args['openPayload']! as String) as Map;
    destination.remove('title');
    final presentation = Map<String, Object?>.of(args)
      ..['openPayload'] = destination;
    final signature = jsonEncode(presentation);
    // The offline line and the lifetime are what keep the row honest when no
    // event follows: they go out at once, not after the rate window.
    final controls = jsonEncode([
      row.hideSensitive,
      row.offline,
      args['timeoutMs'],
      args['tag'],
      args['stopLabel'],
      args['actionPayload'],
      destination,
    ]);
    final immediate = row.controls != null && row.controls != controls;
    final now = _now();
    final last = row.postedAt;
    final unchanged = row.postedTag != null && row.signature == signature;
    if (!immediate && unchanged && now.difference(last!) < renewAfter) return;
    if (!immediate && last != null && now.difference(last) < minInterval) {
      // Too soon: the newest state goes out when the window ends.
      row.timer ??= Timer(minInterval - now.difference(last), () {
        row.timer = null;
        if (identical(_rows[key], row)) unawaited(_apply(key, row));
      });
      return;
    }
    row.timer?.cancel();
    row.timer = null;
    final tag = liveTurnTag(turn);
    final previousTag = row.postedTag;
    // Claimed before the first await: a second change arriving meanwhile
    // waits for the window instead of racing this post.
    row
      ..postedAt = now
      ..postedTag = tag
      ..signature = signature
      ..controls = controls;
    final revision = ++row.revision;
    String? icon;
    try {
      icon = await iconFor?.call(turn);
    } catch (_) {}
    if (!identical(_rows[key], row) ||
        !row.show ||
        row.settled ||
        row.revision != revision) {
      return;
    }
    if (previousTag != null && previousTag != tag) {
      // The chat got its durable id mid-turn: its row moves with it.
      await _cancel(previousTag);
    }
    if (!identical(_rows[key], row) ||
        !row.show ||
        row.settled ||
        row.revision != revision) {
      return;
    }
    // The rate limit measures publications, including time spent awaiting a face.
    row.postedAt = _now();
    try {
      await sink.postLiveUpdate({
        ...args,
        'largeIconPath': ?icon,
        'trackerIconPath': ?icon,
      });
    } catch (_) {
      // Best effort: the next change posts again.
      row.signature = null;
    }
  }

  Future<void> _withdraw(_LiveRow? row) async {
    final tag = row?.postedTag;
    if (row == null || tag == null) return;
    row
      ..postedTag = null
      ..postedAt = null
      ..signature = null
      ..controls = null;
    row.revision++;
    await _cancel(tag);
  }

  Future<void> _cancel(String tag) async {
    try {
      await sink.cancel(id: RichNotificationIds.live, tag: tag);
    } catch (_) {}
  }
}

/// Whether [next] is news of the same turn beyond [previous]: its phase,
/// tools, tasks or subagents moved, or the chat changed id. A new title or
/// the same report again is not.
bool _liveTurnProgressed(LiveTurnSnapshot previous, LiveTurnSnapshot next) =>
    previous.sessionId != next.sessionId ||
    previous.phase != next.phase ||
    previous.tools != next.tools ||
    previous.tool != next.tool ||
    previous.tasksDone != next.tasksDone ||
    previous.tasksTotal != next.tasksTotal ||
    previous.subagents != next.subagents;

class _LiveRow {
  LiveTurnSnapshot? turn;
  bool show = false;
  bool hideSensitive = false;
  bool background = false;

  /// [failedChecks] reached [LiveTurnNotifications.offlineAfterFailures]:
  /// the row says «no connection · retrying».
  bool offline = false;

  /// Background checks in a row that could not reach the server.
  int failedChecks = 0;

  /// The background check ended this turn ([settledStartedAtMs]
  /// is its start): the chat may still report it, the row stays withdrawn.
  bool settled = false;
  int? settledStartedAtMs;

  String? postedTag;
  DateTime? postedAt;
  String? signature;
  String? controls;
  int revision = 0;
  Timer? timer;
}
