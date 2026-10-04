import '../../models/agent_profile.dart';
import '../../models/desktop_active_session.dart';
import '../../models/hosted_groups.dart';

/// Row presence for a bot (spec 070 § Presence).
///
/// Only server evidence is consulted: `profiles.list.worker_session`
/// (fresh when `last_active` is within [BotPresence.workerFreshness]),
/// `session.active_list` live status and hosted room `driver_status`.
/// There is no "wrote recently" heuristic.
enum BotPresence {
  idle,
  thinking,
  working,
  attention;

  static const workerFreshness = Duration(seconds: 150);

  /// Tolerated clock skew for server timestamps in the future.
  static const futureSkew = Duration(seconds: 60);

  int get priority => index;

  static BotPresence derive({
    required AgentProfile profile,
    required DateTime now,
    Iterable<DesktopActiveSession> liveSessions = const [],
    Iterable<BotRoomSeat> roomSeats = const [],
    Set<String> ambiguousSessionIds = const {},
  }) {
    var result = BotPresence.idle;
    void lift(BotPresence candidate) {
      if (candidate.priority > result.priority) result = candidate;
    }

    for (final live in _ownLiveSessions(
      profile,
      liveSessions,
      ambiguousSessionIds,
    )) {
      lift(ofLiveStatus(live.status));
    }
    if (workerIsFresh(profile.workerSession, now)) lift(BotPresence.working);
    for (final seat in roomSeats) {
      final status = seat.driverStatus;
      if (status.approvals.any((a) => a.memberId == seat.memberId)) {
        lift(BotPresence.attention);
      } else if (seat.running) {
        lift(BotPresence.working);
      } else if (seat.queued) {
        lift(BotPresence.thinking);
      }
    }
    return result;
  }

  /// Stored ids that more than one of [profiles] owns. `session.active_list`
  /// carries no profile, so a live row with such an id cannot be attributed.
  static Set<String> ambiguousSessionIds(Iterable<AgentProfile> profiles) {
    final owners = <String, int>{};
    for (final profile in profiles) {
      for (final id in _ownSessionIds(profile)) {
        owners[id] = (owners[id] ?? 0) + 1;
      }
    }
    return {
      for (final entry in owners.entries)
        if (entry.value > 1) entry.key,
    };
  }

  /// The `session.active_list` row that makes [profile] busy: the most
  /// pressing one (attention, then working, then thinking), the most recent
  /// among equals. Null when none of its own sessions is live.
  static DesktopActiveSession? liveSessionFor(
    AgentProfile profile,
    Iterable<DesktopActiveSession> liveSessions, {
    Set<String> ambiguousSessionIds = const {},
  }) {
    DesktopActiveSession? best;
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    for (final live in _ownLiveSessions(
      profile,
      liveSessions,
      ambiguousSessionIds,
    )) {
      final presence = ofLiveStatus(live.status);
      if (presence == BotPresence.idle) continue;
      if (best == null) {
        best = live;
        continue;
      }
      final bestPresence = ofLiveStatus(best.status);
      final newer = (live.lastActiveAt ?? epoch).isAfter(
        best.lastActiveAt ?? epoch,
      );
      if (presence.priority > bestPresence.priority ||
          (presence == bestPresence && newer)) {
        best = live;
      }
    }
    return best;
  }

  /// Rows of [liveSessions] that belong to [profile]. Matching is by the
  /// profile's own stored ids only, and an id [ambiguous] between profiles
  /// matches nobody.
  static Iterable<DesktopActiveSession> _ownLiveSessions(
    AgentProfile profile,
    Iterable<DesktopActiveSession> liveSessions,
    Set<String> ambiguous,
  ) sync* {
    final ownIds = _ownSessionIds(profile);
    for (final live in liveSessions) {
      final stored = live.storedSessionId;
      if (stored == null ||
          !ownIds.contains(stored) ||
          ambiguous.contains(stored)) {
        continue;
      }
      yield live;
    }
  }

  /// Presence a `session.active_list` row status stands for (the one mapping
  /// [derive] uses too).
  static BotPresence ofLiveStatus(String? status) => switch (status) {
    'waiting' => BotPresence.attention,
    'starting' || 'resuming' => BotPresence.thinking,
    'working' || 'streaming' => BotPresence.working,
    _ => BotPresence.idle,
  };

  static bool workerIsFresh(AgentProfileWorkerSession? worker, DateTime now) {
    if (worker == null) return false;
    return isFreshActivity(worker.lastActive, now);
  }

  /// Whether server activity at [lastActiveSeconds] (epoch seconds) still
  /// counts as ongoing work at [now]: within [workerFreshness], tolerating
  /// [futureSkew] of clock drift.
  static bool isFreshActivity(num lastActiveSeconds, DateTime now) {
    final age = now.millisecondsSinceEpoch / 1000 - lastActiveSeconds;
    return age >= -futureSkew.inSeconds && age <= workerFreshness.inSeconds;
  }

  static Set<String> _ownSessionIds(AgentProfile profile) => {
    for (final summary in [
      profile.canonicalSession,
      profile.lastSession,
      profile.preferredSession,
    ])
      if (summary != null) ...[
        summary.id,
        ?summary.resolvedId,
      ],
    if (profile.workerSession case final worker?) worker.id,
  };
}

/// One bot's seat in a hosted room plus that room's driver evidence.
final class BotRoomSeat {
  final String roomId;
  final String memberId;
  final RoomDriverStatus driverStatus;

  /// The member has a task the driver reports as running.
  final bool running;

  /// The member has a queued/pending task (driver not yet running it).
  final bool queued;

  const BotRoomSeat({
    required this.roomId,
    required this.memberId,
    required this.driverStatus,
    this.running = false,
    this.queued = false,
  });

  /// Seats owned by [profile] on the room authority. A peer seat with the
  /// same profile name never lends liveness to a local bot.
  static List<BotRoomSeat> forProfile(
    String profile,
    HostedGroupsSnapshot snapshot,
  ) {
    final seats = <BotRoomSeat>[];
    for (final room in snapshot.rooms) {
      if (room.disbanded) continue;
      final status = snapshot.driverStatusFor(room.roomId);
      if (status == null) continue;
      for (final member in room.members) {
        if (member.owner.connectionId != room.authorityGatewayId ||
            member.owner.profile != profile) {
          continue;
        }
        final memberActions = status.approvals.where(
          (a) => a.memberId == member.memberId,
        );
        // Driver counts are room-wide; a member only works while the driver
        // runs AND its own turn is open in the log (no time heuristic).
        final open = _memberHasLiveTurn(snapshot, room.roomId, member.memberId);
        seats.add(
          BotRoomSeat(
            roomId: room.roomId,
            memberId: member.memberId,
            driverStatus: status,
            running: status.working && memberActions.isEmpty && open,
            queued: !status.working && status.running && open,
          ),
        );
      }
    }
    return seats;
  }

  static bool _memberHasLiveTurn(
    HostedGroupsSnapshot snapshot,
    String roomId,
    String memberId,
  ) {
    for (final log in snapshot.logs) {
      String? open;
      for (final event in log.events) {
        if (event.roomId != roomId) continue;
        final member = event.activity.memberId ?? event.actor.id;
        if (member != memberId) continue;
        if (event.kind == 'turn.started') open = event.activity.taskId ?? '';
        if (const {
          'turn.settled',
          'turn.failed',
          'turn.cancelled',
          'turn.deferred',
          'turn.reassigned',
        }.contains(event.kind)) {
          open = null;
        }
      }
      if (open != null) return true;
    }
    return false;
  }
}
