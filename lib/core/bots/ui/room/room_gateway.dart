import 'dart:io';
import 'dart:typed_data';

import '../../../models/attachment_draft.dart';
import '../../../models/hosted_groups.dart';
import '../../../services/artifact_export_service.dart';
import '../../../services/attachment_uploader.dart';
import '../../../services/connection_manager.dart';
import '../../../services/generated_media_service.dart';
import '../../../widgets/attachment_card.dart'
    show openGeneratedMediaExternally, shareMediaFile;
import 'room_models.dart';

/// What the Room screen reads and writes. The hosted room authority stays on
/// the server: every mutation returns the server read-back.
///
/// Mission Control adapts its pooled `MissionControlRepository` (incremental
/// `RoomLogCursor` + `driver_status`) to this surface; tests use fakes.
abstract interface class RoomGateway {
  /// `groups.state` (+ driver status) and the incremental `groups.log`.
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room);

  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
  });

  Future<HostedGroupWorkspaceReadback> rename(
    HostedGroupRoom room, {
    required String name,
  });

  /// `groups.stop` — cancels queued and running member work.
  Future<HostedGroupWorkspaceReadback> stop(HostedGroupRoom room);

  Future<HostedGroupWorkspaceReadback> disband(HostedGroupRoom room);

  /// `groups.approve` for one pending approval (server `request_id`).
  Future<void> approve(
    HostedGroupRoom room, {
    required RoomApprovalAction action,
    required String choice,
  });

  /// `groups.retry` for a task the server lists as retryable.
  Future<void> retry(HostedGroupRoom room, {required String taskId});
}

/// Server capabilities as seen by one open room.
final class RoomCapabilities {
  final bool canSend;
  final bool canRename;
  final bool canStop;
  final bool canDisband;
  final bool canApprove;
  final bool canRetry;

  /// Answer member prompts (`request.answer`, `clarify.lock`,
  /// `approval.respond`) and cancel a member wait (`session.interrupt`).
  final bool canAnswerPrompts;

  /// `groups.*` exposes no member add/remove RPC (only the
  /// `room.members_changed` event), so membership is read-only.
  final bool canEditMembers;

  const RoomCapabilities({
    this.canSend = false,
    this.canRename = false,
    this.canStop = false,
    this.canDisband = false,
    this.canApprove = false,
    this.canRetry = false,
    this.canAnswerPrompts = false,
    this.canEditMembers = false,
  });

  static const none = RoomCapabilities();

  factory RoomCapabilities.from(
    GroupsCapabilities? capabilities, {
    required bool readOnly,
  }) {
    bool has(GroupMethod method) =>
        !readOnly && (capabilities?.supports(method) ?? false);
    return RoomCapabilities(
      canSend: has(GroupMethod.send),
      canRename: has(GroupMethod.rename),
      canStop: has(GroupMethod.stop),
      canDisband: has(GroupMethod.disband),
      canApprove: has(GroupMethod.approve),
      canRetry: has(GroupMethod.retry),
    );
  }
}

/// Why the composer `+` is disabled (gap G1: `groups.send` carries text only).
enum RoomAttachBlock { none, crossGateway, noUploader, readOnly }

/// Upload for the G1 interim: the file lands in the server's managed
/// filesystem and its path is referenced from the message text.
abstract interface class RoomAttachmentUploader {
  /// Absolute managed path of the uploaded copy, or `null` on failure.
  Future<String?> upload(AttachmentDraft draft);
}

/// Download / open / share for an attachment card (T309).
abstract interface class RoomAttachmentActions {
  bool canFetch(RoomAttachmentRef ref);
  Future<File> fetch(RoomAttachmentRef ref);
  Future<void> open(RoomAttachmentRef ref, File file);
  Future<void> share(RoomAttachmentRef ref, File file);
  Future<ArtifactSaveResult> save(RoomAttachmentRef ref, File file);
}

/// Real uploader: Console's existing `AttachmentUploader` (Dashboard
/// `files/upload` under `hermes_home/uploads`).
final class DashboardRoomAttachmentUploader implements RoomAttachmentUploader {
  final SavedConnection connection;
  const DashboardRoomAttachmentUploader(this.connection);

  @override
  Future<String?> upload(AttachmentDraft draft) async {
    final result = await AttachmentUploader.upload(connection, draft);
    return result.ok ? result.managedPath : null;
  }
}

/// Real actions over the Dashboard `files/download` route, cached with the
/// same service the chat uses for generated media.
final class DashboardRoomAttachmentActions implements RoomAttachmentActions {
  final SavedConnection connection;
  final String profile;
  final ArtifactExportActions exporter;

  const DashboardRoomAttachmentActions({
    required this.connection,
    required this.profile,
    this.exporter = const PlatformArtifactExportActions(),
  });

  GeneratedMediaReference? _reference(RoomAttachmentRef ref) =>
      GeneratedMediaService.referenceFromSource(ref.path);

  @override
  bool canFetch(RoomAttachmentRef ref) {
    final reference = _reference(ref);
    return reference != null &&
        reference.sourceKind == GeneratedMediaSourceKind.serverPath;
  }

  @override
  Future<File> fetch(RoomAttachmentRef ref) {
    final reference = _reference(ref);
    if (reference == null) {
      throw const FormatException('unsupported room attachment');
    }
    return GeneratedMediaService.ensureDownloaded(
      '${connection.id}\u0000$profile',
      reference,
      fetchServerPathToFileWithProgress:
          (path, destination, reportProgress, cancelled) async {
            final client = DashboardClient.lazy(connection);
            try {
              await client.apiDownloadToFile(
                'files/download?path=${Uri.encodeQueryComponent(path)}',
                destination,
                maxBytes: GeneratedMediaService.maxFileBytes,
                profile: profile,
                onProgress: reportProgress,
                isCancelled: cancelled,
              );
            } finally {
              client.close();
            }
          },
    );
  }

  @override
  Future<void> open(RoomAttachmentRef ref, File file) async {
    final reference = _reference(ref);
    if (reference == null) {
      throw const FormatException('unsupported room attachment');
    }
    // Same guarded "open with" path the chat uses for generated media.
    await openGeneratedMediaExternally(
      file,
      mimeType: reference.mimeType,
      expectedSize: await file.length(),
    );
  }

  @override
  Future<void> share(RoomAttachmentRef ref, File file) => shareMediaFile(file);

  @override
  Future<ArtifactSaveResult> save(RoomAttachmentRef ref, File file) async {
    final Uint8List bytes = await file.readAsBytes();
    return exporter.saveBytes(fileName: ref.name, bytes: bytes);
  }
}
