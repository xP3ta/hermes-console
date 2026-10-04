// Pure helpers of the GPT-Live contract shared with Hermes Desktop
// (`voice-live.ts`, `use-voice-live-conversation.ts`). No I/O, no clocks.

/// Voice mode reported by `GET /api/audio/voice-live/status`. Informational:
/// the local opt-in, not this value, decides whether a session starts.
enum VoiceLiveMode { chained, gptLive }

/// Parsed, non-secret status of the server's GPT-Live capability.
final class VoiceLiveStatus {
  final VoiceLiveMode mode;
  final bool available;
  final String? reason;
  final String? model;
  final String? voice;

  const VoiceLiveStatus({
    required this.mode,
    required this.available,
    this.reason,
    this.model,
    this.voice,
  });
}

bool _truthy(Object? value) {
  if (value == null || value == false) return false;
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  return true;
}

String? _optionalString(Object? value) => value?.toString();

/// Desktop `fetchVoiceLiveStatus` parser: `null` unless the body is an object
/// with `ok == true`; `mode` is gpt-live only on an exact match.
VoiceLiveStatus? parseVoiceLiveStatus(Object? body) {
  if (body is! Map || body['ok'] != true) return null;
  return VoiceLiveStatus(
    mode: body['mode'] == 'gpt-live'
        ? VoiceLiveMode.gptLive
        : VoiceLiveMode.chained,
    available: _truthy(body['available']),
    reason: _optionalString(body['reason']),
    model: _optionalString(body['model']),
    voice: _optionalString(body['voice']),
  );
}

enum VoiceLiveSpeaker { user, assistant }

/// One transcript delta from the live voice model.
final class VoiceLiveFragment {
  final VoiceLiveSpeaker speaker;
  final String text;
  final int startMs;
  final int endMs;

  const VoiceLiveFragment({
    required this.speaker,
    required this.text,
    required this.startMs,
    required this.endMs,
  });
}

String collapseWhitespace(String text) =>
    text.replaceAll(RegExp(r'\s+'), ' ').trim();

const int _historyMaxMessages = 24;
const int _historyMaxChars = 6000;
const int _historyMaxCharsPerMessage = 1200;

bool _hiddenMessage(Map<String, dynamic> message) {
  if (message['_pipeline'] == true || message['hidden'] == true) return true;
  final kind = message['display_kind'];
  return kind is String && kind.trim().isNotEmpty;
}

/// Newest text turns of the chat as `session.input` items, oldest first.
/// User/assistant only, non-hidden, whitespace-collapsed, each at most 1 200
/// characters, at most 24 messages and 6 000 characters in total.
List<Map<String, dynamic>> toLiveHistory(List<Map<String, dynamic>> messages) {
  final picked = <Map<String, dynamic>>[];
  var total = 0;
  for (var i = messages.length - 1; i >= 0; i--) {
    if (picked.length >= _historyMaxMessages) break;
    final message = messages[i];
    final role = message['role'];
    if (role != 'user' && role != 'assistant') continue;
    if (_hiddenMessage(message)) continue;
    var text = collapseWhitespace((message['content'] ?? '').toString());
    if (text.isEmpty) continue;
    if (text.length > _historyMaxCharsPerMessage) {
      text = text.substring(0, _historyMaxCharsPerMessage);
    }
    if (total + text.length > _historyMaxChars) break;
    total += text.length;
    picked.add({
      'type': 'message',
      'role': role,
      'content': [
        {'type': role == 'user' ? 'input_text' : 'output_text', 'text': text},
      ],
    });
  }
  return picked.reversed.toList(growable: false);
}

const int _commentaryMaxChars = 1400;

/// Splits speech text into chunks the vendor accepts for
/// `session.commentary.append` (about 500 tokens): whitespace collapsed, at
/// most 1 400 characters per chunk, cut on sentence boundaries first and
/// hard-split only for a single sentence longer than the cap.
List<String> chunkForCommentary(String text) {
  final clean = collapseWhitespace(text);
  if (clean.isEmpty) return const [];
  if (clean.length <= _commentaryMaxChars) return [clean];
  final chunks = <String>[];
  var current = '';
  void flush() {
    if (current.isNotEmpty) chunks.add(current);
    current = '';
  }

  for (final sentence in clean.split(RegExp(r'(?<=[.!?])\s+'))) {
    if (sentence.length > _commentaryMaxChars) {
      flush();
      for (var i = 0; i < sentence.length; i += _commentaryMaxChars) {
        final end = i + _commentaryMaxChars;
        chunks.add(
          sentence.substring(i, end > sentence.length ? sentence.length : end),
        );
      }
      continue;
    }
    final joined = current.isEmpty ? sentence : '$current $sentence';
    if (joined.length > _commentaryMaxChars) {
      flush();
      current = sentence;
    } else {
      current = joined;
    }
  }
  flush();
  return chunks;
}

/// What a delegation hands to Hermes: the last user utterance as the turn
/// text and the recent spoken transcript as model-only context.
typedef VoiceLiveDelegationPrompt = ({String prompt, String voiceContext});

VoiceLiveDelegationPrompt delegationPrompt(List<VoiceLiveFragment> fragments) {
  final merged = <({VoiceLiveSpeaker speaker, StringBuffer text})>[];
  for (final fragment in fragments) {
    if (merged.isNotEmpty && merged.last.speaker == fragment.speaker) {
      merged.last.text.write(fragment.text);
    } else {
      merged.add((
        speaker: fragment.speaker,
        text: StringBuffer(fragment.text),
      ));
    }
  }
  final lines = <String>[];
  var lastUser = '';
  for (final entry in merged) {
    final text = collapseWhitespace(entry.text.toString());
    if (text.isEmpty) continue;
    final isUser = entry.speaker == VoiceLiveSpeaker.user;
    if (isUser) lastUser = text;
    lines.add('${isUser ? 'User' : 'Voice assistant'}: $text');
  }
  final voiceContext = lines.join('\n');
  var prompt = lastUser;
  if (prompt.isEmpty && voiceContext.isNotEmpty) {
    prompt = voiceContext.length > 400
        ? voiceContext.substring(voiceContext.length - 400)
        : voiceContext;
  }
  return (prompt: prompt, voiceContext: voiceContext);
}
