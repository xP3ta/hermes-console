import 'dart:convert';

import '../models/session.dart';
import '../services/session_reconciler.dart';
import 'chat_turn.dart';
import 'markdown_clipboard.dart';

enum HomeRecentDateGroup { today, yesterday, earlier }

class HomeRecentSummary {
  final String? user;
  final String? assistant;

  const HomeRecentSummary({this.user, this.assistant});

  bool get isEmpty => user == null && assistant == null;
}

int homeRecentSessionLimit({
  required double viewportHeight,
  required double textScale,
}) {
  final base = viewportHeight >= 760
      ? 8
      : viewportHeight >= 680
      ? 7
      : 6;
  if (textScale >= 1.3) return 6;
  if (textScale >= 1.15 && base > 7) return 7;
  return base;
}

HomeRecentDateGroup homeRecentDateGroup(double timestamp, DateTime now) {
  if (timestamp <= 0) return HomeRecentDateGroup.earlier;
  final date = DateTime.fromMillisecondsSinceEpoch((timestamp * 1000).round());
  if (_sameDate(date, now)) return HomeRecentDateGroup.today;
  final yesterday = DateTime(now.year, now.month, now.day - 1);
  if (_sameDate(date, yesterday)) return HomeRecentDateGroup.yesterday;
  return HomeRecentDateGroup.earlier;
}

String? homeRecentPreview({
  required String title,
  required Session session,
  String? userPreview,
  String? assistantPreview,
}) {
  final summary = homeRecentSummary(
    title: title,
    session: session,
    userPreview: userPreview,
    assistantPreview: assistantPreview,
  );
  return summary.assistant ?? summary.user;
}

HomeRecentSummary homeRecentSummary({
  required String title,
  required Session session,
  String? userPreview,
  String? assistantPreview,
}) {
  final comparableTitle = _comparisonText(title);
  final compactUser = _compactPreview(
    userPreview ?? session.lastUserPreview ?? session.cleanPreview,
  );
  final compactAssistant = _compactPreview(
    assistantPreview ?? session.lastAssistantPreview ?? '',
  );

  final user = _withoutTitleDuplicate(compactUser, comparableTitle);
  final assistant = _withoutDuplicate(
    compactAssistant,
    comparableTitle: comparableTitle,
    comparableUser: _comparisonText(user ?? ''),
  );
  return HomeRecentSummary(user: user, assistant: assistant);
}

String? humanReadableSessionPreview(String? value) =>
    value == null ? null : _compactPreview(value);

String? sessionListPreview(Session session) {
  for (final candidate in [
    session.cleanPreview,
    session.lastAssistantPreview ?? '',
    session.lastUserPreview ?? '',
  ]) {
    final compact = _compactPreview(candidate);
    if (compact != null) return compact;
  }
  return null;
}

String? latestUserPreview(
  Iterable<Map<String, dynamic>> messages, {
  bool newestFirst = false,
}) => _latestRolePreview(messages, role: 'user', newestFirst: newestFirst);

String? latestAssistantPreview(
  Iterable<Map<String, dynamic>> messages, {
  bool newestFirst = false,
}) => _latestRolePreview(messages, role: 'assistant', newestFirst: newestFirst);

String? _latestRolePreview(
  Iterable<Map<String, dynamic>> messages, {
  required String role,
  required bool newestFirst,
}) {
  final ordered = newestFirst
      ? messages
      : messages.toList(growable: false).reversed;
  for (final message in ordered) {
    if (message['role']?.toString().toLowerCase() != role) continue;
    if (role == 'user' && !isRealUserTurn(message)) continue;
    final displayKind = message['display_kind']?.toString().trim() ?? '';
    if (role == 'assistant' &&
        const {'hidden', 'reasoning', 'system', 'tool', 'internal'}
            .contains(displayKind)) {
      continue;
    }
    final raw =
        desktopSessionDisplayText(message['content']) ??
        desktopSessionDisplayText(message['text']);
    final compact = _compactPreview(raw ?? '');
    if (compact != null) return compact;
  }
  return null;
}

String? _withoutTitleDuplicate(String? value, String comparableTitle) {
  if (value == null || comparableTitle.isEmpty) return value;
  final comparable = _comparisonText(value);
  if (comparable.isEmpty ||
      comparable == comparableTitle ||
      comparable.startsWith('$comparableTitle ') ||
      comparableTitle.startsWith('$comparable ')) {
    return null;
  }
  return value;
}

String? _withoutDuplicate(
  String? value, {
  required String comparableTitle,
  required String comparableUser,
}) {
  if (value == null) return null;
  final comparable = _comparisonText(value);
  if (comparable.isEmpty ||
      (comparableTitle.isNotEmpty && comparable == comparableTitle) ||
      (comparableUser.isNotEmpty && comparable == comparableUser)) {
    return null;
  }
  return value;
}

bool _sameDate(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

String? _compactPreview(String value) {
  final raw = value.trim();
  if (raw.isEmpty || _isNonHumanPreview(raw)) return null;
  final compact = markdownToCompactText(
    Session.stripCronPreamble(raw),
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.isEmpty || _isNonHumanPreview(compact)) return null;
  final lower = compact.toLowerCase();
  if (lower == 'operation interrupted.' ||
      lower.startsWith('operation interrupted:')) {
    return null;
  }
  final runes = compact.runes.toList(growable: false);
  if (runes.length <= 320) return compact;
  return '${String.fromCharCodes(runes.take(319))}…';
}

bool _isNonHumanPreview(String value) {
  final lower = value.toLowerCase();
  if (lower.startsWith('<system-reminder') ||
      lower.startsWith('<system>') ||
      lower.startsWith('<tool_') ||
      lower.startsWith('<reasoning>') ||
      lower.startsWith('[system:') ||
      lower.startsWith('[continuing toward your standing goal') ||
      lower.startsWith('[your active task list was preserved') ||
      lower.startsWith('[async delegation')) {
    return true;
  }
  if (effectiveUserDisplayKind({
    'role': 'user',
    'content': value,
  }).isNotEmpty) {
    return true;
  }
  if (!value.startsWith('[') && !value.startsWith('{')) return false;
  try {
    final decoded = jsonDecode(value);
    return decoded is List || decoded is Map;
  } on FormatException {
    return RegExp(
      r'^\[\s*\{\s*"(?:id|type|function|tool_call_id|tool_use_id)"',
      caseSensitive: false,
    ).hasMatch(value);
  }
}

String _comparisonText(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[áàäâã]'), 'a')
    .replaceAll(RegExp(r'[éèëê]'), 'e')
    .replaceAll(RegExp(r'[íìïî]'), 'i')
    .replaceAll(RegExp(r'[óòöôõ]'), 'o')
    .replaceAll(RegExp(r'[úùüû]'), 'u')
    .replaceAll('ñ', 'n')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();
