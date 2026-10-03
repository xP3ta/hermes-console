import 'dart:async';

import '../models/desktop_model_catalog.dart';
import '../models/model_active_info.dart';
import '../models/model_provider.dart';

/// Where the chat model picker got its catalog from. It decides where a
/// selection is persisted, so it travels with every cached entry.
enum ModelPickerSource { socket, bridge, dashboard, gateway }

/// One catalog as the chat model picker shows it.
final class ModelPickerResult {
  const ModelPickerResult({
    required this.info,
    required this.providers,
    required this.source,
    this.desktopCatalog,
  });

  final ModelActiveInfo info;
  final List<ModelProvider> providers;
  final ModelPickerSource source;

  /// Typed catalog when [source] is [ModelPickerSource.socket].
  final DesktopModelCatalog? desktopCatalog;

  bool get hasModels => providers.any((p) => p.models.isNotEmpty);
}

/// A cached picker catalog. [fresh] entries are served as they are; stale
/// ones are painted at once while a refresh runs (stale-while-revalidate).
final class ModelPickerCacheEntry {
  const ModelPickerCacheEntry(this.result, {required this.fresh});

  final ModelPickerResult result;
  final bool fresh;
}

/// Per connection/profile cache of whatever source answered the picker, plus
/// a short memory of failing sources (mk1215).
///
/// Desktop keeps `model.options` in its query cache for 60 s and dedupes
/// subscribers. Console used to cache only the socket catalog, so every
/// picker open without a live runtime paid the Bridge and the Dashboard in
/// series again, and a broken Bridge was retried on every open and resume.
final class ModelPickerCache {
  ModelPickerCache({
    this.freshFor = const Duration(seconds: 60),
    this.keepStaleFor = const Duration(minutes: 30),
    this.failureCooldown = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration freshFor;
  final Duration keepStaleFor;
  final Duration failureCooldown;
  final DateTime Function() _now;

  final Map<String, ({DateTime at, ModelPickerResult result, bool stale})>
  _entries = {};
  final Map<String, DateTime> _failures = {};
  final Map<String, Future<ModelPickerResult>> _inFlight = {};

  static String key(String connectionId, String profile) =>
      '$connectionId\u0000$profile';

  ModelPickerCacheEntry? peek(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    final age = _now().difference(entry.at);
    if (age >= keepStaleFor) {
      _entries.remove(key);
      return null;
    }
    return ModelPickerCacheEntry(
      entry.result,
      fresh: !entry.stale && age < freshFor,
    );
  }

  void write(String key, ModelPickerResult result) {
    _entries[key] = (at: _now(), result: result, stale: false);
  }

  /// Marks the entry stale (a model change made its "current" marker old)
  /// but keeps it so the next open still paints at once.
  void invalidate(String key) {
    final entry = _entries[key];
    if (entry == null) return;
    _entries[key] = (at: entry.at, result: entry.result, stale: true);
  }

  /// Drops every entry and failure (tests, or a forced full refresh).
  void clear() {
    _entries.clear();
    _failures.clear();
  }

  bool isCoolingDown(String key, ModelPickerSource source) {
    final at = _failures['$key\u0000${source.name}'];
    return at != null && _now().difference(at) < failureCooldown;
  }

  void noteFailure(String key, ModelPickerSource source) =>
      _failures['$key\u0000${source.name}'] = _now();

  void noteSuccess(String key, ModelPickerSource source) =>
      _failures.remove('$key\u0000${source.name}');
}

/// One HTTP fallback of the picker as the chat screen reads it: `null` when
/// the source has no catalog.
typedef ModelPickerFallback =
    Future<(ModelActiveInfo, List<ModelProvider>)?> Function();

typedef ModelPickerSourceLoader = Future<ModelPickerResult?> Function();

/// Loads the picker catalog like Desktop: the gateway socket first, then the
/// read-only fallbacks raced in parallel with a short timeout each, and the
/// gateway model list last. Concurrent calls for the same [key] share one
/// load, and the winner is cached whatever its source.
///
/// Throws a [StateError] only when no source produced a catalog.
Future<ModelPickerResult> loadModelPickerCatalog({
  required ModelPickerCache cache,
  required String key,
  required Map<ModelPickerSource, ModelPickerSourceLoader> sources,
  Duration fallbackTimeout = const Duration(seconds: 4),
}) {
  final running = cache._inFlight[key];
  if (running != null) return running;
  final load = _load(cache, key, sources, fallbackTimeout);
  cache._inFlight[key] = load;
  void forget() {
    if (identical(cache._inFlight[key], load)) cache._inFlight.remove(key);
  }

  load.then<void>((_) => forget(), onError: (Object _) => forget());
  return load;
}

Future<ModelPickerResult> _load(
  ModelPickerCache cache,
  String key,
  Map<ModelPickerSource, ModelPickerSourceLoader> sources,
  Duration fallbackTimeout,
) async {
  // A source that just failed is skipped for a while, unless every source is
  // cooling down: the picker is an explicit action and must still try.
  final everyCooling = sources.keys.every((s) => cache.isCoolingDown(key, s));
  bool usable(ModelPickerSource source) =>
      sources.containsKey(source) &&
      (everyCooling || !cache.isCoolingDown(key, source));

  Future<ModelPickerResult?> attempt(
    ModelPickerSource source, {
    Duration? timeout,
  }) async {
    ModelPickerResult? result;
    try {
      final pending = sources[source]!();
      result = await (timeout == null ? pending : pending.timeout(timeout));
    } catch (_) {
      result = null;
    }
    if (result == null) {
      cache.noteFailure(key, source);
    } else {
      cache.noteSuccess(key, source);
    }
    return result;
  }

  ModelPickerResult? emptyAnswer;
  ModelPickerResult? accept(ModelPickerResult? result) {
    if (result == null) return null;
    if (result.hasModels) {
      cache.write(key, result);
      return result;
    }
    emptyAnswer ??= result;
    return null;
  }

  // 1) The gateway socket (its own short timeout lives in the client).
  if (usable(ModelPickerSource.socket)) {
    final won = accept(await attempt(ModelPickerSource.socket));
    if (won != null) return won;
  }

  // 2) Bridge and Dashboard in parallel: the first catalog with models wins.
  final racers = [
    for (final source in const [
      ModelPickerSource.bridge,
      ModelPickerSource.dashboard,
    ])
      if (usable(source)) source,
  ];
  if (racers.isNotEmpty) {
    final winner = Completer<ModelPickerResult?>();
    var pending = racers.length;
    for (final source in racers) {
      unawaited(
        attempt(source, timeout: fallbackTimeout).then((result) {
          pending--;
          // A slower racer that answers after the winner must not write the
          // cache: the next open would switch to a source the user never saw.
          if (winner.isCompleted) return;
          final won = accept(result);
          if (won != null) {
            winner.complete(won);
          } else if (pending == 0) {
            winner.complete(null);
          }
        }),
      );
    }
    final won = await winner.future;
    if (won != null) return won;
  }

  // 3) The gateway's own model list as the last resort.
  if (usable(ModelPickerSource.gateway)) {
    final won = accept(
      await attempt(ModelPickerSource.gateway, timeout: fallbackTimeout),
    );
    if (won != null) return won;
  }

  final empty = emptyAnswer;
  if (empty != null) return empty;
  throw StateError('No model catalog source answered');
}
