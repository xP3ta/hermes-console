import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/services/bot_roster_cache.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/bot_roster_fakes.dart';
import 'support/fake_bot_chat_title_lookup.dart';

MissionBackendSnapshot snapshot(List<String> names) => MissionBackendSnapshot(
  profiles: [for (final name in names) AgentProfile(name: name)],
  board: const KanbanBoard(columns: []),
  profilesCapability: MissionCapabilityState.available,
  sessionsCapability: MissionCapabilityState.available,
  kanbanCapability: MissionCapabilityState.available,
  loadedAt: DateTime.fromMillisecondsSinceEpoch(120000),
);

/// Behaves like the real repository: each load stamps its roster read
/// before going on the wire and publishes it to the shared store.
final class PendingSource implements MissionControlDataSource {
  PendingSource(this.registry);
  final BotRosterRegistry registry;
  final loads = <Completer<MissionBackendSnapshot>>[];

  @override
  Future<MissionBackendSnapshot> load() async {
    final ticket = registry.beginRead(connection.id);
    final answer = Completer<MissionBackendSnapshot>();
    loads.add(answer);
    final result = await answer.future;
    registry.publish(
      connection.id,
      connection.label,
      result.profiles,
      ticket: ticket,
    );
    return result;
  }

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;

  @override
  void close() {}
}

Finder botRow(String name) =>
    inPane('B', find.byKey(ValueKey('mission-bot-row-$name')));

void main() {
  final secureStore = <String, String>{};
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
          switch (call.method) {
            case 'write':
              secureStore[args['key'] as String] = args['value'] as String;
            case 'read':
              return secureStore[args['key'] as String];
            case 'readAll':
              return Map<String, String>.from(secureStore);
            case 'delete':
              secureStore.remove(args['key'] as String);
          }
          return null;
        });
  });
  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'a rename on Profiles shows in Mission Control at once and its late older load cannot undo it',
    (tester) async {
      useWideView(tester);
      final registry = BotRosterRegistry();
      final server = FakeProfilesServer();
      final source = PendingSource(registry);
      final cache = MissionSnapshotCache()
        ..write(connection, snapshot(['default', 'ops']));
      final manager0 = await manager();
      await tester.pumpWidget(
        panes([
          (
            'A',
            ProfilesScreen(
              connection: connection,
              connManager: manager0,
              rosterRegistry: registry,
              clientOverride: server.client,
            ),
          ),
          (
            'B',
            MissionControlScreen(
              connection: connection,
              connManager: manager0,
              dataSource: source,
              snapshotCache: cache,
              rosterRegistry: registry,
              botChatTitleLookup: FakeBotChatTitleLookup(),
            ),
          ),
        ]),
      );
      await tester.pump();
      // Mission Control paints its cached snapshot; its load is pending.
      expect(source.loads, hasLength(1));
      expect(botRow('ops'), findsOneWidget);
      server.reads.single.complete(roster(['default', 'ops']));
      await tester.pump();
      await tester.pump();

      await renameOnProfilesScreen(tester, 'A', 1, 'ops2');
      expect(server.mutations, 1);
      expect(botRow('ops2'), findsOneWidget);
      expect(botRow('ops'), findsNothing);
      expect(source.loads, hasLength(1));

      // Mission Control's load started before the rename and lands late.
      source.loads.single.complete(snapshot(['default', 'ops']));
      await tester.pump();
      await tester.pump();
      expect(botRow('ops2'), findsOneWidget);
      expect(botRow('ops'), findsNothing);

      server.reads.last.complete(roster(['default', 'ops2']));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // Tear down while timers are idle.
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'a delete confirmed over the cached roster hides the bot in Mission Control before any live read',
    (tester) async {
      useWideView(tester);
      final manager0 = await manager();
      final prefs = await SharedPreferences.getInstance();
      await BotRosterCache(prefs).write(connection, const [
        AgentProfile(name: 'default'),
        AgentProfile(name: 'ops'),
      ]);
      // Cold start: the shared store holds only the cached roster.
      final registry = BotRosterRegistry()
        ..attachPersistence(prefs, [connection]);
      final source = PendingSource(registry);
      final cache = MissionSnapshotCache()
        ..write(connection, snapshot(['default', 'ops']));
      await tester.pumpWidget(
        panes([
          (
            'B',
            MissionControlScreen(
              connection: connection,
              connManager: manager0,
              dataSource: source,
              snapshotCache: cache,
              rosterRegistry: registry,
              botChatTitleLookup: FakeBotChatTitleLookup(),
            ),
          ),
        ]),
      );
      await tester.pump();
      expect(source.loads, hasLength(1));
      expect(registry.store(connection.id).isLive, isFalse);
      expect(botRow('ops'), findsOneWidget);

      // Another screen deletes `ops`; the live read is still on the wire.
      registry.profileDeleted(connection.id, 'ops');
      await tester.pump();
      expect(botRow('ops'), findsNothing);
      expect(botRow('default'), findsOneWidget);

      // The read started before the delete and lands late.
      source.loads.single.complete(snapshot(['default', 'ops']));
      await tester.pump();
      await tester.pump();
      expect(botRow('ops'), findsNothing);
      expect(botRow('default'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
