import 'dart:async';
import 'dart:collection';

/// Debounced, cancellable completion lookups for the composer palettes.
///
/// One instance per palette (`/` commands, `@` references). A keystroke burst
/// collapses into a single request after [debounce]; [cancel] (palette closed,
/// trigger gone, screen disposed) drops the pending timer and makes any
/// in-flight answer stale, so a late reply can never repaint a closed palette.
/// Answers are memoised per query (Desktop `slash-completion-cache` parity):
/// walking back to a query already seen is served without a round trip.
final class ComposerCompletionScheduler<T extends Object> {
  ComposerCompletionScheduler({
    required this.fetch,
    this.debounce = const Duration(milliseconds: 180),
    this.cacheSize = 32,
  });

  final Future<T?> Function(String query) fetch;
  final Duration debounce;
  final int cacheSize;

  final LinkedHashMap<String, T> _cache = LinkedHashMap<String, T>();
  Timer? _timer;
  int _epoch = 0;
  int _requests = 0;

  /// Network lookups actually started (cache hits and debounced-away
  /// keystrokes do not count). Exposed for performance tests.
  int get requestCount => _requests;

  bool get hasPendingTimer => _timer?.isActive ?? false;

  /// Cached answer for [query], if any.
  T? cached(String query) {
    final hit = _cache.remove(query);
    if (hit != null) _cache[query] = hit;
    return hit;
  }

  /// Schedules a lookup for [query]. Any earlier pending or in-flight lookup is
  /// superseded. A cached answer is delivered synchronously, without a timer.
  void schedule(String query, void Function(String query, T? result) onResult) {
    cancel();
    final hit = cached(query);
    if (hit != null) {
      onResult(query, hit);
      return;
    }
    final epoch = _epoch;
    _timer = Timer(debounce, () {
      _timer = null;
      unawaited(_run(query, epoch, onResult));
    });
  }

  Future<void> _run(
    String query,
    int epoch,
    void Function(String query, T? result) onResult,
  ) async {
    _requests++;
    T? result;
    try {
      result = await fetch(query);
    } catch (_) {
      result = null;
    }
    if (epoch != _epoch) return;
    if (result != null) _remember(query, result);
    onResult(query, result);
  }

  void _remember(String query, T value) {
    _cache.remove(query);
    _cache[query] = value;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// Drops the pending timer and invalidates in-flight lookups.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _epoch++;
  }

  /// Forget memoised answers (e.g. the session runtime or cwd changed).
  void clearCache() => _cache.clear();

  void dispose() {
    cancel();
    _cache.clear();
  }
}
