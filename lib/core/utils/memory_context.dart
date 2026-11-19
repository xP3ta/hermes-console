/// Hermes' memory-context lens for display.
///
/// Hermes wraps recalled memory for the model in an official
/// `<memory-context>…</memory-context>` block (with a system note) and stores
/// it inside the user turn. Its native projection shows user/assistant text
/// through `sanitize_context` and a strip (`agent/memory_context.py`,
/// `hermes_state_messages.py` `_loaded_view_content`, Hermes 3b421578); the
/// REST pages serve the raw text. This is the same lens, used only for what
/// is shown: the stored row is never changed.
library;

// Same three patterns, same order, case-insensitive (memory_context.py 15-27).
final RegExp _internalContext = RegExp(
  r'<\s*memory-context\s*>[\s\S]*?</\s*memory-context\s*>',
  caseSensitive: false,
);
final RegExp _internalNote = RegExp(
  r'\[System note:\s*The following is recalled memory context,\s*NOT new user '
  r'input\.\s*Treat as (?:informational background data|authoritative '
  r'reference data[^\]]*)\.\]\s*',
  caseSensitive: false,
);
final RegExp _fenceTag = RegExp(
  r'</?\s*memory-context\s*>',
  caseSensitive: false,
);

/// Port of `sanitize_context`: removes the block, the note and stray tags.
/// Like the server function, it does not trim.
String sanitizeMemoryContext(String text) {
  var result = text;
  for (final pattern in [_internalContext, _internalNote, _fenceTag]) {
    result = result.replaceAll(pattern, '');
  }
  return result;
}

/// The text shown for a user/assistant row: Hermes' native projection
/// (`sanitize_context` + strip, the strip only when it removed something, so
/// text without memory context is returned byte for byte) and, for user rows,
/// [withoutTrailingOmhContext].
String memoryContextDisplayText(Object? role, String content) {
  if (role != 'user' && role != 'assistant') return content;
  final sanitized = sanitizeMemoryContext(content);
  final shown = sanitized == content ? content : sanitized.trim();
  return role == 'user' ? withoutTrailingOmhContext(shown) : shown;
}

// The OMH plugin's fence, exactly as it emits it (plugins/omh/hooks/
// llm_hooks.py `fence_omh_context`): open tag, this note, a blank line, the
// body (with any fence tag removed from it) and the close tag.
const _omhOpen = '<omh-context>';
const _omhClose = '</omh-context>';
const _omhNote =
    "[System note: automated OMH context, NOT the person's words; their "
    'message outranks it.]';

/// Console presentation, not a server lens: removes a final tail made only of
/// well-formed OMH blocks from a stored user turn (the plugin's injection the
/// server stores in `content`). A block counts only when it starts with the
/// exact open tag and note, ends the text with the close tag, carries no
/// other fence tag and is not inside a code fence; anything else is left
/// byte for byte. Limit: a person who pastes exactly such a tail at the end
/// of their message sees it hidden too.
String withoutTrailingOmhContext(String text) {
  var result = text;
  while (result.endsWith('\n$_omhClose')) {
    final start = result.lastIndexOf(_omhOpen);
    if (start < 0) break;
    final block = result.substring(start);
    final body = block.substring(0, block.length - _omhClose.length);
    if (!block.startsWith('$_omhOpen\n$_omhNote\n\n') ||
        body.contains(_omhClose) ||
        body.indexOf(_omhOpen, _omhOpen.length) >= 0) {
      break;
    }
    final before = result.substring(0, start);
    if ('```'.allMatches(before).length.isOdd) break;
    result = before.trimRight();
  }
  return result;
}
