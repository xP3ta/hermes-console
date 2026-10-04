import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/bot_create_screen.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

import 'support/bot_roster_fakes.dart';

/// Profiles and Bot Mode share one create flow and one delete flow.
void main() {
  Future<(ConnectionManager, FakeProfilesServer)> pumpProfiles(
    WidgetTester tester,
  ) async {
    useWideView(tester);
    final connManager = await manager();
    final server = FakeProfilesServer();
    await tester.pumpWidget(
      panes([
        (
          'P',
          ProfilesScreen(
            connection: connection,
            connManager: connManager,
            rosterRegistry: BotRosterRegistry(),
            clientOverride: server.client,
          ),
        ),
      ]),
    );
    await tester.pump();
    server.reads.single.complete(roster(['default', 'ops']));
    await tester.pumpAndSettle();
    return (connManager, server);
  }

  testWidgets('"New profile" opens the same form as Bot Mode\'s "New bot"', (
    tester,
  ) async {
    await pumpProfiles(tester);
    final create = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.endsWith('-dock-create'),
    );
    final fab = find.byType(FloatingActionButton);
    await tester.tap(create.evaluate().isNotEmpty ? create.first : fab);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(BotCreateScreen), findsOneWidget);
  });

  testWidgets('delete uses the shared confirmation and leaves the deleted '
      'active profile', (tester) async {
    final (connManager, server) = await pumpProfiles(tester);
    await connManager.setActiveProfile(connection.id, 'ops');
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('profile-delete-confirm')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('profile-delete-confirm-yes')));
    await tester.pump();
    await tester.pump();
    expect(server.mutations, 1);
    expect(connManager.activeProfileFor(connection.id), '');
    for (final read in server.reads.where((r) => !r.isCompleted)) {
      read.complete(roster(['default']));
    }
    await tester.pumpAndSettle();
  });
}
