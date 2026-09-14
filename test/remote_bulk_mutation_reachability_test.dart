import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('no screen or repository exposes remote bulk cleanup or stop-all', () {
    final settings = source('lib/core/screens/settings_screen.dart');
    final sessions = source('lib/core/screens/session_list_screen.dart');
    final cron = source('lib/core/screens/cron_screen.dart');
    final cronRepository = source('lib/core/services/cron_repository.dart');
    final sessionDeletion = source('lib/core/services/session_deletion.dart');
    final agents = source('lib/core/screens/agent_center_screen.dart');

    expect(settings, isNot(contains("ValueKey('history-cleanup-cron')")));
    expect(settings, isNot(contains('Future<void> _clearCron()')));
    expect(settings, isNot(contains('deleteCronConversations(')));

    expect(sessions, isNot(contains("value: 'cleanup'")));
    expect(sessions, isNot(contains("ValueKey('session-cleanup-surface')")));
    expect(sessions, isNot(contains('Future<void> _promptCleanup()')));
    expect(sessions, isNot(contains('_bulkDelete(')));

    expect(cron, isNot(contains("ValueKey('cron-cleanup-conversations')")));
    expect(cron, isNot(contains('Future<void> _cleanCronConversations()')));
    expect(cron, isNot(contains('deleteCronConversations(')));
    for (final forbidden in const [
      'CronConversationCleanupPreview',
      'CronConversationCleanupResult',
      'cronSessionsSafeForCleanup',
      'previewConversationCleanup(',
      'deleteCronConversations(',
      'sessions/bulk-delete',
    ]) {
      expect(cronRepository, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(sessionDeletion, isNot(contains('sessionsSafeForBulkDelete')));
    expect(sessionDeletion, isNot(contains('cronResults')));

    expect(agents, isNot(contains("ValueKey('agent-center-stop-all')")));
    expect(agents, isNot(contains('Future<void> _stopAllProcesses()')));
    expect(RegExp(r'killBackgroundProcess\(').allMatches(agents), hasLength(1));
  });

  test('explicit one-target mutations remain wired', () {
    final settings = source('lib/core/screens/settings_screen.dart');
    final sessions = source('lib/core/screens/session_list_screen.dart');
    final cron = source('lib/core/screens/cron_screen.dart');
    final agents = source('lib/core/screens/agent_center_screen.dart');

    expect(settings, contains("ValueKey('history-cleanup-normal')"));
    expect(settings, contains('clearProfileLocalConversationState('));
    expect(settings, contains('profile: targetProfile'));

    expect(sessions, contains('_confirmAndDeleteSession(Session session)'));
    expect(
      sessions,
      contains('_client.deleteSession(sessionId, profile: ownerProfile)'),
    );
    expect(sessions, contains('await _confirmAndDeleteSession(session);'));

    expect(cron, contains('Future<void> _delete(CronJob job)'));
    expect(cron, contains('_client.deleteCronJob(job.id, profile: _profile)'));
    expect(cron, contains("value: 'delete'"));

    expect(
      agents,
      contains('_stopProcess(BackgroundProcessEntry process, int ordinal)'),
    );
    expect(agents, contains('process.opaqueId,'));
    expect(agents, contains(': () => _stopProcess('));
  });
}
