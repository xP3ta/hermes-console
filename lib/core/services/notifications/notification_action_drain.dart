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
import '../app_lock_sensitive_read_fence.dart';
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

  String _entryKey(String key) =>
      '$storageKey.${base64Url.encode(utf8.encode(key))}';

  @override
  Future<String?> stateOf(String key, DateTime now, Duration window) async {
    await prefs.reload();
    final raw = prefs.getString(_entryKey(key));
    final entry = raw == null ? (await _load())[key] : jsonDecode(raw);
    if (entry is! Map) return null;
    if (entry['s'] == 'rescue_pending') return 'rescue_pending';
    final at = entry['at'];
    if (at is! int || now.millisecondsSinceEpoch - at > window.inMilliseconds) {
      return null;
    }
    return entry['s'] as String?;
  }

  @override
  Future<void> mark(String key, String state, DateTime now) async {
    if (!await prefs.setString(
      _entryKey(key),
      jsonEncode({'s': state, 'at': now.millisecondsSinceEpoch}),
    )) {
      throw StateError('checkpoint unavailable');
    }
  }

  @override
  Future<void> forget(String key) async {
    await prefs.remove(_entryKey(key));
  }
}

/// Where a reply that could not be delivered waits for the user.
abstract interface class ReplyRescue {
  Future<void> keep(NotificationActionPayload payload, String text);
}

/// Composer-draft key of the destination conversation (same keys the Bot
/// Chat, Room and chat screens read).
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
    case NotificationActionRoute.session:
      // The chat's own composer draft: the key the chat screen reads when
      // the card's "open" brings the user to this session.
      final session = p.sessionId;
      if (session == null) return null;
      final owner = p.profile?.trim() ?? '';
      return (sessionId: session, profile: owner.isEmpty ? 'default' : owner);
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
  Future<void> keep(
    NotificationActionPayload p,
    String text, {
    String? actionUid,
  }) => AppLockSensitiveReadFence.run(prefs, () => _keep(p, text, actionUid));

  Future<void> _keep(
    NotificationActionPayload p,
    String text,
    String? actionUid,
  ) async {
    if (actionUid == null || actionUid.isEmpty) {
      throw StateError('rescue action identity unavailable');
    }
    final address = replyDraftAddress(
      p,
      activeProfile: prefs.getString('active_profile_${p.connId}') ?? '',
    );
    if (address == null) throw StateError('rescue destination unavailable');
    final existing = await _store.load(
      p.connId,
      address.sessionId,
      profile: address.profile,
    );
    AppLockSensitiveReadFence.current.ensureCurrent();
    final saved = await _store.save(
      p.connId,
      address.sessionId,
      text,
      existing.attachments,
      profile: address.profile,
      preparedTurnClientTurnId: existing.preparedTurnClientTurnId,
      replyThreadId: existing.replyThreadId ?? p.threadId,
      rescueActionUid: actionUid,
    );
    if (!saved) throw StateError('rescue not committed');
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
        final disclosure = AppLockSensitiveReadFence.capture();
        final actions = await inbox.takePendingActions(routes);
        if (!disclosure.isCurrent) break;
        if (actions.isEmpty && !_again) break;
        var retained = false;
        for (final action in actions) {
          if (!await _handleOne(action, disclosure)) retained = true;
          handled++;
        }
        if (retained) break;
      }
    } finally {
      _running = false;
    }
    return handled;
  }

  Future<bool> _handleOne(
    PendingNotificationAction action,
    SensitiveReadTicket disclosure,
  ) async {
    if (!disclosure.isCurrent) return false;
    final custody = inbox is ClaimedNotificationActionInbox
        ? inbox as ClaimedNotificationActionInbox
        : null;
    var phase = action.phase;
    if (action.action == 'reply' &&
        (action.text?.trim().isEmpty ?? true) &&
        phase != 'confirmed' &&
        phase != 'rescued') {
      return false;
    }
    Future<void> checkpoint(String next) async {
      if (phase == next) return;
      if (next == 'rescued') disclosure.ensureCurrent();
      if (custody != null && !await custody.checkpoint(action, phase, next)) {
        throw StateError('retired notification claim');
      }
      phase = next;
    }

    try {
      if (phase == 'uncertain') {
        return false; // No resend and no rejection/rescue assertion.
      }
      if (phase != 'confirmed' && phase != 'rescued') {
        if (action.expired || phase == 'rescue_pending') {
          await checkpoint('rescue_pending');
        } else {
          await checkpoint('executing');
          final outcome = await router.handle(
            action,
            checkpoint: checkpoint,
            disclosure: disclosure,
          );
          if (outcome == ActionOutcome.maybeDone) {
            await checkpoint('uncertain');
            return false;
          }
          if (outcome == ActionOutcome.failed && phase != 'confirmed') {
            await checkpoint('rescue_pending');
          } else {
            await checkpoint('confirmed');
          }
        }
        if (phase == 'rescue_pending') {
          if (!await _rescue(action, disclosure)) {
            await custody?.deferClaim(action);
            return false;
          }
          await checkpoint('rescued');
        }
      }
      // A rescued checkpoint handed off before revocation may finish, but an
      // old execution must not retire custody after that await.
      if (phase == 'rescued') disclosure.ensureCurrent();
      if (custody != null) {
        return await custody.ackClaim(action);
      } else {
        await inbox.ackActions([action.uid]); // Legacy test/custom inbox only.
      }
      return true;
    } catch (error) {
      if (error is SensitiveReadUnavailable) await custody?.deferClaim(action);
      // Keep native custody. A failed checkpoint is not a failed remote send.
      if (kDebugMode) {
        debugPrint('[hermes-actions] retained ${error.runtimeType}');
      }
      return false;
    }
  }

  Future<bool> _rescue(
    PendingNotificationAction action,
    SensitiveReadTicket disclosure,
  ) async {
    final text = action.text?.trim() ?? '';
    if (action.action != 'reply') return true;
    if (text.isEmpty || rescue == null) return false;
    try {
      return await AppLockSensitiveReadFence.runWithTicket(
        disclosure,
        () async {
          final target = rescue!;
          if (target is DraftReplyRescue) {
            await target.keep(action.payload, text, actionUid: action.uid);
          } else {
            await target.keep(action.payload, text);
          }
          // Even an already-admitted write or custom rescue may complete after
          // revocation. Completion is not authority to confirm rescue or ACK.
          disclosure.ensureCurrent();
          return true;
        },
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[hermes-actions] rescue ${error.runtimeType}');
      }
      return false;
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
  NotificationActionRoute.session,
  NotificationActionRoute.kanban,
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
    if (kDebugMode) {
      debugPrint('[hermes-actions] headless ${error.runtimeType}');
    }
  } finally {
    await platform.drainFinished();
  }
}
