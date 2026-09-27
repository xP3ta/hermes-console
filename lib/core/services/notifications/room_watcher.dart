// T607 — room watcher for the background listener (spec 070 § Room
// notifications). Reads hosted rooms incrementally (`groups.state` +
// `groups.log since_seq`) and turns server evidence into notification
// decisions. The decider is pure; the driver owns IO, backoff and cursors.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../bots/data/bot_mode_repository.dart';
import '../../bots/ui/room/room_prefs.dart';
import '../../models/hosted_groups.dart';
import '../../models/room_member_status.dart' show roomMessageNeedsYou;

/// What the watcher decided for one room tick.
sealed class RoomNotice {
  const RoomNotice();

  /// Durable identity for the event ledger (null = not deduplicated, e.g. the
  /// in-place Live Update refresh).
  String? get dedupeKey;
}

final class RoomApprovalNotice extends RoomNotice {
  final RoomApprovalAction action;
  const RoomApprovalNotice(this.action);
  @override
  String get dedupeKey => 'approval:${action.requestId}';
}

final class RoomMentionNotice extends RoomNotice {
  final HostedGroupEvent event;
  const RoomMentionNotice(this.event);
  @override
  String get dedupeKey => 'mention:${event.eventId}';
}

final class RoomRoundFinishedNotice extends RoomNotice {
  final List<String> repliedMemberIds;
  final int throughSeq;
  final String? lastText;
  final String? lastMemberId;
  const RoomRoundFinishedNotice(
    this.repliedMemberIds,
    this.throughSeq, {
    this.lastText,
    this.lastMemberId,
  });
  @override
  String get dedupeKey => 'round:$throughSeq';
}

final class RoomMemberFailedNotice extends RoomNotice {
  final HostedGroupEvent event;
  const RoomMemberFailedNotice(this.event);
  @override
  String get dedupeKey => 'failed:${event.eventId}';
}

final class RoomBlockedNotice extends RoomNotice {
  final int atSeq;
  const RoomBlockedNotice(this.atSeq);
  @override
  String get dedupeKey => 'blocked:$atSeq';
}

/// Live Update refresh (or end) while the room works.
final class RoomLiveNotice extends RoomNotice {
  final bool working;
  final List<({String memberId, String state})> members;
  final String? workingMemberId;
  final int? round;
  final int? startedAtMs;
  const RoomLiveNotice({
    required this.working,
    this.members = const [],
    this.workingMemberId,
    this.round,
    this.startedAtMs,
  });
  @override
  String? get dedupeKey => null;
}

/// Approvals that disappeared from `pending_actions` (answered anywhere).
final class RoomApprovalClearedNotice extends RoomNotice {
  final String requestId;
  const RoomApprovalClearedNotice(this.requestId);
  @override
  String? get dedupeKey => null;
}

/// Persisted per-room watcher state (no message text).
@immutable
class RoomWatchState {
  final int cursor;
  final bool working;
  final bool blocked;
  final List<String> repliers;
  final String? lastMemberId;
  final Set<String> pendingRequestIds;
  final int? workingSinceMs;
  final int? round;

  /// Members with a `turn.started` not yet settled (server evidence only).
  final Set<String> openMembers;

  const RoomWatchState({
    this.openMembers = const {},
    this.cursor = 0,
    this.working = false,
    this.blocked = false,
    this.repliers = const [],
    this.lastMemberId,
    this.pendingRequestIds = const {},
    this.workingSinceMs,
    this.round,
  });

  Map<String, Object?> toJson() => {
    'cursor': cursor,
    'working': working,
    'blocked': blocked,
    'repliers': repliers,
    'last': ?lastMemberId,
    'pending': pendingRequestIds.toList(),
    'since': ?workingSinceMs,
    'round': ?round,
    'open': openMembers.toList(),
  };

  static RoomWatchState fromJson(Object? raw) {
    if (raw is! Map) return const RoomWatchState();
    List<String> strings(Object? v) => [
      if (v is List)
        for (final e in v)
          if (e is String) e,
    ];
    return RoomWatchState(
      cursor: raw['cursor'] is int ? raw['cursor'] as int : 0,
      working: raw['working'] == true,
      blocked: raw['blocked'] == true,
      repliers: strings(raw['repliers']),
      lastMemberId: raw['last'] as String?,
      pendingRequestIds: strings(raw['pending']).toSet(),
      workingSinceMs: raw['since'] is int ? raw['since'] as int : null,
      round: raw['round'] is int ? raw['round'] as int : null,
      openMembers: strings(raw['open']).toSet(),
    );
  }
}

/// Pure decision step. [previous] is null on first sight of the room: then
/// only currently pending approvals surface (history is never replayed).
({List<RoomNotice> notices, RoomWatchState next}) decideRoomNotices({
  required RoomWatchState? previous,
  required RoomDriverStatus? driverStatus,
  required List<HostedGroupEvent> newEvents,
  required int latestSeq,
  required RoomNotificationLevel level,
  required int nowMs,
}) {
  final notices = <RoomNotice>[];
  final status = driverStatus ?? RoomDriverStatus.unknown;
  final approvals = status.approvals.toList();
  final pendingIds = {for (final a in approvals) a.requestId};
  final before = previous ?? const RoomWatchState();

  // Approvals surface in every level, muted included.
  for (final action in approvals) {
    if (!before.pendingRequestIds.contains(action.requestId) ||
        previous == null) {
      notices.add(RoomApprovalNotice(action));
    }
  }
  for (final gone in before.pendingRequestIds.difference(pendingIds)) {
    notices.add(RoomApprovalClearedNotice(gone));
  }

  if (previous == null) {
    return (
      notices: notices,
      next: RoomWatchState(
        cursor: latestSeq,
        working: status.working,
        blocked: status.blocked,
        pendingRequestIds: pendingIds,
        workingSinceMs: status.working ? nowMs : null,
      ),
    );
  }


  var repliers = [...before.repliers];
  var lastMember = before.lastMemberId;
  String? lastText;
  var round = before.round;
  final open = <String>{...before.openMembers};
  final startedNow = <String>[];
  for (final event in newEvents) {
    final member = event.activity.memberId ?? event.actor.id;
    switch (event.kind) {
      case 'message.user':
        repliers = [];
        lastMember = null;
        round = null;
      case 'message.member':
        if (!repliers.contains(member)) repliers.add(member);
        lastMember = member;
        lastText = event.publicText;
        if (level != RoomNotificationLevel.muted &&
            roomMessageNeedsYou(event.publicText ?? '')) {
          notices.add(RoomMentionNotice(event));
        }
      case 'turn.started':
        open.add(member);
        startedNow.add(member);
        final r = event.activity.roundIndex;
        if (r != null) round = r + 1;
      case 'turn.failed':
        open.remove(member);
        if (level != RoomNotificationLevel.muted) {
          notices.add(RoomMemberFailedNotice(event));
        }
      case 'turn.settled' ||
          'turn.cancelled' ||
          'turn.deferred' ||
          'turn.reassigned':
        open.remove(member);
    }
  }

  if (status.blocked && !before.blocked && level != RoomNotificationLevel.muted) {
    notices.add(RoomBlockedNotice(latestSeq));
  }

  final finished = before.working && !status.working;
  if (finished) {
    if (level == RoomNotificationLevel.all && repliers.isNotEmpty) {
      notices.add(
        RoomRoundFinishedNotice(
          List.unmodifiable(repliers),
          latestSeq,
          lastText: lastText,
          lastMemberId: lastMember,
        ),
      );
    }
  }

  final since = status.working
      ? (before.working ? before.workingSinceMs ?? nowMs : nowMs)
      : null;
  if (level == RoomNotificationLevel.all &&
      (status.working || before.working)) {
    notices.add(
      RoomLiveNotice(
        working: status.working,
        workingMemberId: status.working
            ? (startedNow.isNotEmpty
                  ? startedNow.last
                  : open.isNotEmpty
                  ? open.last
                  : null)
            : null,
        members: [
          for (final id in repliers) (memberId: id, state: 'done'),
          for (final id in open)
            if (!repliers.contains(id)) (memberId: id, state: 'working'),
          for (final a in approvals) (memberId: a.memberId, state: 'needs_you'),
        ],
        round: round,
        startedAtMs: since,
      ),
    );
  }

  return (
    notices: notices,
    next: RoomWatchState(
      cursor: latestSeq,
      working: status.working,
      blocked: status.blocked,
      repliers: finished ? const [] : repliers,
      lastMemberId: lastMember,
      pendingRequestIds: pendingIds,
      workingSinceMs: since,
      round: finished ? null : round,
      openMembers: status.running || status.working ? open : const {},
    ),
  );
}

/// Last observed room for widgets and presence.
@immutable
class RoomWatchView {
  final HostedGroupRoom room;
  final RoomDriverStatus? driverStatus;
  final RoomWatchState state;
  final String? lastMemberId;
  final String? lastText;

  const RoomWatchView({
    required this.room,
    required this.driverStatus,
    required this.state,
    this.lastMemberId,
    this.lastText,
  });
}

/// Presents decisions (implemented by the listener with rich notifications).
abstract interface class RoomNoticePresenter {
  Future<void> present(
    String connId,
    HostedGroupRoom room,
    List<RoomNotice> notices,
  );
}

/// Claims a dedupe key once across isolates (the notification ledger).
typedef RoomNoticeClaim = Future<bool> Function(
  String connId,
  String roomId,
  String dedupeKey,
);

/// IO driver for one connection. Called from the listener tick; holds no
/// timers. Backoff is per connection and doubles up to [maxDelay].
class RoomWatcher {
  RoomWatcher({
    required this.connId,
    required this.prefs,
    required this.presenter,
    required this.claim,
    DateTime Function()? now,
    this.baseDelay = const Duration(minutes: 1),
    this.maxDelay = const Duration(minutes: 15),
    this.maxRooms = 12,
    this.pageLimit = 100,
    this.maxPagesPerTick = 8,
  }) : _now = now ?? DateTime.now;

  final String connId;
  final SharedPreferences prefs;
  final RoomNoticePresenter presenter;
  final RoomNoticeClaim claim;
  final Duration baseDelay;
  final Duration maxDelay;
  final int maxRooms;
  final int pageLimit;

  /// Log pages read per room per tick. A longer backlog resumes from the
  /// server cursor on the next tick; events are never skipped.
  final int maxPagesPerTick;
  final DateTime Function() _now;

  int _failures = 0;
  DateTime? _retryAt;
  bool _anyWorking = false;
  final Map<String, ({String memberId, String text})> _lastMessages = {};
  List<RoomWatchView> _views = const [];

  /// Rooms seen by the last successful tick (widgets, presence).
  List<RoomWatchView> get views => _views;

  static const storageKey = 'bg_room_watch_v1';

  bool get anyWorking => _anyWorking;
  Duration? get retryAfter {
    final at = _retryAt;
    if (at == null) return null;
    final left = at.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get allowsAttempt => _retryAt == null || !_now().isBefore(_retryAt!);

  void _recordFailure() {
    _failures++;
    var delay = baseDelay;
    for (var i = 1; i < _failures && delay < maxDelay; i++) {
      delay *= 2;
    }
    if (delay > maxDelay) delay = maxDelay;
    _retryAt = _now().add(delay);
  }

  Map<String, Object?> _loadAll() {
    try {
      final raw = prefs.getString(storageKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      return decoded is Map ? Map<String, Object?>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  static String roomKey(String connId, HostedGroupRoom room) =>
      '$connId|${room.authorityGatewayId}:${room.roomId}';

  /// Same key the Room screen writes (`SharedPreferencesRoomPrefs`).
  static String prefsRoomKey(HostedGroupRoom room) =>
      '${room.authorityGatewayId}:${room.roomId}';

  /// One incremental pass. Returns false when skipped by backoff or failed.
  Future<bool> tick(BotModeGateway gateway) async {
    if (!allowsAttempt) return false;
    final all = _loadAll();
    final roomPrefs = SharedPreferencesRoomPrefs(prefs);
    var working = false;
    try {
      final caps = await gateway.groupCapabilities();
      if (!caps.methods.contains(GroupMethod.state) ||
          !caps.methods.contains(GroupMethod.log)) {
        _failures = 0;
        _retryAt = _now().add(maxDelay);
        return false;
      }
      final rooms = (await gateway.listGroups(generation: caps.generation))
          .where((r) => !r.disbanded)
          .take(maxRooms)
          .toList();
      final seen = <String>{};
      final views = <RoomWatchView>[];
      for (final listed in rooms) {
        final key = roomKey(connId, listed);
        seen.add(key);
        final previousRaw = all[key];
        final previous = previousRaw == null
            ? null
            : RoomWatchState.fromJson(previousRaw);
        // Quiet rooms cost one `groups.state`; the log is read only when
        // the server says there is something past our cursor.
        final state = await gateway.groupState(
          listed.roomId,
          generation: caps.generation,
        );
        final room = state.room;
        var events = <HostedGroupEvent>[];
        var latest = room.latestSeq;
        if (previous != null && room.latestSeq > previous.cursor) {
          var since = previous.cursor;
          for (var page = 0; page < maxPagesPerTick; page++) {
            final log = await gateway.groupLog(
              room.roomId,
              sinceSeq: since,
              limit: pageLimit,
              generation: caps.generation,
            );
            events.addAll(log.events);
            final stalled = log.cursor <= since;
            since = log.cursor;
            // Complete read: adopt the head. Partial: the next tick resumes
            // from the cursor we actually reached.
            latest = log.hasMore && !stalled ? log.cursor : log.latestSeq;
            if (!log.hasMore || stalled) break;
          }
        } else if (previous != null && room.latestSeq < previous.cursor) {
          // Authority rotated or the log rewound: rebaseline silently.
          events = [];
        }
        final level = await roomPrefs.notificationLevel(prefsRoomKey(room));
        final decision = decideRoomNotices(
          previous: previous,
          driverStatus: state.driverStatus,
          newEvents: events,
          latestSeq: latest,
          level: level,
          nowMs: _now().millisecondsSinceEpoch,
        );
        working = working || decision.next.working;
        final fresh = <RoomNotice>[];
        for (final notice in decision.notices) {
          final dedupe = notice.dedupeKey;
          if (dedupe == null || await claim(connId, room.roomId, dedupe)) {
            fresh.add(notice);
          }
        }
        if (fresh.isNotEmpty) {
          await presenter.present(connId, room, fresh);
        }
        all[key] = decision.next.toJson();
        for (final event in events) {
          if (event.kind == 'message.member' && event.publicText != null) {
            _lastMessages[key] = (
              memberId: event.activity.memberId ?? event.actor.id,
              text: event.publicText!,
            );
          }
        }
        views.add(
          RoomWatchView(
            room: room,
            driverStatus: state.driverStatus,
            state: decision.next,
            lastMemberId: _lastMessages[key]?.memberId,
            lastText: _lastMessages[key]?.text,
          ),
        );
      }
      _views = List.unmodifiable(views);
      all.removeWhere(
        (key, _) => key.startsWith('$connId|') && !seen.contains(key),
      );
      await prefs.setString(storageKey, jsonEncode(all));
      _failures = 0;
      _retryAt = null;
      _anyWorking = working;
      return true;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[hermes-rooms] watch failed (${error.runtimeType})');
      }
      _recordFailure();
      return false;
    }
  }
}
