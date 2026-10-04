import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import '../../../../l10n/app_localizations.dart';
import '../../active_chat_service.dart';
import '../../prompt_client_surface.dart';
import '../live/live_audio_environment.dart';
import '../live/live_rtc_transport.dart';
import '../live/voice_live_api.dart';
import '../live/voice_live_protocol.dart';
import '../live/voice_live_session.dart';
import '../spoken_text.dart';
import '../voice_phase.dart';
import '../voice_service.dart' show SttCheck, SttStatus;
import '../voice_settings.dart' show SttEngineKind;
import 'local_voice_command_detector.dart';
import 'voice_conversation_engine.dart';

/// Why the app ends a live session on its own. None of them reconnects: the
/// stage stays open with a note and a Retry the user can tap.
enum LiveSessionEnd {
  /// The app went to the background or the screen locked.
  appBackground,

  /// Privacy (the app lock) asked every microphone to close.
  privacy,

  /// The chat route was left.
  routeLeave,

  /// The active Hermes profile changed.
  profileSwitch,

  /// Audio focus or the output route changed under the session.
  audioInterrupted,
}

/// A [VoiceConversationEngine] that can also be torn down by the app with a
/// stated reason.
abstract interface class LiveVoiceConversationEngine
    implements VoiceConversationEngine {
  Future<void> endSession(LiveSessionEnd reason);
}

/// GPT-Live conversation on the same [VoiceUiSurface] the chained engine uses.
///
/// The voice model talks to the user over WebRTC; every request that needs
/// Hermes arrives as a delegation, becomes one normal chat turn (tagged with
/// the `voice-live` surface) and its progress and answer flow back to the voice
/// model as quiet context and commentary. Every exit goes through [_endSession]
/// or [exit]; nothing here reconnects by itself.
class GptLiveVoiceConversationController extends ChangeNotifier
    implements LiveVoiceConversationEngine {
  GptLiveVoiceConversationController({
    required this._apiFactory,
    required this._transportFactory,
    required this._audioEvents,
    required this._languageCode,
  });

  static const Duration _noReplyGrace = Duration(seconds: 15);
  // An empty terminal publishes no event until the stored transcript is
  // reconciled, so the turn state is also sampled while a delegation runs.
  static const Duration _turnPoll = Duration(milliseconds: 150);
  static const Duration _stopQuietWindow = Duration(milliseconds: 1500);
  static const String _nudge =
      'The user has finished speaking. Respond now to what they said.';
  static const String _noSpokenResult =
      'Hermes finished that request without a spoken result.';
  static final RegExp _sentenceEnd = RegExp(r'(?:[.!?…]["”’)\]]*|\n)(?:\s|$)');
  static const Set<String> _bareStopWords = {
    'stop',
    'stop it',
    'enough',
    'para',
    'basta',
    'detente',
  };

  final VoiceLiveApi Function(ActiveChat chat) _apiFactory;
  final LiveRtcTransport Function() _transportFactory;
  final Stream<LiveAudioEvent> Function() _audioEvents;
  final String Function() _languageCode;
  final StreamController<SttCheck> _unavailable =
      StreamController<SttCheck>.broadcast();

  ActiveChat? _chat;
  String _model = '';
  String _profile = '';
  Future<void> Function(String prompt)? _onBeforeSend;
  VoiceLiveSession? _session;
  VoiceLiveApi? _api;
  StreamSubscription<ActiveChatEvent>? _chatSub;
  StreamSubscription<LiveAudioEvent>? _audioSub;
  Timer? _graceTimer;
  Timer? _turnPollTimer;
  Timer? _stopTimer;
  Future<void>? _exitInFlight;
  bool _disposed = false;
  bool _starting = false;
  bool _userPaused = false;
  bool _overlayPaused = false;
  int _epoch = 0;
  int _delegationGen = 0;

  String? _delegationId;
  final Set<String> _seenDelegations = {};
  final Set<String> _announcedTools = {};
  int _spokenCursor = 0;
  String _lastContent = '';
  String _staleContent = '';
  bool _spokeAnything = false;

  /// The chat reported the start of the turn this delegation submitted. Until
  /// then a terminal event belongs to the turn it superseded.
  bool _turnLive = false;

  String _partial = '';
  String _userTranscript = '';
  VoiceLiveSpeaker? _lastSpeaker;

  @override
  bool active = false;

  @override
  String? note;

  @override
  bool get paused => _overlayPaused;

  @override
  bool get overlayMinimized => false;

  @override
  void minimizeOverlay() {}

  @override
  bool get userPaused => _userPaused;

  @override
  bool get whisper => false;

  @override
  String get partialTranscript => _partial;

  @override
  String get userTranscript => _userTranscript;

  @override
  String get publicCommentary => '';

  @override
  String? get activeTool =>
      _delegationId == null ? null : _chat?.activeVoiceToolLabel;

  @override
  String get assistantResponse =>
      _delegationId == null ? '' : (_chat?.assistantNarrationContent ?? '');

  @override
  bool get responding => _delegationId != null && _spokeAnything;

  @override
  bool get backendActive =>
      _delegationId != null && (_chat?.isStreaming ?? false);

  @override
  bool get spokenInterruptionArmed =>
      active && _session?.started == true && !_userPaused;

  @override
  ActiveChat? get ownerChat => active ? _chat : null;

  @override
  bool ownsChat(ActiveChat chat) => active && identical(_chat, chat);

  @override
  Stream<SttCheck> get unavailable => _unavailable.stream;

  @override
  VoicePhase get phase {
    if (!active) return VoicePhase.idle;
    if (_starting) return VoicePhase.thinking;
    if (_session == null) return VoicePhase.idle;
    if (_delegationId != null) {
      if (_chat?.pendingApproval != null) return VoicePhase.waitingPermission;
      if (activeTool != null) return VoicePhase.toolCall;
      if (_chat?.isStreaming ?? false) return VoicePhase.thinking;
    }
    return VoicePhase.listening;
  }

  @override
  String? get sessionId => active ? _chat?.serverSessionId : null;

  /// A live session or its start still holds the microphone.
  @override
  bool get audioLeaseRequired => active && (_session != null || _starting);

  Strings get _strings => lookupStrings(Locale(_languageCode()));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---- lifecycle ----

  @override
  Future<void> enter({
    required ActiveChat chat,
    required String model,
    String profile = '',
    bool allowTransportFallback = false,
    Future<void> Function(String prompt)? onBeforeSend,
  }) async {
    if (_disposed) return;
    if (active && identical(_chat, chat)) return;
    if (active) await exit();
    if (_disposed) return;
    _chat = chat;
    _model = model;
    _profile = profile;
    _onBeforeSend = onBeforeSend;
    active = true;
    note = null;
    _userPaused = false;
    _overlayPaused = false;
    _resetUtterance();
    _chatSub = chat.changes.listen(
      _onChatEvent,
      onError: (Object _) {},
      cancelOnError: false,
    );
    await _startSession();
  }

  Future<void> _startSession() async {
    final chat = _chat;
    if (chat == null || !active || _starting || _session != null) return;
    final epoch = ++_epoch;
    _starting = true;
    note = null;
    _seenDelegations.clear();
    _notify();

    final api = _apiFactory(chat);
    final session = VoiceLiveSession(
      transport: _transportFactory(),
      api: api,
      profile: _profile,
      history: toLiveHistory(chat.buildHistory()),
      onDelegation: (id, context) {
        if (epoch == _epoch) _onDelegation(id, context);
      },
      onClosed: (reason, seconds) {
        if (epoch == _epoch) _onSessionClosed(reason, seconds);
      },
      onTranscript: (fragment) {
        if (epoch == _epoch) _onFragment(fragment);
      },
    );
    _api = api;
    _session = session;
    try {
      await session.start();
      if (epoch != _epoch) return;
      _starting = false;
      if (session.finished) return;
      _audioSub = _audioEvents().listen(
        (_) => unawaited(endSession(LiveSessionEnd.audioInterrupted)),
        onError: (Object _) {},
      );
      _notify();
    } on LiveMicrophoneDeniedException {
      if (epoch != _epoch) return;
      _releaseSession(session);
      _unavailable.add(
        const SttCheck(SttStatus.needsMicPermission, SttEngineKind.system),
      );
      _notify();
    } on VoiceLiveSessionException catch (error) {
      if (epoch != _epoch) return;
      _releaseSession(session);
      final s = _strings;
      note = error.detail.isEmpty
          ? s.voiceGptLiveCouldNotStart
          : s.voiceGptLiveCouldNotStartDetail(error.detail);
      _notify();
    } catch (_) {
      if (epoch != _epoch) return;
      _releaseSession(session);
      note = _strings.voiceGptLiveCouldNotStart;
      _notify();
    }
  }

  /// Forgets a session that already tore itself down.
  void _releaseSession(VoiceLiveSession session) {
    if (!identical(_session, session)) return;
    _starting = false;
    _session = null;
    _closeApi();
    unawaited(_audioSub?.cancel());
    _audioSub = null;
  }

  void _closeApi() {
    final api = _api;
    _api = null;
    api?.close();
  }

  void _onSessionClosed(String reason, int? seconds) {
    if (_disposed || !active) return;
    final session = _session;
    if (session != null) _releaseSession(session);
    _clearDelegation();
    _cancelStopTimer();
    final s = _strings;
    final why = switch (reason) {
      'connection_lost' => s.voiceGptLiveReasonConnectionLost,
      'close_requested' => null,
      'closed' => s.voiceGptLiveReasonClosed,
      _ => seconds == null ? reason : '$reason (${seconds}s)',
    };
    note = why == null
        ? s.voiceGptLiveEnded
        : s.voiceGptLiveEndedWithReason(why);
    _notify();
  }

  /// Tears the session down at once and leaves the stage open with a note.
  @override
  Future<void> endSession(LiveSessionEnd reason) async {
    final session = _session;
    if (!active || session == null) return;
    final s = _strings;
    final why = reason == LiveSessionEnd.audioInterrupted
        ? s.voiceGptLiveReasonAudio
        : s.voiceGptLiveReasonLeft;
    // Rotating the epoch first keeps `abort`'s onClosed from wording the note.
    _epoch++;
    _releaseSession(session);
    session.abort('close_requested');
    if (_disposed) return;
    _clearDelegation();
    _cancelStopTimer();
    note = s.voiceGptLiveEndedWithReason(why);
    _notify();
  }

  @override
  void retry() {
    if (!active || _session != null || _starting) return;
    unawaited(_startSession());
  }

  @override
  Future<void> exit() => _exitInFlight ??= _exit().whenComplete(() {
    _exitInFlight = null;
  });

  Future<void> _exit() async {
    if (!active && _session == null) return;
    _epoch++;
    active = false;
    note = null;
    _userPaused = false;
    _overlayPaused = false;
    _starting = false;
    _clearDelegation();
    _cancelStopTimer();
    _resetUtterance();
    final chatSub = _chatSub;
    _chatSub = null;
    final audioSub = _audioSub;
    _audioSub = null;
    final session = _session;
    _session = null;
    _closeApi();
    _chat = null;
    _notify();
    unawaited(session?.close());
    await Future.wait([
      if (chatSub != null) chatSub.cancel(),
      if (audioSub != null) audioSub.cancel(),
    ]);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _epoch++;
    _disposed = true;
    active = false;
    _graceTimer?.cancel();
    _turnPollTimer?.cancel();
    _stopTimer?.cancel();
    unawaited(_chatSub?.cancel());
    unawaited(_audioSub?.cancel());
    final session = _session;
    _session = null;
    _closeApi();
    unawaited(session?.close());
    unawaited(_unavailable.close());
    super.dispose();
  }

  // ---- delegations ----

  void _onDelegation(String id, List<VoiceLiveFragment> context) {
    if (!active || _disposed) return;
    if (!_seenDelegations.add(id)) return;
    final prompt = delegationPrompt(context);
    final text = prompt.prompt.trim();
    if (text.isEmpty) return;
    final command = _commandFor(text);
    if (command == LocalVoiceCommand.end) {
      unawaited(exit());
      return;
    }
    if (command == LocalVoiceCommand.pause) {
      pauseConversation();
      return;
    }
    unawaited(_runDelegation(id, text, prompt.voiceContext));
  }

  LocalVoiceCommand? _commandFor(String text) {
    final lower = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), '')
        .trim();
    if (_bareStopWords.contains(lower)) return LocalVoiceCommand.end;
    final command = const LocalVoiceCommandDetector().detect(
      text,
      language: _languageCode(),
    );
    return switch (command) {
      LocalVoiceCommand.silenceCurrent => LocalVoiceCommand.end,
      _ => command,
    };
  }

  Future<void> _runDelegation(
    String id,
    String text,
    String voiceContext,
  ) async {
    final chat = _chat;
    final session = _session;
    if (chat == null || session == null) return;
    final gen = ++_delegationGen;
    // A new request supersedes the old one; its remaining speech is dropped.
    _clearDelegation(keepGeneration: true);
    bool current() =>
        active &&
        !_disposed &&
        gen == _delegationGen &&
        identical(_session, session);
    try {
      if (chat.isStreaming) {
        await chat.cancel();
        if (!current()) return;
      }
      _delegationId = id;
      _announcedTools.clear();
      _spokenCursor = 0;
      _lastContent = '';
      _staleContent = chat.assistantNarrationContent;
      _spokeAnything = false;
      _turnLive = false;
      _turnPollTimer?.cancel();
      _turnPollTimer = Timer.periodic(_turnPoll, (_) => _pollTurn(session, id));
      _notify();
      await _onBeforeSend?.call(text);
      if (!current()) return;
      final accepted = await chat.send(
        fullText: text,
        model: _model,
        history: chat.buildHistory(),
        profile: _profile,
        clientSurface: PromptClientSurface.voiceLive(
          voiceContext: voiceContext,
        ),
      );
      if (!current()) return;
      if (!accepted) {
        _apologize(session, id);
        return;
      }
      _graceTimer?.cancel();
      _graceTimer = Timer(_noReplyGrace, () {
        if (!current() || _delegationId != id) return;
        if (!(_chat?.isStreaming ?? false)) _settle(session, id);
      });
      _observe();
    } catch (_) {
      if (!current()) return;
      _apologize(session, id);
    }
  }

  void _pollTurn(VoiceLiveSession session, String id) {
    if (_disposed || !active || _delegationId != id) return;
    _observe();
    final state = _chat?.state;
    // Only a terminal state proves the turn ran; an idle chat that never
    // started one is left to the no-reply grace timer.
    if (_turnLive &&
        (state == ChatPipelineState.completed ||
            state == ChatPipelineState.failed ||
            state == ChatPipelineState.cancelled)) {
      _settle(session, id);
      _notify();
    }
  }

  void _apologize(VoiceLiveSession session, String id) {
    session.commentary(id, _strings.voiceGptLiveDelegationFailed);
    if (_delegationId == id) _clearDelegation(keepGeneration: true);
    _notify();
  }

  void _clearDelegation({bool keepGeneration = false}) {
    if (!keepGeneration) _delegationGen++;
    _graceTimer?.cancel();
    _graceTimer = null;
    _turnPollTimer?.cancel();
    _turnPollTimer = null;
    _delegationId = null;
    _spokenCursor = 0;
    _lastContent = '';
    _staleContent = '';
    _spokeAnything = false;
    _turnLive = false;
  }

  // ---- Hermes -> voice model ----

  void _onChatEvent(ActiveChatEvent event) {
    if (_disposed || !active) return;
    if (event == ActiveChatEvent.started) _turnLive = true;
    _observe();
    final terminal =
        event == ActiveChatEvent.done ||
        event == ActiveChatEvent.error ||
        event == ActiveChatEvent.cancelled;
    final session = _session;
    final id = _delegationId;
    if (terminal && _turnLive && session != null && id != null) {
      _settle(session, id);
    }
    _notify();
  }

  void _observe() {
    final session = _session;
    final chat = _chat;
    final id = _delegationId;
    if (session == null || chat == null || id == null) return;
    final label = chat.activeVoiceToolLabel;
    if (label != null && _announcedTools.add(label)) {
      session.think(id, 'Hermes is working: $label. Not done yet.');
    }
    final content = chat.assistantNarrationContent;
    if (_staleContent.isNotEmpty) {
      if (content == _staleContent) return;
      _staleContent = '';
    }
    if (content.length < _spokenCursor) _spokenCursor = 0;
    _lastContent = content;
    final pending = content.substring(_spokenCursor);
    var end = -1;
    for (final match in _sentenceEnd.allMatches(pending)) {
      end = match.end;
    }
    if (end <= 0) return;
    _spokenCursor += end;
    _say(session, id, pending.substring(0, end));
  }

  void _say(VoiceLiveSession session, String id, String raw) {
    final clean = SpokenText.fromMarkdown(raw);
    // One append per sentence keeps the voice model's pacing natural.
    for (final sentence in clean.split(RegExp(r'(?<=[.!?…])\s+'))) {
      for (final chunk in chunkForCommentary(sentence)) {
        if (session.commentary(id, chunk)) _spokeAnything = true;
      }
    }
  }

  /// The Hermes turn ended: speak the unspoken tail, or say there was none.
  void _settle(VoiceLiveSession session, String id) {
    if (_delegationId != id) return;
    final chat = _chat;
    var content = chat?.assistantNarrationContent ?? '';
    if (content.isEmpty) content = _lastContent;
    if (_staleContent.isNotEmpty && content == _staleContent) content = '';
    if (content.length < _spokenCursor) _spokenCursor = 0;
    final tail = content.substring(_spokenCursor);
    if (tail.trim().isNotEmpty) _say(session, id, tail);
    if (!_spokeAnything) session.think(id, _noSpokenResult);
    _clearDelegation();
    _notify();
  }

  // ---- transcripts and spoken stop ----

  void _resetUtterance() {
    _partial = '';
    _userTranscript = '';
    _lastSpeaker = null;
  }

  void _onFragment(VoiceLiveFragment fragment) {
    if (!active || _disposed) return;
    if (fragment.speaker == VoiceLiveSpeaker.user) {
      if (_lastSpeaker != VoiceLiveSpeaker.user) _partial = '';
      _partial += fragment.text;
      _userTranscript = _partial;
      _lastSpeaker = VoiceLiveSpeaker.user;
      _stopTimer?.cancel();
      _stopTimer = Timer(_stopQuietWindow, _onUserQuiet);
    } else {
      _partial = '';
      _lastSpeaker = VoiceLiveSpeaker.assistant;
    }
    _notify();
  }

  void _onUserQuiet() {
    _stopTimer = null;
    if (!active || _disposed) return;
    final text = collapseWhitespace(_userTranscript);
    if (text.isEmpty) return;
    if (_commandFor(text) == LocalVoiceCommand.end) unawaited(exit());
  }

  void _cancelStopTimer() {
    _stopTimer?.cancel();
    _stopTimer = null;
  }

  // ---- controls ----

  @override
  void onOrbTap() {
    if (_userPaused) {
      playConversation();
      return;
    }
    _session?.instruct(_nudge);
  }

  @override
  void stopAndTalk() => _session?.instruct(_nudge);

  @override
  void finishListening() => _session?.instruct(_nudge);

  @override
  void pauseConversation() {
    final session = _session;
    if (session == null || _userPaused) return;
    _userPaused = true;
    session.setMuted(true);
    _notify();
  }

  @override
  void playConversation() {
    final session = _session;
    if (session == null || !_userPaused) return;
    _userPaused = false;
    session.setMuted(false);
    _notify();
  }

  @override
  void cancelBackend() {
    final chat = _chat;
    if (_delegationId == null) return;
    _clearDelegation();
    if (chat != null) unawaited(chat.cancel());
    _notify();
  }

  // ---- app lifecycle ----

  /// Privacy (app lock) closes the microphone for good: a live session never
  /// resumes by itself, the user restarts it from the stage.
  @override
  Future<void> suspendForPrivacy() => endSession(LiveSessionEnd.privacy);

  /// `main.dart` calls this only when the user did not opt in to keep voice
  /// running with the screen locked.
  @override
  Future<void> onAppBackgrounded() => endSession(LiveSessionEnd.appBackground);

  // The live stream has no half-duplex capture to arm or disarm, and a lost
  // session is not revived on return.
  @override
  Future<void> suspendFullDuplexForAppBackground() async {}

  @override
  Future<void> resumeFullDuplexCaptureIfNeeded() async {}

  @override
  void onAppResumed({required bool appUnlocked}) {}

  @override
  Future<void> pauseFromSystemControl() async => pauseConversation();

  @override
  Future<void> resumeFromSystemControl() async => playConversation();

  @override
  void pauseForApproval() {
    if (_overlayPaused) return;
    _overlayPaused = true;
    _notify();
  }

  @override
  void resumeOverlay() {
    if (!_overlayPaused) return;
    _overlayPaused = false;
    _notify();
  }
}
