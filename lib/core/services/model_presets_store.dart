import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/desktop_session_config.dart';
import '../models/desktop_model_catalog.dart';

String modelPresetKey(String provider, String model) => '$provider::$model';

final class ModelPreset {
  final DesktopReasoningEffort? effort;
  final DesktopFastMode? fast;

  const ModelPreset({this.effort, this.fast});

  ModelPreset copyWith({
    DesktopReasoningEffort? effort,
    DesktopFastMode? fast,
  }) => ModelPreset(effort: effort ?? this.effort, fast: fast ?? this.fast);

  Map<String, dynamic> toJson() => {
    if (effort != null) 'effort': effort!.wire,
    if (fast != null) 'fast': fast!.wire,
  };

  factory ModelPreset.fromJson(Object? value) {
    final json = value is Map ? value : const {};
    DesktopReasoningEffort? effort;
    DesktopFastMode? fast;
    final rawEffort = json['effort'];
    final rawFast = json['fast'];
    for (final item in DesktopReasoningEffort.values) {
      if (item.wire == rawEffort) effort = item;
    }
    for (final item in DesktopFastMode.values) {
      if (item.wire == rawFast) fast = item;
    }
    return ModelPreset(effort: effort, fast: fast);
  }

  @override
  bool operator ==(Object other) =>
      other is ModelPreset && effort == other.effort && fast == other.fast;

  @override
  int get hashCode => Object.hash(effort, fast);
}

final Expando<Map<String, Future<void>>> _writeChains = Expando();

final class ModelPresetsStore {
  final SharedPreferences _prefs;
  final String connectionId;

  const ModelPresetsStore(this._prefs, {required this.connectionId});

  String get _storageKey => 'model_presets_v1.$connectionId';

  Map<String, ModelPreset> _readAll() {
    final raw = _prefs.getString(_storageKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String)
            entry.key as String: ModelPreset.fromJson(entry.value),
      };
    } catch (_) {
      return {};
    }
  }

  ModelPreset? read(String provider, String model) =>
      _readAll()[modelPresetKey(provider, model)];

  Future<ModelPreset?> merge(
    String provider,
    String model, {
    DesktopReasoningEffort? effort,
    DesktopFastMode? fast,
  }) => _serialized(() async {
    final all = _readAll();
    final key = modelPresetKey(provider, model);
    final previous = all[key];
    all[key] = (previous ?? const ModelPreset()).copyWith(
      effort: effort,
      fast: fast,
    );
    await _writeAll(all);
    return previous;
  });

  Future<void> restore(String provider, String model, ModelPreset? preset) =>
      _serialized(() async {
        final all = _readAll();
        final key = modelPresetKey(provider, model);
        if (preset == null) {
          all.remove(key);
        } else {
          all[key] = preset;
        }
        await _writeAll(all);
      });

  /// Runs one read-modify-write of the shared blob after every earlier one
  /// for the same preferences and connection has finished writing, so the
  /// read always sees the latest blob. The chain lives on the preferences
  /// object because callers build a fresh store per update.
  Future<T> _serialized<T>(Future<T> Function() update) {
    final chains = _writeChains[_prefs] ??= <String, Future<void>>{};
    final key = _storageKey;
    final result = (chains[key] ?? Future<void>.value()).then((_) => update());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    chains[key] = tail;
    tail.whenComplete(() {
      if (identical(chains[key], tail)) chains.remove(key);
    });
    return result;
  }

  Future<void> _writeAll(Map<String, ModelPreset> values) => _prefs.setString(
    _storageKey,
    jsonEncode({for (final entry in values.entries) entry.key: entry.value}),
  );
}

Future<void> applyModelPresetForCapabilities({
  required ModelPreset? preset,
  required DesktopModelCapabilities? capabilities,
  required Future<void> Function(DesktopReasoningEffort effort) applyEffort,
  required Future<void> Function(DesktopFastMode mode) applyFast,
}) async {
  if (preset?.effort != null && capabilities?.reasoning == true) {
    await applyEffort(preset!.effort!);
  }
  if (preset?.fast != null && capabilities?.fast == true) {
    await applyFast(preset!.fast!);
  }
}
