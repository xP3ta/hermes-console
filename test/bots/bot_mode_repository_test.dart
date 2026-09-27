import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_mode_repository.dart';
import 'package:hermes_android/core/bots/data/gateway_socket_meter.dart';
import 'package:hermes_android/core/bots/state/attention.dart';
import 'package:hermes_android/core/bots/state/bot_chat_target.dart';
import 'package:hermes_android/core/bots/state/bot_presence.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import '../support/spec070_fixtures.dart';

final class FakeBotModeGateway implements BotModeGateway {
  final calls = <String>[];
  final logSince = <int>[];
  bool quietLog = false;
  bool groupsFail = false;
  AgentProfileSessionSummary? titleRow;
  (String, Map<String, Object?>)? lastMutation;

  @override
  Future<List<AgentProfile>> listProfiles() async {
    calls.add('profiles.list');
    return spec070Profiles();
  }

  @override
  Future<DesktopActiveSessionList> listActiveSessions() async {
    calls.add('session.active_list');
    return spec070ActiveSessions();
  }

  @override
  Future<GroupsCapabilities> groupCapabilities() async {
    calls.add('groups.capabilities');
    if (groupsFail) throw StateError('offline');
    return spec070Capabilities();
  }

  @override
  Future<List<HostedGroupRoom>> listGroups({required int generation}) async {
    calls.add('groups.list');
    return [spec070Room()];
  }

  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})> groupState(
    String roomId, {
    required int generation,
  }) async {
    calls.add('groups.state');
    return (room: spec070Room(), driverStatus: spec070DriverStatus());
  }

  @override
  Future<HostedGroupLogPage> groupLog(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    calls.add('groups.log');
    logSince.add(sinceSeq);
    if (sinceSeq == 0) return spec070LogPage('groups_log_page1');
    if (sinceSeq == 4) return spec070LogPage('groups_log_page2');
    return spec070LogPage('groups_log_empty');
  }

  @override
  Future<HostedGroupRoom> stopGroup(
    String roomId, {
    required int generation,
  }) async {
    lastMutation = ('groups.stop', {'room_id': roomId});
    return spec070Room();
  }

  @override
  Future<HostedGroupRoom> retryGroupTask(
    String roomId, {
    required String taskId,
    required int generation,
  }) async {
    lastMutation = ('groups.retry', {'room_id': roomId, 'task_id': taskId});
    return spec070Room();
  }

  @override
  Future<HostedGroupRoom> approveGroupTask(
    String roomId, {
    required RoomApprovalAction action,
    required String choice,
    required int generation,
  }) async {
    lastMutation = (
      'groups.approve',
      {
        'room_id': roomId,
        'member_id': action.memberId,
        'task_id': action.taskId,
        'execution_generation': action.executionGeneration,
        'choice': choice,
        'request_id': action.requestId,
      },
    );
    return spec070Room();
  }

  @override
  Future<AgentProfileSessionSummary?> findBotChatByTitle(String profile) async {
    calls.add('session.list:title');
    return titleRow;
  }
}

void main() {
  group('BotModeRepository', () {
    late FakeBotModeGateway gateway;
    late BotModeRepository repo;

    setUp(() {
      gateway = FakeBotModeGateway();
      repo = BotModeRepository(
        gateway: gateway,
        now: () => DateTime.fromMillisecondsSinceEpoch(1790000600 * 1000),
      );
    });

    test('load() builds server-sourced rows, rooms and projection', () async {
      final snapshot = await repo.load();
      final byName = {for (final b in snapshot.bots) b.profile.name: b};
      expect(byName['default']!.presence, BotPresence.working);
      expect(byName['astra']!.presence, BotPresence.attention);
      expect(byName['radar']!.presence, BotPresence.idle);
      expect(byName['default']!.chat.sessionId, '20260920_100000_tip001');
      expect(
        byName['astra']!.attention.map((a) => a.kind),
        contains(AttentionKind.approval),
      );
      expect(snapshot.rooms.single.log?.events, hasLength(8));
      expect(snapshot.attentionCount, 3);
      expect(snapshot.projectionRooms.rooms.map((r) => r.roomId), [
        'room-desktop-1',
      ]);
      expect(snapshot.hostedGroups.driverStatusFor('room-devs'), isNotNull);
    });

    test('room refresh only reads the log delta', () async {
      await repo.load();
      gateway.logSince.clear();
      final room = await repo.refreshRoom('room-devs', generation: 1);
      expect(gateway.logSince, [8]);
      expect(room.log?.events, hasLength(8));
    });

    test('groups failure degrades to bots without rooms', () async {
      gateway.groupsFail = true;
      final snapshot = await repo.load();
      expect(snapshot.bots, hasLength(3));
      expect(snapshot.rooms, isEmpty);
    });

    test(
      'approve sends the exact server tuple and only offered choices',
      () async {
        final snapshot = await repo.load();
        final room = snapshot.rooms.single;
        final action = room.driverStatus!.approvals.single;
        await repo.approve(room, action: action, choice: 'once', generation: 1);
        expect(gateway.lastMutation?.$1, 'groups.approve');
        expect(
          gateway.lastMutation?.$2,
          spec070Fixture('groups_approve')['params'],
        );
        expect(
          () => repo.approve(
            room,
            action: action,
            choice: 'always',
            generation: 1,
          ),
          throwsStateError,
        );
      },
    );

    test('retry only for server-listed retryable tasks', () async {
      final room = (await repo.load()).rooms.single;
      await repo.retry(room, taskId: 'task-radar-1', generation: 1);
      expect(gateway.lastMutation?.$1, 'groups.retry');
      expect(
        gateway.lastMutation?.$2,
        spec070Fixture('groups_retry')['params'],
      );
      expect(
        () => repo.retry(room, taskId: 'task-astra-1', generation: 1),
        throwsStateError,
      );
    });

    test('resolveBotChat falls back to the title registry lookup', () async {
      final radar = spec070Profiles().singleWhere((p) => p.name == 'radar');
      expect((await repo.resolveBotChat(radar)).exists, isFalse);
      gateway.titleRow = AgentProfileSessionSummary.tryParse(
        (spec070Result('session_list_title')['sessions'] as List).single,
      );
      final target = await repo.resolveBotChat(radar);
      expect(target.source, BotChatTargetSource.canonical);
      expect(target.sessionId, '20260910_080000_radar2');
      final hermes = spec070Profiles().first;
      gateway.calls.clear();
      await repo.resolveBotChat(hermes);
      expect(gateway.calls, isEmpty, reason: 'canonical_session suffices');
    });

    test('close rejects further use and releases once', () async {
      var released = 0;
      final owned = BotModeRepository(
        gateway: gateway,
        onClose: () => released++,
      );
      owned.close();
      owned.close();
      expect(released, 1);
      expect(owned.load, throwsStateError);
    });
  });

  group('sockets (T209)', () {
    final connection = SavedConnection(
      id: 'conn-botmode-pool',
      label: 'Home',
      host: '10.0.0.1',
      port: 8642,
      apiKey: 'k',
    );

    test(
      'pooled repositories share one client; no client per refresh',
      () async {
        final pool = SharedGatewayPool.instance;
        final before = pool.liveClientCount;
        var created = 0;
        TuiGatewayClient factory(SavedConnection c) {
          created++;
          return TuiGatewayClient(c);
        }

        final a = BotModeRepository.pooled(connection, factory: factory);
        final b = BotModeRepository.pooled(connection, factory: factory);
        expect(created, 1);
        expect(pool.liveClientCount, before + 1);
        a.close();
        expect(pool.liveClientCount, before + 1);
        b.close();
        expect(pool.liveClientCount, before);
      },
    );

    test('room refreshes over one repository open zero new clients', () async {
      final gateway = FakeBotModeGateway();
      final repo = BotModeRepository(gateway: gateway);
      GatewaySocketMeter.instance.reset();
      await repo.load();
      for (var i = 0; i < 20; i++) {
        await repo.refreshRoom('room-devs', generation: 1);
      }
      expect(GatewaySocketMeter.instance.totalOpened, 0);
    });

    test('meter counts opens within the trailing minute', () {
      final meter = GatewaySocketMeter.instance..reset();
      var now = DateTime(2026);
      meter.now = () => now;
      meter.recordOpen();
      meter.recordOpen();
      expect(meter.openedLastMinute, 2);
      now = now.add(const Duration(seconds: 61));
      meter.recordOpen();
      expect(meter.openedLastMinute, 1);
      expect(meter.totalOpened, 3);
      meter.reset();
    });
  });
}
