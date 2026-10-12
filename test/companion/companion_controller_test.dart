import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/models/companion_presence_level.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

Companion _nimbus([String slug = 'nimbus']) => Companion(
  slug: slug,
  name: slug,
  author: 'team',
  license: 'CC0-1.0',
  spritesheetAsset: 'assets/companions/$slug/spritesheet.webp',
  frameWidth: 192,
  frameHeight: 208,
  cols: 8,
  rows: 9,
  fps: 8,
  states: const {
    CompanionAnimationState.idle: RowSpec(row: 0, frameCount: 8, loop: true),
  },
);

/// Repo de prueba que evita la carga real de assets.
class _FakeRepo extends CompanionRepository {
  final List<Companion> _all;
  _FakeRepo(this._all);

  @override
  Future<List<Companion>> loadAll() async => _all;
}

Future<CompanionController> _controller(List<Companion> pets) async {
  final prefs = await CompanionPreferences.load();
  return CompanionController(_FakeRepo(pets), prefs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('init carga disponibles y aplica defaults', () async {
    final c = await _controller([_nimbus()]);
    await c.init();
    expect(c.available.length, 1);
    expect(c.enabled, isTrue);
    expect(c.selectedSlug, isNull);
    expect(c.activeCompanion, isNull); // sin selección → fallback
    // On, everywhere, for whoever never touched the setting.
    expect(c.presence, CompanionPresenceLevel.full);
  });

  test('seleccionar activa la mascota', () async {
    final c = await _controller([_nimbus()]);
    await c.init();
    await c.select('nimbus');
    expect(c.activeCompanion?.slug, 'nimbus');
  });

  test(
    'on/off: enabled=false → activeCompanion null aunque haya selección',
    () async {
      final c = await _controller([_nimbus()]);
      await c.init();
      await c.select('nimbus');
      await c.setEnabled(false);
      expect(c.enabled, isFalse);
      expect(c.activeCompanion, isNull);
    },
  );

  test('slug inexistente → activeCompanion null (fallback)', () async {
    final c = await _controller([_nimbus()]);
    await c.init();
    await c.select('no-existe');
    expect(c.activeCompanion, isNull);
  });

  test('persiste selección y on/off entre instancias', () async {
    final prefs1 = await CompanionPreferences.load();
    final c1 = CompanionController(_FakeRepo([_nimbus()]), prefs1);
    await c1.init();
    await c1.select('nimbus');
    await c1.setEnabled(false);

    final prefs2 = await CompanionPreferences.load();
    final c2 = CompanionController(_FakeRepo([_nimbus()]), prefs2);
    await c2.init();
    expect(c2.selectedSlug, 'nimbus');
    expect(c2.enabled, isFalse);
    expect(c2.activeCompanion, isNull); // desactivada
  });

  test('tamaño continuo y nivel visible se mantienen coherentes', () async {
    final c = await _controller([_nimbus()]);
    await c.init();

    await c.setSizeMultiplier(1.33);
    expect(c.sizeMultiplier, closeTo(1.33, 0.001));

    await c.setVisibilityLevel(CompanionPresenceLevel.off);
    expect(c.enabled, isFalse);
    expect(c.presence, CompanionPresenceLevel.off);
    expect(c.presenceLevel, CompanionPresenceLevel.off);

    await c.setVisibilityLevel(CompanionPresenceLevel.full);
    expect(c.enabled, isTrue);
    expect(c.presence, CompanionPresenceLevel.full);

    await c.setVisibilityLevel(CompanionPresenceLevel.chat);
    expect(c.enabled, isTrue);
    expect(c.presence, CompanionPresenceLevel.chat);
  });

  group('what a chat reads (presenceLevel)', () {
    test('no pet of its own: the island keeps the face it had', () async {
      final c = await _controller([_nimbus()]);
      await c.init();
      expect(c.presence, CompanionPresenceLevel.full);
      expect(c.presenceLevel, CompanionPresenceLevel.ambient);
      expect(c.presenceLevel.showsStatusPresence, isFalse);
      expect(c.presenceLevel.isVisible, isTrue);
      await c.setVisibilityLevel(CompanionPresenceLevel.chat);
      expect(c.presenceLevel, CompanionPresenceLevel.ambient);
    });

    test('with a pet: it stands on the island in both choices', () async {
      final c = await _controller([_nimbus()]);
      await c.init();
      await c.select('nimbus');
      expect(c.presenceLevel, CompanionPresenceLevel.full);
      expect(c.presenceLevel.showsStatusPresence, isTrue);
      await c.setVisibilityLevel(CompanionPresenceLevel.chat);
      expect(c.presenceLevel, CompanionPresenceLevel.chat);
      expect(c.presenceLevel.showsStatusPresence, isTrue);
      await c.setVisibilityLevel(CompanionPresenceLevel.off);
      expect(c.presenceLevel, CompanionPresenceLevel.off);
    });

    test('the old stored values', () async {
      // "Mínima" (and nothing stored): now everywhere.
      SharedPreferences.setMockInitialValues({
        CompanionPreferences.presenceLevelKey: 'minimal',
      });
      var c = await _controller([_nimbus()]);
      await c.init();
      expect(c.presence, CompanionPresenceLevel.full);
      expect(c.presenceLevel, CompanionPresenceLevel.ambient);

      // "Completa" without a pet kept the profile's face in the pet's
      // slot of the island: whoever had it keeps it.
      SharedPreferences.setMockInitialValues({
        CompanionPreferences.presenceLevelKey: 'full',
      });
      c = await _controller([_nimbus()]);
      await c.init();
      expect(c.presence, CompanionPresenceLevel.full);
      expect(c.presenceLevel, CompanionPresenceLevel.full);
      // Choosing again is a choice of the new setting.
      await c.setVisibilityLevel(CompanionPresenceLevel.chat);
      expect(c.presenceLevel, CompanionPresenceLevel.ambient);

      SharedPreferences.setMockInitialValues({
        CompanionPreferences.presenceLevelKey: 'off',
      });
      c = await _controller([_nimbus()]);
      await c.init();
      expect(c.presence, CompanionPresenceLevel.off);
    });
  });

  test('la velocidad es independiente para cada mascota', () async {
    final c = await _controller([_nimbus(), _nimbus('jinx')]);
    await c.init();

    await c.select('nimbus');
    await c.setAnimationSpeed(0.6);
    expect(c.animationSpeed, closeTo(0.6, 0.001));

    await c.select('jinx');
    expect(c.animationSpeed, 1);
    await c.setAnimationSpeed(1.2);

    await c.select('nimbus');
    expect(c.animationSpeed, closeTo(0.6, 0.001));
    await c.select('jinx');
    expect(c.animationSpeed, closeTo(1.2, 0.001));
  });
}
