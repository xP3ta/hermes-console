import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/desktop_projection_rooms.dart';
import 'package:hermes_android/core/bots/state/attention.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/room_member_status.dart';

import '../support/spec070_fixtures.dart';

MissionAgent _agent(
  String name, {
  MissionAgentStatus status = MissionAgentStatus.idle,
  Map<String, dynamic> meta = const {},
  AgentProfileWorkerSession? worker,
  String? preview,
  double? lastActive,
  String? liveTitle,
}) => MissionAgent(
  profile: AgentProfile(
    name: name,
    botModeUiMeta: meta,
    workerSession: worker,
    canonicalSession: preview == null && lastActive == null
        ? null
        : AgentProfileSessionSummary(
            id: 'chat-$name',
            title: 'Bot Chat',
            preview: preview ?? '',
            lastActive: lastActive,
          ),
  ),
  status: status,
  statusEvidence: '',
  usage: const MissionUsage(),
  liveSessionTitle: liveTitle,
);

void main() {
  group('state signal and working line', () {
    test('signal comes from server evidence with attention first', () {
      const idle = BotLiveStatus(RoomPresence.idle);
      expect(
        BotRosterEntry.signalFor(agent: _agent('a'), live: idle),
        BotFaceSignal.idle,
      );
      expect(
        BotRosterEntry.signalFor(
          agent: _agent('a', status: MissionAgentStatus.working),
          live: idle,
        ),
        BotFaceSignal.working,
      );
      expect(
        BotRosterEntry.signalFor(
          agent: _agent('a', status: MissionAgentStatus.thinking),
          live: idle,
        ),
        BotFaceSignal.thinking,
      );
      expect(
        BotRosterEntry.signalFor(
          agent: _agent('a', status: MissionAgentStatus.responding),
          live: idle,
        ),
        BotFaceSignal.speaking,
      );
      expect(
        BotRosterEntry.signalFor(
          agent: _agent('a', status: MissionAgentStatus.working),
          live: idle,
          hasAttention: true,
        ),
        BotFaceSignal.attention,
      );
      expect(
        BotRosterEntry.signalFor(
          agent: _agent('a'),
          live: const BotLiveStatus(RoomPresence.working),
        ),
        BotFaceSignal.working,
      );
    });

    test('a fresh worker alone leaves the Bot Chat line on its preview', () {
      final now = DateTime.now();
      final working = BotRosterEntry.from(
        agent: _agent(
          'forja',
          status: MissionAgentStatus.working,
          worker: AgentProfileWorkerSession(
            id: 'w',
            source: 'tool',
            title: 'flutter test (3/9)',
            lastActive: now.millisecondsSinceEpoch / 1000,
          ),
          preview: 'old reply',
          lastActive: now.millisecondsSinceEpoch / 1000 - 600,
        ),
        live: const BotLiveStatus(RoomPresence.idle),
        now: now,
      );
      // Only the canonical Bot Chat lights the avatar and names the work.
      expect(working.signal, BotFaceSignal.idle);
      expect(working.workingOn, isNull);
      expect(working.preview, 'old reply');
      final idle = BotRosterEntry.from(
        agent: _agent(
          'review',
          preview: 'No P0/P1, one nit.',
          lastActive: 1790000000,
        ),
        live: const BotLiveStatus(RoomPresence.idle),
        now: now,
      );
      expect(idle.signal, BotFaceSignal.idle);
      expect(idle.workingOn, isNull);
      expect(idle.preview, 'No P0/P1, one nit.');
      expect(idle.at, DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000));
    });
  });

  group('rooms from hosted groups and Desktop projection', () {
    test('hosted preview, needs-you and projection Desktop rows', () {
      final room = spec070Room();
      final hosted = HostedGroupsSnapshot(
        capabilities: spec070Capabilities(),
        rooms: [room],
        logs: [spec070LogPage('groups_log_page1')],
        driverStatuses: {room.roomId: spec070DriverStatus()},
      );
      final profiles = spec070Profiles();
      final entries = RoomRosterEntry.build(
        hosted: hosted,
        attention: AttentionSummary.fromSnapshot(hosted),
        projection: DesktopProjectionRooms.parse(
          profiles.singleWhere((p) => p.name == 'default').groupsProjection,
          hostedRoomIds: {room.roomId},
        ),
        localProfiles: {for (final p in profiles) p.name: p},
      );
      final hostedEntry = entries.singleWhere((e) => !e.desktopOnly);
      expect(hostedEntry.title, 'Console Devs');
      expect(hostedEntry.needsYou, isTrue);
      expect(hostedEntry.working, isTrue);
      expect(hostedEntry.members.map((m) => m.handle), ['astra', 'radar']);
      final desktop = entries.singleWhere((e) => e.desktopOnly);
      expect(desktop.title, 'Hermes Console · Equipo');
      expect(desktop.needsYou, isTrue);
      expect(desktop.previewAuthor, 'astra');
      expect(desktop.projection?.readOnly, isTrue);
    });
  });
}
