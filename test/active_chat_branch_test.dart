import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/utils/turn_control.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/turn_side_gateway.dart';

SavedConnection _connection() => SavedConnection(
  id: 'branch',
  label: 'Branch',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  kind: InstanceKind.vps,
);

/// `/api/sessions/{id}/messages` with `order=latest` paging, like Hermes.
class _TranscriptServer {
  _TranscriptServer(this.rows);

  final List<Map<String, dynamic>> rows;
  final List<Uri> requests = [];

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    final limit = int.parse(request.url.queryParameters['limit'] ?? '120');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, rows.length - offset);
    final start = math.max(0, end - limit);
    final page = rows.sublist(start, end);
    return http.Response(
      jsonEncode({
        'object': 'list',
        'session_id': 'stored-branch',
        'messages': page,
        'data': page,
        'pagination': {
          'limit': limit,
          'offset': offset,
          'order': 'latest',
          'returned': page.length,
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

/// Six stored rows: tool plumbing and an empty assistant row in between, so
/// the server's user/assistant space differs from the rendered one.
List<Map<String, dynamic>> _storedRows() => [
  {'id': 1, 'message_id': 'm1', 'role': 'user', 'content': 'q1'},
  {
    'id': 2,
    'message_id': 'm2',
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      {
        'id': 'call-1',
        'type': 'function',
        'function': {'name': 'execute_code', 'arguments': '{}'},
      },
    ],
  },
  {
    'id': 3,
    'message_id': 'm3',
    'role': 'tool',
    'tool_call_id': 'call-1',
    'content': 'resultado interno',
  },
  {'id': 4, 'message_id': 'm4', 'role': 'assistant', 'content': 'a1'},
  {'id': 5, 'message_id': 'm5', 'role': 'user', 'content': 'q2'},
  {'id': 6, 'message_id': 'm6', 'role': 'assistant', 'content': 'a2'},
];

Future<(ActiveChat, FakeTurnSideGateway, _TranscriptServer)> _openChat({
  int pageSize = 3,
}) async {
  final gateway = FakeTurnSideGateway();
  final server = _TranscriptServer(_storedRows());
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    transcriptPageSizeForTesting: pageSize,
    connection: _connection(),
    sessionId: 'stored-branch',
    sessionTitle: 'Branch',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      apiKey: 'test-key',
      httpClient: server.client(),
    ),
    desktopGateway: gateway,
    initialStoredSessionId: 'stored-branch',
    allowUnownedDesktopSnapshotForTesting: true,
  );
  addTearDown(chat.dispose);
  addTearDown(gateway.close);
  await chat.loadMessages();
  expect(
    await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
    isTrue,
  );
  chat.state = ChatPipelineState.completed;
  return (chat, gateway, server);
}

Map<String, dynamic> _row(ActiveChat chat, String text) =>
    chat.messages.firstWhere((message) => message['content'] == text);

DesktopControlFailure _transportLoss() =>
    const DesktopControlFailure(DesktopControlFailureKind.unavailable);

void main() {
  test('count is over user/assistant rows, after loading earlier pages', () async {
    final (chat, gateway, server) = await _openChat();
    expect(chat.hasEarlierMessages, isTrue);

    final outcome = await chat.branchChat(fromMessage: _row(chat, 'a1'));

    expect(outcome.status, BranchStatus.opened);
    expect(outcome.storedSessionId, 'stored-child-1');
    expect(chat.hasEarlierMessages, isFalse);
    expect(server.requests.length, greaterThan(1));
    final branch = gateway.callsTo('session.branch').single.params;
    expect(branch['session_id'], 'runtime-side');
    // q1 and a1: the tool row and the empty assistant row do not count.
    expect(branch['count'], 2);
    expect(branch['idempotency_key'], isA<String>());
    expect(gateway.callsTo('session.branch_whole'), isEmpty);
  });

  test('the latest message branches the whole chat', () async {
    final (chat, gateway, _) = await _openChat();

    final outcome = await chat.branchChat(fromMessage: _row(chat, 'a2'));

    expect(outcome.status, BranchStatus.opened);
    expect(gateway.callsTo('session.branch'), isEmpty);
    final whole = gateway.callsTo('session.branch_whole').single.params;
    expect(whole.containsKey('count'), isFalse);
  });

  test('typed /branch branches the whole chat', () async {
    final (chat, gateway, _) = await _openChat();

    final outcome = await chat.branchChat();

    expect(outcome.status, BranchStatus.opened);
    expect(gateway.callsTo('session.branch_whole'), hasLength(1));
  });

  test('a missing branch_whole falls back to branch without count', () async {
    final (chat, gateway, _) = await _openChat();
    gateway.failures.add(
      const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: -32601,
      ),
    );

    final outcome = await chat.branchChat();

    expect(outcome.status, BranchStatus.opened);
    final whole = gateway.callsTo('session.branch_whole').single.params;
    final plain = gateway.callsTo('session.branch').single.params;
    expect(plain.containsKey('count'), isFalse);
    expect(plain['idempotency_key'], whole['idempotency_key']);
  });

  test('a busy chat is refused without a request', () async {
    final (chat, gateway, _) = await _openChat();
    chat.state = ChatPipelineState.streaming;

    final outcome = await chat.branchChat();

    expect(outcome.status, BranchStatus.busy);
    expect(gateway.calls, isEmpty);
  });

  test('a target that cannot be matched is refused, never guessed', () async {
    final (chat, gateway, _) = await _openChat();

    final outcome = await chat.branchChat(
      fromMessage: {'role': 'user', 'content': 'q1', 'id': 999},
    );

    expect(outcome.status, BranchStatus.targetNotFound);
    expect(gateway.calls, isEmpty);
  });

  test('a lost response retries with the same key, a new action gets a new one', () async {
    final (chat, gateway, _) = await _openChat();
    gateway.failures.add(_transportLoss());

    final first = await chat.branchChat();

    expect(first.status, BranchStatus.opened);
    final attempts = gateway.callsTo('session.branch_whole');
    expect(attempts, hasLength(2));
    expect(
      attempts.first.params['idempotency_key'],
      attempts.last.params['idempotency_key'],
    );
    expect(gateway.connectCalls, greaterThan(0));

    final second = await chat.branchChat();
    expect(second.status, BranchStatus.opened);
    final all = gateway.callsTo('session.branch_whole');
    expect(
      all.last.params['idempotency_key'],
      isNot(attempts.first.params['idempotency_key']),
    );
  });

  test('a definitive error drops the key', () async {
    final (chat, gateway, _) = await _openChat();
    gateway.failures.add(
      const DesktopControlFailure(
        DesktopControlFailureKind.rejected,
        code: 5000,
      ),
    );

    expect((await chat.branchChat()).status, BranchStatus.failed);
    expect((await chat.branchChat()).status, BranchStatus.opened);

    final keys = gateway
        .callsTo('session.branch_whole')
        .map((call) => call.params['idempotency_key'])
        .toList();
    expect(keys, hasLength(2));
    expect(keys.first, isNot(keys.last));
  });

  test('a still-ambiguous attempt keeps its key for the next tap', () async {
    final (chat, gateway, _) = await _openChat();
    gateway.failures
      ..add(_transportLoss())
      ..add(_transportLoss());

    expect((await chat.branchChat()).status, BranchStatus.failed);
    expect((await chat.branchChat()).status, BranchStatus.opened);

    final keys = gateway
        .callsTo('session.branch_whole')
        .map((call) => call.params['idempotency_key'])
        .toSet();
    expect(keys, hasLength(1));
  });

  test('4008 reads as nothing to branch yet', () async {
    final (chat, gateway, _) = await _openChat();
    gateway.failures.add(
      const DesktopControlFailure(
        DesktopControlFailureKind.rejected,
        code: 4008,
      ),
    );

    expect((await chat.branchChat()).status, BranchStatus.nothingToBranch);
  });

  test('a second tap while one branch is pending does nothing', () async {
    final (chat, gateway, _) = await _openChat();
    gateway.branchGate = Completer<void>();

    final first = chat.branchChat();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final second = await chat.branchChat();
    gateway.branchGate!.complete();

    expect(second.status, BranchStatus.inFlight);
    expect((await first).status, BranchStatus.opened);
    expect(gateway.callsTo('session.branch_whole'), hasLength(1));
  });

  test('method-not-found on branch hides the entries', () async {
    final (chat, gateway, _) = await _openChat();
    expect(chat.canBranchChat, isTrue);
    gateway.failures
      ..add(
        const DesktopControlFailure(
          DesktopControlFailureKind.unsupported,
          code: -32601,
        ),
      )
      ..add(
        const DesktopControlFailure(
          DesktopControlFailureKind.unsupported,
          code: -32601,
        ),
      );

    expect((await chat.branchChat()).status, BranchStatus.unsupported);
    expect(chat.canBranchChat, isFalse);
  });
}
