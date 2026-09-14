import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/agent_center_screen.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
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
}

Widget _app(Widget home, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: home,
);

String _widgetProjection(WidgetTester tester) {
  final values = <String>[];
  for (final widget in tester.allWidgets) {
    final key = widget.key;
    if (key != null) values.add(key.toString());
    if (widget case Text(:final data, :final textSpan)) {
      values.add(data ?? textSpan?.toPlainText() ?? '');
    }
    if (widget case Semantics(:final properties)) {
      values.addAll(
        [
          properties.label,
          properties.value,
          properties.hint,
          properties.tooltip,
        ].whereType<String>(),
      );
    }
    if (widget case Tooltip(:final message)) {
      if (message != null) values.add(message);
    }
  }
  return values.join('\n');
}

void _expectNoPrivateProjection(WidgetTester tester) {
  final projection = _widgetProjection(tester);
  for (final privateValue in const [
    '/private/host/spawn.json',
    'private-session',
    'Parallel review',
    'private goal',
    'private summary',
    'private result',
    'private error',
    'private output',
    'flutter test --token secret',
    'proc-sensitive-id',
    'private-model',
  ]) {
    expect(projection, isNot(contains(privateValue)), reason: privateValue);
  }
}

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
  });

  testWidgets(
    'Agents projects status-only rows and preserves exact history and stop controls',
    (tester) async {
      final gateway = _FakeControlGateway()
        ..agents = AgentCenterSnapshot.fromJson(
          snapshots: {
            'entries': [
              {
                'path': '/private/host/spawn.json',
                'session_id': 'private-session',
                'label': 'Parallel review',
                'goal': 'private goal',
                'count': 2,
                'started_at': 1704067200,
                'metadata': {'model': 'private-model'},
              },
            ],
          },
          processes: {
            'processes': [
              {
                'session_id': 'proc-sensitive-id',
                'command': 'flutter test --token secret',
                'status': 'running',
                'uptime_seconds': 7,
                'output_tail': 'private output',
                'error': 'private error',
              },
            ],
          },
        )
        ..spawnTreeDetail = SpawnTreeDetail.fromJson({
          'session_id': 'private-session',
          'label': 'Parallel review',
          'subagents': [
            {
              'id': 'private-subagent-id',
              'status': 'completed',
              'goal': 'private goal',
              'summary': 'private summary',
              'result': 'private result',
              'error': 'private error',
              'output': 'private output',
              'metadata': {'model': 'private-model'},
            },
          ],
        });

      await tester.pumpWidget(
        _app(
          AgentCenterScreen(gateway: gateway, runtimeSessionId: 'runtime-test'),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Process 1'), findsOneWidget);
      expect(find.textContaining('running · 7 s'), findsOneWidget);
      expect(find.text('Agent work 1'), findsOneWidget);
      expect(find.textContaining('2 subagents'), findsOneWidget);
      _expectNoPrivateProjection(tester);

      await tester.tap(find.byKey(const ValueKey('agent-center-history-1')));
      await tester.pumpAndSettle();

      expect(gateway.loadedSpawnTreePaths, ['/private/host/spawn.json']);
      expect(find.text('Agent work 1'), findsWidgets);
      expect(find.text('Subagent 1'), findsOneWidget);
      expect(find.text('COMPLETED'), findsOneWidget);
      _expectNoPrivateProjection(tester);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('agent-center-process-stop-1')),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Process 1'), findsWidgets);
      _expectNoPrivateProjection(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
      await tester.pumpAndSettle();

      expect(gateway.killedProcesses, ['proc-sensitive-id']);
      _expectNoPrivateProjection(tester);
    },
  );

  testWidgets('Agents conserva detener uno y no expone detener todos', (
    tester,
  ) async {
    final gateway = _FakeControlGateway()
      ..agents = AgentCenterSnapshot.fromJson(
        snapshots: const {'entries': <Object>[]},
        processes: const {
          'processes': [
            {'session_id': 'proc-a', 'command': 'tarea a', 'status': 'running'},
            {'session_id': 'proc-b', 'command': 'tarea b', 'status': 'running'},
          ],
        },
      );
    await tester.pumpWidget(
      _app(
        AgentCenterScreen(gateway: gateway, runtimeSessionId: 'runtime-test'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byKey(const ValueKey('agent-center-new-task')), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-center-stop-all')), findsNothing);
    expect(find.text('Detener todos'), findsNothing);
    expect(find.byTooltip('Detener este proceso'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Detener este proceso').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Detener'));
    await tester.pumpAndSettle();

    expect(gateway.killedProcesses, ['proc-a']);
  });

  testWidgets('unsupported centre is explicit instead of an empty fake list', (
    tester,
  ) async {
    final gateway = _FakeControlGateway()
      ..failure = const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: -32601,
      );

    await tester.pumpWidget(_app(AgentCenterScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(
      find.text('Esta versión de Hermes no publica el centro de agentes.'),
      findsOneWidget,
    );
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('Agents renders English empty-state copy', (tester) async {
    final gateway = _FakeControlGateway();

    await tester.pumpWidget(
      _app(AgentCenterScreen(gateway: gateway), locale: const Locale('en')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Agents'), findsOneWidget);
    expect(find.text('Running'), findsNothing);
    expect(find.text('Saved delegations'), findsOneWidget);
    expect(
      find.text('Hermes has not saved any subagent delegations yet.'),
      findsOneWidget,
    );
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
    expect(find.text('Workspaces'), findsOneWidget);
    expect(find.textContaining('working directory (cwd)'), findsWidgets);
    expect(find.text('No projects yet'), findsOneWidget);
  });
}
