import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';

/// The guided tours Ajustes › Recorrido guiado lists. Each one points at
/// the real widgets of its screen ([GuideLayer]).
enum GuideTourId { general, chat, bots }

typedef GuideText = String Function(Strings s);

/// One step of a tour: what it points at and what it says.
///
/// [targets] are `ValueKey<String>` values of the real widget, in order of
/// preference. `prefix*` matches any key that starts with `prefix`,
/// `*suffix` any key that ends with `suffix`. A step whose targets are not
/// on screen is skipped: a tour never points at nothing.
@immutable
class GuideStep {
  final String id;
  final List<String> targets;
  final GuideText title;
  final GuideText body;

  const GuideStep({
    required this.id,
    required this.targets,
    required this.title,
    required this.body,
  });

  /// Whether [key] is one of this step's targets.
  bool matches(Key? key) {
    if (key is! ValueKey<String>) return false;
    final value = key.value;
    for (final spec in targets) {
      if (guideKeyMatches(spec, value)) return true;
    }
    return false;
  }
}

bool guideKeyMatches(String spec, String value) {
  if (spec.endsWith('*')) {
    return value.startsWith(spec.substring(0, spec.length - 1));
  }
  if (spec.startsWith('*')) return value.endsWith(spec.substring(1));
  return value == spec;
}

/// The dock in any of its forms: the gesture dock, its tablet rail or the
/// classic dock (gesture dock flag off).
const _dockTargets = ['gesture-dock', 'gesture-dock-rail', '*-floating-dock'];

/// The steps of [tour], in order.
List<GuideStep> guideStepsFor(GuideTourId tour) => switch (tour) {
  GuideTourId.general => [
    GuideStep(
      id: 'home-board',
      targets: const ['home-widget-*'],
      title: (s) => s.gt1215HomeBoardTitle,
      body: (s) => s.gt1215HomeBoardBody,
    ),
    GuideStep(
      id: 'home-server',
      targets: const ['home-header-title'],
      title: (s) => s.gt1215HomeServerTitle,
      body: (s) => s.gt1215HomeServerBody,
    ),
    GuideStep(
      id: 'home-profile',
      targets: const ['profile-switcher'],
      title: (s) => s.gt1215HomeProfileTitle,
      body: (s) => s.gt1215HomeProfileBody,
    ),
    GuideStep(
      id: 'home-dock',
      targets: _dockTargets,
      title: (s) => s.gt1215HomeDockTitle,
      body: (s) => s.gt1215HomeDockBody,
    ),
  ],
  GuideTourId.chat => [
    GuideStep(
      id: 'chat-header',
      targets: const ['chat-activity-pill', 'chat-header', 'bot-chat-header'],
      title: (s) => s.gt1215ChatHeaderTitle,
      body: (s) => s.gt1215ChatHeaderBody,
    ),
    GuideStep(
      id: 'chat-composer',
      targets: const ['chat-composer-host'],
      title: (s) => s.gt1215ChatComposerTitle,
      body: (s) => s.gt1215ChatComposerBody,
    ),
    GuideStep(
      id: 'chat-notch',
      targets: const ['chat-notch'],
      title: (s) => s.gt1215ChatNotchTitle,
      body: (s) => s.gt1215ChatNotchBody,
    ),
    GuideStep(
      id: 'chat-status',
      targets: const ['chat-status-pill', 'status-pill-capsule'],
      title: (s) => s.gt1215ChatStatusTitle,
      body: (s) => s.gt1215ChatStatusBody,
    ),
  ],
  GuideTourId.bots => [
    GuideStep(
      id: 'bots-pinned',
      targets: const ['dots-row-pinned'],
      title: (s) => s.gt1215BotsPinnedTitle,
      body: (s) => s.gt1215BotsPinnedBody,
    ),
    GuideStep(
      id: 'bots-team',
      targets: const ['dots-tile-*'],
      title: (s) => s.gt1215BotsTeamTitle,
      body: (s) => s.gt1215BotsTeamBody,
    ),
    GuideStep(
      id: 'bots-rooms',
      targets: const ['roster-room-row-*'],
      title: (s) => s.gt1215BotsRoomsTitle,
      body: (s) => s.gt1215BotsRoomsBody,
    ),
    GuideStep(
      id: 'bots-create',
      targets: const ['mission-create-agent'],
      title: (s) => s.gt1215BotsCreateTitle,
      body: (s) => s.gt1215BotsCreateBody,
    ),
    GuideStep(
      id: 'bots-dock',
      targets: _dockTargets,
      title: (s) => s.gt1215BotsDockTitle,
      body: (s) => s.gt1215BotsDockBody,
    ),
  ],
};

/// Finds the widget a step points at, or null when it is not on screen.
/// Installed by the visible [GuideLayer].
typedef GuideTargetProbe = bool Function(GuideStep step);

/// The one engine behind every guided tour: which tour runs and on which
/// step, what is already done, and the rules every tour follows (one at a
/// time, steps without a target are skipped, nothing shows over App Lock,
/// nothing stays on screen after it ends).
class GuideController extends ChangeNotifier {
  GuideController();

  static final GuideController instance = GuideController();

  static const storageKey = 'guided_tours_v1';
  static const schemaVersion = 1;

  /// A tour asked for on a screen that is still opening waits this long
  /// for its first target, then gives up quietly.
  static const startWindow = Duration(seconds: 8);

  /// A step whose target left the screen (a sheet over it, the route
  /// popped) waits this long before the tour moves on or ends.
  static const lostGrace = Duration(milliseconds: 1500);

  GuideTourId? _tour;
  int? _step;
  Set<GuideTourId> _done = {};
  bool _paused = false;
  Timer? _startTimer;
  Timer? _lostTimer;
  Future<void>? _loading;

  /// The probe of the visible layer; null while no layer is mounted.
  GuideTargetProbe? probe;

  /// The tour that runs (or waits for its screen), if any.
  GuideTourId? get tour => _tour;

  /// The step on screen; null while the tour waits for its screen.
  int? get step => _step;

  bool get active => _tour != null;

  List<GuideStep> _steps = const [];

  /// The steps of the running tour (all of them, on screen or not).
  List<GuideStep> get steps => _steps;

  GuideStep? get currentStep {
    final i = _step;
    return i == null ? null : steps[i];
  }

  /// Tours finished to the end.
  bool isDone(GuideTourId tour) => _done.contains(tour);

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null) return;
      final json = jsonDecode(raw);
      if (json is! Map || json['schema_version'] != schemaVersion) return;
      final done = json['done'];
      if (done is List) {
        _done = {
          for (final name in done)
            ...GuideTourId.values.where((t) => t.name == name),
        };
        notifyListeners();
      }
    } catch (_) {
      // A corrupt value: nothing is done yet.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        storageKey,
        jsonEncode({
          'schema_version': schemaVersion,
          'done': [for (final t in _done) t.name],
        }),
      );
    } catch (_) {
      // The in-memory value stays; the next finish retries the write.
    }
  }

  /// Starts [tour] (Ajustes › Recorrido guiado). Any
  /// other tour ends first and the keyboard closes. General, Chat and
  /// Bots start on their first step that is on screen; until the screen
  /// shows one (it may still be opening) nothing is drawn.
  void start(GuideTourId tour) {
    unawaited(ensureLoaded());
    FocusManager.instance.primaryFocus?.unfocus();
    _clear();
    _tour = tour;
    _steps = guideStepsFor(tour);
    _step = null;
    _armStartTimer();
    notifyListeners();
  }

  void _armStartTimer() {
    _startTimer?.cancel();
    _startTimer = Timer(startWindow, () {
      _startTimer = null;
      if (_tour == null || _step != null) return;
      if (_paused) {
        _armStartTimer();
        return;
      }
      _clear();
      notifyListeners();
    });
  }

  bool _available(int index) => probe?.call(steps[index]) ?? false;

  /// The layer found the screen: shows the first step on it.
  void showFirstAvailable() {
    if (_tour == null || _step != null) return;
    for (var i = 0; i < steps.length; i++) {
      if (_available(i)) {
        _startTimer?.cancel();
        _startTimer = null;
        _step = i;
        notifyListeners();
        return;
      }
    }
  }

  /// "Siguiente": the next step on screen; after the last one the tour is
  /// done.
  void next() {
    final at = _step;
    if (at == null) return;
    _lostTimer?.cancel();
    _lostTimer = null;
    for (var i = at + 1; i < steps.length; i++) {
      if (_available(i)) {
        _step = i;
        notifyListeners();
        return;
      }
    }
    finish();
  }

  /// "Atrás": the previous step on screen, if there is one.
  void back() {
    final at = _step;
    if (at == null) return;
    for (var i = at - 1; i >= 0; i--) {
      if (_available(i)) {
        _lostTimer?.cancel();
        _lostTimer = null;
        _step = i;
        notifyListeners();
        return;
      }
    }
  }

  /// Whether a step before the current one is on screen ("Atrás").
  bool get canGoBack {
    final at = _step;
    if (at == null) return false;
    for (var i = at - 1; i >= 0; i--) {
      if (_available(i)) return true;
    }
    return false;
  }

  /// Whether the current step is the last one on screen ("Terminar").
  bool get isLastStep {
    final at = _step;
    if (at == null) return false;
    for (var i = at + 1; i < steps.length; i++) {
      if (_available(i)) return false;
    }
    return true;
  }

  /// The tour went to its end: it is marked done.
  void finish() {
    final tour = _tour;
    if (tour == null) return;
    _clear();
    if (_done.add(tour)) unawaited(_save());
    notifyListeners();
  }

  /// "Saltar" (or the screen went away): ends without marking it done.
  void skip() {
    if (_tour == null) return;
    _clear();
    notifyListeners();
  }

  /// App Lock is up (or the layer cannot see its screen): timers wait.
  void setPaused(bool paused) => _paused = paused;

  /// The current step's target is gone. After [lostGrace] the tour moves
  /// on to a step still on screen, or ends when none is (route popped).
  void targetLost() {
    if (_step == null || _lostTimer != null) return;
    _lostTimer = Timer(lostGrace, () {
      _lostTimer = null;
      final at = _step;
      if (at == null) return;
      if (_paused) {
        targetLost();
        return;
      }
      if (_available(at)) return;
      final anyLeft = [
        for (var i = 0; i < steps.length; i++) i,
      ].any(_available);
      if (anyLeft) {
        next();
      } else {
        skip();
      }
    });
  }

  /// The target is back before [lostGrace] ran out.
  void targetFound() {
    _lostTimer?.cancel();
    _lostTimer = null;
  }

  void _clear() {
    _startTimer?.cancel();
    _lostTimer?.cancel();
    _startTimer = _lostTimer = null;
    _tour = null;
    _steps = const [];
    _step = null;
  }

  @visibleForTesting
  void resetForTesting() {
    _clear();
    _done = {};
    _paused = false;
    _loading = null;
    probe = null;
  }
}
