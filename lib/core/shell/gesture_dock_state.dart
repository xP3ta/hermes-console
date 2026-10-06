import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// When the floating dock hides (Ajustes › Dock).
enum DockHideMode {
  /// Never hides.
  fixed,

  /// Hides only when the user swipes it down. The default.
  manual,

  /// Also hides while a list scrolls down and comes back on the way up.
  auto;

  static DockHideMode parse(Object? value) => values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => DockHideMode.manual,
  );
}

/// The gestures the coach teaches and Ajustes › Trucos y gestos lists.
enum DockGesture {
  swipe,
  hide,
  show,
  up,
  hold,

  /// The handle above a chat composer. The chat owns it; it reports here
  /// with [GestureDockController.learn] so the list stays complete.
  chatHandle;

  static DockGesture? parse(Object? value) => values
      .cast<DockGesture?>()
      .firstWhere((g) => g?.name == value, orElse: () => null);
}

/// The four places of the dock. Swipes step through [swipeOrder]; "Nuevo"
/// opens a chat and is not a place you can stand on.
enum GestureDockTab {
  home,
  create,
  projects,
  settings;

  static const swipeOrder = [
    GestureDockTab.home,
    GestureDockTab.projects,
    GestureDockTab.settings,
  ];
}

/// Everything the gesture dock keeps per device.
@immutable
class GestureDockSettings {
  static const schemaVersion = 1;

  final DockHideMode mode;
  final bool gestures;

  /// Opaque surface instead of the blurred glass (cheaper to draw).
  final bool opaque;

  /// One-a-day tips about gestures not learned yet.
  final bool tips;
  final bool welcomeSeen;
  final bool tourDone;
  final Set<DockGesture> learned;

  /// Taps on the dock: they unlock the tips.
  final int taps;

  /// Local day (days since the epoch) the last tip was shown.
  final int? lastTipDay;
  final Map<DockGesture, int> skips;
  final bool hideHintShown;

  const GestureDockSettings({
    this.mode = DockHideMode.manual,
    this.gestures = true,
    this.opaque = false,
    this.tips = true,
    this.welcomeSeen = false,
    this.tourDone = false,
    this.learned = const {},
    this.taps = 0,
    this.lastTipDay,
    this.skips = const {},
    this.hideHintShown = false,
  });

  GestureDockSettings copyWith({
    DockHideMode? mode,
    bool? gestures,
    bool? opaque,
    bool? tips,
    bool? welcomeSeen,
    bool? tourDone,
    Set<DockGesture>? learned,
    int? taps,
    int? lastTipDay,
    Map<DockGesture, int>? skips,
    bool? hideHintShown,
  }) => GestureDockSettings(
    mode: mode ?? this.mode,
    gestures: gestures ?? this.gestures,
    opaque: opaque ?? this.opaque,
    tips: tips ?? this.tips,
    welcomeSeen: welcomeSeen ?? this.welcomeSeen,
    tourDone: tourDone ?? this.tourDone,
    learned: learned ?? this.learned,
    taps: taps ?? this.taps,
    lastTipDay: lastTipDay ?? this.lastTipDay,
    skips: skips ?? this.skips,
    hideHintShown: hideHintShown ?? this.hideHintShown,
  );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'mode': mode.name,
    'gestures': gestures,
    'opaque': opaque,
    'tips': tips,
    'welcome_seen': welcomeSeen,
    'tour_done': tourDone,
    'learned': [for (final g in learned) g.name],
    'taps': taps,
    'last_tip_day': lastTipDay,
    'skips': {for (final e in skips.entries) e.key.name: e.value},
    'hide_hint_shown': hideHintShown,
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

    final learned = <DockGesture>{};
    final rawLearned = raw['learned'];
    if (rawLearned is List) {
      for (final entry in rawLearned) {
        final gesture = DockGesture.parse(entry);
        if (gesture != null) learned.add(gesture);
      }
    }
    final skips = <DockGesture, int>{};
    final rawSkips = raw['skips'];
    if (rawSkips is Map) {
      for (final entry in rawSkips.entries) {
        final gesture = DockGesture.parse(entry.key);
        final count = entry.value;
        if (gesture != null && count is int && count > 0) {
          skips[gesture] = count;
        }
      }
    }
    final taps = raw['taps'];
    final lastTipDay = raw['last_tip_day'];
    return GestureDockSettings(
      mode: DockHideMode.parse(raw['mode']),
      gestures: flag('gestures', true),
      opaque: flag('opaque', false),
      tips: flag('tips', true),
      welcomeSeen: flag('welcome_seen', false),
      tourDone: flag('tour_done', false),
      learned: learned,
      taps: taps is int && taps >= 0 ? taps : 0,
      lastTipDay: lastTipDay is int ? lastTipDay : null,
      skips: skips,
      hideHintShown: flag('hide_hint_shown', false),
    );
  }
}

/// One tip and the condition that unlocks it (owner guide § 4.3; the
/// thresholds were set by eye and are meant to be tuned with real use).
@immutable
class DockTip {
  final DockGesture gesture;
  final bool Function(GestureDockSettings s) unlocked;

  const DockTip(this.gesture, this.unlocked);
}

final List<DockTip> dockTips = [
  DockTip(
    DockGesture.swipe,
    (s) => s.taps >= 6 && !s.learned.contains(DockGesture.swipe),
  ),
  DockTip(
    DockGesture.hide,
    (s) =>
        s.mode != DockHideMode.fixed &&
        s.taps >= 9 &&
        !s.learned.contains(DockGesture.hide),
  ),
  DockTip(
    DockGesture.up,
    (s) =>
        s.learned.contains(DockGesture.swipe) &&
        s.taps >= 12 &&
        !s.learned.contains(DockGesture.up),
  ),
  DockTip(
    DockGesture.hold,
    (s) =>
        s.learned.contains(DockGesture.up) &&
        s.taps >= 15 &&
        !s.learned.contains(DockGesture.hold),
  ),
];

/// The three steps of the guided tour, in order.
const List<DockGesture> dockTourSteps = [
  DockGesture.swipe,
  DockGesture.hide,
  DockGesture.show,
];

/// Shared state of the gesture dock. Every route mounts its own dock, but
/// they all read this one controller, so the dock stays hidden, the tour
/// stays on its step and a tip stays up while the user moves between tabs.
class GestureDockController {
  GestureDockController();

  static final GestureDockController instance = GestureDockController();

  static const storageKey = 'gesture_dock_v1';
  static const welcomeDelay = Duration(milliseconds: 1800);
  static const tourCelebration = Duration(milliseconds: 800);
  static const practiceTimeout = Duration(seconds: 14);
  static const hintDuration = Duration(seconds: 4);

  /// Local clock; tests replace it.
  DateTime Function() now = DateTime.now;

  final ValueNotifier<GestureDockSettings> _settings =
      ValueNotifier<GestureDockSettings>(const GestureDockSettings());
  final ValueNotifier<bool> _hidden = ValueNotifier<bool>(false);
  final ValueNotifier<int?> _tourStep = ValueNotifier<int?>(null);
  final ValueNotifier<bool> _tourCelebrating = ValueNotifier<bool>(false);
  final ValueNotifier<DockGesture?> _tip = ValueNotifier<DockGesture?>(null);
  final ValueNotifier<bool> _welcome = ValueNotifier<bool>(false);
  final ValueNotifier<DockGesture?> _practice = ValueNotifier<DockGesture?>(
    null,
  );
  final ValueNotifier<bool> _hint = ValueNotifier<bool>(false);

  ValueListenable<GestureDockSettings> get settings => _settings;
  ValueListenable<bool> get hidden => _hidden;
  ValueListenable<int?> get tourStep => _tourStep;
  ValueListenable<bool> get tourCelebrating => _tourCelebrating;
  ValueListenable<DockGesture?> get tip => _tip;
  ValueListenable<bool> get welcome => _welcome;
  ValueListenable<DockGesture?> get practice => _practice;
  ValueListenable<bool> get hint => _hint;

  GestureDockSettings get value => _settings.value;

  /// The "Ir a" sheet or a shortcuts popover is open: no tip over it.
  bool sheetOpen = false;

  /// A dock gesture is in progress.
  bool dragging = false;

  /// Whether something needs the user (a pending permission). Set by the
  /// visible dock from the app's attention source.
  bool Function() needsYou = _never;
  static bool _never() => false;

  /// Hook for the floating mascot: when set and it returns true, the
  /// mascot shows the welcome in its own bubble and later calls
  /// [answerWelcome]; otherwise the dock shows its own card.
  static bool Function(GestureDockController controller)? welcomePresenter;

  final Map<Object, VoidCallback?> _activeDocks = {};
  bool get hasActiveDock => _activeDocks.isNotEmpty;

  bool _loaded = false;
  bool get loaded => _loaded;
  Future<void>? _loading;
  Timer? _welcomeTimer;
  Timer? _tourTimer;
  Timer? _practiceTimer;
  Timer? _hintTimer;
  double _scrollAccumulator = 0;

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
      if (hasActiveDock) _scheduleWelcome();
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

  /// A dock on the visible route. The first one schedules the welcome.
  /// [republish] is called when another dock leaves (end of a route
  /// transition), so the one still on screen publishes its geometry again.
  void attach(Object dock, [VoidCallback? republish]) {
    final first = _activeDocks.isEmpty;
    _activeDocks[dock] = republish;
    if (first) _scheduleWelcome();
  }

  void detach(Object dock) {
    _activeDocks.remove(dock);
    if (_activeDocks.isEmpty) {
      _welcomeTimer?.cancel();
      _welcomeTimer = null;
      return;
    }
    for (final republish in _activeDocks.values.toList()) {
      republish?.call();
    }
  }

  // ---- settings --------------------------------------------------------

  Future<void> setMode(DockHideMode mode) async {
    await _update((s) => s.copyWith(mode: mode));
    if (mode == DockHideMode.fixed) setHidden(false);
    _scrollAccumulator = 0;
  }

  Future<void> setGestures(bool enabled) =>
      _update((s) => s.copyWith(gestures: enabled));

  Future<void> setOpaque(bool opaque) =>
      _update((s) => s.copyWith(opaque: opaque));

  Future<void> setTips(bool enabled) =>
      _update((s) => s.copyWith(tips: enabled));

  // ---- hide / show -----------------------------------------------------

  void setHidden(bool hide) {
    if (value.mode == DockHideMode.fixed) hide = false;
    if (_hidden.value == hide) return;
    _hidden.value = hide;
    if (hide &&
        !value.hideHintShown &&
        _tourStep.value == null &&
        !value.tourDone) {
      _hint.value = true;
      unawaited(_update((s) => s.copyWith(hideHintShown: true)));
      _hintTimer?.cancel();
      _hintTimer = Timer(hintDuration, () => _hint.value = false);
    } else if (!hide && _hint.value) {
      _hintTimer?.cancel();
      _hint.value = false;
    }
  }

  /// Auto mode: one vertical scroll update of the visible list.
  /// [delta] > 0 scrolls down (content moves up).
  void handleScroll({
    required double delta,
    required double pixels,
    required double minExtent,
  }) {
    if (value.mode != DockHideMode.auto || !hasActiveDock) return;
    if (pixels - minExtent < 24) {
      _scrollAccumulator = 0;
      setHidden(false);
      return;
    }
    if (delta == 0) return;
    if (_scrollAccumulator != 0 && _scrollAccumulator.sign != delta.sign) {
      _scrollAccumulator = 0;
    }
    _scrollAccumulator += delta;
    if (_scrollAccumulator > 28) {
      _scrollAccumulator = 0;
      setHidden(true);
    } else if (_scrollAccumulator < -14) {
      _scrollAccumulator = 0;
      setHidden(false);
    }
  }

  // ---- learning --------------------------------------------------------

  /// The user did [gesture] for real.
  void learn(DockGesture gesture) {
    if (!value.learned.contains(gesture)) {
      unawaited(_update((s) => s.copyWith(learned: {...s.learned, gesture})));
    }
    if (_practice.value == gesture) {
      _practiceTimer?.cancel();
      _practice.value = null;
    }
    if (_tip.value == gesture) _tip.value = null;
    final step = _tourStep.value;
    if (step != null &&
        !_tourCelebrating.value &&
        dockTourSteps[step] == gesture) {
      _tourCelebrating.value = true;
      _tourTimer?.cancel();
      _tourTimer = Timer(tourCelebration, () {
        _tourCelebrating.value = false;
        final next = step + 1;
        if (next >= dockTourSteps.length) {
          _endTour(done: true);
        } else {
          _tourStep.value = next;
        }
      });
    }
  }

  /// A plain tap on a dock tab: counts towards unlocking tips.
  void recordTap() {
    unawaited(_update((s) => s.copyWith(taps: s.taps + 1)));
    maybeShowTip();
  }

  // ---- welcome and tour ------------------------------------------------

  void _scheduleWelcome() {
    if (!_loaded || value.welcomeSeen || _welcome.value) return;
    if (_tourStep.value != null || _welcomeTimer != null) return;
    _welcomeTimer = Timer(welcomeDelay, () {
      _welcomeTimer = null;
      if (!hasActiveDock || value.welcomeSeen || _tourStep.value != null) {
        return;
      }
      if (needsYou() || sheetOpen) return;
      final presenter = welcomePresenter;
      if (presenter != null && presenter(this)) return;
      _welcome.value = true;
    });
  }

  /// "Enséñame" ([teach] true) or "Luego".
  void answerWelcome({required bool teach}) {
    _welcome.value = false;
    unawaited(_update((s) => s.copyWith(welcomeSeen: true)));
    if (teach) startTour();
  }

  void startTour() {
    _welcome.value = false;
    _tip.value = null;
    _practice.value = null;
    if (value.mode == DockHideMode.fixed || !value.gestures) {
      unawaited(
        _update((s) => s.copyWith(mode: DockHideMode.manual, gestures: true)),
      );
    }
    setHidden(false);
    _tourCelebrating.value = false;
    _tourStep.value = 0;
  }

  void skipTour() => _endTour(done: false);

  void _endTour({required bool done}) {
    _tourTimer?.cancel();
    _tourCelebrating.value = false;
    _tourStep.value = null;
    unawaited(
      _update(
        (s) => s.copyWith(welcomeSeen: true, tourDone: done || s.tourDone),
      ),
    );
  }

  // ---- tips ------------------------------------------------------------

  int get today {
    final local = now();
    return DateTime.utc(
          local.year,
          local.month,
          local.day,
        ).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
  }

  /// Shows at most one tip per day, and never over a pending permission,
  /// an open sheet, the tour, the welcome or a gesture in progress.
  void maybeShowTip() {
    final s = value;
    if (!s.tips || !s.welcomeSeen || !s.gestures) return;
    if (_tourStep.value != null || _welcome.value || _tip.value != null) {
      return;
    }
    if (s.lastTipDay == today) return;
    if (needsYou() || sheetOpen || dragging) return;
    for (final candidate in dockTips) {
      if ((s.skips[candidate.gesture] ?? 0) >= 2) continue;
      if (!candidate.unlocked(s)) continue;
      _tip.value = candidate.gesture;
      unawaited(_update((x) => x.copyWith(lastTipDay: today)));
      return;
    }
  }

  /// "Ahora no": twice and that tip never comes back.
  void tipNotNow() {
    final gesture = _tip.value;
    if (gesture == null) return;
    _tip.value = null;
    unawaited(
      _update(
        (s) => s.copyWith(
          skips: {...s.skips, gesture: (s.skips[gesture] ?? 0) + 1},
        ),
      ),
    );
  }

  /// "Ya lo sé".
  void tipKnown() {
    final gesture = _tip.value;
    if (gesture == null) return;
    learn(gesture);
  }

  /// "Probarlo" (and "Probar" in Ajustes › Trucos y gestos): shows the
  /// finger on the dock until the gesture is done or 14 s pass.
  void tryGesture(DockGesture gesture) {
    _tip.value = null;
    if (gesture == DockGesture.show) {
      if (value.mode == DockHideMode.fixed) {
        unawaited(_update((s) => s.copyWith(mode: DockHideMode.manual)));
      }
      _hidden.value = true;
    } else if (gesture != DockGesture.chatHandle) {
      setHidden(false);
    }
    _practice.value = gesture;
    _practiceTimer?.cancel();
    _practiceTimer = Timer(practiceTimeout, () => _practice.value = null);
  }

  @visibleForTesting
  void resetForTesting({GestureDockSettings? settings, bool loaded = true}) {
    for (final timer in [
      _welcomeTimer,
      _tourTimer,
      _practiceTimer,
      _hintTimer,
    ]) {
      timer?.cancel();
    }
    _welcomeTimer = _tourTimer = _practiceTimer = _hintTimer = null;
    _settings.value = settings ?? const GestureDockSettings();
    _hidden.value = false;
    _tourStep.value = null;
    _tourCelebrating.value = false;
    _tip.value = null;
    _welcome.value = false;
    _practice.value = null;
    _hint.value = false;
    _activeDocks.clear();
    sheetOpen = false;
    dragging = false;
    needsYou = _never;
    welcomePresenter = null;
    now = DateTime.now;
    _scrollAccumulator = 0;
    _loaded = loaded;
    _loading = loaded ? Future<void>.value() : null;
  }
}
