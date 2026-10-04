/// Surface that originated a prompt, sent to the Hermes server as optional
/// `prompt.submit` metadata. Ordinary typed turns never carry one.
final class PromptClientSurface {
  /// Wire value of `ClientSurface.voice_live` in the Hermes gateway contract.
  static const String voiceLiveSurface = 'voice-live';

  /// Server-side cap for `voice_context`; longer text is cut, not rejected.
  static const int maxVoiceContextChars = 6000;

  final String surface;
  final String? voiceContext;

  const PromptClientSurface({required this.surface, this.voiceContext});

  const PromptClientSurface.voiceLive({String? voiceContext})
    : this(surface: voiceLiveSurface, voiceContext: voiceContext);

  /// Keys merged into the `prompt.submit` params. `voice_context` is sent only
  /// when non-empty and is clamped to [maxVoiceContextChars].
  Map<String, dynamic> toParams() {
    final context = voiceContext;
    return {
      'surface': surface,
      if (context != null && context.trim().isNotEmpty)
        'voice_context': context.length > maxVoiceContextChars
            ? context.substring(0, maxVoiceContextChars)
            : context,
    };
  }
}

/// Merges optional [extra] metadata into the fixed `prompt.submit` [base].
///
/// The base keys (`session_id`, `text`, `client_turn_id`, `queued`,
/// `interrupted`) always win and keep their position, so metadata can add keys
/// but never replace or reorder what routing and idempotency rely on. With an
/// empty [extra] the result is the base, key for key.
Map<String, dynamic> mergePromptSubmitParams(
  Map<String, dynamic> base,
  Map<String, dynamic> extra,
) => {
  ...base,
  for (final entry in extra.entries)
    if (!base.containsKey(entry.key)) entry.key: entry.value,
};
