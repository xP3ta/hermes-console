import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/state/attention.dart';
import 'package:hermes_android/core/home/home_now.dart';
import 'package:hermes_android/core/home/home_sources.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';

import '../support/spec070_fixtures.dart';

HostedGroupsSnapshot _groups() => HostedGroupsSnapshot(
  capabilities: spec070Capabilities(),
  rooms: [spec070Room()],
  logs: [
    HostedGroupLogPage.append(
      spec070LogPage('groups_log_page1'),
      spec070LogPage('groups_log_page2'),
    ),
  ],
  driverStatuses: {'room-devs': spec070DriverStatus()},
);

CronJob _job(Map<String, dynamic> json) =>
    CronJob.fromJson({'id': 'j1', 'name': 'Backup', ...json});

void main() {
  group('team', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1790000600 * 1000);

    test('bots whose canonical Bot Chat works; never the main bot or a '
        'hidden one', () {
      final team = homeTeam(
        profiles: spec070Profiles(),
        activeSessions: const [
          // default (main) Bot Chat tip: working, but it is the main bot.
          DesktopActiveSession(
            runtimeSessionId: 'rt-hermes',
            storedSessionId: '20260920_100000_tip001',
            status: 'working',
          ),
          DesktopActiveSession(
            runtimeSessionId: 'rt-astra',
            storedSessionId: '20260901_120000_astra1',
            status: 'working',
            title: 'Bot Chat',
          ),
        ],
        liveChats: const [],
        now: now,
      );
      expect(team.map((b) => b.profileName), ['astra']);
      expect(team.single.state, HomeTeamState.working);
    });

    test('an idle canonical chat is not on the team', () {
      final team = homeTeam(
        profiles: spec070Profiles(),
        activeSessions: spec070ActiveSessions().sessions,
        liveChats: const [],
        now: now,
      );
      expect(team, isEmpty);
    });

    test('no profiles, no team', () {
      expect(
        homeTeam(
          profiles: const [],
          activeSessions: spec070ActiveSessions().sessions,
          liveChats: const [],
          now: now,
        ),
        isEmpty,
      );
    });
  });

  group('room approvals and news', () {
    test('the driver approval with its exact action and member', () {
      final groups = _groups();
      final items = homeRoomApprovals(
        groups,
        AttentionSummary.fromSnapshot(groups),
      );
      final item = items.single;
      expect(item.roomKey, 'room-devs');
      expect(item.where, 'Console Devs');
      expect(item.actor, 'Astra');
      expect(item.command, contains('git push origin main'));
      expect(item.canAllow, isTrue);
      expect(item.canDeny, isTrue);
      final ref = item.ref as HomeRoomApprovalRef;
      expect(ref.action.requestId, 'apr-1');
      expect(ref.room.roomId, 'room-devs');
    });

    test('member messages after the seen mark count as news', () {
      final news = homeRoomNews(
        _groups(),
        acksFor: (_) => const RoomAttentionAcks(seenSeq: 2),
      );
      expect(news.single.count, 1);
      expect(news.single.title, 'Console Devs');
    });

    test('nothing new after the mark, or a room never seen: no news', () {
      expect(
        homeRoomNews(
          _groups(),
          acksFor: (_) => const RoomAttentionAcks(seenSeq: 3),
        ),
        isEmpty,
      );
      expect(
        homeRoomNews(_groups(), acksFor: (_) => RoomAttentionAcks.none),
        isEmpty,
      );
    });
  });

  group('chat approvals', () {
    late ActiveChatService chats;
    final connection = SavedConnection(
      id: 'c1',
      label: 'QA',
      host: '127.0.0.2',
      port: 8642,
      apiKey: 'k',
    );

    setUp(() => chats = ActiveChatService(attachDesktopRuntimeOnLoad: false));
    tearDown(() => chats.dispose());

    ActiveChat attach(String id, Map<String, dynamic>? request) {
      final chat = chats.attach(
        connection: connection,
        sessionId: id,
        sessionTitle: 'Deploy $id',
        sessionProfile: 'default',
        disableForegroundKeepAlive: true,
      );
      chat
        ..state = ChatPipelineState.executing
        ..pendingApproval = request;
      return chat;
    }

    test('one item per pending request, answered by its own chat', () {
      final pending = attach('s1', {
        'request_id': 'r1',
        'command': 'rm -rf build',
        'choices': ['once', 'session', 'deny'],
      });
      final idle = attach('s2', null);
      final items = homeChatApprovals(
        [pending, idle],
        chatKey: (chat) => chat.sessionId,
        whereOf: (chat) => chat.sessionTitle,
      );
      final item = items.single;
      expect(item.sessionKey, 's1');
      expect(item.where, 'Deploy s1');
      expect(item.command, 'rm -rf build');
      expect(item.canAllow, isTrue);
      expect(item.canDeny, isTrue);
      expect(
        identical((item.ref as HomeChatApprovalRef).chat, pending),
        isTrue,
      );
    });

    test('Permitir only when the request offers a one-time allow', () {
      final chat = attach('s1', {
        'request_id': 'r1',
        'command': 'ls',
        'choices': ['deny'],
      });
      final item = homeChatApprovals(
        [chat],
        chatKey: (_) => null,
        whereOf: (_) => '',
      ).single;
      expect(item.canAllow, isFalse);
      expect(item.canDeny, isTrue);
    });

    test('a request without an id is not answerable and not shown', () {
      final chat = attach('s1', {'command': 'ls'});
      expect(
        homeChatApprovals([chat], chatKey: (_) => null, whereOf: (_) => ''),
        isEmpty,
      );
    });
  });

  group('automations', () {
    DateTime? parse(Object? raw) =>
        raw == null ? null : DateTime.tryParse(raw.toString());

    test('a failed last run is red', () {
      final jobs = homeAutomations([
        _job({'last_status': 'error'}),
        _job({'id': 'j2', 'state': 'error'}),
        _job({'id': 'j3', 'last_status': 'ok'}),
      ], parseTime: parse);
      expect(jobs.map((j) => j.failed), [true, true, false]);
    });

    test('a paused job has no next run', () {
      final jobs = homeAutomations([
        _job({'state': 'paused', 'next_run_at': '2026-10-06T18:00:00'}),
        _job({'id': 'j2', 'next_run_at': '2026-10-06T18:00:00'}),
      ], parseTime: parse);
      expect(jobs.first.nextRun, isNull);
      expect(jobs.first.enabled, isFalse);
      expect(jobs.last.nextRun, DateTime(2026, 10, 6, 18));
      expect(jobs.last.name, 'Backup');
    });
  });
}
