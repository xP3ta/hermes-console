import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryFenceStorage implements CompressionRestoreStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

/// Lifecycle gateway whose resume acknowledges a deferred (hydrating) history,
/// exactly like Hermes Agent 0.20 for a cold per-profile bot session.
class _HydratingGateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  int resumeCalls = 0;
  String? lastProfile;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

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
    resumeCalls += 1;
    lastProfile = profile;
    return DesktopSessionSnapshot.fromJson(
      const {
        'session_id': 'runtime-bot',
        'session_key': 'stored-bot',
        'message_count': 2,
        'hydrating': true,
        'messages': <Object>[],
      },
      requestedStoredSessionId: storedSessionId,
      created: false,
      method: 'session.resume',
    );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw StateError('must not create while loading');

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw StateError('legacy resume must not run while loading');

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
    if (!_events.isClosed) await _events.close();
  }
}

const _rows = [
  {'id': 1, 'role': 'user', 'content': 'hola bot'},
  {'id': 2, 'role': 'assistant', 'content': 'hola humano'},
];

Map<String, Object?> _page(http.Request request) {
  final limit = request.url.queryParameters['limit'];
  // A whole-transcript Dashboard read carries no paging parameters.
  if (limit == null) return {'session_id': 'stored-bot', 'messages': _rows};
  return _pagedBody(request);
}

Map<String, Object?> _pagedBody(http.Request request) => {
  'session_id': 'stored-bot',
  'messages': _rows,
  'pagination': {
    'limit': int.parse(request.url.queryParameters['limit']!),
    'offset': int.parse(request.url.queryParameters['offset']!),
    'order': 'latest',
    'returned': _rows.length,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final connection = SavedConnection(
    id: 'profile-fallback',
    label: 'profile-fallback',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'main-profile-key',
    kind: InstanceKind.vps,
  );

  ({
    ActiveChat chat,
    _HydratingGateway gateway,
    List<Uri> gatewayReads,
    List<Uri> dashboardReads,
    List<Uri> gateway401s,
    List<int> hydrationWaits,
  })
  build({
    required int gatewayStatus,
    int Function()? gatewayStatusNow,
    int dashboardStatus = 200,
    Future<http.Response> Function(http.Request request)? dashboardHandler,
    Future<void> Function()? gatewayGate,
  }) {
    final gateway401s = <Uri>[];
    final hydrationWaits = <int>[];
    final gatewayReads = <Uri>[];
    final dashboardReads = <Uri>[];
    final gateway = _HydratingGateway();
    final chat = ActiveChat(
      connection: connection,
      sessionId: 'stored-bot',
      sessionTitle: 'Bot',
      sessionProfile: 'research',
      notifications: null,
      onTerminal: () {},
      api: ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'main-profile-key',
        httpClient: MockClient((request) async {
          gatewayReads.add(request.url);
          final status = gatewayStatusNow?.call() ?? gatewayStatus;
          if (status == 401 && gatewayGate != null) await gatewayGate();
          if (status == 401) gateway401s.add(request.url);
          if (status != 200) return http.Response('{}', status);
          return http.Response(jsonEncode(_page(request)), 200);
        }),
      ),
      transcriptDashboard: DashboardClient(
        host: '127.0.0.1',
        manualToken: 'dashboard-token',
        httpClientOverride: MockClient((request) async {
          dashboardReads.add(request.url);
          if (dashboardHandler != null) return dashboardHandler(request);
          if (dashboardStatus != 200) {
            return http.Response('{}', dashboardStatus);
          }
          return http.Response(jsonEncode(_page(request)), 200);
        }),
      ),
      desktopGateway: gateway,
      compressionRestoreStore: CompressionRestoreStore(
        storage: _MemoryFenceStorage(),
      ),
      allowUnownedDesktopSnapshotForTesting: true,
      // The server-side hydration event never arrives in this harness: any
      // wait on it would hang the open instead of showing the Dashboard page.
      historyHydrationAwaiter: () {
        hydrationWaits.add(hydrationWaits.length);
        return Completer<bool>().future;
      },
    );
    return (
      chat: chat,
      gateway: gateway,
      gatewayReads: gatewayReads,
      dashboardReads: dashboardReads,
      gateway401s: gateway401s,
      hydrationWaits: hydrationWaits,
    );
  }

  test('an unauthorized profile gateway route falls back to the Dashboard '
      'immediately and is not retried', () async {
    final harness = build(gatewayStatus: 401);
    addTearDown(harness.chat.dispose);

    final stopwatch = Stopwatch()..start();
    await harness.chat
        .loadMessages(expectedMessageCount: 2, profile: 'research')
        .timeout(const Duration(seconds: 5));
    stopwatch.stop();

    expect(harness.chat.messages.map((m) => m['content']), [
      'hola humano',
      'hola bot',
    ]);
    expect(harness.hydrationWaits, isEmpty);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(harness.gatewayReads, hasLength(1));
    expect(harness.gatewayReads.single.path, contains('/p/research/'));
    expect(harness.dashboardReads, isNotEmpty);
    expect(
      harness.dashboardReads.first.path,
      '/api/sessions/stored-bot/messages',
    );
    expect(harness.dashboardReads.first.queryParameters['profile'], 'research');
    expect(harness.gateway.resumeCalls, 1);

    // A later refresh goes straight to the Dashboard: 401 is definitive.
    await harness.chat
        .loadMessages(
          expectedMessageCount: 2,
          profile: 'research',
          passiveOnly: true,
        )
        .timeout(const Duration(seconds: 5));
    expect(harness.gatewayReads, hasLength(1));
    expect(harness.chat.messages, hasLength(2));
  });

  test('a profile with its own gateway key keeps the gateway route', () async {
    final harness = build(gatewayStatus: 200);
    addTearDown(harness.chat.dispose);

    await harness.chat
        .loadMessages(expectedMessageCount: 2, profile: 'research')
        .timeout(const Duration(seconds: 5));

    expect(harness.chat.messages, hasLength(2));
    expect(harness.gatewayReads, isNotEmpty);
    expect(harness.dashboardReads, isEmpty);
    expect(harness.hydrationWaits, isEmpty);
  });

  PreparedTurn botTurn() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return PreparedTurn(
      connectionId: connection.id,
      sessionId: 'stored-bot',
      clientTurnId: 'bot-turn',
      createdAtMs: now,
      updatedAtMs: now,
      text: 'hola bot',
      attachments: const [],
      model: 'hermes-agent',
      profile: 'research',
      state: PreparedTurnState.ambiguous,
      retryBoundary: PreparedTurnRetryBoundary.identity(rowId: 1),
    );
  }

  void expectSingleGateway401(List<Uri> gateway401s) {
    expect(gateway401s, hasLength(1));
    expect(gateway401s.single.path, contains('/p/research/'));
  }

  void expectDashboardWholeRead(Uri read) {
    expect(read.path, '/api/sessions/stored-bot/messages');
    expect(read.queryParameters['profile'], 'research');
    expect(read.queryParameters.containsKey('limit'), isFalse);
  }

  /// The chat opened while the profile route still answered (or through a
  /// path that never read it over REST); the next whole-transcript read is
  /// the first one to meet the 401.
  Future<
    ({
      ActiveChat chat,
      List<Uri> gateway401s,
      List<Uri> dashboardReads,
      List<Uri> gatewayReads,
    })
  >
  openedThen401({
    int dashboardStatus = 200,
    Future<http.Response> Function(http.Request request)? dashboardHandler,
    Future<void> Function()? gatewayGate,
  }) async {
    var status = 200;
    final harness = build(
      gatewayStatus: 200,
      gatewayStatusNow: () => status,
      dashboardStatus: dashboardStatus,
      dashboardHandler: dashboardHandler,
      gatewayGate: gatewayGate,
    );
    addTearDown(harness.chat.dispose);
    await harness.chat
        .loadMessages(expectedMessageCount: 2, profile: 'research')
        .timeout(const Duration(seconds: 5));
    expect(harness.dashboardReads, isEmpty);
    status = 401;
    return (
      chat: harness.chat,
      gateway401s: harness.gateway401s,
      dashboardReads: harness.dashboardReads,
      gatewayReads: harness.gatewayReads,
    );
  }

  group('whole-transcript reads of a named profile', () {
    test('resume reconcile falls back to the Dashboard and latches', () async {
      final h = await openedThen401();
      // Not settled yet (e.g. painted from cache): resume reads it whole.
      h.chat.messagesLoaded = false;

      await h.chat.reconcileAfterResume().timeout(const Duration(seconds: 5));

      expectSingleGateway401(h.gateway401s);
      expect(h.dashboardReads, hasLength(1));
      expectDashboardWholeRead(h.dashboardReads.single);

      // Another resume and a regular refresh reuse the latch.
      h.chat.messagesLoaded = false;
      await h.chat.reconcileAfterResume().timeout(const Duration(seconds: 5));
      await h.chat
          .loadMessages(expectedMessageCount: 2, profile: 'research')
          .timeout(const Duration(seconds: 5));
      expectSingleGateway401(h.gateway401s);
      expect(h.dashboardReads.length, greaterThanOrEqualTo(3));
    });

    test('delivery settle reads the transcript from the Dashboard', () async {
      final h = await openedThen401();

      await h.chat
          .composerTurnDeliveredPerTranscript(botTurn())
          .timeout(const Duration(seconds: 5));

      expectSingleGateway401(h.gateway401s);
      expect(h.dashboardReads, hasLength(1));
      expectDashboardWholeRead(h.dashboardReads.single);
    });

    test('ambiguous-turn recovery reads from the Dashboard once the gateway '
        'said 401', () async {
      final h = await openedThen401();

      final first = await h.chat
          .resolveAmbiguousRetryFromTranscript(botTurn())
          .timeout(const Duration(seconds: 5));
      final second = await h.chat
          .resolveAmbiguousRetryFromTranscript(botTurn())
          .timeout(const Duration(seconds: 5));

      expect(first, isNot(AmbiguousRetryEvidence.unknown));
      expect(second, first);
      expectSingleGateway401(h.gateway401s);
      expect(h.dashboardReads, hasLength(2));
    });

    test('a late gateway 401 after the latch does not reopen the gateway '
        'route', () async {
      final releases = <Completer<void>>[];
      final h = await openedThen401(
        gatewayGate: () {
          final release = Completer<void>();
          releases.add(release);
          return release.future;
        },
      );

      // Two reads reach the gateway before either has an answer.
      final early = h.chat.resolveAmbiguousRetryFromTranscript(botTurn());
      final late = h.chat.resolveAmbiguousRetryFromTranscript(botTurn());
      await pumpEventQueue();
      expect(releases, hasLength(2));

      // The first 401 latches; the slow one lands afterwards.
      releases[0].complete();
      await early.timeout(const Duration(seconds: 5));
      releases[1].complete();
      await late.timeout(const Duration(seconds: 5));
      expect(h.gateway401s, hasLength(2));

      for (var i = 0; i < 3; i++) {
        await h.chat
            .resolveAmbiguousRetryFromTranscript(botTurn())
            .timeout(const Duration(seconds: 5));
        await h.chat
            .loadMessages(
              expectedMessageCount: 2,
              profile: 'research',
              passiveOnly: true,
            )
            .timeout(const Duration(seconds: 5));
      }
      expect(h.gateway401s, hasLength(2));
    });
  });

  group('subagent transcript page', () {
    test('a child transcript of a named profile falls back to the Dashboard '
        'and shares the latch', () async {
      final h = await openedThen401();

      final rows = await h.chat
          .loadChildTranscript('child-1')
          .timeout(const Duration(seconds: 5));
      expect(rows, hasLength(2));
      expectSingleGateway401(h.gateway401s);
      expect(h.gateway401s.single.path, contains('/sessions/child-1/'));
      expect(h.dashboardReads.single.path, '/api/sessions/child-1/messages');
      expect(h.dashboardReads.single.queryParameters['profile'], 'research');

      // Reopening the page and reading the parent go straight to the
      // Dashboard.
      await h.chat
          .loadChildTranscript('child-1')
          .timeout(const Duration(seconds: 5));
      await h.chat
          .resolveAmbiguousRetryFromTranscript(botTurn())
          .timeout(const Duration(seconds: 5));
      expectSingleGateway401(h.gateway401s);
      expect(h.dashboardReads, hasLength(3));
    });

    test('the page keeps using the caller read-only client', () async {
      final h = await openedThen401();
      final childReads = <Uri>[];
      final readOnly = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'main-...ey',
        httpClient: MockClient((request) async {
          childReads.add(request.url);
          return http.Response(jsonEncode(_page(request)), 200);
        }),
      );
      addTearDown(readOnly.close);

      final rows = await h.chat
          .loadChildTranscript('child-1', gateway: readOnly)
          .timeout(const Duration(seconds: 5));

      expect(rows, hasLength(2));
      expect(
        childReads.single.path,
        '/p/research/api/sessions/child-1/messages',
      );
      expect(h.gateway401s, isEmpty);
      expect(h.dashboardReads, isEmpty);
    });
  });

  group('the Dashboard cannot serve the profile either', () {
    test('whole reads stop after one attempt and report it once', () async {
      final h = await openedThen401(dashboardStatus: 403);
      final events = <ActiveChatEvent>[];
      final sub = h.chat.changes.listen(events.add);
      addTearDown(sub.cancel);

      expect(
        await h.chat
            .resolveAmbiguousRetryFromTranscript(botTurn())
            .timeout(const Duration(seconds: 5)),
        AmbiguousRetryEvidence.unknown,
      );
      expect(h.chat.profileTranscriptAccessBlocked, isTrue);

      // Resume, settle, subagent page and polling make no request at all.
      h.chat.messagesLoaded = false;
      await h.chat.reconcileAfterResume().timeout(const Duration(seconds: 5));
      await h.chat
          .composerTurnDeliveredPerTranscript(botTurn())
          .timeout(const Duration(seconds: 5));
      await expectLater(
        h.chat.loadChildTranscript('child-1'),
        throwsA(isA<ProfileTranscriptAccessRequired>()),
      );
      for (var i = 0; i < 3; i++) {
        await expectLater(
          h.chat.loadMessages(
            expectedMessageCount: 2,
            profile: 'research',
            passiveOnly: true,
          ),
          throwsA(isA<ProfileTranscriptAccessRequired>()),
        );
      }
      await pumpEventQueue();
      expectSingleGateway401(h.gateway401s);
      expect(h.dashboardReads, hasLength(1));
      expect(
        events.where((e) => e == ActiveChatEvent.dashboardAuthChanged),
        hasLength(1),
      );

      // An explicit retry tries the Dashboard once more, never the gateway.
      h.chat.retryProfileTranscriptAccess();
      expect(h.chat.profileTranscriptAccessBlocked, isFalse);
      await expectLater(
        h.chat.loadChildTranscript('child-1'),
        throwsA(isA<ProfileTranscriptAccessRequired>()),
      );
      expectSingleGateway401(h.gateway401s);
      expect(h.dashboardReads, hasLength(2));
      expect(h.chat.profileTranscriptAccessBlocked, isTrue);
    });

    test('an open whose paged read fails on both routes is blocked, not '
        'retried', () async {
      final harness = build(gatewayStatus: 401, dashboardStatus: 401);
      addTearDown(harness.chat.dispose);

      await expectLater(
        harness.chat
            .loadMessages(expectedMessageCount: 2, profile: 'research')
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<ProfileTranscriptAccessRequired>()),
      );
      final dashboardAfterOpen = harness.dashboardReads.length;
      expect(dashboardAfterOpen, greaterThanOrEqualTo(1));
      for (var i = 0; i < 3; i++) {
        await expectLater(
          harness.chat.loadMessages(
            expectedMessageCount: 2,
            profile: 'research',
            passiveOnly: true,
          ),
          throwsA(isA<ProfileTranscriptAccessRequired>()),
        );
      }
      expect(harness.gatewayReads, hasLength(1));
      expect(harness.dashboardReads, hasLength(dashboardAfterOpen));
      expect(harness.chat.profileTranscriptAccessBlocked, isTrue);
    });

    test('a missing session keeps its 404 meaning', () async {
      final h = await openedThen401(dashboardStatus: 404);

      await expectLater(
        h.chat.loadChildTranscript('child-1'),
        throwsA(isA<DashboardHttpException>()),
      );
      expect(h.chat.profileTranscriptAccessBlocked, isFalse);
    });
  });

  group('a Dashboard that fails without refusing access', () {
    // Only an authentication refusal means "this profile needs Dashboard
    // access". A dropped connection, a timeout or a server error is a
    // transient read failure: no latch, no access notice, the next read
    // asks again.
    Future<void> expectTransient(
      Future<http.Response> Function(http.Request request) handler,
    ) async {
      final h = await openedThen401(dashboardHandler: handler);
      final events = <ActiveChatEvent>[];
      final sub = h.chat.changes.listen(events.add);
      addTearDown(sub.cancel);

      await expectLater(
        h.chat.loadChildTranscript('child-1'),
        throwsA(isNot(isA<ProfileTranscriptAccessRequired>())),
      );
      expect(h.chat.profileTranscriptAccessBlocked, isFalse);
      await expectLater(
        h.chat.loadChildTranscript('child-1'),
        throwsA(isNot(isA<ProfileTranscriptAccessRequired>())),
      );
      await pumpEventQueue();
      expect(h.chat.profileTranscriptAccessBlocked, isFalse);
      expect(h.dashboardReads, hasLength(2));
      expect(
        events.where((e) => e == ActiveChatEvent.dashboardAuthChanged),
        isEmpty,
      );
      expectSingleGateway401(h.gateway401s);
    }

    test('a dropped connection', () async {
      await expectTransient(
        (_) async => throw http.ClientException('connection reset'),
      );
    });

    test('a server error', () async {
      await expectTransient((_) async => http.Response('{}', 503));
    });

    test('a rate limit', () async {
      await expectTransient((_) async => http.Response('{}', 429));
    });

    test('a sign-in that failed or was throttled on the server', () async {
      for (final code in [
        DashboardAuthFailureCode.loginFailed,
        DashboardAuthFailureCode.rateLimited,
      ]) {
        await expectTransient(
          (_) async => throw DashboardAuthException(code, statusCode: 502),
        );
      }
    });

    test('a refusal is still an access problem', () async {
      for (final status in [401, 403]) {
        final h = await openedThen401(dashboardStatus: status);
        await expectLater(
          h.chat.loadChildTranscript('child-1'),
          throwsA(isA<ProfileTranscriptAccessRequired>()),
        );
        expect(
          h.chat.profileTranscriptAccessBlocked,
          isTrue,
          reason: '$status',
        );
      }
    });

    test('a Dashboard sign-in refusal is an access problem', () async {
      for (final code in [
        DashboardAuthFailureCode.loginRequired,
        DashboardAuthFailureCode.invalidCredentials,
        DashboardAuthFailureCode.sessionCookieMissing,
      ]) {
        final h = await openedThen401(
          dashboardHandler: (_) async => throw DashboardAuthException(code),
        );
        await expectLater(
          h.chat.loadChildTranscript('child-1'),
          throwsA(isA<ProfileTranscriptAccessRequired>()),
        );
        expect(h.chat.profileTranscriptAccessBlocked, isTrue, reason: '$code');
      }
    });

    test(
      'the transient failure of a paged open is not reported as access',
      () async {
        final harness = build(
          gatewayStatus: 401,
          dashboardHandler: (_) async => http.Response('{}', 502),
        );
        addTearDown(harness.chat.dispose);

        Object? error;
        try {
          await harness.chat
              .loadMessages(expectedMessageCount: 2, profile: 'research')
              .timeout(const Duration(seconds: 5));
        } catch (e) {
          error = e;
        }
        expect(error, isNot(isA<ProfileTranscriptAccessRequired>()));
        expect(harness.chat.profileTranscriptAccessBlocked, isFalse);
      },
    );
  });
}
