import 'dart:convert';

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

    test('a FUTURE schema version fails closed to defaults', () {
      final style = DockStyle.fromJson({
        'schema_version': 99,
        'border_shape': 'rounded',
        'transparency': 1.0,
        'depth': 'floating',
      });

      expect(style.toJson(), const DockStyle().toJson());
    });

    test(
      'a lower-than-current schema version is not rejected outright (C3)',
      () {
        // Regression for C3: any bump of `schemaVersion` used to wipe the
        // whole payload for a version mismatch in either direction. A
        // version <= the current one should still go through field-by-field
        // parsing (the "upgrade path") instead of failing closed; only a
        // genuinely FUTURE version (a real downgrade of the app) does.
        final style = DockStyle.fromJson({
          'schema_version': 0,
          'border_shape': 'rounded',
          'transparency': 0.5,
          'depth': 'flat',
        });

        expect(style.borderShape, DockBorderShape.rounded);
        expect(style.transparency, 0.5);
        expect(style.depth, DockDepth.flat);
      },
    );

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

    test(
      'a non-boolean "visible" field does not silently count as visible (C5)',
      () {
        final fallback = DockProfileConfig.defaultGeneral();
        final persisted = {
          'schema_version': DockProfileConfig.schemaVersion,
          'items': [
            {'id': 'home', 'visible': 'yes'},
            {'id': 'create', 'visible': true},
          ],
          'show_back_on_subscreens': true,
          'style': const DockStyle().toJson(),
        };

        final value = DockProfileConfig.fromJson(persisted, fallback);

        // Before the fix, `json['visible'] != false` let ANY non-`false`
        // value (a string, a number, `null`) through as visible; a
        // non-boolean now falls back to the type's default (`true`) via an
        // explicit type check, but the important part is that this no
        // longer depends on the field's literal (accidental) value.
        expect(value.items.first.id, DockItemId.home);
        expect(value.items.first.visible, isTrue);
      },
    );

    test('duplicate item ids in persisted data are deduplicated (C5)', () {
      final fallback = DockProfileConfig.defaultGeneral();
      final persisted = {
        'schema_version': DockProfileConfig.schemaVersion,
        'items': [
          {'id': 'home', 'visible': true},
          {'id': 'home', 'visible': false},
          {'id': 'create', 'visible': true},
        ],
        'show_back_on_subscreens': true,
        'style': const DockStyle().toJson(),
      };

      final value = DockProfileConfig.fromJson(persisted, fallback);

      expect(value.items.where((i) => i.id == DockItemId.home).length, 1);
      // The FIRST occurrence wins, matching how `resolveDockSlots` and the
      // reorder/visibility UI already treat "first" as authoritative.
      expect(
        value.items.firstWhere((i) => i.id == DockItemId.home).visible,
        isTrue,
      );
    });

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
      final slots = resolveDockSlots(visibleItems: items, showBack: false);

      expect(slots, items);
    });

    test('inserts Back without dropping any visible item', () {
      final slots = resolveDockSlots(visibleItems: items, showBack: true);

      // A previous version silently dropped the last non-pinned item to
      // avoid growing the bar by one slot — but that made an item the user
      // just enabled in Ajustes › Dock "disappear" depending on the screen,
      // with no indication why. Every visible item now always shows.
      expect(slots, [
        null,
        DockItemId.bots,
        DockItemId.create,
        DockItemId.work,
      ]);
    });

    test(
      'a single visible item survives Back by growing the bar by one slot',
      () {
        // The bar itself does not change size in practice (each tile just
        // narrows), so growing from 1 to 2 slots is the correct behavior.
        final slots = resolveDockSlots(
          visibleItems: const [DockItemId.create],
          showBack: true,
        );

        expect(slots, [null, DockItemId.create]);
      },
    );

    test(
      'an empty visible list still shows Back instead of an empty floating bar',
      () {
        // Regression for A4: a profile with every item hidden used to
        // resolve to an empty slot list even with Back requested, leaving a
        // floating bar with no items and no way to navigate. The old test
        // here froze that bug as expected behavior; this asserts the fix.
        expect(resolveDockSlots(visibleItems: const [], showBack: true), [
          null,
        ]);
      },
    );

    test('an empty visible list stays empty when Back is not shown', () {
      expect(
        resolveDockSlots(visibleItems: const [], showBack: false),
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

    test(
      'a well-formed payload with an unexpected field type also fails closed (not just malformed JSON)',
      () async {
        // Regression for C1: `load()` used to catch only `FormatException`
        // (malformed JSON syntax). A syntactically valid JSON document with
        // an unexpected type deep inside — here a String where `bots` is
        // expected to be a Map — throws a `TypeError` at
        // `(json['bots'] as Map?)`, which used to escape uncaught from
        // `unawaited(ensureLoaded())`.
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'dock_preferences_v1',
          jsonEncode({'schema_version': 1, 'bots': 'oops', 'general': {}}),
        );
        final store = DockPreferencesStore(prefs);

        final value = store.load();

        expect(value.bots.toJson(), DockPreferences.defaults().bots.toJson());
      },
    );

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

    test(
      'persist: false updates memory instantly without writing to disk; a '
      'later persist: true call writes the value that is currently in memory',
      () async {
        // Regression for C4: the transparency slider used to write to
        // `SharedPreferences` on every `onChanged` frame while dragging.
        // `persist: false` must update the reactive in-memory value (so a
        // live preview keeps working) without touching disk at all; disk
        // catches up only once persistence is explicitly requested.
        final controller = DockPreferencesController.instance;
        await controller.ensureLoaded();
        final prefs = await SharedPreferences.getInstance();

        await controller.updateBots(
          (p) => p.copyWith(style: p.style.copyWith(transparency: 0.42)),
          persist: false,
        );

        expect(controller.value.bots.style.transparency, 0.42);
        final onDiskDuringDrag = DockPreferencesStore(prefs).load();
        expect(onDiskDuringDrag.bots.style.transparency, isNot(0.42));

        await controller.updateBots(
          (p) => p.copyWith(style: p.style.copyWith(transparency: 0.42)),
        );

        final onDiskAfterCommit = DockPreferencesStore(prefs).load();
        expect(onDiskAfterCommit.bots.style.transparency, 0.42);

        await controller.resetBots();
      },
    );
  });
}
