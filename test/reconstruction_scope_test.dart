import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _between(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex, greaterThanOrEqualTo(0));
  expect(endIndex, greaterThan(startIndex));
  return source.substring(startIndex, endIndex);
}

String _classBody(String source, String declaration) {
  final start = source.indexOf(declaration);
  expect(start, greaterThanOrEqualTo(0));
  final open = source.indexOf('{', start + declaration.length);
  expect(open, greaterThan(start));
  var depth = 0;
  for (var index = open; index < source.length; index++) {
    if (source.codeUnitAt(index) == 123) depth++;
    if (source.codeUnitAt(index) == 125 && --depth == 0) {
      return source.substring(start, index + 1);
    }
  }
  fail('Unbalanced class body for $declaration');
}

void main() {
  test(
    'Home recent previews never reconstruct missing text from transcripts',
    () {
      final source = File(
        'lib/core/screens/home_dashboard_screen.dart',
      ).readAsStringSync();
      final hydration = _between(
        source,
        'Future<void> _hydrateTurnPreviews(',
        'String _recentGroupLabel(',
      );

      expect(hydration, isNot(contains('.getMessages(')));
      expect(hydration, isNot(contains('latestUserPreview(messages')));
      expect(hydration, isNot(contains('latestAssistantPreview(messages')));
    },
  );

  test('secondary SessionDetail has no transcript reconstruction surface', () {
    final source = File(
      'lib/core/screens/session_detail_screen.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('.getMessages(')));
    expect(source, isNot(contains('_messages')));
    expect(source, isNot(contains('_MessageTile')));
    expect(source, isNot(contains('_resolveSessionArtifacts')));
    expect(source, isNot(contains('SessionArtifactsSheet')));
  });

  test('Cron notifications never reconstruct text from session messages', () {
    final source = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final preview = _between(
      source,
      'static String? notificationPreview(',
      'static bool shouldNotifyResult(',
    );

    expect(preview, isNot(contains('getSessionMessages')));
    expect(preview, isNot(contains('getMessages')));
    expect(preview, isNot(contains('latestAssistantPreview')));
  });

  test('subagent rows render generic identity and status only', () {
    final source = File(
      'lib/core/widgets/subagent_activity_card.dart',
    ).readAsStringSync();
    final row = _classBody(source, 'class _SubagentRow');

    expect(row, isNot(contains('activity.goalPreview')));
    expect(row, isNot(contains('activity.resultPreview')));
    expect(row, isNot(contains('activity.details.detailPreview')));
    expect(row, isNot(contains('activity.details.activeToolName')));
  });
}
