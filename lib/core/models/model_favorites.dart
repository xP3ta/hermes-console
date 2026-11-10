import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The models a person starred in the model sheet: an ordered list of
/// `provider|model` pairs kept on the device, per connection and profile.
///
/// Order is the order they were starred in, so the list never reshuffles by
/// itself. At most [maxEntries] are kept: a full list refuses one more
/// ([toggled] returns it unchanged) instead of dropping an older favourite.
@immutable
final class ModelFavorites {
  const ModelFavorites._(this._keys);

  static const empty = ModelFavorites._([]);

  /// Most favourites kept.
  static const maxEntries = 12;

  final List<String> _keys;

  /// SharedPreferences key: one list per connection and profile, as the
  /// other per-profile model settings (`model_usage_v1_…`).
  static String storageKey(String connectionId, String profile) =>
      'model_favorites_v1_${connectionId}_$profile';

  static String keyOf(String provider, String model) => '$provider|$model';

  static ModelFavorites decode(String? raw) {
    if (raw == null || raw.isEmpty) return empty;
    try {
      final json = jsonDecode(raw);
      if (json is! List) return empty;
      final keys = <String>[];
      for (final item in json) {
        if (item is String &&
            item.indexOf('|') > 0 &&
            item.indexOf('|') < item.length - 1 &&
            !keys.contains(item)) {
          keys.add(item);
        }
        if (keys.length == maxEntries) break;
      }
      return keys.isEmpty ? empty : ModelFavorites._(List.unmodifiable(keys));
    } on FormatException {
      return empty;
    }
  }

  String encode() => jsonEncode(_keys);

  bool get isEmpty => _keys.isEmpty;
  bool get isNotEmpty => _keys.isNotEmpty;
  bool get isFull => _keys.length >= maxEntries;
  int get length => _keys.length;

  bool contains(String provider, String model) =>
      _keys.contains(keyOf(provider, model));

  /// The favourites in the order they were starred.
  List<({String provider, String model})> get entries => [
    for (final key in _keys)
      (
        provider: key.substring(0, key.indexOf('|')),
        model: key.substring(key.indexOf('|') + 1),
      ),
  ];

  /// This list with [provider]/[model] starred, or unstarred if it was.
  /// A full list returns itself when asked to add one more.
  ModelFavorites toggled(String provider, String model) {
    if (provider.isEmpty || model.isEmpty) return this;
    final key = keyOf(provider, model);
    if (_keys.contains(key)) {
      final next = [..._keys]..remove(key);
      return next.isEmpty ? empty : ModelFavorites._(List.unmodifiable(next));
    }
    if (isFull) return this;
    return ModelFavorites._(List.unmodifiable([..._keys, key]));
  }

  @override
  bool operator ==(Object other) =>
      other is ModelFavorites && listEquals(other._keys, _keys);

  @override
  int get hashCode => Object.hashAll(_keys);
}
