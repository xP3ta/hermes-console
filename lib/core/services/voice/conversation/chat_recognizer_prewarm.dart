// The first voice start of a chat, without its wait.
//
// Opening this phone's recognition model takes seconds, and the first
// "Voz" tap of a chat used to wait for all of them. While a chat is on
// screen the model is loaded ahead, in the background — for somebody who
// talks to this phone, and for nobody else: it costs memory and battery, so
// who never uses voice must not pay anything for it.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/flavor.dart';
import '../../../widgets/frosted_backdrop.dart';
import '../../connection_manager.dart';
import '../live/voice_chat_mode_store.dart';
import '../voice_service.dart';
import 'native_voice.dart';

/// Has this phone's recogniser loaded while a chat is on screen.
///
/// The chat attaches it once its first frame is out and detaches it when it
/// goes away; nothing here runs before that frame or holds it back, and the
/// load itself waits [settleTime] more so the chat's entrance and its
/// transcript are painted first. The recogniser is loaded then, and again
/// whenever the app comes back to the chat, only if all of this holds:
///
/// - a voice conversation or a dictation ran on this phone's recogniser in
///   the last [VoiceService.recentVoiceUseDays] days;
/// - no memory pressure was reported during this run of the app, and nothing
///   is using or holding a voice model;
/// - the chat's voice conversation runs on this phone: not on the Hermes
///   server and not as GPT-Live;
/// - the device is not a low-RAM one and battery saver is off.
///
/// The microphone is never opened. What is loaded is released by the rules
/// of [VoiceService.loadRecognizerAhead], by the app leaving the screen and
/// by the last chat going away.
class ChatRecognizerPrewarm with WidgetsBindingObserver {
  ChatRecognizerPrewarm._(
    this._voice,
    this._preferences,
    this._connection,
    this._profile,
    this._deviceConstrained,
    this._dashboardIdentity,
    this._settle,
  );

  /// The chat's entrance (its route animation, the first frames of the
  /// transcript) is left alone: nothing is decided or loaded during it.
  static const Duration settleTime = Duration(milliseconds: 600);

  final VoiceService _voice;
  final SharedPreferences _preferences;
  final SavedConnection _connection;
  final Future<String> Function() _profile;
  final Future<bool> Function() _deviceConstrained;
  final String Function(SavedConnection connection) _dashboardIdentity;
  final Duration _settle;

  bool _detached = false;
  int _epoch = 0;
  Timer? _settling;

  /// Call once the chat's first frame is out. [profile] resolves the Hermes
  /// profile the chat talks to. [deviceConstrained], [dashboardIdentity] and
  /// [settle] replace the platform probe, the Dashboard client and
  /// [settleTime] in tests.
  static ChatRecognizerPrewarm attach({
    required VoiceService voice,
    required SharedPreferences preferences,
    required SavedConnection connection,
    required Future<String> Function() profile,
    Future<bool> Function()? deviceConstrained,
    String Function(SavedConnection connection)? dashboardIdentity,
    Duration settle = settleTime,
  }) {
    final prewarm = ChatRecognizerPrewarm._(
      voice,
      preferences,
      connection,
      profile,
      deviceConstrained ?? _platformSaysConstrained,
      dashboardIdentity ?? _dashboardIdentityOf,
      settle,
    );
    WidgetsBinding.instance.addObserver(prewarm);
    voice.chatShown();
    prewarm._considerSoon();
    return prewarm;
  }

  /// Call when the chat goes away.
  void detach() {
    if (_detached) return;
    _detached = true;
    _epoch++;
    _settling?.cancel();
    _settling = null;
    WidgetsBinding.instance.removeObserver(this);
    _voice.chatLeft();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _considerSoon();
      case AppLifecycleState.inactive:
        // A system dialog or the notification shade: still on screen.
        break;
      case AppLifecycleState.hidden ||
          AppLifecycleState.paused ||
          AppLifecycleState.detached:
        // Nobody can press the voice button from here: a load that was
        // being decided is dropped and one that is only waiting is released.
        _epoch++;
        _settling?.cancel();
        _settling = null;
        unawaited(_voice.releaseWaitingRecognizer(reason: 'app_hidden'));
    }
  }

  /// Low-RAM device or battery saver, from the probe the frosted surfaces
  /// already use, read again because either may have changed while away.
  static Future<bool> _platformSaysConstrained() async {
    await FrostedBackdropPolicy.refresh();
    return FrostedBackdropPolicy.reducedPerformance.value;
  }

  static String _dashboardIdentityOf(SavedConnection connection) {
    final dashboard = DashboardClient.lazy(connection);
    try {
      return dashboard.baseUrl;
    } finally {
      dashboard.close();
    }
  }

  bool _onThisPhone(String profile) {
    final identity = nativeVoicePreferenceIdentity(
      _dashboardIdentity(_connection),
      profile: profile,
    );
    if (NativeVoiceModeStore(_preferences).read(identity) ==
        NativeVoiceMode.server) {
      return false;
    }
    final live = VoiceChatModeStore(
      _preferences,
    ).read(VoiceChatModeStore.identity(_connection.id, profile));
    return live?.startsLive != true;
  }

  /// Whether anything this needs no platform call for stands in the way.
  /// The cheapest question comes first: somebody who does not talk to this
  /// phone stops at one preference read, without a line in the log.
  bool _blocked() {
    final blocker = _voice.recognizerAheadBlocker;
    if (blocker == null) return false;
    if (blocker != 'no_recent_use') _skipped(blocker);
    return true;
  }

  void _considerSoon() {
    _settling?.cancel();
    _settling = null;
    if (!kVoiceRuntimeEnabled || _detached || _blocked()) return;
    _settling = Timer(_settle, () {
      _settling = null;
      unawaited(_consider());
    });
  }

  Future<void> _consider() async {
    if (_detached) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null &&
        lifecycle != AppLifecycleState.resumed &&
        lifecycle != AppLifecycleState.inactive) {
      return;
    }
    final epoch = ++_epoch;
    bool current() => !_detached && epoch == _epoch;
    if (_blocked()) return;
    try {
      final profile = await _profile();
      if (!current()) return;
      if (!_onThisPhone(profile)) {
        _skipped('route');
        return;
      }
      if (await _deviceConstrained()) {
        _skipped('constrained_device');
        return;
      }
      if (!current()) return;
      await _voice.loadRecognizerAhead(stillWanted: current);
    } catch (error) {
      _skipped('error_${error.runtimeType}');
    }
  }

  void _skipped(String reason) =>
      debugPrint('[VOICE-PERF] voice.recognizer.ahead=skip reason=$reason');
}
