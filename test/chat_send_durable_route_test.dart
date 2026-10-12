// A conversation started on this phone has two names: the provisional id of
// the screen it was written in (`mob-…`) and the durable id Hermes gave it on
// its first turn. The chat that runs it stays alive under the first name
// while every list offers it under the second. Whichever name a screen was
// opened with, what is typed in it must be sent. And a press of send that
// sends nothing always says so: one line in the log, one sentence on screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/app_lock_sensitive_read_fence.dart';
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
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _provisionalId = 'mob-1-durable-route-fixture';
const _durableId = 'stored-durable-route-fixture';

final _connection = SavedConnection(
  id: 'durable-route-fixture',
  label: 'Synthetic fixture',
  host: 'example.invalid',
  port: 443,
  apiKey: '',
  useHttps: true,
  kind: InstanceKind.vps,
);

/// The chat as its first screen knows it: written here, not yet in Hermes.
const _provisional = Session(
  id: _provisionalId,
  title: 'Synthetic fixture',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

/// The same chat as every list offers it once Hermes has stored it.
const _durable = Session(
  id: _durableId,
  title: 'Synthetic fixture',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 2,
  isActive: false,
  preview: 'Synthetic first',
  startedAt: 0,
);

class _Gateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final eventsController = StreamController<TuiGatewayEvent>.broadcast();
  final submissions = <String>[];
  int creates = 0;

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
  }) async {
    creates++;
    return const DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-fixture',
      storedSessionId: _durableId,
      created: true,
    );
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
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

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

typedef _Fixture = ({
  ActiveChat chat,
  ActiveChatService service,
  NavigatorState navigator,
  List<Map<String, dynamic>> stored,
});

/// The app with the chat's first screen open, as after tapping "new chat".
Future<_Fixture> _mount(
  WidgetTester tester,
  _Gateway gateway, {
  void Function(SharedPreferences prefs)? beforeOpen,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final stored = <Map<String, dynamic>>[];
  final service = ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final chat = service.attach(
    connection: _connection,
    sessionId: _provisional.id,
    sessionTitle: _provisional.title,
    sessionSnapshot: _provisional,
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: '',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    ),
    desktopGateway: gateway,
    attachDesktopRuntimeOnLoad: false,
    disableForegroundKeepAlive: true,
    storedMessageLoader: (_, _) async => [
      for (final row in stored) Map<String, dynamic>.of(row),
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
  beforeOpen?.call(prefs);
  _push(navigator, 'provisional', _provisional);
  await _flush(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await tester.pump(const Duration(minutes: 5));
  });
  return (chat: chat, service: service, navigator: navigator, stored: stored);
}

void _push(NavigatorState navigator, String key, Session session) =>
    navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          key: ValueKey(key),
          connection: _connection,
          session: session,
        ),
      ),
    );

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await tester.pump();
  final send = find.byKey(const ValueKey('send')).hitTestable();
  expect(send, findsOneWidget);
  await tester.tap(send);
  await _flush(tester);
}

/// Runs [body] collecting what the app logs. `debugPrint` is put back before
/// the test ends, as the test binding requires.
Future<void> _withLog(Future<void> Function(List<String> lines) body) async {
  final lines = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) lines.add(message);
  };
  try {
    await body(lines);
  } finally {
    debugPrint = original;
  }
}

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(ChatScreen)));

String _composerText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first).controller!.text;

/// The first turn of the chat, written in its first screen and answered.
Future<void> _firstTurn(
  WidgetTester tester,
  _Gateway gateway,
  _Fixture fixture,
) async {
  await _send(tester, 'Synthetic first');
  expect(gateway.creates, 1);
  expect(gateway.submissions, ['Synthetic first']);
  fixture.stored.addAll([
    {'id': 'row-user-1', 'role': 'user', 'content': 'Synthetic first'},
    {'id': 'row-reply-1', 'role': 'assistant', 'content': 'Synthetic reply'},
  ]);
  gateway.complete('Synthetic reply');
  await _flush(tester);
  await tester.pump(const Duration(seconds: 2));
  expect(fixture.chat.storedSessionId, _durableId);
  expect(fixture.chat.isStreaming, isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final secure = <String, String>{};
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        switch (call.method) {
          case 'read':
            return secure[args['key']];
          case 'write':
            secure[args['key'] as String] = args['value'] as String;
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

  test('a lease covers its conversation as one begun with those ids would: '
      'the newest route owns them, a displaced, retired or outdated one '
      'gains nothing', () async {
    LocalConversationLifecycle begin(String id) =>
        LocalConversationCleanupFence.beginLifecycle(
          connectionId: _connection.id,
          profile: 'default',
          sessionId: id,
        );
    bool writes(LocalConversationLifecycle lease, String id) =>
        LocalConversationCleanupFence.writeRejectionReason(
          connectionId: _connection.id,
          profile: 'default',
          sessionId: id,
          lifecycle: lease,
        ) ==
        null;
    bool cover(LocalConversationLifecycle lease, Set<String> ids) =>
        LocalConversationCleanupFence.coverConversation(lease, ids);

    final first = begin(_provisionalId);
    final second = begin(_durableId);
    expect(writes(second, _provisionalId), isFalse);

    expect(cover(second, {_provisionalId, _durableId, ''}), isTrue);
    expect(writes(second, _provisionalId), isTrue);
    expect(writes(second, _durableId), isTrue);
    expect(writes(first, _provisionalId), isFalse);

    // The older route takes nothing back while the newer one lives.
    expect(cover(first, {_durableId}), isFalse);
    expect(LocalConversationCleanupFence.renewAfterRouteReturn(first), isNull);
    expect(writes(second, _durableId), isTrue);

    // Once the newer one is gone it gains nothing more, and the older one
    // renews and covers the conversation again.
    LocalConversationCleanupFence.endLifecycle(second);
    expect(cover(second, {_provisionalId}), isFalse);
    final renewed = LocalConversationCleanupFence.renewAfterRouteReturn(first)!;
    expect(cover(renewed, {_durableId}), isTrue);
    expect(writes(renewed, _provisionalId), isTrue);
    expect(writes(renewed, _durableId), isTrue);
    expect(writes(first, _provisionalId), isFalse);

    // A cleanup outdates every lease begun before it.
    await LocalConversationCleanupFence.cleanupProfile(
      connectionId: _connection.id,
      profile: 'default',
      operation: () async {},
    );
    expect(cover(renewed, {'another-id'}), isFalse);
    expect(writes(renewed, _durableId), isFalse);
  });

  testWidgets('a chat left and opened again from the list, under the id '
      'Hermes gave it, sends what is typed', (tester) async {
    final gateway = _Gateway();
    final fixture = await _mount(tester, gateway);
    await _firstTurn(tester, gateway, fixture);

    fixture.navigator.pop();
    await _flush(tester);
    expect(find.byType(ChatScreen), findsNothing);
    // The chat that ran the turn stays alive and answers to both names.
    expect(
      fixture.service.of(_connection.id, _durableId, profile: 'default'),
      same(fixture.chat),
    );

    _push(fixture.navigator, 'durable', _durable);
    await _flush(tester);
    await _send(tester, 'Synthetic second');

    expect(tester.takeException(), isNull);
    expect(gateway.submissions, ['Synthetic first', 'Synthetic second']);
    expect(gateway.creates, 1);
    expect(_composerText(tester), isEmpty);
    gateway.complete('Synthetic second reply');
    await _flush(tester);
  });

  testWidgets('a chat opened under the id Hermes gave it over its first '
      'screen (a notification tap) sends what is typed, and so does the '
      'first screen once back on top', (tester) async {
    final gateway = _Gateway();
    final fixture = await _mount(tester, gateway);
    await _firstTurn(tester, gateway, fixture);

    _push(fixture.navigator, 'durable', _durable);
    await _flush(tester);
    expect(find.byType(ChatScreen, skipOffstage: false), findsNWidgets(2));
    await _send(tester, 'Synthetic second');

    expect(tester.takeException(), isNull);
    expect(gateway.submissions, ['Synthetic first', 'Synthetic second']);
    expect(_composerText(tester), isEmpty);
    fixture.stored.addAll([
      {'id': 'row-user-2', 'role': 'user', 'content': 'Synthetic second'},
      {'id': 'row-reply-2', 'role': 'assistant', 'content': 'Second reply'},
    ]);
    gateway.complete('Second reply');
    await _flush(tester);
    await tester.pump(const Duration(seconds: 2));

    fixture.navigator.pop();
    await _flush(tester);
    expect(find.byType(ChatScreen), findsOneWidget);
    await _send(tester, 'Synthetic third');

    expect(tester.takeException(), isNull);
    expect(gateway.submissions, [
      'Synthetic first',
      'Synthetic second',
      'Synthetic third',
    ]);
    expect(_composerText(tester), isEmpty);
    gateway.complete('Third reply');
    await _flush(tester);
  });

  testWidgets('the draft of a chat reopened under its durable id is kept '
      'and cleared under that id', (tester) async {
    final gateway = _Gateway();
    final fixture = await _mount(tester, gateway);
    await _firstTurn(tester, gateway, fixture);
    final drafts = ChatDraftStore(await SharedPreferences.getInstance());
    // The first screen's draft of the message it sent is gone.
    for (final id in [_provisionalId, _durableId]) {
      expect(
        (await drafts.load(_connection.id, id, profile: 'default')).text,
        isEmpty,
        reason: id,
      );
    }

    fixture.navigator.pop();
    await _flush(tester);
    _push(fixture.navigator, 'durable', _durable);
    await _flush(tester);
    await tester.enterText(find.byType(TextField).first, 'Synthetic draft');
    await _flush(tester);
    expect(
      (await drafts.load(_connection.id, _durableId, profile: 'default')).text,
      'Synthetic draft',
    );

    await _send(tester, 'Synthetic draft');
    expect(gateway.submissions, ['Synthetic first', 'Synthetic draft']);
    expect(
      (await drafts.load(_connection.id, _durableId, profile: 'default')).text,
      isEmpty,
    );
    gateway.complete('Synthetic second reply');
    await _flush(tester);
  });

  testWidgets('a send the chat refuses is logged with its reason and tells '
      'what to do, with the message still in the composer', (tester) async {
    final gateway = _Gateway();
    final fixture = await _mount(tester, gateway);
    await _firstTurn(tester, gateway, fixture);
    fixture.navigator.pop();
    await _flush(tester);
    _push(fixture.navigator, 'durable', _durable);
    await _flush(tester);
    // Something else takes the id the chat writes under: the screen's own
    // checks still pass, the chat's admission does not.
    LocalConversationCleanupFence.beginLifecycle(
      connectionId: _connection.id,
      profile: 'default',
      sessionId: _provisionalId,
    );

    await _withLog((lines) async {
      await _send(tester, 'Synthetic refused');
      expect(tester.takeException(), isNull);
      expect(gateway.submissions, ['Synthetic first']);
      expect(_composerText(tester), 'Synthetic refused');
      expect(
        lines,
        contains('[composer-send] refused (chatWrite:displacedByLiveOwner)'),
      );
      expect(find.text(_strings(tester).chaSendNotSentReopen), findsWidgets);
      // The button is free again for the next press.
      expect(find.byKey(const ValueKey('send')).hitTestable(), findsOneWidget);
    });
  });

  testWidgets('a send of blank space is logged and tells to write a '
      'message', (tester) async {
    final gateway = _Gateway();
    await _mount(tester, gateway);
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.pump();

    await _withLog((lines) async {
      tester
          .widget<ConsoleComposer>(find.byType(ConsoleComposer))
          .onSend('   ', const []);
      await _flush(tester);
      expect(tester.takeException(), isNull);
      expect(gateway.creates, 0);
      expect(gateway.submissions, isEmpty);
      expect(lines, contains('[composer-send] refused (nothingToSend)'));
      expect(find.text(_strings(tester).chaSendNothingToSend), findsWidgets);
    });
  });

  testWidgets('a send made while the secure restore cannot finish is '
      'refused at once and frees the composer, instead of waiting for it', (
    tester,
  ) async {
    final gateway = _Gateway();
    final issuer = Object();
    final locked = ValueNotifier<bool>(true);
    addTearDown(() => AppLockSensitiveReadFence.unbind(issuer));
    // The Keystore is closed before the chat opens: its restore read parks.
    await _mount(
      tester,
      gateway,
      beforeOpen: (prefs) =>
          AppLockSensitiveReadFence.bind(issuer, prefs, locked),
    );

    await _withLog((lines) async {
      await tester.enterText(find.byType(TextField).first, 'Synthetic held');
      await tester.pump();
      tester
          .widget<ConsoleComposer>(find.byType(ConsoleComposer))
          .onSend('Synthetic held', const []);
      await _flush(tester);
      expect(tester.takeException(), isNull);
      expect(gateway.submissions, isEmpty);
      expect(lines, contains('[composer-send] refused (restoreParked)'));
      expect(_composerText(tester), 'Synthetic held');
      expect(find.text(_strings(tester).chaOutboxUnavailable), findsWidgets);
      // A later press is not swallowed by a submission that never ended.
      lines.clear();
      tester
          .widget<ConsoleComposer>(find.byType(ConsoleComposer))
          .onSend('Synthetic held', const []);
      await _flush(tester);
      expect(lines, contains('[composer-send] refused (restoreParked)'));
      expect(
        lines,
        isNot(contains('[composer-send] ignored (submissionInFlight)')),
      );
    });

    // Unlocked, the restore runs again and the same message goes out.
    locked.value = false;
    AppLockSensitiveReadFence.configurationChanged(issuer);
    await _flush(tester);
    await _send(tester, 'Synthetic held');
    expect(gateway.submissions, ['Synthetic held']);
    gateway.complete('Synthetic reply');
    await _flush(tester);
  });
}
