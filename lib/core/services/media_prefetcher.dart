import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../utils/byte_bounded_lru_cache.dart';
import 'generated_media_service.dart';
import 'media_dimensions.dart';

typedef MediaPrefetchLoad = Future<File> Function();
typedef MediaDecodeWarmer = Future<void> Function(File file);

/// Starts fetching the media of a message as soon as the message arrives
/// (live stream or transcript page), before its row is built, so that the
/// row paints from the private disk cache with its final size already known.
///
/// - Fetches go through [GeneratedMediaService.runAutoLoad], so prefetches
///   and on-screen auto-loads together never exceed two at a time.
/// - The caller's [MediaPrefetchLoad] is the same download the row uses
///   (same cache scope), so a row that appears mid-fetch joins it through
///   [pending] instead of issuing a second request.
/// - Only server-path media the row would auto-load, within the automatic
///   size cap, is prefetched.
/// - While App Lock is locked nothing is fetched or decoded: requests wait
///   and resume on unlock.
/// - Images get their dimensions from a header probe and their thumbnail
///   bitmap decoded at display size into the image cache.
class MediaPrefetcher {
  MediaPrefetcher({
    ValueListenable<bool>? locked,
    MediaDecodeWarmer? warmDecode,
  }) : _lockedOverride = locked,
       _warmDecode = warmDecode ?? _precacheThumbnail;

  static final MediaPrefetcher instance = MediaPrefetcher().._registerClear();

  /// App Lock state for [instance]; wired once at startup.
  static ValueListenable<bool>? appLocked;

  static const int _readyCapacity = 256;

  final ValueListenable<bool>? _lockedOverride;
  final MediaDecodeWarmer _warmDecode;
  final Map<String, Future<File?>> _inFlight = <String, Future<File?>>{};
  final LinkedHashMap<String, File> _ready = LinkedHashMap<String, File>();
  final List<VoidCallback> _onUnlock = <VoidCallback>[];
  ValueListenable<bool>? _listening;
  int _epoch = 0;

  ValueListenable<bool>? get _lock => _lockedOverride ?? appLocked;
  bool get _locked => _lock?.value ?? false;

  void _registerClear() => PrivateRenderCaches.register(clear);

  /// Queues a background fetch. Returns false when the media is not eligible
  /// (not a server path, over the automatic cap, or unsafe to auto-load).
  bool prefetch({
    required String key,
    required GeneratedMediaReference reference,
    required MediaPrefetchLoad load,
  }) {
    if (reference.sourceKind != GeneratedMediaSourceKind.serverPath ||
        !GeneratedMediaService.allowsAutoLoad(reference)) {
      return false;
    }
    final size = reference.sizeBytes;
    if (size != null && size > GeneratedMediaService.autoLoadLimit(reference)) {
      return false;
    }
    if (_ready.containsKey(key) || _inFlight.containsKey(key)) return true;
    final epoch = _epoch;
    final future = _run(key, reference, load, epoch);
    _inFlight[key] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_inFlight[key], future)) _inFlight.remove(key);
      }),
    );
    return true;
  }

  /// The fetch in progress for [key], for a row to join.
  Future<File?>? pending(String key) => _inFlight[key];

  /// The verified cached copy a finished prefetch produced.
  File? readyFile(String key) {
    final file = _ready.remove(key);
    if (file == null) return null;
    if (!file.existsSync()) return null;
    _ready[key] = file;
    return file;
  }

  /// Forgets everything (connection removed, profile switch).
  void clear() {
    _epoch++;
    _ready.clear();
    _inFlight.clear();
    _onUnlock.clear();
    MediaDimensionsCache.clear();
  }

  Future<void> _whileUnlocked() {
    if (!_locked) return Future<void>.value();
    final completer = Completer<void>();
    _onUnlock.add(completer.complete);
    final lock = _lock;
    if (lock != null && !identical(_listening, lock)) {
      _listening?.removeListener(_drainUnlocked);
      _listening = lock;
      lock.addListener(_drainUnlocked);
    }
    return completer.future;
  }

  void _drainUnlocked() {
    if (_locked || _onUnlock.isEmpty) return;
    final waiting = List<VoidCallback>.of(_onUnlock);
    _onUnlock.clear();
    for (final resume in waiting) {
      resume();
    }
  }

  Future<File?> _run(
    String key,
    GeneratedMediaReference reference,
    MediaPrefetchLoad load,
    int epoch,
  ) async {
    try {
      await _whileUnlocked();
      if (epoch != _epoch) return null;
      final file = await GeneratedMediaService.runAutoLoad<File?>(() async {
        // The lock may have landed while this waited for a slot.
        if (_locked || epoch != _epoch) return null;
        return load();
      });
      if (file == null) {
        if (_locked && epoch == _epoch) {
          // Locked while queued: retry once unlocked, still before any row.
          await _whileUnlocked();
          if (epoch != _epoch) return null;
          return await _run(key, reference, load, epoch);
        }
        return null;
      }
      if (epoch != _epoch) return null;
      if (reference.kind == GeneratedMediaKind.image) {
        final size = await readImageDimensions(file);
        if (size != null) {
          MediaDimensionsCache.remember(key, size);
          MediaDimensionsCache.remember(file.path, size);
        }
      }
      _ready.remove(key);
      _ready[key] = file;
      while (_ready.length > _readyCapacity) {
        _ready.remove(_ready.keys.first);
      }
      if (reference.kind == GeneratedMediaKind.image) {
        // A row joining this fetch needs the file, not the bitmap: warm the
        // decode on the side (the image cache shares the pending load).
        unawaited(_warm(file, epoch));
      }
      return file;
    } catch (error) {
      debugPrint('[media-prefetch] skipped (${error.runtimeType})');
      return null;
    }
  }

  Future<void> _warm(File file, int epoch) async {
    // Decoding is private work too: never while locked.
    await _whileUnlocked();
    if (epoch != _epoch) return;
    try {
      await _warmDecode(file);
    } catch (_) {
      // The row decodes on its own if warming failed.
    }
  }

  static Future<void> _precacheThumbnail(File file) {
    final completer = Completer<void>();
    final stream = generatedImageThumbnailProvider(
      file,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) {
        if (!completer.isCompleted) completer.complete();
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!completer.isCompleted) completer.complete();
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  @visibleForTesting
  void resetForTesting() => clear();

  @visibleForTesting
  Iterable<String> get trackedKeysForTesting => {
    ..._inFlight.keys,
    ..._ready.keys,
  };
}
