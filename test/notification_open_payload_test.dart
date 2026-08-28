import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/main.dart';

void main() {
  group('NotificationOpen payload', () {
    test('roundtrip conserva superficie Bot y perfil', () {
      const original = NotificationOpen(
        connId: 'conn-1',
        sessionId: 'stored-bot-1',
        title: 'Bot Chat',
        profile: 'builder',
        surface: NotificationChatSurface.bot,
      );

      final decoded = NotificationOpen.tryParse(original.toPayload());

      expect(decoded, isNotNull);
      expect(decoded!.connId, original.connId);
      expect(decoded.sessionId, original.sessionId);
      expect(decoded.profile, 'builder');
      expect(decoded.surface, NotificationChatSurface.bot);
      expect(decoded.roomId, isNull);
    });

    test('roundtrip conserva superficie Room, sala y perfil manager', () {
      const original = NotificationOpen(
        connId: 'conn-1',
        sessionId: 'stored-room-1',
        title: '#release',
        profile: 'manager',
        surface: NotificationChatSurface.room,
        roomId: 'room-1',
      );

      final payload = original.toPayload(base: 'https://hermes.example');
      final raw = jsonDecode(payload) as Map<String, dynamic>;
      final decoded = NotificationOpen.tryParse(payload);

      expect(raw['surface'], 'room');
      expect(raw['room'], 'room-1');
      expect(raw['base'], 'https://hermes.example');
      expect(decoded!.surface, NotificationChatSurface.room);
      expect(decoded.roomId, 'room-1');
      expect(decoded.profile, 'manager');
    });

    test('roundtrip conserva destino exacto de Kanban sin sesión', () {
      const original = NotificationOpen(
        connId: 'conn-1',
        taskId: 'task-42',
        title: 'Preparar publicación',
      );

      final raw = jsonDecode(original.toPayload()) as Map<String, dynamic>;
      final decoded = NotificationOpen.tryParse(original.toPayload());

      expect(raw['tid'], 'task-42');
      expect(decoded, isNotNull);
      expect(decoded!.taskId, 'task-42');
      expect(decoded.sessionId, isEmpty);
      expect(decoded.runId, isNull);
    });

    test('payload legacy sin superficie conserva routing normal', () {
      final decoded = NotificationOpen.tryParse(
        jsonEncode({
          'conn': 'legacy-conn',
          'sid': 'legacy-session',
          'title': 'Legacy chat',
          'profile': 'research',
        }),
      );

      expect(decoded, isNotNull);
      expect(decoded!.surface, NotificationChatSurface.normal);
      expect(decoded.roomId, isNull);
      expect(decoded.profile, 'research');
    });

    test('superficie desconocida degrada a normal', () {
      final decoded = NotificationOpen.tryParse(
        '{"conn":"conn-1","sid":"session-1","surface":"future"}',
      );

      expect(decoded!.surface, NotificationChatSurface.normal);
    });
  });

  group('notification owner routing', () {
    test('Bot se dirige a Bots con su perfil', () {
      final target = missionControlTargetForNotification(
        const NotificationOpen(
          connId: 'conn-1',
          sessionId: 'stored-bot-1',
          profile: ' builder ',
          surface: NotificationChatSurface.bot,
        ),
      );

      expect(target, isNotNull);
      expect(target!.surface, MissionControlOwnedSurface.bot);
      expect(target.sessionId, 'stored-bot-1');
      expect(target.profile, 'builder');
    });

    test('Room se dirige a Trabajo con su room id', () {
      final target = missionControlTargetForNotification(
        const NotificationOpen(
          connId: 'conn-1',
          sessionId: 'stored-room-1',
          profile: 'manager',
          surface: NotificationChatSurface.room,
          roomId: ' room-1 ',
        ),
      );

      expect(target, isNotNull);
      expect(target!.surface, MissionControlOwnedSurface.room);
      expect(target.roomId, 'room-1');
      expect(target.profile, 'manager');
    });

    test(
      'chat normal no se redirige y dedicado incompleto conserva sección',
      () {
        expect(
          missionControlTargetForNotification(
            const NotificationOpen(connId: 'conn-1', sessionId: 'normal-1'),
          ),
          isNull,
        );
        final incompleteRoom = missionControlTargetForNotification(
          const NotificationOpen(
            connId: 'conn-1',
            sessionId: 'room-1',
            surface: NotificationChatSurface.room,
          ),
        );
        expect(incompleteRoom?.surface, MissionControlOwnedSurface.room);
        expect(incompleteRoom?.roomId, isEmpty);
      },
    );
  });
}
