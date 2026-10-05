import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/navigation/enclosing_route.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:hermes_android/core/services/mission_snapshot_prewarm.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart' show hermesRouteObserver;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_bot_chat_title_lookup.dart';
import 'support/spec070_fixtures.dart';

/// Dock navigation pushes a route over the current screen and pops back to
/// it. The outgoing screen must not rebuild in the first frame of that
/// transition: `ModalRoute.of(context)` anywhere in a screen's State
/// subscribed it to the route's `isCurrent`, which flips exactly then, and the
/// whole screen (Home: ~600 elements) was rebuilt in the same frame in which
/// the destination built its own first frame.

List<Session> _sessions(int n) => [
  for (var i = 0; i < n; i++)
    Session(
      id: 'sess-$i',
      title: 'Conversation $i',
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 10 + i,
      isActive: false,
      preview: 'Preview $i',
      startedAt: 1.7e9 - i * 3600,
      updatedAt: 1.7e9 - i * 3000,
    ),
];

/// Answers after a LAN-like delay, so a refresh started when a pop begins
/// lands in the middle of the back transition.
class _Client extends ApiClient {
  static const latency = Duration(milliseconds: 80);
  var sessionReads = 0;

  _Client()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  @override
  Future<bool> healthCheck() async {
    await Future<void>.delayed(latency);
    return true;
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
  }) async {
    sessionReads++;
    await Future<void>.delayed(latency);
    return _sessions(60);
  }

  @override
  void close() {}
}

final class _Source implements MissionControlDataSource {
  @override
  Future<MissionBackendSnapshot> load() async => MissionBackendSnapshot(
    profiles: spec070Profiles(),
    profilesCapability: MissionCapabilityState.available,
    sessionsCapability: MissionCapabilityState.available,
    kanbanCapability: MissionCapabilityState.available,
    board: const KanbanBoard(columns: <KanbanColumn>[]),
    loadedAt: DateTime(2026),
  );

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;

  @override
  void close() {}
}

Future<(ConnectionManager, SavedConnection)> _manager() async {
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  await manager.saveConnection(
    'QA',
    '127.0.0.2',
    8642,
    'test-key',
    kind: InstanceKind.vps,
  );
  final connection = manager.getConnections().single;
  await manager.setActiveConnection(connection.id);
  return (manager, connection);
}

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('en'),
  // The app's observer: Home refreshes from `didPopNext` on every return.
  navigatorObservers: [hermesRouteObserver],
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: home,
);

Future<void> _idle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Frames of a page transition (MaterialPageRoute: 300 ms) at 60 Hz.
Future<void> _transitionFrames(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 19; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Rebuilds of the [T] screen element during a push over it and during the
/// pop back to it, from the first frame to the last of each transition.
Future<({int push, int pop})> _transitionRebuilds<T extends Widget>(
  WidgetTester tester,
) async {
  var rebuilds = 0;
  debugOnRebuildDirtyWidget = (element, _) {
    if (element.widget is T) rebuilds++;
  };
  addTearDown(() => debugOnRebuildDirtyWidget = null);
  final screen = tester.element(find.byType(T));
  rebuilds = 0;
  Navigator.of(screen).push(
    MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('destination')),
    ),
  );
  await _transitionFrames(tester);
  final push = rebuilds;
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 50));
  rebuilds = 0;
  Navigator.of(screen).pop();
  await _transitionFrames(tester);
  final pop = rebuilds;
  debugOnRebuildDirtyWidget = null;
  return (push: push, pop: pop);
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });

  testWidgets('Home does not rebuild when a dock destination is pushed over '
      'it or popped back to it', (tester) async {
    final (manager, _) = await _manager();
    final client = _Client();
    await tester.pumpWidget(
      _app(
        HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => client,
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        ),
      ),
    );
    await _idle(tester);
    final readsBefore = client.sessionReads;

    final rebuilds = await _transitionRebuilds<HomeDashboardScreen>(tester);

    expect(rebuilds.push, 0, reason: 'during the push');
    expect(rebuilds.pop, 0, reason: 'during the back transition');
    // The return refresh still runs, once, after the transition.
    await _idle(tester);
    expect(client.sessionReads, readsBefore + 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await _idle(tester);
  });

  testWidgets('returning to Home from a dock destination refreshes once, '
      'after the back transition', (tester) async {
    final (manager, _) = await _manager();
    final client = _Client();
    await tester.pumpWidget(
      _app(
        HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => client,
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        ),
      ),
    );
    await _idle(tester);
    // Settings asks Home for a full reload on return (`.then`), on top of
    // the `didPopNext` refresh every return gets.
    await tester.tap(find.byKey(const ValueKey('general-mode-dock-settings')));
    await _idle(tester);
    final readsBefore = client.sessionReads;
    var rebuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is HomeDashboardScreen) rebuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    // The dock's "Home" action.
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .popUntil((route) => route.isFirst);
    await _transitionFrames(tester);

    expect(rebuilds, 0, reason: 'Home stays still while Settings slides away');
    debugOnRebuildDirtyWidget = null;
    await _idle(tester);
    expect(client.sessionReads, readsBefore + 1, reason: 'one coalesced read');
    await tester.pumpWidget(const SizedBox.shrink());
    await _idle(tester);
  });

  testWidgets('Mission Control does not rebuild when a screen is pushed over '
      'it or popped back to it', (tester) async {
    final (manager, connection) = await _manager();
    final cache = MissionSnapshotCache();
    await tester.pumpWidget(
      _app(
        MissionControlScreen(
          connection: connection,
          connManager: manager,
          dataSource: _Source(),
          snapshotCache: cache,
          prewarm: MissionSnapshotPrewarm(cache: cache),
          botChatTitleLookup: FakeBotChatTitleLookup(),
        ),
      ),
    );
    await _idle(tester);

    final rebuilds = await _transitionRebuilds<MissionControlScreen>(tester);

    expect(rebuilds.push, 0, reason: 'during the push');
    expect(rebuilds.pop, 0, reason: 'during the back transition');
    await tester.pumpWidget(const SizedBox.shrink());
    await _idle(tester);
  });

  testWidgets('Conversations does not rebuild when a chat is pushed over it '
      'or popped back to it', (tester) async {
    final (manager, connection) = await _manager();
    await tester.pumpWidget(
      _app(
        SessionListScreen(
          connection: connection,
          connManager: manager,
          clientOverride: _Client(),
          eventStreamOverride: const Stream.empty(),
        ),
      ),
    );
    await _idle(tester);

    final rebuilds = await _transitionRebuilds<SessionListScreen>(tester);

    expect(rebuilds.push, 0, reason: 'during the push');
    expect(rebuilds.pop, 0, reason: 'during the back transition');
    await tester.pumpWidget(const SizedBox.shrink());
    await _idle(tester);
  });

  testWidgets('the general dock shell does not rebuild when a destination is '
      'pushed over it', (tester) async {
    final (manager, connection) = await _manager();
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: GeneralDockShell(
                      connection: connection,
                      connManager: manager,
                      body: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _idle(tester);
    // Pushed as a subscreen: Back is shown (the isFirst aspect still works).
    expect(find.byKey(const ValueKey('general-mode-dock-back')), findsOne);

    final rebuilds = await _transitionRebuilds<GeneralDockShell>(tester);

    expect(rebuilds.push, 0, reason: 'during the push');
    expect(rebuilds.pop, 0, reason: 'during the back transition');
    expect(find.byKey(const ValueKey('general-mode-dock-back')), findsOne);
  });

  testWidgets('EnclosingRoute reports the route once and keeps its child '
      'when the route status changes', (tester) async {
    final reported = <ModalRoute<Object?>?>[];
    var childBuilds = 0;
    final child = Builder(
      builder: (_) {
        childBuilds++;
        return const Text('screen');
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EnclosingRoute(onRoute: reported.add, child: child),
      ),
    );
    expect(reported, hasLength(1));
    expect(reported.single, isA<PageRoute<Object?>>());
    expect(childBuilds, 1);

    Navigator.of(
      tester.element(find.text('screen')),
    ).push(MaterialPageRoute<void>(builder: (_) => const Text('top')));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('top'))).pop();
    await tester.pumpAndSettle();

    expect(reported, hasLength(1), reason: 'same route: not reported again');
    expect(childBuilds, 1, reason: 'route status changes skip the child');
  });
}
