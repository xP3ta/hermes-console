// Chat stability (1.4.0): a finished answer keeps what it showed of its turn
// when a re-read brings it back poorer, the text being read does not move when
// the line above it is redrawn, and a selection survives a new map of the
// same text.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/turn_activity_memory.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/pinned_prompt_prefs.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/session_reconciler.dart'
    show assistantActivityTraceKey;
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
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
    runtimeSessionId: 'runtime-scroll-stress',
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
    runtimeSessionId: 'runtime-scroll-stress',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-scroll-stress',
    storedSessionId: 'sess-scroll-stress',
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
        sessionId: 'runtime-scroll-stress',
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
  id: 'conn-scroll-stress',
  label: 'Scroll stress',
  host: 'example.test',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-scroll-stress',
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

const _stepsKey = assistantActivityTraceKey;

List<Map<String, dynamic>> _threeSteps() => <Map<String, dynamic>>[
  for (var i = 1; i <= 3; i++)
    <String, dynamic>{
      'kind': 'tool',
      'label': 'terminal',
      'status': 'completed',
      'id': 'call-$i',
      'detail': 'paso $i',
    },
];

const _short = 'Frase seleccionable de la respuesta terminada.';

/// The body of the answer: many paragraphs, so a reader can sit inside it.
String _body() => [
  for (var i = 0; i < 40; i++)
    'Párrafo $i de la respuesta terminada. Este texto ocupa varias líneas '
        'para que el lector pueda quedarse a mitad de la respuesta.',
].join('\n\n');

/// Newest first: the answer of one turn and its prompt, then older turns.
List<Map<String, dynamic>> _transcript({
  bool steps = true,
  bool ids = true,
  String body = '',
  List<Map<String, dynamic>>? older,
}) => [
  {
    if (ids) 'id': 'asst-final',
    'role': 'assistant',
    'content': body.isEmpty ? _body() : body,
    if (steps) _stepsKey: _threeSteps(),
  },
  {
    if (ids) 'id': 'user-final',
    'role': 'user',
    'content': 'Pregunta del turno con herramientas',
  },
  ...(older ?? _older()),
];

List<Map<String, dynamic>> _older({int turns = 6}) => [
  for (var turn = turns - 1; turn >= 0; turn--) ...[
    {
      'id': 'old-a-$turn',
      'role': 'assistant',
      'content': 'Respuesta histórica $turn. Texto de relleno del historial.',
    },
    {
      'id': 'old-u-$turn',
      'role': 'user',
      'content': 'Pregunta histórica $turn.',
    },
  ],
];

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
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  Future<ActiveChat> pumpChat(
    WidgetTester tester,
    _StreamingGateway gateway,
    List<Map<String, dynamic>> history,
  ) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    await PinnedPromptPrefs.load(prefs);
    addTearDown(() => PinnedPromptPrefs.debugUse(null));
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService();
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: 'sess-scroll-stress',
      sessionTitle: 'Prueba de scroll',
      api: _safeApi(),
      desktopGateway: gateway,
      disableForegroundKeepAlive: true,
    );
    chat
      ..internalMessagesForTesting = history
      ..messagesLoaded = true;
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
    final navigatorContext = tester.element(find.byType(Navigator).first);
    Navigator.of(navigatorContext).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(seconds: 1));
    return chat;
  }

  Finder transcript() => find.descendant(
    of: find.byType(ChatScrollInteractionGuard),
    matching: find.byType(ListView),
  );

  ScrollController controllerOf(WidgetTester tester) =>
      tester.widget<ListView>(transcript()).controller!;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
  }

  Future<void> scrollUp(WidgetTester tester, double distance) async {
    final gesture = await tester.startGesture(tester.getCenter(transcript()));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(Offset(0, distance));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> tearDownChat(WidgetTester tester, _StreamingGateway g) async {
    await g.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  }

  /// A paragraph of the answer that is on screen: what the reader reads.
  Finder visibleParagraph(WidgetTester tester) {
    final viewport = tester.getRect(transcript());
    for (var i = 0; i < 40; i++) {
      final f = find.textContaining('Párrafo $i de la respuesta');
      if (f.evaluate().isEmpty) continue;
      final dy = tester.getTopLeft(f.first).dy;
      if (dy >= viewport.top + 160 && dy < viewport.bottom - 200) return f;
    }
    throw StateError('no visible paragraph');
  }

  final line = find.byKey(const ValueKey('chat-inline-activity-text'));

  int carried(WidgetTester tester) =>
      (tester.state(
            find.byType(ChatScreen),
          ) as dynamic).debugTurnActivityCarried
          as int;

  group('a finished answer keeps its «Trabajó · N pasos» line', () {
    testWidgets('a re-read without the steps does not take the line away', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, _transcript());
      expect(line, findsOneWidget);
      expect(
        tester.widget<Text>(line).data,
        contains('3 comandos'),
        reason: 'the line says how many steps the turn took',
      );
      final before = tester.getTopLeft(find.textContaining('Párrafo 0 de')).dy;
      final shifts = ChatAnswerAnchorRenderBox.debugHeightChanges;

      // The history comes back from a source that only holds the final text.
      chat.internalMessagesForTesting = _transcript(steps: false);
      chat.debugEmitMessagesHydrated();
      await settle(tester);

      expect(
        ChatAnswerAnchorRenderBox.debugHeightChanges,
        shifts,
        reason: 'no answer changed height',
      );
      expect(line, findsOneWidget, reason: 'seen once, not lost');
      expect(
        tester.getTopLeft(find.textContaining('Párrafo 0 de')).dy,
        closeTo(before, 1),
        reason: 'the text under the line does not move',
      );
      expect(carried(tester), greaterThan(0));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a re-read with other steps keeps the richer turn', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, _transcript());
      final before = tester.getTopLeft(find.textContaining('Párrafo 0 de')).dy;

      final one = _transcript();
      one.first[_stepsKey] = [_threeSteps().first];
      chat.internalMessagesForTesting = one;
      chat.debugEmitMessagesHydrated();
      await settle(tester);

      expect(line, findsOneWidget);
      expect(tester.widget<Text>(line).data, contains('3 comandos'));
      expect(
        tester.getTopLeft(find.textContaining('Párrafo 0 de')).dy,
        closeTo(before, 1),
      );
      await tearDownChat(tester, gateway);
    });

    testWidgets('the answer a turn closed here keeps it once it is saved', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      // First the row as the turn left it on this device: no durable id.
      final chat = await pumpChat(tester, gateway, _transcript(ids: false));
      expect(line, findsOneWidget);

      // Then the saved copy: ids, same prompt and text, no steps.
      chat.internalMessagesForTesting = _transcript(steps: false);
      chat.debugEmitMessagesHydrated();
      await settle(tester);

      expect(line, findsOneWidget);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a re-read that brings more steps shows them', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, _transcript(steps: false));
      expect(line, findsNothing);

      chat.internalMessagesForTesting = _transcript();
      chat.debugEmitMessagesHydrated();
      await settle(tester);

      expect(line, findsOneWidget);
      await tearDownChat(tester, gateway);
    });

    testWidgets('the reader inside the answer stays on the text they read', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, _transcript());
      await scrollUp(tester, 300);
      expect(controllerOf(tester).position.pixels, greaterThan(150));
      final marker = visibleParagraph(tester);
      final before = tester.getTopLeft(marker).dy;

      chat.internalMessagesForTesting = _transcript(steps: false);
      chat.debugEmitMessagesHydrated();
      await settle(tester);

      expect(marker, findsOneWidget);
      expect(
        tester.getTopLeft(marker).dy,
        closeTo(before, 1),
        reason: 'no jump of the text being read',
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });
  });

  group('the text being read stays put when the answer\'s head changes', () {
    testWidgets('the line arriving on a re-read does not push the reader', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, _transcript(steps: false));
      await scrollUp(tester, 300);
      expect(controllerOf(tester).position.pixels, greaterThan(150));
      final marker = visibleParagraph(tester);
      final before = tester.getTopLeft(marker).dy;

      // The same answer, now with the turn's line over it (+ its height).
      chat.internalMessagesForTesting = _transcript();
      chat.debugEmitMessagesHydrated();
      await settle(tester);

      expect(line, findsOneWidget);
      expect(marker, findsOneWidget);
      expect(
        tester.getTopLeft(marker).dy,
        closeTo(before, 1),
        reason: 'the head grew; the text under it stays where it was',
      );
      await tearDownChat(tester, gateway);
    });
  });

  group('the memory of a turn', () {
    Map<String, dynamic> row({
      String? id,
      int steps = 3,
      String text = 'Respuesta',
    }) => {
      'id': ?id,
      'role': 'assistant',
      'content': text,
      if (steps > 0) _stepsKey: _threeSteps().take(steps).toList(),
    };

    test('never degrades by id, and learns richer rows', () {
      final memory = TurnActivityMemory();
      expect(memory.settle(row(id: 'a')), isNotNull);
      final poorer = row(id: 'a', steps: 0);
      final shown = memory.settle(poorer);
      expect(shown[_stepsKey], hasLength(3));
      expect(identical(memory.settle(poorer), shown), isTrue);
      final richer = row(id: 'a', steps: 3)
        ..[_stepsKey] = [..._threeSteps(), _threeSteps().first];
      expect(identical(memory.settle(richer), richer), isTrue);
      expect(memory.settle(row(id: 'a', steps: 1))[_stepsKey], hasLength(4));
    });

    test('text never joins two rows that both have an id', () {
      final memory = TurnActivityMemory();
      memory.settle(row(id: 'a'), textKey: 'k');
      final other = row(id: 'b', steps: 0);
      expect(identical(memory.settle(other, textKey: 'k'), other), isTrue);
    });

    test('a saved copy is paired with the local answer by its text', () {
      final memory = TurnActivityMemory();
      memory.settle(row(), textKey: 'k');
      final saved = row(id: 'a', steps: 0);
      expect(memory.settle(saved, textKey: 'k')[_stepsKey], hasLength(3));
      expect(memory.settle(row(id: 'a', steps: 0))[_stepsKey], hasLength(3));
    });

    test('keeps the measured time of the turn it carries', () {
      final memory = TurnActivityMemory();
      memory.settle({...row(id: 'a'), '_activity_duration_seconds': 42});
      final shown = memory.settle(row(id: 'a', steps: 0));
      expect(shown['_activity_duration_seconds'], 42);
    });

    test('the same steps without the measured time get it back', () {
      final memory = TurnActivityMemory();
      memory.settle({...row(id: 'a'), '_activity_duration_seconds': 72});
      final saved = row(id: 'a');
      final shown = memory.settle(saved);
      expect(shown['_activity_duration_seconds'], 72);
      expect(shown[_stepsKey], saved[_stepsKey]);
      expect(identical(memory.settle(saved), shown), isTrue);
      // The local answer of a turn (no id) paired with its saved copy.
      final local = TurnActivityMemory();
      local.settle({...row(), '_activity_duration_seconds': 72}, textKey: 'k');
      expect(
        local.settle(row(id: 'b'), textKey: 'k')['_activity_duration_seconds'],
        72,
      );
    });

    test('a running call weighs nothing: it is not drawn once over', () {
      final memory = TurnActivityMemory();
      memory.settle(row(id: 'a'));
      final stale = row(id: 'a', steps: 0)
        ..[_stepsKey] = [
          {..._threeSteps().first, 'status': 'running'},
        ];
      expect(memory.settle(stale)[_stepsKey], hasLength(3));
    });

    test('is bounded', () {
      final memory = TurnActivityMemory(capacity: 4);
      for (var i = 0; i < 20; i++) {
        memory.settle(row(id: 'r$i'));
      }
      final fresh = row(id: 'r0', steps: 0);
      expect(identical(memory.settle(fresh), fresh), isTrue);
    });
  });

  group('selection and rows that survive a re-read', () {
    test('the identity of a selection is the text, not the map', () {
      final a = {'role': 'assistant', 'content': 'misma frase', 'x': 1};
      final b = {'role': 'assistant', 'content': 'misma frase', 'x': 2};
      expect(chatSelectionIdentity(a), chatSelectionIdentity(b));
      expect(
        chatSelectionIdentity({...a, 'content': 'otra frase'}),
        isNot(chatSelectionIdentity(a)),
      );
      expect(chatSelectionIdentity({'id': 'm1'}), 'm1');
    });

    testWidgets('a held selection survives a re-read of the same text', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      // The answer as the screen holds it before it has a durable id.
      final chat = await pumpChat(
        tester,
        gateway,
        _transcript(ids: false, steps: false, body: _short),
      );
      final phrase = find.textContaining('Frase seleccionable');
      await tester.longPress(phrase.first);
      await tester.pumpAndSettle();
      SelectableRegionState region() => tester
          .state<SelectionAreaState>(
            find.ancestor(
              of: find.textContaining('Frase seleccionable').first,
              matching: find.byType(SelectionArea),
            ),
          )
          .selectableRegion;
      expect(
        region().selectionOverlay?.toolbarIsVisible,
        isTrue,
        reason: 'precondition: a selection is held',
      );

      // The same answer, as new maps.
      chat.internalMessagesForTesting = [
        for (final row in _transcript(ids: false, steps: false, body: _short))
          <String, dynamic>{...row},
      ];
      chat.debugEmitMessagesHydrated();
      await settle(tester);

      expect(
        region().selectionOverlay?.toolbarIsVisible,
        isTrue,
        reason: 'the reader is still holding the text',
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a held selection is told to the chat, and let go', (
      tester,
    ) async {
      final hold = ChatSelectionHold();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatSelectionHoldScope(
              hold: hold,
              child: const ChatMessageSelectionArea(
                child: Text('una frase para sostener'),
              ),
            ),
          ),
        ),
      );
      expect(hold.active, isFalse);
      await tester.longPress(find.text('una frase para sostener'));
      await tester.pumpAndSettle();
      expect(hold.active, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(hold.active, isFalse, reason: 'a closed message holds nothing');
    });
  });
}
