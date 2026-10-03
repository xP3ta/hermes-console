import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/remote_bot_roster.dart';

import 'support/bot_roster_fakes.dart';

void main() {
  testWidgets(
    'a rename on Profiles shows in the remote roster at once and a late read cannot undo it',
    (tester) async {
      useWideView(tester);
      final registry = BotRosterRegistry();
      final server = FakeProfilesServer();
      final remoteReads = <Completer<List<AgentProfile>>>[];
      await tester.pumpWidget(
        panes([
          (
            'A',
            ProfilesScreen(
              connection: connection,
              connManager: await manager(),
              rosterRegistry: registry,
              clientOverride: server.client,
            ),
          ),
          (
            'B',
            Scaffold(
              body: RemoteBotRoster(
                connections: [connection],
                registry: registry,
                query: '',
                showHidden: false,
                refreshedAt: DateTime(2026),
                loader: (SavedConnection _) {
                  final read = Completer<List<AgentProfile>>();
                  remoteReads.add(read);
                  return read.future;
                },
                onOpen: (_, _) {},
                onDetails: (_, _) {},
              ),
            ),
          ),
        ]),
      );
      await tester.pump();
      server.reads.single.complete(roster(['default', 'ops']));
      await tester.pumpAndSettle();
      expect(inPane('B', find.text('ops')), findsOneWidget);
      expect(remoteReads, hasLength(1));

      await renameOnProfilesScreen(tester, 'A', 1, 'ops2');
      expect(server.mutations, 1);
      expect(inPane('B', find.text('ops2')), findsOneWidget);
      expect(inPane('B', find.text('ops')), findsNothing);
      expect(remoteReads, hasLength(1));

      // The remote roster's own read started before the rename.
      remoteReads.single.complete(const [
        AgentProfile(name: 'default', isDefault: true),
        AgentProfile(name: 'ops'),
      ]);
      await tester.pumpAndSettle();
      expect(inPane('B', find.text('ops2')), findsOneWidget);
      expect(inPane('B', find.text('ops')), findsNothing);
      server.reads.last.complete(roster(['default', 'ops2']));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('cold start paints the cached roster as unavailable', (
    tester,
  ) async {
    final prefs = (await manager()).prefs;
    final seeded = BotRosterRegistry()..attachPersistence(prefs, const []);
    seeded.hydrate(connection);
    seeded.publish('roster', 'QA', const [AgentProfile(name: 'kept')]);
    await tester.pump();
    final registry = BotRosterRegistry();
    final pending = Completer<List<AgentProfile>>();
    await tester.pumpWidget(
      panes([
        (
          'B',
          Scaffold(
            body: RemoteBotRoster(
              connections: [connection],
              prefs: prefs,
              registry: registry,
              query: '',
              showHidden: false,
              refreshedAt: DateTime(2026),
              loader: (_) => pending.future,
              onOpen: (_, _) {},
              onDetails: (_, _) {},
            ),
          ),
        ),
      ]),
    );
    expect(find.text('kept'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    pending.complete(const [AgentProfile(name: 'live')]);
    await tester.pumpAndSettle();
    expect(find.text('live'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
  });
}
