import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/services/busy_input_mode.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'support/test_api_client.dart';
import 'support/in_memory_compression_restore_storage.dart';

SavedConnection _connection() => SavedConnection(
  id: 'conn-busy-input',
  label: 'Composer recall',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
);

Session _session() => Session(
  id: 'sess-busy-input',
  title: 'Recuperar mensaje',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

class _BusyGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopIdempotentGateway,
        HermesDesktopRedirectGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  final calls = <String>[];
  final turnIds = <String>[];
  Completer<void>? interruptAck;
  Completer<void>? redirectAck;
  Completer<void>? submitAck;
  Future<void> Function()? onRedirect;
  Object? redirectError;
  Object? interruptError;
  Object? steerError;
  bool completeOnInterrupt = true;
  DesktopRedirectDisposition redirectDisposition =
      DesktopRedirectDisposition.redirected;

  void completeTurn() => _events.add(
    const TuiGatewayEvent(
      type: 'message.complete',
      sessionId: 'runtime-busy',
      payload: {'text': 'finished'},
    ),
  );
  bool interruptUnsupported = false;
  bool steerUnsupported = false;

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
    runtimeSessionId: 'runtime-busy',
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
    runtimeSessionId: 'runtime-busy',
    storedSessionId: storedSessionId,
    created: false,
  );
  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => resumeExisting('sess-busy-input', profile: profile);
  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    calls.add('send:$text');
    await submitAck?.future;
  }

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    turnIds.add(clientTurnId);
    calls.add('send:$text');
    await submitAck?.future;
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-$clientTurnId',
      state: DesktopTurnState.accepted,
      duplicate: false,
    );
  }

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String runtimeSessionId,
    String clientTurnId,
  ) async => DesktopTurnStatus(known: false, clientTurnId: clientTurnId);
  @override
  Future<void> interrupt(String runtimeSessionId) async {
    calls.add('interrupt');
    if (interruptUnsupported) {
      throw const TuiGatewayRpcError(
        'session.interrupt',
        'missing',
        code: -32601,
      );
    }
    if (interruptError case final error?) throw error;
    await interruptAck?.future;
    calls.add('ack');
    if (completeOnInterrupt) {
      _events.add(
        const TuiGatewayEvent(
          type: 'message.complete',
          sessionId: 'runtime-busy',
          payload: {'text': '', 'status': 'interrupted'},
        ),
      );
    }
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    calls.add('steer:$text');
    if (steerError case final error?) throw error;
    if (steerUnsupported) {
      throw const TuiGatewayRpcError('session.steer', 'missing', code: -32601);
    }
  }

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    calls.add('redirect:$text');
    await onRedirect?.call();
    await redirectAck?.future;
    if (redirectError case final error?) throw error;
    return redirectDisposition;
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}
  @override
  Future<void> close() => _events.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  late _BusyGateway gateway;
  late Directory support;
  final configRequests = <String>[];
  Object? configMode;
  bool configFails = false;
  Completer<void>? configGate;
  ActiveChat? mountedChat;
  ActiveChatService? mountedService;

  List<PreparedTurn> persistedTurns() {
    // Observe the write itself. loadAllForChat is a recovery operation: it
    // deliberately rewrites any submitting record to ambiguous.
    final raw = secureStore[TurnOutboxStore.storageKeyForTesting] ?? '{}';
    return (jsonDecode(raw) as Map<String, dynamic>).values
        .map(
          (value) =>
              PreparedTurn.fromJson(Map<String, dynamic>.from(value as Map)),
        )
        .toList();
  }

  void mockChannel(String name) {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUp(() {
    secureStore.clear();
    gateway = _BusyGateway();
    support = Directory.systemTemp.createTempSync('busy-input-test');
    configRequests.clear();
    configFails = false;
    configGate = null;
    configMode = null;
    mountedChat = null;
    mountedService = null;
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
          (_) async => support.path,
        );
  });

  tearDown(() async {
    if (support.existsSync()) support.deleteSync(recursive: true);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });

  void testChatWidgets(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        // testWidgets verifies pending timers before package:test tearDowns.
        // Dispose the live turn's watchdog inside the test callback, even if
        // an assertion fails, rather than simulating five minutes of activity.
        mountedChat?.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        mountedService?.dispose();
        await tester.pump();
      }
    });
  }

  Future<ActiveChat> pumpChat(
    WidgetTester tester, {
    String mode = 'queue',
    bool busy = false,
    bool failConfig = false,
    int Function()? wallClockMs,
  }) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view
      ..physicalSize = const Size(1080, 2280)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    configMode = mode;
    configFails = failConfig;
    final routes = MockClient((request) async {
      if (request.url.path == '/api/config') {
        await configGate?.future;
        configRequests.add(request.url.queryParameters['profile'] ?? 'default');
        return http.Response(
          configFails
              ? '{}'
              : jsonEncode({
                  'display': {'busy_input_mode': configMode},
                }),
          configFails ? 503 : 200,
        );
      }
      return http.Response('{}', 404);
    });
    final activeChats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    mountedService = activeChats;
    addTearDown(activeChats.dispose);
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: _session().id,
      sessionTitle: _session().title,
      sessionProfile: 'default',
      initialStoredSessionId: _session().id,
      api: testApiClient(httpClient: routes),
      transcriptDashboard: testDashboardClient(httpClient: routes),
      desktopGateway: gateway,
      wallClockMsForTesting: wallClockMs,
      turnIdempotencyCapability: () async => true,
      storedMessageLoader: (_, _) async => const [],
      disableForegroundKeepAlive: true,
      attachDesktopRuntimeOnLoad: false,
      allowUnownedDesktopSnapshotForTesting: true,
      transcriptPageSizeForTesting: 120,
    );
    mountedChat = chat;
    chat.messagesLoaded = true;

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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));

    final navigatorContext = tester.element(find.byType(Navigator).first);
    Navigator.of(navigatorContext).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(() async {
      await chat.refreshBusyInputMode();
      if (busy) {
        expect(
          await chat.send(
            fullText: 'first turn',
            model: 'hermes-agent',
            profile: 'default',
            history: const [],
          ),
          isTrue,
        );
      }
    });
    await tester.pump();
    return chat;
  }

  Finder composerField() => find.descendant(
    of: find.byType(ConsoleComposer),
    matching: find.byType(TextField),
  );

  TextEditingController composer(WidgetTester tester) =>
      tester.widget<TextField>(composerField()).controller!;

  Future<void> settle(WidgetTester tester) async {
    // Storage and transcript decode may run outside fake widget time.
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> submit(WidgetTester tester, {bool queue = false}) async {
    await tester.enterText(composerField(), 'follow up');
    await tester.pump();
    final widget = tester.widget<ConsoleComposer>(find.byType(ConsoleComposer));
    expect(
      find.byTooltip(
        widget.sendLabel ??
            Strings.of(
              tester.element(find.byType(ConsoleComposer)),
            ).chaSendTooltip,
      ),
      findsOneWidget,
    );
    if (widget.sendLabel != null) {
      expect(widget.sendLabel, isNot(endsWith('…')));
    }
    if (queue) {
      widget.onQueue!();
    } else {
      widget.onSend('follow up', const []);
    }
    await settle(tester);
  }

  const labels = {
    'interrupt': 'Interrumpir y enviar…',
    'queue': 'Poner en cola…',
    'steer': 'Guiar al agente…',
  };
  for (final mode in labels.keys) {
    for (final busy in [false, true]) {
      testChatWidgets(
        '$mode with busy=$busy follows server policy and labels',
        (tester) async {
          final chat = await pumpChat(tester, mode: mode, busy: busy);
          gateway.calls.clear();
          if (busy) {
            expect(
              tester
                  .widget<ConsoleComposer>(find.byType(ConsoleComposer))
                  .hintText,
              labels[mode],
            );
          }
          await submit(tester);
          expect(composer(tester).text, isEmpty);
          if (!busy || mode == 'interrupt') {
            expect(
              gateway.calls,
              busy ? ['redirect:follow up'] : ['send:follow up'],
            );
            expect(chat.queuedEntries, isEmpty);
            expect(gateway.turnIds.toSet().length, gateway.turnIds.length);
          } else if (mode == 'steer') {
            expect(gateway.calls, ['steer:follow up']);
            expect(chat.queuedEntries, isEmpty);
          } else {
            expect(gateway.calls, isEmpty);
            expect(chat.queuedEntries.single.text, 'follow up');
          }
          expect(configRequests, everyElement('default'));
        },
      );
    }
  }

  test(
    'opening another profile refreshes from its own server config',
    () async {
      final requests = <String>[];
      var researchMode = 'steer';
      final routes = MockClient((request) async {
        final profile = request.url.queryParameters['profile'] ?? 'default';
        requests.add(profile);
        return http.Response(
          jsonEncode({
            'display': {
              'busy_input_mode': profile == 'research' ? researchMode : 'queue',
            },
          }),
          200,
        );
      });
      final service = ActiveChatService(
        attachDesktopRuntimeOnLoad: false,
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(service.dispose);
      ActiveChat open(String profile) => service.attach(
        connection: _connection(),
        sessionId: 'owned-$profile',
        sessionTitle: profile,
        sessionProfile: profile,
        api: testApiClient(httpClient: routes),
        transcriptDashboard: testDashboardClient(httpClient: routes),
        desktopGateway: _BusyGateway(),
        disableForegroundKeepAlive: true,
      );
      final main = open('default');
      final research = open('research');
      await main.refreshBusyInputMode();
      await research.refreshBusyInputMode();
      expect(main.busyInputMode, BusyInputMode.queue);
      expect(research.busyInputMode, BusyInputMode.steer);
      researchMode = 'interrupt';
      await research.refreshBusyInputMode();
      expect(research.busyInputMode, BusyInputMode.interrupt);
      expect(main.busyInputMode, BusyInputMode.queue);
      expect(requests, ['default', 'research', 'research']);
    },
  );

  testChatWidgets(
    'interrupt with gateway queued ACK shows one bubble and no undeletable queue',
    (tester) async {
      final chat = await pumpChat(tester, mode: 'interrupt', busy: true);
      gateway.calls.clear();
      gateway.redirectDisposition = DesktopRedirectDisposition.queued;
      const text =
          'Dame la lista exacta de reglas WAF y de límites de peticiones activas en Cloudflare para api.example.com, y la prueba de que el registro con una invitación válida entra y uno sin invitación no';
      await tester.enterText(composerField(), text);
      await tester.pump();
      expect(
        tester.widget<ConsoleComposer>(find.byType(ConsoleComposer)).hintText,
        labels['interrupt'],
      );
      await tester.tap(find.byKey(const ValueKey('send')));
      await settle(tester);
      expect(gateway.calls, ['redirect:$text']);
      expect(
        chat.messages.where(
          (row) => row['role'] == 'user' && row['content'] == text,
        ),
        hasLength(1),
      );
      expect(chat.queuedEntries, isEmpty);
      expect(find.byKey(const ValueKey('chat-queue-toggle')), findsNothing);
      expect(persistedTurns(), isEmpty);
      gateway.completeTurn();
      await settle(tester);
      expect(gateway.calls, ['redirect:$text']);
    },
  );

  testChatWidgets('config read failure keeps queue and queue hint', (
    tester,
  ) async {
    final chat = await pumpChat(
      tester,
      mode: 'interrupt',
      busy: true,
      failConfig: true,
    );
    gateway.calls.clear();
    expect(
      tester.widget<ConsoleComposer>(find.byType(ConsoleComposer)).hintText,
      labels['queue'],
    );
    await submit(tester);
    expect(gateway.calls, isEmpty);
    expect(chat.queuedEntries.single.text, 'follow up');
  });

  testChatWidgets(
    'interrupt waits for ACK; repeated send submits one clientTurnId',
    (tester) async {
      final chat = await pumpChat(tester, mode: 'interrupt', busy: true);
      gateway.calls.clear();
      gateway.turnIds.clear();
      gateway.redirectError = const TuiGatewayRpcError(
        'session.redirect',
        'missing',
        code: -32601,
      );
      gateway.interruptAck = Completer<void>();
      String? durableTurnId;
      gateway.onRedirect = () async {
        durableTurnId = persistedTurns().single.clientTurnId;
      };
      await submit(tester);
      expect(gateway.calls, ['redirect:follow up', 'interrupt']);
      final widget = tester.widget<ConsoleComposer>(
        find.byType(ConsoleComposer),
      );
      widget.onSend('follow up', const []);
      widget.onKeyboardSubmit!();
      await settle(tester);
      expect(gateway.calls, ['redirect:follow up', 'interrupt']);
      await tester.runAsync(() async {
        gateway.interruptAck!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await settle(tester);
      expect(gateway.calls, [
        'redirect:follow up',
        'interrupt',
        'ack',
        'send:follow up',
      ]);
      expect(gateway.turnIds, [durableTurnId]);
      expect(chat.queuedEntries, isEmpty);
    },
  );

  testChatWidgets('a stalled config refresh does not hold an interrupt send', (
    tester,
  ) async {
    final chat = await pumpChat(tester, mode: 'interrupt', busy: true);
    gateway.calls.clear();
    configGate = Completer<void>();
    final refreshing = chat.refreshBusyInputMode();
    await submit(tester);
    expect(gateway.calls, ['redirect:follow up']);
    expect(configGate!.isCompleted, isFalse);
    configGate!.complete();
    await tester.runAsync(() async {
      await refreshing;
    });
    await settle(tester);
  });

  testChatWidgets(
    'optimistic message paints in the admission frame before submit ACK',
    (tester) async {
      final chat = await pumpChat(tester);
      gateway.submitAck = Completer<void>();
      final sent = chat.send(
        fullText: 'Immediate optimistic frame',
        model: 'hermes-agent',
        history: const [],
      );
      final began = tester.binding.clock.now();
      await tester.pump();
      expect(tester.binding.clock.now(), began);
      expect(
        chat.messages.where(
          (m) => m['content'] == 'Immediate optimistic frame',
        ),
        hasLength(1),
      );
      expect(find.text('Immediate optimistic frame'), findsOneWidget);
      expect(gateway.submitAck!.isCompleted, isFalse);
      gateway.submitAck!.complete();
      await tester.runAsync(() async {
        await sent;
      });
      await settle(tester);
    },
  );

  testChatWidgets(
    'interrupt paints its stable outbox identity before redirect ACK without Stop',
    (tester) async {
      final chat = await pumpChat(tester, mode: 'interrupt', busy: true);
      gateway.calls.clear();
      gateway.redirectAck = Completer<void>();
      List<PreparedTurn>? atRedirect;
      gateway.onRedirect = () async {
        atRedirect = persistedTurns();
        expect(atRedirect, hasLength(1));
        final row = chat.internalMessagesForTesting.singleWhere(
          (m) => m['content'] == 'follow up',
        );
        expect(row['_clientTurnId'], atRedirect!.single.clientTurnId);
        expect(row['_optimistic'], isTrue);
      };
      await submit(tester);
      expect(gateway.calls, ['redirect:follow up']);
      expect(find.byWidgetPredicate((widget) => widget is Text && widget.data == 'follow up'), findsOneWidget);
      expect(gateway.redirectAck!.isCompleted, isFalse);
      gateway.redirectAck!.complete();
      await settle(tester);
      expect(gateway.calls, ['redirect:follow up']);
    },
  );

  testChatWidgets(
    'atomic redirect is durable and cannot drain while its ACK waits',
    (tester) async {
      final chat = await pumpChat(tester, mode: 'interrupt', busy: true);
      gateway.calls.clear();
      gateway.turnIds.clear();
      gateway.redirectAck = Completer<void>();
      List<PreparedTurn>? atRedirect;
      gateway.onRedirect = () async {
        atRedirect = persistedTurns();
      };
      await submit(tester);
      expect(atRedirect, hasLength(1));
      expect(atRedirect!.single.state, PreparedTurnState.submitting);
      final clientTurnId = atRedirect!.single.clientTurnId;
      final composer = tester.widget<ConsoleComposer>(
        find.byType(ConsoleComposer),
      );
      composer.onSend('follow up', const []);
      composer.onKeyboardSubmit!();
      // The live turn may finish before session.redirect acknowledges admission.
      gateway.completeTurn();
      await settle(tester);
      expect(gateway.calls, ['redirect:follow up']);
      expect(gateway.turnIds, isEmpty);
      await tester.runAsync(() async {
        gateway.redirectAck!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await settle(tester);
      expect(gateway.calls, ['redirect:follow up']);
      expect(chat.queuedEntries, isEmpty);
      final stored = await tester.runAsync(
        () => TurnOutboxStore().loadAllForChat(
          _connection().id,
          _session().id,
          profile: 'default',
        ),
      );
      expect(
        stored!.where((turn) => turn.clientTurnId == clientTurnId),
        isEmpty,
      );
    },
  );

  testChatWidgets('failed interrupt warns and resumes the durable queue', (
    tester,
  ) async {
    final chat = await pumpChat(tester, mode: 'interrupt', busy: true);
    gateway.calls.clear();
    gateway.turnIds.clear();
    gateway.redirectError = const TuiGatewayRpcError(
      'session.redirect',
      'missing',
      code: -32601,
    );
    gateway.interruptError = StateError('transport failed');
    gateway.submitAck = Completer<void>();
    await submit(tester);
    expect(
      find.text('No se pudo interrumpir; el mensaje sigue en cola'),
      findsOneWidget,
    );
    expect(chat.queueParked, isFalse);
    expect(chat.queueDrainSuspendedForTesting, isFalse);
    expect(gateway.calls, [
      'redirect:follow up',
      'interrupt',
      'send:follow up',
    ]);
    expect(chat.queuedEntries.single.text, 'follow up');
    await tester.runAsync(() async {
      gateway.submitAck!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await settle(tester);
    expect(gateway.turnIds, hasLength(1));
    expect(chat.queuedEntries, isEmpty);
  });

  testChatWidgets('exhausted Stop budget warns and resumes the queue', (
    tester,
  ) async {
    var now = DateTime.now().millisecondsSinceEpoch;
    final chat = await pumpChat(
      tester,
      mode: 'interrupt',
      busy: true,
      wallClockMs: () => now,
    );
    gateway.calls.clear();
    gateway.turnIds.clear();
    gateway.redirectError = const TuiGatewayRpcError(
      'session.redirect',
      'missing',
      code: -32601,
    );
    gateway.completeOnInterrupt = false;
    gateway.interruptAck = Completer<void>();
    gateway.submitAck = Completer<void>();
    await submit(tester);
    expect(gateway.calls, ['redirect:follow up', 'interrupt']);
    now += 9000;
    await tester.runAsync(() async {
      gateway.interruptAck!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await settle(tester);
    expect(
      find.text('No se pudo interrumpir; el mensaje sigue en cola'),
      findsOneWidget,
    );
    expect(chat.queueParked, isFalse);
    expect(chat.queueDrainSuspendedForTesting, isFalse);
    expect(gateway.calls, [
      'redirect:follow up',
      'interrupt',
      'ack',
      'send:follow up',
    ]);
    await tester.runAsync(() async {
      gateway.submitAck!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await settle(tester);
    expect(gateway.turnIds, hasLength(1));
    expect(chat.queuedEntries, isEmpty);
  });

  testChatWidgets(
    'ambiguous atomic redirect never falls back to Stop or submit',
    (tester) async {
      final chat = await pumpChat(tester, mode: 'interrupt', busy: true);
      gateway.calls.clear();
      gateway.redirectError = StateError('connection lost after dispatch');
      await submit(tester);
      expect(gateway.calls, ['redirect:follow up']);
      expect(composer(tester).text, 'follow up');
      expect(chat.queuedEntries, isEmpty);
      expect(chat.isStreaming, isTrue);
      final stored = await tester.runAsync(
        () => TurnOutboxStore().loadAllForChat(
          _connection().id,
          _session().id,
          profile: 'default',
        ),
      );
      expect(stored!.single.state, PreparedTurnState.ambiguous);
    },
  );

  testChatWidgets(
    'explicit steer rejection queues instead of retaining the draft',
    (tester) async {
      final chat = await pumpChat(tester, mode: 'steer', busy: true);
      gateway.calls.clear();
      gateway.steerError = const TuiGatewayRpcError(
        'session.steer',
        'rejected',
        code: TuiGatewayRpcError.steerRejectedCode,
      );
      await submit(tester);
      expect(gateway.calls, ['steer:follow up']);
      expect(composer(tester).text, isEmpty);
      expect(chat.queuedEntries.single.text, 'follow up');
      expect(chat.isStreaming, isTrue);
    },
  );

  test('policy refresh only emits composer changes', () async {
    var mode = 'queue';
    var failed = false;
    final dashboard = testDashboardClient(
      httpClient: MockClient(
        (_) async => http.Response(
          failed
              ? '{}'
              : jsonEncode({
                  'display': {'busy_input_mode': mode},
                }),
          failed ? 503 : 200,
        ),
      ),
    );
    final chat = ActiveChat(
      connection: _connection(),
      sessionId: 'policy-events',
      sessionTitle: 'Policy',
      sessionProfile: 'default',
      notifications: null,
      onTerminal: () {},
      api: testApiClient(),
      transcriptDashboard: dashboard,
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(chat.dispose);
    addTearDown(dashboard.close);
    final events = <ActiveChatEvent>[];
    final subscription = chat.changes.listen(events.add);
    addTearDown(subscription.cancel);
    await chat.refreshBusyInputMode();
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    mode = 'steer';
    await chat.refreshBusyInputMode();
    await Future<void>.delayed(Duration.zero);
    expect(events, [ActiveChatEvent.busyInputModeChanged]);
    expect(chat.busyInputMode, BusyInputMode.steer);
    events.clear();
    await chat.refreshBusyInputMode();
    await Future<void>.delayed(Duration.zero);
    expect(
      events,
      isEmpty,
      reason: 'an unchanged read has no runtime evidence',
    );
    failed = true;
    await chat.refreshBusyInputMode();
    await Future<void>.delayed(Duration.zero);
    expect(events, [ActiveChatEvent.busyInputModeChanged]);
    expect(chat.busyInputMode, BusyInputMode.queue);
  });

  testChatWidgets('existing long press queues only this message', (
    tester,
  ) async {
    final chat = await pumpChat(tester, mode: 'interrupt', busy: true);
    gateway.calls.clear();
    await tester.enterText(composerField(), 'follow up');
    await tester.pump();
    final button = find.descendant(
      of: find.byType(ConsoleSendButton),
      matching: find.byType(GestureDetector),
    );
    await tester.longPress(button.first);
    await settle(tester);
    expect(gateway.calls, isEmpty);
    expect(chat.queuedEntries.single.text, 'follow up');
    expect(chat.busyInputMode, BusyInputMode.interrupt);
  });

  for (final mode in ['interrupt', 'steer']) {
    testChatWidgets(
      'old gateway without $mode leaves a live turn and queued message',
      (tester) async {
        final chat = await pumpChat(tester, mode: mode, busy: true);
        gateway.calls.clear();
        gateway.redirectError = const TuiGatewayRpcError(
          'session.redirect',
          'missing',
          code: -32601,
        );
        gateway.interruptUnsupported = true;
        gateway.steerUnsupported = true;
        await submit(tester);
        expect(chat.isStreaming, isTrue);
        expect(chat.queuedEntries.single.text, 'follow up');
        expect(
          gateway.calls,
          mode == 'interrupt'
              ? ['redirect:follow up', 'interrupt']
              : ['steer:follow up'],
        );
        expect(chat.busyInputMode, BusyInputMode.queue);
      },
    );
  }
}
