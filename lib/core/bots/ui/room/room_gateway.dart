import 'dart:io';
import 'dart:typed_data';

import '../../../models/attachment_draft.dart';
import '../../../models/hosted_groups.dart';
import '../../../services/artifact_export_service.dart';
import '../../../services/attachment_uploader.dart';
import '../../../services/connection_manager.dart';
import '../../../services/generated_media_service.dart';
import '../../../services/media_prefetcher.dart';
import '../../../services/tui_gateway_client.dart'
    show GroupInvalidResponseError, TuiGatewayRpcError;
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

/// [RoomAttachmentActions] that also fetch the files of the room's own
/// store ([RoomAttachmentRef.stored]). Actions without it leave those files
/// as named chips, opened on Desktop.
abstract interface class RoomStoredAttachmentActions
    implements RoomAttachmentActions {
  /// What the server said when a fetch of a stored file failed, or null when
  /// it said nothing Console can show (the card then only says the file
  /// could not be fetched).
  String? failureMessage(Object error);
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
  Future<ArtifactSaveResult> save(RoomAttachmentRef ref, File file) =>
      exporter.saveFile(fileName: ref.name, file: file);
}

/// Reads one stored file: the message's durable id and its manifest entry.
typedef RoomStoredFileDownload =
    Future<Uint8List> Function(
      String eventId,
      HostedGroupAttachment attachment,
    );

/// Actions of a room whose server lists `groups.attachment.download`: a
/// file of the room's own store is read with it, as Hermes Desktop does
/// (`canonical-group-attachments.tsx::fetchCanonicalGroupAttachment`), kept
/// in the private cache of generated media, and opened, saved and shared
/// like any other room file. Path attachments go to [files].
final class StoreRoomAttachmentActions
    implements RoomStoredAttachmentActions, RoomAttachmentCache {
  /// Actions for path attachments (the Dashboard interim); null when there
  /// are none.
  final RoomAttachmentActions? files;

  /// Cache scope (connection and profile), as for path attachments.
  final String scope;
  final String roomId;
  final RoomStoredFileDownload download;
  final ArtifactExportActions exporter;

  /// Cache root; null is the app-support directory.
  final Directory? cacheRoot;

  const StoreRoomAttachmentActions({
    required this.files,
    required this.scope,
    required this.roomId,
    required this.download,
    this.exporter = const PlatformArtifactExportActions(),
    this.cacheRoot,
  });

  /// The cache identity of [file]: typed and sized from its manifest.
  GeneratedMediaReference _reference(RoomStoredFile file) =>
      GeneratedMediaReference(
        source: [roomId, file.eventId, file.attachment.attachmentId].join('/'),
        kind: file.attachment.kind == 'image'
            ? GeneratedMediaKind.image
            : GeneratedMediaKind.file,
        sourceKind: GeneratedMediaSourceKind.roomAttachment,
        displayName: file.attachment.displayName,
        mimeType: file.attachment.mime,
        sizeBytes: file.attachment.size,
      );

  RoomAttachmentActions get _paths =>
      files ?? (throw const FormatException('unsupported room attachment'));

  @override
  bool canFetch(RoomAttachmentRef ref) =>
      ref.stored != null || (files?.canFetch(ref) ?? false);

  @override
  File? cachedFile(RoomAttachmentRef ref) {
    final stored = ref.stored;
    if (stored != null) {
      return GeneratedMediaService.cachedFileSync(
        scope,
        _reference(stored),
        baseDir: cacheRoot,
      );
    }
    final paths = files;
    return paths is RoomAttachmentCache
        ? (paths as RoomAttachmentCache).cachedFile(ref)
        : null;
  }

  @override
  void prefetch(RoomAttachmentRef ref) {
    // A stored image is fetched by its own card when it is built.
    if (ref.stored != null) return;
    final paths = files;
    if (paths is RoomAttachmentCache) {
      (paths as RoomAttachmentCache).prefetch(ref);
    }
  }

  @override
  Future<File> fetch(RoomAttachmentRef ref) {
    final stored = ref.stored;
    if (stored == null) return _paths.fetch(ref);
    return GeneratedMediaService.ensureDownloaded(
      scope,
      _reference(stored),
      fetchRoomAttachment: (_) => download(stored.eventId, stored.attachment),
      baseDir: cacheRoot,
    );
  }

  @override
  Future<void> open(RoomAttachmentRef ref, File file) {
    final stored = ref.stored;
    if (stored == null) return _paths.open(ref, file);
    // Same guarded "open with" path as every other cached room file.
    return openGeneratedMediaExternally(
      file,
      mimeType: stored.attachment.mime,
      expectedSize: stored.attachment.size,
    );
  }

  @override
  Future<void> share(RoomAttachmentRef ref, File file) =>
      ref.stored == null ? _paths.share(ref, file) : shareMediaFile(file);

  @override
  Future<ArtifactSaveResult> save(RoomAttachmentRef ref, File file) =>
      ref.stored == null
      ? _paths.save(ref, file)
      : exporter.saveFile(fileName: ref.name, file: file);

  @override
  String? failureMessage(Object error) {
    // The server's own words (its JSON-RPC error message), never Console's
    // local verification text.
    if (error is! TuiGatewayRpcError ||
        error is GroupInvalidResponseError ||
        error.code == null) {
      return null;
    }
    final message = error.message.trim();
    return message.isEmpty ? null : message;
  }
}
