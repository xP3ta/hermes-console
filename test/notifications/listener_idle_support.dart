// SPDX-License-Identifier: GPL-3.0-only
// Shared pieces of the listener idle-traffic tests: a real loopback gateway
// socket, the room a Bot Mode pass reads, and a notification sink.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_mode_repository.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import '../bots/room/room_fixtures.dart';
import '../support/rpc_frame_helpers.dart';

final class IdleTicket extends DashboardClient {
  IdleTicket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'idle');
}

/// A loopback Hermes gateway (`/api/ws`): `gateway.ready` (with
/// `change_events` when [changeEvents]), an empty answer to any request, and
/// the global broadcasts of `tui_gateway/server.py`
/// `_broadcast_global_event` (`session_id` is the empty string) on demand.
final class LoopbackGateway {
  late HttpServer server;
  final sockets = <WebSocket>[];
  bool changeEvents = true;

  /// Methods of every request that reached the server.
  final methods = <String>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await drop();
      await server.close(force: true);
    });
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'change_events': changeEvents},
          },
        }),
      );
      socket.listen((raw) {
        final rpc = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
        if (!isClientCapabilitiesFrame(rpc)) {
          methods.add('${rpc['method']}');
        }
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': rpc['id'],
            'result': <String, dynamic>{},
          }),
        );
      }, onError: (Object _) {});
    });
  }

  SavedConnection get connection => SavedConnection(
    id: 'idle-node',
    label: 'Idle node',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'k',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  );

  TuiGatewayClient client() => TuiGatewayClient(
    connection,
    dashboard: IdleTicket(),
    heartbeatInterval: Duration.zero,
  );

  void broadcast(String type) {
    final frame = jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': type,
        'session_id': '',
        'payload': <String, dynamic>{},
      },
    });
    for (final socket in sockets) {
      socket.add(frame);
    }
  }

  /// The server closes the sockets (restart, idle proxy).
  Future<void> drop() async {
    for (final socket in sockets) {
      await socket.close();
    }
    sockets.clear();
  }
}

/// Lets frames and closes travel over loopback.
Future<void> settleLoopback() =>
    Future<void>.delayed(const Duration(milliseconds: 150));

GroupsCapabilities idleCaps() => GroupsCapabilities.tryParse(
  {
    'protocol_version': 1,
    'driver': true,
    'max_log_limit': 500,
    'methods': [for (final m in GroupMethod.values) m.wire],
  },
  connectionId: 'idle-node',
  generation: 1,
)!;

/// One room, its log and driver status. Counts each pass (one
/// `groups.capabilities` per pass) and what else the listener asks for.
class IdleRooms implements BotModeGateway {
  bool working = false;
  List<Map<String, dynamic>> pending = const [];
  List<Map<String, dynamic>> events = [];
  List<AgentProfile> profiles = const [];
  int passes = 0;
  int profileReads = 0;
  int liveListReads = 0;

  int get latest => events.isEmpty ? 0 : events.last['seq'] as int;

  @override
  Future<GroupsCapabilities> groupCapabilities() async {
    passes++;
    return idleCaps();
  }

  @override
  Future<List<HostedGroupRoom>> listGroups({required int generation}) async =>
      [buildRoom(latestSeq: latest)];

  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})> groupState(
    String roomId, {
    required int generation,
  }) async => (
    room: buildRoom(latestSeq: latest),
    driverStatus: driver(working: working, pending: pending),
  );

  @override
  Future<HostedGroupLogPage> groupLog(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    final page = events.where((e) => (e['seq'] as int) > sinceSeq).toList();
    return HostedGroupLogPage.fromJson(
      {
        'events': page,
        'cursor': latest,
        'latest_seq': latest,
        'has_more': false,
        'authority': {'gateway_id': gatewayId, 'epoch': 2},
      },
      expectedRoomId: roomId,
      sinceSeq: sinceSeq,
    );
  }

  @override
  Future<List<AgentProfile>> listProfiles() async {
    profileReads++;
    return profiles;
  }

  @override
  Future<DesktopActiveSessionList> listActiveSessions() async {
    liveListReads++;
    return const DesktopActiveSessionList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class IdleSink implements RichNotificationSink {
  final conversations = <Map<String, Object?>>[];

  @override
  Future<void> cancel({required int id, String? tag}) async {}

  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) async {}

  @override
  Future<bool> postConversation(Map<String, Object?> args) async {
    conversations.add(args);
    return true;
  }

  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {}
}
