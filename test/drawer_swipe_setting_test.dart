// «Abrir el menú deslizando» (1.4.1, user report: on a Galaxy
// S25 the menu's edge drag fought Android's Back gesture and wide tables).
// Off by default — new install and update alike — and persistent; when off the
// left edge never opens the menu, the menu button always does and the open
// menu still closes. Widget tests cannot certify Android's own Back gesture:
// that is the physical check on the Pixel (gesture navigation). What they
// pin is that Console stops asking Android to keep the edge (the native
// exclusion) while it is off.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/look_feel_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/drawer_gesture_exclusion.dart';
import 'package:hermes_android/core/services/drawer_swipe_prefs.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/look_feel.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cs1215_cold_start_store_test.dart' show MemoryColdStartStorage;
import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

const _menuKey = ValueKey('synthetic-menu');

/// A screen built like the four real ones: the shared flag and band, an
/// AppBar whose implied button opens the menu, and a wide table that starts
/// at the left edge.
Widget _syntheticScreen(DrawerSwipePrefs prefs, ScrollController table) =>
    MaterialApp(
      builder: (context, child) =>
          DrawerSwipeScope(notifier: prefs, child: child!),
      home: Builder(
        builder: (context) => Scaffold(
          drawerEnableOpenDragGesture: HermesDrawer.openDragEnabled(context),
          drawerEdgeDragWidth: HermesDrawer.edgeDragWidth(context),
          appBar: AppBar(title: const Text('screen')),
          drawer: const Drawer(child: Text('menu', key: _menuKey)),
          body: SingleChildScrollView(
            key: const ValueKey('wide-table'),
            controller: table,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < 30; i++)
                  SizedBox(width: 120, height: 400, child: Text('col $i')),
              ],
            ),
          ),
        ),
      ),
    );

bool _menuOpen(WidgetTester tester) =>
    tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen;

Future<void> _edgeSwipe(WidgetTester tester) async {
  // Inside the band (no system inset in tests + 48 dp), across the table.
  await tester.dragFrom(const Offset(8, 300), const Offset(300, 0));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    DrawerSwipePrefs.debugUse(null);
    DrawerGestureExclusion.resetForTesting();
  });

  group('preference', () {
    test('a new install starts off', () async {
      SharedPreferences.setMockInitialValues({});
      expect((await DrawerSwipePrefs.load()).enabled, isFalse);
    });

    test(
      'an update from a version without the setting starts off too',
      () async {
        // What 1.4.0 leaves behind: other settings, never this key. The edge
        // drag those versions always had is not carried over as a choice.
        SharedPreferences.setMockInitialValues({
          'haptics_enabled': true,
          'app_text_size_factor': 1.0,
        });
        expect((await DrawerSwipePrefs.load()).enabled, isFalse);
      },
    );

    test('an explicit choice is kept, on or off', () async {
      SharedPreferences.setMockInitialValues({DrawerSwipePrefs.key: true});
      expect((await DrawerSwipePrefs.load()).enabled, isTrue);
      SharedPreferences.setMockInitialValues({DrawerSwipePrefs.key: false});
      expect((await DrawerSwipePrefs.load()).enabled, isFalse);
    });

    test('turning it on persists across restarts', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await DrawerSwipePrefs.load();
      await store.setEnabled(true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(DrawerSwipePrefs.key), isTrue);
      expect((await DrawerSwipePrefs.load()).enabled, isTrue);
      await DrawerSwipePrefs.shared.setEnabled(false);
      expect(prefs.getBool(DrawerSwipePrefs.key), isFalse);
      expect((await DrawerSwipePrefs.load()).enabled, isFalse);
    });
  });

  group('menu on a screen built like the real ones', () {
    testWidgets('off: the edge drag scrolls the table and never opens the '
        'menu; the button opens it and it still closes', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await DrawerSwipePrefs.load();
      final table = ScrollController(initialScrollOffset: 600);
      addTearDown(table.dispose);
      await tester.pumpWidget(_syntheticScreen(prefs, table));

      await _edgeSwipe(tester);
      expect(_menuOpen(tester), isFalse);
      expect(find.byKey(_menuKey), findsNothing);
      expect(table.offset, lessThan(600), reason: 'the table took the drag');

      await tester.tap(find.byType(DrawerButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(_menuOpen(tester), isTrue);

      // Closing by dragging the open menu back still works.
      await tester.dragFrom(const Offset(200, 300), const Offset(-300, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(_menuOpen(tester), isFalse);
    });

    testWidgets('on: the edge drag opens the menu (opt-in)', (tester) async {
      SharedPreferences.setMockInitialValues({DrawerSwipePrefs.key: true});
      final prefs = await DrawerSwipePrefs.load();
      final table = ScrollController(initialScrollOffset: 600);
      addTearDown(table.dispose);
      await tester.pumpWidget(_syntheticScreen(prefs, table));

      await _edgeSwipe(tester);
      expect(_menuOpen(tester), isTrue);
    });

    testWidgets('a change applies at once, without a restart', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await DrawerSwipePrefs.load();
      final table = ScrollController(initialScrollOffset: 600);
      addTearDown(table.dispose);
      await tester.pumpWidget(_syntheticScreen(prefs, table));

      await prefs.setEnabled(true);
      await tester.pump();
      await _edgeSwipe(tester);
      expect(_menuOpen(tester), isTrue);

      tester.state<ScaffoldState>(find.byType(Scaffold).first).closeDrawer();
      await tester.pumpAndSettle();
      expect(_menuOpen(tester), isFalse);
      await prefs.setEnabled(false);
      await tester.pump();
      await _edgeSwipe(tester);
      expect(_menuOpen(tester), isFalse);
    });
  });

  group('Android Back-gesture exclusion', () {
    const channel = MethodChannel('hermes/system_gestures');
    final sent = <bool>[];

    setUp(() {
      sent.clear();
      DrawerGestureExclusion.resetForTesting();
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'setDrawerEdgeExclusion') {
              sent.add((call.arguments as Map)['enabled'] as bool);
            }
            return true;
          });
    });

    tearDown(() {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'off: a screen with the menu does not keep the edge from Back',
      () async {
        SharedPreferences.setMockInitialValues({});
        await DrawerSwipePrefs.load();
        await DrawerGestureExclusion.setEnabled(true);
        expect(sent, isNot(contains(true)));
      },
    );

    test(
      'the band follows the setting at once and only on menu screens',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await DrawerSwipePrefs.load();
        await DrawerGestureExclusion.setEnabled(true);
        sent.clear();

        await prefs.setEnabled(true);
        await pumpEventQueue();
        expect(sent, [true]);

        await DrawerGestureExclusion.setEnabled(false); // a screen without menu
        expect(sent, [true, false]);

        await prefs.setEnabled(false);
        await pumpEventQueue();
        await DrawerGestureExclusion.setEnabled(true); // back on a menu screen
        expect(sent.last, isFalse);
        expect(sent.where((value) => value), hasLength(1));
      },
    );
  });

  testWidgets('Look & Feel: the switch starts off and turns the setting on', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await DrawerSwipePrefs.load(prefs);
    final look = LookFeelPrefs(prefs);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: LookFeelScreen(prefsForTesting: look),
      ),
    );
    await tester.pump();
    final tile = find.byKey(const ValueKey('lfl-drawer-swipe'));
    await tester.scrollUntilVisible(tile, 200);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(find.text('Abrir el menú deslizando'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.tap(tile);
    await tester.pump();
    expect(DrawerSwipePrefs.shared.enabled, isTrue);
    expect(prefs.getBool(DrawerSwipePrefs.key), isTrue);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
  });

  group('the real Home', () {
    const secureChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );

    setUp(() {
      final secure = <String, String>{};
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureChannel, (call) async {
            final args = (call.arguments as Map?) ?? const {};
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
              case 'delete':
                secure.remove(args['key']);
              case 'readAll':
                return Map<String, String>.from(secure);
              case 'containsKey':
                return secure.containsKey(args['key']);
            }
            return null;
          });
    });

    tearDown(() {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureChannel, null);
    });

    testWidgets('off by default: no edge open, the header button opens the '
        'menu; turned on while Home is covered, the edge opens it after '
        'the way back', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final swipe = await DrawerSwipePrefs.load(prefs);
      final manager = (await tester.runAsync(
        () => ConnectionManager.create(prefs),
      ))!;
      await tester.runAsync(
        () => manager.saveConnection(
          'QA',
          '127.0.0.2',
          8642,
          'test-key',
          kind: InstanceKind.vps,
        ),
      );
      await tester.runAsync(
        () => manager.setActiveConnection(manager.getConnections().single.id),
      );
      final chats = ActiveChatService(
        attachDesktopRuntimeOnLoad: false,
        compressionRestoreStore: testCompressionRestoreStore(),
        coldStartStore: ColdStartStore(storage: MemoryColdStartStorage()),
      );
      final client = MockClient((request) async {
        if (request.url.path == '/api/status') {
          return http.Response('{"status":"ok"}', 200);
        }
        if (request.url.path == '/api/sessions') {
          return http.Response(jsonEncode({'sessions': [], 'total': 0}), 200);
        }
        return http.Response('{}', 404);
      });
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          locale: const Locale('en'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          builder: (context, child) =>
              DrawerSwipeScope(notifier: swipe, child: child!),
          home: HomeDashboardScreen(
            connManager: manager,
            activeChatsOverride: chats,
            clientFactory: (conn) =>
                testApiClient(baseUrl: conn.baseUrl, httpClient: client),
            dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final home = find.byWidgetPredicate(
        (widget) => widget is Scaffold && widget.drawer is HermesDrawer,
      );
      bool open() => tester.state<ScaffoldState>(home).isDrawerOpen;
      expect(
        tester.widget<Scaffold>(home).drawerEnableOpenDragGesture,
        isFalse,
      );

      await tester.dragFrom(const Offset(8, 400), const Offset(320, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(open(), isFalse, reason: 'off: the edge does not open the menu');

      await tester.tap(find.byType(DrawerButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(open(), isTrue, reason: 'the header button always opens it');
      tester.state<ScaffoldState>(home).closeDrawer();
      await tester.pump(const Duration(milliseconds: 600));
      expect(open(), isFalse);

      // Settings covers Home; the change must reach the covered route.
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('settings')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await swipe.setEnabled(true);
      await tester.pump();
      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(tester.widget<Scaffold>(home).drawerEnableOpenDragGesture, isTrue);
      await tester.dragFrom(const Offset(8, 400), const Offset(320, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(open(), isTrue, reason: 'on: the edge opens the menu');

      await tester.pumpWidget(const SizedBox.shrink());
      chats.dispose();
      await tester.pump(const Duration(seconds: 15));
    });
  });
}
