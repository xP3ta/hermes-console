import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import '../../../../l10n/app_localizations.dart';
import '../../active_chat_service.dart';
import '../live/voice_live_api.dart';
import '../live/voice_live_protocol.dart' show VoiceLiveStatus;
import '../voice_phase.dart';
import '../voice_service.dart' show SttCheck;
import 'gpt_live_voice_conversation_controller.dart';
import 'voice_conversation_engine.dart';

/// Where the active Hermes profile of a chat's connection can be read and
/// observed.
typedef VoiceProfileWatch = ({Listenable changes, String Function() current});

/// The single voice conversation the app and the chat screen talk to.
///
/// It picks the engine once per entry: GPT-Live only when the local opt-in is
/// on and the server reports it available, the chained local engine in every
/// other case (with one notice when the opt-in could not be honoured). The
/// engine then runs until [exit]; changing the opt-in meanwhile does not swap
/// it. Everything else is forwarded to the engine that is running.
class VoiceConversationCoordinator extends ChangeNotifier
    implements VoiceConversationEngine {
  VoiceConversationCoordinator({
    required this._chained,
    required this._liveFactory,
    required this._gptLiveEnabled,
    required this._apiFactory,
    required this._languageCode,
    this._visibleSession,
    this._profileWatch,
  }) {
    _attach(_chained);
  }

  static const Duration _statusTimeout = Duration(seconds: 5);

  final VoiceConversationEngine _chained;
  final LiveVoiceConversationEngine Function() _liveFactory;
  final bool Function() _gptLiveEnabled;
  final VoiceLiveApi Function(ActiveChat chat) _apiFactory;
  final String Function() _languageCode;
  final ValueListenable<String?>? _visibleSession;
  final VoiceProfileWatch Function(ActiveChat chat)? _profileWatch;

  final StreamController<SttCheck> _unavailable =
      StreamController<SttCheck>.broadcast();
  final List<StreamSubscription<SttCheck>> _unavailableSubs = [];
  LiveVoiceConversationEngine? _live;
  VoiceConversationEngine? _current;
  ActiveChat? _probeChat;
  String _probeProfile = '';
  bool _probing = false;
  bool _disposed = false;
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
    if (_disposed) return;
    // The same chat and profile already being probed is one entry; another
    // profile supersedes the pending probe.
    if (_probing && identical(_probeChat, chat) && _probeProfile == profile) {
      return;
    }
    final running = _current;
    if (running != null && running.active) {
      if (running.ownsChat(chat)) return;
      await exit();
    }
    final epoch = ++_epoch;
    _fallbackNotice = null;
    VoiceConversationEngine engine = _chained;
    if (_gptLiveEnabled()) {
      _probing = true;
      _probeChat = chat;
      _probeProfile = profile;
      notifyListeners();
      final status = await _readStatus(chat, profile);
      if (epoch != _epoch || _disposed) return;
      _probing = false;
      _probeChat = null;
      if (status != null && status.available) {
        engine = _liveEngine();
      } else {
        final s = lookupStrings(Locale(_languageCode()));
        final reason = status?.reason?.trim() ?? '';
        _fallbackNotice = reason.isEmpty
            ? s.voiceGptLiveFallbackNoticeNoReason
            : s.voiceGptLiveFallbackNotice(reason);
      }
    }
    _current = engine;
    if (identical(engine, _live)) _watchLive(chat);
    notifyListeners();
    await engine.enter(
      chat: chat,
      model: model,
      profile: profile,
      allowTransportFallback: allowTransportFallback,
      onBeforeSend: onBeforeSend,
    );
  }

  Future<VoiceLiveStatus?> _readStatus(ActiveChat chat, String profile) async {
    VoiceLiveApi? api;
    try {
      api = _apiFactory(chat);
      return await api.fetchStatus(profile: profile).timeout(_statusTimeout);
    } catch (_) {
      return null;
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
    if (live == null) return;
    final visible = _visibleSession;
    if (visible != null) {
      void onVisible() {
        final id = visible.value;
        final owned = <String?>{
          chat.sessionId,
          chat.serverSessionId,
          chat.logicalSessionId,
          chat.storedSessionId,
        };
        if (!owned.contains(id)) {
          unawaited(live.endSession(LiveSessionEnd.routeLeave));
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
          unawaited(live.endSession(LiveSessionEnd.profileSwitch));
        }
      }

      _profileListener = onProfile;
      _profileChanges = watch.changes;
      watch.changes.addListener(onProfile);
    }
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
  VoicePhase get phase => _probing ? VoicePhase.thinking : _engine.phase;

  @override
  String? get note => _engine.note ?? _fallbackNotice;

  @override
  String? get activeTool => _engine.activeTool;

  @override
  String get assistantResponse => _engine.assistantResponse;

  @override
  String get publicCommentary => _engine.publicCommentary;

  @override
  ActiveChat? get ownerChat => _engine.ownerChat;

  @override
  bool ownsChat(ActiveChat chat) => _engine.ownsChat(chat);

  @override
  String get partialTranscript => _engine.partialTranscript;

  @override
  String get userTranscript => _engine.userTranscript;

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
  bool get audioLeaseRequired => _current?.audioLeaseRequired ?? false;

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
  void retry() => _current?.retry();

  @override
  void minimizeOverlay() => _current?.minimizeOverlay();

  @override
  void pauseForApproval() => _current?.pauseForApproval();

  @override
  void resumeOverlay() => _current?.resumeOverlay();

  // ---- app lifecycle ----

  @override
  Future<void> suspendForPrivacy() =>
      _current?.suspendForPrivacy() ?? Future<void>.value();

  @override
  Future<void> resumeFullDuplexCaptureIfNeeded() =>
      _current?.resumeFullDuplexCaptureIfNeeded() ?? Future<void>.value();

  @override
  Future<void> suspendFullDuplexForAppBackground() =>
      _current?.suspendFullDuplexForAppBackground() ?? Future<void>.value();

  @override
  Future<void> onAppBackgrounded() =>
      _current?.onAppBackgrounded() ?? Future<void>.value();

  @override
  void onAppResumed({required bool appUnlocked}) =>
      _current?.onAppResumed(appUnlocked: appUnlocked);

  @override
  Future<void> pauseFromSystemControl() =>
      _current?.pauseFromSystemControl() ?? Future<void>.value();

  @override
  Future<void> resumeFromSystemControl() =>
      _current?.resumeFromSystemControl() ?? Future<void>.value();
}
