/// Structured failure of a turn: which layer failed and how to recover.
///
/// Port of Hermes Desktop `apps/desktop/src/lib/error-surface.ts`
/// (`parseErrorSurface`, `errorRecoveryPlan`, `formatLimitReset`,
/// `scheduledRetryDelay`, `formatErrorDiagnostics`) and of
/// `store/provider-wait.ts::providerWaitText` for the `error_surface` and
/// `billing` the gateway attaches to a failed `message.complete` and to a
/// resumed `inflight` turn.
///
/// Credential failures keep coming from `ProviderAuthFailure.classify`; the
/// plan only consumes its result.
library;

import 'provider_auth_failure.dart';

/// Private row keys that carry the sanitized failure on an `assistant_error`
/// message.
const turnErrorSurfaceKey = '_errorSurface';
const turnBillingBlockKey = '_billingBlock';

/// Layers a structured error surface may name.
const _layers = {
  'provider',
  'endpoint',
  'streaming',
  'auth',
  'billing',
  'gateway',
  'runtime',
  'disk',
};

const _maxIdentityLength = 128;
const _maxMessageLength = 500;
const _maxBillingLineLength = 240;
const _maxWaitTextLength = 160;

/// Longest delay a platform timer accepts (2^31-1 ms).
const _maxTimerMilliseconds = 2147483647;

final class TurnErrorSurface {
  final String layer;
  final String code;
  final bool retryable;
  final String? provider;
  final String? providerLabel;
  final String? model;

  /// Credential kind, only on the `auth` layer.
  final ProviderAuthKind? authKind;

  /// Name of the key's environment variable (never the key), only on the
  /// `auth` layer. Not shown to the user.
  final String? apiKeyEnv;

  /// The gateway's own sentence for the user (`free_tier_*` codes).
  final String? message;

  /// Epoch seconds at which the provider said its limit lifts.
  final double? resetsAt;

  const TurnErrorSurface({
    required this.layer,
    required this.code,
    required this.retryable,
    this.provider,
    this.providerLabel,
    this.model,
    this.authKind,
    this.apiKeyEnv,
    this.message,
    this.resetsAt,
  });

  bool get isFreeTier => code.startsWith('free_tier_');

  /// Port of `parseErrorSurface`: an unknown layer is no surface, an empty
  /// code is `unknown`, `retryable` is true unless the gateway says `false`,
  /// `resets_at` needs a finite number above zero and `message` a non-blank
  /// string. A JSON `null` counts as absent.
  static TurnErrorSurface? parse(Object? raw) {
    if (raw is! Map) return null;
    final layer = raw['layer'];
    if (layer is! String || !_layers.contains(layer)) return null;
    final code = _text(raw['code']);
    final isAuth = layer == 'auth';
    final resets = raw['resets_at'];
    final message = _text(raw['message']);
    final keyEnv = _text(raw['api_key_env']);
    return TurnErrorSurface(
      layer: layer,
      code: code.isEmpty ? 'unknown' : code,
      retryable: raw['retryable'] != false,
      provider: _identity(raw['provider']),
      providerLabel: _identity(raw['provider_label']),
      model: _identity(raw['model']),
      authKind: isAuth ? ProviderAuthKind.fromWire(raw['auth_kind']) : null,
      apiKeyEnv: isAuth && _envName.hasMatch(keyEnv) ? keyEnv : null,
      message: message.isEmpty
          ? null
          : message.length <= _maxMessageLength
          ? message
          : message.substring(0, _maxMessageLength),
      resetsAt: resets is num && resets.isFinite && resets > 0
          ? resets.toDouble()
          : null,
    );
  }

  /// Sanitized scalars for the row metadata; the same shape [parse] reads.
  Map<String, Object> toJson() => {
    'layer': layer,
    'code': code,
    'retryable': retryable,
    'provider': ?provider,
    'provider_label': ?providerLabel,
    'model': ?model,
    'auth_kind': ?authKind?.wire,
    'api_key_env': ?apiKeyEnv,
    'message': ?message,
    'resets_at': ?resetsAt,
  };
}

/// A provider out of credit, as `message.complete.billing` reports it.
final class TurnBillingBlock {
  final String providerLabel;
  final bool isNous;

  /// Only an `https` URL survives.
  final String? billingUrl;

  /// First line of the gateway's message.
  final String firstLine;

  const TurnBillingBlock({
    required this.providerLabel,
    required this.isNous,
    required this.billingUrl,
    required this.firstLine,
  });

  static TurnBillingBlock? parse(Object? raw) {
    if (raw is! Map) return null;
    final label =
        _identity(raw['provider_label']) ?? _identity(raw['provider']);
    if (label == null) return null;
    final url = _text(raw['billing_url']);
    final uri = Uri.tryParse(url);
    final https = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
    final lines = _text(raw['message']).split(RegExp(r'\r?\n'));
    final first = lines
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    return TurnBillingBlock(
      providerLabel: label,
      isNous: raw['is_nous'] == true,
      billingUrl: https && url.length <= 2048 ? url : null,
      firstLine: first.length <= _maxBillingLineLength
          ? first
          : first.substring(0, _maxBillingLineLength),
    );
  }

  Map<String, Object> toJson() => {
    'provider_label': providerLabel,
    'is_nous': isNous,
    'billing_url': ?billingUrl,
    'message': firstLine,
  };
}

/// The row metadata of a failed turn: the sanitized [errorSurface] and
/// [billing] under their private keys, each only when it parses. Also used to
/// keep them through transcript normalization, where the inputs are already
/// the sanitized form.
Map<String, Object> turnFailureMetadata({
  Object? errorSurface,
  Object? billing,
}) {
  final surface = TurnErrorSurface.parse(errorSurface);
  final block = TurnBillingBlock.parse(billing);
  return {
    turnErrorSurfaceKey: ?surface?.toJson(),
    turnBillingBlockKey: ?block?.toJson(),
  };
}

/// What the card may offer for a failed turn (`errorRecoveryPlan`).
final class ErrorRecoveryPlan {
  final bool retry;
  final bool signInAgain;
  final bool signInFreeTier;
  final bool switchProvider;
  final bool updateApiKey;
  final bool chooseModel;
  final bool compress;
  final bool editMessage;
  final bool openHermesFolder;
  final bool startNewSession;

  const ErrorRecoveryPlan({
    this.retry = false,
    this.signInAgain = false,
    this.signInFreeTier = false,
    this.switchProvider = false,
    this.updateApiKey = false,
    this.chooseModel = false,
    this.compress = false,
    this.editMessage = false,
    this.openHermesFolder = false,
    this.startNewSession = false,
  });

  ErrorRecoveryPlan _with({
    bool? retry,
    bool? chooseModel,
    bool? compress,
    bool? editMessage,
    bool? openHermesFolder,
    bool? startNewSession,
  }) => ErrorRecoveryPlan(
    retry: retry ?? this.retry,
    signInAgain: signInAgain,
    signInFreeTier: signInFreeTier,
    switchProvider: switchProvider,
    updateApiKey: updateApiKey,
    chooseModel: chooseModel ?? this.chooseModel,
    compress: compress ?? this.compress,
    editMessage: editMessage ?? this.editMessage,
    openHermesFolder: openHermesFolder ?? this.openHermesFolder,
    startNewSession: startNewSession ?? this.startNewSession,
  );
}

const _switchProviderLayers = {'auth', 'billing', 'endpoint', 'provider'};

/// Per-code overrides of the layer plan (`CODE_PLANS`).
final Map<String, ErrorRecoveryPlan Function(ErrorRecoveryPlan)> _codePlans = {
  'SESSION_NOT_OWNED': (base) =>
      base._with(retry: false, startNewSession: true),
  'content_policy_blocked': (base) =>
      base._with(editMessage: true, retry: false),
  'context_overflow': (base) =>
      base._with(compress: true, retry: false, startNewSession: true),
  'disk_full': (base) => base._with(openHermesFolder: true, retry: true),
  'loop_error': (base) => base._with(startNewSession: true),
  'model_not_found': (base) => base._with(chooseModel: true, retry: false),
  'payload_too_large': (base) =>
      base._with(compress: true, retry: false, startNewSession: true),
};

/// Port of `errorRecoveryPlan`. [authFailure] is `ProviderAuthFailure.classify`
/// of the same turn: an OAuth one signs in again, any other rejects the key.
ErrorRecoveryPlan errorRecoveryPlan({
  required TurnErrorSurface? surface,
  ProviderAuthFailure? authFailure,
}) {
  final oauthReauth = authFailure != null && authFailure.isOAuth;
  final apiKeyRejected = authFailure != null && !authFailure.isOAuth;
  final base = ErrorRecoveryPlan(
    retry:
        surface == null || surface.retryable || oauthReauth || apiKeyRejected,
    signInAgain: oauthReauth,
    signInFreeTier: surface?.isFreeTier ?? false,
    switchProvider:
        surface != null && _switchProviderLayers.contains(surface.layer),
    updateApiKey: apiKeyRejected,
  );
  final override = surface == null ? null : _codePlans[surface.code];
  return override == null ? base : override(base);
}

/// Recovery actions the card can run, most relevant first.
enum ErrorRecoveryAction {
  signInAgain,
  updateApiKey,
  compress,
  chooseModel,
  editMessage,
  retry,
  signInFreeTier,
  startNewSession,
  switchProvider,
}

/// The actions of [plan] in priority order: the first is the one visible
/// action, the rest go behind the card's details. `openHermesFolder` does not
/// apply on a phone and is never listed.
List<ErrorRecoveryAction> errorRecoveryActions(ErrorRecoveryPlan plan) => [
  if (plan.signInAgain) ErrorRecoveryAction.signInAgain,
  if (plan.updateApiKey) ErrorRecoveryAction.updateApiKey,
  if (plan.compress) ErrorRecoveryAction.compress,
  if (plan.chooseModel) ErrorRecoveryAction.chooseModel,
  if (plan.editMessage) ErrorRecoveryAction.editMessage,
  if (plan.retry) ErrorRecoveryAction.retry,
  if (plan.signInFreeTier) ErrorRecoveryAction.signInFreeTier,
  if (plan.startNewSession) ErrorRecoveryAction.startNewSession,
  if (plan.switchProvider) ErrorRecoveryAction.switchProvider,
];

/// Local clock time and time left of a usage limit reset.
final class LimitReset {
  /// `HH:mm` in the device's time zone.
  final String clock;

  /// `1 h 05 min`, `7 min`.
  final String remaining;

  const LimitReset({required this.clock, required this.remaining});
}

/// Port of `formatLimitReset`. Null when the gateway named no reset or it is
/// not in the future.
LimitReset? formatLimitReset(double? resetsAtSeconds, DateTime now) {
  if (resetsAtSeconds == null) return null;
  final at = DateTime.fromMillisecondsSinceEpoch(
    (resetsAtSeconds * 1000).round(),
  );
  final left = at.difference(now);
  if (left <= Duration.zero) return null;
  final minutes = (left.inMilliseconds / Duration.millisecondsPerMinute).ceil();
  final hours = minutes ~/ 60;
  final rest = (minutes % 60).toString().padLeft(2, '0');
  return LimitReset(
    clock:
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}',
    remaining: hours > 0 ? '$hours h $rest min' : '$minutes min',
  );
}

/// Port of `scheduledRetryDelay`: how long to wait for the reset, or null when
/// there is none, it has passed, or the timer could not hold it.
Duration? scheduledRetryDelay(double? resetsAtSeconds, DateTime now) {
  if (resetsAtSeconds == null) return null;
  final ms = (resetsAtSeconds * 1000).round() - now.millisecondsSinceEpoch;
  if (ms <= 0 || ms > _maxTimerMilliseconds) return null;
  return Duration(milliseconds: ms);
}

/// Port of `formatErrorDiagnostics`: the block «Copiar detalles» copies.
///
/// Without a [surface] (an older gateway) the layer, code, retryable and reset
/// lines are left out: there is nothing real to put in them. Never writes the
/// key variable, a billing URL or the gateway's free-text message.
String formatErrorDiagnostics({
  required DateTime now,
  required TurnErrorSurface? surface,
  required String? composerProvider,
  required String? composerModel,
  required String appVersion,
  required String error,
}) {
  final provider = surface?.provider ?? _nonBlank(composerProvider);
  final model = surface?.model ?? _nonBlank(composerModel);
  final resetsAt = surface?.resetsAt;
  return [
    '── Hermes error details ──',
    'time: ${now.toUtc().toIso8601String()}',
    if (surface != null) ...[
      'layer: ${surface.layer}',
      'code: ${surface.code}',
      'retryable: ${surface.retryable}',
    ],
    if (resetsAt != null)
      'resets_at: ${DateTime.fromMillisecondsSinceEpoch((resetsAt * 1000).round(), isUtc: true).toIso8601String()}',
    if (provider != null) 'provider: $provider',
    if (model != null) 'model: $model',
    'app: $appVersion',
    'error: $error',
  ].join('\n');
}

final _providerWait = RegExp(
  r'^(?:⏳|⚠|↻|⚙)\s*(?:(?:still\s+)?waiting on|loading|processing prompt|no (?:output|response)|model returned|rate limited|provider (?:overloaded|temporarily unavailable))',
  caseSensitive: false,
);

/// Port of `providerWaitText`: the only `thinking.delta` texts that are the
/// core explaining a provider wait; every other one is a decorative spinner
/// phrase. Null when [raw] is not one.
String? providerWaitText(String raw) {
  final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (!_providerWait.hasMatch(line)) return null;
  return line.length <= _maxWaitTextLength
      ? line
      : line.substring(0, _maxWaitTextLength);
}

final _envName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');

String _text(Object? value) => value is String ? value.trim() : '';

String? _identity(Object? value) {
  final text = _text(value);
  return text.isEmpty || text.length > _maxIdentityLength ? null : text;
}

String? _nonBlank(String? value) {
  final text = value?.trim() ?? '';
  return text.isEmpty ? null : text;
}
