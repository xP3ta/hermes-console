// Bot Mode work for the background listener isolate (spec 070 T607 + T701..3):
// watches hosted rooms of the active connection, answers notification/widget
// actions through the same server calls as the app, and publishes the Bot
// Mode widget snapshot. Called from the existing foreground-service tick; it
// owns no timers.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../bots/data/bot_mode_repository.dart';
import '../../bots/state/bot_presence.dart';
import '../../models/agent_profile.dart';
import '../../models/bot_mode_widget_snapshot.dart';
import '../../models/desktop_active_session.dart';
import '../../models/hosted_groups.dart';
import '../connection_manager.dart';
import '../shared_gateway_pool.dart';
import '../tui_gateway_client.dart';
import 'bot_face_bitmap.dart';
import 'bot_notification_presenter.dart';
import 'notification_event_ledger.dart';
import 'notification_action_drain.dart';
import 'notification_service.dart';
import 'notification_strings.dart';
import 'notification_action_ops.dart';
import 'rich_notifications.dart';
import 'room_watcher.dart';

/// Android receivers of the Bot Mode widget family.
const botModeWidgetProviders = <String>[
  // Legacy receiver names (placed widgets migrate in place): Bots, Status,
  // Quick ask. Needs you and Room are new.
  'com.hermesagent.hermes_android.NewSessionWidgetProvider',
  'com.hermesagent.hermes_android.HermesCompactWidgetProvider',
  'com.hermesagent.hermes_android.HermesControlWidgetProvider',
  'com.hermesagent.hermes_android.HermesNeedsYouWidgetProvider',
  'com.hermesagent.hermes_android.HermesRoomWidgetProvider',
];

/// Connection whose rooms are watched: the last one the user opened, else
/// the default, else the first eligible target.
SavedConnection? activeWatchConnection(
  SharedPreferences prefs,
  List<SavedConnection> targets,
) {
  if (targets.isEmpty) return null;
  for (final key in const [
    ConnectionManager.lastConnKey,
    ConnectionManager.defaultConnKey,
  ]) {
    final id = prefs.getString(key);
    for (final c in targets) {
      if (c.id == id) return c;
    }
  }
  return targets.first;
}

/// Builds the widget snapshot from server evidence gathered this tick.
BotModeWidgetSnapshot buildBotModeWidgetSnapshot({
  required SavedConnection connection,
  required bool connected,
  required List<AgentProfile> profiles,
  required List<DesktopActiveSession> liveSessions,
  required List<RoomWatchView> rooms,
  required Map<String, String?> facePaths,
  required NotifL10n t,
  required DateTime now,
  bool hideSensitive = false,
}) {
  final writable = !connection.readOnly;
  WidgetBotState stateFor(AgentProfile profile) {
    final seats = <BotRoomSeat>[];
    for (final view in rooms) {
      final status = view.driverStatus;
      if (status == null) continue;
      for (final m in view.room.members) {
        if (m.owner.profile != profile.name ||
            m.owner.connectionId != view.room.authorityGatewayId) {
          continue;
        }
        final open = view.state.openMembers.contains(m.memberId);
        final asked = status.approvals.any((a) => a.memberId == m.memberId);
        seats.add(
          BotRoomSeat(
            roomId: view.room.roomId,
            memberId: m.memberId,
            driverStatus: status,
            running: status.working && open && !asked,
            queued: !status.working && status.running && open,
          ),
        );
      }
    }
    return switch (BotPresence.derive(
      profile: profile,
      now: now,
      liveSessions: liveSessions,
      roomSeats: seats,
    )) {
      BotPresence.idle => WidgetBotState.idle,
      BotPresence.thinking => WidgetBotState.thinking,
      BotPresence.working => WidgetBotState.working,
      BotPresence.attention => WidgetBotState.needsYou,
    };
  }

  String nameOf(AgentProfile p) =>
      p.displayName.trim().isNotEmpty ? p.displayName.trim() : p.name;

  final bots = <WidgetBot>[
    for (final profile in profiles)
      () {
        final state = stateFor(profile);
        final worker = profile.workerSession;
        final line = switch (state) {
          WidgetBotState.working || WidgetBotState.thinking =>
            !hideSensitive &&
                    worker != null &&
                    BotPresence.workerIsFresh(worker, now)
                ? plainNotificationText(worker.title, max: 60)
                : t.thinking,
          WidgetBotState.needsYou => t.needsYou(nameOf(profile)),
          WidgetBotState.idle => null,
        };
        // Server-resolved canonical chat only; never the legacy pin or the
        // most recent session (apps/desktop/src/AGENTS.md).
        final session = profile.canonicalBotChatSessionId ?? '';
        return WidgetBot(
          profile: profile.name,
          name: nameOf(profile),
          state: state,
          line: line == null || line.isEmpty ? null : line,
          facePath: facePaths['${profile.name}/${state.name}'],
          openPayload: NotificationOpen(
            connId: connection.id,
            // A payload needs one destination; Bot Mode opens the Bot by
            // profile, so a Bot without a chat yet still deep-links.
            sessionId: session.isEmpty ? profile.name : session,
            title: nameOf(profile),
            profile: profile.name,
            surface: NotificationChatSurface.bot,
          ).toPayload(),
        );
      }(),
  ];
  bots.sort((a, b) {
    int rank(WidgetBotState s) => switch (s) {
      WidgetBotState.needsYou => 0,
      WidgetBotState.working => 1,
      WidgetBotState.thinking => 2,
      WidgetBotState.idle => 3,
    };
    return rank(a.state).compareTo(rank(b.state));
  });

  final approvals = <WidgetApproval>[];
  for (final view in rooms) {
    for (final a in view.driverStatus?.approvals ?? const <RoomApprovalAction>[]) {
      final who = memberName(view.room, a.memberId);
      approvals.add(
        WidgetApproval(
          requestId: a.requestId,
          title: '$who · ${view.room.name}',
          text: hideSensitive
              ? t.approvalNeedsOk(null, null)
              : t.approvalNeedsOk(a.command, a.description),
          facePath: facePaths['${memberProfile(view.room, a.memberId)}/needsYou'],
          canApprove: writable && a.offers('once') && a.offers('deny'),
          actionPayload: NotificationActionPayload(
            route: NotificationActionRoute.room,
            connId: connection.id,
            roomId: view.room.roomId,
            requestId: a.requestId,
            taskId: a.taskId,
            memberId: a.memberId,
            executionGeneration: a.executionGeneration,
            choices: a.choices,
          ).encode(),
          openPayload: _roomOpen(connection.id, view.room).toPayload(),
        ),
      );
    }
  }

  WidgetRoom? room;
  final chosen = [...rooms]
    ..sort((a, b) {
      int score(RoomWatchView v) =>
          (v.driverStatus?.working == true ? 2 : 0) +
          (v.driverStatus?.needsUser == true ? 1 : 0);
      final s = score(b).compareTo(score(a));
      return s != 0 ? s : b.room.latestSeq.compareTo(a.room.latestSeq);
    });
  if (chosen.isNotEmpty) {
    final v = chosen.first;
    final status = v.driverStatus;
    final approvalsBy = {
      for (final a in status?.approvals ?? const <RoomApprovalAction>[])
        a.memberId,
    };
    room = WidgetRoom(
      roomId: v.room.roomId,
      name: v.room.name,
      working: status?.working == true,
      members: [
        for (final m in v.room.members)
          WidgetRoomMember(
            m.displayName?.trim().isNotEmpty == true
                ? m.displayName!.trim()
                : m.handle,
            approvalsBy.contains(m.memberId)
                ? 'needs_you'
                : v.state.openMembers.contains(m.memberId)
                ? (status?.working == true ? 'working' : 'queued')
                : v.state.repliers.contains(m.memberId)
                ? 'done'
                : 'idle',
            facePath: facePaths['${m.owner.profile}/idle'],
          ),
      ],
      lastSpeaker: hideSensitive || v.lastMemberId == null
          ? null
          : memberName(v.room, v.lastMemberId!),
      lastMessage: hideSensitive || v.lastText == null
          ? null
          : plainNotificationText(v.lastText, max: 120),
      openPayload: _roomOpen(connection.id, v.room).toPayload(),
      stopPayload: writable && status?.working == true
          ? NotificationActionPayload(
              route: NotificationActionRoute.room,
              connId: connection.id,
              roomId: v.room.roomId,
            ).encode()
          : null,
    );
  }

  return BotModeWidgetSnapshot(
    connectionId: connection.id,
    connectionLabel: connection.label,
    connected: connected,
    bots: bots,
    approvals: approvals,
    room: room,
    updatedAtMs: now.millisecondsSinceEpoch,
  );
}

NotificationOpen _roomOpen(String connId, HostedGroupRoom room) =>
    NotificationOpen(
      connId: connId,
      sessionId: room.roomId,
      title: room.name,
      surface: NotificationChatSurface.room,
      roomId: room.roomId,
    );

/// Listener cadence requested by Bot Mode.
enum BotModeCadence {
  /// Nothing to watch closely: the listener keeps its base cadence (180 s,
  /// or 60 s while Cron/Kanban are watched).
  idle,

  /// A watched room works or waits for an approval: 30 s.
  active,
}

/// Pure network/cadence policy for the Bot Mode part of the listener tick
/// (spec 070 P1-6). Rooms are read every tick only while some exist; an
/// empty `groups.list` backs off (5 → 10 min, below the widget's 12 min
/// staleness guard) so gateways without rooms cost one socket per ~10 min
/// instead of one per minute.
class BotModeTickPolicy {
  BotModeTickPolicy({
    this.emptyBackoff = const Duration(minutes: 5),
    this.maxEmptyBackoff = const Duration(minutes: 10),
  });

  final Duration emptyBackoff;
  final Duration maxEmptyBackoff;
  DateTime? _nextNetworkAt;
  int _emptyStreak = 0;
  BotModeCadence _cadence = BotModeCadence.idle;

  BotModeCadence get cadence => _cadence;

  /// Whether this tick should open the gateway socket at all.
  bool shouldConnect(DateTime now) {
    final at = _nextNetworkAt;
    return at == null || !now.isBefore(at);
  }

  /// Records a completed network pass.
  void record({
    required DateTime now,
    required bool ok,
    required int rooms,
    required bool working,
    required bool pendingApprovals,
  }) {
    _cadence = ok && (working || pendingApprovals)
        ? BotModeCadence.active
        : BotModeCadence.idle;
    if (!ok || rooms > 0) {
      // Failures use the watcher's own exponential backoff.
      _emptyStreak = 0;
      _nextNetworkAt = null;
      return;
    }
    _emptyStreak++;
    var delay = emptyBackoff;
    for (var i = 1; i < _emptyStreak && delay < maxEmptyBackoff; i++) {
      delay *= 2;
    }
    if (delay > maxEmptyBackoff) delay = maxEmptyBackoff;
    _nextNetworkAt = now.add(delay);
  }

  void reset() {
    _nextNetworkAt = null;
    _emptyStreak = 0;
    _cadence = BotModeCadence.idle;
  }
}

class BotModeBackgroundMonitor {
  BotModeBackgroundMonitor({
    PlatformRichNotifications? platform,
    RichNotificationSink? sink,
    BotFaceBitmapCache? faces,
    SharedGatewayPool? pool,
    DateTime Function()? now,
    BotModeTickPolicy? policy,
    Future<void> Function(BotModeWidgetSnapshot snapshot)? publish,
    BotModeGateway Function(TuiGatewayClient client)? gatewayFor,
    this.unreachableAfter = const Duration(minutes: 2),
  }) : _gatewayFor = gatewayFor ?? TuiBotModeGateway.new,
       _platform = platform ?? PlatformRichNotifications(),
       _faces = faces ?? BotFaceBitmapCache(),
       _pool = pool ?? SharedGatewayPool.instance,
       _now = now ?? DateTime.now,
       _policy = policy ?? BotModeTickPolicy(),
       _publish = publish ?? publishBotModeWidgetSnapshot {
    _sink = sink ?? _platform;
  }

  final PlatformRichNotifications _platform;
  late final RichNotificationSink _sink;
  final BotFaceBitmapCache _faces;
  final SharedGatewayPool _pool;
  final DateTime Function() _now;
  final BotModeTickPolicy _policy;
  final Future<void> Function(BotModeWidgetSnapshot snapshot) _publish;
  final BotModeGateway Function(TuiGatewayClient client) _gatewayFor;

  /// Beyond this without a successful pass, Live Updates are withdrawn.
  final Duration unreachableAfter;

  RoomWatcher? _watcher;
  RichRoomNoticePresenter? _presenter;
  String? _watchConnId;
  DateTime? _lastOkAt;
  List<SavedConnection> _targets = const [];
  List<AgentProfile> _profiles = const [];
  DateTime? _profilesAt;
  bool _listening = false;
  NotificationActionDrainer? _drainer;

  static const _profilesTtl = Duration(minutes: 3);

  bool get anyWorking => _watcher?.anyWorking ?? false;

  BotModeCadence get cadence => _policy.cadence;

  /// The listener executes every route: room / run / Bot Chat through the
  /// same server calls as the app, and live chat approvals by durable
  /// identity (`approval.respond` + `request_id`) when the UI is gone.
  static const backgroundRoutes = allNotificationActionRoutes;

  void _ensureListening(SharedPreferences prefs) {
    if (_listening) return;
    _listening = true;
    _platform.listen(() => unawaited(handlePendingActions(prefs)));
  }

  NotificationActionDrainer _drainerFor(SharedPreferences prefs) =>
      _drainer ??= NotificationActionDrainer(
        inbox: _platform,
        routes: backgroundRoutes,
        rescue: DraftReplyRescue(prefs),
        router: NotificationActionRouter(
          ops: GatewayNotificationActionOps(
            resolveConnection: (id) =>
                _targets.where((c) => c.id == id).firstOrNull,
            pool: _pool,
          ),
          sink: _platform,
          t: NotifL10n.of(prefs),
          dedupe: PrefsActionDedupeStore(prefs),
        ),
      );

  Future<void> handlePendingActions(SharedPreferences prefs) async {
    try {
      final drainer = _drainerFor(prefs);
      drainer.router.t = NotifL10n.of(prefs);
      await drainer.drain();
    } catch (error) {
      if (kDebugMode) debugPrint('[hermes-rooms] actions (${error.runtimeType})');
    }
  }

  Future<String?> _shape(String connId, String profile) async {
    for (final p in _profiles) {
      if (p.name == profile) return p.botShape;
    }
    return null;
  }

  /// One pass. Returns true when Bot Mode needs the fast (30 s) cadence.
  Future<bool> tick({
    required SharedPreferences prefs,
    required List<SavedConnection> targets,
    required bool notificationsEnabled,
  }) async {
    _targets = targets;
    _ensureListening(prefs);
    await handlePendingActions(prefs);
    final connection = activeWatchConnection(prefs, targets);
    if (connection == null || !notificationsEnabled) {
      await _dropWatcher();
      return false;
    }
    if (_watchConnId != connection.id) {
      // Live Updates belong to the connection that posted them.
      await _dropWatcher();
    }
    _watchConnId = connection.id;
    final presenter = _presenter ??= RichRoomNoticePresenter(
      sink: _sink,
      prefs: prefs,
      faces: _faces,
      shapeFor: _shape,
      now: _now,
      readOnly: connection.readOnly,
    );
    final watcher = _watcher ??= RoomWatcher(
      connId: connection.id,
      prefs: prefs,
      now: _now,
      presenter: presenter,
      claim: (connId, roomId, key) => NotificationEventLedger(prefs).claim(
        connId: connId,
        profile: 'rooms',
        objectId: roomId,
        eventKind: key,
      ),
    );
    final now = _now();
    if (!watcher.allowsAttempt || !_policy.shouldConnect(now)) {
      await _expireIfUnreachable(now);
      return _policy.cadence == BotModeCadence.active;
    }
    // One pooled socket for the whole pass (rooms, profiles, live list,
    // widgets), released at the end: no socket stays open between ticks.
    final lease = _pool.acquire(connection);
    try {
      final gateway = _gatewayFor(lease.client);
      await _refreshProfiles(gateway);
      final ok = await watcher.tick(gateway);
      final at = _now();
      if (ok) {
        _lastOkAt = at;
        final live = {
          for (final v in watcher.views)
            RichNotificationIds.roomTag(connection.id, v.room.roomId),
        };
        // Rooms that left `groups.list` (disbanded, beyond maxRooms) are
        // never evaluated again: withdraw their Live Update now.
        await presenter.cancelLiveExcept(live);
      } else {
        await _expireIfUnreachable(at);
      }
      _policy.record(
        now: at,
        ok: ok,
        rooms: watcher.views.length,
        working: watcher.anyWorking,
        pendingApprovals: watcher.views.any(
          (v) => v.driverStatus?.approvals.isNotEmpty == true,
        ),
      );
      await _publishWidgets(prefs, connection, gateway, connected: ok);
    } finally {
      lease.release();
    }
    return _policy.cadence == BotModeCadence.active;
  }

  Future<void> _expireIfUnreachable(DateTime now) async {
    final ok = _lastOkAt;
    if (ok != null && now.difference(ok) < unreachableAfter) return;
    await _presenter?.cancelAllLive();
  }

  Future<void> _refreshProfiles(BotModeGateway gateway) async {
    final at = _profilesAt;
    if (at != null && _now().difference(at) < _profilesTtl) return;
    try {
      _profiles = await gateway.listProfiles();
      _profilesAt = _now();
    } catch (_) {}
  }

  Future<void> _publishWidgets(
    SharedPreferences prefs,
    SavedConnection connection,
    BotModeGateway gateway, {
    required bool connected,
  }) async {
    try {
      var live = const <DesktopActiveSession>[];
      if (connected) {
        try {
          live = (await gateway.listActiveSessions()).sessions;
        } catch (_) {}
      }
      final rooms = _watcher?.views ?? const <RoomWatchView>[];
      final faces = <String, String?>{};
      Future<void> face(String? profile, BotFaceBitmapState state) async {
        if (profile == null) return;
        final key = '$profile/${state.name}';
        if (faces.containsKey(key)) return;
        faces[key] = await _faces.pathFor(
          profile: profile,
          shape: await _shape(connection.id, profile),
          state: state,
        );
      }

      for (final p in _profiles.take(16)) {
        for (final s in BotFaceBitmapState.values) {
          if (s != BotFaceBitmapState.failed) await face(p.name, s);
        }
      }
      for (final v in rooms) {
        for (final m in v.room.members.take(6)) {
          await face(m.owner.profile, BotFaceBitmapState.idle);
          await face(m.owner.profile, BotFaceBitmapState.needsYou);
        }
      }
      final snapshot = buildBotModeWidgetSnapshot(
        connection: connection,
        connected: connected,
        profiles: _profiles,
        liveSessions: live,
        rooms: rooms,
        facePaths: faces,
        t: NotifL10n.of(prefs),
        now: _now(),
        hideSensitive: prefs.getBool('notif_hide_sensitive_content') ?? false,
      );
      await _publish(snapshot);
    } catch (error) {
      if (kDebugMode) debugPrint('[hermes-widgets] publish (${error.runtimeType})');
    }
  }

  Future<void> _dropWatcher() async {
    try {
      await _presenter?.cancelAllLive();
    } catch (_) {}
    _presenter = null;
    _watcher = null;
    _watchConnId = null;
    _lastOkAt = null;
    _policy.reset();
  }

  /// Listener stopped: no Live Update may outlive it.
  Future<void> close() => _dropWatcher();
}

String? _lastPublished;
int _lastPublishedAtMs = 0;

/// Writes the snapshot atomically and asks the Bot Mode widgets to redraw.
Future<void> publishBotModeWidgetSnapshot(BotModeWidgetSnapshot snapshot) async {
  final encoded = snapshot.encode();
  // `updated_at_ms` changes every tick; compare without it to avoid redraws.
  final comparable = encoded.replaceFirst(
    RegExp(r'"updated_at_ms":\d+'),
    '',
  );
  // Identical content is skipped, but refreshed every 5 min so the widget's
  // staleness guard keeps seeing a live listener.
  if (comparable == _lastPublished &&
      snapshot.updatedAtMs - _lastPublishedAtMs < 5 * 60 * 1000) {
    return;
  }
  await HomeWidget.saveWidgetData<String>(
    BotModeWidgetSnapshot.storageKey,
    encoded,
  );
  for (final provider in botModeWidgetProviders) {
    try {
      await HomeWidget.updateWidget(qualifiedAndroidName: provider);
    } catch (_) {}
  }
  _lastPublished = comparable;
  _lastPublishedAtMs = snapshot.updatedAtMs;
}
