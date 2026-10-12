import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dock_light.dart';

/// Every item the dock can show (edit mode picks 2–5 of them, in the user's
/// order; Inicio is always there). The names are what is stored on the
/// device: they never change, whatever the item is called on screen.
enum GestureDockTab {
  home,
  create,
  projects,
  settings,
  bots,
  search,
  cron,
  tasks,
  tools,
  activity;

  /// Inicio, Nuevo chat, Chats, Bots, Herramientas.
  static const List<GestureDockTab> defaultLayout = [
    GestureDockTab.home,
    GestureDockTab.create,
    GestureDockTab.search,
    GestureDockTab.bots,
    GestureDockTab.tools,
  ];

  /// What the dock showed until 1.2.15 when nobody had edited it: Inicio,
  /// Nuevo, Proyectos, Ajustes.
  static const List<GestureDockTab> legacyDefaultLayout = [
    GestureDockTab.home,
    GestureDockTab.create,
    GestureDockTab.projects,
    GestureDockTab.settings,
  ];
  static const int minTabs = 2;
  static const int maxTabs = 5;

  /// A place the user can be at, so the item that can show as selected.
  /// "Nuevo chat" and "Actividad" do something and stay where they are.
  bool get isPlace =>
      this != GestureDockTab.create && this != GestureDockTab.activity;

  static GestureDockTab? parse(Object? value) => values
      .cast<GestureDockTab?>()
      .firstWhere((t) => t?.name == value, orElse: () => null);

  /// A valid layout: no repeats, Inicio always present, 2–5 entries.
  static List<GestureDockTab> normalize(Iterable<GestureDockTab> raw) {
    final out = <GestureDockTab>[];
    for (final tab in raw) {
      if (!out.contains(tab)) out.add(tab);
    }
    if (!out.contains(GestureDockTab.home)) out.insert(0, GestureDockTab.home);
    if (out.length > maxTabs) {
      final homeAt = out.indexOf(GestureDockTab.home);
      out.remove(GestureDockTab.home);
      out.removeRange(maxTabs - 1, out.length);
      out.insert(homeAt.clamp(0, maxTabs - 1), GestureDockTab.home);
    }
    for (final tab in defaultLayout) {
      if (out.length >= minTabs) break;
      if (!out.contains(tab)) out.add(tab);
    }
    return List.unmodifiable(out);
  }
}

/// Everything the dock keeps per device.
///
/// Payloads written while the dock had gestures and a first-run welcome
/// also carry `gestures`, `auto_hide`, `tips`, `tour_done`, `learned`,
/// `taps`, `last_tip_day`, `skips`, `hide_hint_shown` and `welcome_seen`:
/// they are read past and dropped on the next write.
@immutable
class GestureDockSettings {
  static const schemaVersion = 1;

  /// Which default layout a stored payload was written under. A payload
  /// without it (or with an older one) whose items are still exactly
  /// [GestureDockTab.legacyDefaultLayout] was never edited: it moves to the
  /// current default. Any other layout is the user's and is kept, and so is
  /// that same set of four once it is stored under this version (someone
  /// chose it in the editor).
  static const layoutVersion = 2;

  /// The items the dock shows, in the user's order.
  final List<GestureDockTab> tabs;

  /// Opaque surface instead of the blurred glass (cheaper to draw).
  final bool opaque;

  const GestureDockSettings({
    this.tabs = GestureDockTab.defaultLayout,
    this.opaque = false,
  });

  GestureDockSettings copyWith({List<GestureDockTab>? tabs, bool? opaque}) =>
      GestureDockSettings(
        tabs: tabs ?? this.tabs,
        opaque: opaque ?? this.opaque,
      );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'layout_version': layoutVersion,
    'tabs': [for (final t in tabs) t.name],
    'opaque': opaque,
  };

  /// Defensive: a corrupt or future payload falls back field by field.
  factory GestureDockSettings.fromJson(Object? raw) {
    if (raw is! Map) return const GestureDockSettings();
    final version = raw['schema_version'];
    if (version is! int || version > schemaVersion) {
      return const GestureDockSettings();
    }
    bool flag(String key, bool fallback) {
      final value = raw[key];
      return value is bool ? value : fallback;
    }

    final rawTabs = raw['tabs'];
    var tabs = rawTabs is List
        ? GestureDockTab.normalize([
            for (final entry in rawTabs) ?GestureDockTab.parse(entry),
          ])
        : GestureDockTab.defaultLayout;
    final storedLayout = raw['layout_version'];
    final untouched =
        (storedLayout is! int || storedLayout < layoutVersion) &&
        listEquals(tabs, GestureDockTab.legacyDefaultLayout);
    if (untouched) tabs = GestureDockTab.defaultLayout;
    return GestureDockSettings(tabs: tabs, opaque: flag('opaque', false));
  }
}

/// Shared state of the dock. Every route mounts its own dock, but they all
/// read this one controller, so a dock hidden by hand stays hidden while the
/// user moves between screens.
class GestureDockController {
  GestureDockController();

  static final GestureDockController instance = GestureDockController();

  static const storageKey = 'gesture_dock_v1';

  final ValueNotifier<GestureDockSettings> _settings =
      ValueNotifier<GestureDockSettings>(const GestureDockSettings());
  final ValueNotifier<bool> _hidden = ValueNotifier<bool>(false);

  ValueListenable<GestureDockSettings> get settings => _settings;

  /// The light that glides behind the icons when the selected place
  /// changes. Shared like everything else here, so it goes on from the dock
  /// that was tapped to the dock of the screen that opens.
  final DockLight light = DockLight();

  /// Hidden by hand (the "Esconder el dock" entry of a long-press menu or
  /// of Ajustes › Dock). Nothing else hides the dock, and this is never
  /// stored: the next app start shows it.
  ValueListenable<bool> get hidden => _hidden;

  GestureDockSettings get value => _settings.value;

  final Map<Object, VoidCallback?> _activeDocks = {};
  bool get hasActiveDock => _activeDocks.isNotEmpty;

  bool _loaded = false;
  bool get loaded => _loaded;
  Future<void>? _loading;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw != null) {
        try {
          _settings.value = GestureDockSettings.fromJson(jsonDecode(raw));
        } catch (_) {
          _settings.value = const GestureDockSettings();
        }
      }
      _loaded = true;
    } catch (_) {
      _loading = null;
    }
  }

  Future<void> _update(
    GestureDockSettings Function(GestureDockSettings) change,
  ) async {
    _settings.value = change(_settings.value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(_settings.value.toJson()));
    } catch (_) {
      // The in-memory value stays; the next change retries the write.
    }
  }

  // ---- docks on screen -------------------------------------------------

  /// A dock on the visible route. [republish] is called when another dock
  /// leaves (end of a route transition), so the one still on screen
  /// publishes its geometry again.
  void attach(Object dock, [VoidCallback? republish]) {
    _activeDocks[dock] = republish;
  }

  void detach(Object dock) {
    _activeDocks.remove(dock);
    if (_activeDocks.isEmpty) {
      // Nobody is looking: no frame is spent on it.
      light.rest();
      return;
    }
    for (final republish in _activeDocks.values.toList()) {
      republish?.call();
    }
  }

  // ---- settings --------------------------------------------------------

  Future<void> setOpaque(bool opaque) =>
      _update((s) => s.copyWith(opaque: opaque));

  /// Edit mode's "Listo": stores [tabs] (normalized: Inicio kept, 2–5).
  Future<void> setTabs(List<GestureDockTab> tabs) =>
      _update((s) => s.copyWith(tabs: GestureDockTab.normalize(tabs)));

  /// Edit mode's "Restablecer".
  Future<void> resetTabs() => setTabs(GestureDockTab.defaultLayout);

  // ---- hide / show -----------------------------------------------------

  /// Hides the dock by hand, or shows it again (its handle, "Usar dock
  /// flotante" turned back on).
  void setHidden(bool hide) {
    if (_hidden.value != hide) _hidden.value = hide;
  }

  @visibleForTesting
  void resetForTesting({GestureDockSettings? settings, bool loaded = true}) {
    _settings.value = settings ?? const GestureDockSettings();
    _hidden.value = false;
    light.reset();
    _activeDocks.clear();
    _loaded = loaded;
    _loading = loaded ? Future<void>.value() : null;
  }
}
