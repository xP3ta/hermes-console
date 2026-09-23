import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_connection_recovery_row.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _DroppingGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRecoverySessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final Completer<void> recoveryConnectGate = Completer<void>();

  bool _connected = false;
  int connectCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    connectCalls += 1;
    if (connectCalls > 1) await recoveryConnectGate.future;
    _connected = true;
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-$connectCalls',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-$connectCalls',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionBinding(
    runtimeSessionId: 'runtime-created',
    storedSessionId: 'session-recovery',
    created: true,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-recovered',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  void commitRecoveryRuntime(String runtimeSessionId) {}

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  void emit(String type, Map<String, dynamic> payload) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-$connectCalls',
        payload: payload,
      ),
    );
  }

  void drop() {
    _connected = false;
    _events.addError(StateError('socket dropped'));
  }

  @override
  Future<void> close() async {
    _connected = false;
    if (!recoveryConnectGate.isCompleted) recoveryConnectGate.complete();
    await _events.close();
  }
}

SavedConnection _connection() => SavedConnection(
  id: 'connection-recovery',
  label: 'Recovery test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  kind: InstanceKind.vps,
);

ActiveChat _chat(_DroppingGateway gateway) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: _connection(),
  sessionId: 'session-recovery',
  sessionTitle: 'Recovery test',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:1',
    apiKey: 'test-key',
    httpClient: MockClient((_) async => http.Response('not found', 404)),
  ),
  desktopGateway: gateway,
  allowUnownedDesktopSnapshotForTesting: true,
  desktopRecoveryBackoff: const [Duration.zero, Duration(seconds: 1)],
);

ChatTransportStatus _disconnected(
  ChatTransportState state, {
  DateTime? since,
}) => ChatTransportStatus(state, disconnectedSince: since ?? DateTime.now());

Widget _recoveryHarness({
  required ChatTransportStatus status,
  required bool activeTurn,
  bool authRequired = false,
  bool appForeground = true,
  ThemeData? theme,
  double textScale = 1,
}) => MaterialApp(
  theme: theme ?? AppTheme.hermesRedLight,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('en'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: Column(
      children: [
        if (authRequired)
          const Text(
            'Sign in to the Dashboard to reconnect live chat.',
            key: ValueKey('auth-required-fixture'),
          ),
        ChatConnectionRecoveryRow(
          key: const ValueKey('recovery-row-host'),
          status: status,
          activeTurn: activeTurn,
          authRequired: authRequired,
          appForeground: appForeground,
          offlineLabel: 'Connection lost. You can keep drafting.',
          reconnectingLabel: 'Reconnecting… Your chat stays available.',
          recoveredLabel: 'Reconnected',
        ),
        const Expanded(
          key: ValueKey('transcript'),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Text(
              'Partial answer remains readable',
              key: ValueKey('last-message'),
            ),
          ),
        ),
        const SizedBox(
          key: ValueKey('composer'),
          height: 80,
          child: TextField(),
        ),
      ],
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('publishes transport loss while a submitted turn reconnects', () async {
    final gateway = _DroppingGateway();
    final chat = _chat(gateway)..smoothStreaming = false;
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'Keep the partial answer visible',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    gateway.emit('message.delta', const {'text': 'Partial answer'});
    await Future<void>.delayed(Duration.zero);
    expect(chat.assistantContent, 'Partial answer');

    gateway.drop();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(chat.state, ChatPipelineState.connecting);
    expect(chat.assistantContent, 'Partial answer');
    expect(
      chat.transportStatus.state,
      anyOf(ChatTransportState.offline, ChatTransportState.reconnecting),
    );
    expect(chat.transportStatus.disconnectedSince, isNotNull);
  });

  test('offline transport replaces a thinking headline but auth does not', () {
    final offline = _disconnected(ChatTransportState.reconnecting);
    expect(
      chatActivityHeadlineForTransport(
        status: offline,
        authRequired: false,
        activityHeadline: 'Thinking…',
        reconnectingHeadline: 'Connection lost — reconnecting…',
      ),
      'Connection lost — reconnecting…',
    );
    expect(
      chatActivityHeadlineForTransport(
        status: offline,
        authRequired: true,
        activityHeadline: 'Thinking…',
        reconnectingHeadline: 'Connection lost — reconnecting…',
      ),
      'Thinking…',
    );
  });

  testWidgets('short active-turn blip never shows the persistent row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _recoveryHarness(
        status: _disconnected(ChatTransportState.offline),
        activeTurn: true,
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(
      find.byKey(const ValueKey('chat-connection-recovery-row')),
      findsNothing,
    );

    await tester.pumpWidget(
      _recoveryHarness(
        status: const ChatTransportStatus(ChatTransportState.connected),
        activeTurn: true,
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.byKey(const ValueKey('chat-connection-recovery-row')),
      findsNothing,
    );
    expect(find.text('Reconnected'), findsNothing);
  });

  testWidgets(
    'flapping produces one visible episode and one recovered notice',
    (tester) async {
      var visibleTransitions = 0;
      var wasVisible = false;
      for (var flap = 0; flap < 5; flap++) {
        await tester.pumpWidget(
          _recoveryHarness(
            status: _disconnected(ChatTransportState.offline),
            activeTurn: true,
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        var visible = find
            .byKey(const ValueKey('chat-connection-recovery-row'))
            .evaluate()
            .isNotEmpty;
        if (visible && !wasVisible) visibleTransitions += 1;
        wasVisible = visible;

        await tester.pumpWidget(
          _recoveryHarness(
            status: const ChatTransportStatus(ChatTransportState.connected),
            activeTurn: true,
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        visible = find
            .byKey(const ValueKey('chat-connection-recovery-row'))
            .evaluate()
            .isNotEmpty;
        if (visible && !wasVisible) visibleTransitions += 1;
        wasVisible = visible;
      }
      expect(visibleTransitions, 0);

      await tester.pumpWidget(
        _recoveryHarness(
          status: _disconnected(
            ChatTransportState.reconnecting,
            since: DateTime.now().subtract(const Duration(seconds: 4)),
          ),
          activeTurn: true,
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('chat-connection-recovery-row')),
        findsOneWidget,
      );
      visibleTransitions += 1;

      await tester.pumpWidget(
        _recoveryHarness(
          status: const ChatTransportStatus(ChatTransportState.connected),
          activeTurn: true,
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(const ValueKey('chat-connection-recovery-row')),
        findsOneWidget,
      );
      await tester.pumpWidget(
        _recoveryHarness(
          status: _disconnected(
            ChatTransportState.offline,
            since: DateTime.now().subtract(const Duration(seconds: 5)),
          ),
          activeTurn: true,
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('chat-connection-recovery-row')),
        findsOneWidget,
      );
      expect(visibleTransitions, 1);

      await tester.pumpWidget(
        _recoveryHarness(
          status: const ChatTransportStatus(ChatTransportState.connected),
          activeTurn: true,
        ),
      );
      await tester.pump(chatConnectionHealthyHysteresis);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('chat-connection-recovery-row')),
        findsNothing,
      );
      expect(find.text('Reconnected'), findsOneWidget);
    },
  );

  testWidgets('resume derives visibility from the original loss timestamp', (
    tester,
  ) async {
    final down = _disconnected(
      ChatTransportState.offline,
      since: DateTime.now().subtract(const Duration(seconds: 10)),
    );
    await tester.pumpWidget(
      _recoveryHarness(status: down, activeTurn: true, appForeground: false),
    );
    await tester.pump(const Duration(seconds: 10));
    expect(
      find.byKey(const ValueKey('chat-connection-recovery-row')),
      findsNothing,
    );

    await tester.pumpWidget(
      _recoveryHarness(status: down, activeTurn: true, appForeground: true),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('chat-connection-recovery-row')),
      findsOneWidget,
    );
  });

  testWidgets('idle chat retains Desktop five-minute grace', (tester) async {
    await tester.pumpWidget(
      _recoveryHarness(
        status: _disconnected(ChatTransportState.offline),
        activeTurn: false,
      ),
    );
    await tester.pump(const Duration(minutes: 4, seconds: 59));
    expect(
      find.byKey(const ValueKey('chat-connection-recovery-row')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey('chat-connection-recovery-row')),
      findsOneWidget,
    );
  });

  testWidgets('auth-required remains the only visible recovery surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      _recoveryHarness(
        status: _disconnected(
          ChatTransportState.offline,
          since: DateTime.now().subtract(const Duration(minutes: 6)),
        ),
        activeTurn: false,
        authRequired: true,
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('auth-required-fixture')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-connection-recovery-row')),
      findsNothing,
    );
  });

  testWidgets(
    '320dp at text scale 2 stays in-flow above transcript and composer',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _recoveryHarness(
          status: _disconnected(
            ChatTransportState.reconnecting,
            since: DateTime.now().subtract(const Duration(seconds: 4)),
          ),
          activeTurn: true,
          textScale: 2,
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      final row = tester.getRect(
        find.byKey(const ValueKey('chat-connection-recovery-row')),
      );
      final transcript = tester.getRect(
        find.byKey(const ValueKey('transcript')),
      );
      final lastMessage = tester.getRect(
        find.byKey(const ValueKey('last-message')),
      );
      final composer = tester.getRect(find.byKey(const ValueKey('composer')));
      expect(row.bottom, lessThanOrEqualTo(transcript.top));
      expect(row.bottom, lessThanOrEqualTo(lastMessage.top));
      expect(lastMessage.bottom, lessThanOrEqualTo(composer.top));
    },
  );

  testWidgets('persistent row renders in light and dark themes', (
    tester,
  ) async {
    for (final theme in [AppTheme.hermesRedLight, AppTheme.hermesRedDark]) {
      await tester.pumpWidget(
        _recoveryHarness(
          status: _disconnected(
            ChatTransportState.reconnecting,
            since: DateTime.now().subtract(const Duration(seconds: 4)),
          ),
          activeTurn: true,
          theme: theme,
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('chat-connection-recovery-row')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
  });
}
