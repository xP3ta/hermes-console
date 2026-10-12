import 'dart:io';
import 'dart:typed_data';

import '../../../models/attachment_draft.dart';
import '../../../models/hosted_groups.dart';
import '../../../services/artifact_export_service.dart';
import '../../../services/attachment_uploader.dart';
import '../../../services/connection_manager.dart';
import '../../../services/generated_media_service.dart';
import '../../../services/media_prefetcher.dart';
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

  /// Compress a local member's history (`session.compress`). Only a declared
  /// server capability may enable it; never an RPC probe, since the method
  /// mutates the session.
  final bool canCompressMembers;

  const RoomCapabilities({
    this.canSend = false,
    this.canRename = false,
    this.canStop = false,
    this.canDisband = false,
    this.canApprove = false,
    this.canRetry = false,
    this.canAnswerPrompts = false,
    this.canEditMembers = false,
    this.canCompressMembers = false,
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

/// Optional private-cache capabilities of [RoomAttachmentActions].
abstract interface class RoomAttachmentCache {
  /// The cached copy, synchronously and without network, or null.
  File? cachedFile(RoomAttachmentRef ref);

  /// Starts fetching [ref] in the background (images only), so its row
  /// paints from the cache when it scrolls into view.
  void prefetch(RoomAttachmentRef ref);
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
final class DashboardRoomAttachmentActions
    implements RoomAttachmentActions, RoomAttachmentCache {
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

  String get _scope => '${connection.id}\u0000$profile';

  @override
  File? cachedFile(RoomAttachmentRef ref) {
    final reference = _reference(ref);
    if (reference == null ||
        reference.sourceKind != GeneratedMediaSourceKind.serverPath) {
      return null;
    }
    return MediaPrefetcher.instance.readyFile(
          GeneratedMediaService.readyKey(_scope, reference),
        ) ??
        GeneratedMediaService.cachedFileSync(_scope, reference);
  }

  @override
  void prefetch(RoomAttachmentRef ref) {
    final reference = _reference(ref);
    if (reference == null || reference.kind != GeneratedMediaKind.image) {
      return;
    }
    MediaPrefetcher.instance.prefetch(
      key: GeneratedMediaService.readyKey(_scope, reference),
      reference: reference,
      load: () => _download(reference),
    );
  }

  @override
  Future<File> fetch(RoomAttachmentRef ref) async {
    final reference = _reference(ref);
    if (reference == null) {
      throw const FormatException('unsupported room attachment');
    }
    // A running prefetch of this file: join it instead of fetching again.
    final pending = MediaPrefetcher.instance.pending(
      GeneratedMediaService.readyKey(_scope, reference),
    );
    if (pending != null) {
      final file = await pending;
      if (file != null) return file;
    }
    return _download(reference);
  }

  Future<File> _download(GeneratedMediaReference reference) {
    return GeneratedMediaService.ensureDownloaded(
      _scope,
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
