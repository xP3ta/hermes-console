import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _ViewerGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopSessionActivityGateway,
        HermesDesktopApprovalResultGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  DesktopSessionSnapshot snapshot;
  DesktopActiveSessionList activeSessionList = const DesktopActiveSessionList(
    sessions: [],
  );
  Completer<DesktopSessionSnapshot>? resumeGate;
  Completer<void>? connectGate;
  bool connected = false;
  int connectCalls = 0;
  int resumeCalls = 0;
  int recoveryResumeCalls = 0;
  int createCalls = 0;
  int submitCalls = 0;
  int activateCalls = 0;
  final approvalCalls =
      <({String runtimeId, String choice, String requestId})>[];
  Completer<DesktopApprovalResult>? approvalGate;
  DesktopApprovalResult approvalResult = const DesktopApprovalResult(
    resolved: 1,
  );

  _ViewerGateway(this.snapshot);

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async {
    connectCalls++;
    await connectGate?.future;
    connected = true;
  }

  void emit(String type, Map<String, dynamic> payload) => _events.add(
    TuiGatewayEvent(
      type: type,
      sessionId: snapshot.runtimeSessionId,
      payload: payload,
    ),
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumeCalls++;
    return resumeGate?.future ?? snapshot;
  }

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    recoveryResumeCalls++;
    return snapshot;
  }

  @override
  // ignore: deprecated_member_use_from_same_package
  void commitRecoveryRuntime(String runtimeSessionId) {}

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async {
    activateCalls++;
    return snapshot;
  }

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async => activeSessionList;

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    createCalls++;
    throw StateError('viewer attach must not create');
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => throw StateError('legacy mutation is outside viewer attach');

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submitCalls++;
  }

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
  }) async {
    await resolveApprovalChecked(
      runtimeSessionId,
      choice,
      requestId: requestId ?? '',
    );
  }

  @override
  Future<DesktopApprovalResult> resolveApprovalChecked(
    String runtimeSessionId,
    String choice, {
    required String requestId,
  }) {
    approvalCalls.add((
      runtimeId: runtimeSessionId,
      choice: choice,
      requestId: requestId,
    ));
    return approvalGate?.future ?? Future.value(approvalResult);
  }

  @override
  Future<void> close() async {
    connected = false;
    await _events.close();
  }
}

ActiveChat _chat(
  _ViewerGateway gateway, {
  required int Function() restCalls,
  bool attachDesktopRuntimeOnLoad = true,
  bool allowUnownedDesktopSnapshotForTesting = true,
  CompressionRestoreStore? compressionRestoreStore,
  Future<http.Response> Function()? restResponse,
  Future<void> Function()? beforePrivacyCheckpointSave,
  Future<void> Function()? beforePrivacySnapshotLoad,
  Future<bool> Function()? historyHydrationAwaiter,
  StoredSessionMessageLoader? storedMessageLoader,
}) {
  return ActiveChat(
    compressionRestoreStore: compressionRestoreStore ?? testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'live-viewer',
      label: 'Live viewer',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-live',
    sessionTitle: 'Live',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test',
      httpClient: MockClient((_) async {
        restCalls();
        return restResponse?.call() ?? http.Response('{"messages":[]}', 200);
      }),
    ),
    desktopGateway: gateway,
    attachDesktopRuntimeOnLoad: attachDesktopRuntimeOnLoad,
    allowUnownedDesktopSnapshotForTesting:
        allowUnownedDesktopSnapshotForTesting,
    beforePrivacyCheckpointSave: beforePrivacyCheckpointSave,
    beforePrivacySnapshotLoad: beforePrivacySnapshotLoad,
    historyHydrationAwaiter: historyHydrationAwaiter,
    storedMessageLoader: storedMessageLoader,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'prehydrated chat acquires one exact non-creating viewer attach',
    () async {
      var reads = 0;
      final gateway = _ViewerGateway(
        DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-live',
            'session_key': 'stored-live',
            'messages': <Object>[],
            'running': true,
          },
          requestedStoredSessionId: 'stored-live',
          created: false,
          method: 'session.resume',
        ),
      );
      final chat = _chat(gateway, restCalls: () => reads++);
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });
      chat.internalMessagesForTesting = [
        {'role': 'assistant', 'content': 'already visible'},
      ];
      chat.messagesLoaded = true;
      chat.adoptDesktopRuntimeForTesting('runtime-prehydrated');
      final visible = chat.messages.single;

      expect(gateway.isConnected, isFalse);
      expect(await chat.attachExistingRuntimeViewer(), isTrue);
      expect(await chat.attachExistingRuntimeViewer(), isTrue);

      expect(gateway.resumeCalls, 1);
      expect(gateway.activateCalls, 0);
      expect(gateway.createCalls, 0);
      expect(gateway.submitCalls, 0);
      expect(reads, 0);
      expect(identical(chat.messages.single, visible), isTrue);
      expect(chat.desktopRuntimeSessionId, 'runtime-live');

      gateway.emit('message.start', const {});
      gateway.emit('subagent.start', const {
        'subagent_id': 'child-live',
        'child_session_id': 'child-durable-live',
        'status': 'running',
      });
      gateway.emit('approval.request', const {
        'request_id': 'approval-live',
        'command': 'pwd',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(chat.subagentAggregate.activeCount, 1);
      expect(chat.subagentActivities, isEmpty);
      expect(chat.pendingApproval?['request_id'], 'approval-live');
      expect(gateway.resumeCalls, 1);
    },
  );

  test(
    'automatic viewer attach rejects a runtime not advertised for the durable '
    'session',
    () async {
      final gateway =
          _ViewerGateway(
              DesktopSessionSnapshot.fromJson(
                const {
                  'session_id': 'runtime-foreign',
                  'session_key': 'stored-live',
                  'messages': <Object>[],
                  'running': true,
                },
                requestedStoredSessionId: 'stored-live',
                created: false,
                method: 'session.resume',
              ),
            )
            ..activeSessionList = const DesktopActiveSessionList(
              sessions: [
                DesktopActiveSession(
                  runtimeSessionId: 'runtime-advertised',
                  storedSessionId: 'stored-live',
                ),
              ],
            );
      final chat = _chat(
        gateway,
        restCalls: () => 0,
        allowUnownedDesktopSnapshotForTesting: false,
      );
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });
      chat.internalMessagesForTesting = [
        {'role': 'assistant', 'content': 'already visible'},
      ];
      chat.messagesLoaded = true;

      expect(await chat.attachExistingRuntimeViewer(), isFalse);

      expect(gateway.resumeCalls, 0);
      expect(gateway.activateCalls, 1);
      expect(gateway.createCalls, 0);
      expect(gateway.submitCalls, 0);
      expect(chat.desktopRuntimeSessionId, isNull);
    },
  );

  test(
    'automatic viewer attach activates the exact advertised runtime',
    () async {
      final gateway =
          _ViewerGateway(
              DesktopSessionSnapshot.fromJson(
                const {
                  'session_id': 'runtime-advertised',
                  'session_key': 'stored-live',
                  'messages': <Object>[],
                  'running': true,
                },
                requestedStoredSessionId: 'stored-live',
                created: false,
                method: 'session.activate',
              ),
            )
            ..activeSessionList = const DesktopActiveSessionList(
              sessions: [
                DesktopActiveSession(
                  runtimeSessionId: 'runtime-advertised',
                  storedSessionId: 'stored-live',
                ),
              ],
            );
      final chat = _chat(
        gateway,
        restCalls: () => 0,
        allowUnownedDesktopSnapshotForTesting: false,
      );
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });
      chat.messagesLoaded = true;

      expect(await chat.attachExistingRuntimeViewer(), isTrue);
      expect(gateway.activateCalls, 1);
      expect(gateway.resumeCalls, 0);
      expect(gateway.createCalls, 0);
      expect(gateway.submitCalls, 0);
      expect(chat.desktopRuntimeSessionId, 'runtime-advertised');
    },
  );

  test('automatic viewer attach resumes a dormant durable session', () async {
    final gateway = _ViewerGateway(
      DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-resumed',
          'session_key': 'stored-live',
          'messages': <Object>[],
          'running': false,
        },
        requestedStoredSessionId: 'stored-live',
        created: false,
        method: 'session.resume',
      ),
    );
    final chat = _chat(
      gateway,
      restCalls: () => 0,
      allowUnownedDesktopSnapshotForTesting: false,
    );
    addTearDown(() async {
      chat.dispose();
      await gateway.close();
    });
    chat.messagesLoaded = true;

    expect(await chat.attachExistingRuntimeViewer(), isTrue);
    expect(gateway.activateCalls, 0);
    expect(gateway.resumeCalls, 1);
    expect(gateway.createCalls, 0);
    expect(gateway.submitCalls, 0);
    expect(chat.desktopRuntimeSessionId, 'runtime-resumed');
  });

  test('passive opt-out blocks every automatic viewer bootstrap', () async {
    var reads = 0;
    final gateway = _ViewerGateway(
      DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-live',
          'session_key': 'stored-live',
          'messages': <Object>[],
          'running': true,
        },
        requestedStoredSessionId: 'stored-live',
        created: false,
        method: 'session.resume',
      ),
    );
    final chat = _chat(
      gateway,
      restCalls: () => reads++,
      attachDesktopRuntimeOnLoad: false,
    );
    addTearDown(() async {
      chat.dispose();
      await gateway.close();
    });
    chat.internalMessagesForTesting = [
      {'role': 'assistant', 'content': 'already visible'},
    ];
    chat.messagesLoaded = true;

    await chat.warmDesktopGatewayForAutomaticBootstrap();
    await chat.warmDesktopGatewayForAutomaticBootstrap();
    expect(await chat.attachExistingRuntimeViewer(), isFalse);
    expect(await chat.attachExistingRuntimeViewer(), isFalse);

    expect(gateway.connectCalls, 0);
    expect(gateway.resumeCalls, 0);
    expect(gateway.createCalls, 0);
    expect(gateway.submitCalls, 0);
    expect(reads, 0);
  });

  test(
    'viewer attach restores pending approval from resume snapshot',
    () async {
      var reads = 0;
      final snapshot = DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-live',
          'session_key': 'stored-live',
          'messages': <Object>[],
          'running': true,
          'pending_approval': {
            'request_id': 'approval-before-attach',
            'tool': 'shell',
            'choices': ['once', 'session', 'deny'],
            'allow_always': false,
          },
        },
        requestedStoredSessionId: 'stored-live',
        created: false,
        method: 'session.resume',
      );
      expect(snapshot.pendingApprovalProvided, isTrue);
      expect(snapshot.pendingApproval?['request_id'], 'approval-before-attach');

      final gateway = _ViewerGateway(snapshot);
      final chat = _chat(gateway, restCalls: () => reads++);
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });
      chat.messagesLoaded = true;

      expect(await chat.attachExistingRuntimeViewer(), isTrue);
      expect(chat.pendingApproval?['request_id'], 'approval-before-attach');
      expect(chat.pendingApproval?['choices'], ['once', 'session', 'deny']);
      expect(chat.pendingApproval?['allow_always'], isFalse);
      expect(reads, 0);
    },
  );

  test(
    'restored approval once and deny use exact parent runtime and request id',
    () async {
      for (final choice in const ['once', 'deny']) {
        var reads = 0;
        final gateway = _ViewerGateway(
          DesktopSessionSnapshot.fromJson(
            const {
              'session_id': 'runtime-live',
              'session_key': 'stored-live',
              'messages': <Object>[],
              'running': true,
              'pending_approval': {
                'request_id': 'approval-restored',
                'tool': 'shell',
                'choices': ['once', 'deny'],
              },
            },
            requestedStoredSessionId: 'stored-live',
            created: false,
            method: 'session.resume',
          ),
        );
        final chat = _chat(gateway, restCalls: () => reads++);
        chat.messagesLoaded = true;
        expect(await chat.attachExistingRuntimeViewer(), isTrue);

        await chat.resolveApproval(choice);

        expect(gateway.approvalCalls, [
          (
            runtimeId: 'runtime-live',
            choice: choice,
            requestId: 'approval-restored',
          ),
        ]);
        expect(chat.pendingApproval, isNull);
        chat.dispose();
        await gateway.close();
      }
    },
  );

  test(
    'resolved zero retires only request A and cannot erase replacement B',
    () async {
      var reads = 0;
      final gateway = _ViewerGateway(
        DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-live',
            'session_key': 'stored-live',
            'messages': <Object>[],
            'running': true,
            'pending_approval': {
              'request_id': 'request-a',
              'choices': ['once', 'deny'],
            },
          },
          requestedStoredSessionId: 'stored-live',
          created: false,
          method: 'session.resume',
        ),
      )..approvalGate = Completer<DesktopApprovalResult>();
      final chat = _chat(gateway, restCalls: () => reads++);
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });
      chat.messagesLoaded = true;
      expect(await chat.attachExistingRuntimeViewer(), isTrue);
      final events = <ActiveChatEvent>[];
      final subscription = chat.changes.listen(events.add);
      addTearDown(subscription.cancel);

      final resolvingA = chat.resolveApproval('once');
      chat.pendingApproval = const {
        'request_id': 'request-b',
        'choices': ['once', 'deny'],
      };
      gateway.approvalGate!.complete(const DesktopApprovalResult(resolved: 0));
      await resolvingA;

      expect(gateway.approvalCalls.single.requestId, 'request-a');
      expect(chat.pendingApproval?['request_id'], 'request-b');
      expect(events, isNot(contains(ActiveChatEvent.toolProgress)));
    },
  );

  test(
    'explicit empty snapshot clears only its captured approval generation',
    () async {
      var reads = 0;
      final gateway = _ViewerGateway(
        DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-live',
            'session_key': 'stored-live',
            'messages': <Object>[],
            'running': true,
            'pending_approval': null,
          },
          requestedStoredSessionId: 'stored-live',
          created: false,
          method: 'session.resume',
        ),
      );
      final chat = _chat(gateway, restCalls: () => reads++);
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });
      chat.pendingApproval = const {'request_id': 'request-before-resume'};
      chat.messagesLoaded = true;

      expect(await chat.attachExistingRuntimeViewer(), isTrue);
      expect(chat.pendingApproval, isNull);
    },
  );

  test(
    'late explicit empty snapshot cannot clear replacement request',
    () async {
      var reads = 0;
      final gateway = _ViewerGateway(
        DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-live',
            'session_key': 'stored-live',
            'messages': <Object>[],
            'running': true,
            'pending_approval': null,
          },
          requestedStoredSessionId: 'stored-live',
          created: false,
          method: 'session.resume',
        ),
      )..resumeGate = Completer<DesktopSessionSnapshot>();
      final chat = _chat(gateway, restCalls: () => reads++);
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });
      chat.pendingApproval = const {'request_id': 'request-a'};
      chat.messagesLoaded = true;

      final attaching = chat.attachExistingRuntimeViewer();
      await Future<void>.delayed(Duration.zero);
      chat.pendingApproval = const {'request_id': 'request-b'};
      gateway.resumeGate!.complete(gateway.snapshot);

      expect(await attaching, isTrue);
      expect(chat.pendingApproval?['request_id'], 'request-b');
    },
  );

  test('malformed snapshot cannot clear a newer live approval', () async {
    var reads = 0;
    final gateway = _ViewerGateway(
      DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-live',
          'session_key': 'stored-live',
          'messages': <Object>[],
          'running': true,
          'pending_approval': {
            'tool': 'shell',
            'description': 'must not become authority without request id',
          },
        },
        requestedStoredSessionId: 'stored-live',
        created: false,
        method: 'session.resume',
      ),
    );
    final chat = _chat(gateway, restCalls: () => reads++);
    addTearDown(() async {
      chat.dispose();
      await gateway.close();
    });
    chat.pendingApproval = const {'request_id': 'new-live-request'};
    chat.messagesLoaded = true;

    expect(await chat.attachExistingRuntimeViewer(), isTrue);
    expect(chat.pendingApproval?['request_id'], 'new-live-request');
  });

  test(
    'viewer cancellation after connect prevents resume and adoption',
    () async {
      var reads = 0;
      final gateway = _ViewerGateway(
        DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-live',
            'session_key': 'stored-live',
            'messages': <Object>[],
            'running': true,
          },
          requestedStoredSessionId: 'stored-live',
          created: false,
          method: 'session.resume',
        ),
      );
      var visible = true;
      gateway.connectGate = Completer<void>();
      final chat = _chat(gateway, restCalls: () => reads++);
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });

      final attach = chat.attachExistingRuntimeViewer(
        stillOwningVisible: () => visible,
      );
      while (gateway.connectCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      visible = false;
      gateway.connectGate!.complete();

      expect(await attach, isFalse);
      expect(gateway.resumeCalls, 0);
      expect(gateway.activateCalls, 0);
      expect(chat.desktopRuntimeSessionId, isNull);
    },
  );

  test(
    'covered cold load stops after connect without resume or snapshot',
    () async {
      var reads = 0;
      final gateway = _ViewerGateway(
        DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-live',
            'session_key': 'stored-live',
            'messages': <Object>[],
            'running': true,
          },
          requestedStoredSessionId: 'stored-live',
          created: false,
          method: 'session.resume',
        ),
      )..connectGate = Completer<void>();
      var visible = true;
      final chat = _chat(gateway, restCalls: () => reads++);
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });

      final loading = chat.loadMessages(stillOwningVisible: () => visible);
      while (gateway.connectCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      visible = false;
      gateway.connectGate!.complete();
      await loading;

      expect(gateway.resumeCalls, 0);
      expect(gateway.activateCalls, 0);
      expect(chat.desktopRuntimeSessionId, isNull);
    },
  );

  test(
    'viewer revoked during privacy checkpoint never adopts resumed runtime',
    () async {
      var reads = 0;
      var visible = true;
      final checkpointEntered = Completer<void>();
      final checkpointGate = Completer<void>();
      final gateway = _ViewerGateway(
        DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-private-checkpoint',
            'session_key': 'stored-live',
            'messages': [
              {
                'row_id': 7,
                'role': 'assistant',
                'content': 'private checkpoint evidence',
                'hidden': true,
              },
            ],
            'running': true,
          },
          requestedStoredSessionId: 'stored-live',
          created: false,
          method: 'session.resume',
        ),
      );
      final chat = _chat(
        gateway,
        restCalls: () => reads++,
        beforePrivacyCheckpointSave: () async {
          if (!checkpointEntered.isCompleted) checkpointEntered.complete();
          await checkpointGate.future;
        },
      );
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });

      final attaching = chat.attachExistingRuntimeViewer(
        stillOwningVisible: () => visible,
      );
      await checkpointEntered.future;
      visible = false;
      checkpointGate.complete();

      expect(await attaching, isFalse);
      expect(chat.desktopRuntimeSessionId, isNull);
      expect(chat.messages, isEmpty);
    },
  );

  test(
    'cold load revoked during privacy snapshot publishes and adopts nothing',
    () async {
      var reads = 0;
      var visible = true;
      final privacyEntered = Completer<void>();
      final privacyGate = Completer<void>();
      final events = <ActiveChatEvent>[];
      final gateway = _ViewerGateway(
        DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-privacy-race',
            'session_key': 'stored-live',
            'messages': [
              {'role': 'assistant', 'content': 'must not publish'},
            ],
            'running': true,
          },
          requestedStoredSessionId: 'stored-live',
          created: false,
          method: 'session.resume',
        ),
      );
      final chat = _chat(
        gateway,
        restCalls: () => reads++,
        beforePrivacySnapshotLoad: () async {
          if (!privacyEntered.isCompleted) privacyEntered.complete();
          await privacyGate.future;
        },
      );
      final subscription = chat.changes.listen(events.add);
      addTearDown(() async {
        await subscription.cancel();
        chat.dispose();
        await gateway.close();
      });

      final loading = chat.loadMessages(stillOwningVisible: () => visible);
      await privacyEntered.future;
      visible = false;
      privacyGate.complete();
      await loading;

      expect(chat.desktopRuntimeSessionId, isNull);
      expect(chat.messages, isEmpty);
      expect(events, isNot(contains(ActiveChatEvent.messagesHydrated)));
    },
  );

  test(
    'cold load revoked while history hydration waits never fetches or publishes',
    () async {
      var reads = 0;
      var visible = true;
      var storedReads = 0;
      final hydrationEntered = Completer<void>();
      final hydrationGate = Completer<bool>();
      final events = <ActiveChatEvent>[];
      final gateway = _ViewerGateway(
        DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-hydration-race',
            'session_key': 'stored-live',
            'message_count': 1,
            'messages': <Object>[],
            'hydrating': true,
            'running': false,
          },
          requestedStoredSessionId: 'stored-live',
          created: false,
          method: 'session.resume',
        ),
      );
      final chat = _chat(
        gateway,
        restCalls: () => reads++,
        storedMessageLoader: (_, _) async {
          storedReads += 1;
          return const <Map<String, dynamic>>[];
        },
        historyHydrationAwaiter: () {
          if (!hydrationEntered.isCompleted) hydrationEntered.complete();
          return hydrationGate.future;
        },
      );
      final subscription = chat.changes.listen(events.add);
      addTearDown(() async {
        await subscription.cancel();
        chat.dispose();
        await gateway.close();
      });

      final loading = chat.loadMessages(
        expectedMessageCount: 1,
        stillOwningVisible: () => visible,
      );
      await hydrationEntered.future;
      events.clear();
      visible = false;
      hydrationGate.complete(true);
      await loading;

      expect(storedReads, 1);
      expect(chat.messages, isEmpty);
      expect(events, isNot(contains(ActiveChatEvent.messagesHydrated)));
    },
  );

  test(
    'cold load revoked during deferred REST never publishes hydrated rows',
    () async {
      var reads = 0;
      var visible = true;
      var storedReads = 0;
      final deferredEntered = Completer<void>();
      final deferredRest = Completer<List<Map<String, dynamic>>>();
      final events = <ActiveChatEvent>[];
      final gateway = _ViewerGateway(
        DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-rest-race',
            'session_key': 'stored-live',
            'message_count': 1,
            'messages': <Object>[],
            'hydrating': true,
            'running': false,
          },
          requestedStoredSessionId: 'stored-live',
          created: false,
          method: 'session.resume',
        ),
      );
      final chat = _chat(
        gateway,
        restCalls: () => reads++,
        historyHydrationAwaiter: () async => true,
        storedMessageLoader: (_, _) {
          storedReads += 1;
          if (storedReads == 1) return Future.value(const []);
          if (!deferredEntered.isCompleted) deferredEntered.complete();
          return deferredRest.future;
        },
      );
      final subscription = chat.changes.listen(events.add);
      addTearDown(() async {
        await subscription.cancel();
        chat.dispose();
        await gateway.close();
      });

      final loading = chat.loadMessages(
        expectedMessageCount: 1,
        stillOwningVisible: () => visible,
      );
      await deferredEntered.future;
      events.clear();
      visible = false;
      deferredRest.complete(const [
        {'role': 'assistant', 'content': 'late deferred row'},
      ]);
      await loading;

      expect(storedReads, 2);
      expect(chat.messages, isEmpty);
      expect(events, isNot(contains(ActiveChatEvent.messagesHydrated)));
    },
  );

  test(
    'cold load A snapshot and late REST cannot replace live approval B',
    () async {
      var reads = 0;
      final restGate = Completer<http.Response>();
      final initial = DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-live',
          'session_key': 'stored-live',
          'messages': <Object>[],
          'running': true,
        },
        requestedStoredSessionId: 'stored-live',
        created: false,
        method: 'session.resume',
      );
      final gateway = _ViewerGateway(initial);
      final chat = _chat(
        gateway,
        restCalls: () => reads++,
        restResponse: () => restGate.future,
      );
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });
      chat.messagesLoaded = true;
      expect(await chat.attachExistingRuntimeViewer(), isTrue);

      chat.pendingApproval = const {'request_id': 'request-a'};
      gateway.snapshot = DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-live',
          'session_key': 'stored-live',
          'messages': <Object>[],
          'running': true,
          'pending_approval': null,
        },
        requestedStoredSessionId: 'stored-live',
        created: false,
        method: 'session.resume',
      );
      gateway.resumeGate = Completer<DesktopSessionSnapshot>();
      final loading = chat.loadMessages(profile: '');
      await Future<void>.delayed(Duration.zero);
      gateway.emit('approval.request', const {
        'request_id': 'request-b',
        'command': 'pwd',
      });
      await Future<void>.delayed(Duration.zero);
      gateway.resumeGate!.complete(gateway.snapshot);
      await Future<void>.delayed(Duration.zero);
      restGate.complete(http.Response('{"messages":[]}', 200));
      await loading;

      expect(reads, 1);
      expect(chat.pendingApproval?['request_id'], 'request-b');
    },
  );

  test('absent snapshot never clears a newer live approval', () async {
    var reads = 0;
    final gateway = _ViewerGateway(
      DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-live',
          'session_key': 'stored-live',
          'messages': <Object>[],
          'running': true,
        },
        requestedStoredSessionId: 'stored-live',
        created: false,
        method: 'session.resume',
      ),
    );
    final chat = _chat(gateway, restCalls: () => reads++);
    addTearDown(() async {
      chat.dispose();
      await gateway.close();
    });
    chat.pendingApproval = const {'request_id': 'new-live-request'};
    chat.messagesLoaded = true;

    expect(await chat.attachExistingRuntimeViewer(), isTrue);
    expect(chat.pendingApproval?['request_id'], 'new-live-request');
  });

  test('resolved zero retira la tarjeta muerta y restaura la aprobación del '
      'snapshot', () async {
    for (final replacement in const <Map<String, dynamic>?>[
      null,
      {
        'request_id': 'request-live',
        'choices': ['once', 'deny'],
      },
    ]) {
      var reads = 0;
      final gateway = _ViewerGateway(
        DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-live',
            'session_key': 'stored-live',
            'messages': <Object>[],
            'running': true,
            'pending_approval': {
              'request_id': 'request-stale',
              'choices': ['once', 'deny'],
            },
          },
          requestedStoredSessionId: 'stored-live',
          created: false,
          method: 'session.resume',
        ),
      )..approvalResult = const DesktopApprovalResult(resolved: 0);
      final chat = _chat(gateway, restCalls: () => reads++);
      chat.messagesLoaded = true;
      expect(await chat.attachExistingRuntimeViewer(), isTrue);
      expect(chat.pendingApproval?['request_id'], 'request-stale');
      final resumesBefore = gateway.resumeCalls;
      // Hermes omite `pending_approval` cuando no hay ninguna (nunca null).
      gateway.snapshot = DesktopSessionSnapshot.fromJson(
        {
          'session_id': 'runtime-live',
          'session_key': 'stored-live',
          'messages': const <Object>[],
          'running': true,
          'pending_approval': ?replacement,
        },
        requestedStoredSessionId: 'stored-live',
        created: false,
        method: 'session.resume',
      );

      await chat.resolveApproval('once');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(gateway.approvalCalls.single.requestId, 'request-stale');
      // Relectura de recuperación: no ancla runtime legacy ni reanuda por la
      // ruta de mutación normal.
      expect(gateway.recoveryResumeCalls, 1);
      expect(gateway.resumeCalls, resumesBefore);
      expect(chat.pendingApproval?['request_id'], replacement?['request_id']);
      chat.dispose();
      await gateway.close();
    }
  });

  Future<(ActiveChat, _ViewerGateway)> attachWithStaleApproval({
    required bool running,
  }) async {
    var reads = 0;
    final snapshot = DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-live',
        'session_key': 'stored-live',
        'messages': const <Object>[],
        'running': running,
        'pending_approval': const {
          'request_id': 'request-stale',
          'choices': ['once', 'deny'],
        },
      },
      requestedStoredSessionId: 'stored-live',
      created: false,
      method: 'session.resume',
    );
    final gateway = _ViewerGateway(snapshot)
      ..approvalResult = const DesktopApprovalResult(resolved: 0);
    final chat = _chat(gateway, restCalls: () => reads++);
    addTearDown(() async {
      chat.dispose();
      await gateway.close();
    });
    chat.messagesLoaded = true;
    expect(await chat.attachExistingRuntimeViewer(), isTrue);
    expect(chat.pendingApproval?['request_id'], 'request-stale');
    return (chat, gateway);
  }

  test('resolved zero relee el snapshot una sola vez por request_id (sin bucle '
      'respond → 0 → resume)', () async {
    final (chat, gateway) = await attachWithStaleApproval(running: true);

    // El snapshot sigue anunciando la misma petición caducada.
    await chat.resolveApproval('once');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(gateway.recoveryResumeCalls, 1);
    expect(chat.pendingApproval, isNull);

    // La misma petición vuelve a llegar (p. ej. otro resume la reanuncia).
    gateway.emit('approval.request', const {
      'request_id': 'request-stale',
      'choices': ['once', 'deny'],
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(chat.pendingApproval?['request_id'], 'request-stale');
    await chat.resolveApproval('once');
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(gateway.approvalCalls, hasLength(2));
    expect(gateway.recoveryResumeCalls, 1);
    expect(chat.pendingApproval, isNull);
  });

  test('resolved zero sin turno vivo no reanuda la sesión', () async {
    // Un `session.resume` sobre una sesión que ya no está viva crea un
    // runtime nuevo en Hermes (`_resume_cold`): sin turno no se relee.
    final (chat, gateway) = await attachWithStaleApproval(running: false);
    chat.state = ChatPipelineState.completed;

    await chat.resolveApproval('once');
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(gateway.approvalCalls.single.requestId, 'request-stale');
    expect(gateway.recoveryResumeCalls, 0);
    expect(chat.pendingApproval, isNull);
  });

  test('resolved zero ignora un snapshot releído sin turno vivo', () async {
    final (chat, gateway) = await attachWithStaleApproval(running: true);
    gateway.snapshot = DesktopSessionSnapshot.fromJson(
      const {
        'session_id': 'runtime-live',
        'session_key': 'stored-live',
        'messages': <Object>[],
        'running': false,
        'pending_approval': {
          'request_id': 'request-other',
          'choices': ['once', 'deny'],
        },
      },
      requestedStoredSessionId: 'stored-live',
      created: false,
      method: 'session.resume',
    );

    await chat.resolveApproval('once');
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(gateway.recoveryResumeCalls, 1);
    expect(chat.pendingApproval, isNull);
  });
}
