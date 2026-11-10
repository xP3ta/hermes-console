import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The bottom sheets the main UI keeps, with how many calls each file may
/// make. Every other file must have none, and these files exactly this many:
/// a new sheet, or a stale entry here, fails.
///
/// `chat_workspace_host.dart`: `showChatWorkspaceSheet`, approved by the owner in
/// mock 136 v2-A §4 (and confirmed in ORDEN-OLAS-PULIDO): on a narrow screen
/// a workspace panel (Terminal, Files, Git, Browser) opens as a sheet over
/// the dimmed chat, as in Cadu. It is not controls detached from what opened
/// them, which is what this rule guards against: it is a whole screen in
/// place of the page that used to open over the chat. It stays modal on
/// purpose: a non-modal panel over 92 % of a phone would leave a chat
/// nobody can see taking touches, and dragging it would fight the terminal
/// and the lists, which use the vertical drags.
const _allowedSheets = {
  'lib/core/widgets/workspace/chat_workspace_host.dart': 1,
  // Explicit owner request: T3-style Agents roster opened by the lower pill.
  'lib/core/widgets/subagent_activity_card.dart': 1,
};

void main() {
  test('user-facing core UI does not introduce modal bottom sheets', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: 'lib must exist');

    final violations = <String>[];
    final found = <String, int>{};
    for (final entity in lib.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = _withoutComments(entity.readAsStringSync());
      final count = _bottomSheetSurface.allMatches(source).length;
      if (count == 0) continue;
      final path = entity.path.replaceAll(r'\', '/');
      found[path] = count;
      if (_allowedSheets[path] != count) violations.add('$path ($count)');
    }
    for (final MapEntry(key: path, value: count) in _allowedSheets.entries) {
      if (found[path] != count) {
        violations.add('$path: expected $count, found ${found[path] ?? 0}');
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Use showHermesFloatingSurface for user-facing modal UI. '
          'Bottom sheets make controls feel detached from the element that '
          'opened them: ${violations.join(', ')}',
    );
  });
}

final _bottomSheetSurface = RegExp(
  r'\b(?:showModalBottomSheet|showBottomSheet)\s*'
  r'(?:<[^>{}()]*>)?\s*\(|\bBottomSheet\s*\(',
);

String _withoutComments(String source) {
  return source
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r'//[^\r\n]*'), '');
}
