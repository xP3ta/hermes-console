import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
// Transitive via flutter_test; no dependency or lockfile change.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/desktop_chat_socket.dart';
import 'support/in_memory_compression_restore_storage.dart';
import 'support/qrc_fake_gateway_socket.dart';
import 'support/test_api_client.dart';

final _connection = SavedConnection(
  id: 'bg-reconcile',
  label: 'Resume',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'unused',
  kind: InstanceKind.vps,
);

class _ResumeGateway extends DesktopChatSocket
    implements HermesDesktopLifecycleGateway {
  bool connected = true;
  int connects = 0;
  int resumes = 0;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async {
    connects++;
    connected = true;
  }

  @override
  Future<void> disconnectIdle() async {
    connected = false;
  }

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumes++;
    return DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-live',
      storedSessionId: storedSessionId,
      created: false,
      messagesProvided: false,
    );
  }
}

class _PagedTranscript extends ApiClient {
  _PagedTranscript()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'unused',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
        profileDashboard: testDashboardClient(
          httpClient: MockClient((_) async => http.Response('{}', 404)),
        ),
      );

  List<Map<String, dynamic>> rows = [
    for (var i = 0; i < 7730; i++)
      {
        'message_id': 'row-$i',
        'role': i.isEven ? 'user' : 'assistant',
        'content': 'history $i',
      },
  ];
  final pages = <({int limit, int offset})>[];
  int fullReads = 0;
  bool malformedPagination = false;
  bool malformedRows = false;
  bool missingCountWitness = false;

  @override
  Future<SessionMessagesPage> getMessagesPage(
    String sessionId, {
    String? profile,
    int limit = 120,
    int offset = 0,
  }) async {
    pages.add((limit: limit, offset: offset));
    final end = (rows.length - offset).clamp(0, rows.length);
    final start = (end - limit).clamp(0, end);
    final page = missingCountWitness && offset > 0
        ? <Map<String, dynamic>>[]
        : rows.sublist(start, end);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    return SessionMessagesPage(
      messages: page,
      resolvedTipId: sessionId,
      messagesFullyParsed: !malformedRows,
      pagination: malformedPagination
          ? {}
          : {'limit': limit, 'offset': offset, 'returned': page.length},
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getMessages(
    String sessionId, {
    String? profile,
    int? maxJsonChars,
  }) async {
    fullReads++;
    await Future<void>.delayed(const Duration(seconds: 6));
    return rows;
  }
}

ActiveChat _chat(
  HermesDesktopGateway gateway,
  _PagedTranscript api, {
  bool attach = false,
}) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: _connection,
  sessionId: 'session-bg',
  sessionTitle: 'Resume',
  notifications: null,
  onTerminal: () {},
  api: api,
  desktopGateway: gateway,
  allowUnownedDesktopSnapshotForTesting: true,
  attachDesktopRuntimeOnLoad: attach,
  turnIdempotencyCapability: () async => false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('automatic warm-up waits for lifecycle instead of dialing a parked socket', () {
    fakeAsync((time) {
      final tickets = QrcTickets();
      final client = TuiGatewayClient(
        _connection,
        dashboard: tickets,
        heartbeatInterval: Duration.zero,
        channelFactory: (_, _) => QrcFakeChannel(),
      );
      final chat = _chat(client, _PagedTranscript(), attach: true);
      unawaited(client.connect());
      time.flushMicrotasks();
      expect(tickets.minted, 1);
      chat.didChangeAppLifecycleState(AppLifecycleState.hidden);
      var settled = false;
      unawaited(
        chat.warmDesktopGatewayForAutomaticBootstrap().then(
          (_) => settled = true,
        ),
      );
      time.flushMicrotasks();
      // A warm-up attempted while suspended currently logs a transport error.
      // It must not even call connect (a connected socket would mask the bug).
      time.elapse(chatTransportBackgroundGrace);
      time.flushMicrotasks();
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      try {
        unawaited(chat.warmDesktopGatewayForAutomaticBootstrap());
        time.flushMicrotasks();
      } finally {
        debugPrint = previous;
      }
      expect(settled, isTrue);
      expect(logs.where((s) => s.contains('warm-up failed')), isEmpty);
      expect(tickets.minted, 1);
      chat.dispose();
      time.elapse(const Duration(seconds: 2));
    });
  });

  for (final defect in <String?>[
    null,
    'missing-anchor',
    'foreign-user',
    'malformed-pagination',
    'malformed-rows',
    'open-tool',
    'count-shortfall',
    'stale-load',
    'background-again',
  ]) {
    test(
      'resume durable tail: ${defect ?? '7730 rows finishes under 2 seconds'}',
      () {
        fakeAsync((time) {
          final gateway = _ResumeGateway();
          final api = _PagedTranscript();
          final chat = _chat(gateway, api);
          // Opening a long chat loads a viewport, not all 7,730 rows.
          unawaited(
            chat.loadMessages(expectedMessageCount: 7730, passiveOnly: true),
          );
          time.elapse(const Duration(milliseconds: 900));
          time.flushMicrotasks();
          expect(chat.messagesLoaded, isTrue);
          final openingRows = chat.internalMessagesForTesting.length;
          expect(openingRows, lessThan(7730));
          unawaited(
            chat.send(
              fullText: 'finish my turn',
              model: 'hermes-agent',
              history: const [],
            ),
          );
          time.flushMicrotasks();
          expect(gateway.submitTexts, ['finish my turn']);
          expect(chat.isStreaming, isTrue);
          chat.didChangeAppLifecycleState(AppLifecycleState.hidden);
          time.elapse(chatTransportBackgroundGrace);
          time.flushMicrotasks();
          api.rows = [
            ...api.rows,
            {
              'message_id': 'owned-user',
              'role': 'user',
              'content': 'finish my turn',
            },
            {
              'message_id': 'owned-final',
              'role': 'assistant',
              'content': 'durable final',
              'finish_reason': 'stop',
            },
          ];
          if (defect == 'missing-anchor') {
            api.rows = [
              for (final row in api.rows)
                {...row, 'message_id': 'foreign-${row['message_id']}'},
            ];
          }
          if (defect == 'foreign-user') {
            api.rows.add({
              'message_id': 'foreign-user',
              'role': 'user',
              'content': 'other turn',
            });
            api.rows.add({
              'message_id': 'foreign-final',
              'role': 'assistant',
              'content': 'foreign final',
            });
          }
          api.malformedPagination = defect == 'malformed-pagination';
          api.malformedRows = defect == 'malformed-rows';
          api.missingCountWitness = defect == 'count-shortfall';
          if (defect == 'open-tool') {
            api.rows.last = {
              ...api.rows.last,
              'tool_calls': [
                {'id': 'pending-tool', 'name': 'lookup'},
              ],
            };
          }
          api.pages.clear();
          final done = <ActiveChatEvent>[];
          final sub = chat.changes.listen(done.add);
          chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
          final resume = chat.reconcileAfterResume();
          var changed = false;
          unawaited(resume.then((value) => changed = value));
          time.flushMicrotasks();
          if (defect == 'stale-load') {
            // A newer viewport publication invalidates the recovery read.
            unawaited(chat.loadMessages(passiveOnly: true));
          }
          if (defect == 'background-again') {
            chat.didChangeAppLifecycleState(AppLifecycleState.hidden);
          }
          time.elapse(const Duration(milliseconds: 1500));
          time.flushMicrotasks();
          if (defect == null) {
            expect(chat.state, ChatPipelineState.completed);
            expect(changed, isTrue);
            expect(
              api.fullReads,
              0,
              reason: 'no complete transcript before done',
            );
            expect(
              api.pages,
              hasLength(2),
              reason: 'tail plus announced-count witness',
            );
            expect(api.pages.first.offset, 0);
            expect(api.pages.last, (limit: 1, offset: 7729));
            expect(chat.assistantContent, 'durable final');
            expect(
              chat.hasEarlierMessages,
              isTrue,
              reason: 'terminal proof is not complete history',
            );
            expect(done.where((e) => e == ActiveChatEvent.done), hasLength(1));
            expect(chat.internalMessagesForTesting.length, lessThan(7730));
          } else {
            expect(
              done.where((e) => e == ActiveChatEvent.done),
              isEmpty,
              reason:
                  'ambiguous or superseded evidence must not close the turn',
            );
            expect(changed, isFalse);
            if (defect != 'background-again') {
              expect(
                api.fullReads,
                1,
                reason: 'keep complete recovery fallback',
              );
            }
          }
          expect(gateway.submitTexts, [
            'finish my turn',
          ], reason: 'resume never resubmits');
          unawaited(sub.cancel());
          chat.dispose();
          time.elapse(const Duration(seconds: 10));
          time.flushMicrotasks();
        });
      },
    );
  }
}
