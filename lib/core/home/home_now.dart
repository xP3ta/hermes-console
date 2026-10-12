/// The items Home widgets are built from (Inicio v4).
///
/// Everything here is computed from data Console already holds (the Home
/// recents, attached chats, the shared Bots snapshot, the cron list, the
/// Kanban board); no field is invented. The screen adapts its sources
/// into these items and keeps the opaque [ref]s to act on them.
library;

/// One chat as Home sees it: a recent row, maybe live, maybe unread.
final class HomeChatItem {
  /// Logical session identity (the same chat on every refresh).
  final String key;
  final String title;

  /// One plain line (`plainPreview` of the session's own preview).
  final String preview;
  final DateTime at;

  /// The server says it has content the user has not read.
  final bool unread;

  /// A turn is in flight right now (from the live status).
  final bool working;

  /// When the turn started, when Console knows it.
  final DateTime? workingSince;

  /// Current step, only when an attached chat already reports it.
  final String? step;

  /// Hermes waits for the user in this chat (a clarify question or another
  /// open prompt), from the live status.
  final bool waitingForUser;

  /// Queued messages held in a paused queue of the attached chat.
  final int queuedPaused;

  /// Last assistant reply line the list row publishes, if any.
  final String? lastReply;

  /// The last turn of an attached chat ended in an error that no later
  /// prompt has replaced yet.
  final bool failed;

  /// Profile that owns the chat (its face).
  final String? profileName;

  /// Name of the bot that owns the chat; null for the main agent.
  final String? agentName;

  /// The user left text unsent in this chat ([preview] is that text).
  final bool draft;
  final Object ref;

  const HomeChatItem({
    required this.key,
    required this.title,
    required this.preview,
    required this.at,
    required this.ref,
    this.unread = false,
    this.working = false,
    this.workingSince,
    this.step,
    this.waitingForUser = false,
    this.queuedPaused = 0,
    this.lastReply,
    this.failed = false,
    this.profileName,
    this.agentName,
    this.draft = false,
  });
}

/// A question Hermes asked in an attached chat and waits on (a clarify
/// prompt): its text and, when it offered choices, the choices.
final class HomeQuestionItem {
  /// Stable identity of the question.
  final String key;

  /// Chat it belongs to ([HomeChatItem.key]), if it is a Home recent.
  final String? sessionKey;

  /// Chat title.
  final String where;

  /// Bot that asks, when it is not the main agent.
  final String? actor;

  /// Profile of who asks (its face), when known.
  final String? profileName;
  final String question;

  /// Answers Home can send as they are (empty: the chat takes a free one).
  final List<String> choices;
  final Object ref;

  const HomeQuestionItem({
    required this.key,
    required this.where,
    required this.question,
    required this.ref,
    this.sessionKey,
    this.actor,
    this.profileName,
    this.choices = const [],
  });
}

/// A pending approval Console already knows (an attached chat's request or
/// a hosted room's pending action).
final class HomeApprovalItem {
  /// Stable identity of the request.
  final String key;

  /// Chat it belongs to ([HomeChatItem.key]), if any.
  final String? sessionKey;

  /// Room it belongs to ([HomeRoomNews.key]), if any.
  final String? roomKey;

  /// Chat title or room name.
  final String where;

  /// Bot that asks, when it is not the main agent.
  final String? actor;

  /// Profile of who asks (its face), when known.
  final String? profileName;

  /// Command preview, possibly empty.
  final String command;
  final bool canAllow;
  final bool canDeny;
  final Object ref;

  const HomeApprovalItem({
    required this.key,
    required this.where,
    required this.command,
    required this.canAllow,
    required this.canDeny,
    required this.ref,
    this.sessionKey,
    this.roomKey,
    this.actor,
    this.profileName,
  });
}

/// A hosted room with messages since this device last saw it.
final class HomeRoomNews {
  final String key;
  final String title;
  final int count;
  final DateTime? at;
  final Object ref;

  const HomeRoomNews({
    required this.key,
    required this.title,
    required this.count,
    required this.ref,
    this.at,
  });
}

/// A scheduled automation (cron job).
final class HomeAutomation {
  final String key;
  final String name;
  final bool enabled;

  /// The last run failed (server `last_status` / state).
  final bool failed;
  final DateTime? nextRun;

  /// When it last ran, if the server says.
  final DateTime? lastRunAt;

  /// The last run ended well (false with [failed]; null: never ran or
  /// unknown).
  final bool? lastRunOk;

  /// Minutes between runs of a job that repeats on an interval.
  final int? everyMinutes;
  final Object ref;

  const HomeAutomation({
    required this.key,
    required this.name,
    required this.ref,
    this.enabled = true,
    this.failed = false,
    this.nextRun,
    this.lastRunAt,
    this.lastRunOk,
    this.everyMinutes,
  });
}

/// A Kanban task as Home shows it.
final class HomeTaskItem {
  final String key;
  final String title;

  /// Who runs it (a profile name), when it has an assignee.
  final String? assignee;

  /// Blocked or waiting for review: it needs the user.
  final bool attention;
  final Object ref;

  const HomeTaskItem({
    required this.key,
    required this.title,
    required this.ref,
    this.assignee,
    this.attention = false,
  });
}

/// The Kanban board Tasks opens on, as Home needs it: what is in progress
/// and what waits, in the board's own order.
final class HomeTasks {
  /// Running now.
  final List<HomeTaskItem> running;

  /// Not started yet (queued for someone, or a note without assignee),
  /// preceded by what is blocked or in review.
  final List<HomeTaskItem> pending;

  const HomeTasks({this.running = const [], this.pending = const []});

  bool get isEmpty => running.isEmpty && pending.isEmpty;
}
