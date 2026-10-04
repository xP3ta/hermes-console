import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'embed_detector.dart';

/// Mermaid needs a bundled JavaScript runtime, which waits for the owner's
/// approval. Until then its fences stay code blocks and no toggle is shown.
const bool embedMermaidAvailable = false;

/// How a type of rich embed behaves in the chat. `off` is the default for
/// every type: the message renders exactly as before and nothing is fetched.
enum EmbedMode {
  off,
  ask,
  always;

  static EmbedMode fromName(Object? name) {
    for (final mode in values) {
      if (mode.name == name) return mode;
    }
    return off;
  }
}

/// Per-device consent for rich embeds. Never synced and never sent to the
/// server: loading an embed reaches a third party, so the choice stays here.
class EmbedConsentStore extends ChangeNotifier {
  EmbedConsentStore._(this._prefs);

  static const String keyPrefix = 'chat_embed_mode_';

  final SharedPreferences? _prefs;
  final Map<EmbedType, EmbedMode> _modes = {};

  static EmbedConsentStore? _shared;

  /// The app-wide store. Until [load] finishes every type reads as `off`.
  static EmbedConsentStore get shared => _shared ??= EmbedConsentStore._(null);

  /// Loads the persisted modes into [shared]; safe to call again.
  static Future<EmbedConsentStore> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = EmbedConsentStore._(resolved);
    store._read();
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static EmbedConsentStore forTesting(SharedPreferences? prefs) {
    final store = EmbedConsentStore._(prefs);
    if (prefs != null) store._read();
    return store;
  }

  @visibleForTesting
  static void debugUse(EmbedConsentStore? store) => _shared = store;

  void _read() {
    for (final type in EmbedType.values) {
      final mode = EmbedMode.fromName(
        _prefs?.getString('$keyPrefix${type.name}'),
      );
      if (mode != EmbedMode.off) _modes[type] = mode;
    }
  }

  EmbedMode modeFor(EmbedType type) => _modes[type] ?? EmbedMode.off;

  Future<void> setMode(EmbedType type, EmbedMode mode) async {
    if (modeFor(type) == mode) return;
    if (mode == EmbedMode.off) {
      _modes.remove(type);
    } else {
      _modes[type] = mode;
    }
    notifyListeners();
    final prefs = _prefs;
    if (prefs == null) return;
    if (mode == EmbedMode.off) {
      await prefs.remove('$keyPrefix${type.name}');
    } else {
      await prefs.setString('$keyPrefix${type.name}', mode.name);
    }
  }

  /// "Clear allowed services": every standing "always" goes back to asking.
  Future<void> clearAllowed() async {
    for (final type in EmbedType.values) {
      if (modeFor(type) == EmbedMode.always) {
        await setMode(type, EmbedMode.ask);
      }
    }
  }

  bool get anyAllowed =>
      EmbedType.values.any((type) => modeFor(type) == EmbedMode.always);
}
