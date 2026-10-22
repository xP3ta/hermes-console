import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/utils/session_title.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const expected = <String, (String, String, String)>{
    'es': ('Tarea programada', 'Tarea del Kanban', 'Conversación'),
    'en': ('Scheduled task', 'Kanban task', 'Conversation'),
    'pt': ('Tarefa agendada', 'Tarefa do Kanban', 'Conversa'),
    'de': ('Geplante Aufgabe', 'Kanban-Aufgabe', 'Unterhaltung'),
    'fr': ('Tâche planifiée', 'Tâche Kanban', 'Conversation'),
    'it': ('Attività pianificata', 'Attività Kanban', 'Conversazione'),
    'ja': ('スケジュールタスク', 'Kanbanタスク', '会話'),
    'ko': ('예약 작업', 'Kanban 작업', '대화'),
    'zh': ('定时任务', '看板任务', '对话'),
  };
  final cron = Session.fromJson({
    'id': 'cron_generic_1',
    'title': null,
    'source': 'cron',
    'preview': '[IMPORTANT: You are running as a scheduled cron job.]',
  });
  final kanban = Session.fromJson({
    'id': '20260627_1',
    'title': 'work kanban task t_aac00edc',
    'source': 'chat',
    'preview': 'work kanban task t_aac00edc',
  });
  final internal = Session.fromJson({
    'id': '20260828_todo',
    'title': '[Your active task list was preserved across context compression]',
    'preview': '[Your active task list was preserved across context compression]',
    'source': 'mobile',
  });
  final named = Session.fromJson({
    'id': 'named_session',
    'title': 'Weekly report',
    'source': 'chat',
  });

  test('the generic title fixture covers exactly the nine supported languages', () {
    expect(expected.keys.toSet(),
        Strings.supportedLocales.map((locale) => locale.languageCode).toSet());
    expect(expected.length, 9);
  });

  for (final entry in expected.entries) {
    test('${entry.key} generic titles use the selected language', () {
      final strings = lookupStrings(Locale(entry.key));
      final scheduled = localizedSessionTitle(strings, cron);
      expect(scheduled, entry.value.$1);
      expect(localizedSessionTitle(strings, kanban), entry.value.$2);
      expect(localizedSessionTitle(strings, internal), entry.value.$3);
      expect(localizedSessionTitle(strings, named), 'Weekly report');
      expect(scheduled == 'Tarea programada', entry.key == 'es');
    });
  }
}
