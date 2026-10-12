import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import '../../../../l10n/app_localizations.dart';
import '../../active_chat_service.dart';
import '../live/voice_chat_mode_store.dart';
import '../live/voice_live_api.dart';
import '../live/voice_live_protocol.dart' show VoiceLiveMode;
import '../voice_phase.dart';
import '../voice_service.dart' show SttCheck;
import 'gpt_live_voice_conversation_controller.dart';
import 'voice_conversation_engine.dart';

/// Where the active Hermes profile of a chat's connection can be read and
/// observed.
typedef VoiceProfileWatch = ({Listenable changes, String Function() current});

/// The single voice conversation the app and the chat screen talk to.
///
/// It picks the engine once per entry, following the server like Desktop
/// does: GPT-Live only when the profile's `voice.voice_chat_mode` is
/// `gpt-live` and the server can start it, the chained local engine in every
/// other case (with one notice when GPT-Live was chosen but cannot start).
///
/// The choice never waits for the network when the mode of that connection
/// and profile is already known: the last answer of the status route decides
/// at once and is refreshed in the background for the next conversation.
/// Only a connection and profile never seen before pay one short probe, and
/// start the chained engine if it does not answer in time. The engine then
/// runs until [exit]; a mode change meanwhile applies to the next entry.
/// Everything else is forwarded to the engine that is running.
class VoiceConversationCoordinator extends ChangeNotifier
    implements VoiceConversationEngine {
  VoiceConversationCoordinator({
    required this._chained,
    required this._liveFactory,
    required this._modes,
    required this._apiFactory,
    required this._languageCode,
    this._visibleSession,
    this._profileWatch,
    this._appVisible,
  }) {
    _attach(_chained);
  }

  static const Duration _statusTimeout = Duration(seconds: 5);

  /// Longest wait for a connection and profile whose mode is still unknown.
  @visibleForTesting
  static const Duration unknownModeProbe = Duration(milliseconds: 1500);

  final VoiceConversationEngine _chained;
  final LiveVoiceConversationEngine Function() _liveFactory;
  final VoiceChatModeStore _modes;
  final VoiceLiveApi Function(ActiveChat chat) _apiFactory;
  final String Function() _languageCode;
  final ValueListenable<String?>? _visibleSession;
  final VoiceProfileWatch Function(ActiveChat chat)? _profileWatch;

  /// Whether the app is on screen right now (in front, or in front without
  /// focus). Without it the app always counts as visible.
  final bool Function()? _appVisible;

  final StreamController<SttCheck> _unavailable =
      StreamController<SttCheck>.broadcast();
  final List<StreamSubscription<SttCheck>> _unavailableSubs = [];
  LiveVoiceConversationEngine? _live;
  VoiceConversationEngine? _current;
  ActiveChat? _probeChat;
  String _probeProfile = '';
  bool _probing = false;
  bool _disposed = false;
  bool _privacyBlocked = false;

  /// The app is not on screen (another app on top, or the screen is off).
  /// GPT-Live never starts then; a session already open may continue.
  bool get _appHidden => !(_appVisible?.call() ?? true);

  /// Connection and profile of the last entry: the mode the next start of
  /// that conversation resolves to.
  String? _modeIdentity;

  /// The running GPT-Live session is one the user allowed to continue with
  /// the app hidden; the live engine decides (lock-screen opt-in, microphone
  /// foreground service, session already open).
  bool get _liveContinuesHidden {
    final live = _live;
    return live != null &&
        identical(_current, live) &&
        live.continuesWhileHidden;
  }

  /// Whether hiding the app must stop voice whatever the lock-screen opt-in
  /// says. GPT-Live never *starts* hidden, so this is true while its mode is
  /// being probed, when the server's mode for the conversation last entered
  /// resolves to it, and while it runs. The one exception is an open GPT-Live
  /// session the user allowed to continue ([_liveContinuesHidden]).
  bool get requiresForegroundVisibility {
    if (_liveContinuesHidden) return false;
    final identity = _modeIdentity;
    return (identity != null && (_modes.read(identity)?.startsLive ?? false)) ||
        _probing ||
        identical(_current, _live) && _live != null;
  }

  int _epoch = 0;
  String? _fallbackNotice;
  VoidCallback? _routeListener;
  VoidCallback? _profileListener;
  Listenable? _profileChanges;

  void _attach(VoiceConversationEngine engine) {
    engine.addListener(_relay);
    _unavailableSubs.add(engine.unavailable.listen(_unavailable.add));
  }

  void _relay() {
    if (!_disposed) notifyListeners();
  }

  VoiceConversationEngine get _engine => _current ?? _chained;

  // ---- entry and exit ----

  @override
  Future<void> enter({
    required ActiveChat chat,
    required String model,
    String profile = '',
    bool allowTransportFallback = false,
    Future<void> Function(String prompt)? onBeforeSend,
  }) async {
    if (_disposed || _privacyBlocked) return;
    if (_current == null && audioLeaseRequired) {
      // Explicit entry can retry failed cleanup, but never admits a sibling
      // engine or a status probe while the old physical owner is retiring.
      _live?.retry();
      return;
    }
    // The same chat and profile already being probed is one entry; another
    // profile supersedes the pending probe.
    if (_probing && identical(_probeChat, chat) && _probeProfile == profile) {
      return;
    }
    final running = _current;
    if (running != null && running.active) {
      if (running.ownsChat(chat)) return;
      await exit();
      if (_disposed || _privacyBlocked || audioLeaseRequired) return;
    }
    final epoch = ++_epoch;
    _fallbackNotice = null;
    final identity = VoiceChatModeStore.identity(chat.connection.id, profile);
    _modeIdentity = identity;
    var mode = _modes.read(identity);
    if (mode == null) {
      // Never seen: one short probe. No answer in time means the normal
      // conversation, which every server can run.
      _probing = true;
      _probeChat = chat;
      _probeProfile = profile;
      _watchLive(chat);
      notifyListeners();
      final answered = await _refreshMode(
        chat,
        profile,
        identity,
        unknownModeProbe,
      );
      if (epoch != _epoch || _disposed) return;
      _probing = false;
      _probeChat = null;
      if (answered) mode = _modes.read(identity);
    } else {
      // Known: decide now, and learn of a change for the next conversation.
      unawaited(_refreshMode(chat, profile, identity, _statusTimeout));
    }
    VoiceConversationEngine engine = _chained;
    if (mode != null && mode.mode == VoiceLiveMode.gptLive) {
      if (mode.available) {
        // The route may have been left while the status read was pending;
        // the route listener is not attached yet, so check the current value.
        // The same goes for the app itself: GPT-Live never starts hidden.
        if (_appHidden || !_chatVisible(chat)) {
          if (!_disposed) notifyListeners();
          return;
        }
        engine = _liveEngine();
      } else {
        _fallbackNotice = lookupStrings(
          Locale(_languageCode()),
        ).voiceGptLiveFallbackNoticeNoReason;
      }
    }
    _current = engine;
    if (identical(engine, _live)) {
      _watchLive(chat);
    } else {
      _unwatchLive();
    }
    notifyListeners();
    if (epoch != _epoch || _disposed || _privacyBlocked) return;
    await engine.enter(
      chat: chat,
      model: model,
      profile: profile,
      allowTransportFallback: allowTransportFallback,
      onBeforeSend: onBeforeSend,
    );
  }

  /// Reads the server's mode for [identity] and remembers the answer. Returns
  /// whether the server answered within [timeout]: a failed or slow read
  /// leaves the last known mode as it was.
  Future<bool> _refreshMode(
    ActiveChat chat,
    String profile,
    String identity,
    Duration timeout,
  ) async {
    VoiceLiveApi? api;
    try {
      api = _apiFactory(chat);
      final status = await readVoiceLiveStatus(
        api,
        profile: profile,
      ).timeout(timeout);
      _modes.remember(identity, status);
      return true;
    } catch (_) {
      return false;
    } finally {
      api?.close();
    }
  }

  LiveVoiceConversationEngine _liveEngine() {
    final existing = _live;
    if (existing != null) return existing;
    final created = _liveFactory();
    _live = created;
    _attach(created);
    return created;
  }

  @override
  Future<void> exit() async {
    _epoch++;
    _probing = false;
    _probeChat = null;
    _unwatchLive();
    final current = _current;
    _current = null;
    _fallbackNotice = null;
    if (!_disposed) notifyListeners();
    if (current != null) await current.exit();
  }

  // ---- teardown triggers for a live session ----

  void _watchLive(ActiveChat chat) {
    _unwatchLive();
    final live = _live;
    final visible = _visibleSession;
    if (visible != null) {
      void onVisible() {
        if (!_chatVisible(chat)) {
          _invalidateProbe();
          if (live != null) {
            unawaited(live.endSession(LiveSessionEnd.routeLeave));
          }
        }
      }

      _routeListener = onVisible;
      visible.addListener(onVisible);
    }
    final watch = _profileWatch?.call(chat);
    if (watch != null) {
      final started = watch.current();
      void onProfile() {
        if (watch.current() != started) {
          _invalidateProbe();
          if (live != null) {
            unawaited(live.endSession(LiveSessionEnd.profileSwitch));
          }
        }
      }

      _profileListener = onProfile;
      _profileChanges = watch.changes;
      watch.changes.addListener(onProfile);
    }
  }

  /// Whether [chat] is the session the user is looking at. Without a route
  /// notifier every chat counts as visible.
  bool _chatVisible(ActiveChat chat) {
    final visible = _visibleSession;
    if (visible == null) return true;
    final owned = <String?>{
      chat.sessionId,
      chat.serverSessionId,
      chat.logicalSessionId,
      chat.storedSessionId,
    };
    return owned.contains(visible.value);
  }

  void _unwatchLive() {
    final route = _routeListener;
    if (route != null) _visibleSession?.removeListener(route);
    _routeListener = null;
    final profile = _profileListener;
    if (profile != null) _profileChanges?.removeListener(profile);
    _profileListener = null;
    _profileChanges = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _unwatchLive();
    for (final subscription in _unavailableSubs) {
      unawaited(subscription.cancel());
    }
    _unavailableSubs.clear();
    _chained.removeListener(_relay);
    _live?.removeListener(_relay);
    _chained.dispose();
    _live?.dispose();
    unawaited(_unavailable.close());
    super.dispose();
  }

  // ---- state of the running engine ----

  @override
  bool get active => _probing || _engine.active;

  @override
  VoicePhase get phase => _privacyBlocked
      ? VoicePhase.idle
      : _probing
      ? VoicePhase.thinking
      : _engine.phase;

  @override
  String? get note => _privacyBlocked ? null : _engine.note ?? _fallbackNotice;

  @override
  String? get activeTool => _privacyBlocked ? null : _engine.activeTool;

  @override
  String get assistantResponse =>
      _privacyBlocked ? '' : _engine.assistantResponse;

  @override
  String get publicCommentary =>
      _privacyBlocked ? '' : _engine.publicCommentary;

  @override
  ActiveChat? get ownerChat => _engine.ownerChat;

  @override
  bool ownsChat(ActiveChat chat) => _engine.ownsChat(chat);

  @override
  String get partialTranscript =>
      _privacyBlocked ? '' : _engine.partialTranscript;

  @override
  String get userTranscript => _privacyBlocked ? '' : _engine.userTranscript;

  @override
  bool get userPaused => _engine.userPaused;

  @override
  bool get backendActive => _engine.backendActive;

  @override
  bool get spokenInterruptionArmed => _engine.spokenInterruptionArmed;

  @override
  bool get paused => _engine.paused;

  @override
  bool get overlayMinimized => _engine.overlayMinimized;

  @override
  bool get responding => _engine.responding;

  @override
  bool get whisper => _engine.whisper;

  @override
  Stream<SttCheck> get unavailable => _unavailable.stream;

  @override
  String? get sessionId => _current?.sessionId;

  @override
  bool get audioLeaseRequired =>
      _chained.audioLeaseRequired || (_live?.audioLeaseRequired ?? false);

  // ---- controls: only a running engine receives them ----

  @override
  void onOrbTap() => _current?.onOrbTap();

  @override
  void pauseConversation() => _current?.pauseConversation();

  @override
  void playConversation() => _current?.playConversation();

  @override
  void stopAndTalk() => _current?.stopAndTalk();

  @override
  void finishListening() => _current?.finishListening();

  @override
  void cancelBackend() => _current?.cancelBackend();

  @override
  void retry() {
    if (_live?.audioLeaseRequired ?? false) {
      // This can only retry retirement or no-op on an existing live session.
      // Never require presentation authority to finish physical cleanup.
      _live?.retry();
      return;
    }
    if (_privacyBlocked || _disposed) return;
    final owner = ownerChat;
    if (owner == null || !_chatVisible(owner)) return;
    // A GPT-Live retry opens a session, and none opens with the app hidden.
    if (_appHidden && identical(_current, _live)) return;
    _current?.retry();
  }

  @override
  void minimizeOverlay() => _current?.minimizeOverlay();

  @override
  void pauseForApproval() => _current?.pauseForApproval();

  @override
  void resumeOverlay() => _current?.resumeOverlay();

  // ---- app lifecycle ----

  @override
  Future<void> suspendForPrivacy() {
    _privacyBlocked = true;
    _invalidateProbe();
    return _current?.suspendForPrivacy() ?? Future<void>.value();
  }

  void _invalidateProbe() {
    _epoch++;
    _probing = false;
    _probeChat = null;
    _relay();
  }

  @override
  Future<void> resumeFullDuplexCaptureIfNeeded() =>
      _current?.resumeFullDuplexCaptureIfNeeded() ?? Future<void>.value();

  @override
  Future<void> suspendFullDuplexForAppBackground() {
    if (requiresForegroundVisibility) {
      _privacyBlocked = true;
      _invalidateProbe();
    }
    return _current?.suspendFullDuplexForAppBackground() ??
        Future<void>.value();
  }

  @override
  Future<void> onAppBackgrounded() {
    // A GPT-Live session allowed to continue hidden stays as it is, and so
    // does what the notification shows of it; the engine keeps it too.
    if (!_liveContinuesHidden) {
      _privacyBlocked = true;
      _invalidateProbe();
    }
    return _current?.onAppBackgrounded() ?? Future<void>.value();
  }

  @override
  void onAppResumed({required bool appUnlocked}) {
    _privacyBlocked = !appUnlocked;
    // Cached engines survive exit. Visibility releases their fences, never
    // their user pause or microphone, even when there is no current engine.
    _chained.onAppResumed(appUnlocked: appUnlocked);
    _live?.onAppResumed(appUnlocked: appUnlocked);
    _relay();
  }

  @override
  Future<void> pauseFromSystemControl() =>
      _current?.pauseFromSystemControl() ?? Future<void>.value();

  @override
  Future<void> resumeFromSystemControl() =>
      _current?.resumeFromSystemControl() ?? Future<void>.value();
}
