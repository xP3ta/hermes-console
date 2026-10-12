import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/state/companion_presence_controller.dart';
import 'package:hermes_android/core/companion/models/companion_mood.dart';

void main() {
  late CompanionPresenceController c;
  setUp(() => c = CompanionPresenceController());
  tearDown(() => c.dispose());

  group('CompanionPresenceController (006 US1)', () {
    test('estado inicial = idle (online)', () {
      expect(c.mood, CompanionMood.idle);
    });

    test('conexión: connecting/offline/online', () {
      c.setConnectionStatus(PresenceConnection.connecting);
      expect(c.mood, CompanionMood.connecting);
      c.setConnectionStatus(PresenceConnection.offline);
      expect(c.mood, CompanionMood.offline);
      c.setConnectionStatus(PresenceConnection.online);
      expect(c.mood, CompanionMood.idle);
    });

    test(
      'messageSent → salto breve → thinking; completado → success → idle',
      () {
        c.onEvent(PresenceEvent.messageSent);
        expect(c.mood, CompanionMood.jump); // gesto breve al enviar
        c.debugSettleTransient(); // decae el salto
        expect(c.mood, CompanionMood.thinking);
        c.onEvent(PresenceEvent.responseCompleted);
        expect(c.mood, CompanionMood.success);
        c.debugSettleTransient();
        expect(c.mood, CompanionMood.idle);
      },
    );

    test('approvalNeeded → waiting (persistente) hasta resolver', () {
      c.onEvent(PresenceEvent.approvalNeeded);
      expect(c.mood, CompanionMood.waiting);
      c.onEvent(PresenceEvent.responseCompleted);
      expect(c.mood, CompanionMood.success);
      c.debugSettleTransient();
      expect(c.mood, CompanionMood.idle);
    });

    test('runFailed → error → idle', () {
      c.onEvent(PresenceEvent.messageSent);
      c.onEvent(PresenceEvent.runFailed);
      expect(c.mood, CompanionMood.error);
      c.debugSettleTransient();
      expect(c.mood, CompanionMood.idle);
    });

    test('prioridad: error overlay manda sobre approval', () {
      c.onEvent(PresenceEvent.approvalNeeded); // waiting
      c.onEvent(PresenceEvent.runFailed); // limpia approval + overlay error
      expect(c.mood, CompanionMood.error);
    });

    test('prioridad: approval(waiting) sobre thinking', () {
      c.onEvent(PresenceEvent.messageSent); // thinking
      c.onEvent(PresenceEvent.approvalNeeded); // waiting gana
      expect(c.mood, CompanionMood.waiting);
    });

    test('appOpened y petTapped → saludo(success) transitorio', () {
      c.onEvent(PresenceEvent.appOpened);
      expect(c.mood, CompanionMood.success);
      c.debugSettleTransient();
      expect(c.mood, CompanionMood.idle);

      c.onEvent(PresenceEvent.petTapped);
      expect(c.mood, CompanionMood.success);
    });

    test('petTapped sobre estado offline vuelve a offline tras el saludo', () {
      c.setConnectionStatus(PresenceConnection.offline);
      c.onEvent(PresenceEvent.petTapped);
      expect(c.mood, CompanionMood.success);
      c.debugSettleTransient();
      expect(c.mood, CompanionMood.offline);
    });

    test('replayToken incrementa en cada transitorio', () {
      final t0 = c.replayToken;
      c.onEvent(PresenceEvent.petTapped);
      expect(c.replayToken, greaterThan(t0));
    });

    test('notifica a los listeners en los cambios de ánimo', () {
      var n = 0;
      c.addListener(() => n++);
      c.onEvent(PresenceEvent.messageSent); // idle→thinking
      expect(n, greaterThan(0));
    });
  });
}
