// What a launcher widget says, before it is drawn: one scene per subject,
// built from the snapshots and local roster the app already publishes.
// Pure data, no canvas,
// no strings of its own (the words come in through [LwWords]).
//
// Privacy: a scene never carries more than the native widgets showed. The
// chat snapshot's `need.text` is already null when the owner hides sensitive
// content; the Chats list's `line` likewise. Nothing here reads a chat body.
import '../../models/home_widget_snapshot.dart';
import '../../models/launcher_widget_chats.dart';
import '../../models/launcher_widget_cron.dart';
import '../../models/launcher_widget_tasks.dart';
import 'launcher_widget_geometry.dart';
import 'launcher_widget_identity.dart';

/// The subjects of the launcher widgets (one receiver each on Android).
enum LwSubject {
  ahora,
  chats,
  cron,
  tasks,
  newChat;

  /// The key Android and Dart both use for this subject.
  String get key => switch (this) {
    LwSubject.ahora => 'ahora',
    LwSubject.chats => 'chats',
    LwSubject.cron => 'cron',
    LwSubject.tasks => 'tasks',
    LwSubject.newChat => 'new',
  };

  static LwSubject? byKey(String key) {
    for (final subject in values) {
      if (subject.key == key) return subject;
    }
    return null;
  }
}

/// The mood of a widget: what state of the world it draws.
enum LwMood { setup, offline, need, work, calm, empty }

/// Snapshot age from which a section is drawn as "last known", in ms. The
/// same window the native readers use.
const lwStaleAfterMs = 15 * 60 * 1000;

/// The legacy name fallback when no roster is available.
String displayName(String profile) {
  final trimmed = profile.trim();
  if (trimmed.isEmpty) return trimmed;
  return trimmed[0].toUpperCase() + trimmed.substring(1);
}

/// A face to draw: the profile it belongs to decides its look.
class LwFace {
  const LwFace(this.profile, {this.name});
  final String profile;
  final String? name;
}

/// Something waiting for the owner.
class LwNeed {
  const LwNeed({
    required this.who,
    required this.profile,
    required this.what,
    required this.question,
    required this.sinceMs,
    required this.open,
    this.answerPayload,
  });

  final String who;
  final String profile;

  /// What is asked, one line; null when it is hidden or unknown.
  final String? what;
  final bool question;
  final int sinceMs;
  final LwOpen open;

  /// Payload of Allow / Deny; null when it can only be answered in the app.
  final String? answerPayload;
}

/// Something running right now.
class LwRun {
  const LwRun({
    required this.who,
    required this.profile,
    required this.phase,
    required this.about,
    required this.sinceMs,
    required this.open,
  });
  final String who;
  final String profile;
  final String phase;
  final String? about;
  final int sinceMs;
  final LwOpen open;
}

/// Where a tap goes, in data (the painter turns it into an [LwTapZone]).
class LwOpen {
  const LwOpen.app()
    : kind = LwActionKind.app,
      payload = null,
      instanceId = null,
      sessionId = null;
  const LwOpen.setup()
    : kind = LwActionKind.setup,
      payload = null,
      instanceId = null,
      sessionId = null;
  const LwOpen.session(this.instanceId, this.sessionId)
    : kind = LwActionKind.session,
      payload = null;
  const LwOpen.payload(this.payload)
    : kind = LwActionKind.payload,
      instanceId = null,
      sessionId = null;

  final LwActionKind kind;
  final String? payload;
  final String? instanceId;
  final String? sessionId;
}

/// Ahora: who needs you, what runs, calm.
class LwAhoraScene {
  const LwAhoraScene({
    required this.mood,
    this.instanceLabel,
    this.needs = const [],
    this.runs = const [],
    this.faces = const [],
    this.lastTitle,
    this.lastAtMs,
    this.sinceMs = 0,
    this.agentName = '',
    this.agentProfile = 'default',
  });

  final LwMood mood;
  final String? instanceLabel;
  final List<LwNeed> needs;
  final List<LwRun> runs;

  /// Faces of the agents around (calm state).
  final List<LwFace> faces;

  /// The last conversation that spoke, and when.
  final String? lastTitle;
  final int? lastAtMs;

  /// When the chat snapshot was written: OFFLINE says "since" it, and
  /// every state turns old (and its picture expires) from it.
  final int sinceMs;
  final String agentName;
  final String agentProfile;

  /// The chat the whole card opens.
  LwOpen get open => needs.isNotEmpty
      ? needs.first.open
      : runs.isNotEmpty
      ? runs.first.open
      : mood == LwMood.setup
      ? const LwOpen.setup()
      : const LwOpen.app();

  static LwAhoraScene from(
    HermesHomeWidgetSnapshot chat, {
    required int nowMs,
    required String agentName,
    List<LauncherWidgetChat> recentChats = const [],
    bool answersAllowed = true,
  }) {
    final configured = chat.configured && chat.instanceId != null;
    if (!configured) return const LwAhoraScene(mood: LwMood.setup);
    final stale =
        chat.updatedAtMs <= 0 || nowMs - chat.updatedAtMs > lwStaleAfterMs;
    final online =
        !stale &&
        (chat.connectionState == HomeWidgetConnectionState.connected ||
            chat.connectionState == HomeWidgetConnectionState.connecting);
    final lastAt = chat.lastActivityAtMs;
    final last = chat.sessionTitle;
    agentName = lwProfileName(chat.instanceId, 'default', fallback: agentName);
    final faces = <LwFace>[];
    final seen = <String>{};
    for (final c in recentChats) {
      final p = c.profile ?? 'default';
      if (seen.add(p)) {
        faces.add(LwFace(p, name: lwProfileName(chat.instanceId, p)));
      }
      if (faces.length == 4) break;
    }
    if (faces.isEmpty) faces.add(LwFace('default', name: agentName));
    if (!online) {
      return LwAhoraScene(
        mood: LwMood.offline,
        instanceLabel: chat.instanceLabel,
        lastTitle: last,
        lastAtMs: lastAt,
        sinceMs: chat.updatedAtMs,
        faces: faces,
        agentName: agentName,
      );
    }
    final needs = <LwNeed>[];
    final runs = <LwRun>[];
    for (final activity in chat.active) {
      final profile = activity.profile ?? 'default';
      final open = LwOpen.session(chat.instanceId, activity.sessionId);
      final who = lwProfileName(
        chat.instanceId,
        profile,
        fallback: profile == 'default' ? agentName : displayName(profile),
      );
      if (activity.needsYou) {
        final need = activity.need;
        needs.add(
          LwNeed(
            who: who,
            profile: profile,
            what: need?.text ?? activity.title,
            question: need?.question ?? false,
            sinceMs: activity.startedAtMs ?? 0,
            open: open,
            answerPayload: answersAllowed ? need?.actionPayload : null,
          ),
        );
      } else {
        runs.add(
          LwRun(
            who: who,
            profile: profile,
            phase: activity.state == HomeWidgetAgentState.toolExecution
                ? (activity.phase ?? '')
                : activity.state.name,
            about: activity.title,
            sinceMs: activity.startedAtMs ?? 0,
            open: open,
          ),
        );
      }
    }
    if (chat.active.isEmpty) {
      // A snapshot of schema 1 lists no activity: only what the last chat
      // does is known. In schema 2 an empty list with a live agent state
      // reads the same way.
      final open = chat.sessionId == null
          ? const LwOpen.app()
          : LwOpen.session(chat.instanceId, chat.sessionId!);
      switch (chat.agentState) {
        case HomeWidgetAgentState.waitingApproval:
          needs.add(
            LwNeed(
              who: agentName,
              profile: 'default',
              what: last,
              question: false,
              sinceMs: 0,
              open: open,
            ),
          );
        case HomeWidgetAgentState.thinking:
        case HomeWidgetAgentState.streaming:
        case HomeWidgetAgentState.toolExecution:
          runs.add(
            LwRun(
              who: agentName,
              profile: 'default',
              phase: chat.agentState == HomeWidgetAgentState.toolExecution
                  ? (chat.toolName ?? '')
                  : chat.agentState.name,
              about: last,
              sinceMs: 0,
              open: open,
            ),
          );
        default:
          break;
      }
    }
    return LwAhoraScene(
      mood: needs.isNotEmpty
          ? LwMood.need
          : runs.isNotEmpty
          ? LwMood.work
          : LwMood.calm,
      instanceLabel: chat.instanceLabel,
      needs: needs,
      runs: runs,
      faces: faces,
      lastTitle: last,
      lastAtMs: lastAt,
      sinceMs: chat.updatedAtMs,
      agentName: agentName,
    );
  }
}

/// One row of the Chats widget.
class LwChatRow {
  const LwChatRow({
    required this.title,
    required this.profile,
    required this.open,
    this.who,
    this.line,
    this.atMs,
    this.waits = false,
    this.running = false,
  });
  final String title;
  final String? who;
  final String profile;
  final LwOpen open;
  final String? line;
  final int? atMs;
  final bool waits;
  final bool running;
}

class LwChatsScene {
  const LwChatsScene({
    required this.mood,
    this.rows = const [],
    this.sinceMs = 0,
    this.waiting = 0,
    this.running = 0,
  });
  final LwMood mood;
  final List<LwChatRow> rows;
  final int sinceMs;
  final int waiting;
  final int running;

  static LwChatsScene from(
    LauncherWidgetChatsSnapshot? list,
    HermesHomeWidgetSnapshot chat, {
    required int nowMs,
  }) {
    if (list == null) return const LwChatsScene(mood: LwMood.setup);
    final stale =
        list.updatedAtMs <= 0 || nowMs - list.updatedAtMs > lwStaleAfterMs;
    // What runs is the chat's instance; after a switch the list can be
    // another instance's, whose session ids say nothing here (the native
    // renderer's `sameInstance`).
    final chatFresh =
        chat.updatedAtMs > 0 &&
        nowMs - chat.updatedAtMs <= lwStaleAfterMs &&
        chat.instanceId != null &&
        chat.instanceId == list.connectionId &&
        (chat.connectionState == HomeWidgetConnectionState.connected ||
            chat.connectionState == HomeWidgetConnectionState.connecting);
    final live = <String, HomeWidgetChatActivity>{
      if (chatFresh)
        for (final a in chat.active) a.sessionId: a,
    };
    final rows = <LwChatRow>[];
    for (final c in list.chats) {
      final a = live[c.id];
      rows.add(
        LwChatRow(
          title: c.title,
          profile: c.profile ?? 'default',
          who: lwProfileName(list.connectionId, c.profile ?? 'default'),
          open: LwOpen.session(list.connectionId, c.id),
          line: c.line,
          atMs: c.atMs,
          waits: a?.needsYou ?? false,
          running: a != null && !a.needsYou,
        ),
      );
    }
    rows.sort((a, b) {
      int rank(LwChatRow r) => r.waits
          ? 0
          : r.running
          ? 1
          : 2;
      return rank(a).compareTo(rank(b));
    });
    if (rows.isEmpty) {
      return LwChatsScene(
        mood: stale ? LwMood.offline : LwMood.empty,
        sinceMs: list.updatedAtMs,
      );
    }
    return LwChatsScene(
      mood: stale ? LwMood.offline : LwMood.calm,
      rows: rows,
      sinceMs: list.updatedAtMs,
      waiting: rows.where((r) => r.waits).length,
      running: rows.where((r) => r.running).length,
    );
  }
}

class LwCronJobView {
  const LwCronJobView(this.job, this.open, {this.who});
  final String? who;
  final LauncherWidgetCronJob job;
  final LwOpen open;
}

class LwCronScene {
  const LwCronScene({
    required this.mood,
    this.jobs = const [],
    this.sinceMs = 0,
  });
  final LwMood mood;

  /// By next run: the ones still to run, soonest first; then the rest.
  final List<LwCronJobView> jobs;
  final int sinceMs;

  static LwCronScene from(
    LauncherWidgetCronSnapshot? cron, {
    required int nowMs,
  }) {
    if (cron == null) return const LwCronScene(mood: LwMood.setup);
    final stale =
        cron.updatedAtMs <= 0 || nowMs - cron.updatedAtMs > lwStaleAfterMs;
    final ahead = <LauncherWidgetCronJob>[];
    final rest = <LauncherWidgetCronJob>[];
    for (final job in cron.jobs) {
      ((job.nextRunAtMs ?? 0) > nowMs ? ahead : rest).add(job);
    }
    ahead.sort((a, b) => a.nextRunAtMs!.compareTo(b.nextRunAtMs!));
    rest.sort((a, b) => (b.nextRunAtMs ?? 0).compareTo(a.nextRunAtMs ?? 0));
    final jobs = [
      for (final job in [...ahead, ...rest])
        LwCronJobView(
          job,
          job.openPayload == null
              ? const LwOpen.app()
              : LwOpen.payload(job.openPayload),
          who: lwProfileName(cron.connectionId, job.profile),
        ),
    ];
    if (jobs.isEmpty) {
      return LwCronScene(
        mood: stale ? LwMood.offline : LwMood.empty,
        sinceMs: cron.updatedAtMs,
      );
    }
    return LwCronScene(
      mood: stale ? LwMood.offline : LwMood.calm,
      jobs: jobs,
      sinceMs: cron.updatedAtMs,
    );
  }
}

class LwTasksScene {
  const LwTasksScene({
    required this.mood,
    this.running = 0,
    this.attention = 0,
    this.pending = 0,
    this.first,
    this.firstAssignee,
    this.open = const LwOpen.app(),
    this.sinceMs = 0,
  });
  final LwMood mood;
  final int running;
  final int attention;
  final int pending;

  /// The card in progress (or the first open one).
  final String? first;
  final String? firstAssignee;
  final LwOpen open;
  final int sinceMs;

  static LwTasksScene from(
    LauncherWidgetTasksSnapshot? tasks, {
    required int nowMs,
  }) {
    if (tasks == null) return const LwTasksScene(mood: LwMood.setup);
    final stale =
        tasks.updatedAtMs <= 0 || nowMs - tasks.updatedAtMs > lwStaleAfterMs;
    final first = tasks.tasks.isEmpty ? null : tasks.tasks.first;
    final open = tasks.tasks.isEmpty || first?.openPayload == null
        ? const LwOpen.app()
        : LwOpen.payload(first!.openPayload);
    if (tasks.runningCount + tasks.attentionCount + tasks.pendingCount == 0) {
      return LwTasksScene(
        mood: stale ? LwMood.offline : LwMood.empty,
        open: open,
        sinceMs: tasks.updatedAtMs,
      );
    }
    return LwTasksScene(
      mood: stale ? LwMood.offline : LwMood.calm,
      running: tasks.runningCount,
      attention: tasks.attentionCount,
      pending: tasks.pendingCount,
      first: first?.title,
      firstAssignee: first?.assignee == null
          ? null
          : lwProfileName(tasks.connectionId, first!.assignee!),
      open: open,
      sinceMs: tasks.updatedAtMs,
    );
  }
}

class LwNewChatScene {
  const LwNewChatScene({required this.ready, this.instanceId});
  final bool ready;
  final String? instanceId;

  static LwNewChatScene from(HermesHomeWidgetSnapshot chat) => LwNewChatScene(
    ready: chat.configured && chat.instanceId != null,
    instanceId: chat.instanceId,
  );
}
