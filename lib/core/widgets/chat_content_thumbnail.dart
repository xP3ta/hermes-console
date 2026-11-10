import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../services/artifact_media.dart';
import '../services/chat_content_extractor.dart';
import '../theme/app_theme.dart';
import 'console_loader.dart';

/// Fetches the images of the Artefactos grid for their thumbnails.
///
/// A conversation can hold hundreds of images, remote or private to the
/// Hermes server, so nothing is fetched up front: a thumbnail asks when it is
/// built (the grid builds only what is on screen or about to be), at most
/// [maxConcurrent] fetches run at once, and a request whose thumbnail left
/// the screen before its turn is dropped. [fetch] stores the bytes only in
/// the app's own media cache; this class keeps just the last [maxEntries]
/// outcomes in memory, each failure with its reason, until [retryFailed].
class ChatContentThumbnailLoader extends ChangeNotifier {
  ChatContentThumbnailLoader({
    required this.fetch,
    this.maxConcurrent = 3,
    this.maxEntries = 120,
    this.cacheKey,
  }) : assert(maxConcurrent > 0),
       assert(maxEntries > 0);

  /// Brings an image to a file in the app-private cache; an
  /// [ArtifactFetchFailure] says why it could not.
  final Future<File> Function(ChatContentItem item) fetch;
  final int maxConcurrent;
  final int maxEntries;

  /// What tells two images apart; their value by default. A view across
  /// profiles includes the owner, since one path can exist in several.
  final String Function(ChatContentItem item)? cacheKey;

  /// The key [item]'s outcome is remembered under.
  String keyOf(ChatContentItem item) => cacheKey?.call(item) ?? item.value;

  /// Settled outcomes by key, least recently used first.
  final Map<String, ThumbnailOutcome> _settled = {};
  final Map<String, Future<File?>> _running = {};
  int _retries = 0;
  final Queue<_PendingThumbnail> _queue = Queue();
  int _active = 0;
  bool _disposed = false;

  /// Fetches running right now.
  @visibleForTesting
  int get activeCount => _active;

  /// Requests waiting for a free slot.
  @visibleForTesting
  int get queuedCount => _queue.length;

  /// Outcomes kept in memory.
  @visibleForTesting
  int get settledCount => _settled.length;

  /// Thumbnails whose fetch failed, as remembered now.
  int get failedCount =>
      _settled.values.where((outcome) => outcome.file == null).length;

  /// Bumped by [retryFailed]; a failed thumbnail asks again when it moves.
  int get retries => _retries;

  /// The settled outcome under [key] (see [keyOf]): the file, or null with
  /// the reason when the fetch failed; null while there is none.
  ThumbnailOutcome? settled(String key) {
    final outcome = _settled.remove(key);
    if (outcome == null) return null;
    _settled[key] = outcome;
    return outcome;
  }

  /// Forgets every failure, so each failed thumbnail on screen asks again
  /// (the retry button; reopening the view starts a new loader anyway).
  void retryFailed() {
    if (_disposed) return;
    _settled.removeWhere((_, outcome) => outcome.file == null);
    _retries++;
    notifyListeners();
  }

  /// The thumbnail file of [item], or null when it cannot be fetched.
  /// [wanted] is asked again when the request's turn comes; false drops it.
  Future<File?> load(ChatContentItem item, {required bool Function() wanted}) {
    final value = keyOf(item);
    final known = settled(value);
    if (known != null) return Future.value(known.file);
    final running = _running[value];
    if (running != null) return running;
    for (final pending in _queue) {
      if (keyOf(pending.item) == value) {
        pending.wanted.add(wanted);
        return pending.completer.future;
      }
    }
    final pending = _PendingThumbnail(item, wanted);
    _queue.add(pending);
    _pump();
    return pending.completer.future;
  }

  void _pump() {
    while (!_disposed && _active < maxConcurrent && _queue.isNotEmpty) {
      final next = _queue.removeFirst();
      if (!next.wanted.any((wanted) => wanted())) {
        // Scrolled away before its turn: nothing is fetched or remembered.
        next.completer.complete(null);
        continue;
      }
      final value = keyOf(next.item);
      _active++;
      final outcome = _fetch(next.item);
      final future = outcome.then((settled) => settled.file);
      _running[value] = future;
      unawaited(
        outcome.then((settled) {
          _active--;
          _running.remove(value);
          if (!_disposed) _remember(value, settled);
          next.completer.complete(settled.file);
          _pump();
        }),
      );
    }
  }

  Future<ThumbnailOutcome> _fetch(ChatContentItem item) async {
    try {
      return (file: await fetch(item), problem: null);
    } on ArtifactFetchFailure catch (failure) {
      return (file: null, problem: failure.problem);
    } catch (error) {
      return (file: null, problem: artifactFetchProblemOf(error, https: false));
    }
  }

  void _remember(String value, ThumbnailOutcome outcome) {
    _settled.remove(value);
    _settled[value] = outcome;
    while (_settled.length > maxEntries) {
      _settled.remove(_settled.keys.first);
    }
    // The view offers its retry button while something failed.
    if (outcome.file == null) notifyListeners();
  }

  /// Drops every waiting request; running fetches finish unobserved.
  @override
  void dispose() {
    _disposed = true;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().completer.complete(null);
    }
    _settled.clear();
    super.dispose();
  }
}

/// A thumbnail's settled fetch: the file, or null and why.
typedef ThumbnailOutcome = ({File? file, ArtifactFetchProblem? problem});

class _PendingThumbnail {
  _PendingThumbnail(this.item, bool Function() wanted) : wanted = [wanted];

  final ChatContentItem item;
  final List<bool Function()> wanted;
  final Completer<File?> completer = Completer<File?>();
}

/// Why an item of «Artefactos» has no picture or did not open, in a few
/// words («Imagen remota no disponible», «Ruta sin carpeta»…). Every case
/// says its own reason; none falls back to a bare «Sin vista previa».
String artifactFetchReason(Strings strings, ArtifactFetchProblem? problem) =>
    switch (problem) {
      ArtifactFetchProblem.remote => strings.artThumbRemote,
      ArtifactFetchProblem.insecure => strings.artThumbInsecure,
      ArtifactFetchProblem.noFolder => strings.artThumbNoFolder,
      ArtifactFetchProblem.notFound => strings.artThumbNotFound,
      ArtifactFetchProblem.tooLarge => strings.artThumbTooLarge,
      ArtifactFetchProblem.denied => strings.artThumbDenied,
      ArtifactFetchProblem.unsupported => strings.artThumbUnsupported,
      ArtifactFetchProblem.unreachable => strings.artThumbUnreachable,
      ArtifactFetchProblem.timedOut => strings.artThumbTimedOut,
      ArtifactFetchProblem.notImage => strings.artThumbNotImage,
      ArtifactFetchProblem.undecodable => strings.artThumbUndecodable,
      ArtifactFetchProblem.failed || null => strings.artThumbDownloadFailed,
    };

enum _ThumbState { loading, ready, failed, none, svg }

/// The picture of one image in the Artefactos grid: the real image, scaled
/// down when decoded, with its own loading and error states.
class ChatContentThumbnail extends StatefulWidget {
  const ChatContentThumbnail({
    required this.item,
    required this.loader,
    required this.height,
    super.key,
  });

  final ChatContentItem item;

  /// Null when the chat cannot fetch images: a plain image glyph is shown.
  final ChatContentThumbnailLoader? loader;
  final double height;

  @override
  State<ChatContentThumbnail> createState() => _ChatContentThumbnailState();
}

class _ChatContentThumbnailState extends State<ChatContentThumbnail> {
  _ThumbState _state = _ThumbState.loading;
  File? _file;
  Uint8List? _inline;
  ArtifactFetchProblem? _problem;
  int _retries = 0;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    final value = item.value;
    final lower = value.toLowerCase();
    // Flutter cannot decode SVG: say so instead of fetching it.
    if (lower.startsWith('data:image/svg') ||
        item.label.toLowerCase().endsWith('.svg')) {
      _state = _ThumbState.svg;
      return;
    }
    if (lower.startsWith('data:')) {
      final data = Uri.tryParse(value)?.data;
      _inline = data?.contentAsBytes();
      _state = _inline == null ? _ThumbState.failed : _ThumbState.ready;
      return;
    }
    final loader = widget.loader;
    if (loader == null) {
      _state = _ThumbState.none;
      return;
    }
    _retries = loader.retries;
    loader.addListener(_onLoader);
    final known = loader.settled(loader.keyOf(item));
    if (known != null) {
      _settle(known);
      return;
    }
    // Asked once the frame that built it is done, never during build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _request());
  }

  void _request() {
    final loader = widget.loader;
    if (!mounted || loader == null) return;
    final item = widget.item;
    unawaited(
      loader.load(item, wanted: () => mounted).then((file) {
        if (!mounted) return;
        setState(
          () => _settle(
            loader.settled(loader.keyOf(item)) ??
                (file: file, problem: ArtifactFetchProblem.failed),
          ),
        );
      }),
    );
  }

  /// The view asked to retry: a failed thumbnail fetches again.
  void _onLoader() {
    final loader = widget.loader;
    if (loader == null || loader.retries == _retries) return;
    _retries = loader.retries;
    if (_state != _ThumbState.failed || _inline != null) return;
    setState(() {
      _state = _ThumbState.loading;
      _problem = null;
    });
    _request();
  }

  void _settle(ThumbnailOutcome outcome) {
    _file = outcome.file;
    _problem = outcome.problem;
    _state = outcome.file == null ? _ThumbState.failed : _ThumbState.ready;
  }

  @override
  void dispose() {
    widget.loader?.removeListener(_onLoader);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    Widget failed([ArtifactFetchProblem? problem]) => _ThumbNote(
      key: const ValueKey('sa1215-thumb-error'),
      icon: Icons.broken_image_outlined,
      text: artifactFetchReason(strings, problem ?? _problem),
    );
    Widget loading() => Center(
      key: const ValueKey('sa1215-thumb-loading'),
      child: ConsoleLoader.small(label: strings.artThumbLoading, dimension: 20),
    );
    final Widget child = switch (_state) {
      _ThumbState.loading => loading(),
      _ThumbState.failed => failed(),
      // Flutter does not draw SVG: the tile says so, also to TalkBack.
      _ThumbState.svg => _ThumbNote(
        key: const ValueKey('sa1215-thumb-svg'),
        icon: Icons.image_outlined,
        text: strings.artThumbSvg,
      ),
      _ThumbState.none => Center(
        key: const ValueKey('sa1215-thumb-none'),
        child: Icon(
          Icons.image_outlined,
          size: 32,
          color: colors.textSecondary,
        ),
      ),
      _ThumbState.ready => LayoutBuilder(
        builder: (context, box) {
          final ratio = MediaQuery.devicePixelRatioOf(context);
          // Bounded both ways: a very tall picture is not decoded at its
          // full height for a small tile.
          final width = (box.maxWidth * ratio).round().clamp(64, 1024);
          final height = (box.maxHeight * ratio).round().clamp(64, 1024);
          final inline = _inline;
          final ImageProvider source = inline != null
              ? MemoryImage(inline)
              : FileImage(_file!);
          return ExcludeSemantics(
            child: Image(
              key: const ValueKey('sa1215-thumb-image'),
              image: ResizeImage(
                source,
                width: width,
                height: height,
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.contain,
              width: box.maxWidth,
              height: box.maxHeight,
              gaplessPlayback: true,
              frameBuilder: (context, image, frame, synchronous) =>
                  frame == null && !synchronous ? loading() : image,
              errorBuilder: (context, error, stack) =>
                  failed(ArtifactFetchProblem.undecodable),
            ),
          );
        },
      ),
    };
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: ColoredBox(
        color: colors.surfaceVariant.withValues(alpha: .6),
        child: child,
      ),
    );
  }
}

/// A tile with no picture: an icon and why, read by TalkBack as the reason.
class _ThumbNote extends StatelessWidget {
  const _ThumbNote({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      label: text,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 28, color: colors.textSecondary),
              const SizedBox(height: 4),
              Flexible(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: HermesType.support.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
