import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';

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
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
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
      ..internalMessagesForTesting = history ?? _history()
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
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    return chat;
  }

  Finder transcript() => find.descendant(
    of: find.byType(ChatScrollInteractionGuard),
    matching: find.byType(ListView),
  );

  Set<Element> under(Finder f) {
    final out = <Element>{};
    for (final root in f.evaluate()) {
      void collect(Element e) {
        out.add(e);
        e.visitChildren(collect);
      }

      collect(root);
    }
    return out;
  }

  /// What one 60-frame scroll costs: rebuilds of the screen, of existing
  /// transcript rows and of the header; paints under the header; and the
  /// offscreen layers (opacity < 1, blur, shader masks) composited per frame.
  Future<Map<String, int>> measure(
    WidgetTester tester,
    Future<void> Function() drive,
  ) async {
    final screen = tester.element(find.byType(ChatScreen));
    final header = under(find.byType(FloatingChatHeader));
    final rows = under(
      find.descendant(of: transcript(), matching: find.byType(SliverList)),
    );
    final headerRO = {
      for (final e in header)
        if (e.renderObject != null) e.renderObject!,
    };
    final out = <String, int>{
      'screen': 0,
      'rows': 0,
      'header': 0,
      'switcher': 0,
      'headerPaints': 0,
      'offscreenLayers': 0,
      'filterLayers': 0,
    };
    final mountedTransitions = <Element>{};
    debugOnRebuildDirtyWidget = (element, _) {
      if (identical(element, screen)) out['screen'] = out['screen']! + 1;
      if (rows.contains(element)) out['rows'] = out['rows']! + 1;
      if (header.contains(element)) out['header'] = out['header']! + 1;
      // A transition that rebuilds again after it mounted is animating.
      if (element.widget is SlideTransition &&
          !mountedTransitions.add(element)) {
        out['switcher'] = out['switcher']! + 1;
      }
    };
    debugProfilePaintsEnabled = true;
    debugOnProfilePaint = (ro) {
      if (headerRO.contains(ro)) out['headerPaints'] = out['headerPaints']! + 1;
    };
    addTearDown(() {
      debugOnRebuildDirtyWidget = null;
      debugOnProfilePaint = null;
      debugProfilePaintsEnabled = false;
    });
    await drive();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      void walk(Layer? l) {
        if (l == null) return;
        if (l is OpacityLayer && (l.alpha ?? 255) < 255) {
          out['offscreenLayers'] = out['offscreenLayers']! + 1;
        }
        if (l is BackdropFilterLayer ||
            l is ShaderMaskLayer ||
            l is ImageFilterLayer) {
          out['filterLayers'] = out['filterLayers']! + 1;
        }
        if (l is ContainerLayer) {
          var c = l.firstChild;
          while (c != null) {
            walk(c);
            c = c.nextSibling;
          }
        }
      }

      walk(tester.binding.renderViews.first.debugLayer);
    }
    debugOnRebuildDirtyWidget = null;
    debugOnProfilePaint = null;
    debugProfilePaintsEnabled = false;
    return out;
  }

  testWidgets('pm1215: a fling through a 60-turn chat rebuilds no row, no '
      'screen and no header, repaints no header and composites no '
      'offscreen layer per frame', (tester) async {
    final gateway = _StreamingGateway();
    await pumpChat(tester, gateway, history: _history(turns: 60));
    // Nothing blurs or masks the transcript (BackdropFilter / ShaderMask
    // over a scrolling list re-render every frame on Android).
    for (final type in [BackdropFilter, ShaderMask, ImageFiltered]) {
      expect(
        find.descendant(
          of: find.byType(ChatScreen),
          matching: find.byWidgetPredicate((w) => w.runtimeType == type),
        ),
        findsNothing,
        reason: '$type in the chat',
      );
    }
    // Leave the bottom first (the jump arrow's own fade is not under test).
    await tester.fling(transcript(), const Offset(0, 500), 2500);
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    final fling = await measure(tester, () async {
      await tester.fling(transcript(), const Offset(0, 500), 2500);
    });
    // ignore: avoid_print
    print('pm1215 fling-mid: $fling');
    expect(fling['screen'], 0, reason: 'screen-wide setState while scrolling');
    expect(fling['rows'], 0, reason: 'existing rows rebuilt while scrolling');
    expect(fling['header'], 0, reason: 'header rebuilt while scrolling');
    expect(fling['headerPaints'], 0, reason: 'header repainted');
    expect(fling['filterLayers'], 0);
    // The pinned prompt changes as turns pass under the header: it swaps
    // in place while the list moves, never cross-fades (a fade is an
    // offscreen layer and a rebuild on every frame of the fling).
    expect(fling['switcher'], 0, reason: 'pinned prompt animated mid-fling');
    expect(fling['offscreenLayers'], 0, reason: 'opacity layers mid-fling');
    final drag = await measure(tester, () async {
      final g = await tester.startGesture(tester.getCenter(transcript()));
      for (var i = 0; i < 30; i++) {
        await g.moveBy(const Offset(0, 14));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
    });
    // ignore: avoid_print
    print('pm1215 drag: $drag');
    expect(drag['screen'], 0);
    expect(drag['rows'], 0);
    expect(drag['switcher'], 0);
    expect(drag['offscreenLayers'], 0);
    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });
}
