import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../models/attachment_draft.dart';
import '../../../models/hosted_groups.dart';
import '../../../services/chat_draft_store.dart';
import '../../../services/app_lock_sensitive_read_fence.dart';
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

/// [RoomFileStore] over Mission Control's callbacks (the pooled repository
/// under the live capabilities).
final class CallbackRoomFileStore implements RoomFileStore {
  final Future<HostedGroupAttachment> Function(
    String uploadId,
    String kind,
    String name,
    String mime,
    Uint8List bytes,
  )
  onUpload;
  final Future<HostedGroupWorkspaceReadback> Function(
    String text,
    List<HostedGroupAttachment> attachments,
    HostedGroupSendAttempt attempt,
  )
  onSend;

  const CallbackRoomFileStore({required this.onUpload, required this.onSend});

  @override
  Future<HostedGroupAttachment> upload(
    HostedGroupRoom room, {
    required String uploadId,
    required String kind,
    required String name,
    required String mime,
    required Uint8List bytes,
  }) => onUpload(uploadId, kind, name, mime, bytes);

  @override
  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required List<HostedGroupAttachment> attachments,
    required HostedGroupSendAttempt attempt,
  }) => onSend(text, attachments, attempt);
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

/// One member-prompt RPC (`room_member_prompts.dart`) on the pooled Desktop
/// socket for [connection].
Future<Map<String, dynamic>> pooledRoomPromptRequest(
  SavedConnection connection,
  String method,
  Map<String, dynamic> params, {
  SharedGatewayPool? pool,
}) async {
  final lease = (pool ?? SharedGatewayPool.instance).acquire(connection);
  try {
    return await lease.client.roomPromptRequest(method, params);
  } finally {
    lease.release();
  }
}

/// Room drafts in the encrypted `ChatDraftStore`, same key as before
/// (`mob-room-<base64(authority, room)>`) so existing drafts survive.
final class ChatDraftRoomStore implements RoomDraftStore, RoomOutboxStore {
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
  Future<RoomDraft> load() async {
    final ticket = store.captureDisclosure();
    final draft = await store.load(connectionId, sessionId, profile: profile);
    ticket.ensureCurrent();
    return (
      text: draft.text,
      threadId: draft.replyThreadId,
      preparedId: draft.preparedTurnClientTurnId,
      preparedText: draft.preparedTurnText,
      files: draft.attachments,
      missingFiles: draft.missingAttachmentNames,
    );
  }

  @override
  Future<void> save(
    String text, {
    String? threadId,
    String? preparedId,
    String? preparedText,
    List<AttachmentDraft> files = const [],
  }) async {
    final saved = await store.save(
      connectionId,
      sessionId,
      text,
      files,
      profile: profile,
      replyThreadId: threadId,
      preparedTurnClientTurnId: preparedId,
      preparedTurnText: preparedText,
    );
    if (!saved) throw const SensitiveReadUnavailable();
  }

  @override
  Future<void> clear({required String preparedId}) => store.clear(
    connectionId,
    sessionId,
    profile: profile,
    onlyPreparedTurnClientTurnId: preparedId,
  );

  @override
  Future<void> retire(List<AttachmentDraft> files) =>
      store.retireAttachments(files);

  // ── The room's durable outbox ────────────────────────────────────────
  //
  // One encrypted record per queued message, next to the composer's own
  // (`<room>.q.<send id>`), and one more that lists their ids in order
  // (`<room>.q`). The composer's record is a single slot that the next
  // save replaces, so a queued message never lives only there. Every key
  // starts with `mob-room-`: none of them is listed as a conversation.

  String get _queueIndexId => '$sessionId.q';
  String _queueEntryId(String id) => '$sessionId.q.$id';

  /// Index updates of one room, one after another, across store objects.
  static final Map<String, Future<void>> _queueTails = {};

  Future<T> _queueSerial<T>(Future<T> Function() action) {
    final scope = '$connectionId\u0000$profile\u0000$sessionId';
    final previous = _queueTails[scope] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _queueTails[scope] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_queueTails[scope], tail)) _queueTails.remove(scope);
      }),
    );
    return result;
  }

  Future<List<String>> _queueIds() async {
    final index = await store.load(
      connectionId,
      _queueIndexId,
      profile: profile,
    );
    if (index.text.isEmpty) return [];
    try {
      return [
        for (final id in jsonDecode(index.text) as List)
          if (id is String && id.isNotEmpty) id,
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeQueueIds(List<String> ids) async {
    if (ids.isEmpty) {
      await store.clear(connectionId, _queueIndexId, profile: profile);
      return;
    }
    final saved = await store.save(
      connectionId,
      _queueIndexId,
      jsonEncode(ids),
      const [],
      profile: profile,
    );
    if (!saved) throw const SensitiveReadUnavailable();
  }

  @override
  Future<void> enqueue(
    String id,
    String text, {
    required String threadId,
    List<AttachmentDraft> files = const [],
  }) => _queueSerial(() async {
    // The message first, its index entry second: an entry never names a
    // message that was not written.
    final saved = await store.save(
      connectionId,
      _queueEntryId(id),
      text,
      files,
      profile: profile,
      replyThreadId: threadId,
    );
    if (!saved) throw const SensitiveReadUnavailable();
    final ids = await _queueIds();
    if (!ids.contains(id)) await _writeQueueIds([...ids, id]);
  });

  @override
  Future<List<RoomQueuedSend>> queued() => _queueSerial(() async {
    final ticket = store.captureDisclosure();
    final ids = await _queueIds();
    final entries = <RoomQueuedSend>[];
    final live = <String>[];
    for (final id in ids) {
      final draft = await store.load(
        connectionId,
        _queueEntryId(id),
        profile: profile,
      );
      ticket.ensureCurrent();
      final thread = draft.replyThreadId;
      if (thread == null ||
          (draft.text.isEmpty &&
              draft.attachments.isEmpty &&
              draft.missingAttachmentNames.isEmpty)) {
        // Expired or never written: nothing left to deliver.
        continue;
      }
      live.add(id);
      entries.add((
        id: id,
        text: draft.text,
        threadId: thread,
        files: draft.attachments,
        missingFiles: draft.missingAttachmentNames,
      ));
    }
    if (live.length != ids.length) await _writeQueueIds(live);
    return entries;
  });

  @override
  Future<void> dequeue(String id) => _queueSerial(() async {
    await store.clear(connectionId, _queueEntryId(id), profile: profile);
    final ids = await _queueIds();
    if (ids.remove(id)) await _writeQueueIds(ids);
  });
}
