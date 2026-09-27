// UI-isolate executor for notification/widget actions. Every Flutter engine
// (UI, background listener, headless drain worker) is woken by the native
// inbox; the inbox's claim lease hands each tap to one of them. A live chat
// approval prefers the attached `ActiveChat`; without it the ops answer by
// durable identity on the server.
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../active_chat_service.dart';
import '../approval_policy.dart';
import '../connection_manager.dart';
import 'notification_action_drain.dart';
import 'notification_action_ops.dart';
import 'notification_strings.dart';
import 'rich_notifications.dart';

class UiNotificationActionHandler {
  UiNotificationActionHandler({
    required this.connManager,
    required this.activeChats,
    required this.prefs,
    PlatformRichNotifications? platform,
  }) : _platform = platform ?? PlatformRichNotifications();

  final ConnectionManager connManager;
  final ActiveChatService activeChats;
  final SharedPreferences prefs;
  final PlatformRichNotifications _platform;

  late final NotificationActionRouter _router = NotificationActionRouter(
    ops: GatewayNotificationActionOps(
      resolveConnection: (id) =>
          connManager.getConnections().where((c) => c.id == id).firstOrNull,
      chatApproval: _chatApproval,
    ),
    sink: _platform,
    t: NotifL10n.of(prefs),
    dedupe: PrefsActionDedupeStore(prefs),
  );

  late final NotificationActionDrainer _drainer = NotificationActionDrainer(
    inbox: _platform,
    router: _router,
    routes: allNotificationActionRoutes,
    rescue: DraftReplyRescue(prefs),
  );

  void start() {
    _platform.listen(() => unawaited(drain()));
    unawaited(drain());
  }

  Future<void> drain() async {
    _router.t = NotifL10n.of(prefs);
    await _drainer.drain();
  }

  /// True when the attached chat resolved it; false = not attached here.
  Future<bool> _chatApproval(NotificationActionPayload p, String choice) async {
    final chat = activeChats.of(p.connId, p.sessionId!, profile: p.profile);
    if (chat == null) return false;
    final pending = chat.pendingApproval;
    final requestId = (pending?['request_id'] ?? pending?['approval_id'])
        ?.toString()
        .trim();
    if (pending == null || requestId != p.requestId) {
      throw StateError('approval no longer pending');
    }
    if (!permittedApprovalChoices(pending).contains(choice)) {
      throw StateError('choice not permitted');
    }
    await chat.resolveApproval(choice);
    return true;
  }
}
