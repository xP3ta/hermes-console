import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_scene.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';

import 'launcher_widget_fixtures.dart';

HermesHomeWidgetSnapshot _asking() => HermesHomeWidgetSnapshot(
  configured: true,
  instanceId: 'home',
  connectionState: HomeWidgetConnectionState.connected,
  agentState: HomeWidgetAgentState.waitingApproval,
  sessionId: 's1',
  sessionTitle: 'Reservar hotel',
  lastActivityAtMs: lwMinutesAgo(27),
  updatedAtMs: lwMinutesAgo(1),
  active: [
    HomeWidgetChatActivity(
      sessionId: 's1',
      state: HomeWidgetAgentState.waitingApproval,
      title: 'Reservar hotel',
      startedAtMs: lwMinutesAgo(2),
      need: const HomeWidgetNeed(
        requestId: 'r1',
        text: 'git push',
        actionPayload: 'payload-approve-deny',
      ),
    ),
  ],
);

void main() {
  group('launcher «Ahora» picture and App Lock', () {
    test('without App Lock the permission offers Permitir / Rechazar', () {
      final scene = LwAhoraScene.from(
        _asking(),
        nowMs: lwNow,
        agentName: 'Agent',
      );
      expect(scene.needs, hasLength(1));
      expect(scene.needs.single.answerPayload, 'payload-approve-deny');
    });

    test('with App Lock the same permission is only «Abrir»', () {
      final scene = LwAhoraScene.from(
        _asking(),
        nowMs: lwNow,
        agentName: 'Agent',
        answersAllowed: false,
      );
      expect(scene.needs, hasLength(1), reason: 'still shown as needing you');
      expect(
        scene.needs.single.answerPayload,
        isNull,
        reason: 'the native receiver would refuse the answer silently',
      );
      expect(scene.needs.single.open, isNotNull);
    });
  });
}
