/// Pure derivation of the light Home (Inicio v3): one hero card for what
/// matters now, one quiet status sentence, «Retomar» and «Próximo».
///
/// Everything here is computed from data Console already holds (the Home
/// recents, attached chats, the shared Bots snapshot, the cron list); no
/// field is invented. The screen adapts its sources into these items and
/// keeps the opaque [ref]s to act on them.
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
  });
}

enum HomeTeamState { waiting, working }

/// A bot (not the main one) whose canonical Bot Chat works or waits.
final class HomeTeamBot {
  final String profileName;
  final String displayName;
  final HomeTeamState state;

  /// Title of what it works on, when the roster names it.
  final String? workingOn;
  final Object? ref;

  const HomeTeamBot({
    required this.profileName,
    required this.displayName,
    required this.state,
    this.workingOn,
    this.ref,
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
  final Object ref;

  const HomeAutomation({
    required this.key,
    required this.name,
    required this.ref,
    this.enabled = true,
    this.failed = false,
    this.nextRun,
  });
}

sealed class HomeHero {
  const HomeHero();

  /// Identity for the hero's switcher: a new key morphs the card.
  String get key;
}

final class HomeHeroNeedsYou extends HomeHero {
  final HomeApprovalItem approval;

  /// Other approvals behind this one (they rise when it is answered).
  final int waiting;

  const HomeHeroNeedsYou(this.approval, {this.waiting = 0});

  @override
  String get key => 'needs:${approval.key}';
}

final class HomeHeroWorking extends HomeHero {
  final HomeChatItem chat;
  const HomeHeroWorking(this.chat);

  @override
  String get key => 'working:${chat.key}';
}

final class HomeHeroFinished extends HomeHero {
  final HomeChatItem chat;
  const HomeHeroFinished(this.chat);

  @override
  String get key => 'finished:${chat.key}';
}

final class HomeHeroCalm extends HomeHero {
  final List<HomeStarter> starters;
  const HomeHeroCalm(this.starters);

  @override
  String get key => 'calm';
}

sealed class HomeStarter {
  const HomeStarter();
  String get key;
}

final class HomeStarterContinue extends HomeStarter {
  final HomeChatItem chat;
  const HomeStarterContinue(this.chat);

  @override
  String get key => 'continue:${chat.key}';
}

final class HomeStarterReview extends HomeStarter {
  final HomeAutomation automation;
  const HomeStarterReview(this.automation);

  @override
  String get key => 'review:${automation.key}';
}

enum HomeStatusKind { calm, needsYou, working, finished, team }

final class HomeStatus {
  final HomeStatusKind kind;
  final String? chatTitle;

  const HomeStatus(this.kind, {this.chatTitle});

  @override
  bool operator ==(Object other) =>
      other is HomeStatus && other.kind == kind && other.chatTitle == chatTitle;

  @override
  int get hashCode => Object.hash(kind, chatTitle);
}

sealed class HomeRetomarRow {
  const HomeRetomarRow();
  String get key;
}

final class HomeRetomarChat extends HomeRetomarRow {
  final HomeChatItem chat;
  const HomeRetomarChat(this.chat);

  @override
  String get key => 'chat:${chat.key}';
}

final class HomeRetomarRoom extends HomeRetomarRow {
  final HomeRoomNews room;
  const HomeRetomarRoom(this.room);

  @override
  String get key => 'room:${room.key}';
}

final class HomeProximo {
  final HomeAutomation automation;
  final bool failed;
  const HomeProximo(this.automation, {required this.failed});
}

final class HomeNow {
  /// A calm «Seguir con…» starter only for a chat touched this recently.
  static const continueWindow = Duration(hours: 12);
  static const maxRetomar = 3;
  static const maxStarters = 3;

  final HomeHero hero;
  final HomeStatus status;

  /// Bots that work or wait, waiting first.
  final List<HomeTeamBot> team;
  final List<HomeRetomarRow> retomar;
  final HomeProximo? proximo;

  const HomeNow({
    required this.hero,
    required this.status,
    required this.team,
    required this.retomar,
    required this.proximo,
  });

  /// The faces get their own row under the sentence unless the sentence is
  /// already about them.
  bool get showTeamRow => team.isNotEmpty && status.kind != HomeStatusKind.team;

  /// [chats] newest first (the Home recents order). [automations] null or
  /// empty: no cron data, so «Próximo» is hidden.
  static HomeNow derive({
    required List<HomeApprovalItem> approvals,
    required List<HomeChatItem> chats,
    required List<HomeRoomNews> rooms,
    required List<HomeTeamBot> team,
    required List<HomeAutomation>? automations,
    required DateTime now,
  }) {
    final jobs = automations ?? const <HomeAutomation>[];
    final failedJobs = [
      for (final job in jobs)
        if (job.failed) job,
    ];

    // Hero, by priority.
    final HomeHero hero;
    final working = chats.where((c) => c.working).firstOrNull;
    final finished = chats.where((c) => c.unread && !c.working).firstOrNull;
    if (approvals.isNotEmpty) {
      hero = HomeHeroNeedsYou(approvals.first, waiting: approvals.length - 1);
    } else if (working != null) {
      hero = HomeHeroWorking(working);
    } else if (finished != null) {
      hero = HomeHeroFinished(finished);
    } else {
      final starters = <HomeStarter>[];
      final last = chats.firstOrNull;
      if (last != null && now.difference(last.at) <= continueWindow) {
        starters.add(HomeStarterContinue(last));
      }
      for (final job in failedJobs) {
        if (starters.length >= maxStarters) break;
        starters.add(HomeStarterReview(job));
      }
      hero = HomeHeroCalm(List.unmodifiable(starters));
    }

    // Status sentence and team.
    final orderedTeam = [
      ...team.where((b) => b.state == HomeTeamState.waiting),
      ...team.where((b) => b.state == HomeTeamState.working),
    ];
    final HomeStatus status;
    if (hero is HomeHeroNeedsYou) {
      status = const HomeStatus(HomeStatusKind.needsYou);
    } else if (working != null) {
      status = HomeStatus(HomeStatusKind.working, chatTitle: working.title);
    } else if (hero is HomeHeroFinished) {
      status = HomeStatus(HomeStatusKind.finished, chatTitle: hero.chat.title);
    } else if (orderedTeam.isNotEmpty) {
      status = const HomeStatus(HomeStatusKind.team);
    } else {
      status = const HomeStatus(HomeStatusKind.calm);
    }

    // Retomar: rooms with news, then chats, without what the hero shows.
    final excludedChats = <String>{
      if (hero case HomeHeroNeedsYou(:final approval)) ?approval.sessionKey,
      if (hero case HomeHeroWorking(:final chat)) chat.key,
      if (hero case HomeHeroFinished(:final chat)) chat.key,
      if (hero is HomeHeroCalm)
        for (final starter in hero.starters)
          if (starter is HomeStarterContinue) starter.chat.key,
    };
    final excludedRooms = <String>{
      if (hero case HomeHeroNeedsYou(:final approval)) ?approval.roomKey,
    };
    final newsRooms =
        rooms
            .where((r) => r.count > 0 && !excludedRooms.contains(r.key))
            .toList()
          ..sort((a, b) {
            final at = a.at?.millisecondsSinceEpoch ?? 0;
            final bt = b.at?.millisecondsSinceEpoch ?? 0;
            return bt.compareTo(at);
          });
    final retomar = <HomeRetomarRow>[
      for (final room in newsRooms) HomeRetomarRoom(room),
      for (final chat in chats)
        if (!excludedChats.contains(chat.key)) HomeRetomarChat(chat),
    ].take(maxRetomar).toList(growable: false);

    // Próximo: a failure in red (unless the calm card already offers it),
    // else the next scheduled run. Never while something needs the user.
    HomeProximo? proximo;
    if (hero is! HomeHeroNeedsYou && jobs.isNotEmpty) {
      final offered = <String>{
        if (hero is HomeHeroCalm)
          for (final starter in hero.starters)
            if (starter is HomeStarterReview) starter.automation.key,
      };
      final failure = failedJobs
          .where((job) => !offered.contains(job.key))
          .firstOrNull;
      if (failure != null) {
        proximo = HomeProximo(failure, failed: true);
      } else {
        HomeAutomation? next;
        for (final job in jobs) {
          final at = job.nextRun;
          if (!job.enabled || at == null || at.isBefore(now)) continue;
          if (next == null || at.isBefore(next.nextRun!)) next = job;
        }
        if (next != null) proximo = HomeProximo(next, failed: false);
      }
    }

    return HomeNow(
      hero: hero,
      status: status,
      team: List.unmodifiable(orderedTeam),
      retomar: retomar,
      proximo: proximo,
    );
  }
}
