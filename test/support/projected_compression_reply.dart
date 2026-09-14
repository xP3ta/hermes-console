/// Contract fixture, not a capture of a private conversation.
/// methods_session._compress_live counts raw history, then session_history's
/// _history_to_messages filters hidden scaffolding and empty tool-call rows.
Map<String, dynamic> projectedCompressionReply({
  String storedSessionId = 'stored-chat',
}) => {
  'status': 'compressed',
  'removed': 4,
  'before_messages': 8,
  'after_messages': 4,
  'before_tokens': 96022,
  'after_tokens': 4821,
  'summary': {
    'noop': false,
    'aborted': false,
    'refused_would_grow': false,
    'fallback_used': false,
    'headline': 'Compressed: 8 → 4 messages',
    'token_line': 'Approx request size: ~96,022 → ~4,821 tokens',
    'note': null,
  },
  'usage': {'context_used': 4821, 'context_max': 200000},
  'info': {'stored_session_id': storedSessionId},
  // The four raw rows include hidden scaffolding + an empty assistant tool
  // invocation; only these two editorial rows cross the official boundary.
  'messages': [
    {'role': 'user', 'text': 'Pregunta conservada'},
    {'role': 'assistant', 'text': 'Respuesta conservada'},
  ],
};
