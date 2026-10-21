// The first voice start of a chat, with less of its wait.
//
// Opening this phone's recognition model takes seconds. It is loaded the
// moment a finger lands on the dictation or voice button, not when a chat
// opens or the app resumes: opening a chat costs nothing, and the gesture's
// own 100-300 ms already go to the model. Only for somebody who talks to
// this phone: it costs memory and battery.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/flavor.dart';
import '../../../widgets/frosted_backdrop.dart';
import '../../connection_manager.dart';
import '../live/voice_chat_mode_store.dart';
import '../voice_service.dart';
import 'native_voice.dart';

/// Has this phone's recogniser loaded when the microphone is first touched.
///
/// The chat attaches it once its first frame is out and detaches it when it
/// goes away. Attaching, and the app coming back to the chat, load nothing:
/// only [armOnMicPressDown] does, and only if all of this holds:
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
/// by the last chat going away: the three paths of the lifecycle are kept.
class ChatRecognizerPrewarm with WidgetsBindingObserver {
  ChatRecognizerPrewarm._(
    this._voice,
    this._preferences,
    this._connection,
    this._profile,
    this._deviceConstrained,
    this._dashboardIdentity,
  );

  final VoiceService _voice;
  final SharedPreferences _preferences;
  final SavedConnection _connection;
  final Future<String> Function() _profile;
  final Future<bool> Function() _deviceConstrained;
  final String Function(SavedConnection connection) _dashboardIdentity;

  bool _detached = false;
  int _epoch = 0;

  /// Call once the chat's first frame is out. [profile] resolves the Hermes
  /// profile the chat talks to. [deviceConstrained] and [dashboardIdentity]
  /// replace the platform probe and the Dashboard client in tests.
  static ChatRecognizerPrewarm attach({
    required VoiceService voice,
    required SharedPreferences preferences,
    required SavedConnection connection,
    required Future<String> Function() profile,
    Future<bool> Function()? deviceConstrained,
    String Function(SavedConnection connection)? dashboardIdentity,
  }) {
    final prewarm = ChatRecognizerPrewarm._(
      voice,
      preferences,
      connection,
      profile,
      deviceConstrained ?? _platformSaysConstrained,
      dashboardIdentity ?? _dashboardIdentityOf,
    );
    WidgetsBinding.instance.addObserver(prewarm);
    voice.chatShown();
    return prewarm;
  }

  /// Call the moment a finger lands on the dictation or voice button (the
  /// pointer-down, not the whole tap) and when a local voice conversation
  /// starts. Loads the recogniser behind the gesture; a second call while it
  /// loads or once it is loaded does not load another.
  void armOnMicPressDown() {
    if (!kVoiceRuntimeEnabled || _detached || _blocked()) return;
    unawaited(_consider());
  }

  /// Call when the chat goes away.
  void detach() {
    if (_detached) return;
    _detached = true;
    _epoch++;
    WidgetsBinding.instance.removeObserver(this);
    _voice.chatLeft();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed || AppLifecycleState.inactive:
        // Back on screen, or a system dialog or the notification shade over
        // it: nothing is loaded until the microphone is touched.
        break;
      case AppLifecycleState.hidden ||
          AppLifecycleState.paused ||
          AppLifecycleState.detached:
        // Nobody can press the voice button from here: a load that was
        // being decided is dropped and one that is only waiting is released.
        _epoch++;
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
