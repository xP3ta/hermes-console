import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/guide/guide_layer.dart';
import 'package:hermes_android/core/guide/guided_tour.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'botmode_parity_model_test.dart' show parityRoom;
import 'support/a11y_main_screen_harness.dart';
import 'support/design_shots.dart';
import 'support/in_memory_compression_restore_storage.dart';

GuideController get _g => GuideController.instance;
GestureDockController get _dock => GestureDockController.instance;

class _HomeClient extends ApiClient {
  _HomeClient()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<bool> healthReachable() => healthCheck();

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => const [];

  @override
  void close() {}
}

class _BotsSource implements MissionControlDataSource {
  final MissionBackendSnapshot snapshot;
  _BotsSource(List<AgentProfile> profiles)
    : snapshot = MissionBackendSnapshot(
        profiles: profiles,
        board: const KanbanBoard(columns: []),
        profilesCapability: MissionCapabilityState.available,
        sessionsCapability: MissionCapabilityState.available,
        kanbanCapability: MissionCapabilityState.available,
        hostedGroupsCapability: MissionCapabilityState.available,
        hostedGroups: HostedGroupsSnapshot(
          capabilities: GroupsCapabilities.tryParse(
            {
              'protocol_version': 2,
              'driver': true,
              'max_log_limit': 50,
              'methods': [
                'groups.capabilities',
                'groups.list',
                'groups.state',
                'groups.log',
              ],
            },
            connectionId: 'tour-bots',
            generation: 1,
          ),
          rooms: [parityRoom()],
          logs: const [],
        ),
        loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
      );
  @override
  Future<MissionBackendSnapshot> load() async => snapshot;
  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;
  @override
  void close() {}
}

Rect? _hole(WidgetTester tester) {
  final paint = find.byKey(const ValueKey('guide-spotlight'));
  if (paint.evaluate().isEmpty) return null;
  return (tester.widget<CustomPaint>(paint).painter! as GuideSpotlightPainter)
      .hole;
}

/// Walks the running tour to its end with Siguiente. On every step the
/// step's target is a real widget of the screen and the spotlight overlaps
/// it. Returns the ids of the steps shown, in order. [shot] renders each
/// step's first frame when design shots are on.
Future<List<String>> _walk(
  WidgetTester tester, {
  Future<void> Function(String id)? shot,
}) async {
  final shown = <String>[];
  for (var guard = 0; guard < 10 && _g.active; guard++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final step = _g.currentStep;
    expect(step, isNotNull, reason: 'tour ${_g.tour} shows no step');
    shown.add(step!.id);
    final hole = _hole(tester);
    expect(hole, isNotNull, reason: '${step.id}: no spotlight');
    final targets = find.byElementPredicate(
      (e) => step.matches(e.widget.key),
      description: 'targets of ${step.id}',
    );
    expect(targets, findsWidgets, reason: step.id);
    final rects = [
      for (final e in targets.evaluate())
        if (e.renderObject is RenderBox &&
            (e.renderObject! as RenderBox).hasSize)
          tester.getRect(find.byElementPredicate((x) => identical(x, e))),
    ];
    expect(
      rects.any((r) => r.overlaps(hole!)),
      isTrue,
      reason: '${step.id}: spotlight $hole is on none of $rects',
    );
    expect(find.byKey(const ValueKey('guide-card')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: step.id);
    if (shot != null) await shot(step.id);
    await tester.tap(find.byKey(const ValueKey('guide-next')));
  }
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 16));
  expect(_g.active, isFalse, reason: 'the tour never ended');
  expect(find.byKey(const ValueKey('guide-layer')), findsNothing);
  return shown;
}

/// Saves the whole view as `<name>.png` when design shots are on: the
/// app's own chat has no shot boundary of its own.
Future<void> _viewShot(WidgetTester tester, String name) async {
  final dir = Platform.environment['DESIGN_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  await tester.pump(const Duration(milliseconds: 400));
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final image = await layer.toImage(Offset.zero & view.size);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

/// The steps of [tour] whose target is in the tree right now.
List<String> _present(GuideTourId tour) => [
  for (final step in guideStepsFor(tour))
    if (find
        .byElementPredicate((e) => step.matches(e.widget.key))
        .evaluate()
        .isNotEmpty)
      step.id,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  // Design shots let the app's own start-up run for real (runAsync).
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          return call.method == 'readAll' ? <String, String>{} : null;
        });
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathChannel,
          (_) async => Directory.systemTemp.path,
        );
    _g.resetForTesting();
    _dock.resetForTesting();
    DockGeometry.instance.resetForTesting();
    FeatureFlags.instance.resetForTesting(gestureDock: true);
  });

  tearDown(() {
    _g.resetForTesting();
    _dock.resetForTesting(settings: const GestureDockSettings());
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
  });

  testWidgets('General on the real Home: no welcome offers it; started on '
      'purpose it runs end to end over the board, the server, the profile '
      'and the dock', (tester) async {
    await loadDesignFonts();
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
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
      globalActivity: GlobalActivityAggregate.inMemory(),
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(chats.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: designShotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('es'),
          theme: AppTheme.hermesRedDark,
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          builder: (context, child) => GuideLayer(child: child!),
          home: HomeDashboardScreen(
            connManager: manager,
            clientFactory: (_) => _HomeClient(),
            activeChatsOverride: chats,
            dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
            activeSessionListLoader: () async =>
                const DesktopActiveSessionList(),
            eventStreamOverride: const Stream.empty(),
            cronJobsLoader: (_, _) async => const [],
            missionSnapshotCacheOverride: MissionSnapshotCache(),
            rosterRegistryOverride: BotRosterRegistry(),
            botsOpenOverride: (_) {},
            serverInfoLoader: (_) async => (version: '0.12.3', update: false),
            limitsLoader: (_) async => null,
          ),
        ),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // No chats yet, first run: Home offers nothing by itself.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.byType(GuideCard), findsNothing);
    expect(_g.tour, isNull);
    final present = _present(GuideTourId.general);
    expect(
      present,
      containsAllInOrder(['home-board', 'home-server', 'home-dock']),
    );
    // Ajustes › Recorrido guiado.
    _g.start(GuideTourId.general);
    await tester.pump();
    expect(_g.tour, GuideTourId.general);
    final shown = await _walk(
      tester,
      shot: (id) async {
        if (id == 'home-board') {
          await saveDesignShot(tester, 'tour-general-dark');
        }
      },
    );
    expect(shown, present);
    expect(_g.isDone(GuideTourId.general), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Chat on the real chat screen of the app: header, composer, '
      'notch and status pill', (tester) async {
    await loadDesignFonts();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpA11yChat(tester, textScale: 1);
    // The status pill only rides under the composer where the chat shows
    // it: a step with no target is skipped, every other one is shown.
    final present = [
      for (final step in guideStepsFor(GuideTourId.chat))
        if (find
            .byElementPredicate((e) => step.matches(e.widget.key))
            .evaluate()
            .isNotEmpty)
          step.id,
    ];
    expect(
      present,
      containsAllInOrder(['chat-header', 'chat-composer', 'chat-notch']),
    );
    _g.start(GuideTourId.chat);
    await tester.pump();
    final shown = await _walk(
      tester,
      shot: (id) async {
        if (id == 'chat-composer') {
          await _viewShot(tester, 'tour-chat-dark');
        }
      },
    );
    expect(shown, present);
    expect(_g.isDone(GuideTourId.chat), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Bots on the real Bots home: pinned, team, rooms, create and '
      'the dock', (tester) async {
    await loadDesignFonts();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: designShotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('es'),
          theme: AppTheme.hermesRedDark,
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          builder: (context, child) => GuideLayer(child: child!),
          home: MissionControlScreen(
            connection: SavedConnection(
              id: 'tour-bots',
              label: 'Test',
              host: 'hermes.local',
              port: 8642,
              apiKey: 'k',
            ),
            connManager: manager,
            dataSource: _BotsSource([
              AgentProfile.fromJson({
                'name': 'default',
                'ui_meta': {
                  'hermes-bots': {'pinned': true},
                },
              }),
              const AgentProfile(name: 'forja'),
              const AgentProfile(name: 'astra'),
            ]),
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final present = _present(GuideTourId.bots);
    expect(
      present,
      containsAllInOrder(['bots-pinned', 'bots-team', 'bots-create']),
    );
    _g.start(GuideTourId.bots);
    await tester.pump();
    final shown = await _walk(
      tester,
      shot: (id) async {
        if (id == 'bots-pinned') await saveDesignShot(tester, 'tour-bots-dark');
      },
    );
    expect(shown, present);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
