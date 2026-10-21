// Server calls behind notification/widget actions. Each method performs the
// SAME call as the in-app control:
//  * room approve → `groups.approve` with the server `request_id` (idempotent)
//  * room stop    → `groups.stop`
//  * room reply   → `groups.send` (client event id = inbox uid, idempotent)
//  * chat approve → the live `ActiveChat.resolveApproval` when the UI has it,
//    else `approval.respond {session_id: <stored id>, request_id, choice}`
//    (upstream resolves a stale/stored id by the durable identity, #91684)
//  * Bot Chat reply → attach (`session.activate` or `session.resume`) +
//    `prompt.submit`; `client_turn_id` only when the gateway advertises
//    `turn_idempotency` (same gate as the main chat), else the official
//    `{status: "streaming"}` reply is the acceptance
//  * cron retry   → `POST /api/cron/jobs/{id}/trigger` (Cron "Run now")
//  * question     → the live `ActiveChat.respondToClarify` when the UI has
//    the chat, else `clarify.respond` / `request.answer` by request id
//  * turn stop    → the live `ActiveChat.cancel` when the UI has the chat,
//    else `session.interrupt` on the runtime `session.active_list` shows for
//    the stored id
//  * chat reply   → the Bot Chat reply's calls, on a normal chat's stored id
//  * mark read    → `PATCH /api/sessions/{id} {unread: false}` (Desktop's
//    row toggle)
//  * mute         → no server call: the job's / task's own switch in
//    `NotificationMuteStore`
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../bots/data/bot_mode_repository.dart';
import '../../models/desktop_compression_outcome.dart';
import '../../models/hosted_groups.dart';
import '../connection_manager.dart';
import '../cron_repository.dart';
import '../session_repository.dart';
import '../shared_gateway_pool.dart';
import '../tui_gateway_client.dart';
import 'notification_mute_store.dart';
import 'rich_notifications.dart';

typedef ConnectionResolver = FutureOr<SavedConnection?> Function(String connId);

/// Returns true when a live `ActiveChat` resolved it; false = not attached
/// here, fall back to the server path.
typedef ChatApprovalExecutor =
    Future<bool> Function(NotificationActionPayload payload, String choice);

/// Returns true when a live `ActiveChat` stopped its own turn; false = not
/// attached here, fall back to the server path.
typedef ChatStopExecutor =
    Future<bool> Function(NotificationActionPayload payload);

/// Returns true when a live `ActiveChat` answered its own open question;
/// false = not attached here, fall back to the server path.
typedef ChatAnswerExecutor =
    Future<bool> Function(NotificationActionPayload payload, String answer);

/// Same capability gate the main chat uses (`_canUseTurnIdempotency`):
/// server-sourced `turn_idempotency` with TTL. Official Hermes does not
/// publish it, so the plain submit path is the common one.
typedef TurnIdempotencyGate = Future<bool> Function(String connId);

/// Transport failures after the request may have left the device.
bool isAmbiguousSubmitFailure(Object error) {
  if (error is TimeoutException) return true;
  if (error is TuiGatewayRpcError) {
    if (error.failureKind != null) return true;
    // An ack this client cannot verify is still a server acceptance.
    if (error.origin == CompressionFailureOrigin.localPreflight) return false;
    return error.code == null &&
        error.message.toLowerCase().contains('acknowledg');
  }
  return false;
}

class GatewayNotificationActionOps
    implements NotificationActionOps, ChatSessionActionOps, AutomationMuteOps {
  GatewayNotificationActionOps({
    required this.resolveConnection,
    this.chatApproval,
    this.chatStop,
    this.chatAnswer,
    TurnIdempotencyGate? turnIdempotency,
    SharedGatewayPool? pool,
    this.clientFactory,
    this.dashboardFactory,
    this.prefsForMute,
  }) : _pool = pool ?? SharedGatewayPool.instance,
       _turnIdempotency =
           turnIdempotency ?? ConnectionManager.isTurnIdempotencySupported;

  final ConnectionResolver resolveConnection;
  final ChatApprovalExecutor? chatApproval;
  final ChatStopExecutor? chatStop;
  final ChatAnswerExecutor? chatAnswer;
  final TurnIdempotencyGate _turnIdempotency;
  final TuiGatewayClient Function(SavedConnection connection)? clientFactory;
  final DashboardClient Function(SavedConnection connection)? dashboardFactory;

  /// The preferences the per-item mutes live in (tests).
  final Future<SharedPreferences> Function()? prefsForMute;
  final SharedGatewayPool _pool;

  Future<SavedConnection> _connection(NotificationActionPayload p) async {
    final connection = await resolveConnection(p.connId);
    if (connection == null) throw StateError('connection unavailable');
    if (connection.readOnly) throw StateError('read-only connection');
    return connection;
  }

  Future<T> _withClient<T>(
    NotificationActionPayload p,
    Future<T> Function(TuiGatewayClient client) body,
  ) async {
    final lease = _pool.acquire(await _connection(p), factory: clientFactory);
    try {
      return await body(lease.client);
    } finally {
      lease.release();
    }
  }

  @override
  Future<void> roomApprove(NotificationActionPayload p, String choice) =>
      _withClient(p, (client) async {
        final caps = await client.groupCapabilities();
        await TuiBotModeGateway(client).approveGroupTask(
          p.roomId!,
          action: RoomApprovalAction(
            taskId: p.taskId!,
            memberId: p.memberId!,
            executionGeneration: p.executionGeneration!,
            requestId: p.requestId!,
            choices: p.choices.isEmpty ? const ['once', 'deny'] : p.choices,
          ),
          choice: choice,
          generation: caps.generation,
        );
      });

  @override
  Future<void> roomStop(NotificationActionPayload p) =>
      _withClient(p, (client) async {
        final caps = await client.groupCapabilities();
        await TuiBotModeGateway(
          client,
        ).stopGroup(p.roomId!, generation: caps.generation);
      });

  @override
  Future<void> roomSend(
    NotificationActionPayload p,
    String text,
    String clientEventId,
  ) => _withClient(p, (client) async {
    final caps = await client.groupCapabilities();
    final attempt = HostedGroupSendAttempt.forClientEvent(
      clientEventId,
      threadId: p.threadId,
    );
    await client.sendGroupText(
      roomId: p.roomId!,
      text: text,
      eventId: attempt.clientEventId,
      threadId: attempt.threadId,
      generation: caps.generation,
    );
  });

  @override
  Future<void> chatApprove(NotificationActionPayload p, String choice) async {
    final executor = chatApproval;
    if (executor != null && await executor(p, choice)) return;
    // No attached chat (UI gone): answer by durable identity, like Desktop
    // after a reconnect. The server matches the exact `request_id`.
    await _withClient(p, (client) async {
      final result = await client.resolveApprovalChecked(
        p.sessionId!,
        choice,
        requestId: p.requestId!,
      );
      if (result.resolved == 0) {
        throw StateError('approval no longer pending');
      }
    });
  }

  @override
  Future<void> sessionStop(NotificationActionPayload p) async {
    final executor = chatStop;
    if (executor != null && await executor(p)) return;
    // No attached chat (UI gone): stop it on the server, like another
    // surface would.
    final sessionId = p.sessionId;
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('no session to stop');
    }
    await _withClient(p, (client) async {
      final live = await client.listActiveSessions();
      for (final row in live.sessions) {
        if (row.storedSessionId == sessionId) {
          await client.interrupt(row.runtimeSessionId);
          return;
        }
      }
      throw StateError('turn already finished');
    });
  }

  @override
  Future<void> sessionAnswer(NotificationActionPayload p, String answer) async {
    final executor = chatAnswer;
    if (executor != null && await executor(p, answer)) return;
    // No attached chat (UI gone): the server settles the request by its id
    // from any connection.
    await _withClient(p, (client) async {
      final response = await client.respondToClarify(p.requestId!, answer);
      if (response.isExpired) throw StateError('question no longer pending');
    });
  }

  @override
  Future<void> sessionReply(
    NotificationActionPayload p,
    String text,
    String clientTurnId,
  ) => _submitToStoredSession(p, text, clientTurnId);

  @override
  Future<void> sessionMarkRead(NotificationActionPayload p) async {
    final connection = await _connection(p);
    final client =
        dashboardFactory?.call(connection) ?? DashboardClient.lazy(connection);
    // Its own client, closed after the write (see [cronTrigger]).
    try {
      await patchDashboardSessionState(client, p.sessionId!, const {
        'unread': false,
      }, p.profile);
    } finally {
      client.close();
    }
  }

  @override
  Future<void> botChatReply(
    NotificationActionPayload p,
    String text,
    String clientTurnId,
  ) => _submitToStoredSession(p, text, clientTurnId);

  /// Attaches to the stored session and submits [text] as its next turn.
  Future<void> _submitToStoredSession(
    NotificationActionPayload p,
    String text,
    String clientTurnId,
  ) => _withClient(p, (client) async {
    final stored = p.sessionId!;
    String? runtime;
    try {
      final live = await client.listActiveSessions();
      for (final row in live.sessions) {
        if (row.storedSessionId == stored) {
          runtime = row.runtimeSessionId;
          break;
        }
      }
      if (runtime != null) {
        await client.activateSession(runtime, storedSessionId: stored);
      }
    } catch (_) {
      runtime = null;
    }
    runtime ??= (await client.resumeSession(
      stored,
      profile: p.profile ?? '',
    )).runtimeSessionId;
    final idempotent = await _turnIdempotency(p.connId);
    try {
      if (idempotent) {
        await client.submitPromptIdempotent(runtime, text, clientTurnId);
      } else {
        // Official gateway: `{status: "streaming"}` is the acceptance.
        await client.submitPrompt(runtime, text);
      }
    } catch (error) {
      if (isAmbiguousSubmitFailure(error)) throw AmbiguousDeliveryError(error);
      rethrow;
    }
  });

  @override
  Future<void> muteAutomation(NotificationActionPayload p) async {
    final prefs =
        await (prefsForMute?.call() ?? SharedPreferences.getInstance());
    // Another isolate may have written the store since this one read it.
    await prefs.reload();
    final store = NotificationMuteStore(prefs);
    if (p.route == NotificationActionRoute.kanban) {
      await store.setKanbanMuted(
        connId: p.connId,
        taskId: p.taskId!,
        muted: true,
      );
    } else {
      await store.setCronPolicy(
        connId: p.connId,
        profile: p.profile ?? 'default',
        jobId: p.taskId!,
        policy: CronNotifyPolicy.off,
      );
    }
  }

  @override
  Future<void> cronTrigger(NotificationActionPayload p) async {
    final connection = await _connection(p);
    final client =
        dashboardFactory?.call(connection) ?? DashboardClient.lazy(connection);
    // Each retry builds its own client; close it so a background isolate does
    // not keep one http.Client (and its keep-alive socket) per tap.
    try {
      await CronRepository(
        client,
        profile: p.profile ?? '',
      ).triggerById(p.taskId!);
    } finally {
      client.close();
    }
  }
}
