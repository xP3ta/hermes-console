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
  }) async {
    final all = _readAll();
    final key = modelPresetKey(provider, model);
    final previous = all[key];
    all[key] = (previous ?? const ModelPreset()).copyWith(
      effort: effort,
      fast: fast,
    );
    await _writeAll(all);
    return previous;
  }

  Future<void> restore(
    String provider,
    String model,
    ModelPreset? preset,
  ) async {
    final all = _readAll();
    final key = modelPresetKey(provider, model);
    if (preset == null) {
      all.remove(key);
    } else {
      all[key] = preset;
    }
    await _writeAll(all);
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
