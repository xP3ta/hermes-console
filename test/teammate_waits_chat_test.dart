// Where «Waiting on teammates» lives: above the composer of a bot's canonical
// Bot Chat and nowhere else (Desktop `teammate-waits.tsx` mounts it in the
// composer's top area for the chat whose canonical session is the sender
// bot's). A gateway that predates `bot_delivery.list` leaves the chat as it
// was.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_delivery.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;
import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

class _BotGateway extends peer.PeerGateway implements BotDeliveryGateway {
  _BotGateway(super.snapshot);

  final profiles = <String>[];
  Object? failure;
  List<BotDelivery> rows = const [];

  @override
  Future<List<BotDelivery>> listBotDeliveries(String profile) async {
    profiles.add(profile);
    final error = failure;
    if (error != null) throw error;
    return rows;
  }
}

BotDelivery _working(String id, String target) => BotDelivery(
  deliveryId: id,
  target: target,
  targetHandle: '',
  state: BotDeliveryState.working,
  since: DateTime.now().millisecondsSinceEpoch / 1000 - 60,
  preview: 'write the report',
);

void main() {
  final connection = SavedConnection(
    id: 'peer',
    label: 'Peer',
    host: 'example.invalid',
    port: 443,
    apiKey: 'test-key',
    useHttps: true,
    kind: InstanceKind.vps,
  );
  Session sessionOf(String source) => Session(
    id: 'stored-peer',
    title: 'Peer',
    model: 'hermes-agent',
    source: source,
    messageCount: 1,
    isActive: false,
    preview: '',
    startedAt: 0,
  );
  final snapshot = DesktopSessionSnapshot.fromJson(
    {
      'session_id': 'runtime-peer',
      'session_key': 'stored-peer',
      'message_count': 1,
      'messages': [peer.publicSnapshot],
      'running': false,
    },
    requestedStoredSessionId: 'stored-peer',
    created: false,
    method: 'session.resume',
  );

  setUp(() {
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
          case 'readAll':
            return Map<String, String>.from(secure);
        }
        return null;
      },
    );
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/background',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
    final temp = Directory.systemTemp.createTempSync('teammate_waits_chat_');
    addTearDown(() => temp.deleteSync(recursive: true));
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => temp.path,
    );
  });

  Future<ActiveChatService> open(
    WidgetTester tester,
    _BotGateway gateway, {
    required String source,
    AgentProfile? bot,
  }) async {
    final session = sessionOf(source);
    final service = ActiveChatService(
      attachDesktopRuntimeOnLoad: true,
      compressionRestoreStore: testCompressionRestoreStore(),
      globalActivity: GlobalActivityAggregate.inMemory(),
    );
    final chat = service.attach(
      connection: connection,
      sessionId: 'stored-peer',
      sessionTitle: 'Peer',
      sessionSnapshot: session,
      initialStoredSessionId: 'stored-peer',
      api: testApiClient(
        baseUrl: 'https://example.invalid',
        httpClient: MockClient((_) async => http.Response('nf', 404)),
      ),
      desktopGateway: gateway,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
    );
    await tester.runAsync(chat.loadMessages);
    tester.platformDispatcher.localesTestValue = [const Locale('en')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
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
    await tester.pump(const Duration(milliseconds: 400));
    Navigator.of(tester.element(find.byType(Navigator).first)).push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => ChatScreen(
          connection: connection,
          session: session,
          initialStoredSessionId: 'stored-peer',
          missionBotProfile: bot,
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 16));
    return service;
  }

  Future<void> close(WidgetTester tester, ActiveChatService service) async {
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await tester.pump(const Duration(minutes: 5));
  }

  final strip = find.byKey(const ValueKey('teammate-waits'));
  const ana = AgentProfile(name: 'ana');

  testWidgets('a bot canonical Bot Chat shows its sender-bot strip above the '
      'composer', (tester) async {
    final gateway = _BotGateway(snapshot)
      ..rows = [_working('d1', 'bob'), _working('d2', 'carol')];
    final service = await open(
      tester,
      gateway,
      source: 'bot-mode-canonical',
      bot: ana,
    );

    expect(gateway.profiles, isNotEmpty);
    expect(gateway.profiles.toSet(), {'ana'});
    expect(strip, findsOneWidget);
    expect(find.text('Waiting on teammates'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('carol'), findsOneWidget);
    expect(find.text('Working on it'), findsNWidgets(2));
    final composer = find.byType(EditableText).first;
    expect(
      tester.getBottomLeft(strip).dy,
      lessThanOrEqualTo(tester.getTopLeft(composer).dy),
      reason: 'it sits above the composer',
    );
    await close(tester, service);
  });

  testWidgets('any other chat has no strip and asks nothing', (tester) async {
    final gateway = _BotGateway(snapshot)..rows = [_working('d1', 'bob')];
    final service = await open(tester, gateway, source: 'api_server');
    expect(strip, findsNothing);
    expect(gateway.profiles, isEmpty);
    await close(tester, service);
  });

  testWidgets('a canonical chat that is not a known bot has no strip', (
    tester,
  ) async {
    final gateway = _BotGateway(snapshot)..rows = [_working('d1', 'bob')];
    final service = await open(tester, gateway, source: 'bot-mode-canonical');
    expect(strip, findsNothing);
    expect(gateway.profiles, isEmpty);
    await close(tester, service);
  });

  testWidgets('a gateway without the method leaves the chat as it was', (
    tester,
  ) async {
    final gateway = _BotGateway(snapshot)
      ..failure = const TuiGatewayRpcError(
        'bot_delivery.list',
        'method not found',
        code: -32601,
      );
    final service = await open(
      tester,
      gateway,
      source: 'bot-mode-canonical',
      bot: ana,
    );
    await tester.pump(const Duration(seconds: 30));
    expect(strip, findsNothing);
    expect(gateway.profiles, ['ana'], reason: 'asked once, not every 5 s');
    expect(tester.takeException(), isNull);
    await close(tester, service);
  });
}
