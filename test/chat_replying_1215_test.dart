import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/pinned_prompt_prefs.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/widgets/chat/chat_replying_indicator.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/message_avatar_header.dart';
import 'package:hermes_android/main.dart';

class _StreamingGateway
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
    runtimeSessionId: 'runtime-replying',
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
    runtimeSessionId: 'runtime-replying',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-replying',
    storedSessionId: 'sess-replying',
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

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-replying',
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

SavedConnection _connection() => SavedConnection(
  id: 'conn-replying',
  label: 'Scroll stress',
  host: 'example.test',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-replying',
  title: 'Prueba de scroll',
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

List<Map<String, dynamic>> _history({int turns = 30, String prefix = 'h'}) {
  final messages = <Map<String, dynamic>>[];
  for (var turn = turns - 1; turn >= 0; turn--) {
    messages.add({
      'id': '$prefix-a-$turn',
      'role': 'assistant',
      'content':
          'Respuesta histórica $turn. '
          'Este texto ocupa varias líneas para que el historial tenga '
          'suficiente recorrido y el lector pueda quedarse a mitad.',
    });
    messages.add({
      'id': '$prefix-u-$turn',
      'role': 'user',
      'content': 'Pregunta histórica $turn con contexto adicional.',
    });
  }
  return messages;
}

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

  Future<ActiveChat> pumpChat(
    WidgetTester tester,
    _StreamingGateway gateway, {
    List<Map<String, dynamic>>? history,
    Map<String, Object> initialPrefs = const {},
    int Function()? wallClockMs,
    bool earlierAvailable = false,
    Future<void> Function(ActiveChat chat)? beforeOpen,
  }) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    SharedPreferences.setMockInitialValues({
      ...initialPrefs,
      'onboarding_done': true,
    });
    final prefs = await SharedPreferences.getInstance();
    await PinnedPromptPrefs.load(prefs);
    addTearDown(() => PinnedPromptPrefs.debugUse(null));
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService();
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: 'sess-replying',
      sessionTitle: 'Prueba de respuesta',
      api: _safeApi(),
      desktopGateway: gateway,
      disableForegroundKeepAlive: true,
      wallClockMsForTesting: wallClockMs,
    );
    chat
      ..internalMessagesForTesting = history ?? _history()
      ..messagesLoaded = true;
    if (earlierAvailable) chat.earlierMessagesAvailableForTesting = true;

    await tester.pumpWidget(
      HermesApp(
        connManager: connectionManager,
        appLock: AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),

        sshManager: SshManager(secureStorage, connectionManager),
        sftpTransfers: SftpTransferService(
          SshManager(secureStorage, connectionManager),
          NotificationService(prefs),
        ),
        sshSessions: SshSessionService(
          SshManager(secureStorage, connectionManager),
        ),
        notifications: NotificationService(prefs),
        activeChats: activeChats,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    if (beforeOpen != null) await beforeOpen(chat);

    final navigatorContext = tester.element(find.byType(Navigator).first);
    Navigator.of(navigatorContext).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    return chat;
  }

  Future<void> settle(WidgetTester tester, [int frames = 10]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
  }

  Future<void> tearDownChat(WidgetTester tester, _StreamingGateway g) async {
    await g.close();
    await tester.pumpWidget(const SizedBox.shrink());
    // A turn left open arms the service's activity watchdog and the stop
    // settle timer; let them run out so no timer outlives the test.
    await tester.pump(const Duration(minutes: 6));
  }

  // ct1215: the live turn tells itself in the transcript. The lone
  // «●●● está respondiendo…» row became the turn's status line.
  Finder statusLine() => find.byKey(const ValueKey('turn-status-line'));

  /// What the status line says, timer included.
  String statusText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('turn-status-text')))
      .textSpan!
      .toPlainText()
      .replaceAll('\u00A0', ' ');

  /// The loose lines of the live turn, under its status.
  Finder liveLines() => find.byKey(const ValueKey('thinking-trace-live'));

  Finder answeringEdge() => find.byWidgetPredicate(
    (w) =>
        w is CustomPaint && w.foregroundPainter is UserBubbleAccentEdgePainter,
  );

  Finder bubbleStatus() => find.byKey(const ValueKey('user-bubble-status'));

  Finder sentCheck() => find.byKey(const ValueKey('user-bubble-sent-check'));

  /// Every painted text run (Text and RichText) that contains [phrase].
  List<String> paintedTextsContaining(WidgetTester tester, String phrase) =>
      tester
          .widgetList<RichText>(find.byType(RichText))
          .map((w) => w.text.toPlainText())
          .where((text) => text.contains(phrase))
          .toList();

  String? bubbleStatusText(WidgetTester tester) {
    final found = bubbleStatus().evaluate();
    if (found.isEmpty) return null;
    return (found.single.widget as Text).data;
  }

  /// The live assistant row: its anchor box, and the header inside it.
  ({Rect row, Rect header}) liveGeometry(WidgetTester tester) {
    final header = find.byType(MessageAvatarHeader).first;
    final row = find.ancestor(
      of: header,
      matching: find.byType(ChatAnswerAnchor),
    );
    return (row: tester.getRect(row.first), header: tester.getRect(header));
  }

  Future<ActiveChat> startTurn(
    WidgetTester tester,
    _StreamingGateway gateway, {
    List<Map<String, dynamic>>? history,
    int Function()? wallClockMs,
  }) async {
    final chat = await pumpChat(
      tester,
      gateway,
      history: history ?? _history(turns: 3),
      wallClockMs: wallClockMs,
    );
    await tester.pump(const Duration(seconds: 1));
    await chat.send(
      fullText: 'Mira por ejemplo las fotos de ayer',
      model: 'hermes-agent',
      history: chat.buildHistory(),
    );
    await settle(tester, 3);
    return chat;
  }

  // Real-shaped `todo.updated` payload (tui_gateway/tool_progress.py).
  Map<String, dynamic> plan(List<List<String>> rows, {int revision = 1}) => {
    'revision': revision,
    'todos': [
      for (final row in rows)
        {'id': row[0], 'content': row[1], 'status': row[2]},
    ],
  };

  final threeOfFive = [
    ['1', 'Probar herramientas en primer plano', 'completed'],
    ['2', 'Lanzar un proceso en segundo plano', 'completed'],
    ['3', 'Probar subagentes en paralelo', 'completed'],
    ['4', 'Resumir el resultado', 'in_progress'],
    ['5', 'Revisar disco (opcional)', 'pending'],
  ];

  group('ct1215 status line of the live turn', () {
    testWidgets('appears as soon as the turn starts, before any text', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      expect(chat.isStreaming, isTrue, reason: 'precondition: turn running');
      expect(statusLine(), findsOneWidget, reason: 'sent, nothing back yet');
      gateway.emit('message.start');
      await settle(tester);
      expect(statusLine(), findsOneWidget, reason: 'turn started, no text yet');
      expect(statusText(tester), startsWith('Pensando · 0:0'));
      // A polite live region that says the state and never the seconds.
      final node = tester.getSemantics(statusLine());
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(node.label, 'Pensando');
      // No tool row, thought or plan yet: the status is the whole turn.
      expect(find.byType(TurnToolRow), findsNothing);
      expect(find.byKey(const ValueKey('turn-reasoning')), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('quotes the thought being written under «Pensando»', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('reasoning.delta', {'text': 'Primero miro las fotos'});
      await settle(tester);
      expect(statusText(tester), startsWith('Pensando'));
      expect(
        find.descendant(
          of: liveLines(),
          matching: find.byKey(const ValueKey('turn-reasoning')),
        ),
        findsOneWidget,
      );
      expect(
        paintedTextsContaining(tester, 'Primero miro las fotos'),
        isNotEmpty,
      );
      // The next delta lands in the same block: it never piles up.
      gateway.emit('reasoning.delta', {'text': ' y luego las comparo.'});
      await settle(tester);
      expect(find.byKey(const ValueKey('turn-reasoning')), findsOneWidget);
      expect(paintedTextsContaining(tester, 'luego las comparo'), isNotEmpty);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('names the tool in hand in plain words, each with its timer', (
      tester,
    ) async {
      var now = DateTime(2026, 10, 11, 12).millisecondsSinceEpoch;
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway, wallClockMs: () => now);
      gateway.emit('message.start');
      await settle(tester);
      now += 5000;
      gateway.emit('tool.start', const {
        'tool_id': 'call-1',
        'name': 'terminal',
        'args': {'command': 'df -h'},
      });
      await settle(tester);
      now += 2000;
      await tester.pump(const Duration(seconds: 1));
      expect(statusText(tester), 'Trabajando · Ejecutando comando · 0:07');
      final row = find.descendant(
        of: liveLines(),
        matching: find.byType(TurnToolRow),
      );
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.text('Ejecutando · df', findRichText: true),
        ),
        findsOneWidget,
      );
      // The running tool counts its own seconds (from the moment it
      // started, which no test clock stamps).
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining(RegExp(r'^\d+:\d\d$')),
        ),
        findsOneWidget,
      );
      // No raw tool id anywhere on screen.
      expect(paintedTextsContaining(tester, 'terminal'), isEmpty);

      gateway.emit('tool.complete', const {
        'tool_id': 'call-1',
        'name': 'terminal',
      });
      await settle(tester);
      expect(statusText(tester), startsWith('Pensando'));
      expect(
        find.descendant(
          of: row,
          matching: find.text('Ejecutó · df', findRichText: true),
        ),
        findsOneWidget,
        reason: 'the finished tool stays as the last step, with its time',
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets(
      'lists the plan in flight: bar, done folded, current, pending',
      (tester) async {
        final gateway = _StreamingGateway();
        await startTurn(tester, gateway);
        gateway.emit('message.start');
        gateway.emit('tool.start', const {
          'tool_id': 'call-todo',
          'name': 'todo',
        });
        gateway.emit('todo.updated', plan(threeOfFive));
        gateway.emit('tool.complete', const {
          'tool_id': 'call-todo',
          'name': 'todo',
        });
        await settle(tester);
        final tasks = find.descendant(
          of: liveLines(),
          matching: find.byKey(const ValueKey('turn-tasks-live')),
        );
        expect(tasks, findsOneWidget);
        expect(
          find.descendant(of: tasks, matching: find.text('Tareas 3/5')),
          findsOneWidget,
        );
        final bar = tester.widget<LinearProgressIndicator>(
          find.descendant(
            of: tasks,
            matching: find.byType(LinearProgressIndicator),
          ),
        );
        expect(bar.value, closeTo(0.6, 0.001));
        // Finished ones are folded behind «3 completadas».
        expect(
          find.descendant(of: tasks, matching: find.text('3 completadas')),
          findsOneWidget,
        );
        expect(
          paintedTextsContaining(tester, 'Probar subagentes en paralelo'),
          isEmpty,
        );
        expect(
          paintedTextsContaining(tester, 'Resumir el resultado'),
          isNotEmpty,
        );
        expect(
          paintedTextsContaining(tester, 'Revisar disco (opcional)'),
          isNotEmpty,
        );
        // The task-list call itself is not a row: the list tells it.
        expect(find.byType(TurnToolRow), findsNothing);

        await tester.tap(find.byKey(const ValueKey('turn-tasks-done-toggle')));
        await settle(tester, 3);
        expect(
          paintedTextsContaining(tester, 'Probar subagentes en paralelo'),
          isNotEmpty,
        );
        expect(tester.takeException(), isNull);
        await tearDownChat(tester, gateway);
      },
    );

    testWidgets('says it waits for the user while an approval is pending', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('tool.start', const {
        'tool_id': 'call-rm',
        'name': 'terminal',
        'args': {'command': 'rm -rf build'},
      });
      gateway.emit('approval.request', const {
        'request_id': 'approval-1',
        'command': 'rm -rf build',
        'pattern_key': 'rm',
      });
      await settle(tester);
      expect(chat.pendingApproval, isNotNull, reason: 'precondition');
      expect(statusText(tester), startsWith('Esperando tu respuesta'));
      expect(tester.getSemantics(statusLine()).label, 'Esperando tu respuesta');
      // The tool that asked stays as the row in hand.
      expect(
        find.descendant(of: liveLines(), matching: find.byType(TurnToolRow)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a delegation is a row of the turn like any other tool', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('tool.start', const {
        'tool_id': 'call-delegate',
        'name': 'delegate_task',
      });
      gateway.emit('subagent.start', const {
        'subagent_id': 'child-1',
        'status': 'running',
        'goal': 'Revisar el disco',
      });
      await settle(tester);
      expect(
        find.descendant(of: liveLines(), matching: find.byType(TurnToolRow)),
        findsOneWidget,
      );
      expect(paintedTextsContaining(tester, 'delegate_task'), isEmpty);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('stays while the answer streams, without moving the header', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      gateway.emit('message.start');
      await settle(tester);
      expect(statusLine(), findsOneWidget);
      final before = liveGeometry(tester);

      gateway.emit('message.delta', {'text': 'Las fotos de ayer están bien.'});
      await settle(tester, 20);
      expect(find.textContaining('Las fotos de ayer'), findsWidgets);
      expect(statusLine(), findsOneWidget, reason: 'the turn is still live');
      expect(statusText(tester), startsWith('Respondiendo'));
      final after = liveGeometry(tester);
      expect(after.header.left, closeTo(before.header.left, 2));
      expect(
        after.header.top - after.row.top,
        closeTo(before.header.top - before.row.top, 2),
        reason: 'same inset from the top of the row: no jump',
      );
      gateway.emit('message.complete', {'text': chat.assistantContent});
      await settle(tester, 30);
      expect(
        statusLine(),
        findsNothing,
        reason: 'nothing left that looks live',
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a finished turn folds into two quiet lines that open', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('reasoning.delta', {'text': 'Monto cinco tareas.'});
      gateway.emit('tool.start', const {
        'tool_id': 'call-todo',
        'name': 'todo',
      });
      gateway.emit('todo.updated', plan(threeOfFive));
      gateway.emit('tool.complete', const {
        'tool_id': 'call-todo',
        'name': 'todo',
      });
      gateway.emit('tool.start', const {
        'tool_id': 'call-1',
        'name': 'terminal',
        'args': {'command': 'df -h'},
      });
      gateway.emit('tool.complete', const {
        'tool_id': 'call-1',
        'name': 'terminal',
      });
      gateway.emit('message.delta', {'text': 'Hecho: 3 de 5 tareas.'});
      await settle(tester, 20);
      gateway.emit('message.complete', {'text': chat.assistantContent});
      await settle(tester, 40);
      expect(chat.isStreaming, isFalse);

      // Nothing that looks alive is left behind.
      expect(statusLine(), findsNothing);
      expect(liveLines(), findsNothing);
      expect(find.byType(TurnToolRow), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ThinkingTraceCard),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );

      final summary = find.byKey(const ValueKey('thinking-trace-summary'));
      final tasks = find.byKey(const ValueKey('thinking-trace-tasks'));
      expect(summary, findsOneWidget);
      expect(tasks, findsOneWidget);
      expect(tester.getSemantics(summary).label, endsWith(' · 1 comando'));
      expect(tester.getSemantics(summary).label, startsWith('Pensó'));
      expect(tester.getSemantics(summary).flagsCollection.isButton, isTrue);
      expect(
        tester.getSemantics(summary).flagsCollection.isExpanded,
        Tristate.isFalse,
      );
      expect(tester.getSemantics(tasks).label, 'Tareas 3 de 5 · 2 sin hacer');
      expect(tester.getSemantics(tasks).flagsCollection.isButton, isTrue);
      // The two lines sit above the reply text.
      expect(
        tester.getRect(tasks).bottom,
        lessThanOrEqualTo(
          tester.getTopLeft(find.textContaining('Hecho: 3 de 5')).dy + 1,
        ),
      );

      // «Pensó…» opens the thought and the tools with their durations.
      await tester.tap(summary);
      await settle(tester, 12);
      expect(
        tester.getSemantics(summary).flagsCollection.isExpanded,
        Tristate.isTrue,
      );
      expect(find.byKey(const ValueKey('turn-reasoning')), findsOneWidget);
      expect(paintedTextsContaining(tester, 'Monto cinco tareas.'), isNotEmpty);
      expect(find.text('Ejecutó · df', findRichText: true), findsOneWidget);
      // «Tareas…» opens the list: done with checks, the rest «sin hacer».
      await tester.tap(tasks);
      await settle(tester, 12);
      expect(find.byKey(const ValueKey('turn-tasks-history')), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(3));
      expect(
        paintedTextsContaining(tester, 'Resumir el resultado · sin hacer'),
        isNotEmpty,
        reason: 'what was in progress is not being worked on any more',
      );
      expect(
        paintedTextsContaining(tester, 'Revisar disco (opcional) · sin hacer'),
        isNotEmpty,
      );
      // And both fold back.
      await tester.tap(summary);
      await tester.tap(tasks);
      await settle(tester, 12);
      expect(find.byKey(const ValueKey('turn-reasoning')), findsNothing);
      expect(find.byKey(const ValueKey('turn-tasks-history')), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('an older turn keeps its folded line, and it opens', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: [
          {
            'id': 'old-a',
            'role': 'assistant',
            'content': 'Listo, el disco está al 92 %.',
            assistantActivityTraceKey: [
              {
                'kind': 'reasoning',
                'text': 'Miro el disco.',
                'status': 'completed',
              },
              {
                'kind': 'tool',
                'id': 'old-1',
                'label': 'terminal',
                'status': 'completed',
                'detail': 'df',
              },
            ],
          },
          {'id': 'old-u', 'role': 'user', 'content': '¿Cómo va el disco?'},
        ],
      );
      await settle(tester);
      final summary = find.byKey(const ValueKey('thinking-trace-summary'));
      expect(summary, findsOneWidget);
      expect(tester.getSemantics(summary).label, 'Pensó · 1 comando');
      expect(statusLine(), findsNothing);
      await tester.tap(summary);
      await settle(tester, 12);
      expect(find.byKey(const ValueKey('turn-reasoning')), findsOneWidget);
      expect(find.text('Ejecutó · df', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('leaves no live line when the turn fails', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('reasoning.delta', {'text': 'Primero miro las fotos'});
      gateway.emit('tool.start', const {
        'tool_id': 'call-1',
        'name': 'terminal',
        'args': {'command': 'ls'},
      });
      await settle(tester);
      expect(statusLine(), findsOneWidget);
      gateway.emit('error', {'message': 'Boom'});
      await settle(tester, 30);
      expect(chat.isStreaming, isFalse);
      expect(statusLine(), findsNothing);
      expect(liveLines(), findsNothing);
      expect(find.byType(TurnToolRow), findsNothing);
      expect(bubbleStatus(), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('leaves no live line when the user stops the turn', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('reasoning.delta', {'text': 'Primero miro las fotos'});
      gateway.emit('tool.start', const {
        'tool_id': 'call-1',
        'name': 'terminal',
        'args': {'command': 'sleep 30'},
      });
      await settle(tester);
      expect(statusLine(), findsOneWidget);
      unawaited(chat.cancel());
      await settle(tester, 30);
      expect(chat.isStreaming, isFalse);
      expect(statusLine(), findsNothing);
      expect(liveLines(), findsNothing);
      expect(find.byType(TurnToolRow), findsNothing);
      expect(bubbleStatus(), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('the mark is still: no animation of its own', (tester) async {
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      await settle(tester);
      expect(statusLine(), findsOneWidget);
      // Only the seconds change; nothing inside the line animates.
      expect(
        find.descendant(
          of: statusLine(),
          matching: find.byWidgetPredicate(
            (w) => w is AnimatedWidget || w is ImplicitlyAnimatedWidget,
          ),
        ),
        findsNothing,
      );
      await tearDownChat(tester, gateway);
    });
  });
  group('rp1215 which bubble is being answered', () {
    testWidgets('footer says Enviado with a check until the answer streams, '
        'then nothing', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      // Accepted by the gateway, the turn itself has not started yet.
      expect(chat.isStreaming, isTrue, reason: 'precondition');
      expect(chat.desktopTurnStartedAt, isNull, reason: 'precondition');
      expect(bubbleStatus(), findsOneWidget);
      expect(bubbleStatusText(tester), 'Enviado');
      expect(sentCheck(), findsOneWidget);

      gateway.emit('message.start');
      await settle(tester);
      // The turn's status line owns its state; the bubble keeps «Enviado».
      expect(statusLine(), findsOneWidget, reason: 'precondition: live');
      expect(bubbleStatusText(tester), 'Enviado');
      expect(sentCheck(), findsOneWidget);
      // Only the bubble of this turn carries it, not the history.
      expect(bubbleStatus(), findsOneWidget);
      final bubble = find.ancestor(
        of: bubbleStatus(),
        matching: find.byKey(const ValueKey('user-turn-row')),
      );
      expect(
        find.descendant(
          of: bubble,
          matching: find.textContaining('Mira por ejemplo las fotos'),
        ),
        findsWidgets,
      );

      gateway.emit('message.delta', {'text': 'Respuesta.'});
      await settle(tester);
      expect(
        bubbleStatus(),
        findsNothing,
        reason: 'the answer is streaming: the bubble says nothing',
      );
      expect(sentCheck(), findsNothing);
      gateway.emit('message.complete', {'text': chat.assistantContent});
      await settle(tester, 40);
      expect(chat.isStreaming, isFalse);
      expect(bubbleStatus(), findsNothing, reason: 'answered: nothing extra');
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('the state of the turn has one owner in the transcript', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      await settle(tester);
      // The turn's status line, never the bubble footer too.
      expect(statusLine(), findsOneWidget, reason: 'precondition: live');
      expect(bubbleStatusText(tester), 'Enviado');
      expect(paintedTextsContaining(tester, 'está respondiendo'), isEmpty);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('while thinking the footer still says only Enviado', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('reasoning.delta', {'text': 'Primero miro las fotos'});
      await settle(tester);
      expect(statusText(tester), startsWith('Pensando'));
      expect(bubbleStatusText(tester), 'Enviado');
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('no accent edge while nothing else waits', (tester) async {
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      await settle(tester);
      expect(bubbleStatus(), findsOneWidget);
      expect(answeringEdge(), findsNothing);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a queued message shows «En cola» and the answered bubble '
        'gets the accent edge', (tester) async {
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: [
          {
            'role': 'user',
            'content': 'Y luego ordénalas por fecha',
            '_optimistic': true,
            '_desktopAcceptedQueued': true,
          },
          {'role': 'assistant', 'content': '', '_pipeline': true},
          {'id': 'u-live', 'role': 'user', 'content': 'Mira las fotos'},
          ..._history(turns: 2),
        ],
        beforeOpen: (chat) async {
          chat.state = ChatPipelineState.streaming;
        },
      );
      await settle(tester);
      Finder rowOf(String text) => find.ancestor(
        of: find.textContaining(text).first,
        matching: find.byKey(const ValueKey('user-turn-row')),
      );
      final queuedStatus = find.descendant(
        of: rowOf('Y luego ordénalas'),
        matching: bubbleStatus(),
      );
      expect(queuedStatus, findsOneWidget);
      expect((tester.widget(queuedStatus) as Text).data, 'En cola');
      final liveStatus = find.descendant(
        of: rowOf('Mira las fotos'),
        matching: bubbleStatus(),
      );
      expect(liveStatus, findsOneWidget);
      expect((tester.widget(liveStatus) as Text).data, 'Enviado');
      expect(
        find.descendant(of: rowOf('Mira las fotos'), matching: answeringEdge()),
        findsOneWidget,
      );
      expect(
        answeringEdge(),
        findsOneWidget,
        reason: 'only the bubble being answered',
      );
      // History bubbles stay plain.
      expect(bubbleStatus(), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });
  });
}
