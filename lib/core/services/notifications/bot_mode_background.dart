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
import '../bot_roster_cache.dart';
import '../connection_manager.dart';
import '../shared_gateway_pool.dart';
import '../tui_gateway_client.dart';
import '../../widgets/hermes_bot_face.dart';
import '../bot_widget_activity.dart';
import '../../widgets/bot_face_identity.dart';
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
  // The original Hermes Console widgets are refreshed by
  // HermesHomeWidgetPublisher, not by this listener.
  'com.hermesagent.hermes_android.HermesBotsWidgetProvider',
  'com.hermesagent.hermes_android.HermesNeedsYouWidgetProvider',
  'com.hermesagent.hermes_android.HermesRoomWidgetProvider',
  'com.hermesagent.hermes_android.HermesQuickAskWidgetProvider',
  'com.hermesagent.hermes_android.HermesStatusWidgetProvider',
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
///
/// Live presence only; outcomes (done/failed), tickers, ordering and the
/// hero are applied afterwards by `BotWidgetActivityTracker`.
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
  String? rosterName(String profile) {
    for (final p in profiles) {
      if (p.name == profile && p.displayName.trim().isNotEmpty) {
        return p.displayName.trim();
      }
    }
    return null;
  }

  // Seat evidence per profile, with the room it belongs to.
  ({WidgetBotState state, HostedGroupRoom? room}) stateFor(
    AgentProfile profile,
  ) {
    final seats = <BotRoomSeat>[];
    final seatRooms = <String, HostedGroupRoom>{};
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
        seatRooms[view.room.roomId] = view.room;
      }
    }
    final state = switch (BotPresence.derive(
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
    // Attribute the state to the room whose seat proves the same level.
    HostedGroupRoom? room;
    for (final seat in seats) {
      final asked = seat.driverStatus.approvals.any(
        (a) => a.memberId == seat.memberId,
      );
      final level = asked
          ? WidgetBotState.needsYou
          : seat.running
          ? WidgetBotState.working
          : seat.queued
          ? WidgetBotState.thinking
          : WidgetBotState.idle;
      if (level != WidgetBotState.idle && level == state) {
        room = seatRooms[seat.roomId];
        break;
      }
    }
    return (state: state, room: room);
  }

  String nameOf(AgentProfile p) =>
      p.displayName.trim().isNotEmpty ? p.displayName.trim() : p.name;

  final bots = <WidgetBot>[
    for (final profile in profiles)
      () {
        final derived = stateFor(profile);
        final state = derived.state;
        final line = switch (state) {
          WidgetBotState.working || WidgetBotState.thinking =>
            botPublicStep(
                  profile: profile,
                  liveSessions: liveSessions,
                  now: now,
                  hideSensitive: hideSensitive,
                ) ??
                t.working,
          WidgetBotState.needsYou => t.needsYou(nameOf(profile)),
          _ => null,
        };
        // Server-resolved canonical chat only; never the legacy pin or the
        // most recent session (apps/desktop/src/AGENTS.md).
        final session = profile.canonicalBotChatSessionId ?? '';
        final room = derived.room;
        return WidgetBot(
          profile: profile.name,
          name: nameOf(profile),
          state: state,
          line: line == null || line.isEmpty ? null : line,
          facePath: facePaths['${profile.name}/${state.faceState}'],
          idleFacePath: facePaths['${profile.name}/idle'],
          role: hideSensitive ? null : _publicRole(profile),
          color: _identityColor(profile),
          roomId: room?.roomId,
          roomName: hideSensitive ? null : room?.name,
          pinned: profile.botPinned,
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
  bots.sort((a, b) => a.state.priority.compareTo(b.state.priority));

  final approvals = <WidgetApproval>[];
  for (final view in rooms) {
    for (final a
        in view.driverStatus?.approvals ?? const <RoomApprovalAction>[]) {
      final who = memberName(view.room, a.memberId, nameFor: rosterName);
      approvals.add(
        WidgetApproval(
          requestId: a.requestId,
          title: '$who · ${view.room.name}',
          text: hideSensitive
              ? t.approvalNeedsOk(null, null)
              : t.approvalNeedsOk(a.command, a.description),
          facePath:
              facePaths['${memberProfile(view.room, a.memberId)}/needsYou'],
          canApprove: writable && a.offers('once') && a.offers('deny'),
          // Room + member + request identity: a widget/notification button
          // can only ever answer THIS room's request.
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

  final chosen = [...rooms]
    ..sort((a, b) {
      int score(RoomWatchView v) =>
          (v.driverStatus?.approvals.isNotEmpty == true ? 4 : 0) +
          (v.driverStatus?.working == true ? 2 : 0) +
          (v.driverStatus?.needsUser == true ? 1 : 0);
      final s = score(b).compareTo(score(a));
      return s != 0 ? s : b.room.latestSeq.compareTo(a.room.latestSeq);
    });
  final widgetRooms = <WidgetRoom>[
    for (final v in chosen.take(4))
      () {
        final status = v.driverStatus;
        final approvalsBy = {
          for (final a in status?.approvals ?? const <RoomApprovalAction>[])
            a.memberId,
        };
        final members = [
          for (final m in v.room.members)
            WidgetRoomMember(
              memberName(v.room, m.memberId, nameFor: rosterName),
              approvalsBy.contains(m.memberId)
                  ? 'needs_you'
                  : v.state.openMembers.contains(m.memberId)
                  ? (status?.working == true ? 'working' : 'queued')
                  : v.state.repliers.contains(m.memberId)
                  ? 'done'
                  : 'idle',
              profile: m.owner.profile,
            ),
        ];
        final phase = approvalsBy.isNotEmpty
            ? 'needs_you'
            : status?.working == true ||
                  (status?.running == true && v.state.openMembers.isNotEmpty)
            ? 'working'
            : 'idle';
        return WidgetRoom(
          roomId: v.room.roomId,
          name: v.room.name,
          working: status?.working == true,
          members: [
            for (final m in members)
              m.withFace(
                m.profile == null
                    ? null
                    : facePaths['${m.profile}/${m.faceState}'],
              ),
          ],
          phase: phase,
          steps: roomRoundSteps(members, t),
          lastSpeaker: hideSensitive || v.lastMemberId == null
              ? null
              : memberName(v.room, v.lastMemberId!, nameFor: rosterName),
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
      }(),
  ];

  return BotModeWidgetSnapshot(
    connectionId: connection.id,
    connectionLabel: connection.label,
    connected: connected,
    bots: bots,
    approvals: approvals,
    rooms: widgetRooms,
    updatedAtMs: now.millisecondsSinceEpoch,
  );
}

/// Public display step for a working Bot: its fresh worker-session title,
/// else the title of its live session. Titles are public display metadata
/// (the session list shows them); previews, tool names/arguments and paths
/// never are. Null when hidden or unknown.
String? botPublicStep({
  required AgentProfile profile,
  required List<DesktopActiveSession> liveSessions,
  required DateTime now,
  bool hideSensitive = false,
}) {
  if (hideSensitive) return null;
  final worker = profile.workerSession;
  if (worker != null && BotPresence.workerIsFresh(worker, now)) {
    final title = plainNotificationText(worker.title, max: 60);
    if (title.isNotEmpty) return title;
  }
  final own = {
    for (final s in [
      profile.canonicalSession,
      profile.lastSession,
      profile.preferredSession,
    ])
      if (s != null) ...[s.id, ?s.resolvedId],
  };
  for (final live in liveSessions) {
    if (live.status != 'working' && live.status != 'starting') continue;
    if (live.storedSessionId == null || !own.contains(live.storedSessionId)) {
      continue;
    }
    final title = plainNotificationText(live.title, max: 60);
    if (title.isNotEmpty) return title;
  }
  return null;
}

/// Round ticker for a room: replied members first (in reply order), then
/// working, then waiting on you; last three.
List<String> roomRoundSteps(List<WidgetRoomMember> members, NotifL10n t) {
  final steps = <String>[
    for (final m in members)
      if (m.state == 'done') t.stepReplied(m.name),
    for (final m in members)
      if (m.state == 'working' || m.state == 'queued') t.stepWorking(m.name),
    for (final m in members)
      if (m.state == 'needs_you') t.needsYou(m.name),
  ];
  return steps.length > 3 ? steps.sublist(steps.length - 3) : steps;
}

String? _publicRole(AgentProfile p) {
  final title = p.mentionTitle.trim();
  if (title.isEmpty) return null;
  final plain = plainNotificationText(title, max: 40);
  return plain.isEmpty ? null : plain;
}

int? _identityColor(AgentProfile p) {
  final hex = p.botColorHex;
  if (hex != null) return 0xFF000000 | int.parse(hex.substring(1), radix: 16);
  final visual = BotFaceBitmapCache.visualFor(p.name, p.botFaceShape);
  if (visual is HermesBlobatarFaceVisual) return visual.headColor.toARGB32();
  return null;
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

  /// A round was just started from this device: read rooms on the next
  /// tick (drop any empty-list backoff) and ask for the fast cadence until
  /// a pass says otherwise.
  void kick() {
    _nextNetworkAt = null;
    _emptyStreak = 0;
    _cadence = BotModeCadence.active;
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

  /// One pooled lease for the listener's lifetime (per watched connection):
  /// the socket stays open between ticks (WS ping keeps it alive) instead of
  /// a handshake + dashboard ticket every 30-180 s. Released on stop or when
  /// the watched connection changes; a dropped socket reconnects through the
  /// gateway owner's backoff.
  SharedGatewayLease? _lease;
  String? _leaseConnId;

  SharedGatewayLease _leaseFor(SavedConnection connection) {
    final current = _lease;
    if (current != null &&
        _leaseConnId == connection.id &&
        !current.client.isClosed) {
      return current;
    }
    current?.release();
    _leaseConnId = connection.id;
    return _lease = _pool.acquire(connection);
  }

  void _releaseLease() {
    _lease?.release();
    _lease = null;
    _leaseConnId = null;
  }

  static const _profilesTtl = Duration(minutes: 3);

  bool get anyWorking => _watcher?.anyWorking ?? false;

  BotModeCadence get cadence => _policy.cadence;

  /// The UI just sent a message to a room (see [BotModeTickPolicy.kick]).
  void expectActivity() => _policy.kick();

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
      if (kDebugMode) {
        debugPrint('[hermes-rooms] actions (${error.runtimeType})');
      }
    }
  }

  /// Configured face of [profile] (shared resolver); null when unknown.
  BotFaceIdentity? _identity(String connId, String profile) {
    for (final p in _profiles) {
      if (p.name == profile) return BotFaceIdentity.ofProfile(p);
    }
    return null;
  }

  /// Roster display name of [profile] (room members without a room name).
  String? _displayName(String profile) {
    for (final p in _profiles) {
      if (p.name == profile) {
        final name = p.displayName.trim();
        return name.isEmpty ? null : name;
      }
    }
    return null;
  }

  /// Raster avatar of an avatar identity, loaded through the current
  /// gateway lease and memoised per roster refresh.
  Future<Uint8List?> Function(String profile)? _avatarLoader;

  Future<Uint8List?> _image(String connId, String profile) async {
    final load = _avatarLoader;
    if (load == null) return _avatars[profile];
    return _avatarBytes(profile, load);
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
      identityFor: _identity,
      imageFor: _image,
      nameFor: _displayName,
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
    // One pooled socket held across passes (rooms, profiles, live list,
    // widgets): no handshake per tick.
    final lease = _leaseFor(connection);
    _avatarLoader = (profile) async =>
        (await lease.client.profileAvatar(profile))?.bytes;
    {
      final gateway = _gatewayFor(lease.client);
      await _refreshProfiles(gateway, prefs, connection);
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
      await _publishWidgets(
        prefs,
        connection,
        gateway,
        connected: ok,
        avatar: _avatarLoader,
      );
    }
    return _policy.cadence == BotModeCadence.active;
  }

  Future<void> _expireIfUnreachable(DateTime now) async {
    final ok = _lastOkAt;
    if (ok != null && now.difference(ok) < unreachableAfter) return;
    await _presenter?.cancelAllLive();
  }

  Future<void> _refreshProfiles(
    BotModeGateway gateway,
    SharedPreferences prefs,
    SavedConnection connection,
  ) async {
    final at = _profilesAt;
    if (at != null && _now().difference(at) < _profilesTtl) return;
    try {
      _profiles = await gateway.listProfiles();
      _profilesAt = _now();
      // This isolate has its own memory: the persisted cache is how the app
      // shows this roster on its next cold start.
      unawaited(
        BotRosterCache(prefs)
            .write(connection, _profiles)
            .catchError((Object _) {}),
      );
      // Avatars may have changed with the roster.
      _avatars.clear();
    } catch (_) {}
  }

  Future<void> _publishWidgets(
    SharedPreferences prefs,
    SavedConnection connection,
    BotModeGateway gateway, {
    required bool connected,
    Future<Uint8List?> Function(String profile)? avatar,
  }) async {
    try {
      var live = const <DesktopActiveSession>[];
      if (connected) {
        try {
          live = (await gateway.listActiveSessions()).sessions;
        } catch (_) {}
      }
      final rooms = _watcher?.views ?? const <RoomWatchView>[];
      final hideSensitive =
          prefs.getBool('notif_hide_sensitive_content') ?? false;
      final t = NotifL10n.of(prefs);
      final now = _now();
      final built = buildBotModeWidgetSnapshot(
        connection: connection,
        connected: connected,
        profiles: _profiles.take(16).toList(),
        liveSessions: live,
        rooms: rooms,
        facePaths: const {},
        t: t,
        now: now,
        hideSensitive: hideSensitive,
      );
      final tracked =
          await (_activity ??= BotWidgetActivityTracker(
            PrefsBotWidgetActivityStore(prefs),
          )).apply(
            built,
            now: now,
            roomFailed: {
              for (final v in rooms)
                if (v.driverStatus?.blocked == true) v.room.roomId,
            },
          );
      // Expression frames rotate on every published update (widgets cannot
      // animate); content-addressed files keep this bounded.
      final frame = now.millisecondsSinceEpoch ~/ 30000;
      final faces = <String, String?>{};
      for (final key in tracked.faceKeys) {
        final slash = key.lastIndexOf('/');
        final profile = key.substring(0, slash);
        final state =
            BotFaceBitmapState.values.asNameMap()[key.substring(slash + 1)] ??
            BotFaceBitmapState.idle;
        final identity =
            _identity(connection.id, profile) ??
            BotFaceIdentity.resolve(profile: profile);
        final photo = identity.source == BotFaceSource.avatar && avatar != null
            ? await _avatarBytes(profile, avatar)
            : null;
        faces[key] = await _faces.pathFor(
          profile: profile,
          identity: identity,
          state: state,
          size: 192,
          frame: frame,
          plate: false,
          image: photo,
        );
      }
      await _publish(tracked.withFaces(faces));
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[hermes-widgets] publish (${error.runtimeType})');
      }
    }
  }

  BotWidgetActivityTracker? _activity;
  final Map<String, Uint8List?> _avatars = {};

  Future<Uint8List?> _avatarBytes(
    String profile,
    Future<Uint8List?> Function(String profile) load,
  ) async {
    if (_avatars.containsKey(profile)) return _avatars[profile];
    try {
      return _avatars[profile] = await load(profile);
    } catch (_) {
      return _avatars[profile] = null;
    }
  }

  Future<void> _dropWatcher() async {
    _releaseLease();
    _avatarLoader = null;
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
Future<void> publishBotModeWidgetSnapshot(
  BotModeWidgetSnapshot snapshot,
) async {
  final encoded = snapshot.encode();
  // `updated_at_ms` changes every tick; compare without it to avoid redraws.
  final comparable = encoded.replaceFirst(RegExp(r'"updated_at_ms":\d+'), '');
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
