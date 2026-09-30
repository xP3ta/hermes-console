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
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/main.dart';

// ignore: unused_element
ScrollPosition _primaryVerticalScrollPosition(
  WidgetTester tester,
  Finder candidates,
) {
  final states = tester
      .stateList<ScrollableState>(candidates)
      .where((state) => state.position.axis == Axis.vertical)
      .toList(growable: false);
  expect(states, isNotEmpty);
  final primary = states.reduce(
    (current, candidate) =>
        candidate.position.maxScrollExtent > current.position.maxScrollExtent
        ? candidate
        : current,
  );
  return primary.position;
}

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
  }) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    SharedPreferences.setMockInitialValues({
      ...initialPrefs,
      'onboarding_done': true,
    });
    final prefs = await SharedPreferences.getInstance();
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
      ..internalMessagesForTesting = history ?? _history()
      ..messagesLoaded = true;

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

  Finder transcript() => find.descendant(
    of: find.byType(ChatScrollInteractionGuard),
    matching: find.byType(ListView),
  );

  ScrollController controllerOf(WidgetTester tester) =>
      tester.widget<ListView>(transcript()).controller!;

  /// First historical answer painted inside the visible viewport: the text
  /// the reader is looking at.
  Finder visibleMarker(WidgetTester tester) {
    final viewport = tester.getRect(transcript());
    for (var turn = 0; turn < 60; turn++) {
      final f = find.textContaining('Respuesta histórica $turn.');
      if (f.evaluate().isEmpty) continue;
      final dy = tester.getTopLeft(f.first).dy;
      if (dy >= viewport.top && dy < viewport.bottom - 60) {
        return find.textContaining('Respuesta histórica $turn.');
      }
    }
    throw StateError('no visible historical marker');
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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
  }

  Future<void> tearDownChat(WidgetTester tester, _StreamingGateway g) async {
    await g.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  }

  List<Map<String, dynamic>> remoteTurn(String id) => [
    {
      'id': '$id-a',
      'role': 'assistant',
      'content': List.filled(
        30,
        'Respuesta llegada desde otra superficie.',
      ).join(' '),
    },
    {
      'id': '$id-u',
      'role': 'user',
      'content': 'Pregunta desde otra superficie',
    },
  ];

  group('#1215 viewport stability', () {
    testWidgets('idle transcript hydration keeps the reader anchored', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, history: _history());
      await tester.pump(const Duration(seconds: 1));
      await scrollUp(tester, 300);
      final controller = controllerOf(tester);
      expect(controller.position.pixels, greaterThan(150));
      final marker = visibleMarker(tester);
      final before = tester.getTopLeft(marker).dy;

      // Another surface finished a turn: the durable read prepends two rows
      // while the reader sits in the middle of the history.
      chat.internalMessagesForTesting = [
        ...remoteTurn('remote-1'),
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      await settle(tester);

      expect(
        controller.position.pixels,
        greaterThan(150),
        reason: 'a service hydration must not pull a reader to the bottom',
      );
      expect(marker, findsOneWidget);
      expect(
        tester.getTopLeft(marker).dy,
        closeTo(before, 1.5),
        reason: 'the text being read must not move when rows arrive below it',
      );
      expect(controller.position.pixels, greaterThan(150));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('idle hydration at the bottom still follows new rows', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, history: _history());
      await tester.pump(const Duration(seconds: 1));
      final controller = controllerOf(tester);
      expect(controller.position.pixels, 0);
      chat.internalMessagesForTesting = [
        ...remoteTurn('remote-2'),
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      await settle(tester);
      expect(controller.position.pixels, closeTo(0, 0.5));
      expect(
        find.textContaining('Respuesta llegada desde otra superficie'),
        findsOneWidget,
      );
      await tearDownChat(tester, gateway);
    });
  });

  group('#1215 edge overscroll', () {
    Future<TestGesture> pullPastBottom(WidgetTester tester) async {
      final gesture = await tester.startGesture(tester.getCenter(transcript()));
      for (var step = 0; step < 8; step++) {
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump();
      }
      return gesture;
    }

    Future<List<double>> releaseAndTrace(
      WidgetTester tester,
      TestGesture gesture,
      ScrollController controller,
    ) async {
      await gesture.up();
      final trace = <double>[controller.position.pixels];
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        trace.add(controller.position.pixels);
      }
      return trace;
    }

    void expectSpringSettle(List<double> trace) {
      for (var i = 1; i < trace.length; i++) {
        expect(
          trace[i],
          greaterThanOrEqualTo(trace[i - 1] - 0.01),
          reason: 'the bounce returns towards the edge without reversing',
        );
      }
      expect(trace.last, closeTo(0, 0.5));
      expect(
        trace.where((pixels) => pixels < -0.5).length,
        greaterThan(2),
        reason: 'the overscroll settles over several frames, not in one snap',
      );
    }

    testWidgets('a row arriving mid-bounce does not snap the edge', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, history: _history());
      await tester.pump(const Duration(seconds: 1));
      final controller = controllerOf(tester);
      final gesture = await pullPastBottom(tester);
      final pulled = controller.position.pixels;
      expect(pulled, lessThan(-30), reason: 'precondition: overscrolled');

      chat.internalMessagesForTesting = [
        ...remoteTurn('bounce'),
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        controller.position.pixels,
        closeTo(pulled, 1),
        reason: 'the finger still holds the overscroll after a relayout',
      );
      expectSpringSettle(await releaseAndTrace(tester, gesture, controller));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('streaming growth mid-bounce keeps the overscroll', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, history: _history());
      await tester.pump(const Duration(seconds: 1));
      final controller = controllerOf(tester);
      await chat.send(
        fullText: 'Respuesta larga',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit('message.start');
      gateway.emit('message.delta', {'text': 'Inicio de la respuesta.'});
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      final gesture = await pullPastBottom(tester);
      final pulled = controller.position.pixels;
      expect(pulled, lessThan(-30), reason: 'precondition: overscrolled');

      gateway.emit('message.delta', {
        'text': '\n\n${List.filled(20, 'Texto que crece.').join(' ')}',
      });
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
        expect(
          controller.position.pixels,
          closeTo(pulled, 1),
          reason: 'frame $frame: growth must not throw the held edge away',
        );
      }
      expectSpringSettle(await releaseAndTrace(tester, gesture, controller));
      gateway.emit('message.complete', {'text': chat.assistantContent});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });
  });

  group('#1215 new messages on the jump button', () {
    Finder jumpButton() => find.byKey(const ValueKey('chat-scroll-to-bottom'));

    testWidgets('counts messages that arrive while the reader is away', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, history: _history());
      await tester.pump(const Duration(seconds: 1));
      await scrollUp(tester, 300);
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-visible')),
        findsOneWidget,
      );
      expect(
        find.textContaining('nuevo'),
        findsNothing,
        reason: 'nothing arrived yet',
      );

      chat.internalMessagesForTesting = [
        ...remoteTurn('away-1'),
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      await settle(tester);
      expect(
        find.descendant(of: jumpButton(), matching: find.text('2 nuevos')),
        findsOneWidget,
      );

      chat.internalMessagesForTesting = [
        {'id': 'away-2-a', 'role': 'assistant', 'content': 'Otra respuesta.'},
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      await settle(tester);
      expect(
        find.descendant(of: jumpButton(), matching: find.text('3 nuevos')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Ir al final de la conversación, 3 nuevos'),
        findsOneWidget,
      );

      await tester.tap(jumpButton());
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controllerOf(tester).position.pixels, closeTo(0, 0.5));
      expect(
        find.textContaining('nuevos'),
        findsNothing,
        reason: 'reaching the bottom reads everything',
      );

      // Back up: only what arrives from now on is new.
      await scrollUp(tester, 300);
      chat.internalMessagesForTesting = [
        {'id': 'away-3-a', 'role': 'assistant', 'content': 'Una más.'},
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      await settle(tester);
      expect(
        find.descendant(of: jumpButton(), matching: find.text('1 nuevo')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a streamed reply counts once, not per token', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, history: _history());
      await tester.pump(const Duration(seconds: 1));
      await chat.send(
        fullText: 'Respuesta larga',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit('message.start');
      await settle(tester);
      await scrollUp(tester, 300);
      for (var delta = 0; delta < 5; delta++) {
        gateway.emit('message.delta', {'text': 'Fragmento $delta. '});
        await settle(tester);
      }
      expect(
        find.descendant(of: jumpButton(), matching: find.text('1 nuevo')),
        findsOneWidget,
      );
      gateway.emit('message.complete', {'text': chat.assistantContent});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await settle(tester);
      expect(
        find.descendant(of: jumpButton(), matching: find.text('1 nuevo')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });
  });

  group('#1215 new since you left', () {
    const lastReadKey =
        'chat_last_read_v1.conn-scroll-stress.sess-scroll-stress';
    Finder divider() => find.byKey(const ValueKey('chat-new-since-divider'));

    testWidgets('lands on the first unread message below a divider', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: _history(),
        initialPrefs: const {lastReadKey: 'message:h-a-24'},
      );
      // One landing, then stillness: no second correction frames later.
      final landed = tester.getTopLeft(divider()).dy;
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getTopLeft(divider()).dy,
          landed,
          reason: 'frame $frame: the landing moved after it settled',
        );
      }
      expect(divider(), findsOneWidget);
      expect(
        find.descendant(
          of: divider(),
          matching: find.text('Nuevo desde que saliste'),
        ),
        findsOneWidget,
      );
      final viewport = tester.getRect(transcript());
      final dividerTop = tester.getTopLeft(divider()).dy;
      expect(
        dividerTop,
        closeTo(viewport.top, 1),
        reason: 'the divider lands at the top of the transcript',
      );
      final firstUnread = find.textContaining('Pregunta histórica 25 ');
      expect(firstUnread, findsOneWidget);
      expect(tester.getTopLeft(firstUnread).dy, greaterThan(dividerTop));
      expect(controllerOf(tester).position.pixels, greaterThan(0));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('chat-scroll-to-bottom')),
          matching: find.text('10 nuevos'),
        ),
        findsOneWidget,
        reason: 'every row from the first unread down is still unread',
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    /// Whether the transcript list is actually painted: no concealing
    /// Visibility/Opacity/Offstage between it and the chat screen.
    bool transcriptPainted() {
      final lists = transcript().evaluate();
      if (lists.isEmpty) return false;
      var painted = true;
      lists.first.visitAncestorElements((element) {
        final widget = element.widget;
        if (widget is ChatScreen) return false;
        if ((widget is Visibility && !widget.visible) ||
            (widget is Opacity && widget.opacity == 0) ||
            (widget is Offstage && widget.offstage)) {
          painted = false;
        }
        return true;
      });
      return painted;
    }

    /// Records, after every painted frame, the transcript offset and whether
    /// the reader could see it. Stops recording when the test ends.
    List<({double pixels, bool painted})> recordFrames(WidgetTester tester) {
      final frames = <({double pixels, bool painted})>[];
      var recording = true;
      addTearDown(() => recording = false);
      tester.binding.addPersistentFrameCallback((_) {
        if (!recording || transcript().evaluate().isEmpty) return;
        final controller = controllerOf(tester);
        if (!controller.hasClients) return;
        frames.add((
          pixels: controller.position.pixels,
          painted: transcriptPainted(),
        ));
      });
      return frames;
    }

    /// Pumps until [done] or a generous frame cap. Frame counts are not a
    /// schedule: the landing ends when its condition holds, not at frame N.
    Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
      for (var frame = 0; frame < 240 && !done(); frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets(
      'lands on a first unread row that the lazy list has not built',
      (tester) async {
        final gateway = _StreamingGateway();
        await pumpChat(
          tester,
          gateway,
          history: _history(),
          initialPrefs: const {lastReadKey: 'message:h-a-4'},
        );
        // Wait for the landing itself, not for a fixed number of frames: the
        // walk length depends on row extents, not on a schedule.
        await pumpUntil(
          tester,
          () =>
              divider().evaluate().isNotEmpty &&
              transcriptPainted() &&
              find
                  .descendant(
                    of: find.byKey(const ValueKey('chat-scroll-to-bottom')),
                    matching: find.text('50 nuevos'),
                  )
                  .evaluate()
                  .isNotEmpty,
        );
        expect(
          divider(),
          findsOneWidget,
          reason: 'the chat opens on the divider, far above the bottom',
        );
        final viewport = tester.getRect(transcript());
        expect(tester.getTopLeft(divider()).dy, closeTo(viewport.top, 1));
        expect(find.textContaining('Pregunta histórica 5 '), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('chat-scroll-to-bottom')),
            matching: find.text('50 nuevos'),
          ),
          findsOneWidget,
        );
        // Stillness after landing.
        final landed = tester.getTopLeft(divider()).dy;
        await settle(tester);
        expect(tester.getTopLeft(divider()).dy, landed);
        expect(tester.takeException(), isNull);
        await tearDownChat(tester, gateway);
      },
    );

    testWidgets('landing on an unbuilt first unread row is one visible move', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      late final List<({double pixels, bool painted})> frames;
      frames = recordFrames(tester);
      await pumpChat(
        tester,
        gateway,
        history: _history(),
        initialPrefs: const {lastReadKey: 'message:h-a-4'},
      );
      await pumpUntil(
        tester,
        () =>
            divider().evaluate().isNotEmpty &&
            transcriptPainted() &&
            (tester.getTopLeft(divider()).dy - tester.getRect(transcript()).top)
                    .abs() <=
                1,
      );
      await settle(tester);
      expect(divider(), findsOneWidget);
      expect(
        tester.getTopLeft(divider()).dy,
        closeTo(tester.getRect(transcript()).top, 1),
      );
      // Precondition: the lazy list really had to walk up through several
      // offsets to build the first unread row.
      final offsets = frames.map((f) => f.pixels).toSet();
      expect(offsets.length, greaterThan(3), reason: '$frames');
      // The reader sees the bottom (or nothing) and then the landing: no
      // intermediate screen of the walk is ever painted.
      final landed = frames.last.pixels;
      final seen = [
        for (final frame in frames)
          if (frame.painted) frame.pixels,
      ];
      final firstLanded = seen.indexOf(landed);
      expect(firstLanded, greaterThanOrEqualTo(0));
      expect(
        seen.sublist(0, firstLanded).every((p) => p == seen.first),
        isTrue,
        reason: 'painted offsets before landing: $seen',
      );
      expect(
        seen.sublist(firstLanded).every((p) => p == landed),
        isTrue,
        reason: 'painted offsets after landing: $seen',
      );
      // The transcript is hidden only briefly while it walks.
      expect(
        frames.where((f) => !f.painted).length,
        lessThanOrEqualTo(24),
        reason: 'concealed frames: $frames',
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a first unread row out of the walk budget shows the bottom', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      late final List<({double pixels, bool painted})> frames;
      frames = recordFrames(tester);
      await pumpChat(
        tester,
        gateway,
        history: _history(turns: 400),
        initialPrefs: const {lastReadKey: 'message:h-a-1'},
      );
      await pumpUntil(tester, () => frames.length > 60);
      await settle(tester);
      // The walk gave up: the reader is at the newest message, not left
      // halfway up the history or behind a blank transcript.
      expect(transcriptPainted(), isTrue);
      expect(controllerOf(tester).position.pixels, 0);
      expect(find.textContaining('Respuesta histórica 399.'), findsOneWidget);
      final seen = [
        for (final frame in frames)
          if (frame.painted) frame.pixels,
      ];
      expect(
        seen.every((p) => p == 0),
        isTrue,
        reason: 'painted offsets: $seen',
      );
      expect(
        frames.where((f) => !f.painted).length,
        lessThanOrEqualTo(24),
        reason: 'concealed frames: $frames',
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('stays at the bottom when the unread rows are on screen', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: _history(),
        initialPrefs: const {lastReadKey: 'message:h-a-28'},
      );
      await settle(tester);
      expect(divider(), findsOneWidget);
      expect(controllerOf(tester).position.pixels, 0);
      expect(
        tester.getTopLeft(divider()).dy,
        greaterThanOrEqualTo(tester.getRect(transcript()).top),
      );
      await tearDownChat(tester, gateway);
    });

    testWidgets('no divider without a marker, or when all is read', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: _history());
      await settle(tester);
      expect(divider(), findsNothing);
      expect(controllerOf(tester).position.pixels, 0);
      await tearDownChat(tester, gateway);

      final second = _StreamingGateway();
      await pumpChat(
        tester,
        second,
        history: _history(),
        initialPrefs: const {lastReadKey: 'message:h-a-29'},
      );
      await settle(tester);
      expect(divider(), findsNothing);
      expect(controllerOf(tester).position.pixels, 0);
      await tearDownChat(tester, second);
    });

    Future<Map<String, Object>> streamReplyAndLeave(
      WidgetTester tester, {
      required String initialMarker,
    }) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(
        tester,
        gateway,
        history: _history(),
        initialPrefs: {lastReadKey: initialMarker},
      );
      await settle(tester);
      await chat.send(
        fullText: 'Pregunta enviada ahora',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit('message.start');
      gateway.emit('message.delta', {'text': 'Respuesta vista en vivo.'});
      await settle(tester);
      gateway.emit('message.complete', {'text': chat.assistantContent});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await settle(tester);
      Navigator.of(tester.element(transcript())).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final prefs = await SharedPreferences.getInstance();
      final stored = <String, Object>{
        for (final key in prefs.getKeys())
          if (key.startsWith(lastReadKey)) key: prefs.get(key)!,
      };
      await tearDownChat(tester, gateway);
      return stored;
    }

    // The turn the reader just watched, as Hermes stores it (durable ids).
    List<Map<String, dynamic>> watchedTurn() => [
      {
        'id': 'live-a',
        'role': 'assistant',
        'content': 'Respuesta vista en vivo.',
      },
      {'id': 'live-u', 'role': 'user', 'content': 'Pregunta enviada ahora'},
    ];

    testWidgets('a reply watched live is read on the next entry', (
      tester,
    ) async {
      final stored = await streamReplyAndLeave(
        tester,
        initialMarker: 'message:h-a-24',
      );
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: [...watchedTurn(), ..._history()],
        initialPrefs: stored,
      );
      await settle(tester);
      expect(
        divider(),
        findsNothing,
        reason: 'the prompt and the reply seen live are not news',
      );
      expect(controllerOf(tester).position.pixels, 0);
      await tearDownChat(tester, gateway);
    });

    testWidgets('only rows after a reply watched live are new', (tester) async {
      final stored = await streamReplyAndLeave(
        tester,
        initialMarker: 'message:h-a-24',
      );
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: [...remoteTurn('later'), ...watchedTurn(), ..._history()],
        initialPrefs: stored,
      );
      await settle(tester);
      expect(divider(), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('chat-scroll-to-bottom')),
          matching: find.text('2 nuevos'),
        ),
        findsOneWidget,
      );
      final dividerTop = tester.getTopLeft(divider()).dy;
      final firstUnread = find.text('Pregunta desde otra superficie');
      expect(firstUnread, findsOneWidget);
      expect(tester.getTopLeft(firstUnread).dy, greaterThan(dividerTop));
      // The prompt sent before leaving sits above the divider (possibly
      // scrolled out of the built range).
      final sent = find.text('Pregunta enviada ahora', skipOffstage: false);
      if (sent.evaluate().isNotEmpty) {
        expect(tester.getTopLeft(sent).dy, lessThan(dividerTop));
      }
      await tearDownChat(tester, gateway);
    });

    testWidgets('leaving the chat stores the newest message as read', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: _history(),
        initialPrefs: const {lastReadKey: 'message:h-a-24'},
      );
      await settle(tester);
      Navigator.of(tester.element(transcript())).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(lastReadKey), 'message:h-a-29');
      await tearDownChat(tester, gateway);
    });
  });
}
