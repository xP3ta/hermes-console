import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
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
  id: 'local-admission-fixture',
  label: 'Synthetic fixture',
  host: 'example.invalid',
  port: 443,
  apiKey: '',
  useHttps: true,
  kind: InstanceKind.vps,
);
const _session = Session(
  id: 'stored-fixture',
  title: 'Synthetic fixture',
  model: 'hermes-agent',
  source: 'api_server',
  messageCount: 1,
  isActive: false,
  preview: '',
  startedAt: 0,
);

class _Gateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final eventsController = StreamController<TuiGatewayEvent>.broadcast();
  final submissions = <String>[];
  int connects = 0;
  int resumes = 0;
  int creates = 0;
  Object? submitError;
  Completer<void>? resumeGate;
  @override
  Stream<TuiGatewayEvent> get events => eventsController.stream;
  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {
    connects++;
  }

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
  }) async {
    resumes++;
    final gate = resumeGate;
    if (gate != null) await gate.future;
    return DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-fixture',
      storedSessionId: storedSessionId,
      created: false,
    );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    creates++;
    throw StateError('fixture must never create');
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
    if (submitError case final error?) throw error;
  }

  void complete() {
    if (!eventsController.isClosed) {
      eventsController.add(
        const TuiGatewayEvent(
          type: 'message.complete',
          sessionId: 'runtime-fixture',
          payload: {'text': 'Synthetic reply'},
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    if (!eventsController.isClosed) await eventsController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Outbox implements TurnOutboxPersistence {
  final turns = <PreparedTurn>[];
  @override
  Future<void> save(PreparedTurn turn) async {
    turns.add(turn);
  }

  @override
  Future<void> delete(PreparedTurn turn) async {}
}

LocalConversationLifecycle _begin() =>
    LocalConversationCleanupFence.beginLifecycle(
      connectionId: _connection.id,
      profile: 'default',
      sessionId: _session.id,
    );
void _assertRejected(LocalConversationLifecycle lifecycle) => expect(
  () => LocalConversationCleanupFence.ensureWriteAllowed(
    connectionId: _connection.id,
    profile: 'default',
    sessionId: _session.id,
    lifecycle: lifecycle,
  ),
  throwsA(isA<LocalConversationWriteRejected>()),
);

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<({ActiveChat chat, ActiveChatService service, NavigatorState navigator})>
_mount(WidgetTester tester, _Gateway gateway) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final service = ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final chat = service.attach(
    connection: _connection,
    sessionId: _session.id,
    sessionTitle: _session.title,
    sessionSnapshot: _session,
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: '',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    ),
    desktopGateway: gateway,
    attachDesktopRuntimeOnLoad: false,
    disableForegroundKeepAlive: true,
    storedMessageLoader: (_, _) async => const [
      {
        'id': 'fixture-row',
        'role': 'assistant',
        'content': 'Synthetic history',
      },
    ],
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
  _push(navigator, 'A');
  await _flush(tester);
  addTearDown(() async {
    gateway.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await tester.pump(const Duration(minutes: 5));
  });
  return (chat: chat, service: service, navigator: navigator);
}

void _push(NavigatorState navigator, String key) => navigator.push<void>(
  MaterialPageRoute<void>(
    builder: (_) => ChatScreen(
      key: ValueKey(key),
      connection: _connection,
      session: _session,
    ),
  ),
);
Future<void> _send(WidgetTester tester, String text) async {
  final send = find.byKey(const ValueKey('send')).hitTestable();
  await tester.enterText(find.byType(TextField).first, text);
  await tester.pump();
  expect(send.hitTestable(), findsOneWidget);
  await tester.tap(send);
  await _flush(tester);
}

void main() {
  var revokeAfterPreparedWrite = false;
  var preparedWrites = 0;
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    revokeAfterPreparedWrite = false;
    preparedWrites = 0;
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
                if (args['key'] == 'chat_turn_outbox_v1' &&
                    revokeAfterPreparedWrite) {
                  preparedWrites++;
                  revokeAfterPreparedWrite = false;
                  LocalConversationCleanupFence.endLifecycle(_begin());
                }
              case 'delete':
                secure.remove(args['key']);
              case 'readAll':
                return Map<String, String>.from(secure);
              case 'containsKey':
                return secure.containsKey(args['key']);
            }
            return null;
          },
        );
    for (final channel in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/background',
    ]) {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async => call.method == 'isRunningService' ? false : null,
        );
  });

  test(
    'typed local admission rejection is unaccepted before any transport',
    () async {
      final gateway = _Gateway();
      final a = _begin();
      final chat = ActiveChat(
        connection: _connection,
        sessionId: _session.id,
        sessionTitle: _session.title,
        localConversationLifecycle: a,
        desktopGateway: gateway,
        notifications: null,
        onTerminal: () {},
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      final b = _begin();
      LocalConversationCleanupFence.endLifecycle(b);
      final store = _Outbox();
      final prepared = PreparedTurn(
        connectionId: _connection.id,
        sessionId: _session.id,
        clientTurnId: 'synthetic-turn',
        createdAtMs: 1,
        updatedAtMs: 1,
        text: 'Synthetic draft',
        attachments: const [],
        model: 'hermes-agent',
        profile: 'default',
      );
      final delivery = ActiveTurnDelivery(prepared: prepared, store: store);
      expect(
        await chat.send(
          fullText: prepared.fullText,
          model: 'hermes-agent',
          history: const [],
          delivery: delivery,
        ),
        isFalse,
      );
      expect(delivery.current.state, PreparedTurnState.failedBeforeAcceptance);
      expect(delivery.transportStarted, isFalse);
      expect(gateway.connects + gateway.resumes + gateway.creates, 0);
      expect(gateway.submissions, isEmpty);
      _assertRejected(a);
      _assertRejected(b);
      chat.dispose();
    },
  );

  testWidgets(
    'local rejection preserves original composer and reports safe error without unhandled future',
    (tester) async {
      final gateway = _Gateway();
      await _mount(tester, gateway);
      revokeAfterPreparedWrite = true;
      await _send(tester, 'Synthetic original draft');
      expect(preparedWrites, 1);
      expect(tester.takeException(), isNull);
      expect(gateway.submissions, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Synthetic original draft',
      );
      final strings = Strings.of(tester.element(find.byType(ChatScreen)));
      expect(find.text(strings.chaOutboxUnavailable), findsWidgets);
      expect(find.byKey(const ValueKey('send')).hitTestable(), findsOneWidget);
    },
  );

  for (final cleanup in ['profile', 'connection', 'delete']) {
    testWidgets(
      '$cleanup invalidation cannot renew returned route or retained callback',
      (tester) async {
        final gateway = _Gateway();
        final fixture = await _mount(tester, gateway);
        final oldA = LocalConversationCleanupFence.currentLifecycle(
          connectionId: _connection.id,
          profile: 'default',
          sessionId: _session.id,
        )!;
        final callback = tester
            .widget<ConsoleComposer>(find.byType(ConsoleComposer))
            .onSend;
        fixture.navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ChatScreen(
              key: const ValueKey('B'),
              connection: _connection,
              session: _session,
            ),
          ),
        );
        await _flush(tester);
        if (cleanup == 'profile') {
          await LocalConversationCleanupFence.cleanupProfile(
            connectionId: _connection.id,
            profile: 'default',
            operation: () async {},
          );
        } else if (cleanup == 'connection') {
          await LocalConversationCleanupFence.cleanupConnection(
            connectionId: _connection.id,
            operation: () async {},
          );
        } else {
          LocalConversationCleanupFence.endLifecycle(oldA);
        }
        fixture.navigator.pop();
        await _flush(tester);
        callback('Synthetic withdrawn action', const []);
        await _send(tester, 'Synthetic preserved draft');
        expect(tester.takeException(), isNull);
        expect(gateway.submissions, isEmpty);
        expect(gateway.connects + gateway.resumes + gateway.creates, 0);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'Synthetic preserved draft',
        );
        _assertRejected(oldA);
      },
    );
  }

  testWidgets(
    'profile ABA rejects retained composer callback but permits fresh fixed-session gesture',
    (tester) async {
      final gateway = _Gateway();
      final fixture = await _mount(tester, gateway);
      await tester.enterText(
        find.byType(TextField).first,
        'Synthetic profile draft',
      );
      await tester.pump();
      final callback = tester
          .widget<ConsoleComposer>(find.byType(ConsoleComposer))
          .onSend;
      final app = tester.state<HermesAppState>(find.byType(HermesApp));
      await app.connManager.setActiveProfile(_connection.id, 'other');
      await app.connManager.setActiveProfile(_connection.id, '');
      callback('Synthetic withdrawn profile callback', const []);
      await _flush(tester);
      expect(gateway.submissions, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Synthetic profile draft',
      );
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump();
      await _send(tester, 'Synthetic fresh profile action');
      expect(gateway.submissions, ['Synthetic fresh profile action']);
      expect(gateway.resumes, 1);
      expect(gateway.creates, 0);
      gateway.complete();
      await _flush(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.chat.dispose();
      fixture.service.dispose();
      await tester.pump(const Duration(minutes: 5));
    },
  );

  test(
    'renewal refuses live owners and foreign profile or connection scope',
    () async {
      final a = _begin();
      final b = _begin();
      expect(LocalConversationCleanupFence.renewAfterRouteReturn(a), isNull);
      expect(
        LocalConversationCleanupFence.currentLifecycle(
          connectionId: _connection.id,
          profile: 'default',
          sessionId: _session.id,
        ),
        same(b),
      );
      LocalConversationCleanupFence.endLifecycle(b);
      final fresh = LocalConversationCleanupFence.renewAfterRouteReturn(a)!;
      _assertRejected(a);
      _assertRejected(b);
      for (final scope in [
        (connection: _connection.id, profile: 'other'),
        (connection: 'foreign', profile: 'default'),
      ]) {
        expect(
          () => LocalConversationCleanupFence.ensureWriteAllowed(
            connectionId: scope.connection,
            profile: scope.profile,
            sessionId: _session.id,
            lifecycle: fresh,
          ),
          throwsA(isA<LocalConversationWriteRejected>()),
        );
      }
      LocalConversationCleanupFence.ensureWriteAllowed(
        connectionId: _connection.id,
        profile: 'default',
        sessionId: _session.id,
        lifecycle: fresh,
      );
    },
  );

  testWidgets(
    'two mounted same-session routes permit fresh send after pop without reviving old tokens',
    (tester) async {
      final gateway = _Gateway();
      final fixture = await _mount(tester, gateway);
      final oldA = LocalConversationCleanupFence.currentLifecycle(
        connectionId: _connection.id,
        profile: 'default',
        sessionId: _session.id,
      )!;
      final oldCallbackA = tester
          .widget<ConsoleComposer>(find.byType(ConsoleComposer))
          .onSend;
      await tester.enterText(
        find.byType(TextField).first,
        'Synthetic retained A draft',
      );
      await tester.pump();
      final oldOperation = LocalConversationCleanupFence.admitOperation(
        connectionId: _connection.id,
        profile: 'default',
        sessionId: _session.id,
        lifecycle: oldA,
        kind: LocalConversationOperationKind.projection,
      );
      final releaseOldWrite = Completer<void>();
      var oldPhysicalWrites = 0;
      final heldOldWrite = () async {
        await releaseOldWrite.future;
        return LocalConversationCleanupFence.commitEffect(
          operation: oldOperation,
          resource: LocalConversationResourceKey(
            connectionId: _connection.id,
            profile: 'default',
            sessionId: _session.id,
            physicalKey: 'synthetic-held-projection',
          ),
          mutation: () async {
            oldPhysicalWrites++;
          },
        );
      }();
      fixture.navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(
            key: const ValueKey('B'),
            connection: _connection,
            session: _session,
          ),
        ),
      );
      await _flush(tester);
      expect(find.byType(ChatScreen, skipOffstage: false), findsNWidgets(2));
      final b = LocalConversationCleanupFence.currentLifecycle(
        connectionId: _connection.id,
        profile: 'default',
        sessionId: _session.id,
      )!;
      final oldCallbackB = tester
          .widget<ConsoleComposer>(find.byType(ConsoleComposer))
          .onSend;
      await tester.enterText(
        find.byType(TextField).first,
        'Synthetic retained B draft',
      );
      await tester.pump();
      oldCallbackA('Synthetic stale callback', const []);
      await _flush(tester);
      expect(gateway.submissions, isEmpty);
      fixture.navigator.pop();
      await _flush(tester);
      expect(find.byType(ChatScreen), findsOneWidget);
      _assertRejected(oldA);
      _assertRejected(b);
      expect(
        () =>
            LocalConversationCleanupFence.ensureOperationAllowed(oldOperation),
        throwsA(isA<LocalConversationWriteRejected>()),
      );
      oldCallbackA('Synthetic stale callback', const []);
      oldCallbackB('Synthetic disposed callback', const []);
      await _flush(tester);
      expect(gateway.submissions, isEmpty);
      final releaseFreshResume = Completer<void>();
      gateway.resumeGate = releaseFreshResume;
      await _send(tester, 'Synthetic fresh action');
      expect(tester.takeException(), isNull);
      expect(gateway.submissions, isEmpty);
      expect(gateway.creates, 0);
      expect(gateway.resumes, 1);
      final fresh = LocalConversationCleanupFence.currentLifecycle(
        connectionId: _connection.id,
        profile: 'default',
        sessionId: _session.id,
      )!;
      expect(identical(fresh, oldA) || identical(fresh, b), isFalse);
      final rejection = expectLater(
        heldOldWrite,
        throwsA(isA<LocalConversationWriteRejected>()),
      );
      releaseOldWrite.complete();
      await rejection;
      expect(oldPhysicalWrites, 0);
      expect(gateway.submissions, isEmpty);
      releaseFreshResume.complete();
      await _flush(tester);
      expect(gateway.submissions, ['Synthetic fresh action']);
      oldCallbackA('Synthetic stale callback', const []);
      oldCallbackB('Synthetic disposed callback', const []);
      await _flush(tester);
      expect(gateway.submissions, ['Synthetic fresh action']);
      expect(oldPhysicalWrites, 0);
      expect(gateway.submissions, ['Synthetic fresh action']);
      expect(
        () =>
            LocalConversationCleanupFence.ensureOperationAllowed(oldOperation),
        throwsA(isA<LocalConversationWriteRejected>()),
      );
      _assertRejected(oldA);
      _assertRejected(b);
      final drafts = ChatDraftStore(await SharedPreferences.getInstance());
      expect(
        (await drafts.load(
          _connection.id,
          _session.id,
          profile: 'default',
        )).text,
        isEmpty,
      );
      await tester.enterText(
        find.byType(TextField).first,
        'Synthetic future draft',
      );
      await _flush(tester);
      expect(
        (await drafts.load(
          _connection.id,
          _session.id,
          profile: 'default',
        )).text,
        'Synthetic future draft',
      );
      gateway.complete();
      await _flush(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.chat.dispose();
      fixture.service.dispose();
      await tester.pump(const Duration(minutes: 5));
    },
  );
}
