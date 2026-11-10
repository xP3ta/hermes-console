import 'dart:convert';

/// How often the user picked each model in the chat model sheet, to offer
/// the most used ones first. Pure data: persistence lives with the caller.
///
/// Keys are `provider|model`; counts are bounded so a stored blob cannot
/// grow without limit.
final class ModelUsage {
  const ModelUsage._(this._counts);

  static const empty = ModelUsage._({});

  /// Distinct models kept; the least used ones are dropped past this.
  static const maxEntries = 40;

  /// Fewest picks before a model counts as "frequent".
  static const minPicks = 2;

  final Map<String, int> _counts;

  static String keyOf(String provider, String model) => '$provider|$model';

  static ModelUsage decode(String? raw) {
    if (raw == null || raw.isEmpty) return empty;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return empty;
      final counts = <String, int>{};
      for (final entry in json.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && key.contains('|') && value is int && value > 0) {
          counts[key] = value;
        }
      }
      return ModelUsage._(counts);
    } on FormatException {
      return empty;
    }
  }

  String encode() => jsonEncode(_counts);

  int countOf(String provider, String model) =>
      _counts[keyOf(provider, model)] ?? 0;

  /// This usage after one more pick of [provider]/[model].
  ModelUsage bumped(String provider, String model) {
    if (provider.isEmpty || model.isEmpty) return this;
    final next = Map<String, int>.of(_counts);
    final key = keyOf(provider, model);
    next[key] = (next[key] ?? 0) + 1;
    if (next.length > maxEntries) {
      final ordered = next.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return ModelUsage._({
        for (final entry in ordered.take(maxEntries)) entry.key: entry.value,
      });
    }
    return ModelUsage._(next);
  }

  /// The [limit] most picked models (at least [minPicks] picks each), most
  /// used first; ties keep the order of [candidates].
  List<({String provider, String model})> top(
    Iterable<({String provider, String model})> candidates, {
    int limit = 3,
  }) {
    final ranked = [
      for (final c in candidates)
        if (countOf(c.provider, c.model) >= minPicks) c,
    ];
    // List.sort is not stable: rank by count, then by candidate position.
    final position = {for (final (i, c) in ranked.indexed) c: i};
    ranked.sort((a, b) {
      final byCount = countOf(
        b.provider,
        b.model,
      ).compareTo(countOf(a.provider, a.model));
      return byCount != 0 ? byCount : position[a]!.compareTo(position[b]!);
    });
    return ranked.take(limit).toList();
  }
}
