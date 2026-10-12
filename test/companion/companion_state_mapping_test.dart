import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/models/companion_mood.dart';

void main() {
  group('companionStateForMood', () {
    const expected = <CompanionMood, CompanionAnimationState>{
      CompanionMood.idle: CompanionAnimationState.idle,
      CompanionMood.thinking: CompanionAnimationState.run,
      CompanionMood.connecting: CompanionAnimationState.waiting,
      CompanionMood.waiting: CompanionAnimationState.waiting,
      CompanionMood.success: CompanionAnimationState.wave,
      CompanionMood.error: CompanionAnimationState.failed,
      CompanionMood.offline: CompanionAnimationState.idle,
      CompanionMood.jump: CompanionAnimationState.jump,
    };

    test('cubre todos los CompanionMood', () {
      expect(expected.keys.toSet(), CompanionMood.values.toSet());
    });

    for (final entry in expected.entries) {
      test('${entry.key.name} → ${entry.value.name}', () {
        expect(companionStateForMood(entry.key), entry.value);
      });
    }
  });

  group('companionStateFromId', () {
    test('reconoce ids válidos', () {
      expect(companionStateFromId('idle'), CompanionAnimationState.idle);
      expect(companionStateFromId('failed'), CompanionAnimationState.failed);
    });

    test('devuelve null para ids desconocidos', () {
      expect(companionStateFromId('bogus'), isNull);
    });
  });

  group('CompanionAnimationStateX.loopsByDefault', () {
    test('idle/run/waiting ciclan; wave/failed/jump/review no', () {
      expect(CompanionAnimationState.idle.loopsByDefault, isTrue);
      expect(CompanionAnimationState.run.loopsByDefault, isTrue);
      expect(CompanionAnimationState.waiting.loopsByDefault, isTrue);
      expect(CompanionAnimationState.wave.loopsByDefault, isFalse);
      expect(CompanionAnimationState.failed.loopsByDefault, isFalse);
      expect(CompanionAnimationState.jump.loopsByDefault, isFalse);
      expect(CompanionAnimationState.review.loopsByDefault, isFalse);
    });
  });
}
