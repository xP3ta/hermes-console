// The room list as Hermes Desktop builds it (canonical-group-registry.tsx
// `useGatewayGroupRooms`, canonical-groups.ts `listCanonicalRooms`): only
// `groups.capabilities` + `groups.list`, re-read every 10 s while it is on
// screen, a failed re-read keeping the last good list; a room's
// conversation is read only while that room is open, and a row shows what
// the room's view last read (canonical-group-details.tsx
// `$canonicalRoomLive`).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/state/attention.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bots/room/room_fixtures.dart';
import 'support/fake_bot_chat_title_lookup.dart';
import 'support/spec070_fixtures.dart';

/// A second listed room, never opened in these tests.
Map<String, dynamic> _opsRoomJson() => {
  ...Map<String, dynamic>.from(spec070Result('groups_state')['room'] as Map),
  'room_id': 'room-ops',
  'name': 'Ops',
  'updated_at': 1790000900.0,
};

/// Records every request the repository puts on the wire.
final class _RecordingGateway
    implements
        MissionHostedGroupsGateway,
        MissionHostedGroupsIncrementalGateway,
        MissionHostedGroupsListingGateway {
  _RecordingGateway({this.withUnreadable = true});

  final bool withUnreadable;
  final calls = <String>[];

  /// What the next `groups.list` throws, if anything.
  Object? listFailure;

  /// Holds each `groups.list` answer (built when the read arrived) until
  /// completed.
  Completer<void>? listGate;

  /// Rooms the server no longer lists.
  final hidden = <String>{};

  /// The room-devs row as the server holds it now.
  String devsName = 'Console Devs';
  int devsRevision = 5;

  Map<String, dynamic> _devsJson() => {
    ...Map<String, dynamic>.from(spec070Result('groups_state')['room'] as Map),
    'name': devsName,
    'revision': devsRevision,
  };

  /// What `groups.state` says of the room's driver.
  bool working = true;

  int count(String method) => calls.where((call) => call == method).length;

  @override
  Future<GroupsCapabilities> capabilities() async {
    calls.add('groups.capabilities');
    return spec070Capabilities();
  }

  @override
  Future<HostedGroupListing> listing({required int generation}) async {
    calls.add('groups.list');
    final failure = listFailure;
    if (failure != null) throw failure;
    final rooms = [
      if (!hidden.contains('room-devs')) HostedGroupRoom.fromJson(_devsJson()),
      if (!hidden.contains('room-ops')) HostedGroupRoom.fromJson(_opsRoomJson()),
    ];
    await listGate?.future;
    return HostedGroupListing(
      rooms: rooms,
      unreadable: withUnreadable
          ? const [
              HostedGroupUnreadableRoom(
                roomId: 'room-bad',
                reason: HostedGroupUnreadableReason.invalidData,
              ),
            ]
          : const [],
    );
  }

  @override
  Future<List<HostedGroupRoom>> list({required int generation}) async =>
      (await listing(generation: generation)).rooms;

  @override
  Future<HostedGroupRoom> state(
    String roomId, {
    required int generation,
  }) async {
    calls.add('groups.state');
    return spec070Room();
  }

  @override
  Future<HostedGroupLogPage> log(
    String roomId, {
    required int generation,
  }) async {
    calls.add('groups.log');
    return spec070LogPage('groups_log_page1');
  }

  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})>
  stateWithDriver(String roomId, {required int generation}) async {
    calls.add('groups.state');
    return (
      room: spec070Room(),
      driverStatus: RoomDriverStatus(
        running: working,
        working: working,
        blocked: false,
      ),
    );
  }

  @override
  Future<HostedGroupLogPage> logSince(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    calls.add('groups.log');
    if (sinceSeq == 0) return spec070LogPage('groups_log_page1');
    if (sinceSeq == 4) return spec070LogPage('groups_log_page2');
    return HostedGroupLogPage.fromJson(
      {
        'events': const <Object?>[],
        'cursor': sinceSeq,
        'latest_seq': sinceSeq,
        'has_more': false,
        'authority': {'gateway_id': 'gw-home-1', 'epoch': 2},
      },
      expectedRoomId: roomId,
      sinceSeq: sinceSeq,
    );
  }

  @override
  Future<HostedGroupRoom> rename(
    String roomId, {
    required String name,
    required int generation,
  }) async {
    calls.add('groups.rename');
    devsName = name;
    devsRevision = 6;
    return HostedGroupRoom.fromJson(_devsJson());
  }

  @override
  Future<HostedGroupRoom> disband(
    String roomId, {
    required int generation,
  }) async {
    calls.add('groups.disband');
    return HostedGroupRoom.fromJson({
      ...(roomId == 'room-ops' ? _opsRoomJson() : _devsJson()),
      'revision': 6,
      'disbanded_at': 1790001000.0,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The socket the rooms are read on, under test control.
final class _Link extends ChangeNotifier {
  bool up = false;

  void set(bool value) {
    up = value;
    notifyListeners();
  }
}

MissionControlRepository _repository(
  _RecordingGateway gateway, {
  _Link? link,
}) => MissionControlRepository(
  profilesLoader: () async => const [],
  sessionsLoader: () async => const [],
  boardLoader: () async => const KanbanBoard(columns: []),
  hostedGroupsGateway: gateway,
  link: link,
  linkUp: link == null ? null : () => link.up,
);

Future<void> _roomAction(
  WidgetTester tester,
  String roomId,
  String action,
) async {
  final row = find.byKey(ValueKey('roster-room-row-${_publicKey(roomId)}'));
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.longPress(row);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('roster-room-action-$action')));
  await tester.pumpAndSettle();
}

String? _title(WidgetTester tester, String roomId) => tester
    .widget<Text>(
      find.byKey(ValueKey('roster-room-title-${_publicKey(roomId)}')),
    )
    .data;

final _connection = SavedConnection(
  id: 'rooms-like-desktop',
  label: 'Rooms',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

Future<void> _pumpBots(
  WidgetTester tester,
  MissionControlDataSource source,
) async {
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: MissionControlScreen(
        connection: _connection,
        connManager: manager,
        dataSource: source,
        botChatTitleLookup: FakeBotChatTitleLookup(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

final _notice = find.byKey(const ValueKey('mission-rooms-unreadable'));

Finder _roomRows() => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith('roster-room-row-');
});

String _publicKey(String roomId) => RoomRosterEntry(
  roomKey: 'hosted:$roomId',
  title: '',
  members: const [],
).publicKey;

/// A room read the test answers by hand.
final class _HeldRoomGateway implements RoomGateway {
  _HeldRoomGateway(this.room, this.log);

  final HostedGroupRoom room;
  final HostedGroupLogPage log;
  final answer = Completer<void>();
  int reads = 0;

  HostedGroupWorkspaceReadback get _readback => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: 1,
    driverStatus: driver(),
  );

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async {
    reads++;
    await answer.future;
    return _readback;
  }

  @override
  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
  }) async => _readback;

  @override
  Future<HostedGroupWorkspaceReadback> rename(
    HostedGroupRoom room, {
    required String name,
  }) async => _readback;

  @override
  Future<HostedGroupWorkspaceReadback> stop(HostedGroupRoom room) async =>
      _readback;

  @override
  Future<HostedGroupWorkspaceReadback> disband(HostedGroupRoom room) async =>
      _readback;

  @override
  Future<void> approve(
    HostedGroupRoom room, {
    required RoomApprovalAction action,
    required String choice,
  }) async {}

  @override
  Future<void> retry(HostedGroupRoom room, {required String taskId}) async {}
}

final class _NoTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}

/// Captures the poller's next tick so the test fires it by hand.
final class _Ticks {
  void Function()? _next;

  Timer call(Duration delay, void Function() callback) {
    _next = callback;
    return _NoTimer();
  }

  void fire() {
    final next = _next;
    expect(next, isNotNull, reason: 'the poller scheduled no tick');
    _next = null;
    next!();
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('repository: the list is groups.list alone', () {
    test('a load and a re-read call only groups.capabilities and groups.list: '
        'no room is read to list it, and an unread room is unknown, not '
        'empty', () async {
      final gateway = _RecordingGateway();
      final repo = _repository(gateway);
      addTearDown(repo.close);

      final snapshot = await repo.load();
      final hosted = snapshot.hostedGroups;
      expect(snapshot.hostedGroupsCapability, MissionCapabilityState.available);
      expect([for (final room in hosted.rooms) room.roomId], [
        'room-devs',
        'room-ops',
      ]);
      expect(gateway.calls.toSet(), {'groups.capabilities', 'groups.list'});
      expect(gateway.count('groups.state'), 0);
      expect(gateway.count('groups.log'), 0);
      expect(hosted.logAt(0), isNull);
      expect(hosted.logAt(1), isNull);
      expect(hosted.driverStatuses, isEmpty);
      // Rows Console cannot parse stay reported apart, as before.
      expect(hosted.unreadableRooms.single.roomId, 'room-bad');

      final again = await repo.refreshHostedGroups(hosted);
      expect(again.rooms, hasLength(2));
      expect(gateway.count('groups.state'), 0);
      expect(gateway.count('groups.log'), 0);
      expect(gateway.count('groups.list'), 2);
    });

    test('a room its open view read keeps that log and live state on its '
        'row in later list reads; a room never opened shows neither', () async {
      final gateway = _RecordingGateway();
      final repo = _repository(gateway);
      addTearDown(repo.close);
      final first = (await repo.load()).hostedGroups;
      final devs = first.rooms.firstWhere((room) => room.roomId == 'room-devs');

      // The room screen's poll: the only path that reads a room.
      final read = await repo.readHostedGroup(
        devs,
        generation: first.capabilities!.generation,
      );
      expect(read.log, isNotNull);

      final before = gateway.calls.length;
      final listed = await repo.refreshHostedGroups(first);
      expect(gateway.calls.sublist(before), [
        'groups.capabilities',
        'groups.list',
      ]);
      expect(listed.logFor('room-devs')?.latestSeq, read.log!.latestSeq);
      expect(listed.driverStatusFor('room-devs')?.working, isTrue);
      expect(listed.driverReadAt['room-devs'], isNotNull);
      expect(listed.logFor('room-ops'), isNull);
      expect(listed.driverStatusFor('room-ops'), isNull);

      final rows = RoomRosterEntry.build(
        hosted: listed,
        attention: AttentionSummary.fromSnapshot(listed),
      );
      final devsRow = rows.singleWhere(
        (row) => row.hostedRoomId == 'room-devs',
      );
      final opsRow = rows.singleWhere((row) => row.hostedRoomId == 'room-ops');
      expect(devsRow.working, isTrue, reason: 'what its open view read');
      expect(devsRow.preview, isNotEmpty);
      // The server would say it works too, but nothing read it here.
      expect(opsRow.working, isFalse);
      expect(opsRow.preview, isEmpty);
      expect(opsRow.attentionCount, 0);
      // Age and order from the room's own updated_at, as Desktop's rows.
      expect(
        opsRow.at,
        DateTime.fromMillisecondsSinceEpoch(1790000900 * 1000),
      );
    });

    test('a failed list re-read throws and changes nothing the repository '
        'knows: the next one lists the rooms with what their views read',
        () async {
      final gateway = _RecordingGateway();
      final repo = _repository(gateway);
      addTearDown(repo.close);
      final first = (await repo.load()).hostedGroups;
      final devs = first.rooms.first;
      await repo.readHostedGroup(
        devs,
        generation: first.capabilities!.generation,
      );

      gateway.listFailure = const TuiGatewayRpcError(
        'groups.list',
        'Timeout waiting for JSON-RPC response',
        failureKind: TuiGatewayRpcFailureKind.timeout,
      );
      await expectLater(
        repo.refreshHostedGroups(first),
        throwsA(isA<TuiGatewayRpcError>()),
      );

      gateway.listFailure = null;
      final healed = await repo.refreshHostedGroups(first);
      expect(healed.rooms, hasLength(2));
      expect(healed.logFor(devs.roomId), isNotNull);
    });
  });

  group('Bots screen', () {
    testWidgets('the room list is read again every 10 s while it is on '
        'screen, never while another route covers it, and never a room\'s '
        'state or log', (tester) async {
      final gateway = _RecordingGateway(withUnreadable: false);
      await _pumpBots(tester, _repository(gateway));
      expect(gateway.count('groups.list'), 1);

      await tester.pump(const Duration(seconds: 10));
      expect(gateway.count('groups.list'), 2);
      await tester.pump(const Duration(seconds: 10));
      expect(gateway.count('groups.list'), 3);

      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const SizedBox()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final covered = gateway.count('groups.list');
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(gateway.count('groups.list'), covered, reason: 'covered');

      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(gateway.count('groups.list'), greaterThan(covered));
      expect(gateway.count('groups.state'), 0);
      expect(gateway.count('groups.log'), 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed re-read keeps the last good list on screen and '
        'shows no transport error', (tester) async {
      final gateway = _RecordingGateway(withUnreadable: false);
      await _pumpBots(tester, _repository(gateway));
      expect(_roomRows(), findsNWidgets(2));
      expect(_notice, findsNothing);

      gateway.listFailure = const TuiGatewayRpcError(
        'groups.list',
        'Timeout waiting for JSON-RPC response',
        failureKind: TuiGatewayRpcFailureKind.timeout,
      );
      final failedAt = gateway.count('groups.list');
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(gateway.count('groups.list'), failedAt + 1, reason: 'it read');
      expect(_roomRows(), findsNWidgets(2));
      expect(_notice, findsNothing);

      // No retry of its own: the next read is the next tick's.
      await tester.pump(const Duration(seconds: 5));
      expect(gateway.count('groups.list'), failedAt + 1);

      gateway.listFailure = null;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(_roomRows(), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('back from a room, its row shows the live state its open '
        'view read (needs you: an unanswered @user); a room never opened '
        'shows none', (tester) async {
      tester.view.physicalSize = const Size(412 * 3, 915 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final gateway = _RecordingGateway(withUnreadable: false);
      await _pumpBots(tester, _repository(gateway));
      final strings = Strings.of(
        tester.element(find.byType(MissionControlScreen)),
      );
      final devsLine = find.byKey(
        ValueKey('roster-room-line-${_publicKey('room-devs')}'),
      );
      final opsLine = find.byKey(
        ValueKey('roster-room-line-${_publicKey('room-ops')}'),
      );
      final live = [strings.dotsRoomWorking, strings.dotsWaiting];
      expect(
        live,
        isNot(contains(tester.widget<Text>(devsLine).data)),
        reason: 'not read yet: unknown, neither working nor waiting',
      );

      final devsRow = find.byKey(
        ValueKey('roster-room-row-${_publicKey('room-devs')}'),
      );
      await tester.ensureVisible(devsRow);
      await tester.pump();
      await tester.tap(devsRow);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // The room's first poll reads it (groups.state + groups.log).
      await tester.pump();
      await tester.pump();
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(gateway.count('groups.state'), greaterThan(0));

      // The list cannot be read when the room closes: what the row shows
      // comes from what the room's view read, not from a list read.
      gateway.listFailure = const TuiGatewayRpcError(
        'groups.list',
        'Timeout waiting for JSON-RPC response',
        failureKind: TuiGatewayRpcFailureKind.timeout,
      );
      final listed = gateway.count('groups.list');
      Navigator.of(tester.element(find.byType(RoomScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(gateway.count('groups.list'), listed + 1, reason: 'it tried');

      // Its view read a member asking @user (and a working driver): the
      // row says it needs you, the state that wins on a Bots row.
      expect(tester.widget<Text>(devsLine).data, strings.dotsWaiting);
      expect(
        find.byKey(
          ValueKey('roster-room-needs-you-${_publicKey('room-devs')}'),
        ),
        findsOneWidget,
      );
      expect(
        live,
        isNot(contains(tester.widget<Text>(opsLine).data)),
        reason: 'never opened: no live state read in the background',
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Bots screen, like Desktop', () {
    testWidgets('the socket coming back up reads the list at once', (
      tester,
    ) async {
      final gateway = _RecordingGateway(withUnreadable: false);
      final link = _Link();
      await _pumpBots(tester, _repository(gateway, link: link));
      final listed = gateway.count('groups.list');

      await tester.pump(const Duration(seconds: 3));
      link.set(true);
      await tester.pump();
      await tester.pump();
      expect(gateway.count('groups.list'), listed + 1);

      // Only the edge up reads: staying up, or going down, does not.
      link.set(true);
      await tester.pump();
      link.set(false);
      await tester.pump();
      expect(gateway.count('groups.list'), listed + 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a room disbanded here never comes back from a list read '
        'that still has it; once a list no longer has it, it is forgotten', (
      tester,
    ) async {
      final gateway = _RecordingGateway(withUnreadable: false);
      await _pumpBots(tester, _repository(gateway));
      expect(_roomRows(), findsNWidgets(2));

      await _roomAction(tester, 'room-ops', 'disband');
      await tester.tap(find.byKey(const ValueKey('roster-room-confirm')));
      await tester.pumpAndSettle();
      expect(gateway.count('groups.disband'), 1);
      expect(_roomRows(), findsOneWidget);

      // The server still lists it (its list predates the disband).
      final listed = gateway.count('groups.list');
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(gateway.count('groups.list'), greaterThan(listed));
      expect(_roomRows(), findsOneWidget);

      gateway.hidden.add('room-ops');
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(_roomRows(), findsOneWidget);

      // Forgotten: a room listed again under that id is shown.
      gateway.hidden.remove('room-ops');
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(_roomRows(), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a list read that started before a room action never '
        'paints over what the action changed', (tester) async {
      final gateway = _RecordingGateway(withUnreadable: false);
      await _pumpBots(tester, _repository(gateway));
      expect(_title(tester, 'room-devs'), 'Console Devs');

      // A list read is on the wire, built before the rename.
      final held = gateway.listGate = Completer<void>();
      final listed = gateway.count('groups.list');
      await tester.pump(const Duration(seconds: 10));
      expect(gateway.count('groups.list'), listed + 1);

      await _roomAction(tester, 'room-devs', 'rename');
      await tester.enterText(
        find.byKey(const ValueKey('roster-room-rename-field')),
        'Renamed',
      );
      await tester.tap(find.byKey(const ValueKey('roster-room-rename-save')));
      await tester.pumpAndSettle();
      expect(gateway.count('groups.rename'), 1);
      expect(_title(tester, 'room-devs'), 'Renamed');

      gateway.listGate = null;
      held.complete();
      await tester.pump();
      await tester.pump();
      expect(_title(tester, 'room-devs'), 'Renamed');

      // The next read is the server's own, after the rename.
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(_title(tester, 'room-devs'), 'Renamed');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('room screen opened without a log', () {
    testWidgets('shows it loading, marks nothing seen until its messages are '
        'on screen, then shows them and marks them seen', (tester) async {
      tester.view.physicalSize = const Size(412 * 3, 915 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final seq = EventSeq();
      final log = buildLog([
        seq.user('hola equipo'),
        seq.member('m-review', 'review', 'Revisado y listo.', 'user:0'),
      ]);
      final room = buildRoom(latestSeq: log.latestSeq);
      final gateway = _HeldRoomGateway(room, log);
      final prefs = MemoryRoomPrefs();
      final ticks = _Ticks();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.hermesRedDark,
          home: RoomScreen(
            room: room,
            gateway: gateway,
            capabilities: const RoomCapabilities(canSend: true),
            profileFor: (_) => null,
            prefs: prefs,
            pollTimer: ticks.call,
            clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('room-loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('room-empty')), findsNothing);

      // Its first read is on the wire and has not answered.
      ticks.fire();
      await tester.pump();
      expect(gateway.reads, 1);
      expect(find.byKey(const ValueKey('room-loading')), findsOneWidget);

      // Leaving now marks nothing: nothing of the room was shown.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(prefs.seen, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      gateway.answer.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('room-loading')), findsNothing);
      expect(
        find.textContaining('Revisado y listo.', findRichText: true),
        findsWidgets,
      );

      // Shown: leaving marks it seen, as a room opened with its log.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(prefs.seen[roomPrefsKey(room)], log.latestSeq);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
