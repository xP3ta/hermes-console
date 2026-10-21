// The live row of a running chat turn (Android 16 Live Update, an ongoing
// row with a bar below it).
//
// One row per chat while its turn runs: who works, the conversation, a timer,
// one activity line in plain words, a rail and the counts the turn has. It is
// silent; what makes sound is a request for the user or a failure, which are
// their own cards. Dart owns the copy, the lock-screen redaction and when the
// row exists; Kotlin (`HermesRichNotifications.postLiveUpdate`) only draws it.
import 'dart:async';

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
    lookupStrings(Locale(t.es ? 'es' : 'en')),
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

/// Live row copy (es/en), resolved without BuildContext like [NotifL10n].
extension LiveTurnCopy on NotifL10n {
  String _l(String esText, String enText) => es ? esText : enText;

  /// The activity line: one phase in plain words. A running tool whose name
  /// is known is worded by [liveToolLine] instead.
  String livePhase(LiveTurnPhase phase) => switch (phase) {
    LiveTurnPhase.thinking => _l('Pensando', 'Thinking'),
    LiveTurnPhase.responding => _l('Respondiendo', 'Responding'),
    LiveTurnPhase.compacting => _l('Compactando', 'Compacting'),
    LiveTurnPhase.waitingForYou => _l('Te espera', 'Waiting for you'),
    LiveTurnPhase.waitingForApproval => _l(
      'Espera tu permiso',
      'Waiting for approval',
    ),
    LiveTurnPhase.needsClarification => _l(
      'Tiene una pregunta',
      'Needs clarification',
    ),
    LiveTurnPhase.usingTool ||
    LiveTurnPhase.working => _l('Trabajando', 'Working'),
  };

  /// The status-bar chip: at most seven characters, or Android cuts it.
  String liveChip(LiveTurnPhase phase) => switch (phase) {
    LiveTurnPhase.thinking => _l('Piensa', 'Think'),
    LiveTurnPhase.responding => _l('Escribe', 'Reply'),
    LiveTurnPhase.compacting => _l('Resume', 'Compact'),
    LiveTurnPhase.waitingForYou => _l('Te toca', 'You'),
    LiveTurnPhase.waitingForApproval => _l('Permiso', 'Approve'),
    LiveTurnPhase.needsClarification => _l('Duda', 'Ask'),
    LiveTurnPhase.usingTool ||
    LiveTurnPhase.working => _l('Trabaja', 'Working'),
  };

  String liveTasks(int done, int total) =>
      _l('Tareas $done de $total', 'Tasks $done of $total');
  String liveSubagents(int n) => n == 1
      ? _l('1 subagente', '1 subagent')
      : _l('$n subagentes', '$n subagents');
  String liveTools(int n) => n == 1
      ? _l('1 herramienta', '1 tool')
      : _l('$n herramientas', '$n tools');

  /// Title when nothing may name the conversation (lock screen, hidden
  /// content, a turn only the background listener still watches).
  String liveWorkingTitle(String who) =>
      _l('$who está trabajando', '$who is working');
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
Map<String, Object?> liveTurnArgs(
  NotifL10n t,
  LiveTurnSnapshot turn, {
  required String who,
  String? iconPath,
  bool hideSensitive = false,
  Duration timeout = LiveTurnNotifications.rowLifetime,
}) {
  final tool = turn.tool?.trim() ?? '';
  final running = turn.phase == LiveTurnPhase.usingTool && tool.isNotEmpty;
  final phase = running
      ? liveToolLine(t, tool, isSkill: turn.toolIsSkill)
      : t.livePhase(turn.phase);
  final counts = <String>[
    if (turn.hasTasks) t.liveTasks(turn.tasksDone, turn.tasksTotal),
    if (turn.subagents > 0) t.liveSubagents(turn.subagents),
    if (turn.tools > 0) t.liveTools(turn.tools),
  ];
  // Counts are numbers only: they are as safe on the lock screen as the phase.
  final line = [phase, ...counts].join(' · ');
  // The lock screen says that it works, not which tool, connector or skill.
  final publicLine = [t.livePhase(turn.phase), ...counts].join(' · ');
  final named = turn.detailed && !hideSensitive && turn.title.trim().isNotEmpty;
  // Nothing but "it runs" is known: the name alone, not a sentence that only
  // repeats the line below it.
  final anonymous = turn.detailed ? t.liveWorkingTitle(who) : who;
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
    'title': named ? plainNotificationText(turn.title, max: 80) : anonymous,
    // With content hidden the row is as discreet as its lock-screen version.
    'text': hideSensitive ? publicLine : line,
    'bigText': hideSensitive ? publicLine : line,
    'subText': ?(named ? who : null),
    'shortText': t.liveChip(turn.phase),
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
    this.minInterval = const Duration(seconds: 1),
    this.renewAfter = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// A row left without updates for this long is withdrawn by Android.
  static const Duration rowLifetime = Duration(minutes: 30);

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

  /// The turn of [key] changed (null: it is not running any more).
  /// [show] is the tray policy for it right now; [hideSensitive] redacts.
  Future<void> update(
    String key,
    LiveTurnSnapshot? turn, {
    required bool show,
    bool hideSensitive = false,
  }) async {
    if (turn == null) {
      final row = _rows.remove(key);
      row?.timer?.cancel();
      await _withdraw(row);
      return;
    }
    final row = _rows.putIfAbsent(key, _LiveRow.new);
    row
      ..turn = turn
      ..show = show
      ..hideSensitive = hideSensitive;
    await _apply(key, row);
  }

  /// The tray policy changed (app sent to the background, another chat on
  /// screen): every row is posted or withdrawn again. [policy] answers
  /// whether the row of a turn may be shown.
  Future<void> refresh(
    bool Function(LiveTurnSnapshot turn) policy, {
    bool hideSensitive = false,
  }) async {
    for (final entry in _rows.entries.toList()) {
      final row = entry.value;
      final turn = row.turn;
      if (turn == null) continue;
      row
        ..show = policy(turn)
        ..hideSensitive = hideSensitive;
      await _apply(entry.key, row);
    }
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
    if (!row.show) {
      row.timer?.cancel();
      row.timer = null;
      await _withdraw(row);
      return;
    }
    final t = strings();
    final who = whoFor?.call(turn) ?? t.brand;
    final signature = Object.hash(turn, who, row.hideSensitive, t.es);
    final now = _now();
    final last = row.postedAt;
    final unchanged = row.postedTag != null && row.signature == signature;
    if (unchanged && now.difference(last!) < renewAfter) return;
    if (last != null && now.difference(last) < minInterval) {
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
      ..signature = signature;
    String? icon;
    try {
      icon = await iconFor?.call(turn);
    } catch (_) {}
    if (!identical(_rows[key], row) || !row.show) return;
    if (previousTag != null && previousTag != tag) {
      // The chat got its durable id mid-turn: its row moves with it.
      await _cancel(previousTag);
    }
    try {
      await sink.postLiveUpdate(
        liveTurnArgs(
          t,
          turn,
          who: who,
          iconPath: icon,
          hideSensitive: row.hideSensitive,
        ),
      );
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
      ..signature = null;
    await _cancel(tag);
  }

  Future<void> _cancel(String tag) async {
    try {
      await sink.cancel(id: RichNotificationIds.live, tag: tag);
    } catch (_) {}
  }
}

class _LiveRow {
  LiveTurnSnapshot? turn;
  bool show = false;
  bool hideSensitive = false;
  String? postedTag;
  DateTime? postedAt;
  int? signature;
  Timer? timer;
}
