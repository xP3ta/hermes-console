import 'support/live_chat_v4.dart';

import 'package:hermes_android/core/widgets/chat/chat_pinned_prompt_header.dart';
import 'package:hermes_android/core/design/floating.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/widgets/chat/chat_notch.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/chat/live_reply_reveal.dart';
import 'package:hermes_android/core/design/tokens.dart' show HermesChrome;
import 'package:hermes_android/core/design/glass_strip.dart'
    show HermesGlassStrip;
import 'package:hermes_android/core/widgets/frosted_backdrop.dart'
    show FrostedBackdrop, FrostedBackdropPolicy, FrostedZone;
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/chat_stream_trace.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/pinned_prompt_prefs.dart';
import 'package:hermes_android/core/services/reasoning_disclosure_prefs.dart';
import 'package:hermes_android/core/widgets/generated_image_card.dart';
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
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart'
    show chatWorkspaceSplitFits;
import 'package:hermes_android/core/theme/app_theme.dart';

import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/bottom_transparency.dart';
import 'support/fake_webview_platform.dart';
import 'support/test_api_client.dart';

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

/// A draft store that always restores [draft]: the composer opens with it.
class _OneDraftStore extends ChatDraftStore {
  _OneDraftStore(super.prefs, this.draft);

  final ChatDraft draft;

  @override
  Future<ChatDraft> load(
    String connectionId,
    String sessionId, {
    String profile = 'default',
    bool claimUnscopedLegacy = false,
  }) async => draft;
}

/// A 1x1 PNG, for an image attachment staged in the composer.
final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGA'
  'WjR9awAAAABJRU5ErkJggg==',
);

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
    ChatDraftStore Function(SharedPreferences prefs)? draftStore,
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
        builder: (_) => ChatScreen(
          connection: connection,
          session: _session(),
          draftStoreOverride: draftStore?.call(prefs),
        ),
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

  // scroll-follow (Desktop parity: use-stick-to-bottom in
  // apps/desktop/src/components/assistant-ui/thread/list.tsx follows while
  // locked to the bottom, escapes on user scroll-up, re-locks at the bottom).
  // The chat follows only a reader who is pegado al final: one who went up is
  // never carried back by anything but his own «ir al final» or his own send.
  group('scroll-follow: only a reader at the bottom is followed', () {
    Finder jump() => find.byKey(const ValueKey('chat-scroll-to-bottom'));

    Future<void> finishTurn(
      WidgetTester tester,
      _StreamingGateway gateway,
      ActiveChat chat,
    ) async {
      gateway.emit('message.complete', {'text': chat.assistantContent});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await settle(tester);
    }

    Future<void> bounceSettle(WidgetTester tester) async {
      for (var frame = 0; frame < 90; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<ActiveChat> startLongTurn(
      WidgetTester tester,
      _StreamingGateway gateway,
    ) async {
      final chat = await pumpChat(tester, gateway, history: _history());
      await tester.pump(const Duration(seconds: 1));
      await chat.send(
        fullText: 'Cuéntame algo largo',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit('message.start');
      gateway.emit('message.delta', {
        'text': 'Primera línea de la respuesta.',
      });
      await settle(tester);
      return chat;
    }

    testWidgets('idle: activity that arrives later does not carry a reader '
        'who went up within one screen', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startLongTurn(tester, gateway);
      await finishTurn(tester, gateway, chat);
      await scrollUp(tester, 300);
      final controller = controllerOf(tester);
      final before = controller.position.pixels;
      expect(before, greaterThan(150));
      for (var i = 0; i < 3; i++) {
        gateway.emit('subagent.start', {
          'subagent_id': 'bg-$i',
          'status': 'running',
          'goal': 'Tarea en segundo plano $i',
          'event_id': 'e-$i',
          'event_revision': 1,
        });
        await tester.pump(const Duration(seconds: 2));
        gateway.emit('subagent.progress', {
          'subagent_id': 'bg-$i',
          'status': 'running',
          'text': 'Avanzando $i',
          'event_id': 'e-$i-p',
          'event_revision': 2,
        });
        await tester.pump(const Duration(seconds: 2));
      }
      await settle(tester);
      // A row may land under the reader (that moves the offset away from the
      // tail, never towards it): what must not happen is being carried down.
      expect(controller.position.pixels, greaterThan(before - 1.5));
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-visible')),
        findsOneWidget,
      );
      await tearDownChat(tester, gateway);
    });

    testWidgets('a reader who went up is not moved by the end of the turn '
        'and the jump button shows', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startLongTurn(tester, gateway);
      await scrollUp(tester, 300);
      final controller = controllerOf(tester);
      final marker = visibleMarker(tester);
      final markerTop = tester.getTopLeft(marker).dy;
      for (var i = 0; i < 4; i++) {
        gateway.emit('message.delta', {
          'text': '\n\n${List.filled(20, 'Más texto del turno.').join(' ')}',
        });
        await tester.pump(const Duration(seconds: 3));
        expect(tester.getTopLeft(marker).dy, closeTo(markerTop, 1.5));
      }
      await finishTurn(tester, gateway, chat);
      await tester.pump(const Duration(seconds: 6));
      expect(tester.getTopLeft(marker).dy, closeTo(markerTop, 1.5));
      expect(controller.position.pixels, greaterThan(150));
      expect(jump(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-visible')),
        findsOneWidget,
      );
      await tearDownChat(tester, gateway);
    });

    testWidgets('during the turn: the reader who comes back to the bottom by '
        'himself is followed again', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startLongTurn(tester, gateway);
      await scrollUp(tester, 300);
      final controller = controllerOf(tester);
      expect(controller.position.pixels, greaterThan(150));
      await tester.drag(transcript(), const Offset(0, -900));
      await bounceSettle(tester);
      expect(controller.position.pixels, closeTo(0, 1.5));
      for (var i = 0; i < 3; i++) {
        gateway.emit('message.delta', {
          'text': '\n\n${List.filled(30, 'Texto nuevo del turno.').join(' ')}',
        });
        await settle(tester);
        expect(
          controller.position.pixels,
          closeTo(0, 1.5),
          reason: 'back at the bottom the turn is followed again',
        );
      }
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-hidden')),
        findsOneWidget,
      );
      await finishTurn(tester, gateway, chat);
      expect(controller.position.pixels, closeTo(0, 1.5));
      await tearDownChat(tester, gateway);
    });

    testWidgets('idle: a reader who comes back to the bottom by himself is '
        'followed, and the jump button follows him', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startLongTurn(tester, gateway);
      await finishTurn(tester, gateway, chat);
      await scrollUp(tester, 300);
      await tester.drag(transcript(), const Offset(0, -900));
      await bounceSettle(tester);
      final controller = controllerOf(tester);
      expect(controller.position.pixels, closeTo(0, 1.5));
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-hidden')),
        findsOneWidget,
      );
      await chat.send(
        fullText: 'Otro turno',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit('message.start');
      gateway.emit('message.delta', {
        'text': List.filled(60, 'Respuesta nueva que crece.').join(' '),
      });
      await settle(tester);
      expect(controller.position.pixels, closeTo(0, 1.5));
      await finishTurn(tester, gateway, chat);
      await tearDownChat(tester, gateway);
    });
    testWidgets('the jump button brings a reader down and resumes the '
        'follow', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startLongTurn(tester, gateway);
      await scrollUp(tester, 300);
      final controller = controllerOf(tester);
      expect(controller.position.pixels, greaterThan(150));
      await tester.tap(jump());
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(controller.position.pixels, closeTo(0, 0.5));
      gateway.emit('message.delta', {
        'text': '\n\n${List.filled(30, 'Texto tras el botón.').join(' ')}',
      });
      await settle(tester);
      expect(controller.position.pixels, closeTo(0, 0.5));
      await finishTurn(tester, gateway, chat);
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
    // Mock 137 A: by default the thought is one 48 dp line and the live
    // turn hardly grows. This group needs a turn that grows, so the thought
    // opens at six lines while it thinks (the setting off, Console before
    // 1.4.0) and stays open once a tool follows it (Desktop's latch,
    // message-parts.tsx:242-255): the stress on the anchor is the same.
    setUp(() => ReasoningDisclosurePrefs.shared.setCollapsedByDefault(false));
    tearDown(() => ReasoningDisclosurePrefs.debugUse(null));

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
        find.byKey(const ValueKey('chat-inline-activity'), skipOffstage: false);

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
      work(gateway).first();
      await settle(tester);
      await openInlineDetails(tester);
      await scrollUp(tester, 180);
      final controller = controllerOf(tester);
      expect(controller.position.pixels, greaterThan(150));
      final marker = visibleMarker(tester);
      final before = tester.getTopLeft(marker).dy;

      await openInlineDetails(tester);
      final steps = work(gateway).skip(1).toList();
      for (var index = 0; index < steps.length; index++) {
        steps[index]();
        await settle(tester);
        expect(
          tester.getTopLeft(marker).dy,
          closeTo(before, 1.5),
          reason: 'step $index moved the text being read',
        );
      }
      // Q9-CHAT5 v2: the turn grows by step cards (48 dp each) and its
      // plan; before, by the whole thought (137 A).
      // Keep the >80 dp stimulus independent of the capsule's painted height.
      expect(
        tester.getSize(find.byKey(const ValueKey('turn-step-cards'))).height,
        greaterThan(80),
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
      work(gateway).first();
      await settle(tester);
      await openInlineDetails(tester);
      await scrollUp(tester, 300);
      final marker = visibleMarker(tester);
      final before = tester.getTopLeft(marker).dy;
      await openInlineDetails(tester);
      for (final step in work(gateway).skip(1)) {
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
        lessThan(pixels - 50),
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
      await openInlineDetails(tester);
      for (final step in work(gateway)) {
        step();
        await settle(tester);
        expect(controller.position.pixels, closeTo(0, 0.5));
      }
      // The tools are an open timeline while the turn lives; it grows by its rows.
      final rows = find.byWidgetPredicate(
        (w) => w is Semantics && '${w.key}'.contains('turn-step-card-'),
      );
      final fold = inlineLabel;
      final inner = find.byWidgetPredicate(
        (w) => '${w.key}'.contains('turn-inner-thought-'),
      );
      if (inner.evaluate().isEmpty && fold.evaluate().isNotEmpty) {
        await tester.tap(fold);
        await settle(tester);
      }
      expect(rows, findsWidgets);
      expect(controller.position.pixels, closeTo(0, 0.5));
      final viewport = tester.getRect(transcript());
      final lines = tester.getRect(
        find.byKey(const ValueKey('turn-step-cards')),
      );
      // Q9-CHAT5 v2: the turn grew by its step rows and its plan; what is
      // newest stays in view.
      // This functional threshold stays >80 dp as the capsule gets slimmer.
      expect(lines.height, greaterThan(80));
      expect(lines.bottom, lessThanOrEqualTo(viewport.bottom));
      // …above the composer and what floats on it, never under them.
      final bars = tester.getRect(
        find.byKey(const ValueKey('chat-bottom-bars')),
      );
      expect(lines.bottom, lessThanOrEqualTo(bars.top));
      // A thought followed by a tool is over: ITS row is on screen, and it
      // opens the thought (not any step's row).
      final thoughtCard = find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            ('${w.key}'.contains('turn-thought-card-') ||
                '${w.key}'.contains('turn-inner-thought-')) &&
            (w.properties.label ?? '').startsWith('Pens'),
      );
      expect(thoughtCard, findsOneWidget, reason: 'the thought\'s card');
      final thought = tester.getSemantics(thoughtCard);
      expect(thought.label, startsWith('Pens'));
      expect(thought.flagsCollection.isButton, isTrue);
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
      await openInlineDetails(tester);
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
      await openInlineDetails(tester);
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

    // REVIEW-T3-B C2: F5 makes heights change over ~200 ms instead of one
    // frame. The reader is held in every one of those frames.
    Future<void> endLiveTurn(
      WidgetTester tester,
      _StreamingGateway gateway,
      ActiveChat chat,
    ) async {
      gateway.emit('message.complete', {'text': chat.assistantContent});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
    }

    testWidgets('F5: an image of the live turn changes size, a reader '
        'scrolled up stays put frame by frame', (tester) async {
      final gateway = _StreamingGateway();
      final chat = await startTurn(tester, gateway);
      await scrollUp(tester, 300);
      final marker = visibleMarker(tester);
      final before = tester.getTopLeft(marker).dy;
      gateway.emit('message.delta', {
        'text':
            'Aquí la tienes:\n\n~/.hermes/cache/images/f5-lector.png\n\n'
            'Y el texto sigue debajo.',
      });
      // Its 16:9 hole, then (no Dashboard here) the error card: another
      // height, eased over HermesMotion.base. The download is real I/O.
      final card = find.byType(GeneratedImageCard, skipOffstage: false);
      final controller = controllerOf(tester);
      var sawImage = false;
      var framesAfter = 0;
      // gint56 moved 5.5 dp in frame 17: each frame's reader, scroll and
      // card, so a failure says which change was not held (measured, not
      // guessed).
      final trace = <String>[];
      for (var frame = 0; frame < 300 && framesAfter < 20; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump(const Duration(milliseconds: 16));
        final shown = card.evaluate().isNotEmpty;
        final cardState = shown
            ? '${tester.widget<GeneratedImageCard>(card).status.name}/'
                  '${tester.getSize(card).height.toStringAsFixed(1)}'
            : '-';
        final position = controller.position;
        trace.add(
          'f$frame dy=${tester.getTopLeft(marker).dy.toStringAsFixed(2)} '
          'px=${position.pixels.toStringAsFixed(2)} '
          'max=${position.maxScrollExtent.toStringAsFixed(2)} '
          'card=$cardState',
        );
        final recent = trace.skip(math.max(0, trace.length - 24));
        expect(
          tester.getTopLeft(marker).dy,
          closeTo(before, 1.5),
          reason:
              'frame $frame moved the text being read\n${recent.join('\n')}',
        );
        if (!shown) continue;
        sawImage = true;
        if (tester.widget<GeneratedImageCard>(card).status !=
            GeneratedImageStatus.downloading) {
          framesAfter++;
        }
      }
      expect(sawImage, isTrue, reason: 'precondition: the image came');
      expect(framesAfter, 20, reason: 'precondition: it changed size');
      await endLiveTurn(tester, gateway, chat);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    for (final readerUp in const [false, true]) {
      final reader = readerUp
          ? 'scrolled up stays put'
          : 'at the bottom stays there';
      testWidgets('F5: an approval rises over the composer and the reader '
          '$reader, frame by frame', (tester) async {
        final gateway = _StreamingGateway();
        final chat = await startTurn(tester, gateway);
        gateway.emit('message.delta', {
          'text': List.filled(30, 'Texto del turno en marcha.').join(' '),
        });
        await settle(tester);
        final controller = controllerOf(tester);
        // The lower pill reserves more room than the retired header capsule.
        // Read a historical row beyond this long live reply before testing
        // the approval's frame-by-frame anchor contract.
        if (readerUp) await scrollUp(tester, 600);
        final marker = readerUp ? visibleMarker(tester) : null;
        final before = marker == null ? 0.0 : tester.getTopLeft(marker).dy;
        gateway.emit('approval.request', const {
          'request_id': 'approval-reader',
          'command': 'rm -rf build',
          'pattern_key': 'rm',
        });
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (marker == null) {
            expect(
              controller.position.pixels,
              closeTo(0, 0.5),
              reason: 'frame $frame: the reader left the bottom',
            );
          } else {
            final bars = find.byKey(const ValueKey('chat-bottom-bars'));
            expect(
              tester.getTopLeft(marker).dy,
              closeTo(before, 1.5),
              reason:
                  'frame $frame moved the text being read '
                  '(px=${controller.position.pixels.toStringAsFixed(2)}, '
                  'bars top=${tester.getTopLeft(bars).dy.toStringAsFixed(2)})',
            );
          }
        }
        expect(chat.pendingApproval, isNotNull, reason: 'precondition');
        await endLiveTurn(tester, gateway, chat);
        expect(tester.takeException(), isNull);
        await tearDownChat(tester, gateway);
      });
    }

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
        // Q9-CHAT5 v2: the live turn's lines (no status line under the name
        // any more: the pills above the composer say it).
        final live = find
            .byKey(const ValueKey('chat-inline-activity'))
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

  // F0 of the fluidity plan (REPORT-AUDITORIA-FLUIDEZ §4): the streaming
  // path is measured before it changes. A reply streams while the reader
  // follows the bottom, with an open code fence, then the turn ends. The
  // counts are printed as the reference baseline (work, not milliseconds); the
  // assertions only pin that every point is wired. F1-F3 tighten them.
  testWidgets('F0: every point of the stream is measured (baseline)', (
    tester,
  ) async {
    final gateway = _StreamingGateway();
    final chat = await pumpChat(tester, gateway, history: _history(turns: 3));
    await tester.pump(const Duration(seconds: 1));
    ChatStreamTrace.debugReset();
    await chat.send(
      fullText: 'Mide el flujo',
      model: 'hermes-agent',
      history: chat.buildHistory(),
    );
    gateway.emit('message.start');
    for (var i = 0; i < 20; i++) {
      gateway.emit('message.delta', {
        'text': 'Palabra $i de una respuesta que fluye poco a poco. ',
      });
      await tester.pump(const Duration(milliseconds: 40));
    }
    gateway.emit('message.delta', {'text': '\n\n```dart\nvoid main() {\n'});
    await tester.pump(const Duration(milliseconds: 40));
    final highlightsBefore = ChatStreamTrace.debugCount(
      ChatStreamPoint.highlight,
    );
    for (var i = 0; i < 6; i++) {
      gateway.emit('message.delta', {'text': '  print($i);\n'});
      await tester.pump(const Duration(milliseconds: 40));
    }
    final highlightsWhileOpen =
        ChatStreamTrace.debugCount(ChatStreamPoint.highlight) -
        highlightsBefore;
    gateway.emit('message.delta', {'text': '}\n```\n\nFin.'});
    await tester.pump(const Duration(milliseconds: 40));
    gateway.emit('message.complete', {'text': chat.assistantContent});
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    await settle(tester);

    int count(ChatStreamPoint point) => ChatStreamTrace.debugCount(point);
    int chars(ChatStreamPoint point) => ChatStreamTrace.debugChars(point);
    // ignore: avoid_print
    print(
      '[F0] flush=${count(ChatStreamPoint.flush)}/'
      '${chars(ChatStreamPoint.flush)}c '
      'reveal=${count(ChatStreamPoint.reveal)}/'
      '${chars(ChatStreamPoint.reveal)}c '
      'tailBuild=${count(ChatStreamPoint.tailBuild)} '
      'highlightWhileOpen=$highlightsWhileOpen '
      'turnEnd=${count(ChatStreamPoint.turnEnd)} '
      'turnEndJump=${ChatStreamTrace.debugLastTurnEndChars}c',
    );
    expect(count(ChatStreamPoint.flush), greaterThan(0));
    expect(chars(ChatStreamPoint.flush), greaterThan(0));
    expect(count(ChatStreamPoint.reveal), greaterThan(0));
    expect(count(ChatStreamPoint.tailBuild), greaterThan(0));
    expect(count(ChatStreamPoint.turnEnd), 1);
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
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

  // the owner, Fold horizontal (APK 9708), the split Samsung keyboard: the
  // composer with an attachment rose up to the header and no message was
  // left between them («no se puede trabajar»). With the keyboard up the
  // header is one thin row and the attachment a chip in the input row.
  group('open Fold with the keyboard up (APK 9708)', () {
    for (final withAttachment in [false, true]) {
      final label = withAttachment ? 'with an attachment' : 'no attachment';
      testWidgets('2448x1848, 800 px keyboard, $label: four transcript '
          'lines, nothing overlaps', (tester) async {
        tester.view.physicalSize = const Size(2448, 1848);
        tester.view.devicePixelRatio = 2.625;
        addTearDown(tester.view.reset);
        final temp = Directory.systemTemp.createTempSync('fold-keyboard-');
        addTearDown(() {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });
        final image = File('${temp.path}/captura.png')
          ..writeAsBytesSync(_tinyPng);
        final gateway = _StreamingGateway();
        await pumpChat(
          tester,
          gateway,
          draftStore: withAttachment
              ? (prefs) => _OneDraftStore(
                  prefs,
                  ChatDraft(
                    text: '',
                    attachments: [
                      AttachmentDraft(
                        localId: 'shot',
                        type: AttachmentType.image,
                        name: 'captura.png',
                        mimeType: 'image/png',
                        sizeBytes: image.lengthSync(),
                        localPath: image.path,
                      ),
                    ],
                  ),
                )
              : null,
        );
        await settle(tester);
        tester.view.viewInsets = const FakeViewPadding(bottom: 800);
        await settle(tester);
        await settle(tester);

        if (withAttachment) {
          expect(
            find.byKey(const ValueKey('composer-attachment-chips')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('composer-attachment-preview')),
            findsNothing,
          );
        }
        final header = tester.widget<FloatingChatHeader>(
          find.byType(FloatingChatHeader),
        );
        expect(header.compact, isTrue, reason: 'one thin row');
        final headerBottom = FloatingChatHeader.insetFor(
          tester.element(transcript()),
          compact: true,
        );
        final composer = tester.getRect(
          find.byKey(const ValueKey('chat-composer-host')),
        );
        // Vistas v3: nothing on the composer's top edge (no notch).
        final bottomTop = composer.top;
        final island = tester.getRect(find.byKey(const ValueKey('island')));
        expect(
          island.bottom,
          lessThanOrEqualTo(headerBottom),
          reason: 'the island stays in the header',
        );
        expect(
          bottomTop,
          greaterThan(headerBottom),
          reason: 'the header and the composer overlap',
        );
        final lineFinder = find.textContaining('Pregunta histórica 0');
        final measured = lineFinder.evaluate().isEmpty
            ? 0.0
            : tester.getSize(lineFinder.first).height;
        final line = measured > 0 && measured < 40 ? measured : 24.0;
        final lines = (bottomTop - headerBottom) / line;
        debugPrint(
          '[nav-a] transcript lines with the keyboard ($label): '
          '${lines.toStringAsFixed(1)}',
        );
        expect(lines, greaterThanOrEqualTo(4));
        // And some of the conversation is really painted there.
        final visible = find
            .descendant(of: transcript(), matching: find.byType(RichText))
            .evaluate()
            .map((e) {
              final box = e.renderObject! as RenderBox;
              return box.localToGlobal(Offset.zero) & box.size;
            })
            .where((r) => r.top >= headerBottom && r.bottom <= bottomTop);
        expect(visible, isNotEmpty);
        expect(tester.takeException(), isNull);
        await tearDownChat(tester, gateway);
      });
    }
  });

  group('#114 prompts and sticky prompt', () {
    Finder jumpButton() => find.byKey(const ValueKey('chat-scroll-to-bottom'));
    Finder sticky() => find.byKey(const ValueKey('chat-sticky-prompt'));

    // Vistas v3: the header and the pinned chip are one strip of glass.
    // These tests guard the solid band, which is the glass' fallback
    // (reduced motion, high contrast, a device that does not blur): they run
    // without blur. The glass case: «the pinned chip is a piece of the
    // header's glass» below.
    setUp(() => FrostedBackdropPolicy.blurAllowed.value = false);
    tearDown(() => FrostedBackdropPolicy.blurAllowed.value = true);

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
      await tester.tap(find.byKey(const ValueKey('chat-settings-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // The workspace row and Search sit above the grid, so Prompts may
      // start below the fold of the lazily built sheet list: drag the sheet
      // until it shows.
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
        tester.getSemantics(sticky()).label,
        contains('Pregunta larga del turno'),
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    // the owner (video del Fold): al entrar, el chip «Tú:» aparecía, se iba y
    // volvía. Se decide una vez, con el primer diseño asentado.
    testWidgets('opening the chat shows the sticky prompt once and never '
        'takes it back', (tester) async {
      final gateway = _StreamingGateway();
      final visibility = <bool>[];
      var recording = true;
      tester.binding.addPersistentFrameCallback((_) {
        if (!recording) return;
        final shown = sticky().evaluate().isNotEmpty;
        if (visibility.isEmpty || visibility.last != shown) {
          visibility.add(shown);
        }
      });
      addTearDown(() => recording = false);
      await pumpChat(tester, gateway, history: longReplyHistory());
      await settle(tester);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(sticky(), findsOneWidget);
      // Hidden until the first settled layout, then shown: one change, and
      // it never goes away and comes back.
      expect(visibility.last, isTrue);
      expect(
        visibility.length,
        lessThanOrEqualTo(2),
        reason: 'visibility changes: $visibility',
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    // the owner, Fold horizontal (APK 9708): «Tú: El guardar…» floated over the
    // reply and cut «Pensando». It is a band of the header now, the whole
    // width: the header's solid band runs down under it, so it never floats
    // over the text. Gate gint37: it takes that room only while it shows;
    // the transcript keeps no band of its own for it.
    testWidgets('the sticky prompt has its own solid band under the header', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: longReplyHistory());
      await settle(tester);
      expect(sticky(), findsOneWidget);
      final band = find.byKey(const ValueKey('chat-pinned-prompt-band'));
      expect(band, findsOneWidget);
      final bandRect = tester.getRect(band);
      expect(bandRect.width, closeTo(tester.getRect(transcript()).width, 1));
      // QA 9709 (ORDEN-Q9-CHAT 1): the band sits right under the island,
      // whatever its shape (here at rest, shorter than the header's extent),
      // and never below the header's extent.
      expect(
        bandRect.top,
        closeTo(tester.getRect(find.byType(ChatIsland)).bottom + 16, 1),
      );
      expect(bandRect.top, lessThanOrEqualTo(readableTop(tester) + 0.5));
      expect(bandRect.height, 48);
      expect(bandRect.contains(tester.getRect(sticky()).center), isTrue);
      // The header's band continued: opaque from the header's extent (over
      // the header's own fade) down to the band's bottom edge, then the
      // same fade.
      final backdrop = find.byKey(
        const ValueKey('chat-pinned-prompt-backdrop'),
      );
      final backdropBox = tester.widget<DecoratedBox>(backdrop);
      final gradient =
          (backdropBox.decoration as BoxDecoration).gradient! as LinearGradient;
      final backdropRect = tester.getRect(backdrop);
      expect(gradient.colors[1].a, 1);
      expect(backdropRect.top, closeTo(bandRect.top, 0.5));
      expect(
        backdropRect.top + gradient.stops![1] * backdropRect.height,
        closeTo(bandRect.bottom, 0.5),
      );
      expect(
        backdropRect.bottom - bandRect.bottom,
        FloatingChatHeader.scrimTail,
      );
      // Gate gint38: in a layer of its own, not inside the header, which
      // must not rebuild or repaint as turns scroll under it.
      expect(
        find.descendant(
          of: find.byType(FloatingChatHeader),
          matching: sticky(),
        ),
        findsNothing,
      );
      // No room kept for it in the transcript: the rows under it scroll
      // under the header, as they do with no prompt pinned.
      final list = tester.widget<ListView>(transcript());
      expect(
        (list.padding! as EdgeInsets).top,
        closeTo(readableTop(tester) - tester.getRect(transcript()).top, 0.5),
      );
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    // QA 9709 (the owner, captures 1247, 1248, 1254): on the open Fold, a panel
    // beside the chat, the band sat a status bar below the island (a pane
    // gives the chat no system padding, and the header's extent was read
    // above the pane), and with the keyboard up it fell on the composer and
    // the model pill. Two windows, with the Fold's status bar: the open Fold
    // (a panel beside the chat) and upright (no panel fits beside it). The
    // keyboard as an inset, and as the owner's Fold gave it in 1247: the window
    // ends above it (the panes ended above the keyboard and the header kept
    // its face, so the chat saw no inset).
    for (final window in const [Size(933, 704), Size(657, 870)]) {
      for (final keyboard in _Keyboard.values) {
        final name = '${window.width.toInt()}x${window.height.toInt()}';
        testWidgets('the band sits under the island and never over the '
            'composer: $name, keyboard ${keyboard.name}', (tester) async {
          tester.view.physicalSize = window;
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 45);
          tester.view.viewPadding = const FakeViewPadding(top: 45);
          addTearDown(tester.view.reset);
          WebViewPlatform.instance = FakeWebViewPlatform();
          final gateway = _StreamingGateway();
          await pumpChat(tester, gateway, history: longReplyHistory());
          await settle(tester);
          if (chatWorkspaceSplitFits(window.width)) {
            // The browser panel on the right, as in 1248 (the owner's final
            // windows: a row of Ajustes' «Paneles»).
            await tester.tap(
              find.byKey(const ValueKey('chat-settings-button')),
            );
            await tester.pump();
            await tester.pump(
              kChatNotchSheetOpen + const Duration(milliseconds: 80),
            );
            await tester.tap(
              find.byKey(const ValueKey('chat-control-workspace-browser')),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
            expect(
              find.byKey(const ValueKey('chat-workspace-divider')),
              findsOneWidget,
              reason: 'precondition: the panel beside the chat',
            );
          }
          await settle(tester);
          expect(sticky(), findsOneWidget, reason: 'precondition: pinned');
          switch (keyboard) {
            case _Keyboard.none:
              break;
            case _Keyboard.inset:
              tester.view.viewInsets = const FakeViewPadding(bottom: 330);
            case _Keyboard.resized:
              tester.view.physicalSize = Size(
                window.width,
                window.height - 330,
              );
          }
          await settle(tester);
          await tester.pump(const Duration(milliseconds: 300));
          await settle(tester);

          final island = tester.getRect(find.byType(ChatIsland).first);
          final bars = tester.getRect(
            find.byKey(const ValueKey('chat-bottom-bars')),
          );
          final composer = tester.getRect(
            find.byKey(const ValueKey('chat-composer-host')),
          );
          final band = find.byKey(const ValueKey('chat-pinned-prompt-band'));
          if (keyboard == _Keyboard.none) {
            expect(band, findsOneWidget, reason: 'room for it');
          }
          if (band.evaluate().isNotEmpty) {
            final bandRect = tester.getRect(band);
            final backdrop = tester.getRect(
              find.byKey(const ValueKey('chat-pinned-prompt-backdrop')),
            );
            expect(
              bandRect.top - island.bottom,
              inInclusiveRange(0, 20),
              reason: 'right under the island ($island, band $bandRect)',
            );
            // Never over the composer or the model pill (both in the
            // bottom bars), and the transcript keeps rows between them.
            expect(backdrop.overlaps(composer), isFalse);
            expect(backdrop.bottom, lessThanOrEqualTo(bars.top + 0.5));
            expect(bars.top - backdrop.bottom, greaterThanOrEqualTo(48));
            final list = tester.getRect(transcript());
            expect(list.top, lessThanOrEqualTo(backdrop.bottom));
            expect(list.bottom, greaterThanOrEqualTo(bars.top - 0.5));
          } else {
            expect(sticky(), findsNothing);
          }
          expect(tester.takeException(), isNull);
          await tearDownChat(tester, gateway);
        });
      }
    }

    testWidgets('the pinned chip is a piece of the header\'s glass: one '
        'strip, one blur, the transcript behind it', (tester) async {
      FrostedBackdropPolicy.blurAllowed.value = true;
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: longReplyHistory());
      await settle(tester);
      expect(sticky(), findsOneWidget);
      final strip = find.byWidgetPredicate(
        (widget) =>
            widget is HermesGlassStrip && widget.zone == FrostedZone.top,
      );
      expect(strip, findsOneWidget);
      expect(
        find.descendant(of: strip, matching: find.byType(HermesGlassStrip)),
        findsNothing,
      );
      final foot = find.byWidgetPredicate(
        (widget) =>
            widget is HermesGlassStrip && widget.zone == FrostedZone.bottom,
      );
      expect(foot, findsOneWidget);
      expect(
        tester.widget<HermesGlassStrip>(foot).key,
        const ValueKey('chat-foot-glass'),
      );
      expect(find.ancestor(of: foot, matching: strip), findsNothing);
      for (final piece in [
        find.byKey(const ValueKey('chat-header')),
        sticky(),
      ]) {
        expect(
          find.ancestor(of: piece, matching: strip),
          findsOneWidget,
          reason: '$piece in the strip',
        );
      }
      // The transcript is behind every strip, inside neither header nor foot.
      expect(
        find.ancestor(
          of: transcript(),
          matching: find.byType(HermesGlassStrip),
        ),
        findsNothing,
      );
      // No solid band under the chip: the reply shows around it.
      expect(
        find.byKey(const ValueKey('chat-pinned-prompt-backdrop')),
        findsNothing,
      );
      final colors = Theme.of(tester.element(sticky())).hermes;
      final piece = find.descendant(
        of: sticky(),
        matching: find.byType(HermesFloatingSurface),
      );
      final face = tester.widget<Material>(
        find.descendant(of: piece, matching: find.byType(Material)).first,
      );
      expect(face.color, FrostedBackdrop.glassVeil(colors));
      final shadow =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: piece,
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as ShapeDecoration;
      expect(
        shadow.shadows,
        isEmpty,
        reason: 'the shared strip owns the surface',
      );
      // The strip builds its own render boundary directly below its scope.
      // Resolve that actual render object, check its owning widget, then
      // count the filters in its painted layer subtree (not by coordinates).
      ContainerLayer stripLayer(Finder finder) {
        final render = tester.renderObject<RenderObject>(finder);
        final creator = render.debugCreator;
        expect(creator, isA<DebugCreator>());
        expect(
          (creator as DebugCreator).element
              .findAncestorWidgetOfExactType<HermesGlassStrip>(),
          same(tester.widget<HermesGlassStrip>(finder)),
        );
        expect(render.attached, isTrue);
        expect(render.isRepaintBoundary, isTrue);
        final layer = render.debugLayer;
        expect(layer, isNotNull);
        return layer!;
      }

      List<BackdropFilterLayer> filtersIn(Layer layer) {
        final filters = <BackdropFilterLayer>[];
        void walk(Layer layer) {
          if (layer is BackdropFilterLayer) filters.add(layer);
          if (layer is ContainerLayer) {
            for (var c = layer.firstChild; c != null; c = c.nextSibling) {
              walk(c);
            }
          }
        }

        walk(layer);
        return filters;
      }

      // Exactly one blur for the header and pinned chip together. The foot
      // is the grey chrome (the owner): its strip holds no glass piece and so
      // owns no blur; nothing else in the scene filters.
      final headerFilters = filtersIn(stripLayer(strip));
      final footFilters = filtersIn(stripLayer(foot));
      expect(headerFilters, hasLength(1));
      expect(footFilters, isEmpty);
      final rootLayer = tester.binding.renderViews.first.debugLayer;
      expect(rootLayer, isNotNull);
      expect(filtersIn(rootLayer!), [headerFilters.single]);
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
      // Gate gint37: with nothing pinned the band is gone and takes no room;
      // the header is solid down to its own extent.
      expect(
        tester
            .getSize(find.byKey(const ValueKey('chat-pinned-prompt-room')))
            .height,
        0,
      );
      final scrim = find.byKey(const ValueKey('floating-header-scrim'));
      final scrimBox = tester.widget<DecoratedBox>(scrim);
      final gradient =
          (scrimBox.decoration as BoxDecoration).gradient! as LinearGradient;
      final scrimRect = tester.getRect(scrim);
      expect(
        scrimRect.top + gradient.stops![1] * scrimRect.height,
        closeTo(readableTop(tester), 0.5),
      );
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
        tester.getSemantics(sticky()).label,
        contains('Pregunta larga del turno'),
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
    // floating chip's own surface; since Ola 3 the solid chrome every
    // floating piece shares.
    void expectOpaqueStickyBackdrop(WidgetTester tester) {
      final stickyRect = tester.getRect(sticky());
      final colors = Theme.of(tester.element(sticky())).hermes;
      final face = tester.widget<Material>(
        find.descendant(of: sticky(), matching: find.byType(Material)).first,
      );
      expect(face.color, HermesChrome.of(colors).fill);
      final backdrop = find.byKey(
        const ValueKey('chat-pinned-prompt-backdrop'),
      );
      final rect = tester.getRect(backdrop);
      final gradient =
          (tester.widget<DecoratedBox>(backdrop).decoration as BoxDecoration)
                  .gradient!
              as LinearGradient;
      expect(gradient.colors[1].a, 1);
      expect(rect.left, lessThanOrEqualTo(stickyRect.left));
      expect(rect.right, greaterThanOrEqualTo(stickyRect.right));
      expect(rect.top, lessThanOrEqualTo(stickyRect.top));
      expect(
        rect.top + gradient.stops![1] * rect.height,
        greaterThanOrEqualTo(stickyRect.bottom),
      );
      expect(
        tester.getRect(
          find.descendant(of: sticky(), matching: find.byType(Material)).first,
        ),
        stickyRect,
      );
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
      // Queue management is supplemental activity; ordinary tool work
      // remains in the conversation and does not create this footer.
      expect(chat.enqueue('PUBLIC_QUEUED_STICKY'), isTrue);
      await settle(tester);
      final pill = find.byKey(const ValueKey('chat-queue-chip'));
      expect(pill, findsOneWidget, reason: 'precondition: queued input pill');

      await tester.tap(find.byKey(const ValueKey('chat-queue-open')));
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
      expect(tester.getSemantics(sticky()).label, contains('Revisa el perfil'));
      expectOpaqueStickyBackdrop(tester);

      await chat.cancelQueuedByIdentity(chat.queuedEntries.single.id);
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
    Finder dismiss() => find.byKey(const ValueKey('chat-jump-to-prompt'));

    // Vistas v3: the header and the pinned chip are one strip of glass.
    // These tests guard the solid band, which is the glass' fallback
    // (reduced motion, high contrast, a device that does not blur): they run
    // without blur. The glass case: «the pinned chip is a piece of the
    // header's glass» below.
    setUp(() => FrostedBackdropPolicy.blurAllowed.value = false);
    tearDown(() => FrostedBackdropPolicy.blurAllowed.value = true);

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
      final prompt = tester.widget<ChatPinnedPromptHeader>(header().last);
      for (final tag in ['A', 'B']) {
        if (prompt.text.contains('Pregunta $tag del turno')) return tag;
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
      expect(box.size, const Size(48, 48));
      expect(
        find.descendant(
          of: header(),
          matching: find.byIcon(Icons.arrow_upward_rounded),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(header()).label,
        contains('Pregunta B del turno larga'),
      );
      // The destination is revealed without wrapping when activated.
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
      final island = tester.getRect(find.byType(ChatIsland).first);
      expect(chip.size, const Size(48, 48));
      expect(chip.right, inInclusiveRange(screen.right - 24, screen.right));
      expect(chip.top, greaterThanOrEqualTo(island.bottom));
      expect(chip.top - island.bottom, lessThanOrEqualTo(20));
      // Never over the composer or the bottom bars, and the reply keeps
      // rows to read between them.
      final bars = tester.getRect(
        find.byKey(const ValueKey('chat-bottom-bars')),
      );
      final composer = tester.getRect(
        find.byKey(const ValueKey('chat-composer-host')),
      );
      final backdrop = tester.getRect(
        find.byKey(const ValueKey('chat-pinned-prompt-backdrop')),
      );
      expect(chip.overlaps(composer), isFalse);
      expect(backdrop.overlaps(composer), isFalse);
      expect(backdrop.bottom, lessThanOrEqualTo(bars.top + 0.5));
      expect(bars.top - backdrop.bottom, greaterThanOrEqualTo(48));
      final floating = find.descendant(
        of: header(),
        matching: find.byType(HermesFloatingSurface),
      );
      expect(floating, findsOneWidget);
      final face = tester.widget<Material>(
        find.descendant(of: floating, matching: find.byType(Material)).first,
      );
      final colors = Theme.of(tester.element(header())).hermes;
      expect(face.color, HermesChrome.of(colors).fill);
      expect(face.shape, isA<StadiumBorder>());
      expect(tester.getSemantics(header()).label, contains('Vale'));
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
      expect(tester.getSemantics(header()).label, contains('📎 2'));
      expect(
        tester.widget<ChatPinnedPromptHeader>(header()).attachmentCount,
        2,
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

    testWidgets(
      'long press hides the arrow for this chat only, and it stays hidden',
      (tester) async {
        final gateway = _StreamingGateway();
        await pumpChat(tester, gateway, history: twoLongTurns());
        await settle(tester);
        await settleHeader(tester);
        expect(headerState(tester), 'B');

        await tester.longPress(dismiss());
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
        final stored = {
          for (final key in prefs.getKeys()) key: prefs.get(key)!,
        };
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
      },
    );

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
    testWidgets('long press offers Undo in a notice, which shows it again', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: twoLongTurns());
      await settle(tester);
      await settleHeader(tester);
      expect(headerState(tester), 'B');

      await tester.longPress(dismiss());
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

      await tester.longPress(dismiss());
      await settleHeader(tester);
      expect(find.text('Oculta en este chat'), findsOneWidget);
      // A routine status notice lands right behind it.
      HermesNotice.of(tester.element(find.byType(ChatScreen)))
          .show(message: 'Aviso de fondo');
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
        await tester.tap(find.byKey(const ValueKey('chat-settings-button')));
        await settleHeader(tester);
        expect(find.byKey(const ValueKey('chat-control-dialog')), findsOne);
      }

      await openMenu();
      expect(show, findsNothing);
      await tester.binding.handlePopRoute();
      await settleHeader(tester);

      await tester.longPress(dismiss());
      await settleHeader(tester);
      HermesNotice.of(tester.element(find.byType(Scaffold).last))
          .removeCurrentSnackBar();
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
      // On a compact viewport the action may sit low in the sheet: scroll
      // its own list to it. Ajustes hangs from the header, so a finger
      // pulling it up takes it away (the way it came): no drag here.
      await tester.ensureVisible(show);
      await tester.pump();
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
      await tester.longPress(dismiss());
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
    // The newest row can always rest above the composer (Vistas v3: no
    // notch on it any more).
    final padding = tester.widget<ListView>(list).padding! as EdgeInsets;
    expect(padding.bottom, greaterThan(bars.height));
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

  // REVIEW-T2-A C3: the F3 reveal clock inside the chat. It runs only while
  // there is text to reveal, it is not used with reduced motion (the whole
  // text at once), and closing the chat in the middle of a burst leaves no
  // clock behind. Counted with [debugActiveChatRevealClocks]: a check on
  // `hasScheduledFrame` would also see the turn's own once-a-second timer
  // and the status line's beat, which are not the reveal.
  group('F3 reveal clock in the chat', () {
    // Q9SUAVE paints a composed reply; Text finders also see its hidden tail.
    // Keep the visibility assertions on the renderer, including the last
    // letters' opacity/height, instead of treating source presence as paint.
    Finder painted(String phrase) => find.byElementPredicate((element) {
      if (element.widget is! LiveReplyReveal) return false;
      final render = element.renderObject;
      return render is RenderLiveReplyReveal &&
          render.visibleText.contains(phrase) &&
          render.settled;
    });

    Future<ActiveChat> start(
      WidgetTester tester,
      _StreamingGateway gateway,
    ) async {
      final chat = await pumpChat(tester, gateway, history: _history(turns: 3));
      await tester.pump(const Duration(seconds: 1));
      await chat.send(
        fullText: 'Cuéntame algo largo',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit('message.start');
      await settle(tester);
      return chat;
    }

    /// The service's turn ends as a real one does: its token flush and its
    /// activity watchdog belong to the turn, which outlives the screen
    /// (gint48: left streaming, they were the pending timers).
    Future<void> endTurn(
      WidgetTester tester,
      _StreamingGateway gateway,
      ActiveChat chat,
    ) async {
      gateway.emit('message.complete', {'text': chat.assistantContent});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(chat.isStreaming, isFalse);
    }

    final burst = [
      ...List.filled(60, 'Una frase que se revela palabra a palabra.'),
      'FIN-DE-RAFAGA.',
    ].join(' ');

    testWidgets('it runs while there is text to reveal, then stops', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await start(tester, gateway);
      expect(debugActiveChatRevealClocks, 0);
      gateway.emit('message.delta', {'text': burst});
      var ran = false;
      for (
        var frame = 0;
        frame < 120 && painted('FIN-DE-RAFAGA').evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
        ran |= debugActiveChatRevealClocks == 1;
      }
      expect(painted('FIN-DE-RAFAGA'), findsOneWidget);
      expect(ran, isTrue, reason: 'a burst is revealed by the clock');
      // Everything shown, the turn still streaming: the clock has stopped.
      await tester.pump(const Duration(milliseconds: 33));
      expect(chat.isStreaming, isTrue);
      expect(debugActiveChatRevealClocks, 0);
      await endTurn(tester, gateway, chat);
      await tearDownChat(tester, gateway);
    });

    testWidgets('reduced motion: the whole burst in the frame it arrives', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final gateway = _StreamingGateway();
      final chat = await start(tester, gateway);
      gateway.emit('message.delta', {'text': burst});
      // The event reaches the service through the test gateway's stream;
      // as the other reduced-motion tests do, wait until it has the text
      // (gint48: one bare pump was not enough for the delta to arrive).
      for (
        var frame = 0;
        frame < 100 && !chat.assistantContent.contains('FIN-DE-RAFAGA');
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
        expect(debugActiveChatRevealClocks, 0, reason: 'no reveal clock');
      }
      // One frame with no time passing: with motion a step shows about an
      // eighth of a burst, here the whole of it is already there.
      await tester.pump();
      expect(find.textContaining('FIN-DE-RAFAGA'), findsOneWidget);
      expect(debugActiveChatRevealClocks, 0);
      await endTurn(tester, gateway, chat);
      await tearDownChat(tester, gateway);
    });

    testWidgets('closing the chat in the middle of a burst leaves no clock', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      final chat = await start(tester, gateway);
      gateway.emit('message.delta', {'text': burst});
      for (
        var frame = 0;
        frame < 30 && debugActiveChatRevealClocks == 0;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(debugActiveChatRevealClocks, 1, reason: 'mid-burst');
      expect(painted('FIN-DE-RAFAGA'), findsNothing);
      // The chat screen goes away mid-burst: its clock goes with it…
      await tester.pumpWidget(const SizedBox.shrink());
      expect(debugActiveChatRevealClocks, 0);
      // …and frames go on with none left (a leaked clock would tick here).
      await tester.pump(const Duration(milliseconds: 100));
      expect(debugActiveChatRevealClocks, 0);
      // The turn itself lives in the service, past the screen; it ends.
      await endTurn(tester, gateway, chat);
      await gateway.close();
    });
  });

  // Last in the file: the composer send crosses real async work (outbox,
  // storage) and its leftovers must not reach the tests above.
  group('scroll-follow: his own message goes down', () {
    testWidgets('sending from the composer while reading goes down, always', (
      tester,
    ) async {
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway, history: _history());
      await tester.pump(const Duration(seconds: 1));
      await scrollUp(tester, 300);
      final controller = controllerOf(tester);
      expect(controller.position.pixels, greaterThan(150));
      await tester.enterText(
        find.descendant(
          of: find.byType(ConsoleComposer),
          matching: find.byType(TextField),
        ),
        'Mensaje propio',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      // The ACK crosses real async work (outbox, storage): give it real time.
      for (var frame = 0; frame < 40; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(find.text('Mensaje propio'), findsWidgets);
      expect(
        controller.position.pixels,
        closeTo(0, 0.5),
        reason: 'sending his own message goes down, always',
      );
      // End the turn the send started, then let its own timers run out.
      gateway.emit('message.start');
      gateway.emit('message.complete', {'text': 'Hecho.'});
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 40));
      await tearDownChat(tester, gateway);
    });
  });
}

/// How the keyboard reaches the chat (QA 9709 band tests).
enum _Keyboard { none, inset, resized }
