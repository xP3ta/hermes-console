import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_health_tracker.dart';

void main() {
  group('ConnectionHealthTracker', () {
    test('un microcorte no convierte una conexión sana en offline', () {
      final tracker = ConnectionHealthTracker();
      final first = tracker.beginProbe();
      expect(tracker.recordResult(first, healthy: true), isTrue);

      final transient = tracker.beginProbe();
      expect(tracker.recordResult(transient, healthy: false), isTrue);

      expect(tracker.healthy, isTrue);
      expect(tracker.checking, isTrue);
      expect(tracker.retryDelay, const Duration(seconds: 3));
    });

    test('dos fallos consecutivos confirman el estado offline', () {
      final tracker = ConnectionHealthTracker();
      tracker.recordResult(tracker.beginProbe(), healthy: true);
      tracker.recordResult(tracker.beginProbe(), healthy: false);
      tracker.recordResult(tracker.beginProbe(), healthy: false);

      expect(tracker.healthy, isFalse);
      expect(tracker.checking, isFalse);
      expect(tracker.consecutiveFailures, 2);
      expect(tracker.retryDelay, const Duration(seconds: 30));
    });

    test('una respuesta antigua no pisa una comprobación nueva', () {
      final tracker = ConnectionHealthTracker();
      final oldProbe = tracker.beginProbe();
      final currentProbe = tracker.beginProbe();

      expect(tracker.recordResult(currentProbe, healthy: true), isTrue);
      expect(tracker.recordResult(oldProbe, healthy: false), isFalse);
      expect(tracker.healthy, isTrue);
      expect(tracker.consecutiveFailures, 0);
    });

    test('un éxito recupera inmediatamente y reinicia los fallos', () {
      final tracker = ConnectionHealthTracker();
      tracker.recordResult(tracker.beginProbe(), healthy: false);
      tracker.recordResult(tracker.beginProbe(), healthy: false);
      tracker.recordResult(tracker.beginProbe(), healthy: true);

      expect(tracker.healthy, isTrue);
      expect(tracker.checking, isFalse);
      expect(tracker.consecutiveFailures, 0);
    });
  });

  test(
    'qa9485: un re-sondeo de una conexión sana no muestra «comprobando»',
    () {
      final tracker = ConnectionHealthTracker();
      tracker.beginProbe();
      // Primer sondeo: nada conocido aún.
      expect(tracker.showsChecking, isTrue);
      tracker.recordResult(1, healthy: true);
      final probe = tracker.beginProbe();
      expect(tracker.checking, isTrue);
      expect(tracker.showsChecking, isFalse);
      // Tras caer a offline, el siguiente sondeo vuelve a «comprobando».
      tracker.recordResult(probe, healthy: false);
      tracker.recordResult(tracker.beginProbe(), healthy: false);
      tracker.beginProbe();
      expect(tracker.showsChecking, isTrue);
    },
  );
}
