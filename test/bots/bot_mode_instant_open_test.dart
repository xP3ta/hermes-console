import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/inter_font.dart';
import '../support/spec070_fixtures.dart';

/// Rooms whose reads can be held open, to observe concurrency.
final class _SlowGateway
    implements
        MissionHostedGroupsGateway,
        MissionHostedGroupsIncrementalGateway {
  _SlowGateway(this.roomIds);

  final List<String> roomIds;
  final sinceCalls = <String, List<int>>{};
  var inFlight = 0;
  var maxInFlight = 0;
  Completer<void>? gate;

  HostedGroupRoom _room(String id) {
    final json = Map<String, dynamic>.from(
      spec070Result('groups_state')['room'] as Map,
    );
    json['room_id'] = id;
    return HostedGroupRoom.fromJson(json);
  }

  @override
  Future<GroupsCapabilities> capabilities() async => spec070Capabilities();
  @override
  Future<List<HostedGroupRoom>> list({required int generation}) async => [
    for (final id in roomIds) _room(id),
  ];
  @override
  Future<HostedGroupRoom> state(String roomId, {required int generation}) =>
      throw StateError('incremental only');
  @override
  Future<HostedGroupLogPage> log(String roomId, {required int generation}) =>
      throw StateError('full log must not be re-read');

  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})>
  stateWithDriver(String roomId, {required int generation}) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await (gate?.future ?? Future<void>.value());
      return (room: _room(roomId), driverStatus: spec070DriverStatus());
    } finally {
      inFlight--;
    }
  }

  @override
  Future<HostedGroupLogPage> logSince(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    (sinceCalls[roomId] ??= []).add(sinceSeq);
    final page = sinceSeq == 0
        ? 'groups_log_page1'
        : sinceSeq == 4
        ? 'groups_log_page2'
        : 'groups_log_empty';
    final fixture = spec070Fixture(page);
    final json = Map<String, dynamic>.from(spec070Result(page));
    json['events'] = [
      for (final e in json['events'] as List)
        {...Map<String, dynamic>.from(e as Map), 'room_id': roomId},
    ];
    return HostedGroupLogPage.fromJson(
      json,
      expectedRoomId: roomId,
      sinceSeq: (fixture['params'] as Map)['since_seq'] as int,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MissionControlRepository _repository(MissionHostedGroupsGateway gateway) =>
    MissionControlRepository(
      profilesLoader: () async => spec070Profiles(),
      sessionsLoader: () async => const [],
      boardLoader: () async => const KanbanBoard(columns: []),
      hostedGroupsGateway: gateway,
    );

/// A data source whose load() waits until the test releases it.
final class _HeldSource implements MissionControlDataSource {
  _HeldSource(this.snapshot);
  final MissionBackendSnapshot snapshot;
  var loads = 0;
  Completer<void> gate = Completer<void>();

  @override
  Future<MissionBackendSnapshot> load() async {
    loads++;
    await gate.future;
    return snapshot;
  }

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;
  @override
  void close() {}
}

final _connection = SavedConnection(
  id: 'instant-open',
  label: 'Instant',
  host: 'localhost',
  port: 8642,
  apiKey: 'k',
);

void main() {
  setUpAll(loadInterFont);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('rooms are read concurrently, bounded, in listed order', () async {
    final ids = [for (var i = 0; i < 8; i++) 'room-$i'];
    final gateway = _SlowGateway(ids)..gate = Completer<void>();
    final repository = _repository(gateway);
    final load = repository.load();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(gateway.maxInFlight, MissionControlRepository.roomReadConcurrency);
    gateway.gate!.complete();
    final snapshot = await load;
    expect([for (final r in snapshot.hostedGroups.rooms) r.roomId], ids);
    expect(snapshot.hostedGroups.logs, hasLength(8));
    repository.close();
  });

  test(
    'a reopened repository resumes each room log from the last snapshot',
    () async {
      final gateway = _SlowGateway(['room-a', 'room-b']);
      final first = _repository(gateway);
      final seen = await first.load();
      first.close();
      expect(gateway.sinceCalls, {
        'room-a': [0, 4],
        'room-b': [0, 4],
      });

      gateway.sinceCalls.clear();
      final reopened = _repository(gateway)..seedHostedLogs(seen.hostedGroups);
      final again = await reopened.load();
      expect(gateway.sinceCalls, {
        'room-a': [8],
        'room-b': [8],
      }, reason: 'only the delta after what the user already saw');
      expect(again.hostedGroups.logs.first.events, hasLength(8));
      reopened.close();
    },
  );

  testWidgets(
    'reopening Bot Mode paints the last snapshot on the first frame',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      final gateway = _SlowGateway(['room-a']);
      final repository = _repository(gateway);
      final snapshot = await tester.runAsync(repository.load);
      repository.close();
      final cache = MissionSnapshotCache();
      final source = _HeldSource(snapshot!);

      Future<void> open() => tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: MissionControlScreen(
            connection: _connection,
            connManager: manager,
            dataSource: source,
            snapshotCache: cache,
          ),
        ),
      );

      // First visit ever: nothing known yet, the loading state is honest.
      await open();
      await tester.pump();
      expect(find.text('Reading team state…'), findsOneWidget);
      source.gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('Reading team state…'), findsNothing);

      // Leave and come back while the server is slow.
      await tester.pumpWidget(const SizedBox());
      source.gate = Completer<void>();
      await open();
      await tester.pump();
      expect(find.text('Reading team state…'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('roster-'),
        ),
        findsWidgets,
      );
      expect(source.loads, 2, reason: 'still refreshes in the background');
      source.gate.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
