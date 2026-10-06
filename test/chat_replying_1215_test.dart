import 'dart:async';

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
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/pinned_prompt_prefs.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/widgets/chat/chat_replying_indicator.dart';
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
        bridgeManager: BridgeManager(secureStorage, connectionManager),
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

  Finder indicator() => find.byType(ChatReplyingIndicator);

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
  }) async {
    final chat = await pumpChat(
      tester,
      gateway,
      history: history ?? _history(turns: 3),
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

  group('rp1215 replying row in 1:1 chats', () {
    testWidgets('appears as soon as the turn starts, before any text', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      expect(chat.isStreaming, isTrue, reason: 'precondition: turn running');
      expect(indicator(), findsOneWidget, reason: 'sent, nothing back yet');
      expect(
        find.descendant(
          of: indicator(),
          matching: find.text('está respondiendo…'),
        ),
        findsOneWidget,
      );
      gateway.emit('message.start');
      await settle(tester);
      expect(indicator(), findsOneWidget, reason: 'turn started, no text yet');
      // One live header only: the old «Trabajando…» line is replaced.
      expect(find.text('Trabajando…'), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('says «pensando…» while only reasoning arrives', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('reasoning.delta', {'text': 'Primero miro las fotos'});
      await settle(tester);
      expect(indicator(), findsOneWidget);
      expect(
        find.descendant(of: indicator(), matching: find.text('está pensando…')),
        findsOneWidget,
      );
      expect(find.text('está respondiendo…'), findsNothing);
      expect(find.text('Trabajando…'), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('morphs into the answer without moving the header', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      gateway.emit('message.start');
      await settle(tester);
      expect(indicator(), findsOneWidget);
      final before = liveGeometry(tester);

      gateway.emit('message.delta', {'text': 'Las fotos de ayer están bien.'});
      await settle(tester, 20);
      expect(indicator(), findsNothing, reason: 'first visible text arrived');
      expect(find.textContaining('Las fotos de ayer'), findsWidgets);
      final after = liveGeometry(tester);
      expect(after.header.left, closeTo(before.header.left, 2));
      expect(
        after.header.top - after.row.top,
        closeTo(before.header.top - before.row.top, 2),
        reason: 'same inset from the top of the row: no jump',
      );
      gateway.emit('message.complete', {'text': chat.assistantContent});
      await settle(tester, 30);
      expect(indicator(), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('disappears when the turn fails', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      gateway.emit('message.start');
      await settle(tester);
      expect(indicator(), findsOneWidget);
      gateway.emit('error', {'message': 'Boom'});
      await settle(tester, 30);
      expect(chat.isStreaming, isFalse);
      expect(indicator(), findsNothing);
      expect(bubbleStatus(), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('disappears when the user stops the turn', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      gateway.emit('message.start');
      await settle(tester);
      expect(indicator(), findsOneWidget);
      unawaited(chat.cancel());
      await settle(tester, 30);
      expect(chat.isStreaming, isFalse);
      expect(indicator(), findsNothing);
      expect(bubbleStatus(), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('leaves once answer text follows the reasoning', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('reasoning.delta', {'text': 'Primero miro las fotos'});
      await settle(tester);
      expect(indicator(), findsOneWidget, reason: 'precondition: thinking');
      gateway.emit('message.delta', {'text': 'La tercera es la mejor.'});
      await settle(tester, 20);
      expect(find.textContaining('La tercera es la mejor'), findsWidgets);
      expect(indicator(), findsNothing, reason: 'the answer took its place');
      expect(paintedTextsContaining(tester, 'está pensando'), isEmpty);
      gateway.emit('message.complete', {'text': chat.assistantContent});
      await settle(tester, 30);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('leaves when the user stops a turn that was thinking', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      gateway.emit('message.start');
      gateway.emit('reasoning.delta', {'text': 'Primero miro las fotos'});
      await settle(tester);
      expect(indicator(), findsOneWidget, reason: 'precondition: thinking');
      unawaited(chat.cancel());
      await settle(tester, 30);
      expect(chat.isStreaming, isFalse);
      expect(indicator(), findsNothing);
      expect(paintedTextsContaining(tester, 'está pensando'), isEmpty);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('dots move, and stay still with reduced motion', (
      tester,
    ) async {
      List<double> opacities() => tester
          .widgetList<Opacity>(
            find.descendant(of: indicator(), matching: find.byType(Opacity)),
          )
          .map((o) => o.opacity)
          .toList();

      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      await settle(tester);
      final a = opacities();
      await tester.pump(const Duration(milliseconds: 300));
      final b = opacities();
      expect(a, hasLength(3));
      expect(a, isNot(equals(b)), reason: 'the dots animate');
      await tearDownChat(tester, gateway);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final still = _StreamingGateway();
      await startTurn(tester, still);
      still.emit('message.start');
      await settle(tester);
      final c = opacities();
      await tester.pump(const Duration(milliseconds: 300));
      expect(c, hasLength(3));
      expect(opacities(), equals(c), reason: 'reduced motion: static dots');
      await tearDownChat(tester, still);
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
      // The typing row owns «respondiendo»; the bubble keeps «Enviado».
      expect(indicator(), findsOneWidget, reason: 'precondition: replying');
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

    testWidgets('«está respondiendo» appears exactly once while replying', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await startTurn(tester, gateway);
      gateway.emit('message.start');
      await settle(tester);
      expect(indicator(), findsOneWidget, reason: 'precondition: replying');
      expect(
        paintedTextsContaining(tester, 'está respondiendo'),
        hasLength(1),
        reason: 'one owner: the typing row, never the bubble footer too',
      );
      expect(
        find.descendant(
          of: indicator(),
          matching: find.textContaining('está respondiendo'),
        ),
        findsOneWidget,
      );
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
      expect(paintedTextsContaining(tester, 'está pensando'), hasLength(1));
      expect(paintedTextsContaining(tester, 'está respondiendo'), isEmpty);
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
