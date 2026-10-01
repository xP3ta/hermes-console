// ss1215: one live status per session, shared by the chat pill, the
// Conversaciones row and the Inicio card, and opening a running chat paints
// its live state (tool, tasks, waiting) before the gateway answers.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/agent_task_list.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/models/session_live_status.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/widgets/activity_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;
import 'support/in_memory_compression_restore_storage.dart';

final Strings _es = StringsEs();

final _connection = SavedConnection(
  id: 'peer',
  label: 'Peer',
  host: 'example.invalid',
  port: 443,
  apiKey: 'k',
  useHttps: true,
  kind: InstanceKind.vps,
);

const _todos = {
  'revision': 3,
  'todos': [
    {'id': '1', 'content': 'Leer el informe', 'status': 'completed'},
    {'id': '2', 'content': 'Arreglar la pastilla', 'status': 'in_progress'},
    {'id': '3', 'content': 'Probar en el móvil', 'status': 'pending'},
  ],
};

DesktopSessionSnapshot _snapshot({
  required bool running,
  Map<String, dynamic>? todos = _todos,
  Map<String, dynamic>? pendingApproval,
}) => DesktopSessionSnapshot.fromJson(
  {
    'session_id': 'runtime-peer',
    'session_key': 'stored-peer',
    'message_count': 1,
    'messages': [peer.publicSnapshot],
    'running': running,
    if (running) 'inflight': {'assistant': '', 'streaming': true},
    'todo_state': ?todos,
    'pending_approval': ?pendingApproval,
  },
  requestedStoredSessionId: 'stored-peer',
  created: false,
  method: 'session.resume',
);

void _roster(ActiveChatService service, String status) {
  service.globalActivity.applyRoster(
    connectionId: 'peer',
    profile: 'default',
    replayEpoch: 'current',
    requestGeneration: service.globalActivity.beginRosterRequest(
      'peer',
      'default',
    ),
    roster: DesktopActiveSessionList(
      sessions: [
        DesktopActiveSession(
          runtimeSessionId: 'runtime-peer',
          storedSessionId: 'stored-peer',
          status: status,
        ),
      ],
    ),
  );
}

ActiveChat _attach(ActiveChatService service, peer.PeerGateway gateway) =>
    service.attach(
      connection: _connection,
      sessionId: 'stored-peer',
      sessionTitle: 'Peer',
      api: ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('nf', 404)),
      ),
      desktopGateway: gateway,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
    );

/// What the list row and Home card resolve for this session.
SessionLiveStatus _listStatus(ActiveChatService service) {
  final chat = service.of('peer', 'stored-peer');
  final global =
      service.globalActivity.isActive('peer', 'default', 'stored-peer')
      ? service.globalActivity.activityFor('peer', 'default', 'stored-peer')
      : null;
  return resolveSessionLiveStatus(
    chat: chat?.liveStatus,
    chatAuthoritative:
        chat != null && (chat.hasDesktopRuntime || chat.lastTerminalAt != null),
    chatSettledAt: chat?.lastTerminalAt,
    global: global,
  );
}

/// The pill's action line as the chat builds it from the same chat.
String? _pillAction(ActiveChat chat, {String headline = 'Pensando…'}) {
  Map<String, dynamic>? live;
  for (final message in chat.messages) {
    if (message['role'] != 'assistant') continue;
    if (message['_pipeline'] == true) live = message;
    break;
  }
  final steps = ActivitySnapshot.splitSteps(
    normalizeAssistantActivityTrace(live?[assistantActivityTraceKey]),
  );
  final model = buildActivityPillModel(
    ActivitySnapshot(
      turnActive: chat.isStreaming,
      tasksActive: chat.isStreaming,
      headline: headline,
      waitingForUser: chat.isStreaming && chat.needsInput,
      current: steps.current,
      tasks: chat.agentTasks,
    ),
    _es,
    now: DateTime(2026),
    revealAfter: Duration.zero,
  );
  return model == null ? null : [model.action, ?model.detail].join(' · ');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  group('state matrix: chat, list and Home read one status', () {
    late ActiveChatService service;
    late peer.PeerGateway gateway;
    late ActiveChat chat;
    late int revisions;

    setUp(() async {
      service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
        globalActivity: GlobalActivityAggregate.inMemory(),
      );
      addTearDown(service.dispose);
      gateway = peer.PeerGateway(_snapshot(running: true));
      addTearDown(gateway.close);
      chat = _attach(service, gateway);
      await chat.loadMessages();
      revisions = 0;
      service.liveStatusRevision.addListener(() => revisions++);
    });

    Future<void> emit(String type, Map<String, dynamic> payload) async {
      gateway.emit(type, payload);
      await Future<void>.delayed(Duration.zero);
    }

    test('thinking with no tool: never «running tools»', () async {
      expect(chat.isStreaming, isTrue);
      expect(chat.liveStatus.phase, SessionLivePhase.thinking);
      expect(_listStatus(service).phase, SessionLivePhase.thinking);
      expect(
        sessionLiveStatusLabel(_es, _listStatus(service)),
        'Pensando… · 1/3 tareas',
      );
    });

    test('running tool X: same tool in pill, list and Home', () async {
      final before = revisions;
      await emit('tool.start', {
        'tool_id': 't1',
        'name': 'terminal',
        'args': {'command': 'pytest -q'},
      });
      expect(revisions, greaterThan(before), reason: 'same event, no poll');
      expect(chat.liveStatus.phase, SessionLivePhase.runningTool);
      expect(chat.liveStatus.toolLabel, 'terminal');
      expect(_pillAction(chat), 'terminal · pytest');
      expect(
        sessionLiveStatusLabel(_es, _listStatus(service)),
        'terminal · pytest · 1/3 tareas',
      );

      await emit('tool.complete', {'tool_id': 't1', 'name': 'terminal'});
      expect(chat.liveStatus.phase, SessionLivePhase.thinking);
      expect(chat.liveStatus.toolLabel, isNull, reason: 'cleared on complete');
      expect(_pillAction(chat), 'Pensando… · Arreglar la pastilla');
    });

    test('tasks move in the same event in pill and list', () async {
      await emit('todo.updated', {
        'revision': 4,
        'todos': [
          {'id': '1', 'content': 'Leer el informe', 'status': 'completed'},
          {'id': '2', 'content': 'Arreglar la pastilla', 'status': 'completed'},
          {'id': '3', 'content': 'Probar en el móvil', 'status': 'in_progress'},
        ],
      });
      expect(chat.liveStatus.tasks?.done, 2);
      expect(_listStatus(service).tasks?.done, 2);
      expect(_pillAction(chat), 'Pensando… · Probar en el móvil');
    });

    test('waiting for you wins over a running tool everywhere', () async {
      await emit('tool.start', {'tool_id': 't2', 'name': 'terminal'});
      await emit('approval.request', {
        'request_id': 'a1',
        'command': 'rm -rf build',
        'description': 'borrar',
      });
      expect(chat.liveStatus.phase, SessionLivePhase.waitingForUser);
      expect(_listStatus(service).phase, SessionLivePhase.waitingForUser);
      expect(_pillAction(chat), 'Esperando tu respuesta');
    });

    test('clarify waits for you too (it used to read «working»)', () async {
      await emit('clarify.request', {
        'request_id': 'c1',
        'question': '¿Sigo?',
        'choices': ['sí', 'no'],
      });
      expect(chat.needsInput, isTrue);
      expect(chat.liveStatus.phase, SessionLivePhase.waitingForUser);
      expect(
        sessionLiveStatusLabel(_es, _listStatus(service)),
        'Esperando tu respuesta · 1/3 tareas',
      );
    });

    test('streaming text: responding everywhere', () async {
      await emit('message.delta', {'text': 'Hola'});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(chat.liveStatus.phase, SessionLivePhase.responding);
      expect(_listStatus(service).phase, SessionLivePhase.responding);
    });

    test(
      'finished: list idle in the same event even with a stale roster row',
      () async {
        _roster(service, 'working');
        await emit('message.complete', {'text': 'Hecho'});
        expect(chat.isStreaming, isFalse);
        expect(chat.liveStatus.isLive, isFalse);
        expect(
          _listStatus(service).isLive,
          isFalse,
          reason: 'a roster row older than the turn end never revives it',
        );
        // A newer roster read (another surface started a turn) still wins.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        _roster(service, 'working');
        expect(_listStatus(service).phase, SessionLivePhase.working);
      },
    );

    test('failed: idle everywhere', () async {
      await emit('error', {'message': 'boom'});
      expect(chat.liveStatus.isLive, isFalse);
      expect(_listStatus(service).isLive, isFalse);
    });
  });

  group('derivation rules', () {
    test('roster-only sessions never name tools', () {
      final status = sessionLiveStatusFromGlobal(
        GlobalActivity(
          scope: const GlobalActivityScope(
            connectionId: 'c',
            profile: 'default',
            durableSessionId: 's',
            runtimeSessionId: 'r',
            replayEpoch: 'e',
          ),
          phase: GlobalActivityPhase.usingTools,
          terminal: false,
          requiresAction: false,
          toolCount: 3,
          subagentCount: 0,
          processCount: 0,
          observedAt: DateTime.utc(2026),
          authority: GlobalActivityAuthority.event,
          stale: false,
        ),
      );
      expect(status.phase, SessionLivePhase.working);
      expect(status.toolLabel, isNull);
      expect(sessionLiveStatusLabel(_es, status), 'Trabajando…');
    });

    test('precedence: compacting < turn, background < delegated', () {
      SessionLiveStatus of(SessionActivity activity) =>
          sessionLiveStatusFromActivity(activity, waitingForUser: false);
      expect(
        of(
          const SessionActivity(
            foregroundTurn: false,
            rosterTurn: false,
            subagentCount: 2,
            processes: [
              SessionActivityProcess(
                id: 'p',
                command: 'sleep',
                notifyOnComplete: false,
                startedAt: null,
              ),
            ],
            foregroundKind: SessionActivityKind.idle,
            observedAt: null,
          ),
        ).phase,
        SessionLivePhase.delegated,
      );
      expect(
        of(
          const SessionActivity(
            foregroundTurn: false,
            rosterTurn: false,
            subagentCount: 0,
            processes: [],
            foregroundKind: SessionActivityKind.idle,
            observedAt: null,
            compacting: true,
          ),
        ).phase,
        SessionLivePhase.compacting,
      );
      expect(
        of(
          const SessionActivity(
            foregroundTurn: true,
            rosterTurn: false,
            subagentCount: 0,
            processes: [],
            foregroundKind: SessionActivityKind.generating,
            observedAt: null,
          ),
        ).phase,
        SessionLivePhase.thinking,
      );
    });
  });

  group('opening a chat that is already running', () {
    late ActiveChatService service;

    setUp(() {
      service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
        globalActivity: GlobalActivityAggregate.inMemory(),
      );
      addTearDown(service.dispose);
    });

    Future<void> visitAndLeave({required bool withTool}) async {
      final gateway = peer.PeerGateway(_snapshot(running: true));
      addTearDown(gateway.close);
      final chat = _attach(service, gateway);
      await chat.loadMessages();
      if (withTool) {
        gateway.emit('tool.start', {
          'tool_id': 't1',
          'name': 'terminal',
          'args': {'command': 'pytest -q'},
        });
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        chat.liveStatus.phase,
        withTool ? SessionLivePhase.runningTool : SessionLivePhase.thinking,
      );
      service.debugDisposeChatForTesting('peer', 'stored-peer');
      expect(service.of('peer', 'stored-peer'), isNull);
    }

    test(
      'roster busy + last visit: tool and tasks before any answer',
      () async {
        await visitAndLeave(withTool: true);
        _roster(service, 'working');
        final gateway = peer.PeerGateway(_snapshot(running: true))
          ..resumeHold = Completer<void>();
        addTearDown(gateway.close);
        final chat = _attach(service, gateway);
        final status = chat.liveStatus;
        expect(status.provisional, isTrue);
        expect(status.phase, SessionLivePhase.runningTool);
        expect(status.toolLabel, 'terminal');
        expect(status.tasks?.done, 1);
        expect(status.tasks?.total, 3);
        expect(_listStatus(service).toolLabel, 'terminal');

        // The snapshot answers: it is authoritative in the same update.
        final load = chat.loadMessages();
        gateway.resumeHold!.complete();
        await load;
        expect(chat.liveStatus.provisional, isFalse);
        expect(chat.liveStatus.phase, SessionLivePhase.thinking);
        expect(chat.liveStatus.tasks?.total, 3);
      },
    );

    test('roster busy, never visited: «working», no invented tool', () {
      _roster(service, 'working');
      final gateway = peer.PeerGateway(_snapshot(running: true))
        ..resumeHold = Completer<void>();
      addTearDown(gateway.close);
      final chat = _attach(service, gateway);
      expect(chat.liveStatus.provisional, isTrue);
      expect(chat.liveStatus.phase, SessionLivePhase.working);
      expect(chat.liveStatus.toolLabel, isNull);
      expect(chat.liveStatus.tasks, isNull);
    });

    test('roster waiting: waiting for you before any answer', () async {
      await visitAndLeave(withTool: true);
      _roster(service, 'waiting');
      final gateway = peer.PeerGateway(_snapshot(running: true))
        ..resumeHold = Completer<void>();
      addTearDown(gateway.close);
      final chat = _attach(service, gateway);
      expect(chat.liveStatus.phase, SessionLivePhase.waitingForUser);
      expect(chat.liveStatus.toolLabel, isNull);
    });

    test('idle chat: nothing provisional, no spinner', () async {
      final gateway = peer.PeerGateway(_snapshot(running: false))
        ..resumeHold = Completer<void>();
      addTearDown(gateway.close);
      final chat = _attach(service, gateway);
      expect(chat.liveStatus.isLive, isFalse);
      expect(chat.provisionalLiveStatus, isNull);
    });

    test(
      'snapshot says finished: provisional clears in the same update',
      () async {
        await visitAndLeave(withTool: true);
        _roster(service, 'working');
        final gateway = peer.PeerGateway(_snapshot(running: false))
          ..resumeHold = Completer<void>();
        addTearDown(gateway.close);
        final chat = _attach(service, gateway);
        expect(chat.liveStatus.phase, SessionLivePhase.runningTool);
        final seen = <SessionLivePhase>[];
        service.liveStatusRevision.addListener(
          () => seen.add(chat.liveStatus.phase),
        );
        final load = chat.loadMessages();
        gateway.resumeHold!.complete();
        await load;
        expect(chat.liveStatus.isLive, isFalse);
        expect(
          seen,
          isNot(contains(SessionLivePhase.working)),
          reason: 'no intermediate generic frame',
        );
        expect(seen.last, SessionLivePhase.idle);
      },
    );

    test('roster stops proving busy: provisional goes at once', () async {
      _roster(service, 'working');
      final gateway = peer.PeerGateway(_snapshot(running: true))
        ..resumeHold = Completer<void>();
      addTearDown(gateway.close);
      final chat = _attach(service, gateway);
      expect(chat.liveStatus.isLive, isTrue);
      _roster(service, 'idle');
      _roster(service, 'idle');
      expect(chat.provisionalLiveStatus, isNull);
      expect(chat.liveStatus.isLive, isFalse);
    });
  });

  test('pill names the task in progress next to n/m when no tool runs', () {
    final tasks = AgentTaskList.tryParse(_todos)!;
    final model = buildActivityPillModel(
      ActivitySnapshot(turnActive: true, headline: 'Pensando…', tasks: tasks),
      _es,
      now: DateTime(2026),
    )!;
    expect(model.action, 'Pensando…');
    expect(model.detail, 'Arreglar la pastilla');
    expect(model.tasksDone, 1);
    expect(model.tasksTotal, 3);
  });

  testWidgets('list label is the pill wording in Spanish', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Builder(
          builder: (context) => Text(
            sessionLiveStatusLabel(
              Strings.of(context),
              const SessionLiveStatus(phase: SessionLivePhase.working),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Trabajando…'), findsOneWidget);
  });
}
