import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/attachment_draft.dart';
import '../services/artifact_viewer_kind.dart';
import '../services/attachment_uploader.dart';
import '../services/generated_media_service.dart';
import 'artifact_viewer/artifact_viewer_screen.dart';
import 'attachment_card.dart';
import 'attachment_history_preview.dart';
import 'hermes_notice.dart';

/// One `@image:<path>` / `@file:<path>` directive line that Hermes persists in
/// a user turn. [path] is the server-side value; it is never rendered, only
/// its file name is.
@immutable
class UserServerAttachmentRef {
  final bool isImage;
  final String path;

  const UserServerAttachmentRef({required this.isImage, required this.path});

  bool get isAbsolute => path.startsWith('/');

  String get displayName {
    final leaf = path.split('/').where((part) => part.isNotEmpty).lastOrNull;
    final name = (leaf ?? '').replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    return name.isEmpty ? 'file' : name;
  }

  /// Validated reference for a Dashboard fetch, or null when the path is
  /// relative, unsafe or sensitive (such a chip is never downloaded).
  GeneratedMediaReference? get fetchReference {
    if (!isAbsolute) return null;
    final reference = GeneratedMediaService.referenceFromSource(path);
    if (reference == null ||
        reference.sourceKind != GeneratedMediaSourceKind.serverPath) {
      return null;
    }
    return reference;
  }

  static final RegExp _lineRe = RegExp(r'^@(image|file):(.+)$');
  static final RegExp _valueRe = RegExp(
    r'''^(?:(`|"|')(.+?)\1|(.+?))(?::\d+(?:-\d+)?)?$''',
  );

  /// Parses a whole line holding exactly one directive. Inline mentions in
  /// prose stay text; an unquoted value never contains whitespace (Hermes
  /// quotes such paths).
  static UserServerAttachmentRef? tryParseLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('@') || trimmed.length > 4096) return null;
    final match = _lineRe.firstMatch(trimmed);
    if (match == null) return null;
    final raw = match.group(2)!.trim();
    final parsed = _valueRe.firstMatch(raw);
    final quoted = parsed?.group(2);
    final value = (quoted ?? parsed?.group(3))?.trim();
    if (value == null ||
        value.isEmpty ||
        value.contains('\u0000') ||
        (quoted == null && value.contains(RegExp(r'\s')))) {
      return null;
    }
    return UserServerAttachmentRef(
      isImage: match.group(1) == 'image',
      path: value,
    );
  }
}

typedef UserServerAttachmentLoader =
    Future<File> Function(GeneratedMediaReference reference);

enum _ServerAttachmentStatus { loading, ready, unavailable, serverOnly, idle }

/// Chip/thumbnail of a user attachment that may only exist on the server.
/// Prefers the verified private copy; otherwise images are fetched lazily
/// (only once this card is built, bounded by the shared auto-load slots) and
/// documents on tap. Failures are remembered so rebuilds never refetch.
class UserServerAttachmentCard extends StatefulWidget {
  final String name;
  final String sizeLabel;
  final AttachmentHistoryReference? localReference;
  final UserServerAttachmentRef serverRef;
  final String cacheScope;
  final UserServerAttachmentLoader loader;

  const UserServerAttachmentCard({
    required this.name,
    required this.sizeLabel,
    required this.serverRef,
    required this.cacheScope,
    required this.loader,
    this.localReference,
    super.key,
  });

  @override
  State<UserServerAttachmentCard> createState() =>
      _UserServerAttachmentCardState();

  @visibleForTesting
  static void clearCachesForTesting() {
    _UserServerAttachmentCardState._ready.clear();
    _UserServerAttachmentCardState._failed.clear();
    _UserServerAttachmentCardState._inFlight.clear();
  }
}

class _UserServerAttachmentCardState extends State<UserServerAttachmentCard> {
  static final Map<String, File> _ready = <String, File>{};
  static final Set<String> _failed = <String>{};
  static const int _memoLimit = 256;

  _ServerAttachmentStatus _status = _ServerAttachmentStatus.idle;
  File? _file;
  bool _local = false;
  int _generation = 0;

  bool get _isImage =>
      widget.localReference?.type == AttachmentType.image ||
      (widget.localReference == null && widget.serverRef.isImage);

  String get _memoKey => '${widget.cacheScope}\u0000${widget.serverRef.path}';

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(UserServerAttachmentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverRef.path != widget.serverRef.path ||
        oldWidget.cacheScope != widget.cacheScope ||
        oldWidget.localReference?.toMarker() !=
            widget.localReference?.toMarker()) {
      _resolve();
    }
  }

  static void _remember<T>(Map<String, T> map, String key, T value) {
    map.remove(key);
    map[key] = value;
    while (map.length > _memoLimit) {
      map.remove(map.keys.first);
    }
  }

  static void _rememberFailure(String key) {
    _failed.remove(key);
    _failed.add(key);
    while (_failed.length > _memoLimit) {
      _failed.remove(_failed.first);
    }
  }

  void _resolve() {
    final generation = ++_generation;
    _file = null;
    _local = false;
    final localMarker = widget.localReference?.toMarker();
    final verifiedLocal = localMarker == null ? null : _ready[localMarker];
    if (verifiedLocal != null && verifiedLocal.existsSync()) {
      // Remounts paint the verified private copy on their first frame.
      _file = verifiedLocal;
      _local = true;
      _status = _ServerAttachmentStatus.ready;
      return;
    }
    final cached = _ready[_memoKey];
    if (cached != null && cached.existsSync()) {
      _file = cached;
      _status = _ServerAttachmentStatus.ready;
      return;
    }
    final reference = widget.serverRef.fetchReference;
    _status = reference == null
        ? _ServerAttachmentStatus.serverOnly
        : _failed.contains(_memoKey)
        ? _ServerAttachmentStatus.unavailable
        : _isImage
        ? _ServerAttachmentStatus.loading
        : _ServerAttachmentStatus.idle;
    unawaited(_resolveAsync(generation, reference));
  }

  Future<void> _resolveAsync(
    int generation,
    GeneratedMediaReference? reference,
  ) async {
    final localReference = widget.localReference;
    if (localReference != null) {
      final file = await AttachmentUploader.resolveHistoryReference(
        localReference,
      );
      if (!mounted || generation != _generation) return;
      if (file != null) {
        _remember(_ready, localReference.toMarker(), file);
        setState(() {
          _file = file;
          _local = true;
          _status = _ServerAttachmentStatus.ready;
        });
        return;
      }
    }
    if (reference == null ||
        !_isImage ||
        _status != _ServerAttachmentStatus.loading) {
      return;
    }
    await _download(generation, reference);
  }

  /// One fetch per server path at a time: the transcript list remounts
  /// bubbles freely, and a remount must join the pending fetch instead of
  /// issuing another request.
  static final Map<String, Future<File?>> _inFlight = <String, Future<File?>>{};

  /// Bounded fetch concurrency, separate from generated-media auto-loads so a
  /// long transcript of user photos neither starves nor is starved by them.
  static const int _maxConcurrentFetches = 2;
  static int _activeFetches = 0;
  static final List<Completer<void>> _fetchWaiters = <Completer<void>>[];

  static Future<T> _withSlot<T>(Future<T> Function() fetch) async {
    if (_activeFetches >= _maxConcurrentFetches) {
      final waiter = Completer<void>();
      _fetchWaiters.add(waiter);
      await waiter.future;
    } else {
      _activeFetches++;
    }
    try {
      return await fetch();
    } finally {
      if (_fetchWaiters.isNotEmpty) {
        _fetchWaiters.removeAt(0).complete();
      } else {
        _activeFetches--;
      }
    }
  }

  Future<File?> _download(
    int generation,
    GeneratedMediaReference reference,
  ) async {
    final key = _memoKey;
    final loader = widget.loader;
    final future = _inFlight[key] ??= () async {
      try {
        final file = await _withSlot(() => loader(reference));
        _remember(_ready, key, file);
        return file;
      } catch (error) {
        debugPrint(
          '[attachment] server copy unavailable (${error.runtimeType})',
        );
        _rememberFailure(key);
        return null;
      } finally {
        _inFlight.remove(key);
      }
    }();
    final file = await future;
    if (mounted && generation == _generation) {
      setState(() {
        _file = file;
        _status = file == null
            ? _ServerAttachmentStatus.unavailable
            : _ServerAttachmentStatus.ready;
      });
    }
    return file;
  }

  Future<void> _open() async {
    var file = _file;
    if (file == null) {
      final reference = widget.serverRef.fetchReference;
      if (reference == null || _status != _ServerAttachmentStatus.idle) return;
      final generation = _generation;
      setState(() => _status = _ServerAttachmentStatus.loading);
      file = await _download(generation, reference);
      if (file == null || !mounted) return;
    }
    if (_isImage) {
      await showImageViewer(context, file);
      return;
    }
    final mimeType =
        widget.localReference?.mimeType ??
        widget.serverRef.fetchReference?.mimeType ??
        '';
    if (artifactViewerRendersInline(
      artifactViewerKindFor(name: widget.name, mimeType: mimeType),
    )) {
      await openArtifactViewer(
        context,
        name: widget.name,
        mimeType: mimeType,
        file: file,
      );
      return;
    }
    final localReference = widget.localReference;
    AttachmentHistoryReference? reference = _local ? localReference : null;
    var previewFile = file;
    if (reference == null) {
      final length = await file.length();
      final persisted = await AttachmentUploader.persistForHistory(
        AttachmentDraft(
          type: AttachmentType.document,
          name: widget.name,
          mimeType: widget.serverRef.fetchReference?.mimeType ?? '',
          sizeBytes: length,
          localPath: file.path,
        ),
        index: 0,
      );
      final resolved = persisted == null
          ? null
          : await AttachmentUploader.resolveHistoryReference(persisted);
      if (persisted != null && resolved != null) {
        reference = persisted;
        previewFile = resolved;
      }
    }
    if (!mounted) return;
    if (reference == null) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).chaAttachmentPreviewUnavailable),
        ),
        kind: HermesNoticeKind.warning,
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AttachmentBytesPreviewScreen(
          name: widget.name,
          sizeLabel: widget.sizeLabel,
          reference: reference!,
          file: previewFile,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final file = _file;
    final ready = _status == _ServerAttachmentStatus.ready && file != null;
    final sizeLabel = switch (_status) {
      _ServerAttachmentStatus.ready ||
      _ServerAttachmentStatus.idle => widget.sizeLabel,
      _ServerAttachmentStatus.loading => strings.cm1215AttachmentLoading,
      _ServerAttachmentStatus.unavailable =>
        strings.cm1215AttachmentUnavailable,
      _ServerAttachmentStatus.serverOnly => strings.cm1215AttachmentServerOnly,
    };
    final mayOpen = ready || _status == _ServerAttachmentStatus.idle;
    final card = AttachmentCard(
      name: widget.name,
      mimeType:
          widget.localReference?.mimeType ??
          widget.serverRef.fetchReference?.mimeType ??
          '',
      sizeLabel: sizeLabel,
      thumbnailFile: ready && _isImage ? file : null,
      onTap: mayOpen ? _open : null,
    );
    if (!mayOpen) return card;
    return Semantics(
      button: true,
      label: strings.chaPreviewAttachment(widget.name),
      onTap: _open,
      excludeSemantics: true,
      child: card,
    );
  }
}
