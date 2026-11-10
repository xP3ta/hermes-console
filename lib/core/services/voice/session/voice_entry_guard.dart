// Why voice mode cannot start right now, decided in one place for every way in
// (the button, Home, the widgets, a shared item). Voice sends what is said as
// its own message; with these pending it would drop or reorder them silently.

import 'package:record/record.dart';

import '../voice_service.dart' show SttCheck, SttStatus;
import '../voice_settings.dart' show SttEngineKind;

/// What stands in the way of entering voice mode.
enum VoiceEntryBlock {
  /// Attachments in the composer would stay behind, unsent.
  attachments,

  /// A sent message is open for editing.
  editingMessage,

  /// Approvals are waiting for an answer.
  pendingApproval,

  /// Messages are queued behind a running turn.
  queued,
}

/// The first thing that blocks entering voice mode, or null when it can start.
VoiceEntryBlock? voiceEntryBlock({
  required bool hasAttachments,
  required bool editingMessage,
  required bool pendingApproval,
  required int queuedMessages,
}) {
  if (editingMessage) return VoiceEntryBlock.editingMessage;
  if (hasAttachments) return VoiceEntryBlock.attachments;
  if (pendingApproval) return VoiceEntryBlock.pendingApproval;
  if (queuedMessages > 0) return VoiceEntryBlock.queued;
  return null;
}

/// Whether the microphone permission is granted (asked if it is not yet).
Future<bool> platformMicrophoneGranted() async {
  final recorder = AudioRecorder();
  try {
    return await recorder.hasPermission();
  } catch (_) {
    return false;
  } finally {
    await recorder.dispose();
  }
}

/// The check that runs before the conversation starts and opens the
/// microphone service.
///
/// GPT-Live uses neither this phone's recognizer, its models nor the phone or
/// server voice route, so none of those may block or delay it: it only needs
/// the microphone permission, which Android 14 wants granted before the
/// microphone foreground service starts. Every other conversation checks its
/// own engine ([localCheck]).
Future<SttCheck> voiceEntryPrecheck({
  required bool startsLive,
  required Future<SttCheck> Function() localCheck,
  Future<bool> Function() microphoneGranted = platformMicrophoneGranted,
}) async {
  if (!startsLive) return localCheck();
  final granted = await microphoneGranted();
  return SttCheck(
    granted ? SttStatus.ready : SttStatus.needsMicPermission,
    SttEngineKind.system,
  );
}
