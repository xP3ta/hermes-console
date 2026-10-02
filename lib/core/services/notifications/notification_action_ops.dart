// Server calls behind notification/widget actions. Each method performs the
// SAME call as the in-app control:
//  * room approve → `groups.approve` with the server `request_id` (idempotent)
//  * room stop    → `groups.stop`
//  * room reply   → `groups.send` (client event id = inbox uid, idempotent)
//  * run approve  → `POST /v1/runs/{id}/approval` with `request_id`
//  * chat approve → the live `ActiveChat.resolveApproval` when the UI has it,
//    else `approval.respond {session_id: <stored id>, request_id, choice}`
//    (upstream resolves a stale/stored id by the durable identity, #91684)
//  * Bot Chat reply → attach (`session.activate` or `session.resume`) +
//    `prompt.submit`; `client_turn_id` only when the gateway advertises
//    `turn_idempotency` (same gate as the main chat), else the official
//    `{status: "streaming"}` reply is the acceptance
//  * cron retry   → `POST /api/cron/jobs/{id}/trigger` (Cron "Run now")
import 'dart:async';

import '../../bots/data/bot_mode_repository.dart';
import '../../models/desktop_compression_outcome.dart';
import '../../models/hosted_groups.dart';
import '../connection_manager.dart';
import '../cron_repository.dart';
import '../secure_storage.dart';
import '../shared_gateway_pool.dart';
import '../tui_gateway_client.dart';
import 'rich_notifications.dart';

typedef ConnectionResolver = FutureOr<SavedConnection?> Function(String connId);
/// Returns true when a live `ActiveChat` resolved it; false = not attached
/// here, fall back to the server path.
typedef ChatApprovalExecutor =
    Future<bool> Function(NotificationActionPayload payload, String choice);

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

class GatewayNotificationActionOps implements NotificationActionOps {
  GatewayNotificationActionOps({
    required this.resolveConnection,
    this.chatApproval,
    TurnIdempotencyGate? turnIdempotency,
    SharedGatewayPool? pool,
    SecureStorage? secure,
    this.clientFactory,
    this.dashboardFactory,
  }) : _pool = pool ?? SharedGatewayPool.instance,
       _secure = secure ?? SecureStorage(),
       _turnIdempotency =
           turnIdempotency ?? ConnectionManager.isTurnIdempotencySupported;

  final ConnectionResolver resolveConnection;
  final ChatApprovalExecutor? chatApproval;
  final TurnIdempotencyGate _turnIdempotency;
  final TuiGatewayClient Function(SavedConnection connection)? clientFactory;
  final DashboardClient Function(SavedConnection connection)? dashboardFactory;
  final SharedGatewayPool _pool;
  final SecureStorage _secure;

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
        await TuiBotModeGateway(client).stopGroup(
          p.roomId!,
          generation: caps.generation,
        );
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
  Future<void> runApprove(NotificationActionPayload p, String choice) async {
    final connection = await _connection(p);
    final token = await _secure.readApiKey(connection.id) ?? connection.apiKey;
    final api = ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: token,
      connectionId: connection.id,
    );
    await api.resolveRunApproval(
      p.runId!,
      choice,
      requestId: p.requestId,
      profile: p.profile,
    );
  }

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
  Future<void> botChatReply(
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
