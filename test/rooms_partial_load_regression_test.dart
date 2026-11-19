// Regression tests for the Reddit report (rooms):
// rooms vanish from Console and «New ▸ room» disappears while Desktop still
// shows the room.
//
// Contract evidence (NousResearch/hermes-agent main 491f984, 2026-11-13):
//  * gateway/hosted_room_discussion.py::validate_user_payload — message.user
//    is {text, thread_id} plus OPTIONAL `attachments`; text may be blank only
//    when attachments are present. No `reply_to`.
//  * gateway/hosted_room_attachments.py::validate_manifest — a list of at most
//    8 entries, each exactly {attachment_id, kind, name, size, mime}, id
//    `att_<32 hex>`, kind image|pdf|file (image→image/*, pdf→application/pdf),
//    0 < size <= 15 000 000, unique ids, total <= 25 000 000.
//  * gateway/hosted_room_discussion.py::_validate_member — `target` is
//    optional (missing → local member of that profile); any other unknown
//    member field is rejected.
//
// Tests tagged [RED] assert the behaviour the user needs and fail on the
// public 1.4.0 code; [CONTROL] tests must stay green before and after.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/bots/data/bot_mode_repository.dart';
import 'package:hermes_android/core/services/notifications/room_watcher.dart';

import 'support/inter_font.dart';
import 'support/rpc_frame_helpers.dart';

const _gw = 'gateway-regression';
const _attId1 = 'att_0123456789abcdef0123456789abcdef';
const _attId2 = 'att_fedcba9876543210fedcba9876543210';

Map<String, dynamic> _att({
  String id = _attId1,
  String kind = 'image',
  String name = 'foto.png',
  Object size = 1234,
  String mime = 'image/png',
  Map<String, Object?> extra = const {},
}) => {
  'attachment_id': id,
  'kind': kind,
  'name': name,
  'size': size,
  'mime': mime,
  ...extra,
};

Map<String, dynamic> _member(String profile, {Map<String, Object?>? extra}) => {
  'member_id': 'm-$profile',
  'profile': profile,
  'handle': profile,
  'target': {'kind': 'local', 'profile': profile},
  ...?extra,
};

Map<String, dynamic> _roomJson(
  String id,
  String name, {
  List<Map<String, dynamic>>? members,
  int latestSeq = 1,
}) => {
  'room_id': id,
  'name': name,
  'members': members ?? [_member('builder'), _member('reviewer')],
  'authority_gateway_id': _gw,
  'authority_epoch': 1,
  'revision': 1,
  'created_at': 1700000000.0,
  'updated_at': 1700000001.0,
  'idempotent': false,
  'latest_seq': latestSeq,
};

Map<String, dynamic> _userEvent(
  String roomId,
  int seq, {
  Map<String, Object?> payload = const {},
  String text = 'hola',
}) => {
  'room_id': roomId,
  'seq': seq,
  'event_id': 'user:$roomId-$seq',
  'kind': 'message.user',
  'actor': {'kind': 'user', 'id': 'desktop-user'},
  'authority_epoch': 1,
  'payload': {'text': text, 'thread_id': 'thread-$seq', ...payload},
  'created_at': 1700000002.0,
  'idempotent': false,
};

HostedGroupEvent _parse(Map<String, dynamic> event) =>
    HostedGroupEvent.fromJson(event, roomId: event['room_id'] as String);

Map<String, dynamic> _logJson(String roomId, List<Map<String, dynamic>> events) {
  final latest = events.isEmpty ? 0 : events.last['seq'] as int;
  return {
    'events': events,
    'cursor': latest,
    'latest_seq': latest,
    'has_more': false,
    'authority': {'gateway_id': _gw, 'epoch': 1},
  };
}

HostedGroupLogPage _log(String roomId, List<Map<String, dynamic>> events) =>
    HostedGroupLogPage.fromJson(
      _logJson(roomId, events),
      expectedRoomId: roomId,
      sinceSeq: 0,
    );

Map<String, dynamic> _caps({List<String>? methods}) => {
  'protocol_version': 2,
  'driver': true,
  'persistent_process': true,
  'authority_gateway_id': _gw,
  'room_link': {'enabled': false, 'reason': 'durable_run_storage_required'},
  'features': ['authority_epoch', 'room_identity', 'monotonic_log'],
  'methods':
      methods ??
      const [
        'groups.capabilities', 'groups.list', 'groups.create', 'groups.state',
        'groups.send', 'groups.rename', 'groups.log', 'groups.disband',
      ],
  'max_log_limit': 500,
};

GroupsCapabilities _parsedCaps() => GroupsCapabilities.tryParse(
  _caps(),
  connectionId: 'regression',
  generation: 1,
)!;

/// Two rooms through the real repository; [stateOf]/[logOf] may poison B.
MissionControlRepository _repo({
  Future<HostedGroupRoom> Function(String roomId)? stateOf,
  Future<HostedGroupLogPage> Function(String roomId)? logOf,
}) {
  final rooms = [
    HostedGroupRoom.fromJson(_roomJson('room-a', 'Room A')),
    HostedGroupRoom.fromJson(_roomJson('room-b', 'Room B')),
  ];
  return MissionControlRepository(
    profilesLoader: () async => const [],
    sessionsLoader: () async => const [],
    boardLoader: () async => const KanbanBoard(columns: []),
    hostedGroupsGateway: MissionHostedGroupsGateway.callbacks(
      capabilities: () async => _parsedCaps(),
      list: ({required generation}) async => rooms,
      state: (roomId, {required generation}) =>
          stateOf?.call(roomId) ??
          Future.value(rooms.firstWhere((r) => r.roomId == roomId)),
      log: (roomId, {required generation}) =>
          logOf?.call(roomId) ??
          Future.value(_log(roomId, [_userEvent(roomId, 1)])),
    ),
  );
}

MissionControlRepository _repoWith({
  Future<GroupsCapabilities> Function()? capabilities,
  MissionGroupsList? list,
  Future<HostedGroupRoom> Function(String roomId)? state,
}) {
  final rooms = [
    HostedGroupRoom.fromJson(_roomJson('room-a', 'Room A')),
    HostedGroupRoom.fromJson(_roomJson('room-b', 'Room B')),
  ];
  return MissionControlRepository(
    profilesLoader: () async => const [
      AgentProfile(name: 'builder'),
      AgentProfile(name: 'reviewer'),
    ],
    sessionsLoader: () async => const [],
    boardLoader: () async => const KanbanBoard(columns: []),
    hostedGroupsGateway: MissionHostedGroupsGateway.callbacks(
      capabilities: capabilities ?? () async => _parsedCaps(),
      list: list ?? ({required generation}) async => rooms,
      state: (roomId, {required generation}) =>
          state?.call(roomId) ??
          Future.value(rooms.firstWhere((r) => r.roomId == roomId)),
      log: (roomId, {required generation}) async =>
          _log(roomId, [_userEvent(roomId, 1)]),
    ),
  );
}

Future<void> _pumpBots(
  WidgetTester tester,
  MissionControlRepository repo, {
  bool readOnly = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  addTearDown(manager.dispose);
  addTearDown(repo.close);
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: MissionControlScreen(
        connection: SavedConnection(
          id: 'regression-b1',
          label: 'Regression',
          host: 'localhost',
          port: 8642,
          apiKey: 'unused',
          readOnly: readOnly,
        ),
        connManager: manager,
        dataSource: repo,
        snapshotCache: MissionSnapshotCache(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the New menu and reports whether «Room» is in it.
Future<bool> _roomCreationOffered(WidgetTester tester) async {
  final newButton = find.byKey(const ValueKey('mission-create-agent'));
  if (newButton.evaluate().isEmpty) return false;
  await tester.tap(newButton);
  await tester.pumpAndSettle();
  final offered = find
      .byKey(const ValueKey('mission-create-chooser-room'))
      .evaluate()
      .isNotEmpty;
  await tester.tapAt(const Offset(5, 5));
  await tester.pumpAndSettle();
  return offered;
}

/// Rooms shown from their last good read (review M1). Read dynamically so
/// the RED run on the API without it fails per test, not at compile time.
Set<String> _stale(HostedGroupsSnapshot s) =>
    ((s as dynamic).staleRoomIds as Set).cast<String>();

List<String> _names(MissionBackendSnapshot s) => [
  for (final room in s.hostedGroups.rooms) room.name,
];

bool _createOffered(MissionBackendSnapshot s) =>
    s.hostedGroupsCapability == MissionCapabilityState.available &&
    (s.hostedGroups.capabilities?.supports(GroupMethod.create) ?? false);

// ── real client over a local WebSocket (generation race) ──────────────────

final class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');
  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'test');
}

final class _Wire {
  final HttpServer server;
  final TuiGatewayClient client;
  final List<WebSocket> sockets;
  _Wire(this.server, this.client, this.sockets);

  static Future<_Wire> start({
    List<String>? methods,
    List<Map<String, dynamic>>? rooms,
    Map<String, List<Map<String, dynamic>>> events = const {},
    bool groups = true,
    Map<String, int> stateErrors = const {},
  }) async {
    final listed = rooms ?? [_roomJson('room-a', 'Room A')];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'regression-${sockets.length}'},
          },
        }),
      );
      socket.listen((raw) {
        final rpc = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
        final method = rpc['method'] as String;
        if (method == 'gateway.ping') return;
        if (isClientCapabilitiesFrame(rpc)) {
          socket.add(jsonEncode(clientCapabilitiesResponse(rpc)));
          return;
        }
        final params = Map<String, dynamic>.from(
          (rpc['params'] as Map?) ?? const {},
        );
        final roomId = params['room_id'];
        if (method == 'groups.state' && stateErrors.containsKey(roomId)) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': rpc['id'],
              'error': {
                'code': stateErrors[roomId],
                'message': 'hosted room state failed',
              },
            }),
          );
          return;
        }
        final Object? result = switch (method) {
          'groups.capabilities' => groups ? _caps(methods: methods) : null,
          'groups.list' => {'rooms': listed, 'next_offset': null},
          'groups.state' => {
            'room': listed.firstWhere((r) => r['room_id'] == roomId),
          },
          'groups.log' => _logJson(
            roomId as String,
            events[roomId] ?? [_userEvent(roomId, 1)],
          ),
          _ => null,
        };
        socket.add(
          jsonEncode(
            result == null
                ? {
                    'jsonrpc': '2.0',
                    'id': rpc['id'],
                    'error': {'code': -32601, 'message': 'method not found'},
                  }
                : {'jsonrpc': '2.0', 'id': rpc['id'], 'result': result},
          ),
        );
      });
    });
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'regression-connection',
        label: 'Regression',
        host: '127.0.0.1',
        port: 8642,
        dashboardUrl: 'http://127.0.0.1:${server.port}',
        apiKey: String.fromCharCodes(const [113, 97]),
      ),
      dashboard: _Dashboard(),
      heartbeatInterval: const Duration(hours: 1),
      heartbeatDeadline: const Duration(hours: 2),
    );
    return _Wire(server, client, sockets);
  }

  Future<void> dropAndAwaitReconnect() async {
    for (final s in List.of(sockets)) {
      await s.close(WebSocketStatus.goingAway, 'regression reconnect');
    }
    var deadline = DateTime.now().add(const Duration(seconds: 5));
    while (client.isConnected && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!client.isConnected && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> close() async {
    await client.close();
    await server.close(force: true);
  }
}

/// The real Bot Mode gateway for rooms; no profiles (the test server has
/// no `profiles.list`).
final class _RoomsOnlyBotGateway implements BotModeGateway {
  _RoomsOnlyBotGateway(this.inner);
  final TuiBotModeGateway inner;

  @override
  Future<List<AgentProfile>> listProfiles() async => const [];
  @override
  Future<DesktopActiveSessionList> listActiveSessions() async =>
      const DesktopActiveSessionList(sessions: []);
  @override
  Future<GroupsCapabilities> groupCapabilities() => inner.groupCapabilities();
  @override
  Future<List<HostedGroupRoom>> listGroups({required int generation}) =>
      inner.listGroups(generation: generation);
  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})> groupState(
    String roomId, {
    required int generation,
  }) => inner.groupState(roomId, generation: generation);
  @override
  Future<HostedGroupLogPage> groupLog(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) => inner.groupLog(
    roomId,
    sinceSeq: sinceSeq,
    limit: limit,
    generation: generation,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('regression: ${invocation.memberName}');
}

final class _NoPresenter implements RoomNoticePresenter {
  @override
  Future<void> present(
    String connId,
    HostedGroupRoom room,
    List<RoomNotice> notices,
  ) async {}
}

final class _OneSnapshotSource
    implements MissionControlDataSource, MissionHostedGroupsDataSource {
  final MissionBackendSnapshot snapshot;
  int loads = 0;
  _OneSnapshotSource(this.snapshot);

  @override
  Future<MissionBackendSnapshot> load() async {
    loads++;
    return snapshot;
  }

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('regression: ${invocation.memberName}');
}

MissionBackendSnapshot _partialSnapshot() => MissionBackendSnapshot(
  profiles: const [AgentProfile(name: 'builder'), AgentProfile(name: 'reviewer')],
  profilesCapability: MissionCapabilityState.available,
  sessionsCapability: MissionCapabilityState.available,
  kanbanCapability: MissionCapabilityState.available,
  board: const KanbanBoard(columns: []),
  hostedGroups: HostedGroupsSnapshot(
    capabilities: _parsedCaps(),
    rooms: [HostedGroupRoom.fromJson(_roomJson('room-a', 'Room A'))],
    logs: [_log('room-a', [_userEvent('room-a', 1)])],
    unreadableRooms: const [
      HostedGroupUnreadableRoom(
        roomId: 'room-b',
        name: 'Room B',
        reason: HostedGroupUnreadableReason.serverError,
      ),
    ],
  ),
  hostedGroupsCapability: MissionCapabilityState.available,
  loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
);

/// Mirrors the production `_TuiMissionHostedGroupsGateway` read surface
/// (mission_control_repository.dart), `listing` included.
final class _ProdShapedGateway
    implements
        MissionHostedGroupsGateway,
        MissionHostedGroupsIncrementalGateway,
        MissionHostedGroupsListingGateway {
  final TuiGatewayClient client;
  _ProdShapedGateway(this.client);

  @override
  Future<GroupsCapabilities> capabilities() => client.groupCapabilities();
  @override
  Future<List<HostedGroupRoom>> list({required int generation}) =>
      client.listGroups(generation: generation);
  @override
  Future<HostedGroupListing> listing({required int generation}) =>
      client.listGroupsDetailed(generation: generation);
  @override
  Future<HostedGroupRoom> state(String roomId, {required int generation}) =>
      client.groupState(roomId, generation: generation);
  @override
  Future<HostedGroupLogPage> log(String roomId, {required int generation}) =>
      client.groupLogComplete(roomId, generation: generation);
  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})>
  stateWithDriver(String roomId, {required int generation}) =>
      client.groupStateWithDriver(roomId, generation: generation);
  @override
  Future<HostedGroupLogPage> logSince(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) => client.groupLog(
    roomId,
    sinceSeq: sinceSeq,
    limit: limit,
    generation: generation,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('regression: read-only gateway');
}

Future<MissionBackendSnapshot> _loadThroughWire({
  required List<Map<String, dynamic>> rooms,
  Map<String, List<Map<String, dynamic>>> events = const {},
  bool groups = true,
}) async {
  final wire = await _Wire.start(rooms: rooms, events: events, groups: groups);
  try {
    return await MissionControlRepository(
      profilesLoader: () async => const [],
      sessionsLoader: () async => const [],
      boardLoader: () async => const KanbanBoard(columns: []),
      hostedGroupsGateway: _ProdShapedGateway(wire.client),
    ).load();
  } finally {
    await wire.close();
  }
}

void main() {
  setUpAll(loadInterFont);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('[RED] Bots: the healthy room lists, the unreadable one is '
      'reported with a retry, and New ▸ room stays offered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = _OneSnapshotSource(_partialSnapshot());
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: MissionControlScreen(
          connection: SavedConnection(
            id: 'regression-screen',
            label: 'Regression',
            host: 'localhost',
            port: 8642,
            apiKey: 'unused',
          ),
          connManager: manager,
          dataSource: source,
          snapshotCache: MissionSnapshotCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rows = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('roster-room-row-');
    });
    expect(rows, findsOneWidget, reason: 'room A only');
    expect(find.text('Room A'), findsWidgets);
    final notice = find.byKey(const ValueKey('mission-rooms-unreadable'));
    expect(notice, findsOneWidget);
    expect(
      find.descendant(of: notice, matching: find.text("1 room couldn't be loaded")),
      findsOneWidget,
    );
    expect(
      find.descendant(of: notice, matching: find.text('Not loaded: Room B')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    final loadsBefore = source.loads;
    await tester.tap(find.byKey(const ValueKey('mission-rooms-unreadable-retry')));
    await tester.pumpAndSettle();
    expect(source.loads, greaterThan(loadsBefore), reason: 'Retry reloads');

    await tester.tap(find.byKey(const ValueKey('mission-create-agent')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mission-create-chooser-room')),
      findsOneWidget,
    );
  });

  group('Bots screen over the real repository (review B1)', () {
    const failed = TuiGatewayRpcError(
      'groups.state',
      'hosted room state failed',
      code: 5115,
    );
    const timeout = TuiGatewayRpcError(
      'groups.list',
      'Timeout waiting for JSON-RPC response',
      failureKind: TuiGatewayRpcFailureKind.timeout,
    );

    testWidgets('[RED] cold start, every room 5115: both reported, '
        'New ▸ room offered', (tester) async {
      await _pumpBots(
        tester,
        _repoWith(state: (_) async => throw failed),
      );
      final notice = find.byKey(const ValueKey('mission-rooms-unreadable'));
      expect(notice, findsOneWidget);
      expect(
        find.descendant(
          of: notice,
          matching: find.text("2 rooms couldn't be loaded"),
        ),
        findsOneWidget,
      );
      expect(await _roomCreationOffered(tester), isTrue);
    });

    testWidgets('[RED] cold start, capabilities proven but groups.list timed '
        'out: rooms reported with Retry, New ▸ room offered', (tester) async {
      await _pumpBots(
        tester,
        _repoWith(list: ({required generation}) async => throw timeout),
      );
      expect(
        find.byKey(const ValueKey('mission-rooms-load-failed')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-rooms-unreadable-retry')),
        findsOneWidget,
      );
      expect(await _roomCreationOffered(tester), isTrue);
    });

    testWidgets('[RED] a room kept from its last good read is announced as '
        'not updated', (tester) async {
      var failB = false;
      final repo = _repoWith(
        state: (roomId) async {
          if (roomId == 'room-b' && failB) {
            throw const TuiGatewayRpcError(
              'groups.state',
              'database is locked',
              code: 5113,
            );
          }
          return HostedGroupRoom.fromJson(
            _roomJson(roomId, roomId == 'room-a' ? 'Room A' : 'Room B'),
          );
        },
      );
      await _pumpBots(tester, repo);
      expect(find.byKey(const ValueKey('mission-rooms-unreadable')), findsNothing);
      failB = true;
      // Pull-to-refresh: a full reload.
      final state = tester.state<RefreshIndicatorState>(
        find.byType(RefreshIndicator).first,
      );
      unawaited(state.show());
      await tester.pumpAndSettle();
      final rows = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('roster-room-row-');
      });
      expect(rows, findsNWidgets(2), reason: 'B stays on screen');
      final notice = find.byKey(const ValueKey('mission-rooms-unreadable'));
      expect(
        find.descendant(
          of: notice,
          matching: find.text("1 room couldn't be updated"),
        ),
        findsOneWidget,
      );
    });

    testWidgets('[CONTROL] capabilities that fail: no New ▸ room', (
      tester,
    ) async {
      await _pumpBots(
        tester,
        _repoWith(
          capabilities: () async => throw const TuiGatewayRpcError(
            'groups.capabilities',
            'Timeout waiting for JSON-RPC response',
            failureKind: TuiGatewayRpcFailureKind.timeout,
          ),
        ),
      );
      expect(await _roomCreationOffered(tester), isFalse);
    });

    testWidgets('[CONTROL] a server without groups.* (-32601): no New ▸ room', (
      tester,
    ) async {
      await _pumpBots(
        tester,
        _repoWith(
          capabilities: () async => throw const TuiGatewayRpcError(
            'groups.capabilities',
            'method not found',
            code: -32601,
          ),
        ),
      );
      expect(await _roomCreationOffered(tester), isFalse);
    });

    testWidgets('[CONTROL] a read-only connection: no New ▸ room, even with '
        'unreadable rooms', (tester) async {
      await _pumpBots(
        tester,
        _repoWith(state: (_) async => throw failed),
        readOnly: true,
      );
      expect(await _roomCreationOffered(tester), isFalse);
    });
  });

  group('message.user attachments (upstream validate_user_payload)', () {
    test('[RED] a text message with a valid attachment manifest parses', () {
      final event = _parse(
        _userEvent(
          'room-b',
          1,
          payload: {
            'attachments': [_att()],
          },
        ),
      );
      expect(event.publicText, 'hola');
      final file = event.attachments.single;
      expect(file.attachmentId, _attId1);
      expect(file.kind, 'image');
      expect(file.name, 'foto.png');
      expect(file.size, 1234);
      expect(file.mime, 'image/png');
    });

    test('[RED] an attachment-only message (blank text) parses and stays '
        'in the transcript', () {
      final event = _parse(
        _userEvent(
          'room-b',
          1,
          text: '',
          payload: {
            'attachments': [
              _att(kind: 'pdf', name: 'doc.pdf', mime: 'application/pdf'),
            ],
          },
        ),
      );
      expect(event.publicText, isNotNull);
      expect(event.publicText, isEmpty);
      expect(event.attachments.single.kind, 'pdf');
      final transcript = buildRoomTranscript(
        events: [event],
        members: const [],
      );
      expect(
        transcript.whereType<RoomMessageEntry>().single.event.eventId,
        event.eventId,
        reason: 'an attachment-only message stays in the transcript',
      );
    });

    test('[CONTROL] text plus an empty attachments list is accepted '
        '(upstream: the list is optional and may be empty)', () {
      final event = _parse(
        _userEvent('room-b', 1, payload: {'attachments': []}),
      );
      expect(event.publicText, 'hola');
      expect(event.attachments, isEmpty);
    });

    test('[CONTROL] a member message with an invalid manifest keeps its '
        'text and shows no files', () {
      final event = _parse({
        ..._userEvent('room-b', 1),
        'kind': 'message.member',
        'actor': {'kind': 'member', 'id': 'm-builder', 'profile': 'builder'},
        'payload': {
          'text': 'ok',
          'thread_id': 't',
          'member_id': 'm-builder',
          'attachments': [_att(id: 'bad')],
        },
      });
      expect(event.publicText, 'ok');
      expect(event.attachments, isEmpty);
    });

    final rejected = <String, Map<String, Object?>>{
      'reply_to is not part of the published contract': {
        'reply_to': {'event_id': 'user:room-b-0'},
      },
      'unknown payload field next to attachments': {
        'attachments': [_att()],
        'unknown': true,
      },
      'attachments is not a list': {'attachments': _att()},
      'attachment id not att_<32 hex>': {
        'attachments': [_att(id: 'att-1')],
      },
      'unknown attachment field': {
        'attachments': [
          _att(extra: {'path': '/etc/passwd'}),
        ],
      },
      'missing attachment field': {
        'attachments': [
          {
            'attachment_id': _attId1,
            'kind': 'file',
            'name': 'a.txt',
            'size': 3,
          },
        ],
      },
      'image kind with a non-image mime': {
        'attachments': [_att(mime: 'application/pdf')],
      },
      'pdf kind with a non-pdf mime': {
        'attachments': [_att(kind: 'pdf', mime: 'image/png')],
      },
      'unknown kind': {
        'attachments': [_att(kind: 'video', mime: 'video/mp4')],
      },
      'zero size': {
        'attachments': [_att(size: 0)],
      },
      'size above the 15 MB per-file limit': {
        'attachments': [_att(size: 15000001)],
      },
      'non-integer size': {
        'attachments': [_att(size: 12.5)],
      },
      'name with a path separator': {
        'attachments': [_att(name: '../secret.png')],
      },
      'name with a newline': {
        'attachments': [_att(name: 'a\nb.png')],
      },
      'invalid mime': {
        'attachments': [_att(kind: 'file', mime: 'not a mime')],
      },
      'duplicate attachment ids': {
        'attachments': [_att(), _att()],
      },
      'more than 8 attachments': {
        'attachments': [
          for (var i = 0; i < 9; i++)
            _att(id: 'att_${i.toRadixString(16).padLeft(32, '0')}'),
        ],
      },
      'total above 25 MB': {
        'attachments': [
          _att(size: 15000000),
          _att(id: _attId2, size: 10000001),
        ],
      },
    };
    for (final entry in rejected.entries) {
      test('[CONTROL] rejected: ${entry.key}', () {
        expect(
          () => _parse(_userEvent('room-b', 1, payload: entry.value)),
          throwsFormatException,
        );
      });
    }

    test('[CONTROL] blank text without attachments stays rejected', () {
      expect(() => _parse(_userEvent('room-b', 1, text: '  ')), throwsFormatException);
      expect(
        () => _parse(
          _userEvent('room-b', 1, text: '', payload: {'attachments': []}),
        ),
        throwsFormatException,
      );
    });
  });

  group('room members (upstream _validate_member)', () {
    test('[RED] a legacy member without target is a local member', () {
      final room = HostedGroupRoom.fromJson(
        _roomJson(
          'room-b',
          'Room B',
          members: [
            {'member_id': 'm-builder', 'profile': 'builder', 'handle': 'builder'},
            _member('reviewer'),
          ],
        ),
      );
      expect(room.members.first.owner.profile, 'builder');
      expect(room.members.first.owner.connectionId, _gw);
    });

    // Stable v0.23.1 (3b421578) tui_gateway/contracts/groups_bot_relay.py
    // RoomMember(OpenModel): «legacy rooms may carry pre-normalisation rows,
    // so the set stays open». Fields Console does not use are ignored (never
    // shown); the fields it uses are still validated. Supersedes the two
    // [CONTROL] rejections of an extra field written earlier in this series
    // (the owner's decision after the independent audit, 2026-11-14).
    // Upstream still rejects the member fields that would name another
    // gateway (`_REMOTE_MEMBER_FIELDS`); those stay rejected below (and in
    // hosted_groups_v13_test «hosted member source authority transition
    // matrix»). An earlier draft of this test wrongly listed `connectionId`
    // as ignorable; run r2regress1 caught it.
    for (final extra in <String, Map<String, Object?>>{
      'a legacy extra field': {'color': '#ff8800'},
      'an unknown nested extra': {
        'meta': {'origin': 'import'},
      },
    }.entries) {
      test('[RED] open member row: ${extra.key} is ignored, the room lists', () {
        final room = HostedGroupRoom.fromJson(
          _roomJson(
            'room-b',
            'Room B',
            members: [_member('builder', extra: extra.value), _member('reviewer')],
          ),
        );
        final member = room.members.first;
        expect(member.handle, 'builder');
        expect(member.owner.connectionId, _gw, reason: 'target decides');
        expect('${member.handle}${member.displayName}', isNot(contains('#ff8800')));
        expect('${member.owner}', isNot(contains('other')));
      });
    }

    final rejectedMembers = <String, Map<String, dynamic>>{
      'empty target': {
        'member_id': 'm-builder',
        'profile': 'builder',
        'handle': 'builder',
        'target': <String, Object?>{},
      },
      'a used field of the wrong type (handle)': {
        ..._member('builder'),
        'handle': 7,
      },
      'a used field missing (member_id)': {
        'profile': 'builder',
        'handle': 'builder',
        'target': {'kind': 'local', 'profile': 'builder'},
      },
      'display_name not a string': {
        ..._member('builder'),
        'display_name': ['x'],
      },
      'target profile mismatch': {
        ..._member('builder'),
        'target': {'kind': 'local', 'profile': 'reviewer'},
      },
      'cross-gateway field connectionId (upstream _REMOTE_MEMBER_FIELDS)':
          _member('builder', extra: {'connectionId': 'other'}),
      'cross-gateway field connection_id': _member(
        'builder',
        extra: {'connection_id': 'other'},
      ),
      'cross-gateway field route': _member(
        'builder',
        extra: {'route': 'relay'},
      ),
    };
    for (final entry in rejectedMembers.entries) {
      test('[CONTROL] rejected member: ${entry.key}', () {
        expect(
          () => HostedGroupRoom.fromJson(
            _roomJson('room-b', 'Room B', members: [entry.value]),
          ),
          throwsFormatException,
        );
      });
    }
  });

  group('one unreadable room does not hide the others', () {
    test('[RED] groups.list page: a malformed row leaves the healthy row', () {
      final page = HostedGroupListPage.fromJson({
        'rooms': [
          _roomJson('room-a', 'Room A'),
          _roomJson('room-b', 'Room\tB'),
        ],
        'next_offset': null,
      });
      expect([for (final r in page.rooms) r.name], ['Room A']);
      expect(page.rowCount, 2);
      final bad = page.unreadable.single;
      expect(bad.roomId, 'room-b');
      expect(bad.name, isNull, reason: 'nothing of a rejected row is shown');
      expect(bad.reason, HostedGroupUnreadableReason.invalidData);
    });

    test('[CONTROL] a malformed page envelope still fails the whole page', () {
      expect(
        () => HostedGroupListPage.fromJson({'rooms': 'nope'}),
        throwsFormatException,
      );
    });

    test('[RED] groups.state error on room B (4114): room A lists and '
        'creation stays offered', () async {
      final s = await _repo(
        stateOf: (roomId) async {
          if (roomId == 'room-b') {
            throw const TuiGatewayRpcError(
              'groups.state',
              'hosted room not found',
              code: 4114,
            );
          }
          return HostedGroupRoom.fromJson(_roomJson(roomId, 'Room A'));
        },
      ).load();
      expect(_names(s), ['Room A']);
      expect(_createOffered(s), isTrue);
      expect(s.failures.containsKey('hostedGroups'), isFalse);
      final bad = s.hostedGroups.unreadableRooms.single;
      expect(bad.roomId, 'room-b');
      expect(bad.name, 'Room B');
      expect(bad.reason, HostedGroupUnreadableReason.serverError);
      expect(s.hostedGroups.rooms.length, s.hostedGroups.logs.length);
    });

    test('[RED] invalid groups.log on room B: room A lists and creation '
        'stays offered', () async {
      final s = await _repo(
        logOf: (roomId) async {
          if (roomId == 'room-b') {
            // What the real client throws for a log it rejects.
            throw const GroupInvalidResponseError(
              'groups.log',
              'Hermes returned an invalid room log',
            );
          }
          return _log(roomId, [_userEvent(roomId, 1)]);
        },
      ).load();
      expect(_names(s), ['Room A']);
      expect(_createOffered(s), isTrue);
      expect(
        s.hostedGroups.unreadableRooms.single.reason,
        HostedGroupUnreadableReason.invalidData,
      );
    });

    test('[CONTROL] a no-code error of another method (gateway.connect '
        'backing off) is the connection\'s, not room B\'s', () async {
      final s = await _repo(
        stateOf: (roomId) async {
          if (roomId == 'room-b') {
            throw const TuiGatewayRpcError(
              'gateway.connect',
              'Hermes Desktop reconnect is backing off',
            );
          }
          return HostedGroupRoom.fromJson(_roomJson(roomId, 'Room A'));
        },
      ).load();
      expect(s.hostedGroupsCapability, MissionCapabilityState.unavailable);
      expect(s.hostedGroups.unreadableRooms, isEmpty);
    });

    // Review B1 (console-reddit-independent-review.md): the earlier
    // «2+ rooms all failing = whole-load failure» heuristic (two [CONTROL]
    // tests here, written in this same fix series) reproduced the reported
    // symptom on a cold start: no room and no «New ▸ room». Superseded by
    // the four tests below; the outcome no longer depends on how many rooms
    // there are.
    test('[RED] end to end: a room whose member row carries an extra legacy '
        'field lists with the others', () async {
      final s = await _loadThroughWire(
        rooms: [
          _roomJson('room-a', 'Room A'),
          _roomJson(
            'room-b',
            'Room B',
            members: [
              _member('builder', extra: {'color': '#ff8800'}),
              _member('reviewer'),
            ],
          ),
        ],
      );
      expect(_names(s), ['Room A', 'Room B']);
      expect(s.hostedGroups.unreadableRooms, isEmpty);
    });

    test('[RED] B1 cold load: every room answering its own server error '
        '(5115) lists both as unreadable and keeps creation', () async {
      const failed = TuiGatewayRpcError(
        'groups.state',
        'hosted room state failed',
        code: 5115,
      );
      final s = await _repo(stateOf: (_) async => throw failed).load();
      expect(s.hostedGroupsCapability, MissionCapabilityState.available);
      expect(s.failures.containsKey('hostedGroups'), isFalse);
      expect(_createOffered(s), isTrue);
      expect(s.hostedGroups.rooms, isEmpty);
      expect(
        [for (final r in s.hostedGroups.unreadableRooms) r.roomId],
        ['room-a', 'room-b'],
      );
    });

    test('[RED] B1 the same failure on one room or on two is classified the '
        'same way (no count heuristic)', () async {
      const failed = TuiGatewayRpcError(
        'groups.state',
        'database is locked',
        code: 5113,
      );
      final one = await _repo(
        stateOf: (roomId) async => roomId == 'room-b'
            ? throw failed
            : HostedGroupRoom.fromJson(_roomJson(roomId, 'Room A')),
      ).load();
      final both = await _repo(stateOf: (_) async => throw failed).load();
      expect(one.hostedGroupsCapability, both.hostedGroupsCapability);
      expect(
        one.hostedGroups.unreadableRooms.single.reason,
        HostedGroupUnreadableReason.serverError,
      );
      expect(
        {for (final r in both.hostedGroups.unreadableRooms) r.reason},
        {HostedGroupUnreadableReason.serverError},
      );
    });

    test('[RED] M1 warm refresh where every room fails transiently keeps '
        'both last good rooms, marked stale', () async {
      var fail = false;
      final repo = _repo(
        stateOf: (roomId) async {
          if (fail) {
            throw const TuiGatewayRpcError(
              'groups.state',
              'database is locked',
              code: 5113,
            );
          }
          return HostedGroupRoom.fromJson(
            _roomJson(roomId, roomId == 'room-a' ? 'Room A' : 'Room B'),
          );
        },
      );
      final first = await repo.load();
      fail = true;
      final refreshed = await repo.refreshHostedGroups(first.hostedGroups);
      expect([for (final r in refreshed.rooms) r.name], ['Room A', 'Room B']);
      expect(refreshed.rooms.length, refreshed.logs.length);
      expect(_stale(refreshed), {'room-a', 'room-b'});
      expect(refreshed.unreadableRooms, isEmpty);
    });

    test('[RED] M1 full reload (pull-to-refresh) where room B fails '
        'transiently keeps B from the last good read, marked stale', () async {
      var failB = false;
      final repo = _repo(
        stateOf: (roomId) async {
          if (roomId == 'room-b' && failB) {
            throw const TuiGatewayRpcError(
              'groups.state',
              'database is locked',
              code: 5113,
            );
          }
          return HostedGroupRoom.fromJson(
            _roomJson(roomId, roomId == 'room-a' ? 'Room A' : 'Room B'),
          );
        },
      );
      final first = await repo.load();
      expect(_names(first), ['Room A', 'Room B']);
      failB = true;
      final reloaded = await repo.load();
      expect(_names(reloaded), ['Room A', 'Room B']);
      expect(_stale(reloaded.hostedGroups), {'room-b'});
      expect(reloaded.hostedGroups.unreadableRooms, isEmpty);
      expect(
        reloaded.hostedGroups.rooms.length,
        reloaded.hostedGroups.logs.length,
      );
      failB = false;
      final healed = await repo.load();
      expect(_names(healed), ['Room A', 'Room B']);
      expect(_stale(healed.hostedGroups), isEmpty);
    });

    test('[CONTROL] M1 data Console rejects is never papered over with the '
        'last good copy: the room becomes unreadable', () async {
      var bad = false;
      final repo = _repo(
        logOf: (roomId) async {
          if (roomId == 'room-b' && bad) {
            throw const GroupInvalidResponseError(
              'groups.log',
              'Hermes returned an invalid room log',
            );
          }
          return _log(roomId, [_userEvent(roomId, 1)]);
        },
      );
      await repo.load();
      bad = true;
      final reloaded = await repo.load();
      expect(_names(reloaded), ['Room A'], reason: 'B is not retained');
      expect(
        reloaded.hostedGroups.unreadableRooms.single.reason,
        HostedGroupUnreadableReason.invalidData,
      );
    });

    test('[RED] creation does not depend on reading rooms: capabilities '
        'proven, groups.list timed out → the snapshot keeps them', () async {
      const timeout = TuiGatewayRpcError(
        'groups.list',
        'Timeout waiting for JSON-RPC response',
        failureKind: TuiGatewayRpcFailureKind.timeout,
      );
      final s = await MissionControlRepository(
        profilesLoader: () async => const [],
        sessionsLoader: () async => const [],
        boardLoader: () async => const KanbanBoard(columns: []),
        hostedGroupsGateway: MissionHostedGroupsGateway.callbacks(
          capabilities: () async => _parsedCaps(),
          list: ({required generation}) async => throw timeout,
          state: (roomId, {required generation}) async =>
              throw UnimplementedError(),
          log: (roomId, {required generation}) async =>
              throw UnimplementedError(),
        ),
      ).load();
      expect(s.hostedGroupsCapability, MissionCapabilityState.unavailable);
      expect(s.failures['hostedGroups'], same(timeout));
      expect(s.hostedGroups.rooms, isEmpty);
      expect(
        s.hostedGroups.capabilities?.supports(GroupMethod.create),
        isTrue,
        reason: 'the proven capabilities survive a failed read',
      );
    });

    test('[RED] incremental refresh: room B failing later (5113) stays '
        'from its last good read, marked stale; room A is fresh', () async {
      var failB = false;
      final repo = _repo(
        stateOf: (roomId) async {
          if (roomId == 'room-b' && failB) {
            throw const TuiGatewayRpcError(
              'groups.state',
              'database is locked',
              code: 5113,
            );
          }
          return HostedGroupRoom.fromJson(
            _roomJson(roomId, roomId == 'room-a' ? 'Room A' : 'Room B'),
          );
        },
      );
      final first = await repo.load();
      expect(_names(first), ['Room A', 'Room B']);
      failB = true;
      final refreshed = await repo.refreshHostedGroups(first.hostedGroups);
      // Review M1: before, B left `rooms` for a transient error even though
      // its previous read was valid.
      expect([for (final r in refreshed.rooms) r.name], ['Room A', 'Room B']);
      expect(_stale(refreshed), {'room-b'});
      expect(refreshed.unreadableRooms, isEmpty);
      expect(refreshed.rooms.length, refreshed.logs.length);
      failB = false;
      final healed = await repo.refreshHostedGroups(refreshed);
      expect([for (final r in healed.rooms) r.name], ['Room A', 'Room B']);
      expect(healed.unreadableRooms, isEmpty);
      expect(_stale(healed), isEmpty, reason: 'a stale room is re-read');
    });

    test('[CONTROL] a room failing on a fresh repository (no last good '
        'read) is unreadable, never invented', () async {
      final s = await _repo(
        stateOf: (roomId) async => roomId == 'room-b'
            ? throw const TuiGatewayRpcError(
                'groups.state',
                'database is locked',
                code: 5113,
              )
            : HostedGroupRoom.fromJson(_roomJson(roomId, 'Room A')),
      ).load();
      expect(_names(s), ['Room A']);
      expect(s.hostedGroups.unreadableRooms.single.roomId, 'room-b');
    });

    for (final global in const [
      TuiGatewayRpcError(
        'groups.state',
        'Hermes connection changed during the group operation',
        failureKind: TuiGatewayRpcFailureKind.connectionLost,
      ),
      TuiGatewayRpcError(
        'groups.log',
        'Timeout waiting for JSON-RPC response',
        failureKind: TuiGatewayRpcFailureKind.timeout,
      ),
    ]) {
      test('[CONTROL] ${global.failureKind!.name} while reading room B is a '
          'whole-load failure, never an «unreadable room»', () async {
        final s = await _repo(
          stateOf: (roomId) async {
            if (roomId == 'room-b') throw global;
            return HostedGroupRoom.fromJson(_roomJson(roomId, 'Room A'));
          },
        ).load();
        expect(s.hostedGroupsCapability, MissionCapabilityState.unavailable);
        expect(s.failures['hostedGroups'], same(global));
        expect(s.hostedGroups.rooms, isEmpty);
      });
    }
  });

  group('end to end over the real client', () {
    test('a Desktop message with a valid image lists both rooms', () async {
      final s = await _loadThroughWire(
        rooms: [_roomJson('room-a', 'Room A'), _roomJson('room-b', 'Room B')],
        events: {
          'room-b': [
            _userEvent(
              'room-b',
              1,
              payload: {
                'attachments': [_att()],
              },
            ),
          ],
        },
      );
      expect(_names(s), ['Room A', 'Room B']);
      expect(_createOffered(s), isTrue);
      expect(s.hostedGroups.unreadableRooms, isEmpty);
      expect(s.hostedGroups.logs[1].events.single.attachments.single.name, 'foto.png');
    });

    test('a list row Console rejects is kept apart; the rest loads', () async {
      final s = await _loadThroughWire(
        rooms: [
          _roomJson('room-a', 'Room A'),
          // A control character in the name (still rejected; an extra member
          // field no longer is: the member row is an open model upstream).
          _roomJson('room-b', 'Room\tB'),
        ],
      );
      expect(_names(s), ['Room A']);
      expect(_createOffered(s), isTrue);
      expect(s.hostedGroups.unreadableRooms.single.roomId, 'room-b');
      expect(s.hostedGroups.unreadableRooms.single.name, isNull);
    });

    test('an attachment Console must reject (non-conformant id) hides only '
        'that room', () async {
      final s = await _loadThroughWire(
        rooms: [_roomJson('room-a', 'Room A'), _roomJson('room-b', 'Room B')],
        events: {
          'room-b': [
            _userEvent(
              'room-b',
              1,
              payload: {
                'attachments': [_att(id: 'att-1')],
              },
            ),
          ],
        },
      );
      expect(_names(s), ['Room A']);
      expect(_createOffered(s), isTrue);
      expect(
        s.hostedGroups.unreadableRooms.single.reason,
        HostedGroupUnreadableReason.invalidData,
      );
    });
  });

  group('server without rooms (diagnostic H2f, review §7.2)', () {
    test('[RED] groups.capabilities answering -32601 is «unsupported», not '
        '«unavailable», and offers no creation', () async {
      final s = await _loadThroughWire(rooms: const [], groups: false);
      expect(s.hostedGroupsCapability, MissionCapabilityState.unsupported);
      expect(_createOffered(s), isFalse);
      expect(s.hostedGroups.rooms, isEmpty);
    });

    test('[CONTROL] a capabilities timeout stays «unavailable» (never '
        'cached as unsupported)', () async {
      final s = await MissionControlRepository(
        profilesLoader: () async => const [],
        sessionsLoader: () async => const [],
        boardLoader: () async => const KanbanBoard(columns: []),
        hostedGroupsGateway: MissionHostedGroupsGateway.callbacks(
          capabilities: () async => throw const TuiGatewayRpcError(
            'groups.capabilities',
            'Timeout waiting for JSON-RPC response',
            failureKind: TuiGatewayRpcFailureKind.timeout,
          ),
          list: ({required generation}) async => const [],
          state: (roomId, {required generation}) async =>
              throw UnimplementedError(),
          log: (roomId, {required generation}) async =>
              throw UnimplementedError(),
        ),
      ).load();
      expect(s.hostedGroupsCapability, MissionCapabilityState.unavailable);
    });

    test('[CONTROL] after a -32601 the next read asks again (not cached)', () async {
      final cache = GroupsCapabilityCache();
      var calls = 0;
      Future<Object?> missing() async {
        calls++;
        throw const TuiGatewayRpcError(
          'groups.capabilities',
          'method not found',
          code: -32601,
        );
      }

      for (var i = 0; i < 2; i++) {
        try {
          await cache.resolve(
            connectionId: 'c',
            generation: 1,
            loader: missing,
          );
        } catch (_) {}
      }
      expect(calls, 2);
    });
  });

  group('background room watcher over the real client (review §7.3)', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    RoomWatcher watcher() => RoomWatcher(
      connId: 'c1',
      prefs: prefs,
      presenter: _NoPresenter(),
      claim: (_, _, _) async => true,
    );

    Map<String, Object?> stored() => Map<String, Object?>.from(
      jsonDecode(prefs.getString(RoomWatcher.storageKey) ?? '{}') as Map,
    );

    test('[RED] a list row Console rejects no longer stops the watch of the '
        'other rooms', () async {
      final wire = await _Wire.start(
        rooms: [
          _roomJson('room-a', 'Room A'),
          _roomJson('room-b', 'Room\tB'),
        ],
      );
      try {
        final w = watcher();
        expect(await w.tick(TuiBotModeGateway(wire.client)), isTrue);
        expect([for (final v in w.views) v.room.roomId], ['room-a']);
      } finally {
        await wire.close();
      }
    });

    test('[RED] a room whose groups.state fails (5115) no longer stops the '
        'watch of the other rooms', () async {
      final wire = await _Wire.start(
        rooms: [_roomJson('room-a', 'Room A'), _roomJson('room-b', 'Room B')],
        stateErrors: const {'room-b': 5115},
      );
      try {
        final w = watcher();
        expect(await w.tick(TuiBotModeGateway(wire.client)), isTrue);
        expect([for (final v in w.views) v.room.roomId], ['room-a']);
      } finally {
        await wire.close();
      }
    });

    test('[RED] a room that cannot be read keeps its stored watch state '
        '(no silent re-baseline that would drop its notices)', () async {
      final good = await _Wire.start(
        rooms: [_roomJson('room-a', 'Room A'), _roomJson('room-b', 'Room B')],
      );
      final w = watcher();
      try {
        expect(await w.tick(TuiBotModeGateway(good.client)), isTrue);
      } finally {
        await good.close();
      }
      final before = stored();
      final keyB = before.keys.singleWhere((k) => k.endsWith(':room-b'));
      for (final broken in [
        _Wire.start(
          rooms: [_roomJson('room-a', 'Room A'), _roomJson('room-b', 'Room B')],
          stateErrors: const {'room-b': 5115},
        ),
        _Wire.start(
          rooms: [
            _roomJson('room-a', 'Room A'),
            _roomJson('room-b', 'Room\tB'),
          ],
        ),
      ]) {
        final wire = await broken;
        try {
          expect(await w.tick(TuiBotModeGateway(wire.client)), isTrue);
          expect(stored()[keyB], before[keyB]);
        } finally {
          await wire.close();
        }
      }
    });

    test('[CONTROL] a lost connection still fails the whole pass', () async {
      final wire = await _Wire.start(
        rooms: [_roomJson('room-a', 'Room A')],
      );
      final gateway = TuiBotModeGateway(wire.client);
      await wire.close();
      expect(await watcher().tick(gateway), isFalse);
    });

    test('[RED] a server without groups.* (-32601) is unsupported: the '
        'watcher waits its long delay, not the failure backoff', () async {
      final wire = await _Wire.start(rooms: const [], groups: false);
      var now = DateTime(2026, 11, 13, 12);
      try {
        final w = RoomWatcher(
          connId: 'c1',
          prefs: prefs,
          presenter: _NoPresenter(),
          claim: (_, _, _) async => true,
          now: () => now,
        );
        expect(await w.tick(TuiBotModeGateway(wire.client)), isFalse);
        now = now.add(const Duration(minutes: 5));
        expect(w.allowsAttempt, isFalse, reason: 'within maxDelay (15 min)');
        now = now.add(const Duration(minutes: 11));
        expect(w.allowsAttempt, isTrue);
      } finally {
        await wire.close();
      }
    });
  });

  group('Bot Mode repository (no production caller; kept consistent)', () {
    test('[RED] one room failing (5115) leaves the others and the '
        'capabilities in the snapshot', () async {
      final wire = await _Wire.start(
        rooms: [_roomJson('room-a', 'Room A'), _roomJson('room-b', 'Room B')],
        stateErrors: const {'room-b': 5115},
      );
      try {
        final repo = BotModeRepository(
          gateway: _RoomsOnlyBotGateway(TuiBotModeGateway(wire.client)),
        );
        final snapshot = await repo.load();
        expect(snapshot.capabilities, isNotNull);
        expect([for (final r in snapshot.rooms) r.room.roomId], ['room-a']);
        repo.close();
      } finally {
        await wire.close();
      }
    });
  });

  group('reconnect generation race (real client)', () {
    test('[RED] a stale capability generation after a reconnect is a lost '
        'connection, not «method not found»', () async {
      final wire = await _Wire.start();
      try {
        final first = await wire.client.groupCapabilities();
        await wire.dropAndAwaitReconnect();
        Object? caught;
        try {
          await wire.client.listGroups(generation: first.generation);
        } catch (error) {
          caught = error;
        }
        expect(caught, isA<TuiGatewayRpcError>());
        final error = caught! as TuiGatewayRpcError;
        expect(error.code, isNot(-32601), reason: '$error');
        expect(error.failureKind, TuiGatewayRpcFailureKind.connectionLost);
      } finally {
        await wire.close();
      }
    });

    test('[CONTROL] a method the server does not advertise stays -32601', () async {
      final wire = await _Wire.start(
        methods: const ['groups.capabilities', 'groups.list'],
      );
      try {
        final caps = await wire.client.groupCapabilities();
        Object? caught;
        try {
          await wire.client.groupState('room-a', generation: caps.generation);
        } catch (error) {
          caught = error;
        }
        expect(caught, isA<TuiGatewayRpcError>());
        expect((caught! as TuiGatewayRpcError).code, -32601);
      } finally {
        await wire.close();
      }
    });
  });
}
