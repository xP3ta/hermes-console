import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/pairing_link_delivery_gate.dart';

void main() {
  group('PairingLinkDeliveryGate', () {
    late DateTime now;
    late PairingLinkDeliveryGate gate;

    setUp(() {
      now = DateTime.utc(2026, 8, 27, 12);
      gate = PairingLinkDeliveryGate(
        now: () => now,
        duplicateWindow: const Duration(seconds: 2),
      );
    });

    test('accepts the first delivery and rejects its immediate duplicate', () {
      final uri = Uri.parse('hermes://pair?host=server&port=8642&token=one');

      expect(gate.shouldHandle(uri), isTrue);
      expect(gate.shouldHandle(uri), isFalse);
    });

    test('accepts a different pairing link immediately', () {
      final first = Uri.parse('hermes://pair?host=one&port=8642&token=one');
      final second = Uri.parse('hermes://pair?host=two&port=8642&token=two');

      expect(gate.shouldHandle(first), isTrue);
      expect(gate.shouldHandle(second), isTrue);
    });

    test('rejects A B A when the second A is still immediate', () {
      final first = Uri.parse('hermes://pair?host=one&port=8642&token=one');
      final second = Uri.parse('hermes://pair?host=two&port=8642&token=two');

      expect(gate.shouldHandle(first), isTrue);
      expect(gate.shouldHandle(second), isTrue);
      expect(gate.shouldHandle(first), isFalse);
    });

    test('allows opening the same link again after the duplicate window', () {
      final uri = Uri.parse('hermes://pair?host=server&port=8642&token=one');

      expect(gate.shouldHandle(uri), isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(gate.shouldHandle(uri), isTrue);
    });

    test('does not suppress a delivery when the clock moves backwards', () {
      final uri = Uri.parse('hermes://pair?host=server&port=8642&token=one');

      expect(gate.shouldHandle(uri), isTrue);
      now = now.subtract(const Duration(seconds: 1));
      expect(gate.shouldHandle(uri), isTrue);
    });

    test('retains a link until the navigator can consume it', () {
      final uri = Uri.parse('hermes://pair?host=server&port=8642&token=one');

      gate.defer(uri);

      expect(gate.hasDeferred, isTrue);
      expect(gate.takeDeferred(), uri);
      expect(gate.hasDeferred, isFalse);
    });

    test('queues an identical deferred link only once', () {
      final uri = Uri.parse('hermes://pair?host=server&port=8642&token=one');

      gate.defer(uri);
      gate.defer(uri);

      expect(gate.takeDeferred(), uri);
      expect(gate.takeDeferred(), isNull);
    });

    test('preserves the order of different deferred links', () {
      final first = Uri.parse('hermes://pair?host=one&port=8642&token=one');
      final second = Uri.parse('hermes://pair?host=two&port=8642&token=two');

      gate.defer(first);
      gate.defer(second);

      expect(gate.takeDeferred(), first);
      expect(gate.takeDeferred(), second);
    });

    test('waiting for navigator does not rotate FIFO', () {
      final first = Uri.parse('hermes://pair?host=one&port=8642&token=one');
      final second = Uri.parse('hermes://pair?host=two&port=8642&token=two');

      gate.defer(first);
      gate.defer(second);

      expect(gate.takeDeferredIf(false), isNull);
      expect(gate.takeDeferredIf(false), isNull);
      expect(gate.takeDeferredIf(true), first);
      expect(gate.takeDeferredIf(true), second);
    });
  });
}
