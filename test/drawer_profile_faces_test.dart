import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/core/widgets/profile_face.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 1x1 transparent PNG: a real raster the avatar decoder accepts.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
    '60e6kgAAAABJRU5ErkJggg==';

AgentProfile _profile(
  String name, {
  bool isDefault = false,
  bool hasAvatar = false,
  Map<String, dynamic>? botMeta,
  double? workerLastActive,
}) => AgentProfile.fromJson({
  'name': name,
  'path': '/home/u/.hermes/profiles/$name',
  'is_default': isDefault,
  'has_avatar': hasAvatar,
  if (botMeta != null) 'ui_meta': {'hermes-bots': botMeta},
  if (workerLastActive != null)
    'worker_session': {
      'id': 'w-$name',
      'source': 'kanban',
      'title': 'job',
      'last_active': workerLastActive,
    },
});

http.Client _sessions() => MockClient((request) async {
  if (request.url.path == '/health') {
    return http.Response('{"status":"ok"}', 200);
  }
  return http.Response('{"data":[],"has_more":false}', 200);
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConnectionManager manager;
  late SavedConnection connection;
  late List<String> loads;

  Future<AgentProfileAvatar?> loader(String name) async {
    loads.add(name);
    return AgentProfileAvatar(
      mimeType: 'image/png',
      bytes: base64Decode(_png),
      width: 1,
      height: 1,
    );
  }

  setUp(() async {
    loads = [];
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
                return null;
              case 'delete':
                secure.remove(args['key']);
                return null;
              case 'readAll':
                return Map<String, String>.from(secure);
            }
            return null;
          },
        );
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.saveConnection(
      'QA',
      '127.0.0.2',
      8642,
      'test-key',
      kind: InstanceKind.vps,
    );
    connection = manager.getConnections().single;
    await manager.setActiveConnection(connection.id);
  });

  tearDown(() {
    BotRosterRegistry.shared.forget(connection.id);
    ProfileFace.debugResetAvatarCaches();
  });

  final now = DateTime.now().millisecondsSinceEpoch / 1000;

  // vozlive: a custom chibi image. ana: Desktop's PNG backfill of a
  // procedural face (shape metadata) -> the bot face, not the frozen PNG.
  // bob: no image at all -> the bot face. default: the main profile with
  // its own custom image.
  List<AgentProfile> roster({bool bobWorking = false}) => [
    _profile('default', isDefault: true, hasAvatar: true),
    _profile('vozlive', hasAvatar: true, botMeta: {'imageKind': 'photo'}),
    _profile('ana', hasAvatar: true, botMeta: {'shape': 'sun'}),
    _profile('bob', workerLastActive: bobWorking ? now : null),
  ];

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> openDrawer(
    WidgetTester tester, {
    required String active,
    String theme = 'dark',
    ValueListenable<bool>? locked,
    bool bobWorking = false,
  }) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await manager.setActiveProfile(connection.id, active);
    BotRosterRegistry.shared.publish(
      connection.id,
      'QA',
      roster(bobWorking: bobWorking),
    );
    final scaffoldKey = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId(theme),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          key: scaffoldKey,
          drawer: HermesDrawer(
            connection: connection,
            connManager: manager,
            current: DrawerSection.home,
            profileAvatarLoader: loader,
            profileFacesLocked: locked,
            recentSessionsClientFactory: (saved) => ApiClient(
              baseUrl: saved.baseUrl,
              apiKey: 'test-key',
              httpClient: _sessions(),
            ),
          ),
          body: const SizedBox.shrink(),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await settle(tester);
  }

  Finder inRow(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('profile-switcher-row')),
    matching: matching,
  );

  Finder inOption(String name, Finder matching) => find.descendant(
    of: find.byKey(ValueKey('profile-switcher-option-$name')),
    matching: matching,
  );

  Color? ringColor(WidgetTester tester, String name) {
    final box = tester.widget<DecoratedBox>(
      find.byKey(ValueKey('profile-face-ring-$name')),
    );
    final border = (box.decoration as BoxDecoration).border as Border?;
    return border?.top.color;
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('profile-switcher-row')));
    await settle(tester);
  }

  testWidgets('drawer row: a custom avatar is painted for the active profile, '
      'never the generic account icon', (tester) async {
    await openDrawer(tester, active: 'vozlive');
    expect(
      inRow(find.byKey(const ValueKey('profile-face-vozlive'))),
      findsOneWidget,
    );
    expect(inRow(find.byType(Image)), findsOneWidget);
    expect(loads, contains('vozlive'));
    expect(inRow(find.byIcon(Icons.account_circle_outlined)), findsNothing);
  });

  testWidgets('drawer row: the main profile shows its own custom image', (
    tester,
  ) async {
    await openDrawer(tester, active: '');
    expect(
      inRow(find.byKey(const ValueKey('profile-face-default'))),
      findsOneWidget,
    );
    expect(inRow(find.byType(Image)), findsOneWidget);
    expect(loads, contains('default'));
  });

  testWidgets('drawer row: without a custom image the bot\'s own face is '
      'painted; a Desktop shape backfill is not treated as a photo', (
    tester,
  ) async {
    await openDrawer(tester, active: 'ana');
    expect(inRow(find.byType(HermesBotFace)), findsOneWidget);
    expect(inRow(find.byType(Image)), findsNothing);
    expect(loads, isNot(contains('ana')));
    expect(inRow(find.byIcon(Icons.account_circle_outlined)), findsNothing);
  });

  testWidgets('drawer row: the active face wears an accent ring', (
    tester,
  ) async {
    await openDrawer(tester, active: 'bob');
    final accent = AppTheme.fromId('dark').hermes.accent;
    expect(ringColor(tester, 'bob'), accent);
  });

  testWidgets('switcher sheet: every profile shows its own face and only '
      'the active one is ringed', (tester) async {
    await openDrawer(tester, active: 'vozlive');
    await openSheet(tester);
    final accent = AppTheme.fromId('dark').hermes.accent;
    for (final name in ['default', 'vozlive', 'ana', 'bob']) {
      expect(
        inOption(name, find.byKey(ValueKey('profile-face-$name'))),
        findsOneWidget,
        reason: name,
      );
      expect(
        inOption(name, find.byIcon(Icons.account_circle_outlined)),
        findsNothing,
        reason: name,
      );
    }
    expect(inOption('default', find.byType(Image)), findsOneWidget);
    expect(inOption('vozlive', find.byType(Image)), findsOneWidget);
    expect(inOption('ana', find.byType(HermesBotFace)), findsOneWidget);
    expect(inOption('bob', find.byType(HermesBotFace)), findsOneWidget);
    expect(inOption('ana', find.byType(Image)), findsNothing);
    expect(inOption('bob', find.byType(Image)), findsNothing);
    final vozRing = find.descendant(
      of: find.byKey(const ValueKey('profile-switcher-option-vozlive')),
      matching: find.byKey(const ValueKey('profile-face-ring-vozlive')),
    );
    final vozBox = tester.widget<DecoratedBox>(vozRing);
    expect(
      ((vozBox.decoration as BoxDecoration).border as Border?)?.top.color,
      accent,
    );
    for (final name in ['default', 'ana', 'bob']) {
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(ValueKey('profile-switcher-option-$name')),
          matching: find.byKey(ValueKey('profile-face-ring-$name')),
        ),
      );
      final color =
          ((box.decoration as BoxDecoration).border as Border?)?.top.color;
      expect(color == null || color.a == 0, isTrue, reason: name);
    }
    // One avatar read per profile, shared by the row and the sheet.
    expect(loads.where((n) => n == 'vozlive'), hasLength(1));
  });

  testWidgets('a working profile shows a status dot but its face stays '
      'still: the drawer starts no animation ticker', (tester) async {
    await openDrawer(tester, active: 'bob', bobWorking: true);
    await openSheet(tester);
    expect(
      find.byKey(const ValueKey('profile-face-working-bob')),
      findsWidgets,
    );
    expect(
      find.byKey(const ValueKey('profile-face-working-ana')),
      findsNothing,
    );
    expect(find.byType(LivingBotFace), findsNothing);
    final faces = tester.widgetList<HermesBotFace>(find.byType(HermesBotFace));
    expect(faces, isNotEmpty);
    expect(faces.every((face) => !face.animate), isTrue);
    await settle(tester);
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('App Lock: nothing is read or decoded while locked; the '
      'custom faces appear after unlock', (tester) async {
    final locked = ValueNotifier<bool>(true);
    addTearDown(locked.dispose);
    await openDrawer(tester, active: 'vozlive', locked: locked);
    await openSheet(tester);
    expect(loads, isEmpty);
    expect(find.byType(Image), findsNothing);
    // Still a face while locked (the bot face), never the generic icon.
    expect(
      inRow(find.byKey(const ValueKey('profile-face-vozlive'))),
      findsOneWidget,
    );
    locked.value = false;
    await settle(tester);
    expect(loads, containsAll(['vozlive', 'default']));
    expect(inRow(find.byType(Image)), findsOneWidget);
  });
}
