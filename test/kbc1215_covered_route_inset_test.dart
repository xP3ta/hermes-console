import 'dart:async';
import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/bots/ui/roster/bots_roster_view.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';

// QA 9490 profile build (Pixel): while the soft keyboard animated in a chat,
// the routes COVERED by that chat (Mission Control's Bots tab and Home) were
// rebuilt and laid out again on every inset step, because they still depended
// on the full MediaQuery. These tests drive the real route stack
// Home → Mission Control (Bots) → chat and animate the IME like Android does.

class _Gateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-covered',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-covered',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-covered',
    storedSessionId: 'sess-covered',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

class _Source implements MissionControlDataSource {
  final MissionBackendSnapshot snapshot;
  _Source(this.snapshot);

  @override
  Future<MissionBackendSnapshot> load() async => snapshot;

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;

  @override
  void close() {}
}

SavedConnection _connection() => SavedConnection(
  id: 'conn-covered',
  label: 'Covered',
  host: 'example.test',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-covered',
  title: 'Chat on top',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

ApiClient _safeApi() => ApiClient(
  baseUrl: 'https://example.test',
  apiKey: 'test-key',
  httpClient: MockClient((_) async => http.Response('not found', 404)),
);

const _profiles = ['builder', 'forja', 'scout'];

MissionBackendSnapshot _botsSnapshot() {
  HostedGroupRoom room(int r) => HostedGroupRoom.fromJson({
    'room_id': 'room-$r',
    'name': 'Room $r',
    'members': [
      for (final p in _profiles)
        {
          'member_id': '$p-$r',
          'handle': p,
          'profile': p,
          'target': {'kind': 'local', 'profile': p},
        },
    ],
    'authority_gateway_id': 'gateway',
    'authority_epoch': 1,
    'revision': 1,
    'created_at': 1,
    'updated_at': 2,
    'latest_seq': 60,
  });
  HostedGroupLogPage log(int r) => HostedGroupLogPage.fromJson(
    {
      'events': [
        for (var seq = 1; seq <= 60; seq++)
          {
            'room_id': 'room-$r',
            'seq': seq,
            'event_id': 'e-$r-$seq',
            'kind': seq.isOdd ? 'message.user' : 'message.member',
            'actor': seq.isOdd
                ? {'kind': 'user', 'id': 'user'}
                : {'kind': 'member', 'id': '${_profiles[seq % 3]}-$r'},
            'authority_epoch': 1,
            'created_at': seq,
            'idempotent': false,
            'payload': seq.isOdd
                ? {'text': 'go $seq', 'thread_id': 't'}
                : {
                    'member_id': '${_profiles[seq % 3]}-$r',
                    'discussion_event_id': 'e-$r-${seq - 1}',
                    'thread_id': 't',
                    'task_id': 'task-$seq',
                    'text': 'reply $seq',
                  },
          },
      ],
      'cursor': 60,
      'latest_seq': 60,
      'has_more': false,
      'authority': {'gateway_id': 'gateway', 'epoch': 1},
    },
    expectedRoomId: 'room-$r',
    sinceSeq: 0,
  );
  return MissionBackendSnapshot(
    profiles: [for (final p in _profiles) AgentProfile(name: p)],
    board: const KanbanBoard(columns: []),
    profilesCapability: MissionCapabilityState.available,
    sessionsCapability: MissionCapabilityState.available,
    kanbanCapability: MissionCapabilityState.available,
    hostedGroupsCapability: MissionCapabilityState.available,
    hostedGroups: HostedGroupsSnapshot(
      rooms: [for (var r = 0; r < 3; r++) room(r)],
      logs: [for (var r = 0; r < 3; r++) log(r)],
    ),
    loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
  );
}

final _openFrames = [for (var i = 1; i <= 20; i++) 900.0 * i / 20];
final _closeFrames = [for (var i = 19; i >= 0; i--) 900.0 * i / 20];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};

  void mockChannel(String name) {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUp(() {
    secureStore.clear();
    TurnOutboxStore.resetSerializationForTesting();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
    mockChannel('dexterous.com/flutter/local_notifications');
    mockChannel('flutter_foreground_task/methods');
    mockChannel('flutter_foreground_task/background');
  });

  void usePhoneView(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1280, 2856)
      ..devicePixelRatio = 3.0
      ..padding = const FakeViewPadding(top: 120, bottom: 72)
      ..viewPadding = const FakeViewPadding(top: 120, bottom: 72);
    addTearDown(tester.view.reset);
  }

  Finder botsTab() => find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_BotsTab',
    skipOffstage: false,
  );

  /// Counts rebuilt elements (that existed when counting started) under each
  /// of [roots].
  int Function() countRebuildsUnder(List<Element> roots) {
    var count = 0;
    final existing = Set<Element>.identity();
    void collect(Element element) {
      existing.add(element);
      element.visitChildren(collect);
    }

    for (final root in roots) {
      existing.add(root);
      root.visitChildren(collect);
    }
    debugOnRebuildDirtyWidget = (element, _) {
      if (!existing.contains(element)) return;
      if (roots.any((root) => identical(root, element))) {
        count++;
        return;
      }
      element.visitAncestorElements((ancestor) {
        if (!roots.any((root) => identical(root, ancestor))) return true;
        count++;
        return false;
      });
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    return () => count;
  }

  /// Home (the app's real `home:` route) → Mission Control (Bots) → chat,
  /// pushed with the same MaterialPageRoute the app uses.
  Future<NavigatorState> pumpStack(WidgetTester tester, _Gateway g) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService();
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: 'sess-covered',
      sessionTitle: 'Chat on top',
      api: _safeApi(),
      desktopGateway: g,
      disableForegroundKeepAlive: true,
    );
    chat
      ..internalMessagesForTesting = [
        for (var i = 0; i < 6; i++)
          {'id': 'm-$i', 'role': 'user', 'content': 'Mensaje $i'},
      ]
      ..messagesLoaded = true;
    await tester.pumpWidget(
      HermesApp(
        connManager: manager,
        appLock: AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),
        bridgeManager: BridgeManager(secureStorage, manager),
        sshManager: SshManager(secureStorage, manager),
        sftpTransfers: SftpTransferService(
          SshManager(secureStorage, manager),
          NotificationService(prefs),
        ),
        sshSessions: SshSessionService(SshManager(secureStorage, manager)),
        notifications: NotificationService(prefs),
        activeChats: activeChats,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.byType(HomeDashboardScreen), findsOneWidget);
    final nav = Navigator.of(tester.element(find.byType(Navigator).first));
    nav.push(
      MaterialPageRoute(
        builder: (_) => MissionControlScreen(
          connection: connection,
          connManager: manager,
          dataSource: _Source(_botsSnapshot()),
          activeChats: activeChats,
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(BotsRosterView), findsOneWidget);
    expect(botsTab(), findsOneWidget);
    nav.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final composer = find.byType(TextField).last;
    await tester.tap(composer);
    await tester.pump();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.widget<TextField>(composer).focusNode!.hasFocus, isTrue);
    return nav;
  }

  Future<void> tearDownStack(WidgetTester tester, _Gateway g) async {
    debugOnRebuildDirtyWidget = null;
    tester.view.resetViewInsets();
    await g.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  }

  testWidgets(
    'keyboard animation in a chat does not rebuild the covered Bots tab or Home',
    (tester) async {
      usePhoneView(tester);
      final g = _Gateway();
      await pumpStack(tester, g);
      final bots = tester.element(botsTab());
      final home = tester.element(
        find.byType(HomeDashboardScreen, skipOffstage: false),
      );
      final botsRebuilds = countRebuildsUnder([bots]);
      final previous = debugOnRebuildDirtyWidget!;
      var homeRebuilds = 0;
      final homeExisting = Set<Element>.identity()..add(home);
      void collect(Element e) {
        homeExisting.add(e);
        e.visitChildren(collect);
      }

      home.visitChildren(collect);
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous(element, builtOnce);
        if (homeExisting.contains(element)) homeRebuilds++;
      };
      for (final inset in [..._openFrames, ..._closeFrames]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(botsRebuilds(), 0, reason: 'inset $inset rebuilt the Bots tab');
        expect(homeRebuilds, 0, reason: 'inset $inset rebuilt Home');
      }
      expect(tester.takeException(), isNull);
      await tearDownStack(tester, g);
    },
  );

  testWidgets(
    'popping the chat with the keyboard open gives the uncovered route the '
    'live inset, size and text scale in its first frame',
    (tester) async {
      usePhoneView(tester);
      final g = _Gateway();
      final nav = await pumpStack(tester, g);
      Element missionControl() => tester.element(
        find.byType(MissionControlScreen, skipOffstage: false),
      );
      for (final inset in _openFrames) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
      }
      // While covered the route keeps what it saw when it was visible.
      expect(MediaQuery.viewInsetsOf(missionControl()).bottom, 0);
      final frozenScale = MediaQuery.textScalerOf(missionControl()).scale(10);
      // Rotation and an accessibility text-size change while covered.
      tester.view.physicalSize = const Size(2856, 1280);
      tester.platformDispatcher.textScaleFactorTestValue = 1.2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pump(const Duration(milliseconds: 16));
      expect(MediaQuery.sizeOf(missionControl()).width, closeTo(1280 / 3, 1));
      expect(MediaQuery.textScalerOf(missionControl()).scale(10), frozenScale);

      nav.pop();
      await tester.pump();
      // First frame after the pop starts: live values, no stale frame.
      final element = missionControl();
      expect(MediaQuery.viewInsetsOf(element).bottom, 80);
      expect(MediaQuery.sizeOf(element).width, closeTo(2856 / 3, 1));
      final live = tester.element(find.byType(Navigator).first);
      expect(MediaQuery.textScalerOf(live).scale(10), greaterThan(frozenScale));
      expect(
        MediaQuery.textScalerOf(element).scale(10),
        MediaQuery.textScalerOf(live).scale(10),
      );
      final home = tester.element(
        find.byType(HomeDashboardScreen, skipOffstage: false),
      );
      // Home is still covered by Mission Control.
      expect(MediaQuery.viewInsetsOf(home).bottom, 0);

      await tester.pump(const Duration(seconds: 1));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump(const Duration(milliseconds: 16));
      expect(MediaQuery.viewInsetsOf(missionControl()).bottom, 100);
      expect(tester.takeException(), isNull);
      await tearDownStack(tester, g);
    },
  );

  for (final reduced in [false, true]) {
    testWidgets('every theme page route freezes while covered, reduced '
        'motion=$reduced', (tester) async {
      usePhoneView(tester);
      final insets = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('dark'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              insets.add(MediaQuery.viewInsetsOf(context).bottom);
              return const Scaffold(body: SizedBox.expand());
            },
          ),
        ),
      );
      final nav = Navigator.of(tester.element(find.byType(Navigator)));
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: TextField(autofocus: true)),
        ),
      );
      await tester.pumpAndSettle();
      insets.clear();
      for (final inset in [..._openFrames, ..._closeFrames, 600.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(insets, isEmpty, reason: 'the covered home rebuilt on insets');
      nav.pop();
      await tester.pump();
      expect(insets, [200], reason: 'first uncovered frame is live');
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(insets.last, 100, reason: 'visible route follows the inset');
    });
  }

  test('app routes that bypass the theme transitions also freeze', () {
    // A PageRouteBuilder does not go through HermesPageTransitionsBuilder,
    // so its page must be wrapped by hand. The adaptive list-detail cover
    // route is never installed (it only reports visibility).
    const notInstalled = {'lib/core/widgets/adaptive_list_detail.dart': 1};
    final missing = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      final routes = RegExp(r'\bPageRouteBuilder\b').allMatches(source).length;
      final wrapped = RegExp(
        r'pageBuilder:[^;]*?CoveredRouteMediaQueryFreeze\(',
      ).allMatches(source).length;
      final path = file.path.replaceAll(r'\', '/');
      if (routes - (notInstalled[path] ?? 0) > wrapped) missing.add(path);
    }
    expect(missing, isEmpty);
  });

  testWidgets('visible Bots tab ignores MediaQuery fields it does not read', (
    tester,
  ) async {
    usePhoneView(tester);
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: MissionControlScreen(
          connection: _connection(),
          connManager: manager,
          dataSource: _Source(_botsSnapshot()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(botsTab(), findsOneWidget);
    final rebuilds = countRebuildsUnder([tester.element(botsTab())]);
    // A field nothing in the Bots tab reads (a foldable hinge appearing).
    for (final top in [100.0, 200.0]) {
      tester.view.displayFeatures = [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, top, 1280, 0),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureFlat,
        ),
      ];
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(rebuilds(), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
