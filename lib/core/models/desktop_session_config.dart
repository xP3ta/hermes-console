/// Session-scoped configuration values accepted by Hermes Desktop 0.19.
///
/// These models are deliberately transport-only. They never represent global
/// Hermes defaults and contain no provider credentials.
enum DesktopSessionConfigKey {
  model('model'),
  reasoning('reasoning'),
  fast('fast');

  const DesktopSessionConfigKey(this.wire);

  final String wire;
}

enum DesktopReasoningEffort {
  none,
  minimal,
  low,
  medium,
  high,
  xhigh,
  max,
  ultra;

  String get wire => name;
}

enum DesktopFastMode {
  fast,
  normal;

  String get wire => name;

  bool get enabled => this == DesktopFastMode.fast;
}

/// A model/provider pair selected from the authenticated model catalog.
///
/// Hermes parses the model command value into flags. Free-form whitespace,
/// controls and flag delimiters are rejected locally so catalog text cannot
/// inject another option into the command grammar.
final class DesktopModelSelection {
  final String modelId;
  final String providerSlug;

  factory DesktopModelSelection({
    required String modelId,
    required String providerSlug,
  }) => DesktopModelSelection._(
    _validatedIdentifier(modelId, 'model', maxLength: 256),
    _validatedIdentifier(providerSlug, 'provider', maxLength: 128),
  );

  const DesktopModelSelection._(this.modelId, this.providerSlug);

  String get sessionWireValue => '$modelId --provider $providerSlug --session';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopModelSelection &&
          modelId == other.modelId &&
          providerSlug == other.providerSlug;

  @override
  int get hashCode => Object.hash(modelId, providerSlug);

  @override
  String toString() =>
      'DesktopModelSelection(model: $modelId, provider: $providerSlug)';
}

/// Explicit configuration captured before creating a new live runtime.
///
/// Null fields preserve server/profile inheritance. In particular, an explicit
/// [DesktopFastMode.normal] must be serialized as `fast: false`, not omitted.
final class DesktopSessionCreateConfig {
  final DesktopModelSelection? model;
  final DesktopReasoningEffort? reasoningEffort;
  final DesktopFastMode? fastMode;
  final String? title;
  final bool hidden;
  final bool createIfMissing;
  final bool allowTransportFallback;

  /// Server-side working directory for a new chat started from a project or
  /// worktree. Sent as `cwd` + `cwd_explicit: true` on `session.create`, the
  /// same pair Hermes Desktop sends for a workspace-anchored new session.
  final String? workspace;

  const DesktopSessionCreateConfig({
    this.model,
    this.reasoningEffort,
    this.fastMode,
    this.title,
    this.hidden = false,
    this.createIfMissing = true,
    this.allowTransportFallback = true,
    this.workspace,
  });

  bool get isEmpty =>
      model == null &&
      reasoningEffort == null &&
      fastMode == null &&
      title == null &&
      !hidden &&
      createIfMissing &&
      allowTransportFallback &&
      workspace == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopSessionCreateConfig &&
          model == other.model &&
          reasoningEffort == other.reasoningEffort &&
          fastMode == other.fastMode &&
          title == other.title &&
          hidden == other.hidden &&
          createIfMissing == other.createIfMissing &&
          allowTransportFallback == other.allowTransportFallback &&
          workspace == other.workspace;

  @override
  int get hashCode => Object.hash(
    model,
    reasoningEffort,
    fastMode,
    title,
    hidden,
    createIfMissing,
    allowTransportFallback,
    workspace,
  );
}

/// Structurally validated acknowledgement from `config.set`.
///
/// The acknowledgement confirms that the command was accepted. Effective
/// state still comes from a subsequent `session.info` for the same runtime.
final class DesktopConfigSetResult {
  final DesktopSessionConfigKey key;
  final String value;
  final String? warning;
  final bool confirmRequired;
  final String? confirmMessage;

  /// `config.set model` during a running turn: Hermes queues the pick and
  /// applies it when the next turn starts (`pending_model_switch`).
  final bool deferred;

  const DesktopConfigSetResult({
    required this.key,
    required this.value,
    this.warning,
    this.confirmRequired = false,
    this.confirmMessage,
    this.deferred = false,
  });

  factory DesktopConfigSetResult.fromJson(
    Map<String, dynamic> json, {
    required DesktopSessionConfigKey expectedKey,
  }) {
    if (json['key'] != expectedKey.wire) {
      throw const FormatException('Unexpected session config key');
    }
    final scope = json['scope'];
    if (scope != null && scope != 'session') {
      throw const FormatException('Session config response has global scope');
    }
    final value = json['value'];
    if (value is! String || value.trim().isEmpty || value.length > 512) {
      throw const FormatException('Invalid session config value');
    }
    final rawConfirm = json['confirm_required'];
    if (rawConfirm != null && rawConfirm is! bool) {
      throw const FormatException('Invalid session config confirmation flag');
    }
    final confirmRequired = rawConfirm == true;
    final warning = _boundedOptionalText(json['warning'], 'warning');
    // `confirm_message` is `str | null`; the guard still holds without it
    // (Desktop asks anyway), so fall back to the legacy `warning` text.
    final confirmMessage =
        _boundedOptionalText(json['confirm_message'], 'confirmation message') ??
        (confirmRequired ? warning : null);
    return DesktopConfigSetResult(
      key: expectedKey,
      value: value,
      warning: warning,
      confirmRequired: confirmRequired,
      confirmMessage: confirmMessage,
      deferred: json['deferred'] == true,
    );
  }
}

String _validatedIdentifier(
  String raw,
  String label, {
  required int maxLength,
}) {
  final value = raw.trim();
  if (value.isEmpty || value.length > maxLength) {
    throw FormatException('Invalid $label identifier');
  }
  if (value.contains('--') ||
      value.codeUnits.any((unit) => unit <= 0x20 || unit == 0x7f)) {
    throw FormatException('Unsafe $label identifier');
  }
  return value;
}

String? _boundedOptionalText(Object? raw, String label) {
  if (raw == null || raw == '') return null;
  if (raw is! String || raw.length > 512) {
    throw FormatException('Invalid $label');
  }
  final value = raw.trim();
  return value.isEmpty ? null : value;
}
