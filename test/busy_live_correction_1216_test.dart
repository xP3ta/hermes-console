// BUSY: text sent while this chat owns a live turn is a live correction
// (`session.redirect`), exactly as Hermes Desktop's composer does
// (use-composer-submit.ts submitWhileBusy). Everything else keeps the durable
// next-turn queue: the long press, a blocking prompt, and any redirect that
// proved nothing was accepted. An ambiguous failure never queues, because the
// server may already hold the correction.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

final _connection = SavedConnection(
  id: 'busy-correction-fixture',
  label: 'Synthetic fixture',
  host: 'example.invalid',
  port: 443,
  apiKey: 'synthetic-test-key',
  useHttps: true,
  kind: InstanceKind.vps,
);

const _session = Session(
  id: 'mob-1-busy-correction-fixture',
  title: 'Synthetic fixture',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

class _Gateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRedirectGateway {
  final eventsController = StreamController<TuiGatewayEvent>.broadcast();
  final submissions = <String>[];
  final redirects = <String>[];
  final steers = <String>[];
  Object? redirectError;
  DesktopRedirectDisposition redirectDisposition =
      DesktopRedirectDisposition.redirected;

  @override
  Stream<TuiGatewayEvent> get events => eventsController.stream;
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
    runtimeSessionId: 'runtime-fixture',
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
    runtimeSessionId: 'runtime-fixture',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-fixture',
    storedSessionId: 'stored-busy-correction-fixture',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
  }

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    redirects.add(text);
    final error = redirectError;
    if (error != null) throw error;
    return redirectDisposition;
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    steers.add(text);
  }

  void complete(String reply) {
    if (eventsController.isClosed) return;
    eventsController.add(
      TuiGatewayEvent(
        type: 'message.complete',
        sessionId: 'runtime-fixture',
        payload: {'text': reply},
      ),
    );
  }

  @override
  Future<void> close() async {
    if (!eventsController.isClosed) await eventsController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush(WidgetTester tester, {int steps = 20}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final _secure = <String, String>{};

/// Draft storage over the same in-memory map the outbox channel mock uses.
class _MemorySecureStorage extends FlutterSecureStorage {
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _secure.remove(key);
    } else {
      _secure[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _secure[key];

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _secure.remove(key);

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map<String, String>.of(_secure);
}

typedef _Fixture = ({ActiveChat chat, ChatDraftStore drafts});

/// The chat open with its first turn running (Hermes is working).
Future<_Fixture> _mountBusy(WidgetTester tester, _Gateway gateway) async {
  tester.platformDispatcher.localesTestValue = [const Locale('es')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  final prefs = await SharedPreferences.getInstance();
  final drafts = ChatDraftStore(prefs, secureStorage: _MemorySecureStorage());
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final service = ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
    desktopGatewayFactory: (_) => gateway,
  );
  final chat = service.attach(
    connection: _connection,
    sessionId: _session.id,
    sessionTitle: _session.title,
    sessionSnapshot: _session,
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'synthetic-test-key',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    ),
    desktopGateway: gateway,
    attachDesktopRuntimeOnLoad: false,
    disableForegroundKeepAlive: true,
    storedMessageLoader: (_, _) async => const [],
  );
  await tester.pumpWidget(
    HermesApp(
      connManager: manager,
      appLock: AppLockService(prefs),
      approvalPolicy: ApprovalPolicyService(prefs),
      fontSize: FontSizeService(prefs),
      sshManager: SshManager(secure, manager),
      sftpTransfers: SftpTransferService(
        SshManager(secure, manager),
        NotificationService(prefs),
      ),
      sshSessions: SshSessionService(SshManager(secure, manager)),
      notifications: NotificationService(prefs),
      activeChats: service,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
  await _flush(tester);
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        key: const ValueKey('busy'),
        connection: _connection,
        session: _session,
        draftStoreOverride: drafts,
      ),
    ),
  );
  await _flush(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await tester.pump(const Duration(minutes: 5));
  });
  await _type(tester, 'Primera petición');
  await _tapSend(tester);
  expect(gateway.submissions, ['Primera petición']);
  expect(chat.isStreaming, isTrue);
  return (chat: chat, drafts: drafts);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _tapSend(WidgetTester tester) async {
  final send = find.byKey(const ValueKey('send')).hitTestable();
  expect(send, findsOneWidget);
  await tester.tap(send);
  await _flush(tester);
}

String _composerText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first).controller!.text;

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(ChatScreen)));

Future<String> _draft(_Fixture fixture) async => (await fixture.drafts.load(
  _connection.id,
  fixture.chat.storedSessionId!,
)).text;

/// Turns of the durable outbox still waiting as next turns.
List<PreparedTurn> _queuedOutbox() {
  final raw = _secure['chat_turn_outbox_v1'];
  if (raw == null) return const [];
  return [
    for (final value in (jsonDecode(raw) as Map).values)
      PreparedTurn.fromJson(Map<String, dynamic>.from(value as Map)),
  ].where((turn) => turn.queued).toList();
}

Iterable<Map<String, dynamic>> _userRows(ActiveChat chat, String text) =>
    chat.messages.where(
      (message) => message['role'] == 'user' && message['content'] == text,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    _secure.clear();
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        switch (call.method) {
          case 'read':
            return _secure[args['key']];
          case 'write':
            _secure[args['key'] as String] = args['value'] as String;
          case 'delete':
            _secure.remove(args['key']);
          case 'readAll':
            return Map<String, String>.from(_secure);
          case 'containsKey':
            return _secure.containsKey(args['key']);
        }
        return null;
      },
    );
    for (final channel in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/background',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
  });

  testWidgets('R1 text during the own live turn is one live correction, '
      'never a queued turn', (tester) async {
    final gateway = _Gateway();
    final fixture = await _mountBusy(tester, gateway);

    await _type(tester, 'Siguiente turno');
    await _tapSend(tester);

    expect(gateway.redirects, ['Siguiente turno']);
    expect(gateway.submissions, ['Primera petición']);
    expect(gateway.steers, isEmpty);
    expect(fixture.chat.queuedMessages, isEmpty);
    expect(_queuedOutbox(), isEmpty);
    final rows = _userRows(fixture.chat, 'Siguiente turno').toList();
    expect(rows, hasLength(1));
    expect(rows.single['_steer'], isTrue);
    expect(_composerText(tester), isEmpty);
    expect(await _draft(fixture), isEmpty);

    gateway.complete('hecho');
    await _flush(tester, steps: 15);
    expect(gateway.submissions, ['Primera petición']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('R2 a rejected redirect falls back to the queue and drains '
      'once, with no duplicate bubble', (tester) async {
    final gateway = _Gateway()
      ..redirectDisposition = DesktopRedirectDisposition.rejected;
    final fixture = await _mountBusy(tester, gateway);

    await _type(tester, 'Siguiente turno');
    await _tapSend(tester);

    expect(gateway.redirects, ['Siguiente turno']);
    expect(fixture.chat.queuedMessages, ['Siguiente turno']);
    expect(_queuedOutbox(), hasLength(1));
    expect(_userRows(fixture.chat, 'Siguiente turno'), isEmpty);
    expect(_composerText(tester), isEmpty);

    gateway.complete('hecho');
    await _flush(tester, steps: 15);
    expect(gateway.submissions, ['Primera petición', 'Siguiente turno']);
    expect(fixture.chat.queuedMessages, isEmpty);
    gateway.complete('segundo hecho');
    await _flush(tester, steps: 10);
    expect(gateway.submissions, ['Primera petición', 'Siguiente turno']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('R3a a redirect the server refused (4010) queues the text', (
    tester,
  ) async {
    final gateway = _Gateway()
      ..redirectError = const TuiGatewayRpcError(
        'session.redirect',
        'not supported',
        code: 4010,
      );
    final fixture = await _mountBusy(tester, gateway);

    await _type(tester, 'Siguiente turno');
    await _tapSend(tester);

    expect(gateway.redirects, ['Siguiente turno']);
    expect(fixture.chat.queuedMessages, ['Siguiente turno']);
    expect(_userRows(fixture.chat, 'Siguiente turno'), isEmpty);
    expect(_composerText(tester), isEmpty);
    gateway.complete('hecho');
    await _flush(tester, steps: 15);
    expect(gateway.submissions, ['Primera petición', 'Siguiente turno']);
    gateway.complete('segundo hecho');
    await _flush(tester, steps: 10);
    expect(tester.takeException(), isNull);
  });

  for (final failure in <String, Object>{
    'timeout': TimeoutException('redirect timed out'),
    'socket': StateError('socket'),
  }.entries) {
    testWidgets('R3b an ambiguous ${failure.key} never queues: the text '
        'stays as a draft and the user is told', (tester) async {
      final gateway = _Gateway()..redirectError = failure.value;
      final fixture = await _mountBusy(tester, gateway);

      await _type(tester, 'Siguiente turno');
      await _tapSend(tester);

      expect(gateway.redirects, ['Siguiente turno']);
      expect(gateway.steers, isEmpty);
      expect(fixture.chat.queuedMessages, isEmpty);
      expect(_queuedOutbox(), isEmpty);
      expect(_userRows(fixture.chat, 'Siguiente turno'), isEmpty);
      expect(_composerText(tester), 'Siguiente turno');
      await tester.pump(const Duration(milliseconds: 400));
      expect(await _draft(fixture), 'Siguiente turno');
      expect(find.text(_strings(tester).chaSteerFailed), findsOneWidget);

      gateway.complete('hecho');
      await _flush(tester, steps: 15);
      expect(gateway.submissions, ['Primera petición']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('R4 a redirect the server queued keeps the bubble and stays '
      'out of the local outbox', (tester) async {
    final gateway = _Gateway()
      ..redirectDisposition = DesktopRedirectDisposition.queued;
    final fixture = await _mountBusy(tester, gateway);

    await _type(tester, 'Siguiente turno');
    await _tapSend(tester);

    expect(gateway.redirects, ['Siguiente turno']);
    expect(_queuedOutbox(), isEmpty);
    final rows = _userRows(fixture.chat, 'Siguiente turno').toList();
    expect(rows, hasLength(1));
    expect(rows.single['_desktopAcceptedQueued'], isTrue);
    expect(_composerText(tester), isEmpty);
    expect(await _draft(fixture), isEmpty);
    expect(find.text(_strings(tester).chaSteerQueued), findsOneWidget);
    gateway.complete('hecho');
    await _flush(tester, steps: 15);
    gateway.complete('segundo hecho');
    await _flush(tester, steps: 10);
    expect(gateway.submissions, ['Primera petición']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long press on send is the explicit queue: no redirect', (
    tester,
  ) async {
    final gateway = _Gateway();
    final fixture = await _mountBusy(tester, gateway);

    await _type(tester, 'Siguiente turno');
    await tester.longPress(find.byKey(const ValueKey('send')));
    await _flush(tester);

    expect(gateway.redirects, isEmpty);
    expect(fixture.chat.queuedMessages, ['Siguiente turno']);
    expect(_queuedOutbox(), hasLength(1));
    expect(_composerText(tester), isEmpty);
    gateway.complete('hecho');
    await _flush(tester, steps: 15);
    expect(gateway.submissions, ['Primera petición', 'Siguiente turno']);
    gateway.complete('segundo hecho');
    await _flush(tester, steps: 10);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pending approval keeps the text in the queue: no redirect', (
    tester,
  ) async {
    final gateway = _Gateway();
    final fixture = await _mountBusy(tester, gateway);
    fixture.chat.pendingApproval = const {'request_id': 'approval-1'};

    await _type(tester, 'Siguiente turno');
    await _tapSend(tester);

    expect(gateway.redirects, isEmpty);
    expect(fixture.chat.queuedMessages, ['Siguiente turno']);
    expect(_queuedOutbox(), hasLength(1));
    gateway.complete('hecho');
    await _flush(tester, steps: 15);
    gateway.complete('segundo hecho');
    await _flush(tester, steps: 10);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a slash command is never redirected as plain text', (
    tester,
  ) async {
    final gateway = _Gateway();
    await _mountBusy(tester, gateway);

    await _type(tester, '/queue Siguiente turno');
    await _tapSend(tester);

    expect(gateway.redirects, isEmpty);
    expect(gateway.steers, isEmpty);
    gateway.complete('hecho');
    await _flush(tester, steps: 15);
    expect(tester.takeException(), isNull);
  });
}
