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
import 'package:hermes_android/core/services/mission_snapshot_prewarm.dart';
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

GroupsCapabilities _parsedCaps({List<String>? methods}) =>
    GroupsCapabilities.tryParse(
      _caps(methods: methods),
      connectionId: 'regression',
      generation: 1,
    )!;

/// Two rooms through the real repository; [stateOf]/[logOf] may poison B,
/// [listError] (when it returns an error) fails `groups.list`. Every read is
/// recorded in [reads] (`groups.list`, `groups.state:<id>`, `groups.log:<id>`).
MissionControlRepository _repo({
  Future<HostedGroupRoom> Function(String roomId)? stateOf,
  Future<HostedGroupLogPage> Function(String roomId)? logOf,
  TuiGatewayRpcError? Function()? listError,
  List<String>? reads,
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
      list: ({required generation}) async {
        reads?.add('groups.list');
        if (listError?.call() case final error?) throw error;
        return rooms;
      },
      state: (roomId, {required generation}) {
        reads?.add('groups.state:$roomId');
        return stateOf?.call(roomId) ??
            Future.value(rooms.firstWhere((r) => r.roomId == roomId));
      },
      log: (roomId, {required generation}) {
        reads?.add('groups.log:$roomId');
        return logOf?.call(roomId) ??
            Future.value(_log(roomId, [_userEvent(roomId, 1)]));
      },
    ),
  );
}

/// A read of one room (`groups.state` or `groups.log`) recorded by [_repo]
/// or [_repoWith]: the room list never makes one.
bool _isRoomRead(String read) =>
    read.startsWith('groups.state:') || read.startsWith('groups.log:');

int _listReads(List<String> reads) =>
    reads.where((read) => read == 'groups.list').length;

/// [_repo]'s callbacks gateway with `groups.list` answered through
/// [MissionHostedGroupsListingGateway], so rows Console rejects are kept
/// apart as [unreadable], as the production gateway does.
final class _ListingGateway
    implements MissionHostedGroupsGateway, MissionHostedGroupsListingGateway {
  _ListingGateway(this.inner, this.unreadable);
  final MissionHostedGroupsGateway inner;
  final List<HostedGroupUnreadableRoom> unreadable;

  @override
  Future<GroupsCapabilities> capabilities() => inner.capabilities();
  @override
  Future<List<HostedGroupRoom>> list({required int generation}) =>
      inner.list(generation: generation);
  @override
  Future<HostedGroupListing> listing({required int generation}) async =>
      HostedGroupListing(
        rooms: await inner.list(generation: generation),
        unreadable: unreadable,
      );
  @override
  Future<HostedGroupRoom> state(String roomId, {required int generation}) =>
      inner.state(roomId, generation: generation);
  @override
  Future<HostedGroupLogPage> log(String roomId, {required int generation}) =>
      inner.log(roomId, generation: generation);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('regression: ${invocation.memberName}');
}

MissionControlRepository _repoWith({
  Future<GroupsCapabilities> Function()? capabilities,
  MissionGroupsList? list,
  Future<HostedGroupRoom> Function(String roomId)? state,
  List<HostedGroupUnreadableRoom> unreadable = const [],
  List<String>? reads,
}) {
  final rooms = [
    HostedGroupRoom.fromJson(_roomJson('room-a', 'Room A')),
    HostedGroupRoom.fromJson(_roomJson('room-b', 'Room B')),
  ];
  final gateway = MissionHostedGroupsGateway.callbacks(
    capabilities: capabilities ?? () async => _parsedCaps(),
    list: ({required generation}) async {
      reads?.add('groups.list');
      if (list != null) return list(generation: generation);
      return rooms;
    },
    state: (roomId, {required generation}) {
      reads?.add('groups.state:$roomId');
      return state?.call(roomId) ??
          Future.value(rooms.firstWhere((r) => r.roomId == roomId));
    },
    log: (roomId, {required generation}) async {
      reads?.add('groups.log:$roomId');
      return _log(roomId, [_userEvent(roomId, 1)]);
    },
  );
  return MissionControlRepository(
    profilesLoader: () async => const [
      AgentProfile(name: 'builder'),
      AgentProfile(name: 'reviewer'),
    ],
    sessionsLoader: () async => const [],
    boardLoader: () async => const KanbanBoard(columns: []),
    hostedGroupsGateway: unreadable.isEmpty
        ? gateway
        : _ListingGateway(gateway, unreadable),
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

/// The room rows of the Bots screen.
Finder get _roomRows => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith('roster-room-row-');
});

/// Rooms A and B as `groups.list` gave them, each without a log or a driver
/// status: no view of either read it, so their conversation is unknown
/// (never empty), and nothing is reported as unreadable.
void _expectListedAlone(HostedGroupsSnapshot hosted) {
  expect([for (final r in hosted.rooms) r.name], ['Room A', 'Room B']);
  expect(hosted.unreadableRooms, isEmpty);
  expect(hosted.logAt(0), isNull);
  expect(hosted.logAt(1), isNull);
  expect(hosted.driverStatuses, isEmpty);
}

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
      client.listGroupsDetailed(limit: 100, generation: generation);
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

/// [body] with a repository over a [_Wire] serving [rooms] and [events];
/// both are closed afterwards.
Future<void> _withWireRepo({
  required List<Map<String, dynamic>> rooms,
  Map<String, List<Map<String, dynamic>>> events = const {},
  required Future<void> Function(MissionControlRepository repo) body,
}) async {
  final wire = await _Wire.start(rooms: rooms, events: events);
  final repo = MissionControlRepository(
    profilesLoader: () async => const [],
    sessionsLoader: () async => const [],
    boardLoader: () async => const KanbanBoard(columns: []),
    hostedGroupsGateway: _ProdShapedGateway(wire.client),
  );
  try {
    await body(repo);
  } finally {
    repo.close();
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

    expect(_roomRows, findsOneWidget, reason: 'room A only');
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
    expect(
      find.byKey(const ValueKey('mission-rooms-unreadable-body')),
      findsOneWidget,
    );
    // The list read itself answered: no failed read to name.
    expect(
      find.byKey(const ValueKey('mission-rooms-read-detail')),
      findsNothing,
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

    // The rooms list is groups.list alone, as Desktop: a room whose
    // groups.state answers 5115 is listed like the others, because no room
    // is read to list it (it was reported unreadable when every room was
    // read to build the list).
    testWidgets('[RED] cold start where every groups.state would answer '
        '5115: both rooms list, no notice, New ▸ room offered', (tester) async {
      final reads = <String>[];
      await _pumpBots(
        tester,
        _repoWith(reads: reads, state: (_) async => throw failed),
      );
      expect(_roomRows, findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('mission-rooms-unreadable')),
        findsNothing,
      );
      expect(reads.where(_isRoomRead), isEmpty);
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
      // Which read failed, as Desktop shows its list error.
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('mission-rooms-read-detail')),
            )
            .data,
        'groups.list · timeout',
      );
      expect(
        find.byKey(const ValueKey('mission-rooms-unreadable-retry')),
        findsOneWidget,
      );
      expect(await _roomCreationOffered(tester), isTrue);
    });

    // Replaces «a room the connection left unread is named, with the read
    // that failed»: no room is read to list it, so a groups.state that would
    // time out leaves nothing unread. The notice names only rows the list
    // itself could not parse, and has no failed read to name while the
    // list answered.
    testWidgets('a room whose groups.state would time out still lists, also '
        'on the 10 s list refresh; only a row the list rejected is reported, '
        'with Retry and no failed read named', (tester) async {
      final reads = <String>[];
      await _pumpBots(
        tester,
        _repoWith(
          reads: reads,
          unreadable: const [
            HostedGroupUnreadableRoom(
              roomId: 'room-c',
              reason: HostedGroupUnreadableReason.invalidData,
            ),
          ],
          state: (roomId) async {
            if (roomId == 'room-b') {
              throw const TuiGatewayRpcError(
                'groups.state',
                'Timeout waiting for JSON-RPC response',
                failureKind: TuiGatewayRpcFailureKind.timeout,
              );
            }
            return HostedGroupRoom.fromJson(_roomJson(roomId, 'Room A'));
          },
        ),
      );
      expect(_roomRows, findsNWidgets(2));
      final notice = find.byKey(const ValueKey('mission-rooms-unreadable'));
      expect(
        find.descendant(
          of: notice,
          matching: find.text("1 room couldn't be loaded"),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: notice, matching: find.text('Not loaded: Room B')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mission-rooms-unreadable-body')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-rooms-read-detail')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mission-rooms-unreadable-retry')),
        findsOneWidget,
      );

      // The list is read again every 10 s (the screen's
      // `roomsRefreshInterval`), groups.list only.
      final listed = _listReads(reads);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(_listReads(reads), greaterThan(listed));
      expect(reads.where(_isRoomRead), isEmpty);
      expect(_roomRows, findsNWidgets(2));
      expect(await _roomCreationOffered(tester), isTrue);
    });

    // Replaces «a room kept from its last good read is announced as not
    // updated»: a reload reads no room, so a room whose read would fail
    // transiently is never left behind nor marked; B stays on screen.
    testWidgets('[RED] pull-to-refresh while room B\'s groups.state would '
        'answer 5113 keeps both rooms, with no notice', (tester) async {
      var failB = false;
      final reads = <String>[];
      final repo = _repoWith(
        reads: reads,
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
      final listed = _listReads(reads);
      // Pull-to-refresh: a full reload.
      final state = tester.state<RefreshIndicatorState>(
        find.byType(RefreshIndicator).first,
      );
      unawaited(state.show());
      await tester.pumpAndSettle();
      expect(_listReads(reads), greaterThan(listed), reason: 'it reloaded');
      expect(_roomRows, findsNWidgets(2), reason: 'B stays on screen');
      expect(
        find.byKey(const ValueKey('mission-rooms-unreadable')),
        findsNothing,
      );
      expect(reads.where(_isRoomRead), isEmpty);
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
        _repoWith(
          state: (_) async => throw failed,
          unreadable: const [
            HostedGroupUnreadableRoom(
              roomId: 'room-c',
              reason: HostedGroupUnreadableReason.invalidData,
            ),
          ],
        ),
        readOnly: true,
      );
      expect(
        find.byKey(const ValueKey('mission-rooms-unreadable')),
        findsOneWidget,
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

    // The rooms list is groups.list alone, as Desktop
    // (`canonical-group-registry.tsx` `useGatewayGroupRooms`): no room's
    // groups.state or groups.log is read to list it, so no failure of one
    // can hide a room, shorten the list or take «New ▸ room» away (review
    // B1: the reported symptom was no room and no «New ▸ room»). Each entry
    // replaces tests of the earlier design, in which every room was read to
    // build the list and a room whose read failed was reported unreadable,
    // kept from its last good read marked stale, or named as not read; the
    // entry names the failure those tests used.
    const notFound = TuiGatewayRpcError(
      'groups.state',
      'hosted room not found',
      code: 4114,
    );
    // What the real client throws for a log it rejects.
    const invalidLog = GroupInvalidResponseError(
      'groups.log',
      'Hermes returned an invalid room log',
    );
    const backingOff = TuiGatewayRpcError(
      'gateway.connect',
      'Hermes Desktop reconnect is backing off',
    );
    const stateFailed = TuiGatewayRpcError(
      'groups.state',
      'hosted room state failed',
      code: 5115,
    );
    const locked = TuiGatewayRpcError(
      'groups.state',
      'database is locked',
      code: 5113,
    );
    const lost = TuiGatewayRpcError(
      'groups.state',
      'Hermes connection changed during the group operation',
      failureKind: TuiGatewayRpcFailureKind.connectionLost,
    );
    const logTimeout = TuiGatewayRpcError(
      'groups.log',
      'Timeout waiting for JSON-RPC response',
      failureKind: TuiGatewayRpcFailureKind.timeout,
    );
    // (name, error, on every room or on room B only, thrown by groups.log
    // instead of groups.state)
    for (final (name, error, everyRoom, onLog)
        in <(String, TuiGatewayRpcError, bool, bool)>[
          ('groups.state error on room B (4114)', notFound, false, false),
          ('invalid groups.log on room B', invalidLog, false, true),
          (
            'a no-code error of another method (gateway.connect backing '
                'off) on room B',
            backingOff,
            false,
            false,
          ),
          ('every room answering its own server error (5115)', stateFailed,
              true, false),
          ('room B failing transiently (5113)', locked, false, false),
          ('every room failing transiently (5113)', locked, true, false),
          ('connectionLost while reading room B', lost, false, false),
          ('timeout while reading room B', logTimeout, false, true),
          ('connectionLost on every room', lost, true, false),
          ('timeout on every room', logTimeout, true, true),
        ]) {
      test('[RED] $name cannot hide a room: both list from groups.list alone '
          'on load, reload and refresh, creation stays offered, and no room '
          'is read', () async {
        final reads = <String>[];
        bool hit(String roomId) => everyRoom || roomId == 'room-b';
        final repo = _repo(
          reads: reads,
          stateOf: (roomId) async {
            if (!onLog && hit(roomId)) throw error;
            return HostedGroupRoom.fromJson(
              _roomJson(roomId, roomId == 'room-a' ? 'Room A' : 'Room B'),
            );
          },
          logOf: (roomId) async {
            if (onLog && hit(roomId)) throw error;
            return _log(roomId, [_userEvent(roomId, 1)]);
          },
        );
        final first = await repo.load();
        final reloaded = await repo.load();
        final refreshed = await repo.refreshHostedGroups(first.hostedGroups);
        for (final s in [first, reloaded]) {
          expect(s.hostedGroupsCapability, MissionCapabilityState.available);
          expect(s.failures.containsKey('hostedGroups'), isFalse);
          expect(_createOffered(s), isTrue);
          _expectListedAlone(s.hostedGroups);
        }
        _expectListedAlone(refreshed);
        expect(_listReads(reads), 3);
        expect(reads.where(_isRoomRead), isEmpty);
      });
    }

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

    // Replaces «M1 data Console rejects is never papered over with the last
    // good copy: the room becomes unreadable». The list no longer reads a
    // room's log, so it cannot reject one: the view of the room reads it and
    // gets the error. Nothing of the rejected data reaches the list; the
    // row keeps the log the view last read correctly.
    test('[CONTROL] a view read Console rejects fails to the view and puts '
        'nothing of it in the list', () async {
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
      final first = await repo.load();
      final roomB = first.hostedGroups.rooms[1];
      await repo.readHostedGroup(roomB, generation: 1);
      bad = true;
      await expectLater(
        repo.readHostedGroup(roomB, generation: 1),
        throwsA(isA<GroupInvalidResponseError>()),
      );
      final reloaded = await repo.load();
      expect(_names(reloaded), ['Room A', 'Room B']);
      expect(reloaded.hostedGroups.unreadableRooms, isEmpty);
      expect(reloaded.hostedGroups.logAt(0), isNull);
      expect(
        [for (final e in reloaded.hostedGroups.logAt(1)!.events) e.eventId],
        ['user:room-b-1'],
        reason: 'what the view last read correctly, nothing after it',
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

    // Replaces «a room failing on a fresh repository (no last good read)
    // is unreadable, never invented»: a room no view read is listed with no
    // log and no driver status (unknown, never an invented empty log), and
    // a view read of it that fails leaves it so.
    test('[CONTROL] a room no view read has no log nor driver status: '
        'unknown, never invented', () async {
      final repo = _repo(
        stateOf: (roomId) async => roomId == 'room-b'
            ? throw const TuiGatewayRpcError(
                'groups.state',
                'database is locked',
                code: 5113,
              )
            : HostedGroupRoom.fromJson(_roomJson(roomId, 'Room A')),
      );
      final s = await repo.load();
      _expectListedAlone(s.hostedGroups);
      await expectLater(
        repo.readHostedGroup(s.hostedGroups.rooms[1], generation: 1),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      _expectListedAlone((await repo.load()).hostedGroups);
    });

    for (final global in const [
      TuiGatewayRpcError(
        'groups.list',
        'Hermes connection changed during the group operation',
        failureKind: TuiGatewayRpcFailureKind.connectionLost,
      ),
      TuiGatewayRpcError(
        'groups.list',
        'Timeout waiting for JSON-RPC response',
        failureKind: TuiGatewayRpcFailureKind.timeout,
      ),
    ]) {
      // Replaces «X on every room is a whole-load failure, as before»: room
      // reads no longer take part in the list (see the table above); the
      // rooms read fails as a whole when groups.list itself does.
      test('${global.failureKind!.name} on groups.list is a whole-load '
          'failure that keeps the proven capabilities', () async {
        final reads = <String>[];
        final s = await _repo(reads: reads, listError: () => global).load();
        expect(s.hostedGroupsCapability, MissionCapabilityState.unavailable);
        expect(s.failures['hostedGroups'], same(global));
        expect(s.hostedGroups.rooms, isEmpty);
        expect(s.hostedGroups.unreadableRooms, isEmpty);
        expect(_createOffered(s), isFalse);
        expect(
          s.hostedGroups.capabilities?.supports(GroupMethod.create),
          isTrue,
        );
        expect(reads.where(_isRoomRead), isEmpty);
      });

      // Replaces «X on the incremental refresh: a lost connection still
      // fails it (the caller reloads); one timeout keeps the room as shown».
      test('${global.failureKind!.name} on groups.list fails the list '
          'refresh (the caller keeps its list); a room read that would fail '
          'is never made, and the room keeps the log its view read', () async {
        final reads = <String>[];
        var cut = false;
        TuiGatewayRpcError? listCut;
        final repo = _repo(
          reads: reads,
          listError: () => listCut,
          stateOf: (roomId) async {
            if (roomId == 'room-b' && cut) {
              throw const TuiGatewayRpcError(
                'groups.state',
                'Timeout waiting for JSON-RPC response',
                failureKind: TuiGatewayRpcFailureKind.timeout,
              );
            }
            return HostedGroupRoom.fromJson(
              _roomJson(roomId, roomId == 'room-a' ? 'Room A' : 'Room B'),
            );
          },
        );
        final first = await repo.load();
        // The room's view reads it once.
        await repo.readHostedGroup(first.hostedGroups.rooms[1], generation: 1);
        cut = true;
        reads.clear();
        final refreshed = await repo.refreshHostedGroups(first.hostedGroups);
        expect([for (final r in refreshed.rooms) r.name], ['Room A', 'Room B']);
        expect(refreshed.logAt(0), isNull);
        expect(refreshed.logAt(1)!.events, hasLength(1));
        expect(refreshed.unreadableRooms, isEmpty);
        expect(reads, ['groups.list']);

        listCut = global;
        await expectLater(
          repo.refreshHostedGroups(refreshed),
          throwsA(same(global)),
        );
        expect(reads.where(_isRoomRead), isEmpty);
      });
    }
  });

  // Hermes Desktop (apps/desktop/src/plugins/hermes-bots): the room list is
  // groups.capabilities + groups.list (canonical-groups.ts
  // discoverCanonicalGroups); groups.state/groups.log are read for a room,
  // and a failed read keeps what was shown (canonical-group-workspace.tsx).
  group('the room list does not depend on reading each room', () {
    const timeout = TuiGatewayRpcError(
      'groups.state',
      'Timeout waiting for JSON-RPC response',
      failureKind: TuiGatewayRpcFailureKind.timeout,
    );

    // Replaces «a room read cut by the connection keeps its last good
    // read»: the list keeps no read of its own; a room keeps what its view
    // read, whatever happens to its next view read.
    test('a room whose view read it keeps that log in later list reads, '
        'even when its next view read is cut', () async {
      var cut = false;
      final reads = <String>[];
      final repo = _repo(
        reads: reads,
        stateOf: (roomId) async {
          if (roomId == 'room-b' && cut) throw timeout;
          return HostedGroupRoom.fromJson(
            _roomJson(roomId, roomId == 'room-a' ? 'Room A' : 'Room B'),
          );
        },
      );
      final first = await repo.load();
      _expectListedAlone(first.hostedGroups);
      final roomB = first.hostedGroups.rooms[1];
      await repo.readHostedGroup(roomB, generation: 1);
      cut = true;
      await expectLater(
        repo.readHostedGroup(roomB, generation: 1),
        throwsA(same(timeout)),
      );
      reads.clear();
      final second = await repo.load();
      expect(second.hostedGroupsCapability, MissionCapabilityState.available);
      expect(_names(second), ['Room A', 'Room B']);
      expect(second.hostedGroups.unreadableRooms, isEmpty);
      expect(second.hostedGroups.logAt(0), isNull, reason: 'no view read A');
      expect(second.hostedGroups.logAt(1)!.events, hasLength(1));
      expect(reads, ['groups.list']);
    });

    // Replaces «one room that never answers in time does not starve the
    // rooms listed after it».
    test('one room that would time out can no longer hide or delay the '
        'list: no room is read to list it', () async {
      final rooms = [
        for (var i = 0; i < 12; i++)
          HostedGroupRoom.fromJson(_roomJson('room-$i', 'Room $i')),
      ];
      var roomReads = 0;
      final s = await MissionControlRepository(
        profilesLoader: () async => const [],
        sessionsLoader: () async => const [],
        boardLoader: () async => const KanbanBoard(columns: []),
        hostedGroupsGateway: MissionHostedGroupsGateway.callbacks(
          capabilities: () async => _parsedCaps(),
          list: ({required generation}) async => rooms,
          state: (roomId, {required generation}) async {
            roomReads++;
            if (roomId == 'room-1') throw timeout;
            return rooms.firstWhere((room) => room.roomId == roomId);
          },
          log: (roomId, {required generation}) async {
            roomReads++;
            return _log(roomId, [_userEvent(roomId, 1)]);
          },
        ),
      ).load();
      expect(s.hostedGroupsCapability, MissionCapabilityState.available);
      expect(_names(s), [for (final room in rooms) room.name]);
      expect(s.hostedGroups.unreadableRooms, isEmpty);
      expect(roomReads, 0, reason: 'no groups.state nor groups.log');
    });

    // Replaces «a lost connection stops the reads not yet started; the room
    // that was read shows and the rest are named» (and its bound of
    // concurrent room reads, which no longer exist).
    test('a connection that would be lost on every room read cannot shorten '
        'the list: every listed room shows, none is read', () async {
      const lost = TuiGatewayRpcError(
        'groups.state',
        'Hermes connection changed during the group operation',
        failureKind: TuiGatewayRpcFailureKind.connectionLost,
      );
      final rooms = [
        for (var i = 0; i < 12; i++)
          HostedGroupRoom.fromJson(_roomJson('room-$i', 'Room $i')),
      ];
      var roomReads = 0;
      final s = await MissionControlRepository(
        profilesLoader: () async => const [],
        sessionsLoader: () async => const [],
        boardLoader: () async => const KanbanBoard(columns: []),
        hostedGroupsGateway: MissionHostedGroupsGateway.callbacks(
          capabilities: () async => _parsedCaps(),
          list: ({required generation}) async => rooms,
          state: (roomId, {required generation}) async {
            roomReads++;
            if (roomId == 'room-0') return rooms.first;
            throw lost;
          },
          log: (roomId, {required generation}) async {
            roomReads++;
            return _log(roomId, [_userEvent(roomId, 1)]);
          },
        ),
      ).load();
      expect(roomReads, 0);
      expect(s.hostedGroupsCapability, MissionCapabilityState.available);
      expect(_names(s), [for (final room in rooms) room.name]);
      expect(s.hostedGroups.unreadableRooms, isEmpty);
      expect(
        [for (var i = 0; i < rooms.length; i++) s.hostedGroups.logAt(i)],
        everyElement(isNull),
      );
    });

    // Replaces «a repository seeded with the shown snapshot keeps a room it
    // could not read as it was shown»: what a view read survives into the
    // next repository (Home makes one per read) through the shown snapshot,
    // and a room no view read stays unknown.
    test('a repository seeded with the shown snapshot keeps what views '
        'read, without reading any room', () async {
      final viewed = _repo();
      final listed = await viewed.load();
      await viewed.readHostedGroup(listed.hostedGroups.rooms[1], generation: 1);
      final shown = await viewed.load();
      expect(shown.hostedGroups.logAt(0), isNull);
      expect(shown.hostedGroups.logAt(1)!.events, hasLength(1));

      final reads = <String>[];
      final next = _repo(
        reads: reads,
        stateOf: (roomId) async {
          if (roomId == 'room-b') throw timeout;
          return HostedGroupRoom.fromJson(_roomJson(roomId, 'Room A'));
        },
      )..seedHostedLogs(shown.hostedGroups);
      final s = await next.load();
      expect(_names(s), ['Room A', 'Room B']);
      expect(s.hostedGroups.logAt(0), isNull);
      expect(s.hostedGroups.logAt(1)!.events, hasLength(1));

      // The next read uses yet another repository, seeded with that one's
      // snapshot: B's content survives a second hop too.
      final third = _repo(
        reads: reads,
        stateOf: (roomId) async {
          if (roomId == 'room-b') throw timeout;
          return HostedGroupRoom.fromJson(_roomJson(roomId, 'Room A'));
        },
      )..seedHostedLogs(s.hostedGroups);
      final again = await third.load();
      expect(_names(again), ['Room A', 'Room B']);
      expect(again.hostedGroups.logAt(1)!.events, hasLength(1));
      expect(reads.where(_isRoomRead), isEmpty);
    });

    test('a newer seed replaces an older one: a room is never shown with an '
        'older copy than the one shown', () async {
      Future<MissionBackendSnapshot> viewedB(MissionControlRepository repo) async {
        final listed = await repo.load();
        await repo.readHostedGroup(listed.hostedGroups.rooms[1], generation: 1);
        return repo.load();
      }

      final older = await viewedB(_repo());
      final newer = await viewedB(
        _repo(
          stateOf: (roomId) async => HostedGroupRoom.fromJson(
            _roomJson(roomId, roomId == 'room-a' ? 'Room A' : 'Room B',
                latestSeq: 2),
          ),
          logOf: (roomId) async =>
              _log(roomId, [_userEvent(roomId, 1), _userEvent(roomId, 2)]),
        ),
      );
      expect(older.hostedGroups.logAt(1)!.events, hasLength(1));
      expect(newer.hostedGroups.logAt(1)!.events, hasLength(2));
      for (final seeds in [
        [older, newer],
        [newer, older],
      ]) {
        final reads = <String>[];
        final repo = _repo(
          reads: reads,
          stateOf: (roomId) async {
            if (roomId == 'room-b') throw timeout;
            return HostedGroupRoom.fromJson(_roomJson(roomId, 'Room A'));
          },
        );
        for (final seed in seeds) {
          repo.seedHostedLogs(seed.hostedGroups);
        }
        final s = await repo.load();
        expect(s.hostedGroups.logAt(1)!.events, hasLength(2));
        expect(reads.where(_isRoomRead), isEmpty);
      }
    });

    // The list no longer reads groups.state, so a server lacking it is told
    // by its capabilities, as Desktop does (`hasSharedRoomSurface`).
    test('a server that lacks groups.state is still not a room list', () async {
      final reads = <String>[];
      final repo = MissionControlRepository(
        profilesLoader: () async => const [],
        sessionsLoader: () async => const [],
        boardLoader: () async => const KanbanBoard(columns: []),
        hostedGroupsGateway: MissionHostedGroupsGateway.callbacks(
          capabilities: () async => _parsedCaps(
            methods: const [
              'groups.capabilities', 'groups.list', 'groups.create',
              'groups.send', 'groups.rename', 'groups.log', 'groups.disband',
            ],
          ),
          list: ({required generation}) async {
            reads.add('groups.list');
            return [HostedGroupRoom.fromJson(_roomJson('room-a', 'Room A'))];
          },
          state: (roomId, {required generation}) async =>
              throw const TuiGatewayRpcError(
                'groups.state',
                'Method not found',
                code: -32601,
              ),
          log: (roomId, {required generation}) async =>
              _log(roomId, [_userEvent(roomId, 1)]),
        ),
      );
      final s = await repo.load();
      expect(s.hostedGroupsCapability, MissionCapabilityState.unsupported);
      expect(s.hostedGroups.rooms, isEmpty);
      expect(reads, isEmpty, reason: 'nothing is listed without the surface');
    });

    test('Home: a failed rooms read keeps the rooms already shown', () async {
      final connection = SavedConnection(
        id: 'rooms',
        label: 'Rooms',
        host: 'localhost',
        port: 8642,
        apiKey: 'k',
      );
      const listTimeout = TuiGatewayRpcError(
        'groups.list',
        'Timeout waiting for JSON-RPC response',
        failureKind: TuiGatewayRpcFailureKind.timeout,
      );
      var failList = false;
      // Snapshots are stamped with the real clock (loadedAt).
      var clock = DateTime.now();
      final cache = MissionSnapshotCache();
      final prewarm = MissionSnapshotPrewarm(
        cache: cache,
        now: () => clock,
        sourceFactory: (_) => failList
            ? _repoWith(list: ({required generation}) async => throw listTimeout)
            : _repoWith(),
      );
      prewarm.refreshForHome(connection: connection);
      await prewarm.claim(connection);
      expect(_names(cache.read(connection)!), ['Room A', 'Room B']);

      failList = true;
      clock = clock.add(const Duration(minutes: 2));
      prewarm.refreshForHome(connection: connection);
      await prewarm.claim(connection);
      final kept = cache.read(connection)!;
      expect(kept.hostedGroupsCapability, MissionCapabilityState.unavailable);
      expect(kept.failures['hostedGroups'], same(listTimeout));
      expect(_names(kept), ['Room A', 'Room B']);

      // The widget's Retry asks again at once (minAge zero), without
      // waiting for the once-a-minute cadence.
      failList = false;
      prewarm.refreshForHome(connection: connection, minAge: Duration.zero);
      await prewarm.claim(connection);
      expect(
        cache.read(connection)!.hostedGroupsCapability,
        MissionCapabilityState.available,
      );
    });
  });

  group('end to end over the real client', () {
    // The list reads no room log; the image is read by the room's view, and
    // the list keeps what that view read.
    test('a Desktop message with a valid image lists both rooms, and the '
        'room\'s view reads the image', () async {
      await _withWireRepo(
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
        body: (repo) async {
          final s = await repo.load();
          expect(_names(s), ['Room A', 'Room B']);
          expect(_createOffered(s), isTrue);
          expect(s.hostedGroups.unreadableRooms, isEmpty);
          expect(s.hostedGroups.logAt(1), isNull, reason: 'no view read it');

          final read = await repo.readHostedGroup(
            s.hostedGroups.rooms[1],
            generation: s.hostedGroups.capabilities!.generation,
          );
          expect(read.log!.events.single.attachments.single.name, 'foto.png');
          final again = await repo.load();
          expect(
            again.hostedGroups.logAt(1)!.events.single.attachments.single.name,
            'foto.png',
          );
        },
      );
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

    // Before, the list read every room's log and this room was reported
    // unreadable. The list reads no log now: the room lists, and only its
    // view's read is refused, with nothing of the log shown.
    test('an attachment Console must reject (non-conformant id) no longer '
        'hides the room: only its view read is refused', () async {
      await _withWireRepo(
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
        body: (repo) async {
          final s = await repo.load();
          expect(_names(s), ['Room A', 'Room B']);
          expect(_createOffered(s), isTrue);
          expect(s.hostedGroups.unreadableRooms, isEmpty);

          await expectLater(
            repo.readHostedGroup(
              s.hostedGroups.rooms[1],
              generation: s.hostedGroups.capabilities!.generation,
            ),
            throwsA(isA<GroupInvalidResponseError>()),
          );
          final again = await repo.load();
          expect(_names(again), ['Room A', 'Room B']);
          expect(again.hostedGroups.logAt(1), isNull);
        },
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
