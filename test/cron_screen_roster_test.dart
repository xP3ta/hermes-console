import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/bot_roster_fakes.dart';

String titledRoster(String bot) => jsonEncode({
  'profiles': [
    {'name': 'default', 'is_default': true},
    {
      'name': bot,
      'ui_meta': {
        'hermes-bots': {'title': 'Radar Bot'},
      },
    },
  ],
});

void main() {
  testWidgets(
    'a rename on Profiles updates the Cron owner line at once and a late read cannot undo it',
    (tester) async {
      useWideView(tester);
      final registry = BotRosterRegistry();
      final server = FakeProfilesServer();
      final cronProfileReads = <Completer<String>>[];
      final cronClient = DashboardClient(
        host: 'hermes.local',
        manualToken: 'token',
        httpClientOverride: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
            return http.Response(
              jsonEncode([
                {
                  'id': 'job',
                  'name': '[bot:radar] Daily sweep',
                  'profile': 'default',
                  'schedule': '0 9 * * *',
                  'enabled': true,
                },
              ]),
              200,
            );
          }
          if (request.method == 'GET' && request.url.path == '/api/profiles') {
            final read = Completer<String>();
            cronProfileReads.add(read);
            return http.Response(await read.future, 200);
          }
          return http.Response('{}', 404);
        }),
      );
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
            CronScreen(
              connection: connection,
              rosterRegistry: registry,
              clientOverride: cronClient,
            ),
          ),
        ]),
      );
      await tester.pump();
      server.reads.single.complete(titledRoster('radar'));
      await tester.pumpAndSettle();
      expect(cronProfileReads, hasLength(1));
      expect(inPane('B', find.textContaining('Radar Bot')), findsWidgets);

      await renameOnProfilesScreen(tester, 'A', 1, 'radar2');
      expect(server.mutations, 1);
      // The job still names `radar`, which no longer exists: no title.
      expect(inPane('B', find.textContaining('Radar Bot')), findsNothing);
      expect(cronProfileReads, hasLength(1));

      // Cron's own read started before the rename and lands late.
      cronProfileReads.single.complete(titledRoster('radar'));
      await tester.pumpAndSettle();
      expect(inPane('B', find.textContaining('Radar Bot')), findsNothing);
      server.reads.last.complete(titledRoster('radar2'));
      await tester.pumpAndSettle();
    },
  );
}
