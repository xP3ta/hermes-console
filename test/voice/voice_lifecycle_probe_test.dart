import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/main.dart';

class _MemorySecureStorage extends FlutterSecureStorage {
  _MemorySecureStorage(this.values);

  final Map<String, String> values;

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
      values.remove(key);
    } else {
      values[key] = value;
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
  }) async => values[key];

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map<String, String>.of(values);
}

class _BlockedSttEngine implements SttEngine {
  _BlockedSttEngine(this.availabilityGate);

  final Completer<bool> availabilityGate;

  @override
  Future<bool> available() => availabilityGate.future;

  @override
  bool get supportsPartials => true;

  @override
  Stream<SttResult> listen({
    String localeId = 'es_ES',
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
  }) => const Stream<SttResult>.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _CountingClient extends MockClient {
  _CountingClient(super.handler);

  int closes = 0;

  @override
  void close() {
    closes++;
    super.close();
  }
}

SavedConnection _connection() => SavedConnection(
  id: 'voice-lifecycle',
  label: 'Voice lifecycle',
  host: '127.0.0.1',
  port: 8642,
  apiKey: String.fromCharCodes(const [116]),
);

Session _session() => Session(
  id: 'voice-lifecycle-session',
  title: 'Voice lifecycle',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

ApiClient _safeApi() => ApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  apiKey: String.fromCharCodes(const [116]),
  httpClient: MockClient((_) async => http.Response('not found', 404)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var secureValues = <String, String>{};
  var storeNamespace = 0;
  var foregroundServiceRunning = false;

  void mockChannel(String name) {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUp(() {
    secureValues = <String, String>{};
    foregroundServiceRunning = false;
    TurnOutboxStore.resetSerializationForTesting();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final arguments =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            final key = arguments['key'] as String?;
            switch (call.method) {
              case 'write':
                secureValues[key!] = arguments['value'] as String;
              case 'read':
                return secureValues[key];
              case 'delete':
                secureValues.remove(key);
              case 'readAll':
                return Map<String, String>.from(secureValues);
              case 'containsKey':
                return secureValues.containsKey(key);
            }
            return null;
          },
        );
    mockChannel('dexterous.com/flutter/local_notifications');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async {
            switch (call.method) {
              case 'isRunningService':
                return foregroundServiceRunning;
              case 'startService':
              case 'restartService':
                foregroundServiceRunning = true;
              case 'stopService':
                foregroundServiceRunning = false;
              case 'attachedActivity':
                return true;
            }
            return null;
          },
        );
    mockChannel('flutter_foreground_task/background');
  });

  Future<void> pumpChat(WidgetTester tester, _BlockedSttEngine stt) async {
    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    SharedPreferences.setMockInitialValues(const {'onboarding_done': true});
    final preferences = await SharedPreferences.getInstance();
    final connectionManager = await ConnectionManager.create(preferences);
    final storage = _MemorySecureStorage(secureValues);
    final draftStore = ChatDraftStore(
      preferences,
      secureStorage: storage,
      mutationNamespaceForTesting: 'voice-lifecycle-${++storeNamespace}',
    );
    final activeChats = ActiveChatService(
      compressionRestoreStore: CompressionRestoreStore(
        storage: FlutterSecureCompressionRestoreStorage(
          secureStorage: storage,
        ),
        mutationNamespaceForTesting:
            'voice-lifecycle-compression-${++storeNamespace}',
      ),
    );
    addTearDown(activeChats.dispose);
    final connection = _connection();
    final session = _session();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: session.id,
      logicalSessionId: session.logicalId,
      sessionTitle: session.displayTitle,
      sessionProfile: session.profile,
      api: _safeApi(),
    );
    chat.messagesLoaded = true;
    chat.state = ChatPipelineState.idle;
    final secureStorage = SecureStorage();

    await tester.pumpWidget(
      HermesApp(
        connManager: connectionManager,
        appLock: AppLockService(preferences),
        approvalPolicy: ApprovalPolicyService(preferences),
        fontSize: FontSizeService(preferences),
        bridgeManager: BridgeManager(secureStorage, connectionManager),
        sshManager: SshManager(secureStorage, connectionManager),
        sftpTransfers: SftpTransferService(
          SshManager(secureStorage, connectionManager),
          NotificationService(preferences),
        ),
        sshSessions: SshSessionService(
          SshManager(secureStorage, connectionManager),
        ),
        notifications: NotificationService(preferences),
        activeChats: activeChats,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));

    final app = tester.state<HermesAppState>(find.byType(HermesApp));
    app.voice.debugSttFactory = () => stt;
    final context = tester.element(find.byType(Navigator).first);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          connection: connection,
          session: session,
          draftStoreOverride: draftStore,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  for (final invalidation in [
    'paused',
    'pausedResumed',
    'hidden',
    'detached',
    'covered',
    'dispose',
    'consent',
    'mode',
    'none',
  ]) {
    testWidgets('adversarial late server setup after $invalidation', (
      tester,
    ) async {
      final permission = Completer<bool>();
      await pumpChat(tester, _BlockedSttEngine(permission));
      final app = tester.state<HermesAppState>(find.byType(HermesApp));
      await app.voice.acceptVoiceDisclosure(continueWhenLocked: false);
      final preferences = await SharedPreferences.getInstance();
      final identity = nativeVoicePreferenceIdentity(
        _connection().effectiveDashboardUrl,
        profile: '',
      );
      await NativeVoiceModeStore(
        preferences,
      ).write(identity, NativeVoiceMode.server);
      await NativeVoiceConsentStore(
        preferences,
      ).write(identity, NativeVoiceConsent.accepted);
      await NativeVoiceCapabilityStore(preferences).write(
        identity,
        NativeVoiceCapability(
          transcribe: true,
          speak: true,
          checkedAtMs: DateTime.now().millisecondsSinceEpoch,
          conclusive: true,
        ),
      );
      final schemaRequested = Completer<void>();
      final release = Completer<void>();
      _CountingClient? setupClient;
      var transcribeRequests = 0;
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        if (!permission.isCompleted) permission.complete(false);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
      });

      await http.runWithClient(
        () async {
          await tester.tap(find.byKey(const ValueKey('voice')));
          for (
            var index = 0;
            index < 20 && !schemaRequested.isCompleted;
            index++
          ) {
            await tester.pump(const Duration(milliseconds: 1));
          }
          expect(
            schemaRequested.isCompleted,
            isTrue,
            reason: 'the real screen must reach the held server setup',
          );
          expect(app.voice.nativeVoiceActive, isFalse);
          expect(app.voiceConvo.active, isFalse);

          if ([
            'paused',
            'pausedResumed',
            'hidden',
            'detached',
          ].contains(invalidation)) {
            final lifecycleState = invalidation == 'pausedResumed'
                ? AppLifecycleState.paused
                : AppLifecycleState.values.byName(invalidation);
            tester.binding.handleAppLifecycleStateChanged(lifecycleState);
            if (invalidation == 'pausedResumed') {
              await tester.pump();
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.hidden,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );
            }
          } else if (invalidation == 'covered') {
            Navigator.of(tester.element(find.byType(ChatScreen))).push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('covered')),
              ),
            );
          } else if (invalidation == 'dispose') {
            Navigator.of(tester.element(find.byType(ChatScreen))).pop();
          } else if (invalidation == 'consent') {
            await NativeVoiceConsentStore(
              preferences,
            ).write(identity, NativeVoiceConsent.rejected);
          } else if (invalidation == 'mode') {
            await NativeVoiceModeStore(
              preferences,
            ).write(identity, NativeVoiceMode.phone);
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          release.complete();
          for (var index = 0; index < 20; index++) {
            await tester.pump(const Duration(milliseconds: 1));
          }
          if (app.voice.nativeVoiceActive) {
            await app.voice.transcribeNativeWav(
              Uint8List.fromList(const [82, 73, 70, 70]),
            );
          }
          expect(
            app.voice.nativeVoiceActive,
            invalidation == 'none',
            reason: 'no late authorization after loss of current UI/lifecycle',
          );
          expect(setupClient?.closes, invalidation == 'none' ? 0 : 1);
          expect(transcribeRequests, invalidation == 'none' ? 1 : 0);
        },
        () {
          late _CountingClient client;
          client = _CountingClient((request) async {
            if (request.url.path == '/api/config/schema') {
              setupClient = client;
              if (!schemaRequested.isCompleted) schemaRequested.complete();
              await release.future;
            }
            if (request.url.path == '/api/audio/transcribe') {
              transcribeRequests++;
              return http.Response('{"ok":true,"transcript":"synthetic"}', 200);
            }
            if (request.url.path == '/') {
              return http.Response(
                'window.__HERMES_SESSION_TOKEN__="synthetic";',
                200,
              );
            }
            return http.Response('{}', 200);
          });
          return client;
        },
      );
    });
  }
}
