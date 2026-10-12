import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/widgets/chat/chat_notch.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/pinned_prompt_prefs.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/utils/unread_rules.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

import 'support/bottom_transparency.dart';

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
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
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
      sessionId: 'sess-scroll-stress',
      sessionTitle: 'Prueba de scroll',
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

  Finder transcript() => find.descendant(
    of: find.byType(ChatScrollInteractionGuard),
    matching: find.byType(ListView),
  );

  /// fh1215: the transcript runs under the floating header; what the reader
  /// can see starts below the header's inset.
  double readableTop(WidgetTester tester) =>
      tester.getRect(transcript()).top +
      FloatingChatHeader.insetFor(tester.element(transcript()));

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

  // ct1215: the live turn tells itself in the transcript (status, thought,
  // tool in hand, plan), so its row grows before the reply has any text.
  group('ct1215 the live turn grows without moving the reader', () {
    Map<String, dynamic> plan() => {
      'revision': 1,
      'todos': [
        for (final (index, status) in const [
          'completed',
          'completed',
          'in_progress',
          'pending',
          'pending',
        ].indexed)
          {
            'id': '${index + 1}',
            'content': 'Tarea ${index + 1} del plan',
            'status': status,
          },
      ],
    };

    /// The steps of a working turn, each one making its row taller.
    List<void Function()> work(_StreamingGateway gateway) => [
      () => gateway.emit('reasoning.delta', {
        'text': List.filled(40, 'Pienso en cómo probarlo.').join(' '),
      }),
      () => gateway.emit('tool.start', const {
        'tool_id': 'call-1',
        'name': 'terminal',
        'args': {'command': 'df -h'},
      }),
      () => gateway.emit('tool.start', const {
        'tool_id': 'call-todo',
        'name': 'todo',
      }),
      () => gateway.emit('todo.updated', plan()),
      () => gateway.emit('tool.complete', const {
        'tool_id': 'call-1',
        'name': 'terminal',
      }),
    ];

    Finder liveLines() =>
        find.byKey(const ValueKey('thinking-trace-live'), skipOffstage: false);

    Future<ActiveChat> startTurn(
      WidgetTester tester,
      _StreamingGateway gateway, {
      int turns = 30,
    }) async {
      final chat = await pumpChat(
        tester,
        gateway,
        history: _history(turns: turns),
      );
      await tester.pump(const Duration(seconds: 1));
      await chat.send(
        fullText: 'Prueba también la lista de tareas',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit('message.start');
      await settle(tester);
      return chat;
    }

    testWidgets('a reader scrolled up stays put from the first line to the '
        'folded turn', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      await scrollUp(tester, 300);
      final controller = controllerOf(tester);
      expect(controller.position.pixels, greaterThan(150));
      final marker = visibleMarker(tester);
      final before = tester.getTopLeft(marker).dy;

      final steps = work(gateway);
      for (var index = 0; index < steps.length; index++) {
        steps[index]();
        await settle(tester);
        expect(
          tester.getTopLeft(marker).dy,
          closeTo(before, 1.5),
          reason: 'step $index moved the text being read',
        );
      }
      expect(
        tester.getSize(liveLines()).height,
        greaterThan(150),
        reason: 'precondition: the live turn really grew under the reader',
      );

      // First token: the live host takes the place of the row.
      gateway.emit('message.delta', {'text': 'Las tres partes funcionan.'});
      await settle(tester);
      expect(
        tester.getTopLeft(marker).dy,
        closeTo(before, 1.5),
        reason: 'the first token moved the text being read',
      );
      gateway.emit('message.delta', {
        'text': '\n\n${List.filled(30, 'Texto que crece.').join(' ')}',
      });
      await settle(tester);
      expect(tester.getTopLeft(marker).dy, closeTo(before, 1.5));

      // The turn ends and its lines fold.
      gateway.emit('message.complete', {'text': chat.assistantContent});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await settle(tester);
      expect(
        tester.getTopLeft(marker).dy,
        closeTo(before, 1.5),
        reason: 'folding the turn moved the text being read',
      );
      expect(controller.position.pixels, greaterThan(150));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a reader scrolled up is not moved by a turn that ends '
        'without text', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      await scrollUp(tester, 300);
      final marker = visibleMarker(tester);
      final before = tester.getTopLeft(marker).dy;
      for (final step in work(gateway)) {
        step();
        await settle(tester);
      }
      expect(tester.getTopLeft(marker).dy, closeTo(before, 1.5));
      final pixels = controllerOf(tester).position.pixels;
      gateway.emit('error', {'message': 'Boom'});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await settle(tester);
      expect(
        controllerOf(tester).position.pixels,
        lessThan(pixels - 100),
        reason: 'precondition: the live row folded under the reader',
      );
      expect(chat.isStreaming, isFalse);
      expect(
        tester.getTopLeft(marker).dy,
        closeTo(before, 1.5),
        reason: 'the failed turn folding moved the text being read',
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('at the bottom the growing turn stays in view and followed', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      final controller = controllerOf(tester);
      expect(controller.position.pixels, closeTo(0, 0.5));
      for (final step in work(gateway)) {
        step();
        await settle(tester);
        expect(controller.position.pixels, closeTo(0, 0.5));
      }
      final viewport = tester.getRect(transcript());
      final lines = tester.getRect(liveLines());
      // The thought is whole: once it is taller than the screen its first
      // lines go up and away, and what is being written stays in view.
      expect(lines.height, greaterThan(150));
      expect(lines.bottom, lessThanOrEqualTo(viewport.bottom));
      // …above the composer and what floats on it, never under them.
      final bars = tester.getRect(
        find.byKey(const ValueKey('chat-bottom-bars')),
      );
      expect(lines.bottom, lessThanOrEqualTo(bars.top));
      expect(
        find.textContaining('Pienso en cómo probarlo', findRichText: true),
        findsWidgets,
        reason: 'the thought being written is on screen',
      );
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-hidden')),
        findsOneWidget,
        reason: 'the reader never left the bottom',
      );
      // The reply that grows under it is followed too, and each of its
      // lines lands above the composer.
      for (var line = 1; line <= 12; line++) {
        gateway.emit('message.delta', {
          'text': 'Línea $line de la respuesta, que sigue creciendo.\n\n',
        });
        await settle(tester);
        expect(controller.position.pixels, closeTo(0, 0.5));
        final newest = tester.getRect(
          find.textContaining('Línea $line de la respuesta').last,
        );
        expect(
          newest.bottom,
          lessThanOrEqualTo(bars.top),
          reason: 'line $line of the reply is above the composer',
        );
      }
      gateway.emit('message.complete', {'text': chat.assistantContent});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await settle(tester);
      expect(controller.position.pixels, closeTo(0, 0.5));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('a short chat: the turn that outgrows the screen is followed, '
        'and its newest line is never under the composer', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway, turns: 1);
      final controller = controllerOf(tester);
      final bars = tester.getRect(
        find.byKey(const ValueKey('chat-bottom-bars')),
      );
      for (final step in work(gateway)) {
        step();
        await settle(tester);
        expect(controller.position.pixels, closeTo(0, 0.5));
        expect(tester.getRect(liveLines()).bottom, lessThanOrEqualTo(bars.top));
      }
      for (var line = 1; line <= 14; line++) {
        gateway.emit('message.delta', {
          'text': 'Línea $line de la respuesta, que sigue creciendo.\n\n',
        });
        await settle(tester);
        expect(
          controller.position.pixels,
          closeTo(0, 0.5),
          reason: 'line $line: the reader is kept at the bottom',
        );
        final newest = tester.getRect(
          find.textContaining('Línea $line de la respuesta').last,
        );
        expect(
          newest.bottom,
          lessThanOrEqualTo(bars.top),
          reason: 'line $line of the reply is above the composer',
        );
      }
      expect(
        controller.position.maxScrollExtent,
        greaterThan(0),
        reason: 'the turn outgrew the screen',
      );
      gateway.emit('message.complete', {'text': chat.assistantContent});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await settle(tester);
      expect(controller.position.pixels, closeTo(0, 0.5));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('the jump button brings a reader back to the growing turn', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      await scrollUp(tester, 300);
      for (final step in work(gateway)) {
        step();
        await settle(tester);
      }
      final jump = find.byKey(const ValueKey('chat-scroll-to-bottom'));
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-visible')),
        findsOneWidget,
      );
      await tester.tap(jump);
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      final controller = controllerOf(tester);
      expect(controller.position.pixels, closeTo(0, 0.5));
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-hidden')),
        findsOneWidget,
      );
      // Back at the bottom the turn is followed again as it grows.
      gateway.emit('reasoning.delta', {
        'text': '\n\n${List.filled(40, 'Sigo pensando.').join(' ')}',
      });
      await settle(tester);
      expect(controller.position.pixels, closeTo(0, 0.5));
      gateway.emit('message.complete', {'text': 'Hecho.'});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('its timers and its tokens rebuild no older row', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      for (final step in work(gateway).take(4)) {
        step();
      }
      await settle(tester);

      // Every element of every row except the live turn's.
      Set<Element> olderRows() {
        final list = tester.element(
          find.descendant(of: transcript(), matching: find.byType(SliverList)),
        );
        final live = find
            .byKey(const ValueKey('turn-status-line'))
            .evaluate()
            .single;
        final found = <Element>{};
        void collect(Element element) {
          found.add(element);
          element.visitChildren(collect);
        }

        list.visitChildren((row) {
          var holdsLive = false;
          live.visitAncestorElements((ancestor) {
            holdsLive = identical(ancestor, row);
            return !holdsLive;
          });
          if (!holdsLive) collect(row);
        });
        return found;
      }

      var older = olderRows();
      expect(older, isNotEmpty);
      var olderRebuilds = 0;
      var liveRebuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (older.contains(element)) {
          olderRebuilds++;
        } else {
          liveRebuilds++;
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      // Three seconds of a running tool: the status line and the tool row
      // count them, and nothing else is rebuilt for it.
      for (var second = 0; second < 3; second++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(liveRebuilds, greaterThan(0), reason: 'the timers ticked');
      expect(olderRebuilds, 0, reason: 'a timer tick rebuilt older rows');

      // The first token swaps the row for the live host (one structural
      // rebuild); from there on each token touches the live host only.
      debugOnRebuildDirtyWidget = null;
      gateway.emit('message.delta', {'text': 'Las tres partes funcionan.'});
      await settle(tester);
      older = olderRows();
      olderRebuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (older.contains(element)) olderRebuilds++;
      };
      for (var token = 0; token < 6; token++) {
        gateway.emit('message.delta', {'text': ' Más texto $token.'});
        await tester.pump(const Duration(milliseconds: 40));
      }
      await settle(tester);
      debugOnRebuildDirtyWidget = null;
      expect(olderRebuilds, 0, reason: 'a token rebuilt older rows');

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
      // QA 9489: the owner's own question (from another surface) is not
      // news; only the reply counts.
      expect(
        find.descendant(of: jumpButton(), matching: find.text('1 nuevo')),
        findsOneWidget,
      );

      chat.internalMessagesForTesting = [
        {'id': 'away-2-a', 'role': 'assistant', 'content': 'Otra respuesta.'},
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      await settle(tester);
      expect(
        find.descendant(of: jumpButton(), matching: find.text('2 nuevos')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Ir al final de la conversación, 2 nuevos'),
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
      final dividerTop = tester.getTopLeft(divider()).dy;
      expect(
        dividerTop,
        closeTo(readableTop(tester) + 48, 1),
        reason:
            'the divider lands at the top of the transcript, under '
            '~1 row (48 dp) of context',
      );
      // fh1215: below the floating header's pill, never under it.
      expect(
        dividerTop,
        greaterThan(
          tester
              .getRect(find.byKey(const ValueKey('chat-activity-pill')))
              .bottom,
        ),
      );
      // QA 9489: the first news is the reply (the owner's own question
      // sits above the divider), and landing shows no count: the pill is
      // only for what arrives while reading.
      final firstUnread = find.textContaining('Respuesta histórica 25.');
      expect(firstUnread, findsOneWidget);
      expect(tester.getTopLeft(firstUnread).dy, greaterThan(dividerTop));
      expect(controllerOf(tester).position.pixels, greaterThan(0));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('chat-scroll-to-bottom')),
          matching: find.textContaining('nuevo'),
        ),
        findsNothing,
        reason: 'no pill count for news from while away',
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
              (tester.getTopLeft(divider()).dy - (readableTop(tester) + 48))
                      .abs() <=
                  1,
        );
        expect(
          divider(),
          findsOneWidget,
          reason: 'the chat opens on the divider, far above the bottom',
        );
        expect(
          tester.getTopLeft(divider()).dy,
          closeTo(readableTop(tester) + 48, 1),
        );
        expect(find.textContaining('Respuesta histórica 5.'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('chat-scroll-to-bottom')),
            matching: find.textContaining('nuevo'),
          ),
          findsNothing,
          reason: 'QA 9489: no pill count for news from while away',
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
            (tester.getTopLeft(divider()).dy - (readableTop(tester) + 48))
                    .abs() <=
                1,
      );
      await settle(tester);
      expect(divider(), findsOneWidget);
      expect(
        tester.getTopLeft(divider()).dy,
        closeTo(readableTop(tester) + 48, 1),
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

    /// Divider top relative to the transcript top.
    double dividerFromTop(WidgetTester tester) =>
        tester.getTopLeft(divider()).dy - readableTop(tester);

    testWidgets('QA 9491: rows reflowing after the landing keep the divider '
        'at the top', (tester) async {
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: _history(),
        initialPrefs: const {lastReadKey: 'message:h-a-24'},
      );
      await settle(tester);
      expect(dividerFromTop(tester), closeTo(48, 2));
      // Rows above AND below the divider change height after the first
      // frame (previews, markdown): bigger, then smaller than at landing.
      for (final scale in [1.6, 0.8]) {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await settle(tester);
        expect(
          dividerFromTop(tester),
          closeTo(48, 2),
          reason: 'text scale $scale moved the divider',
        );
        expect(
          find.textContaining('Respuesta histórica 25.'),
          findsOneWidget,
          reason: 'the first new reply stays right below the divider',
        );
      }
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('QA 9491: a reply streaming at the bottom never overrides '
        'the landing', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(
        tester,
        gateway,
        history: _history(),
        initialPrefs: const {lastReadKey: 'message:h-a-24'},
        // The reply is already being written when the chat opens.
        beforeOpen: (chat) async {
          await chat.send(
            fullText: 'Sigue escribiendo',
            model: 'hermes-agent',
            history: chat.buildHistory(),
          );
          gateway.emit('message.start');
          gateway.emit('message.delta', {'text': 'Empieza la respuesta. '});
          await tester.pump(const Duration(milliseconds: 33));
        },
      );
      await settle(tester);
      expect(chat.isStreaming, isTrue, reason: 'precondition: a live reply');
      expect(divider(), findsOneWidget);
      expect(dividerFromTop(tester), closeTo(48, 2));
      for (var delta = 0; delta < 12; delta++) {
        gateway.emit('message.delta', {
          'text': '${List.filled(12, 'Texto en vivo $delta.').join(' ')}\n\n',
        });
        await tester.pump(const Duration(milliseconds: 33));
        expect(
          dividerFromTop(tester),
          closeTo(48, 2),
          reason: 'delta $delta moved the divider',
        );
      }
      gateway.emit('message.complete', {'text': chat.assistantContent});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await settle(tester);
      expect(dividerFromTop(tester), closeTo(48, 2));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('QA 9491: the landing lets go once the reader scrolls', (
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
      expect(dividerFromTop(tester), closeTo(48, 2));
      await scrollUp(tester, 200);
      final moved = dividerFromTop(tester);
      expect(moved, greaterThan(48 + 150), reason: 'the drag moved the list');
      await settle(tester);
      expect(
        dividerFromTop(tester),
        closeTo(moved, 1),
        reason: 'no snap back to the landing after a scroll',
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
          matching: find.textContaining('nuevo'),
        ),
        findsNothing,
        reason: 'QA 9489: no pill count for news from while away',
      );
      final dividerTop = tester.getTopLeft(divider()).dy;
      // The first news is the reply; the owner's own question from another
      // surface is not news and stays above the divider.
      final firstUnread = find.textContaining(
        'Respuesta llegada desde otra superficie',
      );
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

  group('#114 prompts and sticky prompt', () {
    Finder jumpButton() => find.byKey(const ValueKey('chat-scroll-to-bottom'));
    Finder sticky() => find.byKey(const ValueKey('chat-sticky-prompt'));

    List<Map<String, dynamic>> longReplyHistory() => [
      {
        'id': 'long-a',
        'role': 'assistant',
        'content': List.filled(
          90,
          'Texto de una respuesta muy larga que ocupa varias pantallas.',
        ).join('\n\n'),
      },
      {'id': 'long-u', 'role': 'user', 'content': 'Pregunta larga del turno'},
      ..._history(turns: 6, prefix: 'older'),
    ];

    Future<void> openPrompts(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('chat-notch')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Search and Ir a sit above Session, so Prompts may start below the
      // fold of the lazily built sheet list: drag the sheet until it shows.
      final row = find.byKey(const ValueKey('chat-control-prompts'));
      final list = find.byKey(const ValueKey('chat-control-sheet'));
      for (var i = 0; i < 20; i++) {
        if (row.evaluate().isNotEmpty &&
            tester.getRect(list).contains(tester.getCenter(row))) {
          break;
        }
        await tester.drag(list, const Offset(0, -80));
        await tester.pump();
      }
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    // The sheet list builds rows lazily and `scrollUntilVisible` judges
    // visibility against the whole screen, so drag until the row is inside
    // the sheet itself.
    Future<void> scrollSheetTo(WidgetTester tester, Finder target) async {
      final sheet = find.byKey(const ValueKey('chat-prompt-sheet'));
      final list = find.descendant(of: sheet, matching: find.byType(ListView));
      for (var i = 0; i < 40; i++) {
        if (target.evaluate().isNotEmpty) {
          final y = tester.getCenter(target.last).dy;
          final box = tester.getRect(sheet);
          if (y > box.top + 60 && y < box.bottom - 30) return;
        }
        await tester.drag(list, const Offset(0, -80));
        await tester.pump();
      }
    }

    testWidgets('the sticky prompt shows while its reply spans the top', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: longReplyHistory());
      await settle(tester);
      expect(sticky(), findsOneWidget);
      expect(
        find.descendant(
          of: sticky(),
          matching: find.textContaining('Pregunta larga del turno'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('the sticky prompt stays hidden when its bubble is on screen', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: [
          {'id': 'short-a', 'role': 'assistant', 'content': 'Respuesta corta'},
          {'id': 'short-u', 'role': 'user', 'content': 'Pregunta corta'},
        ],
      );
      await settle(tester);
      expect(sticky(), findsNothing);
      await tearDownChat(tester, gateway);
    });

    testWidgets('tapping the sticky prompt reveals the prompt', (tester) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: longReplyHistory());
      await settle(tester);
      await tester.tap(sticky());
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await settle(tester);
      expect(
        find.descendant(
          of: transcript(),
          matching: find.text('Pregunta larga del turno'),
        ),
        findsOneWidget,
      );
      expect(sticky(), findsNothing);
      await tearDownChat(tester, gateway);
    });

    testWidgets('Prompts lists the loaded prompts and reveals the chosen one', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: _history());
      await settle(tester);
      await openPrompts(tester);
      final sheet = find.byKey(const ValueKey('chat-prompt-sheet'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(
          of: sheet,
          matching: find.text('Pregunta histórica 29 con contexto adicional.'),
        ),
        findsOneWidget,
      );
      final target = find.descendant(
        of: sheet,
        matching: find.text('Pregunta histórica 20 con contexto adicional.'),
      );
      await scrollSheetTo(tester, target);
      await tester.tap(target);
      for (var frame = 0; frame < 80; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(sheet, findsNothing);
      expect(
        find.descendant(
          of: transcript(),
          matching: find.text('Pregunta histórica 20 con contexto adicional.'),
        ),
        findsOneWidget,
      );
      await tearDownChat(tester, gateway);
    });

    testWidgets('the sticky prompt skips a process-notification carrier', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final history = longReplyHistory()
        ..insert(1, {
          'id': 'carrier-u',
          'role': 'user',
          'content':
              '[IMPORTANT: Background process proc_0b5fab8a4839 exited '
              '(exit code 1).\nCommand: echo hi\nOutput:\nhi\n]',
        });
      await pumpChat(tester, gateway, history: history);
      await settle(tester);
      expect(sticky(), findsOneWidget);
      expect(
        find.descendant(
          of: sticky(),
          matching: find.textContaining('Pregunta larga del turno'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sticky(),
          matching: find.textContaining('Background process'),
        ),
        findsNothing,
      );
      await tearDownChat(tester, gateway);
    });

    testWidgets('Prompts does not list a process-notification carrier', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final history = _history()
        ..insert(1, {
          'id': 'carrier-u',
          'role': 'user',
          'content':
              '[IMPORTANT: Background process proc_0b5fab8a4839 exited '
              '(exit code 1).\nCommand: echo hi\nOutput:\nhi\n]',
        });
      await pumpChat(tester, gateway, history: history);
      await settle(tester);
      await openPrompts(tester);
      final sheet = find.byKey(const ValueKey('chat-prompt-sheet'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(
          of: sheet,
          matching: find.textContaining('Background process'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.text('Pregunta histórica 29 con contexto adicional.'),
        ),
        findsOneWidget,
      );
      await tearDownChat(tester, gateway);
    });

    // Owner report: with a terminal tool running, opening the activity pill
    // left the pinned prompt as a see-through bubble over the reply text.
    // Like Desktop (which clips the transcript behind its sticky prompt), the
    // pinned prompt must sit on an opaque field. QA 9493: that field is the
    // floating chip's own surface, the header buttons' tint made opaque.
    void expectOpaqueStickyBackdrop(WidgetTester tester) {
      final stickyRect = tester.getRect(sticky());
      final colors = Theme.of(tester.element(sticky())).hermes;
      final background = Color.alphaBlend(
        colors.surfaceVariant.withValues(alpha: 0.92),
        colors.background,
      );
      final covering = <Color>[];
      for (final element
          in find
              .descendant(
                of: sticky(),
                matching: find.byWidgetPredicate(
                  (w) => w is ColoredBox || w is DecoratedBox,
                ),
              )
              .evaluate()) {
        final widget = element.widget;
        final color = widget is ColoredBox
            ? widget.color
            : ((widget as DecoratedBox).decoration as BoxDecoration?)?.color;
        if (color == null) continue;
        final box = element.renderObject! as RenderBox;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        if (rect.left <= stickyRect.left + 0.5 &&
            rect.right >= stickyRect.right - 0.5 &&
            rect.top <= stickyRect.top + 0.5 &&
            rect.bottom >= stickyRect.bottom - 0.5) {
          covering.add(color);
        }
      }
      expect(
        covering.where((c) => c.a == 1.0),
        isNotEmpty,
        reason:
            'the pinned prompt needs an opaque backdrop over its whole '
            'area; found only $covering',
      );
      expect(covering.firstWhere((c) => c.a == 1.0), background);
      for (final element
          in find
              .ancestor(of: sticky(), matching: find.byType(Opacity))
              .evaluate()) {
        expect((element.widget as Opacity).opacity, 1);
      }
    }

    testWidgets('opening the activity pill keeps the pinned prompt opaque', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      var wallMs = DateTime(2026, 10, 5, 12).millisecondsSinceEpoch;
      final chat = await pumpChat(
        tester,
        gateway,
        wallClockMs: () => wallMs,
        history: [
          {'id': 'short-a', 'role': 'assistant', 'content': 'Respuesta corta'},
          {'id': 'short-u', 'role': 'user', 'content': 'Pregunta corta'},
        ],
      );
      await settle(tester);
      expect(sticky(), findsNothing, reason: 'precondition: nothing pinned');
      await chat.send(
        fullText: 'Revisa el perfil de la oficina operativa',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit('message.start');
      await tester.pump();
      for (var delta = 0; delta < 12; delta++) {
        gateway.emit('message.delta', {
          'text':
              '${List.filled(12, 'Voy a revisar el perfil paso a paso.').join(' ')}'
              '\n\n',
        });
        await tester.pump(const Duration(milliseconds: 33));
      }
      gateway.emit('tool.start', const {
        'tool_id': 'call-pill-sticky',
        'name': 'terminal',
        'args': {'command': 'sleep 300'},
      });
      for (var frame = 0; frame < 120; frame++) {
        wallMs += 33;
        await tester.pump(const Duration(milliseconds: 33));
      }
      final pill = find.byKey(const ValueKey('activity-pill'));
      expect(pill, findsOneWidget, reason: 'precondition: running tool pill');

      await tester.tap(pill);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(
        sticky(),
        findsOneWidget,
        reason: 'precondition: the reply spans the top, its prompt is pinned',
      );
      expect(
        find.descendant(
          of: sticky(),
          matching: find.textContaining('Revisa el perfil'),
        ),
        findsOneWidget,
      );
      expectOpaqueStickyBackdrop(tester);

      gateway.emit('tool.complete', const {
        'tool_id': 'call-pill-sticky',
        'name': 'terminal',
      });
      gateway.emit('message.complete', {'text': chat.assistantContent});
      await tester.pump();
      await tester.pump(const Duration(minutes: 2));
      await tearDownChat(tester, gateway);
    });

    testWidgets('a jump starts an away period with no new messages', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, history: _history());
      await settle(tester);
      await openPrompts(tester);
      final target = find.text('Pregunta histórica 20 con contexto adicional.');
      await scrollSheetTo(tester, target);
      await tester.tap(target.last);
      for (var frame = 0; frame < 80; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-visible')),
        findsOneWidget,
      );
      expect(find.textContaining('nuevo'), findsNothing);

      chat.internalMessagesForTesting = [
        {'id': 'after-jump', 'role': 'assistant', 'content': 'Llega ahora.'},
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      await settle(tester);
      expect(
        find.descendant(of: jumpButton(), matching: find.text('1 nuevo')),
        findsOneWidget,
      );
      await tearDownChat(tester, gateway);
    });
  });

  // Owner redesign: the pinned prompt is a slim one-line header that
  // follows the scroll, can be hidden per chat and switched off in Settings.
  group('#1215 slim pinned prompt', () {
    Finder header() => find.byKey(const ValueKey('chat-sticky-prompt'));
    Finder dismiss() =>
        find.byKey(const ValueKey('chat-pinned-prompt-dismiss'));
    const sessionKey = 'conn-scroll-stress.sess-scroll-stress';
    String longReply(String tag) => List.filled(
      40,
      'Texto de la respuesta $tag que ocupa varias pantallas.',
    ).join('\n\n');

    List<Map<String, dynamic>> twoLongTurns() => [
      {'id': 'turn-b-a', 'role': 'assistant', 'content': longReply('B')},
      {'id': 'turn-b-u', 'role': 'user', 'content': 'Pregunta B del turno'},
      {'id': 'turn-a-a', 'role': 'assistant', 'content': longReply('A')},
      {'id': 'turn-a-u', 'role': 'user', 'content': 'Pregunta A del turno'},
      ..._history(turns: 3, prefix: 'older'),
    ];

    /// 'A', 'B' or '' (no header) as painted after the fade settles.
    String headerState(WidgetTester tester) {
      if (header().evaluate().isEmpty) return '';
      for (final tag in ['A', 'B']) {
        if (find
            .descendant(
              of: header(),
              matching: find.textContaining('Pregunta $tag del turno'),
            )
            .evaluate()
            .isNotEmpty) {
          return tag;
        }
      }
      return '?';
    }

    Future<void> settleHeader(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    /// Walks up the transcript and returns the header states it went
    /// through, with repeats collapsed.
    Future<List<String>> walkUp(WidgetTester tester) async {
      final controller = controllerOf(tester);
      final states = <String>[headerState(tester)];
      for (var step = 0; step < 400; step++) {
        final position = controller.position;
        if (position.pixels >= position.maxScrollExtent) break;
        controller.jumpTo(
          (position.pixels + 40).clamp(0, position.maxScrollExtent),
        );
        await settleHeader(tester);
        final state = headerState(tester);
        if (state != states.last) states.add(state);
        if (state == 'A') break;
      }
      return states;
    }

    testWidgets('the header follows the turn at the top and hides when the '
        'prompt bubble is on screen', (tester) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: twoLongTurns());
      await settle(tester);
      await settleHeader(tester);
      expect(headerState(tester), 'B');

      final states = await walkUp(tester);
      expect(states.first, 'B');
      expect(states.last, 'A', reason: 'states: $states');
      final hiddenAt = states.indexOf('');
      expect(
        hiddenAt,
        inInclusiveRange(1, states.length - 2),
        reason: 'the header hides while prompt B is on screen: $states',
      );
      expect(states, isNot(contains('?')));

      // A fling straight from one turn into the other switches the header
      // directly, without passing over the prompt bubble.
      final controller = controllerOf(tester);
      final insideA = controller.position.pixels + 240;
      controller.jumpTo(40);
      await settle(tester);
      await settleHeader(tester);
      expect(headerState(tester), 'B');
      controller.jumpTo(insideA);
      await settleHeader(tester);
      expect(headerState(tester), 'A');
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('the header is one slim opaque line', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 2856)
        ..devicePixelRatio = 3.1;
      addTearDown(tester.view.reset);
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: [
          {'id': 'slim-a', 'role': 'assistant', 'content': longReply('B')},
          {
            'id': 'slim-u',
            'role': 'user',
            'content': List.filled(20, 'Pregunta B del turno larga').join(' '),
          },
          ..._history(turns: 3, prefix: 'older'),
        ],
      );
      await settle(tester);
      await settleHeader(tester);
      expect(header(), findsOneWidget);
      final box = tester.getRect(header());
      expect(box.height, lessThanOrEqualTo(36));
      final text = tester.widget<Text>(
        find.descendant(
          of: header(),
          matching: find.textContaining('Pregunta B del turno'),
        ),
      );
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(
        find.byKey(const ValueKey('chat-load-earlier')),
        findsNothing,
        reason: 'nothing else sits on the header',
      );
      await tearDownChat(tester, gateway);
    });

    // QA 9493 (owner): the full-width band under the floating header looked
    // bolted on. The pinned prompt is a small floating chip centred under
    // the header pill, on the header buttons' surface; the transcript keeps
    // scrolling under it at both sides.
    testWidgets('QA 9493: the pinned prompt is a floating chip under the '
        'header, not a band', (tester) async {
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: [
          {'id': 'chip-a', 'role': 'assistant', 'content': longReply('B')},
          {'id': 'chip-u', 'role': 'user', 'content': 'Vale'},
          ..._history(turns: 3, prefix: 'older'),
        ],
      );
      await settle(tester);
      await settleHeader(tester);
      expect(header(), findsOneWidget);
      final screen = tester.getRect(find.byType(ChatScreen));
      final chip = tester.getRect(header());
      final headerBottom = FloatingChatHeader.insetFor(
        tester.element(header()),
      );
      expect(chip.width, lessThan(screen.width - 48), reason: '$chip');
      expect(
        chip.width,
        lessThan(200),
        reason: 'a short prompt gives a short chip that hugs it: $chip',
      );
      expect(chip.left, greaterThan(screen.left + 24));
      expect(chip.right, lessThan(screen.right - 24));
      expect(
        chip.center.dx,
        closeTo(screen.center.dx, 1),
        reason: 'centred under the header pill',
      );
      expect(chip.top, greaterThanOrEqualTo(headerBottom - 0.5));
      expect(chip.top, lessThanOrEqualTo(headerBottom + 10));
      expect(chip.height, inInclusiveRange(28, 36));
      final decorated = tester
          .widgetList<DecoratedBox>(
            find.descendant(of: header(), matching: find.byType(DecoratedBox)),
          )
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.color != null)
          .first;
      expect(decorated.borderRadius, isNotNull, reason: 'a rounded chip');
      expect(decorated.border, isNotNull);
      final colors = Theme.of(tester.element(header())).hermes;
      expect(
        decorated.color,
        Color.alphaBlend(
          colors.surfaceVariant.withValues(alpha: 0.92),
          colors.background,
        ),
        reason: 'the header buttons surface, opaque',
      );
      // "Tú" and the × live inside the chip.
      expect(
        find.descendant(of: header(), matching: find.byType(Text)).first,
        findsOneWidget,
      );
      final close = tester.getRect(dismiss());
      expect(close.height, greaterThanOrEqualTo(32));
      expect(chip.contains(tester.getCenter(dismiss())), isTrue);
      await tearDownChat(tester, gateway);
    });

    testWidgets('the header does not overflow with 2.0x text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view
        ..physicalSize = const Size(1280, 2856)
        ..devicePixelRatio = 3.1;
      addTearDown(tester.view.reset);
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: twoLongTurns());
      await settle(tester);
      await settleHeader(tester);
      expect(header(), findsOneWidget);
      final box = tester.getRect(header());
      for (final element
          in find
              .descendant(of: header(), matching: find.byType(RichText))
              .evaluate()) {
        final rendered = element.renderObject! as RenderBox;
        final rect = rendered.localToGlobal(Offset.zero) & rendered.size;
        expect(rect.top, greaterThanOrEqualTo(box.top - 0.5));
        expect(rect.bottom, lessThanOrEqualTo(box.bottom + 0.5));
      }
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('attachments show as a paperclip with their count', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: [
          {'id': 'att-a', 'role': 'assistant', 'content': longReply('B')},
          {
            'id': 'att-u',
            'role': 'user',
            'content': [
              '[📎 una.png · 1 KB]',
              '[📎 dos.png · 2 KB]',
              'Pregunta B del turno con capturas',
              '⟦adjunto⟧',
              'payload para el modelo',
            ].join('\n'),
          },
          ..._history(turns: 3, prefix: 'older'),
        ],
      );
      await settle(tester);
      await settleHeader(tester);
      expect(header(), findsOneWidget);
      expect(
        find.descendant(of: header(), matching: find.byIcon(Icons.attach_file)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header(), matching: find.text('2')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header(), matching: find.byType(RawImage)),
        findsNothing,
      );
      expect(
        find.descendant(of: header(), matching: find.byType(AttachmentCard)),
        findsNothing,
      );
      await tearDownChat(tester, gateway);
    });

    testWidgets('× hides the header for this chat only, and it stays hidden', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: twoLongTurns());
      await settle(tester);
      await settleHeader(tester);
      expect(headerState(tester), 'B');

      await tester.tap(dismiss());
      await settleHeader(tester);
      expect(header(), findsNothing);
      expect(PinnedPromptPrefs.shared.isHiddenFor(sessionKey), isTrue);
      expect(PinnedPromptPrefs.shared.isHiddenFor('conn-x.other'), isFalse);
      expect(PinnedPromptPrefs.shared.enabled, isTrue);

      // Scrolling into another turn does not bring it back.
      final states = await walkUp(tester);
      expect(states.toSet(), {''});

      // Reopening the chat keeps it hidden.
      final prefs = await SharedPreferences.getInstance();
      final stored = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
      await tearDownChat(tester, gateway);
      final again = _StreamingGateway();
      await pumpChat(
        tester,
        again,
        history: twoLongTurns(),
        initialPrefs: stored.cast<String, Object>(),
      );
      await settle(tester);
      await settleHeader(tester);
      expect(header(), findsNothing);
      await tearDownChat(tester, again);
    });

    testWidgets('the Settings switch turns the header off everywhere', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(
        tester,
        gateway,
        history: twoLongTurns(),
        initialPrefs: const {'chat_pinned_prompt_enabled': false},
      );
      await settle(tester);
      await settleHeader(tester);
      expect(header(), findsNothing);

      await PinnedPromptPrefs.shared.setEnabled(true);
      await settleHeader(tester);
      expect(headerState(tester), 'B');
      await PinnedPromptPrefs.shared.setEnabled(false);
      await settleHeader(tester);
      expect(header(), findsNothing);
      await tearDownChat(tester, gateway);
    });

    // QA 9490: once hidden with ×, the pinned prompt could never come back:
    // the Settings switch off/on kept the per-chat hide.
    testWidgets('× offers Undo in a notice, which shows it again', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: twoLongTurns());
      await settle(tester);
      await settleHeader(tester);
      expect(headerState(tester), 'B');

      await tester.tap(dismiss());
      await settleHeader(tester);
      expect(header(), findsNothing);
      // The app's notice lane (HermesNotice) stands in for a SnackBar.
      expect(find.text('Oculta en este chat'), findsOneWidget);
      await tester.tap(find.text('Deshacer'));
      await settleHeader(tester);
      expect(PinnedPromptPrefs.shared.isHiddenFor(sessionKey), isFalse);
      expect(headerState(tester), 'B');
      await tearDownChat(tester, gateway);
    });

    // QA 9491: the Undo notice vanished after 2-4 s on device: any other
    // notice arriving behind it made it yield after the 2.5 s minimum. An
    // undo stays readable and tappable for about 6 s even with a queue.
    testWidgets('the Undo notice holds ~6 s even with another notice queued', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: twoLongTurns());
      await settle(tester);
      await settleHeader(tester);
      expect(headerState(tester), 'B');

      await tester.tap(dismiss());
      await settleHeader(tester);
      expect(find.text('Oculta en este chat'), findsOneWidget);
      // A routine status notice lands right behind it.
      HermesNotice.of(
        tester.element(find.byType(ChatScreen)),
      ).show(message: 'Aviso de fondo');
      // Stepped frames so a close animation could actually run.
      for (var t = 0; t < 55; t++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.text('Oculta en este chat'),
          findsOneWidget,
          reason: 'Undo notice gone after ${(t + 1) * 100} ms',
        );
      }
      expect(find.text('Oculta en este chat'), findsOneWidget);
      expect(find.text('Deshacer'), findsOneWidget);
      expect(find.text('Aviso de fondo'), findsNothing);

      await tester.tap(find.text('Deshacer'));
      await settleHeader(tester);
      expect(PinnedPromptPrefs.shared.isHiddenFor(sessionKey), isFalse);
      // Then the queued notice gets its turn.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Aviso de fondo'), findsOneWidget);
      await tearDownChat(tester, gateway);
    });

    testWidgets('the chat menu shows it again only while it is hidden', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: twoLongTurns());
      await settle(tester);
      await settleHeader(tester);
      expect(headerState(tester), 'B');
      final show = find.byKey(
        const ValueKey('chat-control-show-pinned-prompt'),
      );

      Future<void> openMenu() async {
        await tester.tap(find.byKey(const ValueKey('chat-notch')));
        await settleHeader(tester);
        expect(find.byKey(const ValueKey('chat-control-dialog')), findsOne);
      }

      await openMenu();
      expect(show, findsNothing);
      await tester.binding.handlePopRoute();
      await settleHeader(tester);

      await tester.tap(dismiss());
      await settleHeader(tester);
      HermesNotice.of(
        tester.element(find.byType(Scaffold).last),
      ).removeCurrentSnackBar();
      await settleHeader(tester);
      expect(header(), findsNothing);

      await openMenu();
      expect(
        find.descendant(
          of: show,
          matching: find.text('Mostrar tu pregunta fijada'),
        ),
        findsOneWidget,
      );
      final sheet = find.byKey(const ValueKey('chat-control-sheet'));
      // The new top-level search and Ir a sections put this recovery action
      // below the compact viewport. Scroll the actual sheet, not the chat.
      await tester.drag(sheet, const Offset(0, -420));
      await tester.pump();
      await tester.ensureVisible(show);
      await tester.tap(show);
      await tester.pump();
      await tester.pump(
        kChatNotchSheetClose + const Duration(milliseconds: 120),
      );
      await settleHeader(tester);
      await settleHeader(tester);
      expect(find.byKey(const ValueKey('chat-control-dialog')), findsNothing);
      expect(PinnedPromptPrefs.shared.isHiddenFor(sessionKey), isFalse);
      expect(headerState(tester), 'B');
      await tearDownChat(tester, gateway);
    });

    testWidgets('switching the Settings toggle back on clears every per-chat '
        'hide', (tester) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: twoLongTurns());
      await settle(tester);
      await settleHeader(tester);
      await PinnedPromptPrefs.shared.hideFor('conn-x.other');
      await tester.tap(dismiss());
      await settleHeader(tester);
      expect(header(), findsNothing);

      await PinnedPromptPrefs.shared.setEnabled(false);
      await settleHeader(tester);
      expect(PinnedPromptPrefs.shared.isHiddenFor(sessionKey), isTrue);
      await PinnedPromptPrefs.shared.setEnabled(true);
      await settleHeader(tester);
      expect(PinnedPromptPrefs.shared.isHiddenFor(sessionKey), isFalse);
      expect(PinnedPromptPrefs.shared.isHiddenFor('conn-x.other'), isFalse);
      expect(headerState(tester), 'B');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(PinnedPromptPrefs.hiddenKey), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('following the scroll rebuilds no transcript row', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: twoLongTurns());
      await settle(tester);
      await settleHeader(tester);
      expect(headerState(tester), 'B');
      // Leave the bottom first: showing the jump arrow is not under test.
      controllerOf(tester).jumpTo(40);
      await settle(tester);
      await settleHeader(tester);
      final list = tester.element(
        find.descendant(of: transcript(), matching: find.byType(SliverList)),
      );
      final existing = <Element>{};
      void collect(Element element) {
        existing.add(element);
        element.visitChildren(collect);
      }

      list.visitChildren(collect);
      var rebuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (existing.contains(element)) rebuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      final states = await walkUp(tester);
      debugOnRebuildDirtyWidget = null;
      expect(states.last, 'A', reason: 'precondition: the header switched');
      expect(rebuilds, 0, reason: 'scrolling rebuilt transcript rows');
      await tearDownChat(tester, gateway);
    });
  });

  group('QA 9489 one unread model', () {
    Finder divider() => find.byKey(const ValueKey('chat-new-since-divider'));
    Finder jumpButton() => find.byKey(const ValueKey('chat-scroll-to-bottom'));
    var now = DateTime(2026, 10, 6, 12);
    setUp(() {
      now = DateTime(2026, 10, 6, 12);
      UnreadPresence.debugClock = () => now;
    });
    tearDown(() => UnreadPresence.debugClock = null);

    Future<void> background(WidgetTester tester) async {
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
        await tester.pump();
      }
    }

    Future<void> foreground(WidgetTester tester) async {
      for (final s in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
        await tester.pump();
      }
    }

    List<Map<String, dynamic>> replies(String id, int n) => [
      for (var i = n - 1; i >= 0; i--)
        {
          'id': '$id-$i',
          'role': 'assistant',
          'content': List.filled(
            25,
            'Respuesta $id $i en segundo plano.',
          ).join(' '),
        },
    ];

    testWidgets('backgrounded long enough: lands on the first reply that '
        'arrived meanwhile, divider and no pill', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, history: _history());
      await settle(tester);
      expect(divider(), findsNothing);
      await background(tester);
      chat.internalMessagesForTesting = [
        ...replies('away', 3),
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      await settle(tester);
      expect(divider(), findsNothing, reason: 'nothing decided while hidden');
      now = now.add(const Duration(minutes: 5));
      await foreground(tester);
      for (var f = 0; f < 120 && divider().evaluate().isEmpty; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await settle(tester);
      expect(divider(), findsOneWidget);
      final first = find.textContaining('Respuesta away 0 en');
      expect(first, findsOneWidget);
      expect(
        tester.getTopLeft(first).dy,
        greaterThan(tester.getTopLeft(divider()).dy),
      );
      expect(
        controllerOf(tester).position.pixels,
        greaterThan(0),
        reason: 'opens at the first new reply, not at the last',
      );
      expect(
        find.descendant(
          of: jumpButton(),
          matching: find.textContaining('nuevo'),
        ),
        findsNothing,
      );
      await tearDownChat(tester, gateway);
    });

    testWidgets('a short trip to another app is not leaving: no divider', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, history: _history());
      await settle(tester);
      await background(tester);
      chat.internalMessagesForTesting = [
        ...replies('blip', 2),
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      now = now.add(const Duration(seconds: 5));
      await foreground(tester);
      await settle(tester);
      expect(divider(), findsNothing);
      await tearDownChat(tester, gateway);
    });

    testWidgets('reading back: what arrives while hidden is not counted, '
        'what arrives while reading is', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await pumpChat(tester, gateway, history: _history());
      await tester.pump(const Duration(seconds: 1));
      await scrollUp(tester, 300);
      await background(tester);
      chat.internalMessagesForTesting = [
        ...replies('hidden', 2),
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      await settle(tester);
      now = now.add(const Duration(seconds: 5));
      await foreground(tester);
      await settle(tester);
      expect(
        find.descendant(
          of: jumpButton(),
          matching: find.textContaining('nuevo'),
        ),
        findsNothing,
        reason: 'the pill only counts while the reader is in the chat',
      );
      chat.internalMessagesForTesting = [
        ...replies('live', 1),
        ...chat.internalMessagesForTesting,
      ];
      chat.debugEmitMessagesHydrated();
      await settle(tester);
      expect(
        find.descendant(of: jumpButton(), matching: find.text('1 nuevo')),
        findsOneWidget,
      );
      await tearDownChat(tester, gateway);
    });
  });

  // Owner (QA): the transcript ended at an opaque band above the composer.
  // The bottom group (notices, strips, composer) now floats: the list runs
  // to the bottom under it and reserves its measured height. pm1215 (QA
  // 9494): and nothing is painted above or around it (no fade, no band),
  // exactly like under the floating header.
  testWidgets('bottom group floats: the transcript runs under it to the '
      'bottom and reserves its height; nothing above the composer, the foot '
      'behind the bars is dimmed', (tester) async {
    tester.view
      ..physicalSize = const Size(1080, 2400)
      ..devicePixelRatio = 3
      ..padding = const FakeViewPadding(bottom: 63)
      ..viewPadding = const FakeViewPadding(bottom: 63);
    addTearDown(tester.view.reset);
    final gateway = _StreamingGateway();
    await pumpChat(tester, gateway, history: _history(turns: 30));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final list = find.descendant(
      of: find.byType(ChatScrollInteractionGuard),
      matching: find.byType(ListView),
    );
    final bars = tester.getRect(find.byKey(const ValueKey('chat-bottom-bars')));
    final listRect = tester.getRect(list);
    // The viewport reaches the bottom: the composer floats over it.
    expect(listRect.bottom, closeTo(bars.bottom, 0.5));
    expect(listRect.bottom, closeTo(800, 0.5));
    expect(bars.top, lessThan(listRect.bottom - 40));
    // The newest row can always rest above the composer and its notch.
    final padding = tester.widget<ListView>(list).padding! as EdgeInsets;
    expect(
      padding.bottom,
      greaterThanOrEqualTo(bars.height + kChatNotchHeight),
    );
    // At rest the newest row ends above the composer, close to it.
    final controller = tester.widget<ListView>(list).controller!;
    expect(controller.position.pixels, 0);
    expect(find.byKey(const ValueKey('chat-bottom-scrim')), findsNothing);
    // The foot's scrim (owner, QA 9529) covers the bars and not a pixel more.
    final foot = tester.getRect(find.byKey(const ValueKey('chat-foot-scrim')));
    expect(foot.top, closeTo(bars.top, 0.5));
    expect(foot.bottom, closeTo(bars.bottom, 0.5));
    final composerHost = tester.widget<Container>(
      find.byKey(const ValueKey('chat-composer-host')),
    );
    expect(
      composerHost.color,
      isNull,
      reason: 'only the rounded composer pill may paint a surface',
    );
    // Reading back moves rows under the floating composer.
    await tester.drag(list, const Offset(0, 40));
    await tester.drag(list, const Offset(0, 160));
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.position.pixels, greaterThan(100));
    var under = false;
    for (final e
        in find
            .descendant(of: list, matching: find.byType(RichText))
            .evaluate()) {
      final box = e.renderObject;
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      final r = box.localToGlobal(Offset.zero) & box.size;
      if (r.bottom > bars.top + 1 && r.top < bars.bottom) under = true;
    }
    expect(under, isTrue, reason: 'text passes under the composer');

    // Pixel-level: immediately above the composer there is actual transcript
    // ink, not a uniformly painted fade/band. Geometry above proves this
    // RichText sits below the composer; the pixel assertion proves it remains
    // visible at the paint layer.
    final bg = Theme.of(tester.element(list)).hermes.background;
    final pixels = await ViewPixels.capture(tester);
    final overlap = find
        .descendant(of: list, matching: find.byType(RichText))
        .evaluate()
        .map((e) => e.renderObject)
        .whereType<RenderBox>()
        .map((b) => b.localToGlobal(Offset.zero) & b.size)
        .map(
          (r) => r.intersect(
            Rect.fromLTRB(0, bars.top - 12, listRect.right, bars.top - 1),
          ),
        )
        .firstWhere((r) => !r.isEmpty);
    expect(
      pixels.maxInk(overlap, bg),
      greaterThan(60),
      reason: 'transcript pixels remain visible beside the composer',
    );
    // The host spans the full width behind the rounded composer. This is the
    // regression guard for an opaque host Container: the same transcript
    // glyphs must still be paint-visible inside that host, outside the pill.
    final host = tester.getRect(
      find.byKey(const ValueKey('chat-composer-host')),
    );
    final underHost = find
        .descendant(of: list, matching: find.byType(RichText))
        .evaluate()
        .map((e) => e.renderObject)
        .whereType<RenderBox>()
        .map((b) => b.localToGlobal(Offset.zero) & b.size)
        .map((r) => r.intersect(host))
        .firstWhere((r) => !r.isEmpty);
    expect(
      pixels.maxInk(underHost, bg),
      greaterThan(60),
      reason: 'no opaque host masks transcript beneath the composer',
    );
    await tearDownChat(tester, gateway);
  });
}
