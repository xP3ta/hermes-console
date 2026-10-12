import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../companion/models/companion_mood.dart';
import '../companion/render/companion_floating_pet.dart';
import '../companion/state/companion_controller.dart';
import '../companion/state/companion_presence_controller.dart';
import '../models/home_widget_snapshot.dart';
import '../services/active_chat_service.dart';
import '../services/approval_policy.dart';
import '../services/connection_manager.dart';
import '../services/home_widget_publisher.dart';
import '../services/notifications/background_listener.dart';
import '../services/notifications/notification_service.dart';
import '../services/notifications/notification_strings.dart';
import '../widgets/action_approval.dart';
import '../widgets/mascot/float/mascot_attention.dart';
import '../widgets/mascot/float/mascot_route_watch.dart';
import '../widgets/mascot/float/mascot_sources.dart';
import '../widgets/mascot/mascot_state.dart';

/// Feeds the floating mascot with what the app already knows. It starts
/// nothing of its own: no polling, no socket, no stream held on a chat.
///
/// | what the mascot says                | read from                         |
/// |-------------------------------------|-----------------------------------|
/// | a chat waits for a permission       | the attached chats (every profile |
/// |                                     | and instance) of [activeChats]    |
/// | a chat asks a question              | the same                          |
/// | another profile / instance has news | the in-app notices the app already|
/// |                                     | shows as banners ([onNotice])     |
/// | a task finished, a cron job failed  | the same                          |
/// | thinking, working, offline          | the attached chats of the active  |
/// |                                     | profile, the presence mood and the|
/// |                                     | last health the widget published  |
///
/// While the pet is not shown outside chats it listens to nothing but the
/// pet itself.
class MascotBridge {
  MascotBridge({
    required this.companion,
    required this.presence,
    required this.activeChats,
    required this.connManager,
    required this.notifications,
    required this.homeWidget,
    required this.context,
    required this.open,
    required this.openNotificationSettings,
    MascotRouteWatch? routes,
  }) : routes = routes ?? MascotRouteWatch.instance;

  final CompanionController companion;
  final CompanionPresenceController presence;
  final ActiveChatService activeChats;
  final ConnectionManager connManager;
  final NotificationService notifications;
  final HermesHomeWidgetPublisher homeWidget;
  final MascotRouteWatch routes;

  /// A context under the app (the navigator's), for the lock and notices.
  final BuildContext? Function() context;

  /// Goes to a chat, a job or a task the way a tap on its notification
  /// does (it switches instance when the target needs it).
  final void Function(NotificationOpen open) open;
  final VoidCallback openNotificationSettings;

  late final CompanionFloatingPet pet = CompanionFloatingPet(companion);
  final MascotAttention attention = MascotAttention();
  final ValueNotifier<MascotState> _activity = ValueNotifier<MascotState>(
    MascotState.idle,
  );

  late final MascotSources sources = MascotSources(
    permissions: attention.permissions,
    notices: attention.notices,
    activity: _activity,
  );

  bool _started = false;
  bool _listening = false;
  bool _queued = false;

  List<Listenable> get _signals => [
    activeChats.activeIds,
    activeChats.liveStatusRevision,
    presence,
    connManager.activeConnectionId,
    connManager.activeProfile,
    connManager.connectionsRevision,
    routes.settled,
  ];

  void start() {
    if (_started) return;
    _started = true;
    companion.addListener(_onPet);
    _onPet();
  }

  void dispose() {
    companion.removeListener(_onPet);
    _listen(false);
    attention.dispose();
    _activity.dispose();
  }

  void _onPet() => _listen(pet.shown);

  void _listen(bool on) {
    if (on == _listening) return;
    _listening = on;
    for (final signal in _signals) {
      on
          ? signal.addListener(_refreshSoon)
          : signal.removeListener(_refreshSoon);
    }
    on
        ? notifications.visibleSession.addListener(_onChatShown)
        : notifications.visibleSession.removeListener(_onChatShown);
    if (!on) {
      attention.clear();
      attention.setSuggestions(const []);
      _activity.value = MascotState.idle;
      return;
    }
    _refreshSoon();
    unawaited(_loadSuggestions());
  }

  /// The chat on screen is no longer news.
  void _onChatShown() {
    final id = notifications.visibleSession.value;
    if (id != null && id.isNotEmpty) attention.forget(null, id);
  }

  /// One refresh per burst of changes (the chats notify on every step).
  void _refreshSoon() {
    if (_queued) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (_listening) _refresh();
    });
  }

  SavedConnection? _connection(String id) {
    for (final connection in connManager.getConnections()) {
      if (connection.id == id) return connection;
    }
    return null;
  }

  MascotPlace _place(SavedConnection connection, String? profile) {
    final owner = Session.profileOwner(profile);
    return MascotPlace(
      connId: connection.id,
      connLabel: connection.label,
      profile: owner,
      profileLabel: owner == 'default' ? '' : owner,
    );
  }

  Iterable<ActiveChat> _attachedChats() sync* {
    final seen = <ActiveChat>{};
    for (final raw in activeChats.activeIds.value) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List || decoded.length != 3) continue;
        final conn = decoded[0];
        final profile = decoded[1];
        final session = decoded[2];
        if (conn is! String || profile is! String || session is! String) {
          continue;
        }
        final chat = activeChats.of(conn, session, profile: profile);
        if (chat != null && seen.add(chat)) yield chat;
      } catch (_) {
        // An id this reader does not understand is not a chat to report.
      }
    }
  }

  static String? _requestId(Map<String, dynamic> request) {
    final value = (request['request_id'] ?? request['approval_id'])
        ?.toString()
        .trim();
    return value == null || value.isEmpty ? null : value;
  }

  static String? _commandOf(Map<String, dynamic> request) {
    for (final key in const ['command', 'description', 'tool']) {
      final value = request[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  NotificationOpen _openOf(ActiveChat chat) => NotificationOpen(
    connId: chat.connection.id,
    sessionId: chat.storedSessionId ?? chat.serverSessionId,
    title: chat.sessionTitle,
    profile: Session.profileOwner(chat.sessionProfile),
    surface: chat.notificationSurface,
    roomId: chat.notificationRoomId,
  );

  void _refresh() {
    final connId = connManager.activeConnectionId.value;
    final profile = connId == null ? '' : connManager.activeProfileFor(connId);
    final owner = Session.profileOwner(profile);
    attention.setScope(connId: connId, profile: owner);

    final waiting = <MascotWaiting>[];
    var working = false;
    var thinking = false;
    for (final chat in _attachedChats()) {
      final place = _place(chat.connection, chat.sessionProfile);
      final request = chat.pendingApproval;
      final id = request == null ? null : _requestId(request);
      if (request != null && id != null) {
        waiting.add(
          MascotWaiting(
            key: '${chat.connection.id}:${chat.sessionId}:$id',
            place: place,
            title: chat.sessionTitle,
            command: _commandOf(request),
            resolve: (allow) => _answer(chat, request, allow),
            open: () => open(_openOf(chat)),
          ),
        );
      } else if (chat.pendingInteractivePrompt case final prompt?) {
        waiting.add(
          MascotWaiting(
            key:
                '${chat.connection.id}:${chat.sessionId}:'
                '${prompt.key.requestId}',
            place: place,
            title: chat.sessionTitle,
            open: () => open(_openOf(chat)),
          ),
        );
      }
      if (chat.connection.id != connId || place.owner != owner) continue;
      switch (chat.activityKind) {
        case ChatActivityKind.usingTools:
          working = true;
        case ChatActivityKind.thinking || ChatActivityKind.responding:
          thinking = true;
        case ChatActivityKind.awaitingApproval || null:
          break;
      }
    }
    attention.setWaiting(waiting);
    _activity.value = _stateOf(
      hasConnection: connId != null,
      working: working,
      thinking: thinking,
    );
  }

  MascotState _stateOf({
    required bool hasConnection,
    required bool working,
    required bool thinking,
  }) {
    if (hasConnection) {
      final health = homeWidget.latest.connectionState;
      if (health == HomeWidgetConnectionState.disconnected ||
          health == HomeWidgetConnectionState.error) {
        return MascotState.offline;
      }
    }
    final mood = presence.mood;
    if (mood == CompanionMood.error) return MascotState.error;
    if (working) return MascotState.tool;
    if (thinking || mood == CompanionMood.thinking) return MascotState.thinking;
    if (mood == CompanionMood.success) return MascotState.done;
    return MascotState.idle;
  }

  /// The same gate the chat and Inicio use: read-only blocks approving,
  /// approving asks the App Lock when the policy says so, denying never.
  Future<void> _answer(
    ActiveChat chat,
    Map<String, dynamic> request,
    bool allow,
  ) async {
    final context = this.context();
    if (context == null) return;
    final choice = allow ? ApprovalScope.once.wire : ApprovalScope.deny.wire;
    if (!permittedApprovalChoices(request).contains(choice)) {
      // This request does not take that answer from here: its chat does.
      open(_openOf(chat));
      return;
    }
    final allowed = await approvalAnswerAllowed(
      context,
      choice: choice,
      readOnlyInstance: chat.connection.readOnly,
      sessionId: chat.storedSessionId ?? chat.sessionId,
      reason: Strings.of(context).chaApproveOnce,
    );
    if (!allowed || !identical(chat.pendingApproval, request)) return;
    await chat.resolveApproval(choice);
  }

  /// Something the app is showing as a banner right now. The mascot keeps
  /// it for later when it is about another profile, another instance, or
  /// something that finished or failed.
  void onNotice(InAppNotice notice) {
    if (!_listening) return;
    // Permissions and questions are read live from the chats themselves.
    if (notice.kind == NotificationKind.approval ||
        notice.kind == NotificationKind.test) {
      return;
    }
    final target = notice.open;
    final connection = _connection(target.connId);
    if (connection == null) return;
    final id = [target.sessionId, target.jobId, target.taskId, target.runId]
        .whereType<String>()
        .firstWhere(
          (value) => value.trim().isNotEmpty,
          orElse: () => notice.title,
        );
    final strings = NotifL10n.of(connManager.prefs);
    attention.report(
      MascotEvent(
        id: id,
        place: _place(connection, target.profile),
        text: noticeLine(notice, strings),
        failed: noticeFailed(notice, strings),
        open: () => open(target),
      ),
    );
  }

  /// The banner's own title, with what it is about when the title does not
  /// say it.
  @visibleForTesting
  static String noticeLine(InAppNotice notice, NotifL10n strings) {
    final title = notice.title.trim();
    final hints = {
      strings.replyReadyBody,
      strings.sessionActivityBody,
      strings.backgroundTaskBody,
    };
    var subject = notice.open.title?.trim() ?? '';
    if (subject.isEmpty) {
      final body = notice.body.trim();
      if (!hints.contains(body)) subject = body.split('\n').first.trim();
    }
    if (subject.isEmpty || title.contains(subject)) return title;
    return title.isEmpty ? subject : '$title: $subject';
  }

  @visibleForTesting
  static bool noticeFailed(InAppNotice notice, NotifL10n strings) {
    final title = notice.title.trim();
    return {
      strings.runFailed,
      strings.sessionActivityFailedTitle,
      strings.backgroundTaskFailedTitle,
      strings.cronFailed,
      strings.kanbanCrashed,
      strings.kanbanTimedOut,
      strings.kanbanGaveUp,
      strings.replyFailedTitle(null),
      strings.replyFailedTitle(notice.open.title),
    }.contains(title);
  }

  /// Help that is true on this phone right now. Asked once when the mascot
  /// comes on; each one can be refused for good.
  Future<void> _loadSuggestions() async {
    if (!Platform.isAndroid) return;
    final suggestions = <MascotNotice>[];
    try {
      if (!await notifications.permissionGranted()) {
        suggestions.add(
          MascotNotice(
            key: 'notifications-off',
            kind: MascotNoticeKind.suggestion,
            text: (s) => s.mascotSuggestNotifications,
            action: (s) => s.mascotSuggestTurnOn,
            onAction: () => unawaited(
              notifications.requestPermission().then((_) => _loadSuggestions()),
            ),
          ),
        );
      } else if (!await BackgroundListener.isEnabled()) {
        suggestions.add(
          MascotNotice(
            key: 'background-off',
            kind: MascotNoticeKind.suggestion,
            text: (s) => s.mascotSuggestBackground,
            action: (s) => s.mascotSuggestOpenSettings,
            onAction: openNotificationSettings,
          ),
        );
      }
    } catch (_) {
      // No answer from the platform: nothing to suggest.
    }
    if (_listening) attention.setSuggestions(suggestions);
  }
}
