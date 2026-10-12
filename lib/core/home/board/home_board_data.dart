/// What Home widgets show, derived from sources Console already holds.
/// Nothing here is estimated or invented: an empty field hides its line.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/account_usage_limits.dart';
import '../../models/agent_profile.dart';
import '../../widgets/mission_profile_avatar.dart';
import '../home_now.dart';
import 'home_board_model.dart' show HomeWidgetInstance;

enum HomeBotState { idle, working, waiting }

/// A bot (not the main agent) and what its canonical Bot Chat does now.
@immutable
final class HomeBoardBot {
  final String profileName;
  final String displayName;
  final AgentProfile? profile;
  final HomeBotState state;

  /// Title of what it works on, when the roster names it.
  final String? step;
  final DateTime? since;

  /// Last reply line of its current chat, when the list row has one.
  final String? lastReply;

  /// Room it is replying in right now (set from the rooms of the same
  /// read by [HomeBoardData.withGlance]).
  final String? room;

  /// The last chat it worked on and when, for a bot that is free now.
  final String? lastTitle;
  final DateTime? lastAt;

  const HomeBoardBot({
    required this.profileName,
    required this.displayName,
    required this.state,
    this.profile,
    this.step,
    this.since,
    this.lastReply,
    this.room,
    this.lastTitle,
    this.lastAt,
  });

  /// The same bot seen replying in [room] since [since].
  HomeBoardBot replyingIn(String room, DateTime? since) => HomeBoardBot(
    profileName: profileName,
    displayName: displayName,
    profile: profile,
    state: state == HomeBotState.waiting ? state : HomeBotState.working,
    step: step,
    since: since ?? this.since,
    lastReply: lastReply,
    room: room,
    lastTitle: lastTitle,
    lastAt: lastAt,
  );
}

/// One message line of a room widget.
@immutable
final class HomeBoardRoomLine {
  /// Member profile for the face; null for the user.
  final String? profileName;
  final String author;
  final String text;
  const HomeBoardRoomLine({
    required this.author,
    required this.text,
    this.profileName,
  });
}

@immutable
final class HomeBoardRoom {
  final String key;
  final String title;

  /// Member messages after what this device last saw (0 if never opened).
  final int unread;

  /// Newest public lines, oldest first (at most 3).
  final List<HomeBoardRoomLine> lines;

  /// Members replying in the current round.
  final List<String> responding;

  /// Member profiles, for the face stack.
  final List<String> memberProfiles;

  /// Unseen member messages addressed to the user (open `@user` mentions,
  /// the same attention as the Bots needs-you dot).
  final int mentions;

  /// Members whose turn failed and the user has not seen it yet.
  final List<String> failed;

  /// Profiles of the members replying now, parallel to [responding].
  final List<String> respondingProfiles;

  /// When the member replying now started, when the round says.
  final DateTime? respondingSince;

  /// Who replies after that, when the server's serial order makes it
  /// known.
  final String? next;

  /// When the newest line was written.
  final DateTime? lastAt;

  const HomeBoardRoom({
    required this.key,
    required this.title,
    this.unread = 0,
    this.lines = const [],
    this.responding = const [],
    this.memberProfiles = const [],
    this.mentions = 0,
    this.failed = const [],
    this.respondingProfiles = const [],
    this.respondingSince,
    this.next,
    this.lastAt,
  });

  bool get live => responding.isNotEmpty;
}

@immutable
final class HomeBoardServer {
  final String label;
  final bool online;
  final bool checking;

  /// Round trip of the last health check Home already made.
  final int? latencyMs;
  final String? version;

  /// Null when the update check could not be read.
  final bool? updateAvailable;

  const HomeBoardServer({
    required this.label,
    required this.online,
    this.checking = false,
    this.latencyMs,
    this.version,
    this.updateAvailable,
  });
}

/// Activity of today from the chats list (chats touched today and the
/// counters those rows publish).
@immutable
final class HomeBoardToday {
  final int chats;
  final int messages;
  final int tools;
  const HomeBoardToday({
    required this.chats,
    required this.messages,
    required this.tools,
  });

  static HomeBoardToday? fromSessions(
    Iterable<({double lastActivityAt, int messages, int tools})> rows, {
    required DateTime now,
  }) {
    final start = DateTime(now.year, now.month, now.day);
    var chats = 0, messages = 0, tools = 0;
    for (final row in rows) {
      final at = DateTime.fromMillisecondsSinceEpoch(
        (row.lastActivityAt * 1000).round(),
      );
      if (at.isBefore(start)) continue;
      chats++;
      messages += row.messages;
      tools += row.tools;
    }
    return HomeBoardToday(chats: chats, messages: messages, tools: tools);
  }
}

/// What a «Lo siguiente» row is about. The order of [HomeGlanceTier] is
/// the order of the list.
enum HomeGlanceKind {
  approval,
  question,
  botWaiting,
  pausedQueue,
  failedChat,
  failedRoom,
  failedAutomation,
  finished,
  roomReplies,
  roomNews,
  runningChat,
  runningBot,
  runningRoom;

  HomeGlanceTier get tier => switch (this) {
    approval ||
    question ||
    botWaiting ||
    pausedQueue => HomeGlanceTier.needsYou,
    failedChat || failedRoom || failedAutomation => HomeGlanceTier.failure,
    finished => HomeGlanceTier.finished,
    roomReplies || roomNews => HomeGlanceTier.replies,
    runningChat || runningBot || runningRoom => HomeGlanceTier.running,
  };
}

/// Priority bands of «Lo siguiente», most urgent first.
enum HomeGlanceTier { needsYou, failure, finished, replies, running }

/// One row of «Lo siguiente»: one thing, one action.
@immutable
final class HomeGlanceItem {
  final String key;
  final HomeGlanceKind kind;

  /// Who or what: the bot, chat, job or member names (empty when the
  /// source does not name one, e.g. the main agent).
  final String title;

  /// What it is about, when it is not [title]: the chat a bot finished,
  /// the room of a reply or failure, where an approval comes from.
  final String? subject;

  /// Step, reply line, command or reason, when the source names it.
  final String? detail;
  final DateTime? since;

  /// Replies or new messages (rooms), queued messages (paused queue).
  final int count;

  /// Face of the row, when it belongs to a profile.
  final String? profileName;

  /// What a tap opens: a [HomeChatItem], [HomeBoardBot], [HomeBoardRoom],
  /// [HomeApprovalItem] or [HomeAutomation].
  final Object target;

  const HomeGlanceItem({
    required this.key,
    required this.kind,
    required this.title,
    required this.target,
    this.subject,
    this.detail,
    this.since,
    this.count = 0,
    this.profileName,
  });

  HomeGlanceTier get tier => kind.tier;
}

/// «Lo siguiente»: what to do next, in order, and what runs meanwhile.
@immutable
final class HomeGlance {
  /// Actionable rows, most urgent first (needs you, failures, finished
  /// and unseen, replies).
  final List<HomeGlanceItem> next;

  /// Work in progress; shown only where [next] leaves room.
  final List<HomeGlanceItem> running;

  const HomeGlance({this.next = const [], this.running = const []});

  static const empty = HomeGlance();

  /// Nothing needs the user (things may still be running).
  bool get calm => next.isEmpty;

  /// Rows a widget of a size shows: three for small and wide, five large.
  static int capFor({required bool large}) => large ? 5 : 3;

  /// The rows for [cap]: actionable first, then running in what is left.
  /// When calm, the calm line takes one row.
  List<HomeGlanceItem> rows(int cap) {
    if (calm) return running.take(math.max(0, cap - 1)).toList();
    final shown = next.take(cap).toList();
    return [...shown, ...running.take(cap - shown.length)];
  }

  /// Actionable rows that do not fit in [cap].
  int more(int cap) => math.max(0, next.length - cap);

  static HomeGlance derive({
    required List<HomeChatItem> chats,
    required List<HomeBoardBot> bots,
    required List<HomeBoardRoom> rooms,
    required List<HomeApprovalItem> approvals,
    required List<HomeAutomation>? automations,
  }) {
    final asked = {
      for (final a in approvals)
        if (a.sessionKey != null) a.sessionKey!,
    };
    final askingActors = {
      for (final a in approvals)
        if (a.actor?.isNotEmpty == true) a.actor!,
    };
    final failedRooms = {
      for (final r in rooms)
        if (r.failed.isNotEmpty) r.key,
    };
    final next = <HomeGlanceItem>[
      // 1. Needs you.
      for (final a in approvals)
        HomeGlanceItem(
          key: 'approval:${a.key}',
          kind: HomeGlanceKind.approval,
          title: a.actor ?? '',
          subject: a.where.isEmpty ? null : a.where,
          detail: a.command.isEmpty ? null : a.command,
          profileName: a.profileName,
          target: a,
        ),
      for (final chat in chats)
        if (chat.waitingForUser && !asked.contains(chat.key))
          HomeGlanceItem(
            key: 'question:${chat.key}',
            kind: HomeGlanceKind.question,
            title: chat.title,
            profileName: chat.profileName,
            target: chat,
          ),
      for (final bot in bots)
        if (bot.state == HomeBotState.waiting &&
            !askingActors.contains(bot.displayName))
          HomeGlanceItem(
            key: 'waiting:${bot.profileName}',
            kind: HomeGlanceKind.botWaiting,
            title: bot.displayName,
            detail: bot.step,
            profileName: bot.profileName,
            target: bot,
          ),
      for (final chat in chats)
        if (chat.queuedPaused > 0)
          HomeGlanceItem(
            key: 'queue:${chat.key}',
            kind: HomeGlanceKind.pausedQueue,
            title: chat.title,
            count: chat.queuedPaused,
            profileName: chat.profileName,
            target: chat,
          ),
      // 2. Failures the user has not seen.
      for (final chat in chats)
        if (chat.failed && chat.unread && !chat.working)
          HomeGlanceItem(
            key: 'failed-chat:${chat.key}',
            kind: HomeGlanceKind.failedChat,
            title: chat.title,
            since: chat.at,
            profileName: chat.profileName,
            target: chat,
          ),
      for (final room in rooms)
        if (room.failed.isNotEmpty)
          HomeGlanceItem(
            key: 'failed-room:${room.key}',
            kind: HomeGlanceKind.failedRoom,
            title: room.failed.join(', '),
            subject: room.title,
            profileName: room.memberProfiles.firstOrNull,
            target: room,
          ),
      for (final job in automations ?? const <HomeAutomation>[])
        if (job.failed)
          HomeGlanceItem(
            key: 'failed:${job.key}',
            kind: HomeGlanceKind.failedAutomation,
            title: job.name,
            since: job.lastRunAt,
            target: job,
          ),
      // 3. Finished and not opened since.
      for (final chat in chats)
        if (chat.unread && !chat.working && !chat.failed)
          HomeGlanceItem(
            key: 'finished:${chat.key}',
            kind: HomeGlanceKind.finished,
            title: chat.agentName ?? '',
            subject: chat.title,
            detail:
                chat.lastReply ?? (chat.preview.isEmpty ? null : chat.preview),
            since: chat.at,
            profileName: chat.profileName,
            target: chat,
          ),
      // 4. Replies in rooms: those addressed to the user first.
      for (final room in rooms)
        if (room.mentions > 0 && !failedRooms.contains(room.key))
          _roomRow(room, HomeGlanceKind.roomReplies, room.mentions),
      for (final room in rooms)
        if (room.mentions == 0 &&
            room.unread > 0 &&
            !failedRooms.contains(room.key))
          _roomRow(room, HomeGlanceKind.roomNews, room.unread),
    ];
    final listed = {
      for (final item in next)
        if (item.target case final HomeBoardRoom r) r.key,
    };
    final running = <HomeGlanceItem>[
      for (final chat in chats)
        if (chat.working)
          HomeGlanceItem(
            key: 'chat:${chat.key}',
            kind: HomeGlanceKind.runningChat,
            title: chat.title,
            detail: chat.step,
            since: chat.workingSince,
            profileName: chat.profileName,
            target: chat,
          ),
      for (final bot in bots)
        if (bot.state == HomeBotState.working)
          HomeGlanceItem(
            key: 'bot:${bot.profileName}',
            kind: HomeGlanceKind.runningBot,
            title: bot.displayName,
            detail: bot.step,
            since: bot.since,
            profileName: bot.profileName,
            target: bot,
          ),
      for (final room in rooms)
        if (room.responding.isNotEmpty && !listed.contains(room.key))
          HomeGlanceItem(
            key: 'room:${room.key}',
            kind: HomeGlanceKind.runningRoom,
            title: room.title,
            detail: room.responding.join(', '),
            profileName: room.memberProfiles.firstOrNull,
            target: room,
          ),
    ];
    return HomeGlance(
      next: List.unmodifiable(next),
      running: List.unmodifiable(running),
    );
  }

  static HomeGlanceItem _roomRow(
    HomeBoardRoom room,
    HomeGlanceKind kind,
    int count,
  ) {
    final last = room.lines.lastOrNull;
    return HomeGlanceItem(
      key:
          '${kind == HomeGlanceKind.roomReplies ? 'replies' : 'news'}:'
          '${room.key}',
      kind: kind,
      title: room.title,
      subject: room.title,
      count: count,
      detail: last == null || last.author.isEmpty
          ? null
          : '${last.author}: ${last.text}',
      profileName: last?.profileName ?? room.memberProfiles.firstOrNull,
      target: room,
    );
  }
}

/// Why an «Ahora» entry needs the user.
enum HomeNowAskKind { approval, question, waiting, pausedQueue, failed }

/// Something that waits for the user: an approval, a question, a bot that
/// waits, a paused queue, a turn that failed.
@immutable
final class HomeNowAsk {
  final String key;
  final HomeNowAskKind kind;

  /// Who asks (a bot's name); empty for the main agent.
  final String who;
  final String? profileName;

  /// Chat or room it happens in, when it is not [who]'s own chat.
  final String? where;

  /// The question, or the command it wants to run.
  final String? text;

  /// Queued messages of a paused queue.
  final int count;

  /// A [HomeApprovalItem], [HomeQuestionItem], [HomeChatItem],
  /// [HomeBoardBot] or [HomeBoardRoom].
  final Object target;

  const HomeNowAsk({
    required this.key,
    required this.kind,
    required this.who,
    required this.target,
    this.profileName,
    this.where,
    this.text,
    this.count = 0,
  });
}

/// Work in progress: who, where, what and since when.
@immutable
final class HomeNowRun {
  final String key;

  /// Who works (a bot's name); empty for the main agent.
  final String who;
  final String? profileName;

  /// The chat or room.
  final String? where;

  /// The step, when the source names it (a tool, subagents).
  final String? what;
  final DateTime? since;

  /// A [HomeChatItem], [HomeBoardBot] or [HomeBoardRoom].
  final Object target;

  const HomeNowRun({
    required this.key,
    required this.who,
    required this.target,
    this.profileName,
    this.where,
    this.what,
    this.since,
  });
}

/// One of the last things that finished.
@immutable
final class HomeNowDone {
  final String key;

  /// Who finished (a bot's name); empty for the main agent.
  final String who;
  final String? profileName;
  final String what;
  final DateTime at;

  /// A [HomeChatItem] or [HomeBoardBot].
  final Object target;

  const HomeNowDone({
    required this.key,
    required this.who,
    required this.what,
    required this.at,
    required this.target,
    this.profileName,
  });
}

/// «Ahora»: what needs the user first; else what runs; else calm, with the
/// last things that finished.
@immutable
final class HomeNow {
  final List<HomeNowAsk> asks;
  final List<HomeNowRun> running;

  /// Newest first, at most [maxRecent].
  final List<HomeNowDone> recent;

  const HomeNow({
    this.asks = const [],
    this.running = const [],
    this.recent = const [],
  });

  static const empty = HomeNow();
  static const maxRecent = 4;

  bool get calm => asks.isEmpty && running.isEmpty;

  static HomeNow derive({
    required List<HomeChatItem> chats,
    required List<HomeBoardBot> bots,
    required List<HomeBoardRoom> rooms,
    required List<HomeApprovalItem> approvals,
    required List<HomeQuestionItem> questions,
  }) {
    final askedChats = <String>{
      for (final a in approvals) ?a.sessionKey,
      for (final q in questions) ?q.sessionKey,
    };
    final askingActors = <String>{
      for (final a in approvals) ?a.actor,
      for (final q in questions) ?q.actor,
    };
    final asks = <HomeNowAsk>[
      for (final a in approvals)
        HomeNowAsk(
          key: 'approval:${a.key}',
          kind: HomeNowAskKind.approval,
          who: a.actor ?? '',
          profileName: a.profileName,
          where: a.where.isEmpty ? null : a.where,
          text: a.command.isEmpty ? null : a.command,
          target: a,
        ),
      for (final q in questions)
        HomeNowAsk(
          key: 'question:${q.key}',
          kind: HomeNowAskKind.question,
          who: q.actor ?? '',
          profileName: q.profileName,
          where: q.where.isEmpty ? null : q.where,
          text: q.question.isEmpty ? null : q.question,
          target: q,
        ),
      for (final chat in chats)
        if (chat.waitingForUser && !askedChats.contains(chat.key))
          HomeNowAsk(
            key: 'question:${chat.key}',
            kind: HomeNowAskKind.question,
            who: chat.agentName ?? '',
            profileName: chat.profileName,
            where: chat.title,
            target: chat,
          ),
      for (final bot in bots)
        if (bot.state == HomeBotState.waiting &&
            !askingActors.contains(bot.displayName))
          HomeNowAsk(
            key: 'waiting:${bot.profileName}',
            kind: HomeNowAskKind.waiting,
            who: bot.displayName,
            profileName: bot.profileName,
            where: bot.step,
            target: bot,
          ),
      for (final chat in chats)
        if (chat.queuedPaused > 0)
          HomeNowAsk(
            key: 'queue:${chat.key}',
            kind: HomeNowAskKind.pausedQueue,
            who: chat.agentName ?? '',
            profileName: chat.profileName,
            where: chat.title,
            count: chat.queuedPaused,
            target: chat,
          ),
      for (final chat in chats)
        if (chat.failed && chat.unread && !chat.working)
          HomeNowAsk(
            key: 'failed-chat:${chat.key}',
            kind: HomeNowAskKind.failed,
            who: chat.agentName ?? '',
            profileName: chat.profileName,
            where: chat.title,
            target: chat,
          ),
      for (final room in rooms)
        if (room.failed.isNotEmpty)
          HomeNowAsk(
            key: 'failed-room:${room.key}',
            kind: HomeNowAskKind.failed,
            who: room.failed.join(', '),
            profileName: room.memberProfiles.firstOrNull,
            where: room.title,
            target: room,
          ),
    ];
    // One row per thing alive: a room's reply, a chat, a bot's own chat.
    // A bot replying in a room, or whose chat is a Home recent, is that
    // row only.
    final replying = <String>{
      for (final room in rooms) ...room.respondingProfiles,
    };
    final chatProfiles = <String>{
      for (final chat in chats)
        if (chat.working && chat.agentName != null) ?chat.profileName,
    };
    final running = <HomeNowRun>[
      for (final room in rooms)
        if (room.live)
          HomeNowRun(
            key: 'room:${room.key}',
            who: room.responding.join(', '),
            profileName:
                room.respondingProfiles.firstOrNull ??
                room.memberProfiles.firstOrNull,
            where: room.title,
            since: room.respondingSince,
            target: room,
          ),
      for (final chat in chats)
        if (chat.working)
          HomeNowRun(
            key: 'chat:${chat.key}',
            who: chat.agentName ?? '',
            profileName: chat.profileName,
            where: chat.title,
            what: chat.step,
            since: chat.workingSince,
            target: chat,
          ),
      for (final bot in bots)
        if (bot.state == HomeBotState.working &&
            !replying.contains(bot.profileName) &&
            !chatProfiles.contains(bot.profileName))
          HomeNowRun(
            key: 'bot:${bot.profileName}',
            who: bot.displayName,
            profileName: bot.profileName,
            where: bot.step,
            since: bot.since,
            target: bot,
          ),
    ];
    final recent =
        <HomeNowDone>[
          for (final chat in chats)
            if (!chat.working &&
                !chat.waitingForUser &&
                !chat.draft &&
                !chat.failed)
              HomeNowDone(
                key: 'done:${chat.key}',
                who: chat.agentName ?? '',
                profileName: chat.profileName,
                what: chat.title,
                at: chat.at,
                target: chat,
              ),
          for (final bot in bots)
            if (bot.state == HomeBotState.idle &&
                bot.lastTitle != null &&
                bot.lastAt != null &&
                // Not when a listed chat of the same bot already says it:
                // the same chat, or one at least as recent.
                !chats.any(
                  (c) =>
                      c.profileName == bot.profileName &&
                      (c.title == bot.lastTitle ||
                          !c.at.isBefore(
                            bot.lastAt!.subtract(const Duration(minutes: 1)),
                          )),
                ))
              HomeNowDone(
                key: 'done-bot:${bot.profileName}',
                who: bot.displayName,
                profileName: bot.profileName,
                what: bot.lastTitle!,
                at: bot.lastAt!,
                target: bot,
              ),
        ]..sort((a, b) {
          final byTime = b.at.compareTo(a.at);
          return byTime != 0 ? byTime : a.key.compareTo(b.key);
        });
    return HomeNow(
      asks: List.unmodifiable(asks),
      running: List.unmodifiable(running),
      recent: List.unmodifiable(recent.take(maxRecent)),
    );
  }
}

/// Everything the board paints, one immutable snapshot per change.
@immutable
final class HomeBoardData {
  final List<AgentProfile> profiles;
  final MissionProfileAvatarCache? avatarCache;
  final List<HomeApprovalItem> approvals;

  /// Questions Hermes waits on in attached chats.
  final List<HomeQuestionItem> questions;

  /// Home recents, newest first, with their live state.
  final List<HomeChatItem> chats;
  final List<HomeBoardBot> bots;
  final List<HomeBoardRoom> rooms;

  /// Null: the cron list was not read (yet, or it failed).
  final List<HomeAutomation>? automations;

  /// The last cron list read failed (what is shown, if anything, is the
  /// read before it).
  final bool automationsFailed;

  /// Null: the Kanban board was not read (yet, or it failed).
  final HomeTasks? tasks;
  final bool tasksFailed;
  final AccountUsageLimits? limits;
  final HomeBoardServer? server;
  final HomeBoardToday? today;
  final HomeGlance glance;
  final HomeNow nowBoard;
  final DateTime now;

  /// Whether Bots data (rooms, bots) has been read at least once.
  final bool botsLoaded;

  /// Whether the list of bots is the server's own (a roster read landed):
  /// only then is «no bots» a fact and not something still unread.
  final bool botsKnown;

  /// Whether the recent chats are known (read, or painted from the saved
  /// snapshot).
  final bool chatsLoaded;

  /// Name of the main agent (the active profile), for rows about its own
  /// chats.
  final String mainName;

  const HomeBoardData({
    required this.now,
    this.profiles = const [],
    this.avatarCache,
    this.approvals = const [],
    this.questions = const [],
    this.chats = const [],
    this.bots = const [],
    this.rooms = const [],
    this.automations,
    this.automationsFailed = false,
    this.tasks,
    this.tasksFailed = false,
    this.limits,
    this.server,
    this.today,
    this.glance = HomeGlance.empty,
    this.nowBoard = HomeNow.empty,
    this.botsLoaded = false,
    this.botsKnown = false,
    this.chatsLoaded = true,
    this.mainName = '',
  });

  /// The server does not answer (and is not being checked right now).
  bool get offline => server != null && !server!.online && !server!.checking;

  /// The same data with what is derived from it: each bot placed in the
  /// room it replies in, «Ahora», and the summary the dock's Actividad
  /// sheet shows.
  HomeBoardData withGlance() {
    final seated = [
      for (final bot in bots)
        switch (rooms
            .where((r) => r.respondingProfiles.contains(bot.profileName))
            .firstOrNull) {
          final room? => bot.replyingIn(room.title, room.respondingSince),
          null => bot,
        },
    ];
    return HomeBoardData(
      now: now,
      profiles: profiles,
      avatarCache: avatarCache,
      approvals: approvals,
      questions: questions,
      chats: chats,
      bots: seated,
      rooms: rooms,
      automations: automations,
      automationsFailed: automationsFailed,
      tasks: tasks,
      tasksFailed: tasksFailed,
      limits: limits,
      server: server,
      today: today,
      botsLoaded: botsLoaded,
      botsKnown: botsKnown,
      chatsLoaded: chatsLoaded,
      mainName: mainName,
      // The dock's summary keeps its own rows: a room that replies is the
      // room's row there, so the bots go in as they came.
      glance: HomeGlance.derive(
        chats: chats,
        bots: bots,
        rooms: rooms,
        approvals: approvals,
        automations: automations,
      ),
      nowBoard: HomeNow.derive(
        chats: chats,
        bots: seated,
        rooms: rooms,
        approvals: approvals,
        questions: questions,
      ),
    );
  }

  /// Rooms a «Salas» widget shows: the ones [item] follows, in the user's
  /// order; without a choice, every room, the liveliest first (someone
  /// replying, then replies for the user, then unread, then the newest).
  List<HomeBoardRoom> roomsFor(HomeWidgetInstance item) {
    final keys = item.roomKeys;
    if (keys.isNotEmpty) return [for (final key in keys) ?room(key)];
    int rank(HomeBoardRoom r) => r.live
        ? 0
        : r.mentions > 0 || r.failed.isNotEmpty
        ? 1
        : r.unread > 0
        ? 2
        : 3;
    final at = {for (final (i, r) in rooms.indexed) r.key: i};
    return [...rooms]..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      final ta = a.lastAt?.millisecondsSinceEpoch ?? 0;
      final tb = b.lastAt?.millisecondsSinceEpoch ?? 0;
      if (ta != tb) return tb.compareTo(ta);
      return at[a.key]!.compareTo(at[b.key]!);
    });
  }

  /// The cron jobs in the order «Cron» lists them: a fixed job
  /// ([jobKey]) first, then by next run, then those without one (paused
  /// last).
  static List<HomeAutomation> cronOrder(
    List<HomeAutomation> jobs,
    DateTime now, {
    String? jobKey,
  }) {
    int rank(HomeAutomation j) => j.key == jobKey
        ? 0
        : j.enabled && j.nextRun != null && !j.nextRun!.isBefore(now)
        ? 1
        : j.enabled
        ? 2
        : 3;
    final at = {for (final (i, j) in jobs.indexed) j.key: i};
    return [...jobs]..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      final ta = a.nextRun?.millisecondsSinceEpoch ?? 0;
      final tb = b.nextRun?.millisecondsSinceEpoch ?? 0;
      if (ta != tb) return ta.compareTo(tb);
      return at[a.key]!.compareTo(at[b.key]!);
    });
  }

  /// The automation a small «Cron» shows: [jobKey]'s job when set
  /// (paused or not), else the enabled job that runs soonest after [now].
  static HomeAutomation? nextAutomation(
    List<HomeAutomation>? jobs,
    DateTime now, {
    String? jobKey,
  }) {
    if (jobs == null) return null;
    if (jobKey != null) return jobs.where((j) => j.key == jobKey).firstOrNull;
    HomeAutomation? next;
    for (final job in jobs) {
      final at = job.nextRun;
      if (!job.enabled || at == null || at.isBefore(now)) continue;
      if (next == null || at.isBefore(next.nextRun!)) next = job;
    }
    return next;
  }

  HomeBoardBot? bot(String? profile) =>
      bots.where((b) => b.profileName == profile).firstOrNull;
  AgentProfile? profileFor(String name) =>
      profiles
          .where(
            (p) =>
                (p.isDefault ? 'default' : p.name) ==
                (name.isEmpty ? 'default' : name),
          )
          .firstOrNull ??
      bot(name)?.profile;
  HomeBoardRoom? room(String? key) =>
      rooms.where((r) => r.key == key).firstOrNull;
  HomeChatItem? chat(String? key) =>
      chats.where((c) => c.key == key).firstOrNull;
  HomeQuestionItem? questionOf(String chatKey) =>
      questions.where((q) => q.sessionKey == chatKey).firstOrNull;
}
