// «Herramientas» is gone (1.4.0). Everything that could still name it is
// redirected: the stored dock layouts and dock configs, the old dock
// functions, and nothing native ever pointed at it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/screens/app_settings_screen.dart';
import 'package:hermes_android/core/services/notifications/notification_action_drain.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/widgets/dock_shortcuts.dart';

import '../support/nav_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stored dock layouts', () {
    test('a stored «tools» tab is Ajustes', () {
      expect(GestureDockTab.parse('tools'), GestureDockTab.settings);
      expect(GestureDockTab.parse('settings'), GestureDockTab.settings);
      expect(GestureDockTab.parse('agents'), GestureDockTab.agents);
      expect(GestureDockTab.parse('nonsense'), isNull);
    });

    test('the layouts older versions wrote read as something that still '
        'exists', () {
      for (final stored in const [
        ['home', 'create', 'search', 'bots', 'tools'],
        ['home', 'tools'],
        ['create', 'home', 'tools', 'cron'],
        ['home', 'tools', 'settings'],
      ]) {
        final tabs = GestureDockSettings.fromJson({
          'schema_version': 1,
          'tabs': stored,
        }).tabs;
        expect(tabs, isNotEmpty);
        expect(tabs.map((t) => t.name), isNot(contains('tools')));
        expect(tabs, contains(GestureDockTab.home));
        // No repeats after the redirect.
        expect(tabs.toSet(), hasLength(tabs.length), reason: '$stored');
      }
    });
  });

  group('stored dock configs (the classic catalog)', () {
    DockProfileConfig read(List<Map<String, Object?>> items) =>
        DockProfileConfig.fromJson({
          'schema_version': 1,
          'items': items,
          'show_back_on_subscreens': true,
        }, DockProfileConfig.defaultGeneral());

    test('a visible «tools» becomes a visible Ajustes where it stood', () {
      final config = read([
        {'id': 'home', 'visible': true},
        {'id': 'tools', 'visible': true},
        {'id': 'bots', 'visible': true},
        {'id': 'settings', 'visible': false},
      ]);
      expect(config.items.map((i) => i.id.name), isNot(contains('tools')));
      expect(config.visibleItemIds, [
        DockItemId.home,
        DockItemId.bots,
        DockItemId.settings,
      ]);
    });

    test('with no Ajustes stored, it takes the place of «tools»', () {
      final config = read([
        {'id': 'home', 'visible': true},
        {'id': 'tools', 'visible': true},
        {'id': 'bots', 'visible': true},
      ]);
      expect(config.items.map((i) => i.id).take(3).toList(), [
        DockItemId.home,
        DockItemId.settings,
        DockItemId.bots,
      ]);
      expect(config.items[1].visible, isTrue);
    });

    test('a hidden «tools» leaves Ajustes as it was', () {
      final config = read([
        {'id': 'home', 'visible': true},
        {'id': 'tools', 'visible': false},
        {'id': 'settings', 'visible': false},
      ]);
      expect(config.visibleItemIds, [DockItemId.home]);
      expect(config.items.map((i) => i.id.name), isNot(contains('tools')));
    });

    test('«tools» parses to Ajustes for any reader of the id', () {
      expect(DockItemId.parse('tools'), DockItemId.settings);
      expect(DockItemId.values.map((i) => i.name), isNot(contains('tools')));
    });
  });

  group('the old dock functions', () {
    testWidgets('openDockTools and dockToolsBuilder open Ajustes de la app', (
      tester,
    ) async {
      final manager = await navManager();
      late BuildContext context;
      await tester.pumpWidget(
        navApp(
          Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final built = dockToolsBuilder(navConnection(), manager)(context);
      expect(built, isA<AppSettingsScreen>());
      // Without an instance too (Instancias still works).
      expect(
        dockToolsBuilder(null, manager)(context),
        isA<AppSettingsScreen>(),
      );
    });
  });

  group('nothing native names «Herramientas»', () {
    String read(String path) => File(path).readAsStringSync();

    test(
      'shortcuts, manifest and notification routes have no tools target',
      () {
        for (final path in const [
          'android/app/src/main/res/xml/shortcuts.xml',
          'android/app/src/main/AndroidManifest.xml',
        ]) {
          final text = read(path)
              // The manifest merger's `tools:` namespace is not a destination.
              .replaceAll(RegExp(r'xmlns:tools="[^"]*"'), '')
              .replaceAll(RegExp(r'tools:[a-zA-Z]+="[^"]*"'), '');
          expect(text, isNot(contains('hermes://tools')), reason: path);
          expect(text.toLowerCase(), isNot(contains('"tools"')), reason: path);
        }
        expect(
          allNotificationActionRoutes.map((r) => r.name),
          isNot(anyOf(contains('tools'), contains('settings'))),
        );
      },
    );

    test('no widget, quick tile or shortcut intent asks for the tools tab', () {
      final kotlin = Directory('android/app/src/main/kotlin')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.kt'));
      for (final file in kotlin) {
        final text = file.readAsStringSync();
        expect(
          text,
          isNot(matches(RegExp(r'''["']tools["']'''))),
          reason: file.path,
        );
      }
    });
  });
}
