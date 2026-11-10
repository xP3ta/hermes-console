import 'support/live_chat_v4.dart';

import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/widgets/chat/turn_activity_pill.dart' show debugInlineClockWhenFolded;
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/pinned_prompt_prefs.dart';
import 'package:hermes_android/core/services/reasoning_disclosure_prefs.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/theme/motion.dart';
import 'package:hermes_android/core/widgets/chat/chat_replying_indicator.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_approval_dock.dart';
import 'package:hermes_android/core/widgets/interactive_prompt_card.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/core/widgets/message_avatar_header.dart';
import 'package:hermes_android/core/widgets/activity_pill.dart'
    show ActivityTicker;
import 'package:hermes_android/main.dart';
import 'support/test_api_client.dart';

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

/// REVIEW-T3-B C1: a gateway that answers questions, and never settles an
/// answer, so the question stays `responding` for as long as a test needs.
class _PromptGateway extends _StreamingGateway
    implements HermesDesktopInteractivePromptGateway {
  final Completer<DesktopPromptResponse> clarifyGate = Completer();

  /// Answers to approvals that reached the gateway (REVIEW-T3-B C3).
  int approvalAnswers = 0;

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {
    approvalAnswers++;
  }

  @override
  Future<DesktopPromptResponse> respondToClarify(
    String requestId,
    String answer, {
    String? questionId,
  }) => clarifyGate.future;

  @override
  Future<DesktopPromptResponse> skipClarify(String requestId) =>
      clarifyGate.future;

  @override
  Future<DesktopPromptResponse> respondToSudo(
    String requestId,
    EphemeralSensitiveValue password,
  ) => throw StateError('unexpected sudo response');

  @override
  Future<DesktopPromptResponse> respondToSecret(
    String requestId,
    EphemeralSensitiveValue value,
  ) => throw StateError('unexpected secret response');

  @override
  Future<DesktopPromptResponse> respondToTerminalRead(String requestId) =>
      throw StateError('unexpected terminal response');
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

ApiClient _safeApi() => testApiClient(
  baseUrl: 'https://example.test',
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
  // These tests pin the clock itself; the folded row hides it (video).
  setUp(() => debugInlineClockWhenFolded = true);
  tearDown(() => debugInlineClockWhenFolded = false);
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(StepsBarMemory.reset);
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

  // Normal work stays in the transcript. The centered lower pill only
  // complements it with agents, processes, queued input or a pending question.
  Finder statusLine() => liveInlineActivity;
  Finder floatingStatus() => find.byKey(const ValueKey('subagent-work-status'));
  String statusText(WidgetTester tester) {
    final label = tester.widget<Text>(inlineLabel).data!.replaceAll('…', '');
    final clock = find.byKey(const ValueKey('chat-inline-activity-clock'));
    if (clock.evaluate().isEmpty) return label;
    final parts = tester
        .widget<Text>(clock)
        .data!
        .split(':')
        .map(int.parse)
        .toList();
    return '$label · ${parts[0] * 60 + parts[1]}s';
  }

  Finder stepPill() => find.byKey(const ValueKey('subagent-work-step'));

  void expectWorkStatus(WidgetTester tester) {
    expect(statusLine(), findsOneWidget);
    expect(
      floatingStatus(),
      findsNothing,
      reason: 'ordinary work has no floating pill',
    );
    final header = find.byKey(const ValueKey('chat-header'));
    expect(find.descendant(of: header, matching: statusLine()), findsNothing);
    expect(
      tester.getRect(statusLine()).top,
      greaterThan(tester.getRect(header).bottom),
    );
    expect(inlineLabel, findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-inline-activity-clock')),
      findsOneWidget,
    );
    for (final key in [
      'live-turn-status',
      'live-turn-clock',
      'live-turn-status-pill',
      'live-turn-step-pill',
      'live-turn-thought',
      'subagent_group_card',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing);
    }
  }

  Future<void> expectToolStatus(
    WidgetTester tester,
    String id,
    String target,
  ) async {
    expect(floatingStatus(), findsNothing);
    expect(
      statusLine(),
      findsOneWidget,
      reason: 'the same v4 inline row names the running tool',
    );
    // The live look (9 nov): the card says «Trabajando»; what the turn is
    // doing is in its spoken label and in the window of actions.
    expect(
      tester.widget<Semantics>(statusLine()).properties.label,
      contains(target),
    );
    await openInlineDetails(tester);
    final tool = find.byKey(ValueKey('turn-step-card-$id'));
    expect(tool, findsOneWidget);
    expect(tester.getSemantics(tool).label, contains(target));
    expect(find.byKey(ValueKey('turn-step-mark-$id')), findsOneWidget);
  }

  /// The live turn's lines in the transcript: its step cards and its plan.
  Finder liveLines() => find.ancestor(
    of: liveInlineActivity,
    matching: find.byType(ThinkingTraceCard),
  );

  /// The card of a finished step.
  Finder stepCard(String id) => find.byKey(ValueKey('turn-step-card-$id'));

  /// The turn's one line whose first step is [id]: consecutive steps are one
  /// line, and its rows (the step cards) show once it is opened.
  Finder stepLine(String id) => find.byKey(ValueKey('turn-line-$id'));

  /// The text of the line.
  Finder lineLabel() => workedInlineLabel;

  String lineText(WidgetTester tester) =>
      tester.widget<Text>(lineLabel()).data!;

  /// The thought's own line («Pensando» while written, «Pensó…» after).
  Finder thoughtLine() =>
      find.descendant(of: liveInlineActivity, matching: inlineLabel);

  /// A thought inside the opened «Trabajó» line.
  Finder innerThoughtLabel() => find.byWidgetPredicate(
    (w) => '${w.key}'.contains('turn-inner-thought-label-'),
  );

  /// Presses the thought line itself: the header floats over the top of the
  /// transcript, so a coordinate tap may land under it.
  Future<void> pressThought(WidgetTester tester) async {
    await openInlineDetails(tester);
    final thought = find.byWidgetPredicate(
      (w) =>
          w is Semantics &&
          ('${w.key}'.contains('turn-thought-card-') ||
              '${w.key}'.contains('turn-inner-thought-')),
    );
    expect(thought, findsOneWidget);
    tester.widget<Semantics>(thought).properties.onTap!();
    await tester.pump();
  }

  /// The thought line's button (alone, or a row of the opened line).
  Finder thoughtCard() => find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        ('${w.key}'.contains('turn-thought-card-') ||
            '${w.key}'.contains('turn-inner-thought-')),
  );

  /// Any step card.
  Finder stepCards() =>
      find.byWidgetPredicate((w) => '${w.key}'.contains('turn-step-card-'));

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

  // Keep state, clock, disclosure and completed steps in the transcript.
  // Supplemental activity alone gets the centered lower pill.
  group('ct1215 status of the live turn', () {
    testWidgets('first response and activity paint within one 16 ms frame', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      final began = tester.binding.clock.now();
      gateway.emit('message.start');
      await tester.pump(const Duration(milliseconds: 16));
      expect(statusText(tester), startsWith('Trabajando'));
      expect(tester.binding.clock.now().difference(began).inMilliseconds, 16);

      gateway.emit('reasoning.delta', {'text': 'Checking the requested rules'});
      await tester.pump(const Duration(milliseconds: 16));
      expect(chat.messages.first['reasoning'], contains('Checking'));
      expect(statusLine(), findsOneWidget);

      gateway.emit('message.delta', {'text': 'First visible answer'});
      await tester.pump(const Duration(milliseconds: 16));
      expect(chat.messages.first['content'], 'First visible answer');
      expect(
        paintedTextsContaining(tester, 'First visible answer'),
        isNotEmpty,
      );
      expect(statusText(tester), startsWith('Escribiendo'));
      await tearDownChat(tester, gateway);
    });

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
      // The turn's one clock: «0:0N» right after it starts.
      expect(statusText(tester), matches(RegExp(r'^Trabajando · \ds$')));
      // A polite live region that says the state and never the seconds.
      final node = tester.getSemantics(statusLine());
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(node.label, startsWith('Pensando'));
      expect(node.label, isNot(contains('0:')));
      // No step done, no thought, no step in hand yet: the pill is all.
      expect(stepCards(), findsNothing);
      expect(stepPill(), findsNothing);
      expect(find.byKey(const ValueKey('turn-reasoning')), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('the thought being written stays folded, even with the open '
        'setting: one row, no fragment of its words', (tester) async {
      // Mock 137 A's setting off: the owner still sees it folded while it thinks.
      await ReasoningDisclosurePrefs.shared.setCollapsedByDefault(false);
      addTearDown(() => ReasoningDisclosurePrefs.debugUse(null));
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('reasoning.delta', {'text': 'Primero miro las fotos'});
      await settle(tester);
      final thought = find.byKey(const ValueKey('live-turn-thought'));
      expect(thought, findsNothing, reason: 'no lower thought capsule');
      expectWorkStatus(tester);
      expect(find.byKey(const ValueKey('turn-reasoning')), findsNothing);
      expect(find.byKey(const ValueKey('turn-thought-tail')), findsNothing);
      // The live look (9 nov 2026): a short fragment of the last line, in
      // quiet italic with a cursor, replaces «no fragment of its words».
      expect(
        paintedTextsContaining(tester, 'Primero miro las fotos'),
        isNotEmpty,
      );
      // The next delta only grows that fragment; no block opens.
      gateway.emit('reasoning.delta', {'text': ' y luego las comparo.'});
      await settle(tester);
      expect(find.byKey(const ValueKey('turn-reasoning')), findsNothing);
      expect(find.byKey(const ValueKey('turn-thought-tail')), findsNothing);
      expect(thoughtLine(), findsOneWidget);
      expect(paintedTextsContaining(tester, 'luego las comparo'), isNotEmpty);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('QA9715 thought 137 A: one folded «Pensamiento» row, never a '
        'fragment of the text; opened, the thought grows in ONE block', (
      tester,
    ) async {
      await ReasoningDisclosurePrefs.shared.setCollapsedByDefault(true);
      addTearDown(() => ReasoningDisclosurePrefs.debugUse(null));
      final semantics = tester.ensureSemantics();
      try {
        final gateway = _StreamingGateway();
        await startTurn(tester, gateway);
        gateway.emit('message.start');
        gateway.emit('reasoning.delta', {'text': 'Primero miro las fotos'});
        await settle(tester);
        final thought = find.byKey(const ValueKey('turn-reasoning'));
        expect(thoughtLine(), findsOneWidget);
        expect(tester.widget<Text>(thoughtLine()).data, startsWith('Trabajando'));
        expect(find.byKey(const ValueKey('turn-thought-tail')), findsNothing);
        // The fragment (9 nov live look) is there; the block is still folded.
        expect(paintedTextsContaining(tester, 'Primero miro'), isNotEmpty);
        expect(thought, findsNothing, reason: 'folded');
        expectWorkStatus(tester);
        await pressThought(tester);
        await settle(tester);
        expect(thought, findsOneWidget);
        expect(
          paintedTextsContaining(tester, 'Primero miro las fotos'),
          isNotEmpty,
        );
        for (final delta in [' y luego las comparo', ' antes de responder.']) {
          gateway.emit('reasoning.delta', {'text': delta});
          await settle(tester);
          expect(thought, findsOneWidget);
          expect(thoughtLine(), findsOneWidget);
          expect(paintedTextsContaining(tester, delta.trim()), isNotEmpty);
          expectWorkStatus(tester);
        }
        expect(tester.takeException(), isNull);
        await tearDownChat(tester, gateway);
      } finally {
        semantics.dispose();
      }
    });

    // The header's card says «Trabajando» (the live look, 9 nov), with the clock; the
    // transcript holds ONE folded row named for what it holds, so the word
    // is never said twice at the same time (the owner, APK 9801).
    testWidgets('a live turn that is thinking says «Pensando» once, in the '
        'transcript status; the thought row is «Pensamiento»', (tester) async {
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('reasoning.delta', {'text': 'El usuario pregunta si puede'});
      await settle(tester);
      final inPill = find.descendant(
        of: statusLine(),
        matching: find.textContaining('Trabajando', findRichText: true),
      );
      expect(inPill, findsOneWidget);
      expect(thoughtLine(), findsOneWidget);
      expect(tester.widget<Text>(thoughtLine()).data, startsWith('Trabajando'));
      expect(
        find.textContaining('Trabajando', findRichText: true),
        findsOneWidget,
      );
      // A tool in hand: the pill says the work; the thought, over, is a
      // line of its own, and the tool a row of the open timeline.
      gateway.emit('tool.start', const {
        'tool_id': 'call-1',
        'name': 'terminal',
        'args': {'command': 'df -h'},
      });
      await settle(tester);
      await expectToolStatus(tester, 'call-1', 'df');
      expect(find.text('Pensando'), findsNothing);
      expect(tester.widget<Text>(innerThoughtLabel()).data, isNot('Pensando'));
      expect(
        lineLabel(),
        findsNothing,
        reason: 'the timeline is open while live',
      );
      expect(stepCards(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('names the tool in hand and counts the turn\'s one clock; the '
        'finished tool becomes a card', (tester) async {
      var now = DateTime(2026, 10, 11, 12).millisecondsSinceEpoch;
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway, wallClockMs: () => now);
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
      // The tool's existing process row owns the safe executable and indicator.
      await expectToolStatus(tester, 'call-1', 'df');
      expect(
        stepPill(),
        findsNothing,
        reason: 'the descriptive status now contains the safe tool target',
      );
      // The raw tool id is never in the transcript.
      expect(
        find.descendant(
          of: liveLines(),
          matching: find.textContaining('terminal', findRichText: true),
        ),
        findsNothing,
      );
      expect(
        stepCard('call-1'),
        findsOneWidget,
        reason: 'the step in hand is a row of the open timeline',
      );
      expect(stepLine('call-1'), findsOneWidget);

      gateway.emit('tool.complete', const {
        'tool_id': 'call-1',
        'name': 'terminal',
      });
      await settle(tester);
      // Once the tool is done, the same header returns to thinking.
      expect(tester.getSemantics(statusLine()).label, startsWith('Pensando'));
      expect(statusText(tester), 'Trabajando · 7s');
      expect(stepPill(), findsNothing);
      expect(stepLine('call-1'), findsOneWidget);
      await settle(tester, 12);
      expect(
        stepCard('call-1'),
        findsOneWidget,
        reason: 'recent actions remain visible until the turn ends',
      );
      expect(lineLabel(), findsNothing);
      gateway.emit('message.delta', {'text': 'PUBLIC_TOOL_DONE'});
      await settle(tester, 20);
      gateway.emit('message.complete', {'text': chat.assistantContent});
      await settle(tester, 40);
      expect(stepCard('call-1'), findsNothing);
      await tester.tap(lineLabel());
      await settle(tester, 12);
      expect(stepCard('call-1'), findsOneWidget);
      expect(
        find.descendant(
          of: stepCard('call-1'),
          matching: find.textContaining('df', findRichText: true),
        ),
        findsOneWidget,
        reason: 'the finished tool stays as a card, with what it ran',
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
        await openInlineDetails(tester);
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
        // The earlier done ones fold behind «2 anteriores completadas» (the
        // last done stays in view; the live look, 9 nov).
        expect(
          find.descendant(
            of: tasks,
            matching: find.text('2 anteriores completadas'),
          ),
          findsOneWidget,
        );
        // The last one done stays in view, struck through and dim.
        expect(
          paintedTextsContaining(tester, 'Probar subagentes en paralelo'),
          isNotEmpty,
        );
        expect(
          paintedTextsContaining(tester, 'Resumir el resultado'),
          isNotEmpty,
        );
        expect(
          paintedTextsContaining(tester, 'Revisar disco (opcional)'),
          isNotEmpty,
        );
        // The task-list call itself is not a card: the list tells it.
        expect(stepCard('call-todo'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('turn-tasks-done-toggle')));
        await settle(tester, 3);
        // Opened, the earlier done ones join the last done one.
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
      await settle(tester);
      await expectToolStatus(tester, 'call-rm', 'rm');
      expect(stepPill(), findsNothing);
      gateway.emit('approval.request', const {
        'request_id': 'approval-1',
        'tool': 'terminal',
        'choices': ['once', 'deny'],
        'command': 'rm -rf build',
        'pattern_key': 'rm',
      });
      await settle(tester);
      expect(chat.pendingApproval, isNotNull, reason: 'precondition');
      final island = find.byKey(const ValueKey('island'));
      final waiting = find.byKey(const ValueKey('island-needs-you'));
      expect(waiting, findsOneWidget);
      expect(find.descendant(of: island, matching: waiting), findsOneWidget);
      expect(
        find.descendant(of: waiting, matching: find.text('Te necesita')),
        findsOneWidget,
      );
      expect(find.semantics.byLabel('Te necesita'), findsOneWidget);
      expect(
        tester.widget<ChatIsland>(find.byType(ChatIsland)).status,
        IslandStatus.needsYou,
      );
      expect(
        floatingStatus(),
        findsNothing,
        reason: 'the decision has visual priority',
      );
      expect(tester.widget<Text>(inlineLabel).data, 'Esperando tu permiso');
      expect(statusLine(), findsOneWidget);
      expect(stepPill(), findsNothing, reason: 'no second tool capsule');
      // The header keeps the command's arguments private; the approval
      // card remains where the full command and decision are read.
      expect(
        find.descendant(
          of: island,
          matching: find.textContaining('rm -rf', findRichText: true),
        ),
        findsNothing,
      );
      final approval = find.byType(ChatApprovalDock);
      expect(approval, findsOneWidget);
      expect(
        find.descendant(
          of: approval,
          matching: find.textContaining('rm -rf build', findRichText: true),
        ),
        findsOneWidget,
      );
      final see = find.descendant(of: waiting, matching: find.text('Ver'));
      expect(see, findsOneWidget);
      await tester.tap(see);
      await settle(tester);
      expect(approval, findsOneWidget, reason: 'Ver does not approve the call');
      expect(chat.pendingApproval, isNotNull);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a delegation is a step of the turn like any other tool', (
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
        'tool_call_id': 'call-delegate',
        'status': 'running',
        'goal': 'Revisar el disco',
      });
      await settle(tester);
      final delegates = find.byKey(const ValueKey('delegates-capsule'));
      expect(delegates, findsOneWidget);
      expect(tester.getSemantics(delegates).label, contains('1 subagente'));
      expect(
        find.byKey(const ValueKey('delegated-child-child-1')),
        findsOneWidget,
      );
      await openInlineDetails(tester);
      expect(stepCard('call-delegate'), findsOneWidget);
      await tester.tap(delegates);
      await settle(tester, 20);
      expect(
        find.byKey(const ValueKey('subagent-row-child-1')),
        findsOneWidget,
      );
      Navigator.of(
        tester.element(find.byKey(const ValueKey('subagent-row-child-1'))),
      ).pop();
      await settle(tester, 20);
      expect(
        find.descendant(
          of: liveLines(),
          matching: find.textContaining('delegate_task', findRichText: true),
        ),
        findsNothing,
      );
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
      expect(statusText(tester), startsWith('Escribiendo'));
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

    testWidgets('a finished turn keeps its step cards (decision 2), and they '
        'open', (tester) async {
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
      expect(stepPill(), findsNothing);
      expect(liveLines(), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ThinkingTraceCard),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      // The steps stay: the thought, «Pensó», and the command in ONE closed
      // line.
      expect(thoughtLine(), findsNothing, reason: 'the thought is in the line');
      expect(lineLabel(), findsOneWidget);
      expect(lineText(tester), contains('1 comando'));
      expect(stepCards(), findsNothing);
      expect(
        find.byKey(const ValueKey('thinking-trace-summary')),
        findsNothing,
      );
      await tester.tap(lineLabel());
      await settle(tester, 12);
      expect(stepCards(), findsNWidgets(1), reason: 'the command');
      final tasks = find.byKey(const ValueKey('thinking-trace-tasks'));
      expect(tasks, findsOneWidget);
      expect(tester.getSemantics(tasks).label, 'Tareas 3 de 5 · 2 sin hacer');
      expect(tester.getSemantics(tasks).flagsCollection.isButton, isTrue);
      // Above the reply text.
      expect(
        tester.getRect(tasks).bottom,
        lessThanOrEqualTo(
          tester.getTopLeft(find.textContaining('Hecho: 3 de 5')).dy + 1,
        ),
      );
      // The thought's card opens the thought.
      final card = thoughtCard();
      expect(
        tester.getSemantics(card).flagsCollection.isExpanded,
        Tristate.isFalse,
      );
      await pressThought(tester);
      await settle(tester, 12);
      expect(
        tester.getSemantics(card).flagsCollection.isExpanded,
        Tristate.isTrue,
      );
      expect(find.byKey(const ValueKey('turn-reasoning')), findsOneWidget);
      expect(paintedTextsContaining(tester, 'Monto cinco tareas.'), isNotEmpty);
      // «Tareas…» opens the list: done with checks, the rest «sin hacer».
      await tester.tap(tasks);
      await settle(tester, 12);
      expect(find.byKey(const ValueKey('turn-tasks-history')), findsOneWidget);
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
      await pressThought(tester);
      await tester.tap(tasks);
      await settle(tester, 12);
      expect(find.byKey(const ValueKey('turn-reasoning')), findsNothing);
      expect(find.byKey(const ValueKey('turn-tasks-history')), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a failed step says Fallido after expanding the summary', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: [
          {
            'id': 'failed-a',
            'role': 'assistant',
            'content': 'PUBLIC_FAILED_TOOL',
            assistantActivityTraceKey: [
              {
                'kind': 'tool',
                'id': 'failed-tool',
                'label': 'terminal',
                'status': 'failed',
                'detail': 'git --token=private-value',
                'timestamp': 1700000000000,
                'completed_at': 1700000072000,
              },
            ],
          },
          {'id': 'failed-u', 'role': 'user', 'content': 'PUBLIC_REQUEST'},
        ],
      );
      await settle(tester);
      await tester.tap(lineLabel());
      await settle(tester, 12);
      expect(find.text('Fallido'), findsOneWidget);
      expect(find.text('· 1:12'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('an older turn keeps its step cards, and they open', (
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
      expect(lineLabel(), findsOneWidget);
      expect(lineText(tester), contains('1 comando'));
      expect(thoughtLine(), findsNothing);
      expect(statusLine(), findsNothing);
      await tester.tap(lineLabel());
      await settle(tester, 12);
      expect(stepCards(), findsNWidgets(1), reason: 'the command');
      expect(stepCard('old-1'), findsOneWidget);
      await tester.tap(innerThoughtLabel());
      await settle(tester, 12);
      expect(find.byKey(const ValueKey('turn-reasoning')), findsOneWidget);
      expect(paintedTextsContaining(tester, 'Miro el disco.'), isNotEmpty);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('leaves nothing live when the turn fails', (tester) async {
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
      await expectToolStatus(tester, 'call-1', 'ls');
      expect(
        stepPill(),
        findsNothing,
        reason: 'the descriptive status now contains the safe tool target',
      );
      gateway.emit('error', {'message': 'Boom'});
      await settle(tester, 30);
      expect(chat.isStreaming, isFalse);
      expect(statusLine(), findsNothing);
      expect(stepPill(), findsNothing);
      expect(liveLines(), findsNothing);
      expect(bubbleStatus(), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('leaves nothing live when the user stops the turn', (
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
      await expectToolStatus(tester, 'call-1', 'sleep');
      unawaited(chat.cancel());
      await settle(tester, 30);
      expect(chat.isStreaming, isFalse);
      expect(statusLine(), findsNothing);
      expect(stepPill(), findsNothing);
      expect(liveLines(), findsNothing);
      expect(bubbleStatus(), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('the transcript status clock follows the injected host clock', (
      tester,
    ) async {
      var now = DateTime.utc(2026, 10, 11, 12);
      final gateway = _StreamingGateway();
      await startTurn(
        tester,
        gateway,
        wallClockMs: () => now.millisecondsSinceEpoch,
      );
      gateway.emit('message.start');
      await settle(tester);
      expect(statusLine(), findsOneWidget);
      // Material owns idle theme transitions in the new pill. Its state and
      // elapsed have no repeating animation; only the injected clock advances.
      expect(find.byKey(const ValueKey('live-turn-brain')), findsNothing);
      final ticker = find.descendant(
        of: statusLine(),
        matching: find.byType(ActivityTicker),
      );
      expect(ticker, findsOneWidget);
      final before = statusText(tester);
      final spoken = tester.getSemantics(statusLine()).label;
      await tester.pump(const Duration(seconds: 1));
      expect(statusText(tester), before, reason: 'host clock has not advanced');
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(statusText(tester), 'Trabajando · 2s');
      expect(
        tester.getSemantics(statusLine()).label,
        spoken,
        reason: 'seconds never enter the live region',
      );
      expect(
        tester.hasRunningAnimations,
        isTrue,
        reason: 'v4 isolates the live shimmer animation',
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
      // The turn's status pill owns its state; the bubble keeps «Enviado».
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
      // The turn's status pill, never the bubble footer too.
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
      // Thinking, said once (ORDEN-Q9-CHAT 2; Q9-CHAT5 v2): by the status
      // pill above the composer.
      expect(statusText(tester), startsWith('Trabajando'));
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

  // F5 (REPORT-AUDITORIA-FLUIDEZ §3, C1/C2, P2): a card over the composer
  // or the chat comes in instead of appearing in one frame; with reduced
  // motion it is there at once.
  group('F5: cards that come in', () {
    Finder bars() => find.byKey(const ValueKey('chat-bottom-bars'));

    Future<void> untilFound(WidgetTester tester, Finder finder) async {
      for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
        await tester.pump();
      }
      expect(finder, findsOneWidget);
    }

    Future<void> askApproval(_StreamingGateway gateway) async {
      gateway.emit('message.start');
      gateway.emit('tool.start', const {
        'tool_id': 'call-rm',
        'name': 'terminal',
        'args': {'command': 'rm -rf build'},
      });
    }

    testWidgets('C1: approval grows upwards while the composer stays fixed', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      await askApproval(gateway);
      await settle(tester);
      final before = tester.getTopLeft(bars()).dy;
      final composer = find.byKey(const ValueKey('chat-composer-host'));
      final composerBefore = tester.getRect(composer);
      gateway.emit('approval.request', const {
        'request_id': 'approval-f5',
        'tool': 'terminal',
        'choices': ['once', 'deny'],
        'command': 'rm -rf build',
        'pattern_key': 'rm',
      });
      await untilFound(tester, find.byType(ChatApprovalDock));
      await tester.pump();
      await tester.pump(HermesMotion.base ~/ 2);
      final midway = tester.getTopLeft(bars()).dy;
      await tester.pump(HermesMotion.base);
      await settle(tester, 3);
      final after = tester.getTopLeft(bars()).dy;
      expect(after, lessThan(before), reason: 'the bars grew upwards');
      expect(midway, after, reason: 'the dock has no moving decision targets');
      expect(tester.getRect(composer), composerBefore);
      expect(tester.getRect(find.byType(ChatApprovalDock)).bottom, lessThanOrEqualTo(composerBefore.top));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('C1 with reduced motion: the approval is there at once', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      await askApproval(gateway);
      await settle(tester);
      gateway.emit('approval.request', const {
        'request_id': 'approval-f5-still',
        'tool': 'terminal',
        'choices': ['once', 'deny'],
        'command': 'rm -rf build',
        'pattern_key': 'rm',
      });
      await untilFound(tester, find.byType(ChatApprovalDock));
      final first = tester.getTopLeft(bars()).dy;
      await settle(tester, 6);
      expect(tester.getTopLeft(bars()).dy, first);
      expect(
        find.descendant(
          of: find.byType(ChatApprovalDock),
          matching: find.byType(AnimatedSize),
        ),
        findsNothing,
      );
      await tearDownChat(tester, gateway);
    });

    testWidgets('C2: a question rises into place over a fading veil', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      await settle(tester, 3);
      gateway.emit('clarify.request', const {
        'request_id': 'clarify-f5',
        'question': '¿Seguimos con la tabla?',
      });
      final entrance = find.byKey(
        const ValueKey('interactive-prompt-entrance'),
      );
      await untilFound(tester, entrance);
      double rise() =>
          tester.widget<Transform>(entrance).transform.getTranslation().y;
      expect(rise(), greaterThan(0), reason: 'it starts below its place');
      // From its first frame TalkBack finds it and a finger reaches it.
      expect(find.textContaining('¿Seguimos con la tabla?'), findsOneWidget);
      await tester.pump(HermesMotion.base);
      await tester.pump(HermesMotion.base);
      expect(rise(), closeTo(0, 0.01));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });
    testWidgets('C2 keeps what was typed when the question is answered: '
        'no new card, no second entrance (REVIEW-T3-B C1)', (tester) async {
      final gateway = _PromptGateway();
      final chat = await startTurn(tester, gateway);
      gateway.emit('message.start');
      await settle(tester, 3);
      gateway.emit('clarify.request', const {
        'request_id': 'clarify-f5-keep',
        'question': '¿Qué nombre le pongo?',
      });
      final card = find.byType(InteractivePromptCard);
      await untilFound(tester, card);
      await tester.pump(HermesMotion.base);
      await tester.pump(HermesMotion.base);
      final field = find.descendant(of: card, matching: find.byType(TextField));
      await tester.enterText(field.first, 'informe-final');
      await tester.pump();
      final cardState = tester.state(card);
      // The entry is rebuilt as `responding` (withStatus): the same card.
      unawaited(
        chat.respondToClarify(
          chat.pendingInteractivePrompt!.key,
          'informe-final',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        chat.pendingInteractivePrompt?.status,
        InteractivePromptStatus.responding,
        reason: 'precondition',
      );
      expect(tester.state(card), same(cardState));
      expect(
        tester.widget<TextField>(field.first).controller!.text,
        'informe-final',
      );
      final entrance = find.byKey(
        const ValueKey('interactive-prompt-entrance'),
      );
      expect(
        tester.widget<Transform>(entrance).transform.getTranslation().y,
        closeTo(0, 0.01),
        reason: 'the entrance does not play again',
      );
      await tearDownChat(tester, gateway);
    });
    testWidgets(
      'a resolved approval leaves a quiet outcome beside completed steps',
      (tester) async {
        final gateway = _PromptGateway();
        await startTurn(tester, gateway);
        await askApproval(gateway);
        await settle(tester);
        gateway.emit('approval.request', const {
          'request_id': 'approval-step-outcome',
          'tool': 'terminal',
          'command': 'rm -rf build',
          'choices': ['once', 'deny'],
        });
        await untilFound(tester, find.byType(ChatApprovalDock));
        expect(tester.widget<Text>(inlineLabel).data, 'Esperando tu permiso');
        gateway.emit('approval_resolved', const {
          'request_id': 'approval-step-outcome',
          'choice': 'deny',
        });
        await settle(tester);
        expect(find.byType(ChatApprovalDock), findsNothing);
        await openInlineDetails(tester);
        expect(find.text('Denegado · terminal'), findsOneWidget);
        gateway.emit('tool.complete', const {
          'tool_id': 'call-rm',
          'name': 'terminal',
        });
        gateway.emit('message.complete', const {
          'text': 'No ejecuté el comando.',
        });
        await settle(tester, 40);
        await openInlineDetails(tester);
        expect(
          find.byKey(const ValueKey('approval-settled-step')),
          findsOneWidget,
        );
        expect(find.text('Denegado'), findsOneWidget);
        expect(gateway.approvalAnswers, 0);
        expect(tester.takeException(), isNull);
        await tearDownChat(tester, gateway);
      },
    );

    testWidgets('C1: an approval on its way out takes no tap and is not read '
        '(REVIEW-T3-B C3)', (tester) async {
      final gateway = _PromptGateway();
      final chat = await startTurn(tester, gateway);
      await askApproval(gateway);
      await settle(tester);
      gateway.emit('approval.request', const {
        'request_id': 'approval-c3',
        'tool': 'terminal',
        'choices': ['once', 'deny'],
        'command': 'rm -rf build',
        'pattern_key': 'rm',
      });
      await untilFound(tester, find.byType(ChatApprovalDock));
      await tester.pump(HermesMotion.base);
      await tester.pump(HermesMotion.base);
      // Answered elsewhere: no stale action or accessible decision remains.
      gateway.emit('approval.responded', const {'request_id': 'approval-c3'});
      for (var i = 0; i < 10 && chat.pendingApproval != null; i++) {
        await tester.pump();
      }
      expect(chat.pendingApproval, isNull, reason: 'precondition');
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.byKey(const ValueKey('approval-once')), findsNothing,
        reason: 'a remotely settled request is immediately removed from touch and semantics');
      expect(find.bySemanticsLabel(RegExp('Permiso para ejecutar')), findsNothing);
      expect(gateway.approvalAnswers, 0, reason: 'nothing answered twice');
      await settle(tester, 6);
      expect(find.byType(ChatApprovalDock), findsNothing);
      await tearDownChat(tester, gateway);
    });
  });
}
