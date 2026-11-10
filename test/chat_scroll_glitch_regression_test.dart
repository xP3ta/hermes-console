// Scroll continuity and rebuild isolation of the chat transcript: the jump
// arrow, the keyboard, the composer, a width change, the search reveal and
// live-only tool flushes. Each test pins a reader-visible symptom (a list
// that moved back, a place lost, every cached row rebuilt) rather than an
// implementation detail.
import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
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
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/widgets/chat/chat_notch.dart'
    show kChatNotchSheetOpen;
import 'package:hermes_android/core/widgets/chat_turn_activity.dart'
    show LiveTurnTasks;
import 'package:hermes_android/core/widgets/subagent_activity_card.dart'
    show SubagentActivityCard;
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
    runtimeSessionId: 'runtime-scroll-glitch',
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
    runtimeSessionId: 'runtime-scroll-glitch',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-scroll-glitch',
    storedSessionId: 'sess-scroll-glitch',
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
        sessionId: 'runtime-scroll-glitch',
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
  id: 'conn-scroll-glitch',
  label: 'Scroll glitches',
  host: 'example.test',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-scroll-glitch',
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

List<Map<String, dynamic>> _history({int turns = 60}) {
  final messages = <Map<String, dynamic>>[];
  for (var turn = turns - 1; turn >= 0; turn--) {
    messages.add({
      'id': 'h-a-$turn',
      'role': 'assistant',
      'content':
          'Respuesta histórica $turn. '
          'Este texto ocupa varias líneas para que el historial tenga '
          'suficiente recorrido y el lector pueda quedarse a mitad.',
    });
    messages.add({
      'id': 'h-u-$turn',
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

  Future<({ActiveChat chat, ChatPerformanceProbe probe})> pumpChat(
    WidgetTester tester,
    _StreamingGateway gateway, {
    List<Map<String, dynamic>>? history,
  }) async {
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
      sessionId: 'sess-scroll-glitch',
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

    final probe = ChatPerformanceProbe();
    final navigatorContext = tester.element(find.byType(Navigator).first);
    Navigator.of(navigatorContext).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          connection: connection,
          session: _session(),
          performanceProbe: probe,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    return (chat: chat, probe: probe);
  }

  Finder transcript() => find.descendant(
    of: find.byType(ChatScrollInteractionGuard),
    matching: find.byType(ListView),
  );

  /// The sliver holding the rows: what is under it is the rows themselves,
  /// not the list's own scroll chain (which re-pads itself from notifiers).
  Finder rows() =>
      find.descendant(of: transcript(), matching: find.byType(SliverList));

  ScrollController controllerOf(WidgetTester tester) =>
      tester.widget<ListView>(transcript()).controller!;

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

  /// Rebuilds of elements that already existed under [root] (new rows that
  /// the sliver materializes are not counted).
  int Function() countRebuildsUnder(Element root) {
    var count = 0;
    final existing = Set<Element>.identity()..add(root);
    void collect(Element element) {
      existing.add(element);
      element.visitChildren(collect);
    }

    root.visitChildren(collect);
    debugOnRebuildDirtyWidget = (element, _) {
      if (!existing.contains(element)) return;
      if (identical(element, root)) {
        count++;
        return;
      }
      element.visitAncestorElements((ancestor) {
        if (!identical(ancestor, root)) return true;
        count++;
        return false;
      });
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    return () => count;
  }

  void usePhoneView(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1280, 2856)
      ..devicePixelRatio = 3.0
      ..padding = const FakeViewPadding(top: 120, bottom: 72)
      ..viewPadding = const FakeViewPadding(top: 120, bottom: 72);
    addTearDown(tester.view.reset);
  }

  /// A historical answer painted well inside the viewport, or null.
  int? visibleTurn(WidgetTester tester) {
    final viewport = tester.getRect(transcript());
    for (var turn = 0; turn < 60; turn++) {
      final f = find.textContaining('Respuesta histórica $turn.');
      if (f.evaluate().isEmpty) continue;
      final dy = tester.getTopLeft(f.first).dy;
      if (dy >= viewport.top + 80 && dy < viewport.bottom - 160) return turn;
    }
    return null;
  }

  /// The historical answer whose text is nearest the viewport's centre: the
  /// one the reader is looking at.
  int? centreTurn(WidgetTester tester) {
    final viewport = tester.getRect(transcript());
    int? best;
    var bestDistance = double.infinity;
    for (var turn = 0; turn < 60; turn++) {
      final f = find.textContaining('Respuesta histórica $turn.');
      if (f.evaluate().isEmpty) continue;
      final rect = tester.getRect(f.first);
      if (rect.bottom <= viewport.top || rect.top >= viewport.bottom) continue;
      final distance = (rect.center.dy - viewport.center.dy).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = turn;
      }
    }
    return best;
  }

  Visibility transcriptVisibility(WidgetTester tester) => tester
      .widgetList<Visibility>(
        find.ancestor(of: transcript(), matching: find.byType(Visibility)),
      )
      .firstWhere((visibility) => visibility.maintainSize);

  group('jump arrow', () {
    testWidgets('tapping it never moves the list back up', (tester) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway);
      await settle(tester);
      await scrollUp(tester, 700);
      final controller = controllerOf(tester);
      expect(controller.position.pixels, greaterThan(400));
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-visible')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('chat-scroll-to-bottom')));
      var previous = controller.position.pixels;
      var maxRise = 0.0;
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final pixels = controller.position.pixels;
        if (pixels - previous > maxRise) maxRise = pixels - previous;
        previous = pixels;
      }
      expect(tester.takeException(), isNull);
      expect(
        maxRise,
        lessThan(1),
        reason: 'the list moved back up in the middle of the animation',
      );
      expect(controller.position.pixels, 0);
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-visible')),
        findsNothing,
      );
      await tearDownChat(tester, gateway);
    });

    testWidgets('it fades in instead of popping', (tester) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway);
      await settle(tester);
      final gesture = await tester.startGesture(tester.getCenter(transcript()));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-visible')),
        findsOneWidget,
      );
      // 80 ms into a 160 ms fade: the arrow is on its way, not already there.
      await tester.pump(const Duration(milliseconds: 80));
      final fade = tester.widget<FadeTransition>(
        find.descendant(
          of: find.byKey(const ValueKey('chat-scroll-to-bottom-fade')),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fade.opacity.value, greaterThan(0));
      expect(fade.opacity.value, lessThan(1));
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });

    testWidgets('its appearance rebuilds no existing row', (tester) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway);
      await settle(tester);
      final list = tester.element(transcript());
      final controller = controllerOf(tester);
      final rebuilds = countRebuildsUnder(list);
      final gesture = await tester.startGesture(tester.getCenter(transcript()));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      var before = rebuilds();
      for (var i = 0; i < 5; i++) {
        await gesture.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(rebuilds() - before, 0, reason: 'rows rebuilt during a drag');
      expect(controller.position.pixels, lessThan(100));
      before = rebuilds();
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.position.pixels, greaterThan(100));
      expect(
        find.byKey(const ValueKey('scroll-to-bottom-visible')),
        findsOneWidget,
      );
      expect(
        rebuilds() - before,
        0,
        reason: 'rows rebuilt when the jump arrow appeared',
      );
      await gesture.up();
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });
  });

  group('composer and keyboard', () {
    testWidgets('typing three lines into an empty composer rebuilds no '
        'transcript row and no screen', (tester) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      final pumped = await pumpChat(tester, gateway);
      await settle(tester);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final rebuilds = countRebuildsUnder(tester.element(rows()));
      final h0 = tester.getSize(composer).height;
      pumped.probe.reset();
      await tester.enterText(composer, 'línea uno\nlínea dos\nlínea tres');
      await settle(tester);
      final h1 = tester.getSize(composer).height;
      expect(tester.takeException(), isNull);
      expect(h1, greaterThan(h0), reason: 'the composer did not grow');
      expect(rebuilds(), 0, reason: 'composer growth rebuilt transcript rows');
      expect(pumped.probe.screenBuilds, 0);
      // Emptying it again (the send button goes back to idle) costs the same.
      await tester.enterText(composer, '');
      await settle(tester);
      expect(rebuilds(), 0, reason: 'emptying the composer rebuilt rows');
      expect(pumped.probe.screenBuilds, 0);
      await tearDownChat(tester, gateway);
    });

    testWidgets('the keyboard opening while reading up keeps the place', (
      tester,
    ) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway);
      await settle(tester);
      await scrollUp(tester, 700);
      final controller = controllerOf(tester);
      final p0 = controller.position.pixels;
      final turn0 = visibleTurn(tester);
      expect(turn0, isNotNull);
      for (final inset in [180.0, 450.0, 720.0, 900.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      final p1 = controller.position.pixels;
      final turn1 = visibleTurn(tester);
      tester.view.resetViewInsets();
      expect(tester.takeException(), isNull);
      expect(
        (p1 - p0).abs(),
        lessThan(60),
        reason: 'the keyboard moved a reader who was reading up',
      );
      expect(turn1, turn0, reason: 'the keyboard changed what is read');
      await tearDownChat(tester, gateway);
    });
  });

  group('width change', () {
    testWidgets('unfolding (426 -> 840 dp) while reading up keeps the text '
        'being read where it was', (tester) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      await pumpChat(tester, gateway);
      await settle(tester);
      await scrollUp(tester, 900);
      final controller = controllerOf(tester);
      expect(controller.position.pixels, greaterThan(600));
      final turn = centreTurn(tester);
      expect(turn, isNotNull, reason: 'no answer in view');
      final marker = find.textContaining('Respuesta histórica $turn.');
      // The foot of the text: wider rows wrap fewer lines, so the top of a
      // paragraph moves even when its last line stays put.
      final bottom0 = tester.getRect(marker.first).bottom;
      tester.view.physicalSize = const Size(2520, 2856);
      await settle(tester);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(marker, findsOneWidget, reason: 'the row being read was lost');
      final viewport = tester.getRect(transcript());
      final rect = tester.getRect(marker.first);
      expect(rect.top, greaterThanOrEqualTo(viewport.top));
      expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(
        (rect.bottom - bottom0).abs(),
        lessThan(24),
        reason: 'the text being read moved by more than a line',
      );
      await tearDownChat(tester, gateway);
    });
  });

  group('search', () {
    Future<void> openFind(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('chat-settings-button')));
      await tester.pump();
      await tester.pump(kChatNotchSheetOpen);
      await tester.tap(find.byKey(const ValueKey('chat-control-find')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const ValueKey('chat-find-bar')), findsOneWidget);
    }

    testWidgets('revealing a match far above hides the walk: one visible '
        'move, then the match', (tester) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      final pumped = await pumpChat(tester, gateway);
      await settle(tester);
      final controller = controllerOf(tester);
      final far = find.textContaining('Respuesta histórica 50.');
      expect(far, findsNothing, reason: 'the target row must not be built');
      await openFind(tester);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('chat-find-field')),
          matching: find.byType(TextField),
        ),
        'histórica 50',
      );
      final start = controller.position.pixels;
      var concealedFrames = 0;
      final paintedOffsets = <int>{};
      for (var frame = 0; frame < 160; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (!transcriptVisibility(tester).visible) {
          concealedFrames++;
        } else {
          paintedOffsets.add(controller.position.pixels.round());
        }
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.text('1 de 2'), findsOneWidget);
      expect(concealedFrames, greaterThan(0), reason: 'the walk was painted');
      expect(transcriptVisibility(tester).visible, isTrue);
      expect(far, findsOneWidget);
      final viewport = tester.getRect(transcript());
      final rect = tester.getRect(far.first);
      expect(rect.top, greaterThanOrEqualTo(viewport.top));
      expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
      // Painted frames show the start and the landing, never a screen of
      // the walk in between.
      expect(
        paintedOffsets.where((p) => p != start.round()).length,
        lessThanOrEqualTo(1),
        reason: 'intermediate offsets of the walk were painted',
      );

      // Closing the bar is one screen build: the notice's height change is
      // a padding update, not a second build after the frame.
      pumped.probe.reset();
      await tester.tap(find.byKey(const ValueKey('chat-find-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('chat-find-bar')), findsNothing);
      expect(pumped.probe.screenBuilds, lessThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    });
  });

  group('live turn', () {
    Future<({ActiveChat chat, ChatPerformanceProbe probe})> startTurn(
      WidgetTester tester,
      _StreamingGateway gateway,
    ) async {
      final pumped = await pumpChat(tester, gateway);
      await tester.pump(const Duration(seconds: 1));
      await pumped.chat.send(
        fullText: 'Prueba también la lista de tareas',
        model: 'hermes-agent',
        history: pumped.chat.buildHistory(),
      );
      gateway.emit('message.start');
      await settle(tester);
      return pumped;
    }

    /// Every element of every row above the live turn's (its reply row,
    /// found by its live trace, and its prompt right after it in the
    /// reversed list). The task line of the turn before ([LiveTurnTasks])
    /// reads the live scope by design and is left out.
    Set<Element> olderRows(WidgetTester tester) {
      final list = tester.element(rows());
      final live = tester.element(
        find.byKey(const ValueKey('chat-inline-activity'), skipOffstage: false),
      );
      // A sliver child's slot is its index.
      int? indexOf(Element row) => row.slot is int ? row.slot! as int : null;
      var liveIndex = -1;
      list.visitChildren((row) {
        var holdsLive = false;
        live.visitAncestorElements((ancestor) {
          holdsLive = identical(ancestor, row);
          return !holdsLive;
        });
        if (holdsLive) liveIndex = indexOf(row) ?? -1;
      });
      expect(liveIndex, greaterThanOrEqualTo(0), reason: 'no live row');
      final found = <Element>{};
      void collect(Element element) {
        if (element.widget is LiveTurnTasks) return;
        found.add(element);
        element.visitChildren(collect);
      }

      list.visitChildren((row) {
        if ((indexOf(row) ?? 0) <= liveIndex + 1) return;
        collect(row);
      });
      return found;
    }

    testWidgets('a burst of subagent events with the reader up rebuilds no '
        'older row and no screen', (tester) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      final pumped = await startTurn(tester, gateway);
      final chat = pumped.chat;
      gateway.emit('reasoning.delta', {'text': 'Pienso en cómo probarlo. '});
      await settle(tester);
      // The first subagent changes what the screen shows (its card
      // appears): one screen build. Its tool events afterwards do not.
      gateway.emit('subagent.start', const {
        'subagent_id': 'busy-child',
        'goal': 'Revisar los ficheros',
        'status': 'running',
      });
      await settle(tester);
      SubagentActivityCard card() => tester.widget<SubagentActivityCard>(
        find.byKey(const ValueKey('chat-subagent-status'), skipOffstage: false),
      );
      expect(card().activities, hasLength(1));
      await scrollUp(tester, 700);
      final controller = controllerOf(tester);
      expect(controller.position.pixels, greaterThan(400));

      final older = olderRows(tester);
      expect(older, isNotEmpty);
      var olderRebuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (older.contains(element)) olderRebuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      pumped.probe.reset();
      for (var frame = 0; frame < 6; frame++) {
        for (var i = 0; i < 6; i++) {
          gateway.emit('subagent.tool', {
            'subagent_id': 'busy-child',
            'status': 'tool',
            'tool_name': 'tool_$frame$i',
          });
        }
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 34));
        // The newest event of the burst is on screen: the card repaints on
        // its own revision.
        expect(
          card().activities.single.details.activeToolName,
          'tool_${frame}5',
        );
      }
      await settle(tester);
      debugOnRebuildDirtyWidget = null;
      expect(tester.takeException(), isNull);
      expect(olderRebuilds, 0, reason: 'a subagent flush rebuilt older rows');
      expect(
        pumped.probe.screenBuilds,
        0,
        reason: 'a subagent flush built the screen',
      );
      expect(controller.position.pixels, greaterThan(400));

      gateway.emit('subagent.complete', const {
        'subagent_id': 'busy-child',
        'status': 'completed',
        'summary': 'Hecho',
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(
        pumped.probe.screenBuilds,
        0,
        reason: 'settling the subagent pill must not rebuild the screen',
      );
      gateway.emit('message.complete', {'text': 'Listo.'});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await tearDownChat(tester, gateway);
    });

    testWidgets('steps arriving in a burst carry a reader in the follow band '
        'to the tail in one motion', (tester) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      final chat = (await startTurn(tester, gateway)).chat;
      final controller = controllerOf(tester);
      // A wheel scroll leaves the follow on (no touch paused it): the list
      // is 60 px up, inside the 100 px band, and still following the tail.
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final centre = tester.getCenter(transcript());
      await tester.sendEventToBinding(pointer.hover(centre));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -60)));
      await tester.pump();
      expect(controller.position.pixels, greaterThan(40));
      var previous = controller.position.pixels;
      var maxRise = 0.0;
      for (var step = 0; step < 10; step++) {
        gateway.emit(step.isEven ? 'tool.start' : 'tool.complete', {
          'tool_id': 'call-${step ~/ 2}',
          'name': 'terminal',
          if (step.isEven) 'args': {'command': 'ls $step'},
        });
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 14));
        final pixels = controller.position.pixels;
        if (pixels - previous > maxRise) maxRise = pixels - previous;
        previous = pixels;
      }
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final pixels = controller.position.pixels;
        if (pixels - previous > maxRise) maxRise = pixels - previous;
        previous = pixels;
      }
      expect(tester.takeException(), isNull);
      expect(maxRise, lessThan(1), reason: 'the list moved back up');
      expect(controller.position.pixels, 0);
      gateway.emit('message.complete', {'text': 'Listo.'});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await tearDownChat(tester, gateway);
    });

    testWidgets('steps arriving in a burst do not move a reader 300 px above the '
        'tail (only a reader pinned to the tail is followed)', (tester) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      final chat = (await startTurn(tester, gateway)).chat;
      final controller = controllerOf(tester);
      // A wheel scroll leaves the flag on, but the gate needs the reader
      // within 100 px of the tail: 300 px up is a reader, not a follower.
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final centre = tester.getCenter(transcript());
      await tester.sendEventToBinding(pointer.hover(centre));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -300)));
      await tester.pump();
      expect(controller.position.pixels, greaterThan(250));
      var previous = controller.position.pixels;
      var maxRise = 0.0;
      for (var step = 0; step < 10; step++) {
        gateway.emit(step.isEven ? 'tool.start' : 'tool.complete', {
          'tool_id': 'call-${step ~/ 2}',
          'name': 'terminal',
          if (step.isEven) 'args': {'command': 'ls $step'},
        });
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 14));
        final pixels = controller.position.pixels;
        if (pixels - previous > maxRise) maxRise = pixels - previous;
        previous = pixels;
      }
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final pixels = controller.position.pixels;
        if (pixels - previous > maxRise) maxRise = pixels - previous;
        previous = pixels;
      }
      expect(tester.takeException(), isNull);
      expect(maxRise, lessThan(1), reason: 'the list moved');
      expect(
        controller.position.pixels,
        greaterThan(250),
        reason: 'a reader 300 px above the tail must not be carried down',
      );
      gateway.emit('message.complete', {'text': 'Listo.'});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await tearDownChat(tester, gateway);
    });
  });
}
