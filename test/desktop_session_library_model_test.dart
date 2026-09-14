import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/models/session_category.dart';

void main() {
  test('taxonomía actual conserva las fuentes internas de automatización', () {
    expect(AutomationSessionSources.values, const [
      'cron',
      'kanban',
      'subagent',
      'tool',
      'acp',
      'hermes_flow',
      'vulcan_delegate',
      'webhook',
    ]);

    for (final source in AutomationSessionSources.values) {
      expect(
        SessionCategory.automation.includesSource(source),
        isTrue,
        reason: '$source debe aparecer en Automatización',
      );
      expect(
        SessionCategory.chats.includesSource(source),
        isFalse,
        reason: '$source no debe consumir una página de Chats',
      );
      expect(SessionCategory.all.includesSource(source), isTrue);
    }
  });

  test('Chats conserva fuentes humanas o futuras y Todo no oculta ninguna', () {
    for (final source in const ['mobile', 'tui', 'telegram', 'custom-source']) {
      expect(SessionCategory.chats.includesSource(source), isTrue);
      expect(SessionCategory.automation.includesSource(source), isFalse);
      expect(SessionCategory.all.includesSource(source), isTrue);
    }

    expect(
      SessionCategory.chats.excludeSources,
      AutomationSessionSources.values,
    );
    expect(SessionCategory.automation.sources, AutomationSessionSources.values);
    expect(SessionCategory.all.sources, isEmpty);
    expect(SessionCategory.all.excludeSources, isEmpty);
    expect(
      SessionCategory.chats.includesSource('api_server'),
      isTrue,
      reason: 'API es un transporte de chat, no una automatización',
    );
    expect(SessionCategory.automation.includesSource('api_server'), isFalse);
  });

  test('Session parsea lineage, perfil, rama, archivo y handoff 0.19', () {
    final session = Session.fromJson({
      'id': 'tip-3',
      '_lineage_root_id': 'root-1',
      'parent_session_id': 'tip-2',
      'title': 'Conversation',
      'preview': 'Preview',
      'model': 'model-a',
      'source': 'mobile',
      'message_count': 7,
      'started_at': 100,
      'last_active': 120,
      'is_active': true,
      'cwd': '/managed/project',
      'git_repo_root': '/managed/project',
      'git_branch': 'feature/mobile',
      'archived': true,
      'profile': 'coding',
      'is_default_profile': false,
      'handoff_platform': 'telegram',
      'handoff_state': 'sent',
      'handoff_error': 'none',
    });

    expect(session.logicalId, 'root-1');
    expect(session.parentSessionId, 'tip-2');
    expect(session.gitBranch, 'feature/mobile');
    expect(session.archived, isTrue);
    expect(session.profile, 'coding');
    expect(session.isDefaultProfile, isFalse);
    expect(session.handoffState, 'sent');
    expect(session.isActive, isTrue);
  });

  test(
    'Session degrada campos opcionales malos sin perder una fila válida',
    () {
      final session = Session.tryParse({
        'id': 'valid-id',
        'title': 42,
        'message_count': -1,
        'started_at': 'bad',
        'input_tokens': double.nan,
        'archived': 'yes',
        'preview': List.filled(3000, 'x').join(),
      });

      expect(session, isNotNull);
      expect(session!.title, 'Untitled');
      expect(session.messageCount, 0);
      expect(session.startedAt, 0);
      expect(session.inputTokens, 0);
      expect(session.archived, isFalse);
      expect(session.preview.runes.length, 2048);
      expect(Session.tryParse({'id': true}), isNull);
    },
  );
}
