import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/voice/conversation/gpt_live_voice_conversation_controller.dart';
import 'package:hermes_android/core/services/voice/conversation/voice_conversation_engine.dart';
import 'package:hermes_android/core/services/voice/voice_phase.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';

/// Scripted engine: records every call in [calls] and exposes the state the
/// coordinator reads. Used for both the chained and the live slot.
class FakeVoiceEngine extends ChangeNotifier
    implements VoiceConversationEngine, LiveVoiceConversationEngine {
  FakeVoiceEngine(this.name);

  final String name;
  final List<String> calls = [];
  final StreamController<SttCheck> unavailableController =
      StreamController<SttCheck>.broadcast();
  final List<LiveSessionEnd> ended = [];

  ActiveChat? chat;
  Completer<void>? enterGate;
  String enteredProfile = '';

  @override
  bool active = false;
  @override
  String? note;
  @override
  bool audioLeaseRequired = false;
  @override
  String? sessionId;
  @override
  VoicePhase phase = VoicePhase.idle;
  @override
  bool paused = false;
  @override
  bool userPaused = false;
  @override
  String partialTranscript = '';
  @override
  String assistantResponse = '';
  @override
  String? activeTool;
  @override
  bool responding = false;
  @override
  bool whisper = false;

  void emitChange() => notifyListeners();

  @override
  Future<void> enter({
    required ActiveChat chat,
    required String model,
    String profile = '',
    bool allowTransportFallback = false,
    Future<void> Function(String prompt)? onBeforeSend,
  }) async {
    calls.add('enter');
    this.chat = chat;
    enteredProfile = profile;
    active = true;
    notifyListeners();
    await enterGate?.future;
  }

  @override
  Future<void> exit() async {
    calls.add('exit');
    active = false;
    chat = null;
    notifyListeners();
  }

  @override
  Future<void> endSession(LiveSessionEnd reason) async {
    calls.add('endSession:${reason.name}');
    ended.add(reason);
  }

  @override
  bool ownsChat(ActiveChat chat) => active && identical(this.chat, chat);
  @override
  ActiveChat? get ownerChat => active ? chat : null;
  @override
  Stream<SttCheck> get unavailable => unavailableController.stream;

  @override
  Future<void> suspendForPrivacy() async => calls.add('suspendForPrivacy');
  @override
  Future<void> resumeFullDuplexCaptureIfNeeded() async =>
      calls.add('resumeFullDuplexCaptureIfNeeded');
  @override
  Future<void> suspendFullDuplexForAppBackground() async =>
      calls.add('suspendFullDuplexForAppBackground');
  @override
  Future<void> onAppBackgrounded() async => calls.add('onAppBackgrounded');
  @override
  void onAppResumed({required bool appUnlocked}) =>
      calls.add('onAppResumed:$appUnlocked');
  @override
  Future<void> pauseFromSystemControl() async =>
      calls.add('pauseFromSystemControl');
  @override
  Future<void> resumeFromSystemControl() async =>
      calls.add('resumeFromSystemControl');

  @override
  void pauseForApproval() => calls.add('pauseForApproval');
  @override
  void resumeOverlay() => calls.add('resumeOverlay');
  @override
  void onOrbTap() => calls.add('onOrbTap');
  @override
  void pauseConversation() => calls.add('pauseConversation');
  @override
  void playConversation() => calls.add('playConversation');
  @override
  void stopAndTalk() => calls.add('stopAndTalk');
  @override
  void finishListening() => calls.add('finishListening');
  @override
  void cancelBackend() => calls.add('cancelBackend');
  @override
  void retry() => calls.add('retry');
  @override
  void minimizeOverlay() => calls.add('minimizeOverlay');
  @override
  bool get overlayMinimized => false;
  @override
  bool get backendActive => false;
  @override
  bool get spokenInterruptionArmed => false;
  @override
  String get publicCommentary => '';
  @override
  String get userTranscript => partialTranscript;
}
