import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DockStyle', () {
    test('codec v1 round-trips border shape, transparency and depth', () {
      const style = DockStyle(
        borderShape: DockBorderShape.rounded,
        transparency: 0.4,
        depth: DockDepth.floating,
      );

      expect(DockStyle.fromJson(style.toJson()).toJson(), style.toJson());
    });

    test('unknown schema fails closed to defaults', () {
      final style = DockStyle.fromJson({
        'schema_version': 99,
        'border_shape': 'rounded',
        'transparency': 1.0,
        'depth': 'floating',
      });

      expect(style.toJson(), const DockStyle().toJson());
    });

    test('out-of-range transparency clamps to [0, 1]', () {
      final style = DockStyle.fromJson({
        'schema_version': DockStyle.schemaVersion,
        'border_shape': 'soft',
        'transparency': 5.0,
        'depth': 'elevated',
      });

      expect(style.transparency, 1.0);
    });
  });

  group('DockProfileConfig', () {
    test('unknown schema fails closed to the given fallback', () {
      final fallback = DockProfileConfig.defaultBots();

      final value = DockProfileConfig.fromJson({'schema_version': 0}, fallback);

      expect(value.toJson(), fallback.toJson());
    });

    test(
      'a default catalog item missing from persisted data is appended hidden',
      () {
        final fallback = DockProfileConfig.defaultGeneral();
        final persisted = {
          'schema_version': DockProfileConfig.schemaVersion,
          'items': [
            {'id': 'home', 'visible': true},
            {'id': 'create', 'visible': true},
          ],
          'pinned_item_id': 'create',
          'show_back_on_subscreens': true,
          'style': const DockStyle().toJson(),
        };

        final value = DockProfileConfig.fromJson(persisted, fallback);

        expect(value.items.map((i) => i.id.name), [
          'home',
          'create',
          'bots',
          'settings',
          'work',
          'cron',
          'tasks',
          'sessions',
          'tools',
        ]);
        expect(value.items.last.visible, isFalse);
        expect(value.visibleItemIds.map((i) => i.name), ['home', 'create']);
      },
    );

    test('style is not shared between profiles', () {
      final bots = DockProfileConfig.defaultBots().copyWith(
        style: const DockStyle(borderShape: DockBorderShape.square),
      );
      final general = DockProfileConfig.defaultGeneral();

      expect(bots.style.borderShape, DockBorderShape.square);
      expect(general.style.borderShape, const DockStyle().borderShape);
    });
  });

  group('resolveDockSlots', () {
    const items = [DockItemId.bots, DockItemId.create, DockItemId.work];

    test('returns visible items unchanged when Back is not shown', () {
      final slots = resolveDockSlots(
        visibleItems: items,
        pinnedItemId: DockItemId.create,
        showBack: false,
      );

      expect(slots, items);
    });

    test(
      'inserts Back and drops the last non-pinned item to keep dock size stable',
      () {
        final slots = resolveDockSlots(
          visibleItems: items,
          pinnedItemId: DockItemId.create,
          showBack: true,
        );

        expect(slots, [null, DockItemId.bots, DockItemId.create]);
      },
    );

    test(
      'never removes the pinned item even when it is the only alternative',
      () {
        final slots = resolveDockSlots(
          visibleItems: const [DockItemId.bots, DockItemId.create],
          pinnedItemId: DockItemId.create,
          showBack: true,
        );

        // "bots" is the only non-pinned item, so it is the one dropped;
        // "create" (pinned) survives.
        expect(slots, [null, DockItemId.create]);
      },
    );

    test('empty visible list stays empty regardless of Back', () {
      expect(
        resolveDockSlots(
          visibleItems: const [],
          pinnedItemId: DockItemId.create,
          showBack: true,
        ),
        isEmpty,
      );
    });
  });

  group('DockPreferences', () {
    test('defaults give Bots and General distinct catalogs', () {
      final defaults = DockPreferences.defaults();

      expect(
        defaults.bots.items.map((i) => i.id.name),
        containsAll(['bots', 'create', 'work']),
      );
      expect(
        defaults.general.items.map((i) => i.id.name),
        containsAll(['home', 'create', 'bots', 'settings']),
      );
    });

    test('unknown schema fails closed to defaults', () {
      final value = DockPreferences.fromJson({'schema_version': -1});

      expect(value.bots.toJson(), DockPreferences.defaults().bots.toJson());
      expect(
        value.general.toJson(),
        DockPreferences.defaults().general.toJson(),
      );
    });
  });

  group('DockPreferencesStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('load with nothing persisted returns defaults', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = DockPreferencesStore(prefs);

      final value = store.load();

      expect(value.bots.toJson(), DockPreferences.defaults().bots.toJson());
    });

    test('save then load round-trips a customized profile', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = DockPreferencesStore(prefs);
      final customized = DockPreferences.defaults().copyWith(
        bots: DockPreferences.defaults().bots.copyWith(
          style: const DockStyle(
            borderShape: DockBorderShape.square,
            depth: DockDepth.flat,
          ),
        ),
      );

      await store.save(customized);
      final reloaded = store.load();

      expect(reloaded.bots.toJson(), customized.bots.toJson());
      expect(reloaded.general.toJson(), customized.general.toJson());
    });

    test('corrupt persisted payload fails closed to defaults', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('dock_preferences_v1', 'not json');
      final store = DockPreferencesStore(prefs);

      final value = store.load();

      expect(value.bots.toJson(), DockPreferences.defaults().bots.toJson());
    });

    test('clear removes the persisted payload', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = DockPreferencesStore(prefs);
      await store.save(DockPreferences.defaults());

      await store.clear();

      expect(prefs.getString('dock_preferences_v1'), isNull);
    });
  });

  group('DockPreferencesController', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('updateBots persists the change and notifies listeners', () async {
      final controller = DockPreferencesController.instance;
      await controller.ensureLoaded();
      var notified = false;
      controller.listenable.addListener(() => notified = true);

      await controller.updateBots(
        (p) => p.copyWith(style: p.style.copyWith(depth: DockDepth.flat)),
      );

      expect(notified, isTrue);
      expect(controller.value.bots.style.depth, DockDepth.flat);

      final prefs = await SharedPreferences.getInstance();
      final reloaded = DockPreferencesStore(prefs).load();
      expect(reloaded.bots.style.depth, DockDepth.flat);

      // Reset shared singleton state so other tests are not affected by
      // this test's writes to the process-wide controller instance.
      await controller.resetBots();
    });
  });
}
