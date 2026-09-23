import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

DesktopSessionSnapshot snap(
  List<Map<String, dynamic>> messages, {
  int? count,
  bool omitted = false,
}) => DesktopSessionSnapshot.fromJson(
  {
    'session_id': 'runtime-peer',
    'session_key': 'stored-peer',
    'message_count': count ?? messages.length,
    'messages': messages,
    if (omitted) 'messages_omitted': true,
  },
  requestedStoredSessionId: 'stored-peer',
  created: false,
  method: 'session.resume',
);

class PeerGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopTypedRecoveryGateway {
  PeerGateway(this.snapshot);
  DesktopSessionSnapshot? snapshot;
  Completer<void>? resumeHold;
  final ReplayCoordinator _recovery = ReplayCoordinator();
  final Object _recoveryChannel = Object();
  final bus = StreamController<TuiGatewayEvent>.broadcast();
  @override
  Stream<TuiGatewayEvent> get events => bus.stream;
  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    await resumeHold?.future;
    if (snapshot == null) throw StateError('snapshot unavailable');
    return snapshot!;
  }

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) => resumeExisting(storedSessionId, profile: profile);

  @override
  void commitRecoveryRuntime(String runtimeSessionId) {}

  @override
  RecoveryProof recoveryProofForSnapshot(
    DesktopSessionSnapshot snapshot, {
    required String connectionId,
    required String profile,
    required int bindGeneration,
    required int sessionGeneration,
    required int turnGeneration,
    required Set<RecoveryDomain> coverage,
    int? postSnapshotSequence,
  }) {
    _recovery.quarantine(snapshot.runtimeSessionId);
    return _recovery.mintRecoveryProof(
      connectionId: connectionId,
      durableSessionId: snapshot.storedSessionId,
      runtimeSessionId: snapshot.runtimeSessionId,
      profile: profile,
      socketGeneration: 1,
      channel: _recoveryChannel,
      bindGeneration: bindGeneration,
      sessionGeneration: sessionGeneration,
      turnGeneration: turnGeneration,
      replayEpoch: null,
      created: snapshot.created,
      durableIdentityExplicit: snapshot.storedSessionIdentityExplicit,
      identityAliasesConsistent: snapshot.identityAliasesConsistent,
      coverage: RecoveryDomain.values.toSet(),
      postSnapshotSequence: 1,
    );
  }

  @override
  bool validateRecovery(RecoveryProof proof) => _recovery.canCommitRecovery(
    proof,
    socketGeneration: 1,
    channel: _recoveryChannel,
    replayEpoch: null,
  );

  @override
  bool commitRecovery(RecoveryProof proof) => _recovery.commitRecovery(
    proof,
    socketGeneration: 1,
    channel: _recoveryChannel,
    replayEpoch: null,
  );

  @override
  bool recoveryAuthorityStillCurrent(RecoveryProof proof) =>
      _recovery.isRecoveryAuthorityCurrent(
        proof,
        socketGeneration: 1,
        channel: _recoveryChannel,
        replayEpoch: null,
      );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => snapshot!;
  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-peer',
    storedSessionId: storedSessionId,
    created: false,
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
  @override
  Future<void> close() async {
    if (!bus.isClosed) await bus.close();
  }

  void emit(String type, Map<String, dynamic> payload) => bus.add(
    TuiGatewayEvent(type: type, sessionId: 'runtime-peer', payload: payload),
  );
}

const publicUser = <String, dynamic>{
  'id': 1,
  'role': 'user',
  'content': 'PUBLIC_USER',
};
const privateRest = <String, dynamic>{
  'id': 2,
  'role': 'assistant',
  'content': 'PRIVATE_REVOKED',
};
const privateSnapshot = <String, dynamic>{
  'row_id': 2,
  'role': 'assistant',
  'content': 'PRIVATE_REVOKED',
  'hidden': true,
};
const publicSnapshot = <String, dynamic>{
  'row_id': 1,
  'role': 'user',
  'content': 'PUBLIC_USER',
};

ActiveChat chatFor(
  PeerGateway gateway, {
  Future<http.Response> Function(http.Request)? rest,
  Duration reconcileBudget = Duration.zero,
}) {
  final chat = ActiveChat(
    connection: SavedConnection(
      id: 'peer',
      label: 'Peer',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test',
      useHttps: true,
    ),
    sessionId: 'stored-peer',
    sessionTitle: 'Peer',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test',
      httpClient: MockClient(
        rest ?? (_) async => http.Response('not found', 404),
      ),
    ),
    desktopGateway: gateway,
    compressionRestoreStore: testCompressionRestoreStore(),
    terminalReconcileBudget: reconcileBudget,
    allowUnownedDesktopSnapshotForTesting: true,
  );
  addTearDown(chat.dispose);
  return chat;
}

http.Response restRows(List<Map<String, dynamic>> rows) => http.Response(
  jsonEncode({'data': rows}),
  200,
  headers: {'content-type': 'application/json'},
);

void assertPrivateAbsent(ActiveChat chat) =>
    expect(jsonEncode(chat.messages), isNot(contains('PRIVATE_REVOKED')));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure.clear();
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
                return null;
              case 'delete':
                secure.remove(args['key']);
                return null;
              case 'readAll':
                return Map<String, String>.from(secure);
              default:
                return null;
            }
          },
        );
  });

  test('PEER terminal settlement cannot resurrect prior revoked row', () async {
    const user3 = {'id': 3, 'role': 'user', 'content': 'PUBLIC_CURRENT_USER'};
    const assistant4 = {
      'id': 4,
      'role': 'assistant',
      'content': 'PUBLIC_FINAL',
    };
    final gateway = PeerGateway(
      DesktopSessionSnapshot.fromJson(
        {
          'session_id': 'runtime-peer',
          'session_key': 'stored-peer',
          'message_count': 3,
          'messages': [publicSnapshot, privateSnapshot, user3],
          'running': true,
          'inflight': {'assistant': '', 'streaming': true},
        },
        requestedStoredSessionId: 'stored-peer',
        created: false,
        method: 'session.resume',
      ),
    );
    var settled = false;
    var terminalReads = 0;
    final chat = chatFor(
      gateway,
      reconcileBudget: const Duration(seconds: 1),
      rest: (_) async {
        if (!settled) return http.Response('not found', 404);
        terminalReads++;
        return restRows([publicUser, privateRest, user3, assistant4]);
      },
    );
    await chat.loadMessages();
    assertPrivateAbsent(chat);
    settled = true;
    final done = chat.changes.firstWhere(
      (event) => event == ActiveChatEvent.done,
    );
    gateway.emit('message.complete', {'text': 'PUBLIC_FINAL'});
    await done.timeout(const Duration(seconds: 3));
    expect(terminalReads, 0);
    expect(jsonEncode(chat.messages), contains('PUBLIC_FINAL'));
    expect(jsonEncode(chat.messages), contains('PUBLIC_CURRENT_USER'));
    assertPrivateAbsent(chat);
  });

  test(
    'PEER recovery early return must apply unique snapshot veto first',
    () async {
      final gateway = PeerGateway(
        DesktopSessionSnapshot.fromJson(
          {
            'session_id': 'runtime-peer',
            'session_key': 'stored-peer',
            'message_count': 2,
            'messages': [publicSnapshot, privateRest],
            'running': true,
            'inflight': {'assistant': '', 'streaming': true},
          },
          requestedStoredSessionId: 'stored-peer',
          created: false,
          method: 'session.resume',
        ),
      );
      var recovering = false;
      final chat = chatFor(
        gateway,
        rest: (_) async {
          if (!recovering) return http.Response('not found', 404);
          return http.Response('not found', 404);
        },
      );
      await chat.loadMessages();
      expect(chat.isStreaming, isTrue);
      gateway.snapshot = snap([privateSnapshot], count: 5);
      recovering = true;
      gateway.bus.addError(StateError('peer socket lost'));
      for (var attempt = 0; attempt < 300; attempt++) {
        if (!jsonEncode(chat.messages).contains('PRIVATE_REVOKED')) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final observed = jsonEncode(chat.messages);
      chat.dispose();
      expect(observed, contains('PUBLIC_USER'));
      expect(observed, isNot(contains('PRIVATE_REVOKED')));
    },
  );

  test('PEER mixed channel streaming settles only public output', () async {
    final gateway = PeerGateway(
      DesktopSessionSnapshot.fromJson(
        {
          'session_id': 'runtime-peer',
          'session_key': 'stored-peer',
          'message_count': 1,
          'messages': [publicSnapshot],
          'running': true,
          'inflight': {'assistant': '', 'streaming': true},
        },
        requestedStoredSessionId: 'stored-peer',
        created: false,
        method: 'session.resume',
      ),
    );
    final chat = chatFor(gateway);
    await chat.loadMessages();
    const raw =
        '<|channel｜>analysis<｜message|>PRIVATE_REVOKED<|end｜>'
        '<｜channel|>final<|message｜>PUBLIC_FINAL<｜end|>';
    for (final unit in raw.codeUnits) {
      gateway.emit('message.delta', {'text': String.fromCharCode(unit)});
    }
    final flushed = chat.changes.firstWhere(
      (event) => event == ActiveChatEvent.toolProgress,
    );
    gateway.emit('tool.start', {'name': 'peer'});
    await flushed.timeout(const Duration(seconds: 2));
    assertPrivateAbsent(chat);
    expect(jsonEncode(chat.messages), contains('PUBLIC_FINAL'));
    final done = chat.changes.firstWhere(
      (event) => event == ActiveChatEvent.done,
    );
    gateway.emit('message.complete', {'text': raw});
    await done.timeout(const Duration(seconds: 2));
    assertPrivateAbsent(chat);
    expect(jsonEncode(chat.messages), contains('PUBLIC_FINAL'));
  });

  test(
    'PEER final invalid literal is restored after live withholding',
    () async {
      final gateway = PeerGateway(
        DesktopSessionSnapshot.fromJson(
          {
            'session_id': 'runtime-peer',
            'session_key': 'stored-peer',
            'message_count': 1,
            'messages': [publicSnapshot],
            'running': true,
            'inflight': {'assistant': '', 'streaming': true},
          },
          requestedStoredSessionId: 'stored-peer',
          created: false,
          method: 'session.resume',
        ),
      );
      final chat = chatFor(gateway);
      await chat.loadMessages();
      const raw = 'PUBLIC <｜start｜>not an envelope';
      gateway.emit('message.delta', {'text': raw});
      final flushed = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.toolProgress,
      );
      gateway.emit('tool.start', {'name': 'peer'});
      await flushed.timeout(const Duration(seconds: 2));
      expect(jsonEncode(chat.messages), isNot(contains('not an envelope')));
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit('message.complete', {'text': raw});
      await done.timeout(const Duration(seconds: 2));
      expect(
        chat.messages.where((m) => m['role'] == 'assistant').first['content'],
        raw,
      );
    },
  );

  test('PEER correct REST data shape obeys exact private veto', () async {
    final gateway = PeerGateway(snap([publicSnapshot, privateSnapshot]));
    final chat = chatFor(
      gateway,
      rest: (_) async => restRows([publicUser, privateRest]),
    );
    await chat.loadMessages();
    assertPrivateAbsent(chat);
    expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
  });

  test(
    'PEER duplicate REST plus complete snapshot must not defeat veto',
    () async {
      final gateway = PeerGateway(snap([publicSnapshot, privateSnapshot]));
      final chat = chatFor(
        gateway,
        rest: (_) async => restRows([
          publicUser,
          privateRest,
          Map<String, dynamic>.from(privateRest),
        ]),
      );
      await chat.loadMessages();
      expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
      assertPrivateAbsent(chat);
    },
  );

  test(
    'PEER duplicate fallback plus partial snapshot cannot defeat veto',
    () async {
      final chat = chatFor(PeerGateway(snap([privateSnapshot], count: 5)));
      chat.replaceInternalMessagesForTesting([
        Map<String, dynamic>.from(privateRest),
        Map<String, dynamic>.from(privateRest),
        publicUser,
      ]);
      await chat.loadMessages();
      expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
      assertPrivateAbsent(chat);
    },
  );

  test('PEER control exact unique veto keeps public neighbor', () async {
    final chat = chatFor(PeerGateway(snap([publicSnapshot, privateSnapshot])));
    chat.replaceInternalMessagesForTesting([privateRest, publicUser]);
    await chat.loadMessages();
    assertPrivateAbsent(chat);
    expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
  });

  test(
    'PEER partial snapshot all cached rows revoked must publish empty',
    () async {
      final chat = chatFor(PeerGateway(snap([privateSnapshot], count: 2)));
      chat.replaceInternalMessagesForTesting([privateRest]);
      await chat.loadMessages();
      assertPrivateAbsent(chat);
    },
  );

  test(
    'PEER exact duplicate fallback rows cannot disable private veto',
    () async {
      final chat = chatFor(
        PeerGateway(snap([publicSnapshot, privateSnapshot])),
      );
      chat.replaceInternalMessagesForTesting([
        Map<String, dynamic>.from(privateRest),
        Map<String, dynamic>.from(privateRest),
        publicUser,
      ]);
      await chat.loadMessages();
      expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
      assertPrivateAbsent(chat);
    },
  );

  test('PEER exact duplicate private snapshot cannot disable veto', () async {
    final chat = chatFor(
      PeerGateway(
        snap([
          publicSnapshot,
          privateSnapshot,
          Map<String, dynamic>.from(privateSnapshot),
        ]),
      ),
    );
    chat.replaceInternalMessagesForTesting([privateRest, publicUser]);
    await chat.loadMessages();
    expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
    assertPrivateAbsent(chat);
  });

  test(
    'PEER unique veto survives later REST with unavailable snapshot',
    () async {
      final gateway = PeerGateway(snap([publicSnapshot, privateSnapshot]));
      var phase = 0;
      final chat = chatFor(
        gateway,
        rest: (_) async => phase == 0
            ? http.Response('not found', 404)
            : restRows([publicUser, privateRest]),
      );
      chat.replaceInternalMessagesForTesting([privateRest, publicUser]);
      await chat.loadMessages();
      assertPrivateAbsent(chat);
      phase = 1;
      gateway.snapshot = null;
      await chat.loadMessages();
      expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
      assertPrivateAbsent(chat);
    },
  );

  test(
    'PEER prior veto never flashes when fresh REST beats next snapshot',
    () async {
      final gateway = PeerGateway(snap([publicSnapshot, privateSnapshot]));
      var phase = 0;
      final chat = chatFor(
        gateway,
        rest: (_) async => phase == 0
            ? http.Response('not found', 404)
            : restRows([publicUser, privateRest]),
      );
      chat.replaceInternalMessagesForTesting([privateRest, publicUser]);
      await chat.loadMessages();
      assertPrivateAbsent(chat);
      phase = 1;
      gateway.resumeHold = Completer<void>();
      final published = Completer<String>();
      final load = chat.loadMessages(
        onMessagesPublished: () {
          if (!published.isCompleted) {
            published.complete(jsonEncode(chat.messages));
          }
        },
      );
      final first = await published.future.timeout(const Duration(seconds: 2));
      gateway.resumeHold!.complete();
      await load;
      assertPrivateAbsent(chat);
      expect(first, isNot(contains('PRIVATE_REVOKED')));
    },
  );

  test('PEER idless public and opaque numeric string remain distinct', () {
    const reconciler = DesktopSessionReconciler();
    final merged = reconciler.overlayDurableDisplayMetadata(
      [
        {'id': '2', 'role': 'assistant', 'content': 'PUBLIC_OPAQUE'},
        {'role': 'assistant', 'content': 'PUBLIC_IDLESS'},
        privateRest,
        publicUser,
      ],
      [DesktopSessionMessage.tryParse(privateSnapshot)!],
    );
    expect(merged.map((m) => m['content']).toList(), [
      'PUBLIC_OPAQUE',
      'PUBLIC_IDLESS',
      'PUBLIC_USER',
    ]);
  });

  test(
    'PEER unique veto persists clean output and rehydrates safely',
    () async {
      final chat = chatFor(
        PeerGateway(snap([publicSnapshot, privateSnapshot])),
      );
      chat.replaceInternalMessagesForTesting([privateRest, publicUser]);
      await chat.loadMessages();
      await LocalTranscriptStore.saveFromNewestFirst(
        'peer',
        'stored-peer',
        chat.messages,
      );
      final loaded = await LocalTranscriptStore.load('peer', 'stored-peer');
      expect(jsonEncode(loaded), isNot(contains('PRIVATE_REVOKED')));
      expect(jsonEncode(loaded), contains('PUBLIC_USER'));
      expect(secure.values.join(), isNot(contains('PRIVATE_REVOKED')));
    },
  );

  test(
    'PEER local final literal plus private envelope survives save load',
    () async {
      const literal = 'PUBLIC <｜start｜>not an envelope';
      await LocalTranscriptStore.saveFromNewestFirst('peer', 'stored-peer', [
        {'role': 'assistant', 'content': literal},
        {
          'role': 'assistant',
          'content': '<|channel｜>analysis<|message｜>PRIVATE_REVOKED<|end｜>',
        },
        publicUser,
      ]);
      final loaded = await LocalTranscriptStore.load('peer', 'stored-peer');
      expect(loaded.map((m) => m['content']).toList(), [
        'PUBLIC_USER',
        literal,
      ]);
      expect(secure.values.join(), isNot(contains('PRIVATE_REVOKED')));
    },
  );

  test('PEER duplicate veto bypass reaches durable local cache', () async {
    final chat = chatFor(
      PeerGateway(
        snap([
          publicSnapshot,
          privateSnapshot,
          Map<String, dynamic>.from(privateSnapshot),
        ]),
      ),
    );
    chat.replaceInternalMessagesForTesting([privateRest, publicUser]);
    await chat.loadMessages();
    await LocalTranscriptStore.saveFromNewestFirst(
      'peer',
      'stored-peer',
      chat.messages,
    );
    final loaded = await LocalTranscriptStore.load('peer', 'stored-peer');
    expect(jsonEncode(loaded), contains('PUBLIC_USER'));
    expect(jsonEncode(loaded), isNot(contains('PRIVATE_REVOKED')));
  });
}
