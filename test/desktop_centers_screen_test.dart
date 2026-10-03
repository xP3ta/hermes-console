import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/byte_bounded_lru_cache.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'center-test',
  label: 'Hermes QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-only',
);

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

class _FakeControlGateway implements HermesDesktopControlGateway {
  Object? failure;
  ProjectTreeSnapshot projects = const ProjectTreeSnapshot(projects: []);
  Completer<ProjectTreeSnapshot>? projectGate;
  int projectTreeCalls = 0;
  ProjectNode? projectDetail;
  AgentCenterSnapshot agents = const AgentCenterSnapshot(
    snapshots: [],
    processes: [],
  );
  SpawnTreeDetail spawnTreeDetail = const SpawnTreeDetail(
    startedAt: 1,
    finishedAt: 2,
    subagents: [SpawnTreeSubagentEntry(status: AgentCenterStatus.completed)],
  );
  final List<String> loadedSpawnTreePaths = [];
  final List<String> killedProcesses = [];

  void _throwIfNeeded() {
    final value = failure;
    if (value != null) throw value;
  }

  @override
  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  }) async {
    _throwIfNeeded();
    return agents;
  }

  @override
  Future<ProjectTreeSnapshot> projectTree() async {
    projectTreeCalls++;
    _throwIfNeeded();
    return projectGate?.future ?? projects;
  }

  @override
  Future<ProjectNode?> projectSessions(String projectId) async {
    _throwIfNeeded();
    return projectDetail;
  }

  @override
  Future<SpawnTreeDetail> loadSpawnTree(String opaquePath) async {
    loadedSpawnTreePaths.add(opaquePath);
    return spawnTreeDetail;
  }

  @override
  Future<String> startBackgroundTask(
    String runtimeSessionId,
    String text,
  ) async => 'bg-a';

  @override
  Future<void> killBackgroundProcess(
    String runtimeSessionId,
    String processId,
  ) async {
    killedProcesses.add(processId);
  }

  @override
  Future<ExtensionsInventory> extensionsInventory({
    String runtimeSessionId = '',
  }) => throw UnimplementedError();

  @override
  Future<RecoveryDiff> diffRecovery(
    String runtimeSessionId,
    String checkpointHash,
  ) => throw UnimplementedError();

  @override
  Future<RecoveryTimeline> listRecovery(String runtimeSessionId) =>
      throw UnimplementedError();

  @override
  Future<void> reloadMcp({
    String runtimeSessionId = '',
    required bool confirmed,
  }) => throw UnimplementedError();

  @override
  Future<RecoveryRestoreResult> restoreRecovery(
    String runtimeSessionId,
    String checkpointHash,
  ) => throw UnimplementedError();

  @override
  Future<void> setPluginEnabled(String name, bool enabled) =>
      throw UnimplementedError();

  @override
  Future<void> setSessionWorkingDirectory(
    String runtimeSessionId,
    String path,
  ) => throw UnimplementedError();

  @override
  Future<void> setToolsetEnabled(
    String name,
    bool enabled, {
    String runtimeSessionId = '',
  }) => throw UnimplementedError();

  @override
  Future<SessionGoalSnapshot?> readSessionGoal(String runtimeSessionId) =>
      throw UnimplementedError();

  @override
  Future<void> sendGoalAction(String runtimeSessionId, String action) =>
      throw UnimplementedError();
}

Widget _app(Widget home, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: home,
);

void main() {
  testWidgets('Projects renders authoritative project and hydrated lane', (
    tester,
  ) async {
    final gateway = _FakeControlGateway()
      ..projects = ProjectTreeSnapshot.fromJson({
        'active_id': 'p1',
        'projects': [
          {
            'id': 'p1',
            'label': 'Hermes Console',
            'sessionCount': 1,
            'repos': [],
          },
        ],
      })
      ..projectDetail = ProjectNode.tryParse({
        'id': 'p1',
        'label': 'Hermes Console',
        'sessionCount': 1,
        'repos': [
          {
            'id': 'repo',
            'label': 'app',
            'sessionCount': 1,
            'groups': [
              {
                'id': 'main',
                'label': 'main',
                'totalCount': 1,
                'sessions': [
                  {'id': 'chat-a', 'title': 'Theme Studio'},
                ],
              },
            ],
          },
        ],
      });
    final manager = await _manager();

    await tester.pumpWidget(
      _app(
        ProjectsCenterScreen(
          connection: _connection,
          connectionManager: manager,
          gateway: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Hermes Console'), findsOneWidget);
    expect(find.textContaining('1 conversación'), findsOneWidget);
    await tester.tap(find.text('Hermes Console'));
    await tester.pumpAndSettle();
    expect(find.text('app'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
  });

  testWidgets('Projects reopens from memory while refreshing in background', (
    tester,
  ) async {
    final connection = SavedConnection(
      id: 'center-cache-test',
      label: 'Hermes cache',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-only',
    );
    final manager = await _manager();
    final firstGateway = _FakeControlGateway()
      ..projects = ProjectTreeSnapshot.fromJson({
        'projects': [
          {
            'id': 'cached',
            'label': 'Cached project',
            'sessionCount': 1,
            'repos': [],
          },
        ],
      });

    await tester.pumpWidget(
      _app(
        ProjectsCenterScreen(
          connection: connection,
          connectionManager: manager,
          gateway: firstGateway,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cached project'), findsOneWidget);

    final refresh = Completer<ProjectTreeSnapshot>();
    final secondGateway = _FakeControlGateway()..projectGate = refresh;
    await tester.pumpWidget(
      _app(
        ProjectsCenterScreen(
          connection: connection,
          connectionManager: manager,
          gateway: secondGateway,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Cached project'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    refresh.complete(
      ProjectTreeSnapshot.fromJson({
        'projects': [
          {
            'id': 'fresh',
            'label': 'Fresh project',
            'sessionCount': 1,
            'repos': [],
          },
        ],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fresh project'), findsOneWidget);
    expect(secondGateway.projectTreeCalls, 1);
    // QA9343: la caché de proyectos es privada de la autoridad y se vacía
    // con borrar conexión / revocar keys / cambiar perfil.
    expect(ProjectsCenterScreen.memoryCacheLengthForTesting, greaterThan(0));
    PrivateRenderCaches.clearAll();
    expect(ProjectsCenterScreen.memoryCacheLengthForTesting, 0);
  });

  testWidgets('Projects renders English empty-state copy', (tester) async {
    final gateway = _FakeControlGateway();
    final manager = await _manager();

    await tester.pumpWidget(
      _app(
        ProjectsCenterScreen(
          connection: _connection,
          connectionManager: manager,
          gateway: gateway,
        ),
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Projects'), findsOneWidget);
    // The empty state replaces the section header and explains what to do.
    expect(find.textContaining('server folder they work in'), findsOneWidget);
    expect(find.textContaining('working directory (cwd)'), findsWidgets);
    expect(find.text('No projects yet'), findsOneWidget);
    expect(find.text('What is this?'), findsWidgets);
  });
}
