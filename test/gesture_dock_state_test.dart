import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GestureDockController c;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    c = GestureDockController()
      ..resetForTesting(settings: const GestureDockSettings());
    c.attach(Object());
  });

  tearDown(() => c.resetForTesting());

  group('hidden by hand', () {
    test('shown until someone hides it; setHidden is the only way', () {
      expect(c.hidden.value, isFalse);
      var changes = 0;
      c.hidden.addListener(() => changes++);
      c.setHidden(true);
      c.setHidden(true);
      expect(c.hidden.value, isTrue);
      expect(changes, 1);
      c.setHidden(false);
      expect(c.hidden.value, isFalse);
      expect(changes, 2);
    });

    test('a new screen keeps it as it is', () {
      c.setHidden(true);
      c.attach(Object());
      expect(c.hidden.value, isTrue);
      c.setHidden(false);
      c.attach(Object());
      expect(c.hidden.value, isFalse);
    });
  });

  group('layout (edit mode)', () {
    test('normalize keeps Inicio, drops repeats and caps at 5', () {
      expect(
        GestureDockTab.normalize([
          GestureDockTab.projects,
          GestureDockTab.projects,
        ]),
        [GestureDockTab.home, GestureDockTab.projects],
      );
      expect(
        GestureDockTab.normalize([
          GestureDockTab.search,
          GestureDockTab.cron,
          GestureDockTab.tasks,
          GestureDockTab.tools,
          GestureDockTab.bots,
          GestureDockTab.activity,
          GestureDockTab.home,
        ]),
        hasLength(5),
      );
      expect(
        GestureDockTab.normalize([
          GestureDockTab.search,
          GestureDockTab.cron,
          GestureDockTab.tasks,
          GestureDockTab.tools,
          GestureDockTab.bots,
          GestureDockTab.activity,
          GestureDockTab.home,
        ]),
        contains(GestureDockTab.home),
      );
      expect(GestureDockTab.normalize([GestureDockTab.home]), hasLength(2));
    });

    test(
      'setTabs persists the order; resetTabs restores the default',
      () async {
        await c.setTabs([
          GestureDockTab.home,
          GestureDockTab.activity,
          GestureDockTab.search,
        ]);
        final prefs = await SharedPreferences.getInstance();
        final stored = GestureDockSettings.fromJson(
          jsonDecode(prefs.getString(GestureDockController.storageKey)!),
        );
        expect(stored.tabs, [
          GestureDockTab.home,
          GestureDockTab.activity,
          GestureDockTab.search,
        ]);
        await c.resetTabs();
        expect(c.value.tabs, GestureDockTab.defaultLayout);
      },
    );

    test('the names stored on the device never change', () {
      expect(
        [for (final tab in GestureDockTab.values) tab.name],
        [
          'home',
          'create',
          'projects',
          'settings',
          'bots',
          'search',
          'cron',
          'tasks',
          'tools',
          'activity',
        ],
      );
    });
  });

  // Owner: "Yo pondría: Inicio, crear chat, Chats, Bots y Herramientas".
  group('default layout', () {
    Map<String, Object?> stored(List<String> tabs, {int? layoutVersion}) => {
      'schema_version': 1,
      'layout_version': ?layoutVersion,
      'tabs': tabs,
      'opaque': true,
      'welcome_seen': true,
    };

    const legacy = ['home', 'create', 'projects', 'settings'];

    test('Inicio, Nuevo chat, Chats, Bots, Herramientas', () {
      expect(GestureDockTab.defaultLayout, [
        GestureDockTab.home,
        GestureDockTab.create,
        GestureDockTab.search,
        GestureDockTab.bots,
        GestureDockTab.tools,
      ]);
      expect(const GestureDockSettings().tabs, GestureDockTab.defaultLayout);
      expect(
        GestureDockSettings.fromJson(const {'schema_version': 1}).tabs,
        GestureDockTab.defaultLayout,
      );
      expect(
        GestureDockTab.normalize(GestureDockTab.defaultLayout),
        GestureDockTab.defaultLayout,
      );
    });

    test('a dock nobody edited (still the old four) moves to it', () {
      final loaded = GestureDockSettings.fromJson(stored(legacy));
      expect(loaded.tabs, GestureDockTab.defaultLayout);
      expect(loaded.opaque, isTrue, reason: 'the rest is kept');
      // The dock with gestures wrote no layout version at all.
      expect(
        GestureDockSettings.fromJson(stored(legacy, layoutVersion: 1)).tabs,
        GestureDockTab.defaultLayout,
      );
    });

    test('a dock someone edited keeps its own items', () {
      for (final own in const [
        ['home', 'projects', 'create', 'settings'],
        ['home', 'create', 'projects'],
        ['home', 'create', 'projects', 'settings', 'bots'],
        ['home', 'search'],
        ['create', 'home', 'tools', 'activity', 'cron'],
      ]) {
        expect(
          [
            for (final tab in GestureDockSettings.fromJson(stored(own)).tabs)
              tab.name,
          ],
          own,
          reason: '$own',
        );
      }
    });

    test('the old four, chosen in the editor after the change, stay', () async {
      await c.setTabs(GestureDockTab.legacyDefaultLayout);
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonDecode(
        prefs.getString(GestureDockController.storageKey)!,
      );
      expect((raw as Map)['layout_version'], GestureDockSettings.layoutVersion);
      expect(
        GestureDockSettings.fromJson(raw).tabs,
        GestureDockTab.legacyDefaultLayout,
      );
      final restarted = GestureDockController();
      await restarted.ensureLoaded();
      expect(restarted.value.tabs, GestureDockTab.legacyDefaultLayout);
    });

    test('on the device: the old default is read as the new one and stored '
        'as such on the next change', () async {
      SharedPreferences.setMockInitialValues({
        GestureDockController.storageKey: jsonEncode(stored(legacy)),
      });
      final fresh = GestureDockController();
      await fresh.ensureLoaded();
      expect(fresh.value.tabs, GestureDockTab.defaultLayout);
      await fresh.setOpaque(false);
      final prefs = await SharedPreferences.getInstance();
      final raw =
          jsonDecode(prefs.getString(GestureDockController.storageKey)!)
              as Map<String, dynamic>;
      expect(raw['tabs'], ['home', 'create', 'search', 'bots', 'tools']);
      expect(raw['layout_version'], 2);
    });

    test('a device that never stored anything gets it too', () async {
      SharedPreferences.setMockInitialValues({});
      final fresh = GestureDockController();
      await fresh.ensureLoaded();
      expect(fresh.value.tabs, GestureDockTab.defaultLayout);
    });

    test('Restablecer is the new default', () async {
      await c.setTabs([GestureDockTab.home, GestureDockTab.cron]);
      await c.resetTabs();
      expect(c.value.tabs, GestureDockTab.defaultLayout);
    });
  });

  group('persistence', () {
    test('settings round-trip through SharedPreferences', () async {
      await c.setOpaque(true);
      await c.setTabs([GestureDockTab.home, GestureDockTab.tools]);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(GestureDockController.storageKey)!;
      final loaded = GestureDockSettings.fromJson(jsonDecode(raw));
      expect(loaded.opaque, isTrue);
      expect(loaded.tabs, [GestureDockTab.home, GestureDockTab.tools]);
    });

    test('a fresh controller loads what was stored', () async {
      SharedPreferences.setMockInitialValues({
        GestureDockController.storageKey: jsonEncode(
          const GestureDockSettings(opaque: true).toJson(),
        ),
      });
      final fresh = GestureDockController();
      await fresh.ensureLoaded();
      expect(fresh.value.opaque, isTrue);
    });

    test('a payload from the dock with gestures loads; what it stored about '
        'gestures, auto-hide, tips, tour and welcome is dropped', () async {
      SharedPreferences.setMockInitialValues({
        GestureDockController.storageKey: jsonEncode({
          'schema_version': 1,
          'gestures': false,
          'auto_hide': true,
          'mode': 'auto',
          'tabs': ['home', 'search', 'tools'],
          'opaque': true,
          'tips': true,
          'welcome_seen': true,
          'tour_done': true,
          'learned': ['swipe', 'hide'],
          'taps': 31,
          'last_tip_day': 20000,
          'skips': {'up': 2},
          'hide_hint_shown': true,
        }),
      });
      final fresh = GestureDockController();
      await fresh.ensureLoaded();
      expect(fresh.value.tabs, [
        GestureDockTab.home,
        GestureDockTab.search,
        GestureDockTab.tools,
      ]);
      expect(fresh.value.opaque, isTrue);
      expect(fresh.hidden.value, isFalse, reason: 'auto-hide is gone');

      await fresh.setOpaque(false);
      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString(GestureDockController.storageKey)!)
              as Map<String, dynamic>;
      expect(stored.keys, {
        'schema_version',
        'layout_version',
        'tabs',
        'opaque',
      });
    });

    test('corrupt or future payloads fall back to defaults', () {
      expect(
        GestureDockSettings.fromJson('x').tabs,
        GestureDockTab.defaultLayout,
      );
      expect(
        GestureDockSettings.fromJson({
          'schema_version': 99,
          'opaque': true,
        }).opaque,
        isFalse,
      );
      final odd = GestureDockSettings.fromJson({
        'schema_version': 1,
        'opaque': 7,
        'welcome_seen': 'yes',
        'tabs': ['projects', 'bogus', 'projects'],
      });
      expect(odd.opaque, isFalse);
      expect(odd.tabs, [GestureDockTab.home, GestureDockTab.projects]);
    });
  });
}
