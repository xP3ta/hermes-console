import '../../../models/hosted_groups.dart';
import '../../../services/chat_draft_store.dart';
import '../../../services/connection_manager.dart';
import '../../../services/shared_gateway_pool.dart';
import 'room_gateway.dart';
import 'room_screen.dart';

/// [RoomGateway] over Mission Control's callbacks (pooled repository with
/// the incremental `RoomLogCursor` + `driver_status`) plus the pooled
/// gateway client for approve/retry.
final class CallbackRoomGateway implements RoomGateway {
  final Future<HostedGroupWorkspaceReadback> Function(HostedGroupRoom room)
  onRead;
  final Future<HostedGroupWorkspaceReadback> Function(
    String text,
    HostedGroupSendAttempt attempt,
  )
  onSend;
  final Future<HostedGroupWorkspaceReadback> Function(String name) onRename;
  final Future<HostedGroupWorkspaceReadback> Function() onStop;
  final Future<HostedGroupWorkspaceReadback> Function() onDisband;
  final Future<void> Function(RoomApprovalAction action, String choice)?
  onApprove;
  final Future<void> Function(String taskId)? onRetry;

  const CallbackRoomGateway({
    required this.onRead,
    required this.onSend,
    required this.onRename,
    required this.onStop,
    required this.onDisband,
    this.onApprove,
    this.onRetry,
  });

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) =>
      onRead(room);

  @override
  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
  }) => onSend(text, attempt);

  @override
  Future<HostedGroupWorkspaceReadback> rename(
    HostedGroupRoom room, {
    required String name,
  }) => onRename(name);

  @override
  Future<HostedGroupWorkspaceReadback> stop(HostedGroupRoom room) => onStop();

  @override
  Future<HostedGroupWorkspaceReadback> disband(HostedGroupRoom room) =>
      onDisband();

  @override
  Future<void> approve(
    HostedGroupRoom room, {
    required RoomApprovalAction action,
    required String choice,
  }) {
    final approve = onApprove;
    if (approve == null) throw StateError('groups.approve unavailable');
    return approve(action, choice);
  }

  @override
  Future<void> retry(HostedGroupRoom room, {required String taskId}) {
    final retry = onRetry;
    if (retry == null) throw StateError('groups.retry unavailable');
    return retry(taskId);
  }
}

/// `groups.approve` on the pooled Desktop socket for [connection] (no new
/// socket when Bot Mode already holds one). The server matches the exact
/// `request_id`, so answering an already-answered request is harmless.
Future<void> pooledRoomApprove(
  SavedConnection connection, {
  required String roomId,
  required RoomApprovalAction action,
  required String choice,
  int? generation,
  SharedGatewayPool? pool,
}) async {
  if (!action.offers(choice)) {
    throw StateError('approval choice not offered by the server');
  }
  final lease = (pool ?? SharedGatewayPool.instance).acquire(connection);
  try {
    final client = lease.client;
    final proven = generation ?? (await client.groupCapabilities()).generation;
    await client.approveGroupTask(
      roomId: roomId,
      memberId: action.memberId,
      taskId: action.taskId,
      executionGeneration: action.executionGeneration,
      choice: choice,
      requestId: action.requestId,
      generation: proven,
    );
  } finally {
    lease.release();
  }
}

/// Room drafts in the encrypted `ChatDraftStore`, same key as before
/// (`mob-room-<base64(authority, room)>`) so existing drafts survive.
final class ChatDraftRoomStore implements RoomDraftStore {
  final ChatDraftStore store;
  final String connectionId;
  final String profile;
  final String sessionId;

  const ChatDraftRoomStore({
    required this.store,
    required this.connectionId,
    required this.profile,
    required this.sessionId,
  });

  @override
  Future<({String text, String? threadId, String? preparedId})> load() async {
    final draft = await store.load(connectionId, sessionId, profile: profile);
    return (
      text: draft.text,
      threadId: draft.replyThreadId,
      preparedId: draft.preparedTurnClientTurnId,
    );
  }

  @override
  Future<void> save(String text, {String? threadId, String? preparedId}) =>
      store.save(
        connectionId,
        sessionId,
        text,
        const [],
        profile: profile,
        replyThreadId: threadId,
        preparedTurnClientTurnId: preparedId,
      );

  @override
  Future<void> clear({required String preparedId}) => store.clear(
    connectionId,
    sessionId,
    profile: profile,
    onlyPreparedTurnClientTurnId: preparedId,
  );
}
