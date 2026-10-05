import '../../l10n/app_localizations.dart';

/// What the last assistant answer looks like, for the free local chips.
enum QuickReplyContext { question, code, plan, generic }

final _codeFence = RegExp(r'^\s*(?:```|~~~)', multiLine: true);
final _diffMarker = RegExp(
  r'^(?:\+\+\+ |--- a/|--- /|@@ -\d)',
  multiLine: true,
);
final _numberedStep = RegExp(r'^\s*\d+[.)]\s+\S', multiLine: true);
final _planHeading = RegExp(
  r'^\s*(?:#{1,6}\s*)?(?:\*\*)?(?:plan|pasos|steps|next steps|'
  r'siguientes pasos)\b',
  caseSensitive: false,
  multiLine: true,
);
final _trailingDecoration = RegExp(r'[\s*_`)\]»"”’]+$');

QuickReplyContext classifyQuickReplyContext(String answer) {
  final text = answer.trim();
  final tail = text.replaceFirst(_trailingDecoration, '');
  if (tail.endsWith('?') || tail.endsWith('？')) {
    return QuickReplyContext.question;
  }
  if (_codeFence.hasMatch(text) || _diffMarker.hasMatch(text)) {
    return QuickReplyContext.code;
  }
  if (_numberedStep.allMatches(text).length >= 2 ||
      _planHeading.hasMatch(text)) {
    return QuickReplyContext.plan;
  }
  return QuickReplyContext.generic;
}

/// Free, local reply chips for the last assistant [answer] (no model call).
List<String> heuristicQuickReplies(String answer, Strings strings) {
  if (answer.trim().isEmpty) return const [];
  return switch (classifyQuickReplyContext(answer)) {
    QuickReplyContext.question => [
      strings.rpl1215ReplyYes,
      strings.rpl1215ReplyNo,
      strings.rpl1215ReplyExplainMore,
    ],
    QuickReplyContext.code => [
      strings.rpl1215ReplyRunTests,
      strings.rpl1215ReplyReviewChanges,
    ],
    QuickReplyContext.plan => [
      strings.rpl1215ReplyGoAhead,
      strings.rpl1215ReplyStepByStep,
    ],
    QuickReplyContext.generic => [
      strings.rpl1215ReplyContinue,
      strings.rpl1215ReplySummarize,
    ],
  };
}

/// System instructions for the on-tap `llm.oneshot` suggestion request.
const String smartQuickReplyInstructions =
    'Suggest exactly 3 short replies the user could send next in this chat. '
    'Each under 8 words, in the same language as the conversation, one per '
    'line, no numbering, no quotes, no explanations.';

const int _assistantTailChars = 1500;
const int _userTailChars = 600;

String _tail(String text, int max) {
  final trimmed = text.trim();
  if (trimmed.length <= max) return trimmed;
  return '…${trimmed.substring(trimmed.length - max)}';
}

/// The only conversation content sent for smart replies: the tail of the
/// last assistant message and of the user's last message.
String smartQuickReplyInput({
  required String lastAssistant,
  required String lastUser,
}) {
  final user = _tail(lastUser, _userTailChars);
  return [
    if (user.isNotEmpty) 'User said:\n$user',
    'Assistant replied:\n${_tail(lastAssistant, _assistantTailChars)}',
  ].join('\n\n');
}

final _leadingBullet = RegExp(r'^\s*(?:[-*+•·]|\d+[.)])\s*');
final _wrappingQuotes = RegExp(r'''^["“”'«»]+|["“”'«»]+$''');

/// At most three short, distinct replies from the model's text.
List<String> parseSmartQuickReplies(String raw) {
  final replies = <String>[];
  final seen = <String>{};
  for (final line in raw.split('\n')) {
    final reply = line
        .replaceFirst(_leadingBullet, '')
        .trim()
        .replaceAll(_wrappingQuotes, '')
        .trim();
    if (reply.isEmpty || reply.length > 80) continue;
    if (!seen.add(reply.toLowerCase())) continue;
    replies.add(reply);
    if (replies.length == 3) break;
  }
  return List.unmodifiable(replies);
}
