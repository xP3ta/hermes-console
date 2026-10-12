import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/app_header_title.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/guide/guide_layer.dart';
import 'package:hermes_android/core/home/board/home_board_catalog.dart';
import 'package:hermes_android/core/home/board/home_board_kit.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/home/board/home_board_store.dart';
import 'package:hermes_android/core/home/board/home_board_tiles.dart';
import 'package:hermes_android/core/home/board/home_board_view.dart';
import 'package:hermes_android/core/home/home_feed_cache.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/session_live_status.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/screens/tools_hub_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/screens/lock_screen.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:hermes_android/core/shell/gesture_dock_host.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/core/widgets/profile_face.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/account_usage_fixtures.dart';
import '../support/in_memory_compression_restore_storage.dart';
import '../support/spec070_fixtures.dart';

final _clock = DateTime(2026, 10, 6, 16, 30);
double _ago(Duration d) => _clock.subtract(d).millisecondsSinceEpoch / 1000;

Session _session(
  String id,
  String title, {
  Duration ago = const Duration(days: 3),
  bool? unread,
  String preview = '',
}) => Session(
  id: id,
  title: title,
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 2,
  isActive: false,
  preview: preview,
  startedAt: _ago(ago),
  unread: unread,
);

class _HomeClient extends ApiClient {
  _HomeClient(
    this.sessions, {
    this.onHealth,
    this.hang = false,
    this.down = false,
  }) : super(
         baseUrl: 'http://127.0.0.1:8642',
         apiKey: 'k',
         httpClient: MockClient((_) async => http.Response('{}', 404)),
       );

  final List<Session> sessions;
  final VoidCallback? onHealth;

  /// The server never answers.
  final bool hang;

  /// The server cannot be reached.
  final bool down;

  @override
  Future<bool> healthCheck() {
    onHealth?.call();
    return hang ? Completer<bool>().future : Future.value(!down);
  }

  @override
  Future<bool> healthReachable() => healthCheck();

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => List.of(sessions);

  @override
  void close() {}
}

class _ApprovalApi extends ApiClient {
  _ApprovalApi()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  final List<(String runId, String choice, String? requestId)> answers = [];

  @override
  Future<Map<String, dynamic>> resolveRunApproval(
    String runId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
    String? profile,
  }) async {
    answers.add((runId, choice, requestId));
    return const {'ok': true};
  }
}

final class _Harness {
  final ConnectionManager manager;
  final SharedPreferences prefs;
  final ActiveChatService chats;
  final MissionSnapshotCache cache;
  final BotRosterRegistry roster;
  final List<MissionControlOpenTarget> opened = [];
  final List<(String roomId, String requestId, String choice)> roomAnswers = [];

  /// The cron list and Kanban board kept across Homes of one process.
  final HomeFeedCache feed;
  int limitReads = 0;
  int serverReads = 0;
  int cronReads = 0;
  int taskReads = 0;
  int healthChecks = 0;

  /// The cron and Kanban reads throw.
  bool failFeeds = false;

  /// The cron and Kanban reads wait for this.
  Completer<void>? holdReads;

  _Harness(
    this.manager,
    this.prefs,
    this.chats,
    this.cache,
    this.roster, {
    HomeFeedCache? feed,
  }) : feed = feed ?? HomeFeedCache();

  SavedConnection get connection => manager.getConnections().single;

  HomeBoardViewState board(WidgetTester tester) =>
      tester.state<HomeBoardViewState>(find.byType(HomeBoardView));

  Future<void> seed(HomeBoardLayout layout) => prefs.setString(
    HomeBoardStore.keyFor(connection.id, 'default'),
    layout.encode(),
  );

  /// A layout exactly as an earlier version wrote it.
  Future<void> seedRaw(List<Map<String, Object?>> items) => prefs.setString(
    HomeBoardStore.keyFor(connection.id, 'default'),
    jsonEncode({'v': 1, 'items': items}),
  );

  HomeBoardLayout? stored() {
    final raw = prefs.getString(
      HomeBoardStore.keyFor(connection.id, 'default'),
    );
    return raw == null ? null : HomeBoardLayout.decode(raw);
  }
}

HostedGroupsSnapshot _groups({bool withApproval = true}) =>
    HostedGroupsSnapshot(
      capabilities: spec070Capabilities(),
      rooms: [spec070Room()],
      logs: [
        HostedGroupLogPage.append(
          spec070LogPage('groups_log_page1'),
          spec070LogPage('groups_log_page2'),
        ),
      ],
      driverStatuses: {if (withApproval) 'room-devs': spec070DriverStatus()},
    );

AgentProfile _profile(
  String name, {
  bool isDefault = false,
  String? displayName,
}) => AgentProfile.fromJson({
  'name': name,
  'path': '/home/u/.hermes/profiles/$name',
  'is_default': isDefault,
  'display_name': ?displayName,
});

HomeWidgetInstance _w(
  String id,
  HomeWidgetKind kind, {
  HomeWidgetSize? size,
  Map<String, Object?> options = const {},
}) => HomeWidgetInstance(
  id: id,
  kind: kind,
  size: size ?? HomeWidgetCatalog.of(kind).defaultSize,
  options: options,
);

/// A Kanban board: two tasks running, three waiting, one done.
KanbanBoard _board() => KanbanBoard.fromJson({
  'columns': [
    {
      'name': 'running',
      'tasks': [
        {
          'id': 'k1',
          'title': 'Publicar 1.2.15',
          'status': 'running',
          'assignee': 'astra',
        },
        {
          'id': 'k2',
          'title': 'Rediseñar Inicio',
          'status': 'running',
          'assignee': 'radar',
        },
      ],
    },
    {
      'name': 'todo',
      'tasks': [
        {
          'id': 'k3',
          'title': 'Notas de la versión',
          'status': 'todo',
          'assignee': 'astra',
        },
        {'id': 'k4', 'title': 'Capturas para Google Play', 'status': 'todo'},
        {'id': 'k5', 'title': 'Traducir ajustes de voz', 'status': 'blocked'},
      ],
    },
    {
      'name': 'done',
      'tasks': [
        {'id': 'k6', 'title': 'Ya hecho', 'status': 'done'},
      ],
    },
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  /// A connection and everything Home reads from. A second harness in the
  /// same test is the same device again (same preferences, the same saved
  /// connection) in a new process: nothing read yet.
  Future<_Harness> harness(WidgetTester tester, {bool welcomed = true}) async {
    if (welcomed) {
      // The dock starts from its own defaults.
      GestureDockController.instance.resetForTesting(
        settings: const GestureDockSettings(),
      );
      addTearDown(GestureDockController.instance.resetForTesting);
    }
    final prefs = await SharedPreferences.getInstance();
    final manager = (await tester.runAsync(
      () => ConnectionManager.create(prefs),
    ))!;
    if (manager.getConnections().isEmpty) {
      await tester.runAsync(
        () => manager.saveConnection(
          'QA',
          '127.0.0.2',
          8642,
          'test-key',
          kind: InstanceKind.vps,
        ),
      );
    }
    await tester.runAsync(
      () => manager.setActiveConnection(manager.getConnections().single.id),
    );
    final chats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      globalActivity: GlobalActivityAggregate.inMemory(),
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(chats.dispose);
    return _Harness(
      manager,
      prefs,
      chats,
      MissionSnapshotCache(),
      BotRosterRegistry(),
    );
  }

  Future<void> pumpHome(
    WidgetTester tester,
    _Harness h, {
    List<Session> sessions = const [],
    List<CronJob>? cron,
    DesktopActiveSessionList? activeList,
    Size size = const Size(390, 844),
    double textScale = 1,
    bool reduceMotion = false,
    AppLockService? appLock,
    AccountUsageLimits? limits,
    KanbanBoard? tasks,
    DateTime Function()? clock,

    /// Frames pumped after the first one (0: only the first frame).
    int frames = 30,
    bool hangClient = false,

    /// The server cannot be reached: Home shows its «sin conexión» card.
    bool down = false,
  }) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('amber'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: HomeDashboardScreen(
          connManager: h.manager,
          clientFactory: (_) => _HomeClient(
            sessions,
            onHealth: () => h.healthChecks++,
            hang: hangClient,
            down: down,
          ),
          activeChatsOverride: h.chats,
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
          activeSessionListLoader: () async =>
              activeList ?? const DesktopActiveSessionList(),
          eventStreamOverride: const Stream.empty(),
          cronJobsLoader: (_, _) async {
            h.cronReads++;
            await h.holdReads?.future;
            if (h.failFeeds) throw StateError('cron');
            return cron ?? const [];
          },
          tasksLoader: (_) async {
            h.taskReads++;
            await h.holdReads?.future;
            if (h.failFeeds) throw StateError('kanban');
            return tasks ?? const KanbanBoard(columns: []);
          },
          feedCacheOverride: h.feed,
          missionSnapshotCacheOverride: h.cache,
          rosterRegistryOverride: h.roster,
          roomApproveOverride:
              (_, {required roomId, required action, required choice}) async {
                h.roomAnswers.add((roomId, action.requestId, choice));
              },
          botsOpenOverride: h.opened.add,
          clockOverride: clock ?? () => _clock,
          appLockOverride: appLock,
          serverInfoLoader: (_) async {
            h.serverReads++;
            return (version: '0.12.3', update: true);
          },
          limitsLoader: (_) async {
            h.limitReads++;
            return limits;
          },
        ),
      ),
    );
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Holds [tile] long enough to enter edit mode.
  Future<void> hold(WidgetTester tester, Finder tile) async {
    final g = await tester.startGesture(tester.getCenter(tile));
    await tester.pump(const Duration(milliseconds: 450));
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Edit mode wiggles until «Hecho», so no pumpAndSettle there.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  ActiveChat attachApproval(
    _Harness h,
    String sessionId,
    String title, {
    required _ApprovalApi api,
    List<String> choices = const ['once', 'session', 'deny'],
  }) {
    final chat = h.chats.attach(
      connection: h.connection,
      sessionId: sessionId,
      sessionTitle: title,
      sessionProfile: 'default',
      api: api,
      disableForegroundKeepAlive: true,
    );
    chat
      ..currentRunId = 'run-1'
      ..state = ChatPipelineState.executing
      ..pendingApproval = {
        'request_id': 'req-1',
        'command': 'git push origin fix/dock',
        'choices': choices,
      };
    return chat;
  }

  Finder tileOf(HomeWidgetKind kind) => find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith(
          'home-tile-${kind.name}-',
        ),
  );

  Finder tileById(String id) => find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('home-tile-') &&
        (w.key! as ValueKey<String>).value.endsWith('-$id'),
  );

  group('header and default board', () {
    testWidgets('keeps the instance header and the profile switcher; no '
        '«Inicio» title, no greeting', (tester) async {
      final h = await harness(tester);
      await pumpHome(tester, h);
      // («Inicio» is only the dock's tab label.)
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Inicio')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('home-board-list')),
          matching: find.text('Inicio'),
        ),
        findsNothing,
      );
      expect(find.textContaining('Buenas'), findsNothing);
      expect(find.textContaining('en línea'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-switcher-compact')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('profile-switcher-compact')),
          matching: find.byKey(const ValueKey('profile-face-default')),
        ),
        findsOneWidget,
        reason: 'the active profile shows its own face, not a person icon',
      );
      expect(find.byIcon(Icons.account_circle_outlined), findsNothing);
      // QA 9494: the face sits straight on the button's fill, no backing
      // squircle (it read as a dark square around the face).
      expect(
        tester
            .widget<Container>(
              find.byKey(const ValueKey('profile-switcher-avatar')),
            )
            .child,
        isA<ProfileFace>(),
      );
      await unmount(tester);
    });

    testWidgets('the profile switcher is a round avatar button at the right '
        'of the header, clear of the screen edge', (tester) async {
      final h = await harness(tester);
      await pumpHome(tester, h);
      final button = find.byKey(const ValueKey('profile-switcher-compact'));
      final avatar = find.byKey(const ValueKey('profile-switcher-avatar'));
      final target = tester.getRect(button);
      final ring = tester.getRect(avatar);
      // 44 dp to look at, 48 dp to tap.
      expect(ring.size, const Size(44, 44));
      expect(target.width, greaterThanOrEqualTo(48));
      expect(target.height, greaterThanOrEqualTo(48));
      // The face only: the status line already names the profile.
      expect(
        find.descendant(of: button, matching: find.byType(Text)),
        findsNothing,
      );
      final decoration =
          tester.widget<Container>(avatar).decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(
        (decoration.border! as Border).top.color,
        Theme.of(tester.element(button)).hermes.accent,
      );
      // The chevron badge sits on the ring's bottom-right edge, inside the
      // touch target.
      final chevron = tester.getRect(
        find.byKey(const ValueKey('profile-switcher-chevron')),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('profile-switcher-chevron')),
          matching: find.byIcon(Icons.expand_more_rounded),
        ),
        findsOneWidget,
      );
      expect(chevron.overlaps(ring), isTrue);
      expect(chevron.right, greaterThan(ring.right));
      expect(chevron.bottom, greaterThan(ring.bottom));
      expect(target.expandToInclude(chevron), target);
      // The same margin as the menu icon on the other side: never against
      // the screen edge.
      final menu = tester.getRect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(DrawerButtonIcon),
        ),
      );
      expect(390 - ring.right, 16);
      expect(menu.left, 16);
      await unmount(tester);
    });

    testWidgets('the avatar button is a button named after the active '
        'profile and opens the profile list', (tester) async {
      final h = await harness(tester);
      h.roster.publish(h.connection.id, 'QA', [
        _profile('default', isDefault: true, displayName: 'Hermes'),
        _profile('ana'),
      ]);
      await pumpHome(tester, h);
      final button = find.byKey(const ValueKey('profile-switcher-compact'));
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(button),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'Perfil: Hermes',
          hint: 'Cambiar de perfil',
        ),
      );
      semantics.dispose();
      await tester.tap(button);
      await settle(tester);
      expect(
        find.byKey(const ValueKey('profile-switcher-sheet')),
        findsOneWidget,
      );
      for (final name in const ['default', 'ana']) {
        expect(
          find.byKey(ValueKey('profile-switcher-option-$name')),
          findsOneWidget,
        );
      }
      await unmount(tester);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('320 dp at ${scale}x with a long profile name: the header '
          'does not overflow and the button keeps its place', (tester) async {
        final h = await harness(tester);
        const long = 'mesa-de-operaciones-europa-y-asia-turno-de-noche';
        h.roster.publish(h.connection.id, 'QA', [
          _profile('default', isDefault: true),
          _profile(long),
        ]);
        await tester.runAsync(
          () => h.manager.setActiveProfile(h.connection.id, long),
        );
        await pumpHome(tester, h, size: const Size(320, 640), textScale: scale);
        expect(tester.takeException(), isNull);
        final button = find.byKey(const ValueKey('profile-switcher-compact'));
        final target = tester.getRect(button);
        final ring = tester.getRect(
          find.byKey(const ValueKey('profile-switcher-avatar')),
        );
        expect(ring.size, const Size(44, 44));
        expect(target.width, greaterThanOrEqualTo(48));
        expect(target.height, greaterThanOrEqualTo(48));
        expect(320 - ring.right, 16);
        // The status line names the profile and is cut before the button.
        final status = find.descendant(
          of: find.byType(AppBar),
          matching: find.textContaining(long),
        );
        expect(status, findsOneWidget);
        expect(tester.getRect(status).right, lessThanOrEqualTo(target.left));
        expect(
          tester.getRect(find.byKey(const ValueKey('home-header-title'))).right,
          lessThanOrEqualTo(target.left),
        );
        await unmount(tester);
      });
    }

    testWidgets('a long profile name is still listed by the sheet the button '
        'opens', (tester) async {
      final h = await harness(tester);
      const long = 'mesa-de-operaciones-europa-y-asia-turno-de-noche';
      h.roster.publish(h.connection.id, 'QA', [
        _profile('default', isDefault: true),
        _profile(long),
      ]);
      await tester.runAsync(
        () => h.manager.setActiveProfile(h.connection.id, long),
      );
      await pumpHome(tester, h, size: const Size(320, 640));
      await tester.tap(find.byKey(const ValueKey('profile-switcher-compact')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('profile-switcher-option-$long')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    testWidgets('with a single profile the button stays, as the pill did, '
        'and lists it', (tester) async {
      final h = await harness(tester);
      h.roster.publish(h.connection.id, 'QA', [
        _profile('default', isDefault: true),
      ]);
      await pumpHome(tester, h);
      final button = find.byKey(const ValueKey('profile-switcher-compact'));
      expect(button, findsOneWidget);
      await tester.tap(button);
      await settle(tester);
      expect(
        find.byKey(const ValueKey('profile-switcher-sheet')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-switcher-option-default')),
        findsOneWidget,
      );
      await unmount(tester);
    });

    testWidgets('the status line has no chevron of its own and still opens '
        'the instance status', (tester) async {
      final h = await harness(tester);
      await pumpHome(tester, h);
      final title = find.byKey(const ValueKey('home-header-title'));
      final block = find
          .ancestor(of: title, matching: find.byType(GestureDetector))
          .first;
      expect(
        find.descendant(of: block, matching: find.textContaining('en línea')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: block, matching: find.byType(Icon)),
        findsNothing,
      );
      await tester.tap(title);
      await settle(tester);
      expect(
        find.byKey(const ValueKey('instance-status-surface')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-switcher-sheet')),
        findsNothing,
      );
      await unmount(tester);
    });

    testWidgets('the profile switcher lists every profile with its face', (
      tester,
    ) async {
      final h = await harness(tester);
      h.roster.publish(h.connection.id, 'QA', spec070Profiles());
      await pumpHome(tester, h);
      await tester.tap(find.byKey(const ValueKey('profile-switcher-compact')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('profile-switcher-sheet')),
        findsOneWidget,
      );
      for (final name in const ['default', 'astra', 'radar']) {
        final row = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'profile-switcher-option-',
              ) &&
              find
                  .descendant(
                    of: find.byWidget(w),
                    matching: find.byKey(ValueKey('profile-face-$name')),
                  )
                  .evaluate()
                  .isNotEmpty,
        );
        expect(row, findsOneWidget, reason: '$name row shows its face');
        expect(
          find.descendant(
            of: row,
            matching: find.byKey(ValueKey('profile-face-$name')),
          ),
          findsOneWidget,
          reason: '$name is listed with its own face',
        );
      }
      expect(find.byIcon(Icons.account_circle_outlined), findsNothing);
      await unmount(tester);
    });

    test('the recent chats widget is «Chats» and the bots widget is «Bots», '
        'in both languages; what is stored keeps its name', () {
      for (final locale in const [Locale('es'), Locale('en')]) {
        final s = lookupStrings(locale);
        expect(homeWidgetName(s, HomeWidgetKind.continueChats), 'Chats');
        expect(homeWidgetName(s, HomeWidgetKind.team), 'Bots');
      }
      expect(
        _w('c', HomeWidgetKind.continueChats).toJson()['kind'],
        'continueChats',
      );
      expect(_w('t', HomeWidgetKind.team).toJson()['kind'], 'team');
    });

    testWidgets('the board titles them «Chats» and «Bots», also for a '
        'screen reader', (tester) async {
      final h = await harness(tester);
      await h.seed(
        HomeBoardLayout([
          _w('c', HomeWidgetKind.continueChats, size: HomeWidgetSize.wide),
          _w('t', HomeWidgetKind.team, size: HomeWidgetSize.wide),
        ]),
      );
      await pumpHome(tester, h);
      final semantics = tester.ensureSemantics();
      for (final (kind, name) in const [
        (HomeWidgetKind.continueChats, 'Chats'),
        (HomeWidgetKind.team, 'Bots'),
      ]) {
        expect(
          find.descendant(of: tileOf(kind), matching: find.text(name)),
          findsOneWidget,
        );
        expect(tester.getSemantics(tileOf(kind)).label, startsWith(name));
      }
      semantics.dispose();
      expect(find.text('Continuar'), findsNothing);
      expect(find.text('Equipo'), findsNothing);
      await unmount(tester);
    });

    testWidgets('an idle Home keeps its faces alive on one idle timer, no '
        'vsync ticker; covered, no timer', (tester) async {
      debugLivingBotFacesStill = false;
      addTearDown(() => debugLivingBotFacesStill = true);
      final h = await harness(tester);
      h.roster.publish(h.connection.id, 'QA', spec070Profiles());
      await pumpHome(tester, h, sessions: [_session('a', 'Plan de la semana')]);
      expect(find.byKey(const ValueKey('home-face-astra')), findsWidgets);
      await tester.pump(const Duration(seconds: 1));
      expect(livingBotFaceActiveTickers, 0);
      expect(livingBotFaceIdleFaces, greaterThan(0));
      expect(livingBotFaceClockTimers, 1);
      expect(tester.binding.transientCallbackCount, 0);
      await unmount(tester);
      expect(livingBotFaceClockTimers, 0);
    });
  });

  group('default board', () {
    testWidgets('one agent: Ahora wide, Chats large, then Cron beside '
        'Tareas; calm', (tester) async {
      final h = await harness(tester);
      await pumpHome(tester, h);
      final now = tester.getRect(tileOf(HomeWidgetKind.now));
      final chats = tester.getRect(tileOf(HomeWidgetKind.continueChats));
      final cron = tester.getRect(tileOf(HomeWidgetKind.cron));
      final tasks = tester.getRect(tileOf(HomeWidgetKind.tasks));
      expect(now.top, lessThan(chats.top));
      expect(chats.top, lessThan(cron.top));
      expect(cron.top, tasks.top);
      expect(cron.left, lessThan(tasks.left));
      expect(now.width, chats.width);
      expect(chats.height, greaterThan(now.height * 2));
      expect(cron.width, lessThan(now.width / 2));
      expect(tileOf(HomeWidgetKind.team), findsNothing);
      expect(tileOf(HomeWidgetKind.room), findsNothing);
      expect(find.byKey(const ValueKey('home-now-calm')), findsOneWidget);
      expect(find.text('Todo tranquilo'), findsOneWidget);
      // Nothing is stored for a board nobody arranged.
      expect(h.stored(), isNull);
      expect(h.board(tester).geometry!.plan.full, isTrue);
      await unmount(tester);
    });

    testWidgets('with bots: Ahora wide, Bots large, then Salas beside Cron; '
        'the next launch starts on it', (tester) async {
      final h = await harness(tester);
      h.roster.publish(h.connection.id, 'QA', spec070Profiles());
      await pumpHome(tester, h);
      final now = tester.getRect(tileOf(HomeWidgetKind.now));
      final bots = tester.getRect(tileOf(HomeWidgetKind.team));
      final rooms = tester.getRect(tileOf(HomeWidgetKind.room));
      final cron = tester.getRect(tileOf(HomeWidgetKind.cron));
      expect(now.top, lessThan(bots.top));
      expect(bots.top, lessThan(rooms.top));
      expect(rooms.top, cron.top);
      expect(rooms.left, lessThan(cron.left));
      expect(bots.height, greaterThan(now.height * 2));
      expect(tileOf(HomeWidgetKind.continueChats), findsNothing);
      expect(tileOf(HomeWidgetKind.tasks), findsNothing);
      expect(h.stored(), isNull);
      expect(
        h.prefs.getBool(HomeBoardStore.teamKeyFor(h.connection.id, 'default')),
        isTrue,
      );
      await unmount(tester);

      // A new process: no roster yet, and the first frame is that board.
      final again = _Harness(
        h.manager,
        h.prefs,
        h.chats,
        MissionSnapshotCache(),
        BotRosterRegistry(),
      );
      await pumpHome(tester, again, frames: 0);
      expect(tileOf(HomeWidgetKind.team), findsOneWidget);
      expect(tileOf(HomeWidgetKind.room), findsOneWidget);
      expect(tileOf(HomeWidgetKind.continueChats), findsNothing);
      await unmount(tester);
    });

    testWidgets('one agent that gets its first bot moves to the bots board; '
        'a board the user arranged never moves', (tester) async {
      final h = await harness(tester);
      await pumpHome(tester, h);
      expect(tileOf(HomeWidgetKind.continueChats), findsOneWidget);
      h.roster.publish(h.connection.id, 'QA', spec070Profiles());
      await settle(tester);
      expect(tileOf(HomeWidgetKind.team), findsOneWidget);
      expect(tileOf(HomeWidgetKind.continueChats), findsNothing);
      await unmount(tester);

      final own = await harness(tester);
      await own.seed(
        HomeBoardLayout([
          _w('s', HomeWidgetKind.server),
          _w('n', HomeWidgetKind.now),
        ]),
      );
      own.roster.publish(own.connection.id, 'QA', spec070Profiles());
      await pumpHome(tester, own);
      expect(tileOf(HomeWidgetKind.server), findsOneWidget);
      expect(tileOf(HomeWidgetKind.team), findsNothing);
      expect(own.stored()!.items.map((i) => i.id), ['s', 'n']);
      await unmount(tester);
    });

    testWidgets('the former default, stored untouched, follows the new '
        'default', (tester) async {
      final h = await harness(tester);
      await h.seedRaw([
        {'id': 'w1', 'kind': 'glance', 'size': 'wide'},
        {'id': 'w2', 'kind': 'continueChats', 'size': 'wide'},
        {'id': 'w3', 'kind': 'team', 'size': 'wide'},
        {'id': 'w4', 'kind': 'nextAutomation', 'size': 'small'},
        {'id': 'w5', 'kind': 'today', 'size': 'small'},
      ]);
      await pumpHome(tester, h);
      expect(tileOf(HomeWidgetKind.now), findsOneWidget);
      expect(tileOf(HomeWidgetKind.continueChats), findsOneWidget);
      expect(tileOf(HomeWidgetKind.cron), findsOneWidget);
      expect(tileOf(HomeWidgetKind.tasks), findsOneWidget);
      expect(tileOf(HomeWidgetKind.today), findsNothing);
      expect(
        tester.getSize(tileOf(HomeWidgetKind.continueChats)).height,
        greaterThan(tester.getSize(tileOf(HomeWidgetKind.now)).height * 2),
      );
      await unmount(tester);
    });

    testWidgets('a board the user arranged before is kept, its retired '
        'widgets as their successors in place', (tester) async {
      final h = await harness(tester);
      await h.seedRaw([
        {'id': 'c', 'kind': 'continueChats', 'size': 'small'},
        {
          'id': 'p',
          'kind': 'nextAutomation',
          'size': 'small',
          'options': {'job': 'j2'},
        },
        {'id': 'g', 'kind': 'glance', 'size': 'wide'},
        {'id': 'n', 'kind': 'needsYou', 'size': 'wide'},
        {'id': 'a', 'kind': 'automations', 'size': 'wide'},
      ]);
      await pumpHome(
        tester,
        h,
        cron: [
          CronJob.fromJson({
            'id': 'j1',
            'name': 'Backup',
            'next_run_at': _clock
                .add(const Duration(hours: 1))
                .toIso8601String(),
          }),
          CronJob.fromJson({
            'id': 'j2',
            'name': 'Informe semanal',
            'next_run_at': _clock
                .add(const Duration(hours: 3))
                .toIso8601String(),
          }),
        ],
      );
      expect(
        [
          for (final item in h.board(tester).geometry!.plan.placed)
            (item.id, item.kind, item.size),
        ],
        [
          ('c', HomeWidgetKind.continueChats, HomeWidgetSize.small),
          ('p', HomeWidgetKind.cron, HomeWidgetSize.small),
          ('g', HomeWidgetKind.now, HomeWidgetSize.wide),
          ('a', HomeWidgetKind.cron, HomeWidgetSize.wide),
        ],
      );
      // The fixed job stays fixed; the list widget lists by next run.
      expect(
        find.descendant(
          of: tileById('p'),
          matching: find.text('Informe semanal'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tileById('a'), matching: find.text('Backup')),
        findsOneWidget,
      );
      expect(find.text('Lo siguiente'), findsNothing);
      expect(find.text('Te necesita'), findsNothing);
      await unmount(tester);
    });

    testWidgets('a corrupt stored layout falls back to the default board', (
      tester,
    ) async {
      final h = await harness(tester);
      await h.prefs.setString(
        HomeBoardStore.keyFor(h.connection.id, 'default'),
        '{"v": 1, "items": 7',
      );
      await pumpHome(tester, h);
      expect(tileOf(HomeWidgetKind.now), findsOneWidget);
      expect(tileOf(HomeWidgetKind.continueChats), findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  });

  group('the grid never scrolls', () {
    final rich = [
      _session(
        'w1',
        'Revisar la PR del login',
        ago: const Duration(minutes: 2),
      ),
      _session('u1', 'PR revisada', unread: true, preview: 'Sin bloqueos.'),
      _session('n1', 'Notas de la reunión'),
      _session('n2', 'Viaje a Lisboa'),
      _session('n3', 'Plan de la semana'),
      _session('n4', 'Presupuesto'),
    ];
    final jobs = [
      CronJob.fromJson({
        'id': 'j1',
        'name': 'Copia de seguridad',
        'last_status': 'error',
        'next_run_at': _clock.add(const Duration(hours: 5)).toIso8601String(),
      }),
      CronJob.fromJson({
        'id': 'j2',
        'name': 'Resumen diario',
        'last_status': 'ok',
        'next_run_at': _clock.add(const Duration(hours: 9)).toIso8601String(),
      }),
    ];
    final boards = <String, HomeBoardLayout?>{
      'the default': null,
      'a full board': HomeBoardLayout([
        _w('now', HomeWidgetKind.now, size: HomeWidgetSize.wide),
        _w('chats', HomeWidgetKind.continueChats, size: HomeWidgetSize.wide),
        _w('bots', HomeWidgetKind.team, size: HomeWidgetSize.wide),
        _w('cron', HomeWidgetKind.cron, size: HomeWidgetSize.small),
        _w('tasks', HomeWidgetKind.tasks, size: HomeWidgetSize.small),
      ]),
      'more than fits': HomeBoardLayout([
        _w('now', HomeWidgetKind.now, size: HomeWidgetSize.large),
        _w('chats', HomeWidgetKind.continueChats, size: HomeWidgetSize.large),
        _w('bots', HomeWidgetKind.team, size: HomeWidgetSize.large),
        _w('rooms', HomeWidgetKind.room, size: HomeWidgetSize.large),
        _w('cron', HomeWidgetKind.cron, size: HomeWidgetSize.large),
        _w('tasks', HomeWidgetKind.tasks, size: HomeWidgetSize.large),
        _w('today', HomeWidgetKind.today, size: HomeWidgetSize.wide),
        _w('server', HomeWidgetKind.server, size: HomeWidgetSize.small),
        _w('limits', HomeWidgetKind.planLimits, size: HomeWidgetSize.large),
      ]),
    };

    for (final (size, rows) in const [
      (Size(360, 640), 3),
      (Size(390, 844), 4),
      (Size(412, 915), 4),
    ]) {
      for (final scale in [1.0, 2.0]) {
        for (final gestureDock in [true, false]) {
          testWidgets('${size.width.round()}×${size.height.round()} at '
              '${scale}x, ${gestureDock ? 'gesture' : 'classic'} dock: $rows '
              'whole rows between the header and the dock, nothing to '
              'scroll, no overflow', (tester) async {
            FeatureFlags.instance.resetForTesting(gestureDock: gestureDock);
            addTearDown(FeatureFlags.instance.resetToDefaultForTesting);
            GestureDockController.instance.resetForTesting(
              settings: const GestureDockSettings(),
            );
            addTearDown(GestureDockController.instance.resetForTesting);
            for (final MapEntry(key: name, value: layout) in boards.entries) {
              final h = await harness(tester);
              if (layout != null) await h.seed(layout);
              h.roster.publish(h.connection.id, 'QA', spec070Profiles());
              h.cache.write(
                h.connection,
                MissionBackendSnapshot(
                  hostedGroups: _groups(withApproval: false),
                  loadedAt: _clock,
                ),
              );
              attachApproval(
                h,
                'w1',
                'Revisar la PR del login',
                api: _ApprovalApi(),
              );
              await pumpHome(
                tester,
                h,
                size: size,
                textScale: scale,
                sessions: rich,
                cron: jobs,
                tasks: _board(),
              );
              expect(tester.takeException(), isNull, reason: name);
              final geometry = h.board(tester).geometry!;
              expect(geometry.plan.rows, rows, reason: name);
              expect(
                geometry.rowHeight,
                greaterThanOrEqualTo(HomeBoardGridRule.minRowHeight),
              );
              final list = find.byKey(const ValueKey('home-board-list'));
              final position = tester
                  .widget<SingleChildScrollView>(list)
                  .controller!
                  .position;
              expect(position.maxScrollExtent, 0, reason: name);
              // Every widget sits whole between the header and the dock.
              final top = tester.getRect(find.byType(HermesAppBar)).bottom;
              final bottom = gestureDock
                  ? tester
                        .getRect(find.byKey(const ValueKey('gesture-dock')))
                        .top
                  : size.height - 66;
              final tiles = find.byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith('home-tile-'),
              );
              expect(tiles, findsWidgets, reason: name);
              expect(
                tiles.evaluate().length,
                geometry.plan.placed.length,
                reason: name,
              );
              final rects = [
                for (final e in tiles.evaluate())
                  tester.getRect(find.byWidget(e.widget)),
              ];
              for (final rect in rects) {
                expect(rect.top, greaterThanOrEqualTo(top), reason: name);
                expect(rect.bottom, lessThanOrEqualTo(bottom), reason: name);
                expect(rect.left, greaterThanOrEqualTo(0), reason: name);
                expect(rect.right, lessThanOrEqualTo(size.width), reason: name);
              }
              // Pushing the board does not move it.
              await tester.drag(list, const Offset(0, -260));
              await tester.pump(const Duration(milliseconds: 400));
              expect(position.pixels, 0, reason: name);
              expect(
                [
                  for (final e in tiles.evaluate())
                    tester.getRect(find.byWidget(e.widget)),
                ],
                rects,
                reason: name,
              );
              expect(tester.takeException(), isNull, reason: name);
              h.chats.dispose();
              await unmount(tester);
            }
          });
        }
      }
    }

    testWidgets('a taller phone gets a fifth row; a short one keeps whole '
        'rows only', (tester) async {
      for (final (size, rows) in const [
        (Size(412, 1000), 5),
        (Size(360, 520), 2),
        (Size(800, 360), 1),
      ]) {
        final h = await harness(tester);
        await pumpHome(tester, h, size: size);
        final geometry = h.board(tester).geometry!;
        expect(geometry.plan.rows, rows, reason: '$size');
        expect(geometry.plan.capacity, rows * 2);
        expect(tester.takeException(), isNull, reason: '$size');
        await unmount(tester);
      }
    });

    testWidgets('a banner takes its height from the grid, not from the '
        'page: under the «sin conexión» card the rows tighten and the '
        'widgets stay', (tester) async {
      FeatureFlags.instance.resetForTesting(gestureDock: true);
      addTearDown(FeatureFlags.instance.resetToDefaultForTesting);
      for (final (size, open) in const [
        (Size(390, 844), 4),
        (Size(360, 640), 3),
      ]) {
        final h = await harness(tester);
        await pumpHome(tester, h, size: size, down: true);
        // The widgets glide to their rows.
        await settle(tester);
        final card = find
            .ancestor(
              of: find.byKey(const ValueKey('home-offline-retry')),
              matching: find.byType(Material),
            )
            .first;
        expect(card, findsOneWidget);
        final position = tester
            .widget<SingleChildScrollView>(
              find.byKey(const ValueKey('home-board-list')),
            )
            .controller!
            .position;
        expect(position.maxScrollExtent, 0);
        final geometry = h.board(tester).geometry!;
        final banner = tester.getRect(card);
        final reason =
            '$size banner ${banner.height} row ${geometry.rowHeight}';
        if (open == 4) {
          // A regular phone keeps its four rows, each a little shorter,
          // and everything on the board.
          expect(geometry.plan.rows, 4, reason: reason);
          expect(geometry.plan.hidden, isEmpty, reason: reason);
          expect(geometry.plan.shrunk, isFalse, reason: reason);
          expect(geometry.rowHeight, lessThan(152), reason: reason);
        } else {
          // A short phone has less to give: its three rows, or two.
          expect(geometry.plan.rows, inInclusiveRange(2, 3), reason: reason);
        }
        // Whole rows, none thinner than a row may get.
        expect(
          geometry.rowHeight,
          greaterThanOrEqualTo(HomeBoardGridRule.tightRowHeight),
          reason: reason,
        );
        expect(geometry.plan.placed, isNotEmpty, reason: reason);
        final dock = tester.getRect(find.byKey(const ValueKey('gesture-dock')));
        for (final item in geometry.plan.placed) {
          final rect = tester.getRect(tileById(item.id));
          expect(rect.top, greaterThanOrEqualTo(banner.bottom), reason: reason);
          expect(rect.bottom, lessThanOrEqualTo(dock.top), reason: reason);
        }
        expect(tester.takeException(), isNull, reason: reason);
        h.chats.dispose();
        await unmount(tester);
      }
    });

    testWidgets('a keyboard over Home moves nothing on the board', (
      tester,
    ) async {
      final h = await harness(tester);
      await pumpHome(tester, h);
      final before = h.board(tester).geometry!;
      Rect tile(String id) => tester.getRect(tileById(id));
      final ids = [for (final item in before.plan.placed) item.id];
      final rects = [for (final id in ids) tile(id)];
      addTearDown(tester.view.resetViewInsets);
      // The keyboard on its way up, open, and gone.
      for (final inset in [90.0, 210.0, 336.0, 336.0, 120.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset * 3);
        await tester.pump(const Duration(milliseconds: 16));
        final geometry = h.board(tester).geometry!;
        expect(geometry.plan.rows, before.plan.rows, reason: '$inset');
        expect(geometry.rowHeight, before.rowHeight, reason: '$inset');
        expect([for (final id in ids) tile(id)], rects, reason: '$inset');
      }
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    testWidgets('pulling down still refreshes', (tester) async {
      final h = await harness(tester);
      await pumpHome(tester, h);
      final before = h.healthChecks;
      await tester.fling(
        find.byKey(const ValueKey('home-board-list')),
        const Offset(0, 320),
        900,
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(h.healthChecks, greaterThan(before));
      await unmount(tester);
    });

    testWidgets('a layout that no longer fits keeps its order: what has no '
        'room at its size is shown smaller, the rest waits in edit mode, '
        'and nothing is deleted', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await harness(tester);
      final layout = HomeBoardLayout([
        _w('now', HomeWidgetKind.now, size: HomeWidgetSize.wide),
        _w('bots', HomeWidgetKind.team, size: HomeWidgetSize.large),
        _w('chats', HomeWidgetKind.continueChats, size: HomeWidgetSize.large),
        _w('cron', HomeWidgetKind.cron, size: HomeWidgetSize.small),
        _w('rooms', HomeWidgetKind.room, size: HomeWidgetSize.wide),
        _w('tasks', HomeWidgetKind.tasks, size: HomeWidgetSize.small),
      ]);
      await h.seed(layout);
      await pumpHome(tester, h);
      var plan = h.board(tester).geometry!.plan;
      expect(plan.placed.map((i) => i.id), ['now', 'bots', 'chats']);
      expect(plan.hidden.map((i) => i.id), ['cron', 'rooms', 'tasks']);
      // Chats, stored large, takes the one row that is left.
      expect(plan.shownSize('chats'), HomeWidgetSize.wide);
      expect(
        tester.getSize(tileById('chats')).height,
        closeTo(tester.getSize(tileById('now')).height, 0.5),
      );
      expect(tileById('cron'), findsNothing);
      expect(tileById('rooms'), findsNothing);
      expect(h.stored()!.encode(), layout.encode());

      await hold(tester, tileById('now'));
      expect(find.text('Inicio lleno · +3'), findsOneWidget);
      // Its size control shows the size it has now; its own is off.
      await tester.tap(find.byKey(const ValueKey('home-resize-chats')));
      await settle(tester);
      for (final (size, enabled, selected) in const [
        ('small', true, false),
        ('wide', true, true),
        ('large', false, false),
      ]) {
        expect(
          tester.getSemantics(find.byKey(ValueKey('home-size-chats-$size'))),
          isSemantics(
            isButton: true,
            hasEnabledState: true,
            isEnabled: enabled,
            hasSelectedState: true,
            isSelected: selected,
          ),
          reason: size,
        );
      }
      await tester.tap(
        find.byKey(const ValueKey('home-size-dismiss')),
        warnIfMissed: false,
      );
      await settle(tester);
      expect(h.stored()!.encode(), layout.encode());

      await tester.tap(find.byKey(const ValueKey('home-edit-meter')));
      await settle(tester);
      expect(find.byKey(const ValueKey('home-hidden')), findsOneWidget);
      for (final id in ['cron', 'rooms', 'tasks']) {
        expect(find.byKey(ValueKey('home-hidden-$id')), findsOneWidget);
      }
      // The board is full: no size brings one back yet.
      await tester.tap(find.byKey(const ValueKey('home-hidden-rooms-small')));
      await settle(tester);
      expect(h.stored()!.encode(), layout.encode());
      // One can be let go from here.
      await tester.tap(find.byKey(const ValueKey('home-hidden-remove-rooms')));
      await settle(tester);
      expect(h.stored()!.items.map((i) => i.id), [
        'now',
        'bots',
        'chats',
        'cron',
        'tasks',
      ]);
      expect(find.byKey(const ValueKey('home-hidden-cron')), findsOneWidget);
      Navigator.of(
        tester.element(find.byKey(const ValueKey('home-hidden'))),
      ).pop();
      await settle(tester);

      // Room made on the board: Chats is large again and the ones that
      // waited are back, in their place.
      await tester.tap(find.byKey(const ValueKey('home-remove-bots')));
      await settle(tester);
      plan = h.board(tester).geometry!.plan;
      expect(plan.placed.map((i) => i.id), ['now', 'chats', 'cron', 'tasks']);
      expect(plan.hidden, isEmpty);
      expect(plan.shrunk, isFalse);
      expect(tileById('cron'), findsOneWidget);
      expect(find.text('Inicio lleno'), findsOneWidget);
      semantics.dispose();
      await unmount(tester);
    });
  });

  group('Ahora answers from Home', () {
    const key = 'approval:chat:s-approve:req-1';

    testWidgets('an approval marks the card, shows the command and answers '
        'through the chat itself; Home is calm again', (tester) async {
      final h = await harness(tester);
      final api = _ApprovalApi();
      final chat = attachApproval(h, 's-approve', 'Despliegue', api: api);
      await pumpHome(
        tester,
        h,
        sessions: [_session('s-approve', 'Despliegue')],
      );
      expect(find.byKey(const ValueKey('home-now-ask-$key')), findsOneWidget);
      expect(find.text('git push origin fix/dock'), findsOneWidget);
      expect(
        tester
            .widget<HomeCard>(
              find.descendant(
                of: tileOf(HomeWidgetKind.now),
                matching: find.byType(HomeCard),
              ),
            )
            .hero,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('home-now-allow-$key')));
      await settle(tester);
      expect(api.answers, [('run-1', 'once', 'req-1')]);
      expect(chat.pendingApproval, isNull);
      expect(find.byKey(const ValueKey('home-now-ask-$key')), findsNothing);
      expect(find.text('git push origin fix/dock'), findsNothing);
      h.chats.dispose();
      await unmount(tester);
    });

    testWidgets('Rechazar denies the exact request and never asks App Lock', (
      tester,
    ) async {
      final h = await harness(tester);
      await h.prefs.setBool('app_lock_enabled', true);
      final lock = AppLockService(h.prefs)..locked.value = false;
      final api = _ApprovalApi();
      attachApproval(h, 's-approve', 'Despliegue', api: api);
      await pumpHome(
        tester,
        h,
        appLock: lock,
        sessions: [_session('s-approve', 'Despliegue')],
      );
      await tester.tap(find.byKey(const ValueKey('home-now-deny-$key')));
      await settle(tester);
      expect(find.byType(LockScreen), findsNothing);
      expect(api.answers, [('run-1', 'deny', 'req-1')]);
      h.chats.dispose();
      await unmount(tester);
    });

    testWidgets('Permitir asks App Lock first, as the chat does; cancelling '
        'answers nothing', (tester) async {
      final h = await harness(tester);
      await h.prefs.setBool('app_lock_enabled', true);
      final lock = AppLockService(h.prefs)..locked.value = false;
      final api = _ApprovalApi();
      attachApproval(h, 's-approve', 'Despliegue', api: api);
      await pumpHome(
        tester,
        h,
        appLock: lock,
        sessions: [_session('s-approve', 'Despliegue')],
      );
      await tester.tap(find.byKey(const ValueKey('home-now-allow-$key')));
      await settle(tester);
      expect(find.byType(LockScreen), findsOneWidget);
      expect(api.answers, isEmpty);
      await tester.tap(find.text('Cancelar'));
      await settle(tester);
      expect(find.byType(LockScreen), findsNothing);
      expect(api.answers, isEmpty);
      h.chats.dispose();
      await unmount(tester);
    });

    testWidgets('no Permitir when the request does not offer it; Ver opens '
        'the chat', (tester) async {
      final h = await harness(tester);
      attachApproval(
        h,
        's-approve',
        'Despliegue',
        api: _ApprovalApi(),
        choices: const ['deny'],
      );
      await pumpHome(
        tester,
        h,
        sessions: [_session('s-approve', 'Despliegue')],
      );
      expect(find.byKey(const ValueKey('home-now-allow-$key')), findsNothing);
      expect(find.byKey(const ValueKey('home-now-deny-$key')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-now-open-$key')), findsOneWidget);
      h.chats.dispose();
      await unmount(tester);
    });

    testWidgets('a room approval: Permitir answers the exact request of '
        'the room, Ver opens the room', (tester) async {
      final h = await harness(tester);
      h.cache.write(
        h.connection,
        MissionBackendSnapshot(hostedGroups: _groups(), loadedAt: _clock),
      );
      await pumpHome(tester, h);
      final allow = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'home-now-allow-approval:room:room-devs:',
            ),
      );
      expect(allow, findsOneWidget);
      await tester.tap(allow);
      await settle(tester);
      expect(h.roomAnswers.single.$1, 'room-devs');
      expect(h.roomAnswers.single.$3, 'once');
      // Answered: it leaves Home until a newer Bots read.
      expect(allow, findsNothing);
      await unmount(tester);
    });

    testWidgets('an old Bots read offers no room approval', (tester) async {
      final h = await harness(tester);
      h.cache.write(
        h.connection,
        MissionBackendSnapshot(
          hostedGroups: _groups(),
          loadedAt: _clock.subtract(const Duration(minutes: 9)),
        ),
      );
      await pumpHome(tester, h);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('home-now-allow-'),
        ),
        findsNothing,
      );
      await unmount(tester);
    });

    testWidgets('App Lock locked: nothing of Home is painted', (tester) async {
      final h = await harness(tester);
      final lock = AppLockService(h.prefs)..locked.value = true;
      attachApproval(h, 's-approve', 'Nómina de marzo', api: _ApprovalApi());
      await pumpHome(
        tester,
        h,
        appLock: lock,
        sessions: [
          _session('s-approve', 'Nómina de marzo'),
          _session('u1', 'Contrato privado', unread: true),
        ],
        cron: [
          CronJob.fromJson({'id': 'j', 'name': 'Informe de nóminas'}),
        ],
        tasks: _board(),
      );
      expect(find.byKey(const ValueKey('home-board-locked')), findsOneWidget);
      expect(find.textContaining('git push'), findsNothing);
      expect(find.textContaining('Contrato privado'), findsNothing);
      expect(find.textContaining('Nómina'), findsNothing);
      expect(find.textContaining('nóminas'), findsNothing);
      expect(find.textContaining('Publicar 1.2.15'), findsNothing);
      expect(find.byType(HomeBoardView), findsNothing);
      lock.locked.value = false;
      await tester.pump();
      expect(find.text('Contrato privado'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-now-ask-$key')), findsOneWidget);
      h.chats.dispose();
      await unmount(tester);
    });
  });

  group('each widget opens its real place', () {
    testWidgets('a chat row opens the chat; the working one shows its '
        'clock; one deleted elsewhere leaves at once', (tester) async {
      final h = await harness(tester);
      final unread = _session(
        'u1',
        'PR revisada',
        unread: true,
        preview: 'Sin bloqueos.',
      );
      await pumpHome(
        tester,
        h,
        sessions: [
          _session('w1', 'Revisar la PR', ago: const Duration(minutes: 2)),
          unread,
        ],
        activeList: DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'rt-w1',
              storedSessionId: 'w1',
              status: 'working',
              startedAt: _clock.subtract(const Duration(seconds: 75)),
            ),
          ],
        ),
      );
      final working = find.byKey(const ValueKey('home-continue-w1'));
      expect(working, findsOneWidget);
      expect(
        find.descendant(of: working, matching: find.byType(HomeElapsed)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: working,
          matching: find.textContaining('Trabajando'),
        ),
        findsOneWidget,
      );
      expect(find.text('Terminó · Sin bloqueos.'), findsOneWidget);
      // It is also what runs now.
      expect(
        find.byKey(const ValueKey('home-now-run-chat:w1')),
        findsOneWidget,
      );
      final archive = (await tester.runAsync(
        () => SessionArchive.load(h.prefs, h.connection.id),
      ))!;
      await tester.runAsync(() => archive.markSessionDeleted(unread));
      await settle(tester);
      expect(find.byKey(const ValueKey('home-continue-u1')), findsNothing);
      expect(find.byKey(const ValueKey('home-continue-w1')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('Bots: a face opens its Bot Chat; Salas opens the room, '
        'with its unread count and last line', (tester) async {
      final h = await harness(tester);
      h.roster.publish(h.connection.id, 'QA', spec070Profiles());
      final room = spec070Room();
      await SharedPreferencesRoomPrefs(
        h.prefs,
      ).setLastSeenSeq(roomPrefsKey(room), 2);
      h.cache.write(
        h.connection,
        MissionBackendSnapshot(
          hostedGroups: _groups(withApproval: false),
          loadedAt: _clock,
        ),
      );
      await h.seed(
        HomeBoardLayout([
          _w('t', HomeWidgetKind.team, size: HomeWidgetSize.wide),
          _w('r', HomeWidgetKind.room, size: HomeWidgetSize.wide),
        ]),
      );
      await pumpHome(tester, h);
      final bot = find.byKey(const ValueKey('home-team-bot-astra'));
      expect(bot, findsOneWidget);
      expect(
        find.descendant(of: bot, matching: find.byType(LivingBotFace)),
        findsOneWidget,
      );
      await tester.tap(bot);
      await settle(tester);
      expect(h.opened.single.profile, 'astra');
      h.opened.clear();
      final sala = find.byKey(const ValueKey('home-room-room-devs'));
      expect(sala, findsOneWidget);
      expect(find.byKey(const ValueKey('home-room-unread')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-room-last-room-devs')),
        findsOneWidget,
      );
      await tester.tap(sala);
      await settle(tester);
      expect(h.opened.single.roomId, 'room-devs');
      await unmount(tester);
    });

    testWidgets('a Salas that follows a room that is gone says so', (
      tester,
    ) async {
      final h = await harness(tester);
      h.cache.write(
        h.connection,
        MissionBackendSnapshot(
          hostedGroups: _groups(withApproval: false),
          loadedAt: _clock,
        ),
      );
      await h.seed(
        HomeBoardLayout([
          _w(
            'r',
            HomeWidgetKind.room,
            options: const {
              'rooms': ['room-gone'],
            },
          ),
        ]),
      );
      await pumpHome(tester, h);
      expect(find.byKey(const ValueKey('home-widget-missing')), findsOneWidget);
      expect(find.text('Ya no está disponible'), findsOneWidget);
      await unmount(tester);
    });

    for (final owner in ['ops-a', 'ops-b']) {
      testWidgets('Cron: a job opens that job of its owner $owner; the '
          'failure shows on the widget', (tester) async {
        final h = await harness(tester);
        await h.seed(
          HomeBoardLayout([
            _w('cron', HomeWidgetKind.cron, size: HomeWidgetSize.large),
          ]),
        );
        final id = 'job-$owner';
        await pumpHome(
          tester,
          h,
          cron: [
            CronJob.fromJson({
              'id': id,
              'name': 'Routine $owner',
              'profile': owner,
              'last_status': 'error',
              'last_run_at': _clock
                  .subtract(const Duration(hours: 2))
                  .toIso8601String(),
              'next_run_at': _clock
                  .add(const Duration(hours: 2))
                  .toIso8601String(),
            }),
            CronJob.fromJson({
              'id': 'other',
              'name': 'Different routine',
              'profile': 'other-owner',
              'last_status': 'ok',
              'next_run_at': _clock
                  .add(const Duration(hours: 1))
                  .toIso8601String(),
            }),
          ],
        );
        expect(find.byKey(const ValueKey('home-auto-failed')), findsOneWidget);
        expect(find.text('1 falló'), findsOneWidget);
        expect(find.text('Falló · 14:30'), findsOneWidget);
        final target = find.byKey(ValueKey('home-run-$id'));
        expect(
          tester.getRect(find.byKey(const ValueKey('home-run-other'))).top,
          lessThan(tester.getRect(target).top),
          reason: 'by next run',
        );
        await tester.tap(target);
        await settle(tester);
        final route = tester.widget<CronScreen>(find.byType(CronScreen));
        expect(route.initialJobId, id);
        expect(route.profileOverride, owner);
        expect(route.connection.id, h.connection.id);
        expect(route.connManager, same(h.manager));
        await unmount(tester);
      });
    }

    testWidgets('Tareas: reads the board Tasks opens on, only while it is '
        'on the board; a task opens Tasks on it', (tester) async {
      final without = await harness(tester);
      await without.seed(HomeBoardLayout([_w('n', HomeWidgetKind.now)]));
      await pumpHome(tester, without, tasks: _board());
      expect(without.taskReads, 0);
      await unmount(tester);

      final h = await harness(tester);
      await h.seed(
        HomeBoardLayout([
          _w('tasks', HomeWidgetKind.tasks, size: HomeWidgetSize.large),
        ]),
      );
      await pumpHome(tester, h, tasks: _board());
      expect(h.taskReads, 1);
      expect(find.text('Publicar 1.2.15'), findsOneWidget);
      expect(find.text('Notas de la versión'), findsOneWidget);
      expect(find.text('Ya hecho'), findsNothing);
      expect(find.byKey(const ValueKey('home-tasks-running')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-tasks-pending')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-task-k1')));
      await settle(tester);
      final route = tester.widget<TasksScreen>(find.byType(TasksScreen));
      expect(route.initialTaskId, 'k1');
      expect(route.connection.id, h.connection.id);
      await unmount(tester);
    });

    testWidgets('a read that fails says so on its widget and reads again '
        'on demand; the rest of Home is unaffected', (tester) async {
      final h = await harness(tester);
      await h.seed(
        HomeBoardLayout([
          _w('now', HomeWidgetKind.now),
          _w('cron', HomeWidgetKind.cron, size: HomeWidgetSize.wide),
          _w('tasks', HomeWidgetKind.tasks, size: HomeWidgetSize.wide),
        ]),
      );
      h.failFeeds = true;
      await pumpHome(tester, h, cron: const [], tasks: _board());
      expect(find.text('No se pudo leer'), findsNWidgets(2));
      expect(find.text('Todo tranquilo'), findsOneWidget);
      h.failFeeds = false;
      await tester.tap(find.byKey(const ValueKey('home-widget-retry')).first);
      await settle(tester);
      expect(find.text('No se pudo leer'), findsNothing);
      expect(find.text('Publicar 1.2.15'), findsOneWidget);
      expect(find.text('Sin automatizaciones'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a Chat widget pinned to one chat shows that chat only', (
      tester,
    ) async {
      final h = await harness(tester);
      await h.seed(
        HomeBoardLayout([
          _w('c', HomeWidgetKind.chat, options: const {'chat': 'b'}),
        ]),
      );
      await pumpHome(
        tester,
        h,
        sessions: [
          _session('a', 'Plan de la semana'),
          _session('b', 'Viaje a Lisboa', preview: 'Vuelos listos.'),
        ],
      );
      expect(find.text('Viaje a Lisboa'), findsOneWidget);
      expect(find.text('Plan de la semana'), findsNothing);
      await unmount(tester);
    });
  });

  group('cached first paint', () {
    testWidgets('the first frame is the board with what this process read '
        'last; nothing is awaited and nothing was read yet', (tester) async {
      final h = await harness(tester);
      final scope = HomeFeedCache.scopeOf(h.connection.id, 'default');
      h.feed
        ..putCron(scope, [
          CronJob.fromJson({
            'id': 'j1',
            'name': 'Copia de seguridad',
            'next_run_at': _clock
                .add(const Duration(hours: 5))
                .toIso8601String(),
          }),
        ])
        ..putTasks(scope, _board());
      await h.seed(
        HomeBoardLayout([
          _w('now', HomeWidgetKind.now),
          _w('cron', HomeWidgetKind.cron),
          _w('tasks', HomeWidgetKind.tasks),
        ]),
      );
      // The server never answers: one frame, and nothing was read.
      await pumpHome(
        tester,
        h,
        frames: 0,
        hangClient: true,
        cron: const [],
        tasks: _board(),
      );
      expect(h.healthChecks, lessThanOrEqualTo(1));
      expect(h.cronReads, 0);
      expect(h.taskReads, 0);
      expect(tileOf(HomeWidgetKind.now), findsOneWidget);
      expect(find.text('Copia de seguridad'), findsOneWidget);
      expect(find.text('Publicar 1.2.15'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-widget-skeleton')), findsNothing);
      expect(tester.takeException(), isNull);
      await settle(tester);
      expect(h.cronReads, 0);
      expect(find.text('Copia de seguridad'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('the refresh behind replaces what was cached when it lands', (
      tester,
    ) async {
      final h = await harness(tester);
      final scope = HomeFeedCache.scopeOf(h.connection.id, 'default');
      h.feed.putCron(scope, [
        CronJob.fromJson({
          'id': 'j1',
          'name': 'Copia de seguridad',
          'next_run_at': _clock.add(const Duration(hours: 5)).toIso8601String(),
        }),
      ]);
      await h.seed(HomeBoardLayout([_w('cron', HomeWidgetKind.cron)]));
      h.holdReads = Completer<void>();
      await pumpHome(tester, h, cron: const []);
      // The read is out and has not answered: the cached list stays.
      expect(h.cronReads, 1);
      expect(find.text('Copia de seguridad'), findsOneWidget);
      h.holdReads!.complete();
      await settle(tester);
      expect(find.text('Copia de seguridad'), findsNothing);
      expect(find.text('Sin automatizaciones'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('without anything cached the board is there at once and '
        'each widget waits on its own', (tester) async {
      final h = await harness(tester);
      h.holdReads = Completer<void>();
      await h.seed(
        HomeBoardLayout([
          _w('now', HomeWidgetKind.now),
          _w('chats', HomeWidgetKind.continueChats),
          _w('cron', HomeWidgetKind.cron),
          _w('tasks', HomeWidgetKind.tasks),
        ]),
      );
      await pumpHome(tester, h, frames: 0, hangClient: true);
      expect(find.byType(HermesAppBar), findsOneWidget);
      expect(tileOf(HomeWidgetKind.now), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-initial-loading')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-widget-skeleton')),
        findsNWidgets(3),
      );
      expect(h.board(tester).geometry!.plan.rows, 4);
      h.holdReads!.complete();
      await unmount(tester);
    });

    testWidgets('the cron list and the board are read side by side, once '
        'a minute at most; a failed refresh keeps what was shown', (
      tester,
    ) async {
      final h = await harness(tester);
      await h.seed(
        HomeBoardLayout([
          _w('cron', HomeWidgetKind.cron, size: HomeWidgetSize.wide),
          _w('tasks', HomeWidgetKind.tasks, size: HomeWidgetSize.wide),
        ]),
      );
      final jobs = [
        CronJob.fromJson({
          'id': 'j1',
          'name': 'Copia de seguridad',
          'next_run_at': _clock.add(const Duration(hours: 5)).toIso8601String(),
        }),
      ];
      await pumpHome(tester, h, cron: jobs, tasks: _board());
      expect(h.cronReads, 1);
      expect(h.taskReads, 1);
      final scope = HomeFeedCache.scopeOf(h.connection.id, 'default');
      expect(h.feed.cron(scope), hasLength(1));
      expect(h.feed.tasks(scope), isNotNull);
      // Another refresh within the minute reads neither again.
      await tester.fling(
        find.byKey(const ValueKey('home-board-list')),
        const Offset(0, 320),
        900,
      );
      await settle(tester);
      await settle(tester);
      expect(h.cronReads, 1);
      expect(h.taskReads, 1);
      await unmount(tester);

      // The next Home of this process starts from them even if the read
      // fails.
      final again = _Harness(
        h.manager,
        h.prefs,
        h.chats,
        MissionSnapshotCache(),
        BotRosterRegistry(),
        feed: h.feed,
      )..failFeeds = true;
      await pumpHome(tester, again, cron: jobs, tasks: _board());
      expect(find.text('Copia de seguridad'), findsNothing);
      expect(find.text('Publicar 1.2.15'), findsNothing);
      expect(find.text('No se pudo leer'), findsNWidgets(2));
      await unmount(tester);
    });

    testWidgets('a working chat ticks on its own: the board is not rebuilt', (
      tester,
    ) async {
      final h = await harness(tester);
      final chat = h.chats.attach(
        connection: h.connection,
        sessionId: 'w1',
        sessionTitle: 'Revisar la PR',
        api: _HomeClient(const []),
      );
      chat.seedProvisionalLiveStatus(
        const SessionLiveStatus(phase: SessionLivePhase.working),
        turnStartedAt: _clock.subtract(const Duration(seconds: 75)),
      );
      var clock = _clock;
      await pumpHome(
        tester,
        h,
        clock: () => clock,
        sessions: [_session('w1', 'Revisar la PR')],
        activeList: DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'rt-w1',
              storedSessionId: 'w1',
              status: 'working',
              startedAt: _clock.subtract(const Duration(seconds: 75)),
            ),
          ],
        ),
      );
      final body = find.descendant(
        of: tileOf(HomeWidgetKind.continueChats),
        matching: find.byType(HomeWidgetBody),
      );
      final before = tester.widget<HomeWidgetBody>(body);
      expect(find.text('1:15'), findsOneWidget);
      clock = _clock.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1:18'), findsOneWidget);
      // Same widget instance: only the clock text was rebuilt.
      expect(identical(tester.widget<HomeWidgetBody>(body), before), isTrue);
      await unmount(tester);
    });

    testWidgets('App Lock: nothing painted and no extra read while locked', (
      tester,
    ) async {
      final h = await harness(tester);
      await h.seed(
        HomeBoardLayout([
          _w('l', HomeWidgetKind.planLimits),
          _w('s', HomeWidgetKind.server),
          _w('c', HomeWidgetKind.continueChats),
          _w('t', HomeWidgetKind.tasks),
        ]),
      );
      final lock = AppLockService(h.prefs)..locked.value = true;
      await pumpHome(
        tester,
        h,
        appLock: lock,
        sessions: [_session('secret', 'Nómina de marzo')],
        tasks: _board(),
      );
      expect(find.byKey(const ValueKey('home-board-locked')), findsOneWidget);
      expect(find.text('Nómina de marzo'), findsNothing);
      expect(tileOf(HomeWidgetKind.planLimits), findsNothing);
      expect(h.limitReads, 0);
      expect(h.serverReads, 0);
      expect(h.taskReads, 0);

      lock.locked.value = false;
      await tester.pump();
      expect(find.text('Nómina de marzo'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('without Límites, Servidor or Tareas, Home reads none of '
        'them; with them, each reads once', (tester) async {
      final none = await harness(tester);
      await none.seed(HomeBoardLayout([_w('n', HomeWidgetKind.now)]));
      await pumpHome(tester, none, tasks: _board());
      expect(none.limitReads, 0);
      expect(none.serverReads, 0);
      expect(none.taskReads, 0);
      await unmount(tester);

      final with_ = await harness(tester);
      await with_.seed(
        HomeBoardLayout([
          _w('l', HomeWidgetKind.planLimits, size: HomeWidgetSize.wide),
          _w('s', HomeWidgetKind.server, size: HomeWidgetSize.wide),
        ]),
      );
      await pumpHome(
        tester,
        with_,
        limits: AccountUsageLimits.fromGateway({
          'account_lines': ['Semana: 42% usado • se renueva el lunes'],
        }),
      );
      expect(with_.limitReads, 1);
      expect(with_.serverReads, 1);
      expect(find.textContaining('Hermes 0.12.3'), findsOneWidget);
      expect(find.textContaining('Actualización disponible'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('edit mode', () {
    HomeBoardLayout fullBoard() => HomeBoardLayout([
      _w('now', HomeWidgetKind.now, size: HomeWidgetSize.wide),
      _w('chats', HomeWidgetKind.continueChats, size: HomeWidgetSize.wide),
      _w('bots', HomeWidgetKind.team, size: HomeWidgetSize.wide),
      _w('cron', HomeWidgetKind.cron, size: HomeWidgetSize.small),
      _w('tasks', HomeWidgetKind.tasks, size: HomeWidgetSize.small),
    ]);

    testWidgets('holding 420 ms enters edit mode; 400 ms or a 12 px move '
        'does not; the header becomes the edit bar and comes back', (
      tester,
    ) async {
      final h = await harness(tester);
      await pumpHome(tester, h);
      final tile = tileOf(HomeWidgetKind.continueChats);
      final center = tester.getCenter(tile);
      final rect = tester.getRect(tile);

      var g = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 400));
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('home-edit-done')), findsNothing);

      g = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 100));
      await g.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 500));
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('home-edit-done')), findsNothing);

      g = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 430));
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('home-edit-bar')), findsOneWidget);
      expect(find.byType(HermesAppBar), findsOneWidget);
      expect(find.text('Editar inicio'), findsOneWidget);
      expect(find.text('Hecho'), findsOneWidget);
      // The bar takes the header's place: the grid did not move.
      expect(tester.getRect(tile), rect);
      expect(
        tester.getRect(find.byKey(const ValueKey('home-edit-bar'))).height,
        kToolbarHeight,
      );

      await tester.tap(find.byKey(const ValueKey('home-edit-done')));
      await settle(tester);
      expect(find.byKey(const ValueKey('home-edit-bar')), findsNothing);
      expect(find.byType(HermesAppBar), findsOneWidget);
      expect(tester.getRect(tile), rect);
      await unmount(tester);
    });

    testWidgets('a full board: «+» is off and the meter says «Lleno»; a '
        'size that does not fit is off; a smaller one opens a slot', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final h = await harness(tester);
      await h.seed(fullBoard());
      await pumpHome(tester, h);
      await hold(tester, tileById('now'));
      expect(find.text('Inicio lleno'), findsOneWidget);
      final add = find.byKey(const ValueKey('home-edit-add'));
      expect(
        tester.getSemantics(add),
        isSemantics(isButton: true, isEnabled: false, hasEnabledState: true),
      );
      await tester.tap(add);
      await settle(tester);
      expect(find.byKey(const ValueKey('home-gallery')), findsNothing);
      expect(find.byKey(const ValueKey('home-hole-1-3')), findsNothing);
      // Every widget carries remove and, with more than one size, resize.
      for (final id in ['now', 'chats', 'bots', 'cron', 'tasks']) {
        expect(find.byKey(ValueKey('home-remove-$id')), findsOneWidget);
        expect(find.byKey(ValueKey('home-resize-$id')), findsOneWidget);
      }

      await tester.tap(find.byKey(const ValueKey('home-resize-bots')));
      await settle(tester);
      expect(find.byKey(const ValueKey('home-size-bots')), findsOneWidget);
      for (final (size, enabled, selected) in const [
        ('small', true, false),
        ('wide', true, true),
        ('large', false, false),
      ]) {
        expect(
          tester.getSemantics(find.byKey(ValueKey('home-size-bots-$size'))),
          isSemantics(
            isButton: true,
            hasEnabledState: true,
            isEnabled: enabled,
            hasSelectedState: true,
            isSelected: selected,
          ),
          reason: size,
        );
      }
      await tester.tap(find.byKey(const ValueKey('home-size-bots-large')));
      await settle(tester);
      expect(h.stored()!.byId('bots')!.size, HomeWidgetSize.wide);
      expect(h.board(tester).geometry!.plan.hidden, isEmpty);

      await tester.tap(find.byKey(const ValueKey('home-size-bots-small')));
      await settle(tester);
      expect(h.stored()!.byId('bots')!.size, HomeWidgetSize.small);
      expect(find.text('1 hueco'), findsOneWidget);
      expect(find.text('Inicio lleno'), findsNothing);
      // Tapping away closes the control.
      await tester.tap(
        find.byKey(const ValueKey('home-size-dismiss')),
        warnIfMissed: false,
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('home-size-bots')), findsNothing);
      expect(find.byKey(const ValueKey('home-hole-1-3')), findsOneWidget);
      expect(
        tester.getSemantics(add),
        isSemantics(isButton: true, isEnabled: true, hasEnabledState: true),
      );
      semantics.dispose();
      await unmount(tester);
    });

    testWidgets('one free slot: «Añadir widget» offers what the board can '
        'still take, with only the sizes that fit; a size adds it', (
      tester,
    ) async {
      final h = await harness(tester);
      await h.seed(fullBoard().resize('bots', HomeWidgetSize.small));
      await pumpHome(tester, h);
      await hold(tester, tileById('now'));
      expect(find.text('1 hueco'), findsOneWidget);
      // The hole itself adds too.
      await tester.tap(find.byKey(const ValueKey('home-hole-1-3')));
      await settle(tester);
      final gallery = find.byKey(const ValueKey('home-gallery'));
      expect(gallery, findsOneWidget);
      expect(find.text('Añadir widget'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-gallery-meter')), findsOneWidget);
      // One-per-board widgets already there are not offered; the rest are.
      for (final kind in ['now', 'continueChats', 'tasks']) {
        expect(find.byKey(ValueKey('home-gallery-$kind')), findsNothing);
      }
      for (final kind in ['team', 'room', 'cron', 'bot', 'chat', 'today']) {
        expect(find.byKey(ValueKey('home-gallery-$kind')), findsOneWidget);
      }
      // Wide and large do not fit one slot.
      await tester.tap(find.byKey(const ValueKey('home-add-room-wide')));
      await tester.tap(find.byKey(const ValueKey('home-add-room-large')));
      await settle(tester);
      expect(gallery, findsOneWidget);
      expect(h.stored()!.items.length, 5);
      await tester.tap(find.byKey(const ValueKey('home-add-room-small')));
      await settle(tester);
      expect(gallery, findsNothing);
      final added = h.stored()!.items.last;
      expect(added.kind, HomeWidgetKind.room);
      expect(added.size, HomeWidgetSize.small);
      expect(added.roomKeys, isEmpty);
      expect(find.text('Inicio lleno'), findsOneWidget);
      expect(tileById(added.id), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a bot widget asks which bot first', (tester) async {
      final h = await harness(tester);
      h.roster.publish(h.connection.id, 'QA', spec070Profiles());
      await h.seed(HomeBoardLayout([_w('now', HomeWidgetKind.now)]));
      await pumpHome(tester, h);
      await hold(tester, tileById('now'));
      await tester.tap(find.byKey(const ValueKey('home-edit-add')));
      await settle(tester);
      final option = find.byKey(const ValueKey('home-add-bot-wide'));
      await tester.dragUntilVisible(
        option,
        find.byKey(const ValueKey('home-gallery')),
        const Offset(0, -80),
      );
      await settle(tester);
      await tester.tap(option);
      await settle(tester);
      expect(find.text('Qué bot'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-pick-astra')));
      await settle(tester);
      final added = h.stored()!.items.last;
      expect(added.kind, HomeWidgetKind.bot);
      expect(added.size, HomeWidgetSize.wide);
      expect(added.stringOption('bot'), 'astra');
      await unmount(tester);
    });

    testWidgets('drag reorders with reflow and the order is saved', (
      tester,
    ) async {
      final h = await harness(tester);
      await h.seed(
        HomeBoardLayout([
          _w('a', HomeWidgetKind.server),
          _w('b', HomeWidgetKind.today),
          _w('c', HomeWidgetKind.cron),
        ]),
      );
      await pumpHome(tester, h);
      final from = tester.getCenter(tileById('c'));
      final to = tester.getCenter(tileById('a'));
      final g = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 450));
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 10)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        find.byKey(const ValueKey('home-drop-placeholder')),
        findsOneWidget,
      );
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.stored()!.items.map((i) => i.id), ['c', 'a', 'b']);
      // Reflow: «a» now sits where «b» was.
      expect(
        tester.getRect(tileById('c')).topLeft.dx,
        lessThan(tester.getRect(tileById('a')).topLeft.dx),
      );
      await unmount(tester);
    });

    testWidgets('× removes a widget; its settings change its size and what '
        'it follows, a size that does not fit is off there too', (
      tester,
    ) async {
      final h = await harness(tester);
      h.cache.write(
        h.connection,
        MissionBackendSnapshot(
          hostedGroups: _groups(withApproval: false),
          loadedAt: _clock,
        ),
      );
      await h.seed(
        fullBoard()
            .remove('bots')
            .add(
              HomeWidgetKind.room,
              size: HomeWidgetSize.wide,
              newId: () => 'rooms',
            ),
      );
      await pumpHome(tester, h);
      await hold(tester, tileById('now'));
      await tester.tap(find.byKey(const ValueKey('home-remove-cron')));
      await settle(tester);
      expect(h.stored()!.items.map((i) => i.id), [
        'now',
        'chats',
        'tasks',
        'rooms',
      ]);
      expect(tileById('cron'), findsNothing);

      await tester.tap(tileById('rooms'));
      await settle(tester);
      expect(find.byKey(const ValueKey('home-configure')), findsOneWidget);
      // It follows the liveliest rooms until one is chosen.
      await tester.tap(find.byKey(const ValueKey('home-pick-room-devs')));
      await settle(tester);
      expect(h.stored()!.byId('rooms')!.roomKeys, ['room-devs']);
      await tester.tap(find.byKey(const ValueKey('home-pick-any')));
      await settle(tester);
      expect(h.stored()!.byId('rooms')!.roomKeys, isEmpty);
      // Large would push Tareas out: off. Small fits.
      await tester.tap(
        find.byKey(const ValueKey('home-seg-HomeWidgetSize.large')),
      );
      await settle(tester);
      expect(h.stored()!.byId('rooms')!.size, HomeWidgetSize.wide);
      await tester.tap(
        find.byKey(const ValueKey('home-seg-HomeWidgetSize.small')),
      );
      await settle(tester);
      expect(h.stored()!.byId('rooms')!.size, HomeWidgetSize.small);
      await unmount(tester);
    });

    testWidgets('a Cron fixed to one job from its settings', (tester) async {
      final h = await harness(tester);
      await h.seed(HomeBoardLayout([_w('cron', HomeWidgetKind.cron)]));
      await pumpHome(
        tester,
        h,
        cron: [
          CronJob.fromJson({
            'id': 'j1',
            'name': 'Backup',
            'next_run_at': _clock
                .add(const Duration(hours: 1))
                .toIso8601String(),
          }),
          CronJob.fromJson({
            'id': 'j2',
            'name': 'Informe semanal',
            'next_run_at': _clock
                .add(const Duration(hours: 3))
                .toIso8601String(),
          }),
        ],
      );
      expect(find.text('Backup'), findsOneWidget);
      await hold(tester, tileById('cron'));
      await tester.tap(tileById('cron'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('home-pick-j2')));
      await settle(tester);
      expect(h.stored()!.byId('cron')!.stringOption('job'), 'j2');
      Navigator.of(
        tester.element(find.byKey(const ValueKey('home-configure'))),
      ).pop();
      await settle(tester);
      expect(
        find.descendant(
          of: tileById('cron'),
          matching: find.text('Informe semanal'),
        ),
        findsOneWidget,
      );
      await unmount(tester);
    });

    testWidgets('TalkBack can move, resize and remove a widget', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final h = await harness(tester);
      await h.seed(
        HomeBoardLayout([
          _w('a', HomeWidgetKind.server),
          _w('b', HomeWidgetKind.today),
        ]),
      );
      await pumpHome(tester, h);
      final owner = tester.binding.renderViews.first.owner!.semanticsOwner!;
      void act(String id, String label) {
        final node = tester.getSemantics(tileById(id));
        final action = node
            .getSemanticsData()
            .customSemanticsActionIds!
            .firstWhere(
              (i) => CustomSemanticsAction.getAction(i)!.label == label,
            );
        owner.performAction(node.id, SemanticsAction.customAction, action);
      }

      act('b', 'Mover arriba');
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.stored()!.items.map((i) => i.id), ['b', 'a']);
      act('a', 'Tamaño Ancho');
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.stored()!.byId('a')!.size, HomeWidgetSize.wide);
      act('b', 'Quitar «Hoy»');
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.stored()!.items.map((i) => i.id), ['a']);
      semantics.dispose();
      await unmount(tester);
    });

    testWidgets('an empty board offers to add; reduced motion lands in one '
        'frame', (tester) async {
      final h = await harness(tester);
      await h.seed(HomeBoardLayout(const []));
      await pumpHome(tester, h, reduceMotion: true);
      final empty = find.byKey(const ValueKey('home-board-empty'));
      expect(empty, findsOneWidget);
      await tester.tap(empty);
      await settle(tester);
      expect(find.byKey(const ValueKey('home-gallery')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-add-now-wide')));
      await settle(tester);
      expect(h.stored()!.items.single.kind, HomeWidgetKind.now);
      // Reduced motion: a resize is in place on the next frame.
      await tester.tap(find.byKey(const ValueKey('home-edit-done')));
      await tester.pump();
      final id = h.stored()!.items.single.id;
      final wide = tester.getRect(tileById(id));
      await hold(tester, tileById(id));
      await tester.tap(find.byKey(ValueKey('home-resize-$id')));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('home-size-$id-small')));
      await tester.pump();
      await tester.pump();
      expect(tester.getRect(tileById(id)).width, lessThan(wide.width / 2));
      await unmount(tester);
    });
  });

  group('the other widgets hold in their cells', () {
    for (final scale in [1.0, 2.0]) {
      testWidgets('320 dp at ${scale}x: no overflow with one bot, one chat, '
          'Hoy, Servidor and Límites at every size', (tester) async {
        for (final size in HomeWidgetSize.values) {
          final h = await harness(tester);
          h.roster.publish(h.connection.id, 'QA', [
            _profile('default', isDefault: true, displayName: 'Hermes'),
            _profile(
              'astra',
              displayName: 'Astra la que investiga con un nombre muy largo',
            ),
          ]);
          HomeWidgetSize or(HomeWidgetKind kind) =>
              HomeWidgetCatalog.of(kind).sizes.contains(size)
              ? size
              : HomeWidgetSize.wide;
          await h.seed(
            HomeBoardLayout([
              _w(
                'b',
                HomeWidgetKind.bot,
                size: size,
                options: const {'bot': 'astra'},
              ),
              _w(
                'c',
                HomeWidgetKind.chat,
                size: size,
                options: const {'chat': 'a'},
              ),
              if (size == HomeWidgetSize.small) ...[
                _w('t', HomeWidgetKind.today, size: or(HomeWidgetKind.today)),
                _w('s', HomeWidgetKind.server, size: or(HomeWidgetKind.server)),
                _w('l', HomeWidgetKind.planLimits, size: size),
              ],
            ]),
          );
          await pumpHome(
            tester,
            h,
            size: const Size(320, 760),
            textScale: scale,
            sessions: [
              _session(
                'a',
                'Un chat con un título realmente largo que no cabe en una '
                    'sola línea de ninguna manera',
                preview:
                    'Una respuesta larga, con varias frases, que tampoco '
                    'cabe en dos líneas de un widget pequeño.',
              ),
            ],
            limits: AccountUsageLimits.fromGateway(usage(account: claudeLines)),
          );
          expect(tester.takeException(), isNull, reason: '$size');
          final geometry = h.board(tester).geometry!;
          for (final item in geometry.plan.placed) {
            final rect = tester.getRect(tileById(item.id));
            expect(
              rect.height,
              closeTo(
                geometry.rowHeight * item.size.rows +
                    HomeBoardGridRule.gap * (item.size.rows - 1),
                0.5,
              ),
              reason: 'the cell is the grid\'s, whatever is inside',
            );
          }
          await unmount(tester);
        }
        final h = await harness(tester);
        await h.seed(
          HomeBoardLayout([
            _w('t', HomeWidgetKind.today, size: HomeWidgetSize.wide),
            _w('s', HomeWidgetKind.server, size: HomeWidgetSize.wide),
            _w('l', HomeWidgetKind.planLimits, size: HomeWidgetSize.large),
          ]),
        );
        await pumpHome(
          tester,
          h,
          size: const Size(320, 760),
          textScale: scale,
          sessions: [_session('a', 'Plan', ago: const Duration(minutes: 5))],
          limits: AccountUsageLimits.fromGateway(usage(account: claudeLines)),
        );
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });
    }

    testWidgets('Límites: the model sheet\'s parsing in Spanish; no raw '
        'provider text', (tester) async {
      final h = await harness(tester);
      await h.seed(
        HomeBoardLayout([
          _w('l', HomeWidgetKind.planLimits, size: HomeWidgetSize.large),
        ]),
      );
      await pumpHome(
        tester,
        h,
        limits: AccountUsageLimits.fromGateway(usage(account: claudeLines)),
      );
      final tile = tileOf(HomeWidgetKind.planLimits);
      expect(
        find.descendant(of: tile, matching: find.textContaining('% usado')),
        findsWidgets,
      );
      expect(
        find.descendant(of: tile, matching: find.textContaining('claude.ai')),
        findsNothing,
      );
      expect(
        find.descendant(of: tile, matching: find.textContaining('http')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('home-limit-bar-0')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('Servidor shows the update notice; it opens the status '
        'sheet', (tester) async {
      final h = await harness(tester);
      await h.seed(
        HomeBoardLayout([
          _w('s', HomeWidgetKind.server, size: HomeWidgetSize.wide),
        ]),
      );
      await pumpHome(tester, h);
      expect(find.byKey(const ValueKey('home-server')), findsOneWidget);
      expect(find.text('Conectado'), findsOneWidget);
      expect(find.text('Actualización disponible'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('header and dock', () {
    testWidgets('the header says «CONSOLE» by default, not «HERMES CONSOLE»', (
      tester,
    ) async {
      final h = await harness(tester);
      loadHeaderTitle(h.prefs);
      await pumpHome(tester, h);
      final title = tester.widget<Text>(
        find.byKey(const ValueKey('home-header-title')),
      );
      expect(title.data, 'CONSOLE');
      expect(title.style?.fontWeight, isNot(FontWeight.bold));
      expect(title.style?.letterSpacing ?? 0, lessThanOrEqualTo(0));
      expect(find.text('HERMES CONSOLE'), findsNothing);
      await unmount(tester);
    });

    testWidgets('a stored «HERMES CONSOLE» was the old default: the header '
        'says «CONSOLE»; a title the user wrote shows as written', (
      tester,
    ) async {
      addTearDown(() => headerTitleNotifier.value = kDefaultHeaderTitle);
      final h = await harness(tester);
      await h.prefs.setString(kHeaderTitlePrefKey, 'HERMES CONSOLE');
      loadHeaderTitle(h.prefs);
      await pumpHome(tester, h);
      final title = find.byKey(const ValueKey('home-header-title'));
      expect(tester.widget<Text>(title).data, 'CONSOLE');
      expect(find.text('HERMES CONSOLE'), findsNothing);
      await h.prefs.setString(kHeaderTitlePrefKey, 'Mi servidor');
      loadHeaderTitle(h.prefs);
      await tester.pump();
      expect(tester.widget<Text>(title).data, 'Mi servidor');
      await unmount(tester);
    });

    testWidgets('with the gesture dock (QA 9494) the board ends above it; '
        'no classic dock', (tester) async {
      FeatureFlags.instance.resetForTesting(gestureDock: true);
      addTearDown(FeatureFlags.instance.resetToDefaultForTesting);
      GestureDockController.instance.resetForTesting(
        settings: const GestureDockSettings(),
      );
      addTearDown(GestureDockController.instance.resetForTesting);
      final h = await harness(tester);
      await h.seed(
        HomeBoardLayout([
          for (var i = 0; i < 6; i++) _w('s$i', HomeWidgetKind.cron),
          _w('last', HomeWidgetKind.today, size: HomeWidgetSize.wide),
        ]),
      );
      await pumpHome(tester, h);
      expect(find.byType(GestureDockHost), findsOneWidget);
      expect(find.text('Crear'), findsNothing);
      expect(find.text('Bots'), findsNothing);
      // The last row ends just above the bar, with a little air.
      final last = tester.getRect(tileById('last'));
      final dock = tester.getRect(find.byKey(const ValueKey('gesture-dock')));
      expect(last.bottom, lessThanOrEqualTo(dock.top));
      expect(dock.top - last.bottom, lessThan(40));
      await unmount(tester);
    });

    // The action map the real Home gives its dock (the other screens' maps
    // are in test/dock_destinations_test.dart). Each route is read before
    // it builds: the real screens need a server.
    for (final (id, screen) in const <(DockItemId, Type)>[
      (DockItemId.bots, MissionControlScreen),
      (DockItemId.settings, SettingsScreen),
      (DockItemId.sessions, SessionListScreen),
      (DockItemId.cron, CronScreen),
      (DockItemId.tasks, TasksScreen),
      (DockItemId.tools, ToolsHubScreen),
    ]) {
      testWidgets('Home\'s dock: Inicio is where you are and ${id.name} '
          'opens $screen above Home', (tester) async {
        FeatureFlags.instance.resetForTesting(gestureDock: true);
        addTearDown(FeatureFlags.instance.resetToDefaultForTesting);
        GestureDockController.instance.resetForTesting(
          settings: const GestureDockSettings(),
        );
        addTearDown(GestureDockController.instance.resetForTesting);
        final h = await harness(tester);
        await pumpHome(tester, h);
        final dock = tester.widget<Dock>(find.byType(Dock));
        expect(dock.actions[DockItemId.home]!.selected, isTrue);
        expect(dock.actions[DockItemId.home]!.onTap, isNull);
        expect(dock.actions[DockItemId.create]!.onTap, isNotNull);
        expect(dock.actions[DockItemId.create]!.selected, isFalse);
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        expect(navigator.canPop(), isFalse);
        dock.actions[id]!.onTap!();
        Route<dynamic>? top;
        navigator.popUntil((route) {
          top = route;
          return true;
        });
        expect(top!.isFirst, isFalse, reason: 'one screen above Home');
        final built = (top! as MaterialPageRoute<dynamic>).builder(
          navigator.context,
        );
        expect(built.runtimeType, screen);
        await unmount(tester);
      });
    }

    // The first-run welcome that came with the gesture dock is gone: a new
    // user's Home starts with the board and offers nothing by itself.
    testWidgets('first run without chats: Home offers no welcome', (
      tester,
    ) async {
      FeatureFlags.instance.resetForTesting(gestureDock: true);
      addTearDown(FeatureFlags.instance.resetToDefaultForTesting);
      GestureDockController.instance.resetForTesting();
      addTearDown(GestureDockController.instance.resetForTesting);
      final h = await harness(tester, welcomed: false);
      await pumpHome(tester, h);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.byType(GuideCard), findsNothing);
      await unmount(tester);
    });
  });
}
