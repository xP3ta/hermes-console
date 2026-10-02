import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_bot_chat_title_lookup.dart';
import 'support/spec070_fixtures.dart';

final _connection = SavedConnection(
  id: 'mission-partial',
  label: 'Mission QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

int _bytes(Object? payload) => utf8.encode(jsonEncode(payload)).length;

/// Fake Desktop gateway behind a real [MissionControlRepository]: records
/// every request it would put on the wire and the size of its response.
final class _MeteredGateway
    implements
        MissionHostedGroupsGateway,
        MissionHostedGroupsIncrementalGateway {
  final calls = <String>[];
  var bytes = 0;
  var capabilitiesCached = false;

  /// Room `latest_seq` on the server and its driver evidence.
  var latestSeq = 8;
  var roomWorking = false;

  /// `profiles.list` row with a worker session active right now.
  var workerActive = false;

  void record(String method, Object? payload) {
    calls.add(method);
    bytes += _bytes(payload);
  }

  int count(String method) => calls.where((call) => call == method).length;

  Map<String, dynamic> _roomJson() => {
    ...Map<String, dynamic>.from(spec070Result('groups_state')['room'] as Map),
    'latest_seq': latestSeq,
  };

  RoomDriverStatus _driver() => RoomDriverStatus(
    running: roomWorking,
    working: roomWorking,
    blocked: false,
  );

  MissionControlRepository repository({
    FakeChangeFeed? feed,
    Stream<KanbanEvent> Function(int since)? kanbanEvents,
  }) {
    final sessions = [
      for (var i = 0; i < 200; i++)
        {
          'id': 'session-$i',
          'title': 'Session $i',
          'model': 'model',
          'source': 'cli',
          'message_count': 12,
          'started_at': 100,
          'profile': 'infra',
          'preview': 'Recent work in session $i',
        },
    ];
    final profiles = spec070Result('profiles_list');
    return buildRepository(
      profilesLoader: () async {
        record('profiles.list', profiles);
        return [
          AgentProfile.fromJson({
            'name': 'infra',
            if (workerActive)
              'worker_session': {
                'id': 'worker-1',
                'source': 'kanban',
                'last_active': DateTime.now().millisecondsSinceEpoch / 1000,
              },
          }),
        ];
      },
      sessionsLoader: () async {
        record('profiles/sessions', {'sessions': sessions});
        return const [];
      },
      boardLoader: () async {
        record('kanban.board', const {'columns': []});
        return const KanbanBoard(columns: []);
      },
      gateway: this,
      feed: feed,
      kanbanEvents: kanbanEvents,
    );
  }

  @override
  Future<GroupsCapabilities> capabilities() async {
    if (!capabilitiesCached) {
      capabilitiesCached = true;
      record('groups.capabilities', spec070Result('groups_capabilities'));
    }
    return spec070Capabilities();
  }

  @override
  Future<List<HostedGroupRoom>> list({required int generation}) async {
    final room = _roomJson();
    record('groups.list', {
      'rooms': [room],
    });
    return [HostedGroupRoom.fromJson(room)];
  }

  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})>
  stateWithDriver(String roomId, {required int generation}) async {
    final room = _roomJson();
    record('groups.state', {'room': room, 'driver_status': {}});
    return (room: HostedGroupRoom.fromJson(room), driverStatus: _driver());
  }

  @override
  Future<HostedGroupLogPage> logSince(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    if (sinceSeq == 0 || sinceSeq == 4) {
      final name = sinceSeq == 0 ? 'groups_log_page1' : 'groups_log_page2';
      record('groups.log', spec070Result(name));
      return spec070LogPage(name);
    }
    final json = {
      'events': const <Object?>[],
      'cursor': sinceSeq,
      'latest_seq': sinceSeq,
      'has_more': false,
      'authority': {'gateway_id': 'gw-home-1', 'epoch': 2},
    };
    record('groups.log', json);
    return HostedGroupLogPage.fromJson(
      json,
      expectedRoomId: roomId,
      sinceSeq: sinceSeq,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Gateway's global event channel and its health, under test control.
final class FakeChangeFeed {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  var healthy = true;

  Stream<TuiGatewayEvent> get stream => _events.stream;

  void sessionsChanged() => _events.add(
    const TuiGatewayEvent(type: 'sessions.changed', sessionId: '', payload: {}),
  );

  void drop() {
    healthy = false;
    _events.addError(StateError('Hermes Desktop WebSocket closed'));
  }

  void close() => unawaited(_events.close());
}

MissionControlRepository buildRepository({
  required MissionProfilesLoader profilesLoader,
  required MissionSessionsLoader sessionsLoader,
  required MissionBoardLoader boardLoader,
  required MissionHostedGroupsGateway gateway,
  FakeChangeFeed? feed,
  Stream<KanbanEvent> Function(int since)? kanbanEvents,
}) => MissionControlRepository(
  kanbanEventsLoader: kanbanEvents,
  profilesLoader: profilesLoader,
  sessionsLoader: sessionsLoader,
  boardLoader: boardLoader,
  hostedGroupsGateway: gateway,
  liveChanges: feed == null ? null : () => feed.stream,
  liveChangesAvailable: feed == null ? null : () => feed.healthy,
);

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

Widget _host(ConnectionManager manager, MissionControlDataSource source) =>
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: MissionControlScreen(
        connection: _connection,
        connManager: manager,
        dataSource: source,
        botChatTitleLookup: FakeBotChatTitleLookup(),
      ),
    );

Future<void> _idle(WidgetTester tester, Duration span) async {
  for (var elapsed = Duration.zero; elapsed < span;) {
    await tester.pump(const Duration(seconds: 1));
    elapsed += const Duration(seconds: 1);
  }
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });

  testWidgets('idle Bot Mode with live events: requests and bytes in 5 min', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _MeteredGateway();
    final feed = FakeChangeFeed();
    addTearDown(feed.close);
    await tester.pumpWidget(_host(manager, gateway.repository(feed: feed)));
    await tester.pump();
    await tester.pump();
    final opened = gateway.calls.length;
    final openedBytes = gateway.bytes;

    await _idle(tester, const Duration(minutes: 5));

    final requests = gateway.calls.length - opened;
    final bytes = gateway.bytes - openedBytes;
    // ignore: avoid_print
    print(
      'mission-control idle 5 min: requests=$requests bytes=$bytes '
      'profiles=${gateway.count('profiles.list')} '
      'sessions=${gateway.count('profiles/sessions')} '
      'board=${gateway.count('kanban.board')} '
      'list=${gateway.count('groups.list')} '
      'state=${gateway.count('groups.state')} '
      'log=${gateway.count('groups.log')}',
    );
    // Before: a full reload every 30 s, 60 requests / 363 850 bytes.
    // After: only the 120 s backstop (2 full reloads at 120 s and 240 s).
    expect(gateway.count('profiles/sessions'), 1 + 2);
    expect(gateway.count('kanban.board'), 1 + 2);
    expect(requests, lessThanOrEqualTo(12));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without live events every tick is still a full reload', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _MeteredGateway();
    await tester.pumpWidget(_host(manager, gateway.repository()));
    await tester.pump();
    await tester.pump();
    expect(gateway.count('kanban.board'), 1);
    await _idle(tester, const Duration(minutes: 5));
    expect(gateway.count('kanban.board'), 11);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sessions.changed refreshes only the roster in the same frame', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _MeteredGateway();
    final feed = FakeChangeFeed();
    addTearDown(feed.close);
    await tester.pumpWidget(_host(manager, gateway.repository(feed: feed)));
    await tester.pump();
    await tester.pump();
    await _idle(tester, const Duration(seconds: 31));
    gateway.calls.clear();

    feed.sessionsChanged();
    await tester.pump();
    expect(gateway.count('profiles.list'), 1);
    expect(gateway.count('profiles/sessions'), 1);
    expect(gateway.count('groups.list'), 1);
    // Unchanged quiet room: groups.list proves it, no state/log read.
    expect(gateway.count('groups.state'), 0);
    expect(gateway.count('groups.log'), 0);
    expect(gateway.count('kanban.board'), 0, reason: 'no full reload');

    // A burst coalesces into one trailing refresh after the gap.
    gateway.calls.clear();
    feed
      ..sessionsChanged()
      ..sessionsChanged();
    await tester.pump();
    expect(gateway.count('profiles.list'), 0);
    await _idle(tester, const Duration(seconds: 30));
    expect(gateway.count('profiles.list'), 1);
    expect(gateway.count('kanban.board'), 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a room that moved is re-read on the change event', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _MeteredGateway();
    final feed = FakeChangeFeed();
    addTearDown(feed.close);
    await tester.pumpWidget(_host(manager, gateway.repository(feed: feed)));
    await tester.pump();
    await tester.pump();
    await _idle(tester, const Duration(seconds: 31));
    gateway.calls.clear();

    gateway.latestSeq = 9;
    feed.sessionsChanged();
    await tester.pump();
    await tester.pump();
    expect(gateway.count('groups.state'), 1);
    expect(gateway.count('groups.log'), 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a working room keeps refreshing until it is idle', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _MeteredGateway()..roomWorking = true;
    final feed = FakeChangeFeed();
    addTearDown(feed.close);
    await tester.pumpWidget(_host(manager, gateway.repository(feed: feed)));
    await tester.pump();
    await tester.pump();
    gateway.calls.clear();

    // No event at all: the 30 s tick still re-reads the working room.
    gateway.roomWorking = false;
    await _idle(tester, const Duration(seconds: 30));
    expect(gateway.count('groups.state'), 1);
    expect(gateway.count('kanban.board'), 0);

    // Once idle evidence is shown, quiet ticks stop reading.
    gateway.calls.clear();
    await _idle(tester, const Duration(seconds: 60));
    expect(gateway.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a working bot keeps refreshing its roster without events', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _MeteredGateway()..workerActive = true;
    final feed = FakeChangeFeed();
    addTearDown(feed.close);
    await tester.pumpWidget(_host(manager, gateway.repository(feed: feed)));
    await tester.pump();
    await tester.pump();
    gateway.calls.clear();

    gateway.workerActive = false;
    await _idle(tester, const Duration(seconds: 30));
    expect(gateway.count('profiles.list'), 1);
    expect(gateway.count('kanban.board'), 0);
    gateway.calls.clear();
    await _idle(tester, const Duration(seconds: 60));
    expect(gateway.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dropped events fall back to the 30 s full reload', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _MeteredGateway();
    final feed = FakeChangeFeed();
    addTearDown(feed.close);
    await tester.pumpWidget(_host(manager, gateway.repository(feed: feed)));
    await tester.pump();
    await tester.pump();
    expect(gateway.count('kanban.board'), 1);

    feed.drop();
    await tester.pump();
    await _idle(tester, const Duration(seconds: 30));
    expect(gateway.count('kanban.board'), 2, reason: 'backstop full reload');
    await _idle(tester, const Duration(seconds: 30));
    expect(gateway.count('kanban.board'), 3);

    // Reconnected: the full reload proved the stream, ticks go quiet again.
    feed.healthy = true;
    await _idle(tester, const Duration(seconds: 30));
    expect(gateway.count('kanban.board'), 4);
    await _idle(tester, const Duration(seconds: 90));
    expect(gateway.count('kanban.board'), 4);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a reconnecting Kanban stream keeps the 30 s full reload', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _MeteredGateway();
    final feed = FakeChangeFeed();
    addTearDown(feed.close);
    await tester.pumpWidget(
      _host(
        manager,
        gateway.repository(
          feed: feed,
          kanbanEvents: (_) => Stream.error(StateError('stream dropped')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(gateway.count('kanban.board'), 1);
    // Every Kanban reconnect fails (backoff 3, 6, 12, 24 s): the board is
    // still read by the full reload on every tick.
    await _idle(tester, const Duration(seconds: 30));
    expect(gateway.count('kanban.board'), 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('first event after a drop reloads everything at once', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _MeteredGateway();
    final feed = FakeChangeFeed();
    addTearDown(feed.close);
    await tester.pumpWidget(_host(manager, gateway.repository(feed: feed)));
    await tester.pump();
    await tester.pump();
    feed.drop();
    await tester.pump(const Duration(seconds: 5));
    feed.healthy = true;
    feed.sessionsChanged();
    await tester.pump();
    expect(gateway.count('kanban.board'), 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('events without change_events never trigger a reload storm', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _MeteredGateway();
    final feed = FakeChangeFeed()..healthy = false;
    addTearDown(feed.close);
    await tester.pumpWidget(_host(manager, gateway.repository(feed: feed)));
    await tester.pump();
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      feed.sessionsChanged();
      await tester.pump(const Duration(seconds: 2));
    }
    expect(gateway.count('kanban.board'), 1);
    await _idle(tester, const Duration(seconds: 10));
    expect(gateway.count('kanban.board'), 2, reason: 'the 30 s tick');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('resume refreshes immediately', (tester) async {
    final manager = await _manager();
    final gateway = _MeteredGateway();
    final feed = FakeChangeFeed();
    addTearDown(feed.close);
    await tester.pumpWidget(_host(manager, gateway.repository(feed: feed)));
    await tester.pump();
    await tester.pump();
    expect(gateway.count('kanban.board'), 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 10));
    feed.sessionsChanged();
    await tester.pump();
    expect(gateway.count('profiles.list'), 1, reason: 'paused: no read');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(gateway.count('kanban.board'), 2);
    expect(gateway.count('profiles.list'), 2);
    await tester.pumpWidget(const SizedBox());
  });
}
