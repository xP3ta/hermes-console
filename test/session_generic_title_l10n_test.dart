import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/session_title.dart';
import 'package:hermes_android/core/widgets/session_deletion_dialogs.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  final kanban = Session.fromJson({
    'id': '20260627_1',
    'title': 'work kanban task t_aac00edc',
    'source': 'chat',
    'preview': 'work kanban task t_aac00edc',
  });
  final cron = Session.fromJson({
    'id': 'cron_abc_1',
    'title': null,
    'source': 'cron',
    'preview': '[IMPORTANT: You are running as a scheduled cron job.]',
  });
  final internal = Session.fromJson({
    'id': '20260828_todo',
    'title': '[Your active task list was preserved across context compression]',
    'preview':
        '[Your active task list was preserved across context compression]\n'
        '- [>] verify. Run tests (in_progress)',
    'source': 'mobile',
  });

  test('generic session titles follow the app language', () {
    final en = lookupStrings(const Locale('en'));
    final es = lookupStrings(const Locale('es'));

    expect(localizedSessionTitle(en, kanban), 'Kanban task');
    expect(localizedSessionTitle(en, cron), 'Scheduled task');
    expect(localizedSessionTitle(en, internal), 'Conversation');

    expect(localizedSessionTitle(es, kanban), 'Tarea del Kanban');
    expect(localizedSessionTitle(es, cron), 'Tarea programada');
    expect(localizedSessionTitle(es, internal), 'Conversación');

    // Real titles are never replaced.
    final named = Session.fromJson({
      'id': 's1',
      'title': 'Weekly report',
      'source': 'chat',
    });
    expect(localizedSessionTitle(en, named), 'Weekly report');
  });

  Future<void> openCronDialog(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showCronConversationDeleteDialog(context, cron),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the cron delete dialog names the run in English', (
    tester,
  ) async {
    await openCronDialog(tester, const Locale('en'));
    expect(find.textContaining('Scheduled task'), findsOneWidget);
    expect(find.textContaining('Tarea programada'), findsNothing);
  });

  testWidgets('the cron delete dialog names the run in Spanish', (
    tester,
  ) async {
    await openCronDialog(tester, const Locale('es'));
    expect(find.textContaining('Tarea programada'), findsOneWidget);
  });
}
