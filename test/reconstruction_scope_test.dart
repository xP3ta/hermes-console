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
      // Home paints the session list's own preview (sessionListPreview, the
      // Desktop sidebar rule); it never reads a transcript to fill one in.
      expect(source, isNot(contains('_hydrateTurnPreviews')));
      expect(source, isNot(contains('.getMessages(')));
      expect(source, isNot(contains('latestUserPreview(')));
      expect(source, isNot(contains('latestAssistantPreview(')));
      expect(source, contains('sessionListPreview('));
    },
  );

  test('the list preview consumes only the canonical session preview', () {
    // Desktop's sidebar (session-row.tsx) paints `session.preview` and
    // nothing else: no last-turn fallback on Home or Conversations.
    final helpers = File(
      'lib/core/utils/home_recent_sessions.dart',
    ).readAsStringSync();
    final start = helpers.indexOf('String? sessionListPreview(Session');
    expect(start, isNonNegative);
    final body = helpers.substring(start, helpers.indexOf('\n}\n', start));
    expect(body, contains('.cleanPreview'));
    expect(body, isNot(contains('lastAssistantPreview')));
    expect(body, isNot(contains('lastUserPreview')));
    for (final screen in [
      'lib/core/screens/home_dashboard_screen.dart',
      'lib/core/screens/session_list_screen.dart',
    ]) {
      final source = File(screen).readAsStringSync();
      expect(source, contains('sessionListPreview('), reason: screen);
      expect(source, isNot(contains('homeRecentSummary(')), reason: screen);
      // No fabricated line where Desktop paints none.
      expect(
        source,
        isNot(contains('sessionPreviewUnavailable')),
        reason: screen,
      );
    }
    final home = File(
      'lib/core/screens/home_dashboard_screen.dart',
    ).readAsStringSync();
    expect(home, isNot(contains('.lastAssistantPreview')));
    expect(home, isNot(contains('.lastUserPreview')));
  });

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
    final row = _classBody(source, 'class _SubagentListRow');

    expect(row, isNot(contains('activity.goalPreview')));
    expect(row, isNot(contains('activity.resultPreview')));
    expect(row, isNot(contains('activity.details.detailPreview')));
    expect(row, isNot(contains('activity.details.activeToolName')));
  });
}
