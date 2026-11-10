// The words for a [VoiceCare], in the app language. One place, so the line,
// the capsule and the dialogs say the same thing for the same cause.
import '../../../../l10n/app_localizations.dart';
import 'voice_care.dart';

String voiceCareText(Strings strings, VoiceCare care) => switch (care) {
  VoiceCare.sendFailed => strings.vcrSendFailed,
  VoiceCare.micBusy => strings.vcrMicBusy,
  VoiceCare.micUnavailable => strings.vcrMicUnavailable,
  VoiceCare.needsNetwork => strings.vcrNeedsNetwork,
  VoiceCare.transcriptionTimedOut => strings.vcrTranscriptionTimedOut,
  VoiceCare.languageFallback => strings.vcrLanguageFallback,
  VoiceCare.serverUnavailable => strings.vcrServerUnavailable,
  VoiceCare.pausedByBackground => strings.vcrPausedByBackground,
  VoiceCare.routeRestarted => strings.vcrRouteRestarted,
};
