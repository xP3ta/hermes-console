// Shared executor for notification / widget taps (spec 070 P1-2). The UI
// isolate, the background listener and the headless drain worker all run
// the same [NotificationActionDrainer]:
//  * one router per isolate, persistent semantic dedupe (cross-drain and
//    cross-engine, stored in SharedPreferences);
//  * at-least-once: an entry leaves the native inbox only after it reached a
//    terminal outcome (ack); a claim whose isolate died is re-delivered and
//    replayed only on server-idempotent routes;
//  * a reply that failed or expired never disappears: its text moves to the
//    conversation's encrypted composer draft (`ChatDraftStore`) and the card
//    says "Couldn't send · open to retry".
import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat_draft_store.dart';
import '../connection_manager.dart';
import '../secure_storage.dart';
import 'notification_action_ops.dart';
import 'notification_strings.dart';
import 'rich_notifications.dart';

/// Persistent semantic dedupe shared by every isolate of this install.
class PrefsActionDedupeStore implements ActionDedupeStore {
  PrefsActionDedupeStore(this.prefs);

  final SharedPreferences prefs;
  static const storageKey = 'notif_action_dedupe_v1';

  Future<Map<String, Object?>> _load() async {
    try {
      await prefs.reload();
    } catch (_) {}
    try {
      final raw = prefs.getString(storageKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      return decoded is Map ? Map<String, Object?>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  @override
  Future<String?> stateOf(String key, DateTime now, Duration window) async {
    final all = await _load();
    final entry = all[key];
    if (entry is! Map) return null;
    final at = entry['at'];
    if (at is! int || now.millisecondsSinceEpoch - at > window.inMilliseconds) {
      return null;
    }
    return entry['s'] as String?;
  }

  @override
  Future<void> mark(String key, String state, DateTime now) async {
    final all = await _load();
    final cutoff = now.millisecondsSinceEpoch - const Duration(hours: 1).inMilliseconds;
    all.removeWhere((_, v) => v is! Map || (v['at'] as int? ?? 0) < cutoff);
    all[key] = {'s': state, 'at': now.millisecondsSinceEpoch};
    await prefs.setString(storageKey, jsonEncode(all));
  }

  @override
  Future<void> forget(String key) async {
    final all = await _load();
    if (all.remove(key) != null) {
      await prefs.setString(storageKey, jsonEncode(all));
    }
  }
}

/// Where a reply that could not be delivered waits for the user.
abstract interface class ReplyRescue {
  Future<void> keep(NotificationActionPayload payload, String text);
}

/// Composer-draft key of the destination conversation (same keys the Bot
/// Chat and Room screens read).
({String sessionId, String profile})? replyDraftAddress(
  NotificationActionPayload p, {
  required String activeProfile,
}) {
  switch (p.route) {
    case NotificationActionRoute.botChat:
      final profile = p.profile;
      if (profile == null) return null;
      return (sessionId: 'mob-bot-$profile', profile: profile);
    case NotificationActionRoute.room:
      final room = p.roomId;
      final authority = p.authorityId;
      if (room == null || authority == null) return null;
      return (
        sessionId:
            'mob-room-${base64Url.encode(utf8.encode(jsonEncode([authority, room])))}',
        profile: activeProfile.trim().isEmpty ? 'default' : activeProfile,
      );
    default:
      return null;
  }
}

class DraftReplyRescue implements ReplyRescue {
  DraftReplyRescue(this.prefs, {ChatDraftStore? store})
    : _store = store ?? ChatDraftStore(prefs);

  final SharedPreferences prefs;
  final ChatDraftStore _store;

  @override
  Future<void> keep(NotificationActionPayload p, String text) async {
    final address = replyDraftAddress(
      p,
      activeProfile: prefs.getString('active_profile_${p.connId}') ?? '',
    );
    if (address == null) return;
    final existing = await _store.load(
      p.connId,
      address.sessionId,
      profile: address.profile,
    );
    final current = existing.text.trim();
    if (current == text.trim() || current.endsWith(text.trim())) return;
    await _store.save(
      p.connId,
      address.sessionId,
      current.isEmpty ? text : '$current\n$text',
      existing.attachments,
      profile: address.profile,
      preparedTurnClientTurnId: existing.preparedTurnClientTurnId,
      replyThreadId: existing.replyThreadId ?? p.threadId,
    );
  }
}

class NotificationActionDrainer {
  NotificationActionDrainer({
    required this.inbox,
    required this.router,
    required this.routes,
    this.rescue,
  });

  final NotificationActionInbox inbox;
  final NotificationActionRouter router;
  final Set<NotificationActionRoute> routes;
  final ReplyRescue? rescue;
  bool _running = false;
  bool _again = false;

  /// Drains until the inbox has nothing claimable for [routes].
  Future<int> drain({int maxRounds = 8}) async {
    if (_running) {
      _again = true;
      return 0;
    }
    _running = true;
    var handled = 0;
    try {
      for (var round = 0; round < maxRounds; round++) {
        _again = false;
        final actions = await inbox.takePendingActions(routes);
        if (actions.isEmpty && !_again) break;
        for (final action in actions) {
          await _handleOne(action);
          handled++;
        }
      }
    } finally {
      _running = false;
    }
    return handled;
  }

  Future<void> _handleOne(PendingNotificationAction action) async {
    try {
      if (action.expired) {
        // Already reported as failed by the native sweep: never execute a
        // stale tap; keep the reply text for the user.
        await _rescue(action);
      } else {
        final outcome = await router.handle(action);
        if (outcome == ActionOutcome.failed) await _rescue(action);
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[hermes-actions] ${error.runtimeType}');
      await _rescue(action);
    }
    // Terminal for this tap (done / answered / possibly sent / failed and
    // rescued): remove it. A crash before this line re-delivers it.
    await inbox.ackActions([action.uid]);
  }

  Future<void> _rescue(PendingNotificationAction action) async {
    final text = action.text?.trim() ?? '';
    if (action.action != 'reply' || text.isEmpty) return;
    try {
      await rescue?.keep(action.payload, text);
    } catch (error) {
      if (kDebugMode) debugPrint('[hermes-actions] rescue ${error.runtimeType}');
    }
  }
}

/// Saved connections with their Keystore API keys, without the
/// ConnectionManager side effects (migration, pruning).
Future<List<SavedConnection>> loadConnectionsForActions(
  SharedPreferences prefs, {
  SecureStorage? secure,
}) async {
  final storage = secure ?? SecureStorage();
  final out = <SavedConnection>[];
  for (final raw in prefs.getStringList('saved_connections') ?? const []) {
    try {
      final conn = SavedConnection.fromMap(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      final key = await storage.readApiKey(conn.id);
      out.add(key == null || key.isEmpty ? conn : conn.copyWith(apiKey: key));
    } catch (_) {}
  }
  return out;
}

/// Every route: the headless worker is the only executor alive.
const allNotificationActionRoutes = {
  NotificationActionRoute.room,
  NotificationActionRoute.run,
  NotificationActionRoute.chat,
  NotificationActionRoute.botChat,
  NotificationActionRoute.cron,
};

/// Headless entrypoint booted by `HermesActionDrainWorker` when no engine is
/// alive. Runs one bounded drain and reports `drainFinished`.
@pragma('vm:entry-point')
Future<void> hermesNotificationActionDrain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final platform = PlatformRichNotifications();
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final connections = await loadConnectionsForActions(prefs);
    final drainer = NotificationActionDrainer(
      inbox: platform,
      routes: allNotificationActionRoutes,
      rescue: DraftReplyRescue(prefs),
      router: NotificationActionRouter(
        ops: GatewayNotificationActionOps(
          resolveConnection: (id) =>
              connections.where((c) => c.id == id).firstOrNull,
        ),
        sink: platform,
        t: NotifL10n.of(prefs),
        dedupe: PrefsActionDedupeStore(prefs),
      ),
    );
    await drainer.drain().timeout(const Duration(seconds: 80));
  } catch (error) {
    if (kDebugMode) debugPrint('[hermes-actions] headless ${error.runtimeType}');
  } finally {
    await platform.drainFinished();
  }
}
