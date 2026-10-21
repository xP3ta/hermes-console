import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The card no longer resolves approvals over REST: a pending one reads the
// same as before and points at Tareas; the Desktop socket resolves it.
void main() {
  testWidgets('a pending approval card shows its state and no buttons', (
    tester,
  ) async {
    final info = ChatEventInfo.classify({
      'role': 'tool',
      'content': '{"status":"pending_approval"}',
    });
    expect(info.approvalPending, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(body: ApprovalRequestCard(info: info)),
      ),
    );
    expect(find.text('Approval required'), findsOneWidget);
    expect(find.text('pending'), findsOneWidget);
    expect(find.textContaining('Approvals are resolved'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
  });
}
