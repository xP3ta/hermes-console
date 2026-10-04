import 'package:package_info_plus/package_info_plus.dart';

import '../../l10n/app_localizations.dart';
import '../models/turn_error_surface.dart';

/// Title and optional hint of a failed turn's card.
final class TurnErrorCopy {
  final String title;
  final String? hint;

  const TurnErrorCopy(this.title, [this.hint]);
}

/// Text for [surface], by its code (Desktop `ERROR_CODE_KEYS`), else by its
/// layer. An unknown code reads as its layer; an unknown layer cannot reach
/// here (the parser drops it).
TurnErrorCopy turnErrorCopy(Strings s, TurnErrorSurface surface) {
  final byCode = switch (surface.code) {
    'rate_limit' || 'upstream_rate_limit' || 'free_tier_rate_limited' =>
      TurnErrorCopy(s.te1215TitleRateLimit, s.te1215HintRateLimit),
    'overloaded' || 'free_tier_at_capacity' => TurnErrorCopy(
      s.te1215TitleOverloaded,
      s.te1215HintOverloaded,
    ),
    'server_error' ||
    'free_tier_outage' => TurnErrorCopy(s.te1215TitleServerError),
    'timeout' => TurnErrorCopy(s.te1215TitleTimeout, s.te1215HintTimeout),
    'stream_drop' => TurnErrorCopy(s.te1215TitleStreamDrop),
    'ssl_cert_verification' => TurnErrorCopy(
      s.te1215TitleCertificate,
      s.te1215HintCertificate,
    ),
    'upstream_blocked' => TurnErrorCopy(s.te1215TitleUpstreamBlocked),
    'context_overflow' => TurnErrorCopy(
      s.te1215TitleContextOverflow,
      s.te1215HintContextOverflow,
    ),
    'payload_too_large' => TurnErrorCopy(
      s.te1215TitlePayloadTooLarge,
      s.te1215HintPayloadTooLarge,
    ),
    'model_not_found' || 'free_tier_model_not_free' => TurnErrorCopy(
      s.te1215TitleModelNotFound,
      s.te1215HintModelNotFound,
    ),
    'provider_policy_blocked' ||
    'free_tier_refused' => TurnErrorCopy(s.te1215TitlePolicyBlocked),
    'content_policy_blocked' => TurnErrorCopy(
      s.te1215TitleContentPolicy,
      s.te1215HintContentPolicy,
    ),
    'format_error' ||
    'invalid_response' => TurnErrorCopy(s.te1215TitleFormatError),
    'truncated' ||
    'empty_response' ||
    'no_reply' => TurnErrorCopy(s.te1215TitleEmptyResponse),
    'loop_error' => TurnErrorCopy(s.te1215TitleLoop, s.te1215HintLoop),
    'SESSION_NOT_OWNED' => TurnErrorCopy(
      s.te1215TitleNotOwned,
      s.te1215HintNotOwned,
    ),
    'disk_full' => TurnErrorCopy(s.te1215TitleDiskFull, s.te1215HintDiskFull),
    'free_tier_disabled' ||
    'free_tier_route' => TurnErrorCopy(s.te1215TitleFreeTierOff),
    'billing' => TurnErrorCopy(s.te1215TitleBilling),
    _ => null,
  };
  if (byCode != null) return byCode;
  return TurnErrorCopy(switch (surface.layer) {
    'endpoint' => s.te1215LayerEndpoint,
    'streaming' => s.te1215LayerStreaming,
    'auth' => s.te1215LayerAuth,
    'billing' => s.te1215TitleBilling,
    'gateway' => s.te1215LayerGateway,
    'runtime' => s.te1215LayerRuntime,
    'disk' => s.te1215TitleDiskFull,
    _ => s.te1215LayerProvider,
  });
}

/// Label of a recovery action; the ones that already exist elsewhere reuse
/// their text.
String errorRecoveryActionLabel(Strings s, ErrorRecoveryAction action) =>
    switch (action) {
      ErrorRecoveryAction.signInAgain => s.hr1215SignInAgain,
      ErrorRecoveryAction.updateApiKey => s.hr1215CheckKey,
      ErrorRecoveryAction.compress => s.te1215Compress,
      ErrorRecoveryAction.chooseModel => s.te1215ChooseModel,
      ErrorRecoveryAction.editMessage => s.chaEditMessage,
      ErrorRecoveryAction.retry => s.chaRetry,
      ErrorRecoveryAction.signInFreeTier => s.te1215SignInFree,
      ErrorRecoveryAction.startNewSession => s.chaNewChatTooltip,
      ErrorRecoveryAction.switchProvider => s.te1215SwitchProvider,
    };

/// `1.2.15+1215`, the app version «Copiar detalles» writes.
Future<String> appVersionLabel() async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version}+${info.buildNumber}';
}
