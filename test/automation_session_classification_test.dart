import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/models/session_category.dart';

Session _row(String id, String source, {String title = ''}) => Session(
  id: id,
  title: title,
  model: '',
  source: source,
  messageCount: 2,
  isActive: false,
  preview: title,
  startedAt: 1,
);

void main() {
  // Every source present on the owner's server plus the rest of Desktop's
  // SIDEBAR_EXCLUDED_SOURCES: where each one lands.
  const automation = <String>[
    'cron',
    'oneshot',
    'tool',
    'kanban',
    'subagent',
    'acp',
    'webhook',
  ];
  const chats = <String>['desktop', 'cli', 'bot_room', 'api_server', 'mobile'];

  for (final source in automation) {
    test('source "$source" is an automation run, never a chat', () {
      final row = _row('x-$source', source);
      expect(row.isAutomation, isTrue);
      expect(SessionCategory.automation.includesSource(source), isTrue);
      expect(SessionCategory.chats.includesSource(source), isFalse);
      expect(SessionCategory.chats.excludeSources, contains(source));
    });
  }

  for (final source in chats) {
    test('source "$source" is a chat, never an automation run', () {
      final row = _row('x-$source', source);
      expect(row.isAutomation, isFalse);
      expect(SessionCategory.chats.includesSource(source), isTrue);
      expect(SessionCategory.automation.sources, isNot(contains(source)));
    });
  }

  test('id and title never override the server source', () {
    expect(_row('cron_job_20260920_090000', 'desktop').isAutomation, isFalse);
    expect(
      _row('k', 'desktop', title: 'work kanban task t_42').isAutomation,
      isFalse,
    );
    expect(_row('plain', 'cron').isAutomation, isTrue);
  });

  test('Home recents and the drawer use the same source classifier', () {
    final drawer = File(
      'lib/core/widgets/hermes_drawer.dart',
    ).readAsStringSync();
    expect(drawer, contains('!session.isAutomation'));
    expect(drawer, isNot(contains('.isKanbanJob')));
    final home = File(
      'lib/core/screens/home_dashboard_screen.dart',
    ).readAsStringSync();
    expect(
      home.replaceAll(RegExp(r'\s+'), ' '),
      contains(
        'static bool _isHomeRecentKind(Session s) => '
        '!s.isAutomation && s.listsAsOwnRow;',
      ),
    );
  });
}
