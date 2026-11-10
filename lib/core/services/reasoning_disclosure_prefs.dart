import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hermes Desktop's «Collapse thinking by default»
/// (`store/reasoning-disclosure.ts`, `reasoning.collapsedByDefault`). On (the
/// default since 1.4.0, mock 137 A), the thought being written is one line
/// the reader opens; off, it opens at six lines while it thinks. One switch
/// for the device, in Settings.
class ReasoningDisclosurePrefs extends ChangeNotifier {
  ReasoningDisclosurePrefs._(this._prefs)
    : _collapsedByDefault = _prefs?.getBool(key) ?? defaultCollapsed;

  /// Mock 137 A (the owner, 1.4.0): the live thought is one thin line unless
  /// the reader asks for more. Hermes Desktop's
  /// `$reasoningCollapsedByDefault` starts the other way round; the owner asked
  /// for this one. Off is Console before 1.4.0: open at six lines while it
  /// thinks.
  static const bool defaultCollapsed = true;

  static const String key = 'chat_reasoning_collapsed_by_default';

  final SharedPreferences? _prefs;
  bool _collapsedByDefault;

  static ReasoningDisclosurePrefs? _shared;

  static ReasoningDisclosurePrefs get shared =>
      _shared ??= ReasoningDisclosurePrefs._(null);

  static Future<ReasoningDisclosurePrefs> load([
    SharedPreferences? prefs,
  ]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = ReasoningDisclosurePrefs._(resolved);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static void debugUse(ReasoningDisclosurePrefs? store) => _shared = store;

  bool get collapsedByDefault => _collapsedByDefault;

  Future<void> setCollapsedByDefault(bool value) async {
    if (_collapsedByDefault == value) return;
    _collapsedByDefault = value;
    notifyListeners();
    // Both values are kept: with the default on, off has to be remembered.
    await _prefs?.setBool(key, value);
  }
}
