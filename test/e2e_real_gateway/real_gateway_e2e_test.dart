// Real-gateway E2E: Console's TuiGatewayClient + ActiveChat against a real
// `hermes serve` (Dashboard + /api/ws) and `gateway.run` API server, with
// Hermes' own scripted loopback model provider. No emulator, no fake Hermes.
//
// Skipped unless HERMES_E2E_URL and HERMES_E2E_TOKEN are set; run it with
// `tool/e2e/run_local.sh`, which starts an isolated backend and sets them.
//
// Each prompt carries `[E2E:<KIND>:<tag>]`; tool/e2e/backend.py scripts the
// model by KIND (STREAM, SLOW, CLARIFY, BATCH, COMPACT).
//
// Budgets are assertions: a regression in requests, bytes, reads or sockets
// fails the lane instead of only showing up on a phone.
@Timeout(Duration(minutes: 4))
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/real_gateway.dart';

final _env = E2eEnv.current;

// ── Performance budgets ────────────────────────────────────────────────────
// Measured on the real backend (see the `[e2e-budget]` lines in the log) with
// headroom; tighten them when a change makes Console cheaper.

/// HTTP requests one cold chat open may issue (transcript page + auth).
const _openRequestBudget = 4;

/// Transcript pages one cold chat open may read: exactly the newest page.
const _openPageBudget = 1;

/// Bytes one cold open of the 300-row chat may download (one 120-row page
/// is ~60 KB on the seeded store; a second page or an unbounded read would
/// double it).
const _openBytesBudget = 96 * 1024;

/// JSON-RPC calls one cold open may send on its socket.
const _openRpcBudget = 8;

/// Transcript reads after one terminal `message.complete`: at least one
/// (the durable confirmation of the reply) and at most two.
const _terminalReadBudget = 2;

/// Sockets one chat may hold at once.
const _socketsPerChat = 1;

/// Transcript reads a burst of `sessions.changed` ticks may cause while the
/// chat is idle and nothing in its own transcript changed.
const _sessionsChangedReadBudget = 2;

/// Unique per test process, so a rerun against the same backend never counts
/// an earlier run's model turns.
final _run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);

String _tag(String kind, String tag) => '[E2E:$kind:$tag$_run]';

String _prompt(String kind, String tag) => '${_tag(kind, tag)} please';

Future<void> _settle([Duration d = const Duration(seconds: 2)]) =>
    Future<void>.delayed(d);

void main() {
  useRealNetwork();

  late E2eConsole phone;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    phone = E2eConsole(_env);
  });
  tearDown(() async {
    // ignore: avoid_print
    print('[e2e-traffic] ${phone.meter.report()}');
    // ignore: avoid_print
    print('[e2e-wire]\n${phone.meter.wireTrace()}');
    await phone.close();
  });

  Future<ActiveChat> openIdle(String sessionId) async {
    final chat = phone.open(sessionId);
    await chat.loadMessages();
    await waitFor(
      () => chat.desktopRuntimeSessionId != null,
      what: 'runtime attach of $sessionId',
    );
    return chat;
  }

  Future<bool> send(ActiveChat chat, String text) => chat.send(
    fullText: text,
    model: 'fake-model',
    history: chat.buildHistory(),
  );

  bool assistantSays(ActiveChat chat, String needle) => chat.messages.any(
    (m) => m['role'] == 'assistant' && '${m['content']}'.contains(needle),
  );

  final skip = _env.skipReason;

  test('open chat: one 120-row page within request/byte/RPC budgets', () async {
    final chat = phone.open(_env.seededSession);
    phone.meter.mark();
    await chat.loadMessages(expectedMessageCount: _env.seededRows);
    await waitFor(
      () => chat.desktopRuntimeSessionId != null,
      what: 'runtime attach',
    );
    await _settle();

    final requests = phone.meter.httpSinceMark;
    final pages = phone.meter.transcriptPagesSinceMark;
    final bytes = phone.meter.bytesSinceMark;
    final rpc = phone.meter.rpcSinceMark();
    reportBudget('open', {
      'requests': requests.length,
      'pages': pages.length,
      'bytes': bytes,
      'rpc': rpc.length,
      'sockets': phone.meter.sockets.length,
    });

    expect(chat.messages, hasLength(120));
    expect(chat.hasEarlierMessages, isTrue);
    expect(pages, hasLength(_openPageBudget), reason: '$requests');
    expect(pages.single.url.queryParameters['limit'], '120');
    expect(pages.single.url.queryParameters['order'], 'latest');
    expect(requests.length, lessThanOrEqualTo(_openRequestBudget));
    expect(bytes, lessThanOrEqualTo(_openBytesBudget));
    expect(rpc.length, lessThanOrEqualTo(_openRpcBudget), reason: '$rpc');
    expect(phone.meter.sockets, hasLength(_socketsPerChat));
  }, skip: skip);

  test('send: streaming deltas then message.complete within the terminal '
      'read budget', () async {
    final chat = await openIdle('e2e-chat-01');
    phone.meter.mark();
    var tokens = 0;
    final sub = chat.changes.listen((event) {
      if (event == ActiveChatEvent.token) tokens++;
    });
    addTearDown(sub.cancel);

    expect(await send(chat, _prompt('STREAM', 's1')), isTrue);
    await waitFor(
      () =>
          chat.state == ChatPipelineState.completed &&
          assistantSays(chat, 'streamed reply s1$_run'),
      what: 'turn completion',
    );
    final socket = phone.meter.sockets.single;
    final deltas = socket.received
        .where((f) => (f['params'] as Map?)?['type'] == 'message.delta')
        .length;
    final completes = socket.received
        .where((f) => (f['params'] as Map?)?['type'] == 'message.complete')
        .length;
    await _settle();
    final reads = phone.meter.transcriptPagesSinceMark.length;
    reportBudget('send', {
      'deltas': deltas,
      'tokens': tokens,
      'terminalReads': reads,
      'rpc': phone.meter.rpcSinceMark().length,
    });

    expect(deltas, greaterThan(3), reason: 'the reply must stream');
    expect(tokens, greaterThan(0));
    expect(completes, 1);
    expect(
      reads,
      inInclusiveRange(1, _terminalReadBudget),
      reason: 'the terminal reply must be confirmed against the transcript',
    );
    // Durable confirmation: the painted reply is the stored row, identity
    // included, read independently of the client under test.
    final durable = await _env.storedMessages('e2e-chat-01');
    final stored = durable.lastWhere((m) => m['role'] == 'assistant');
    expect('${stored['content']}', contains('streamed reply s1$_run'));
    final painted = chat.messages.firstWhere((m) => m['role'] == 'assistant');
    expect(painted['content'], stored['content']);
    expect(canonicalTranscriptRowId(painted), stored['id']);
    expect(await _env.modelTurnsFor(_tag('STREAM', 's1')), 1);
    expect(phone.meter.openSockets, _socketsPerChat);
  }, skip: skip);

  test('clarify (single) is answered through the server request and the '
      'turn finishes', () async {
    final chat = await openIdle('e2e-chat-02');
    expect(await send(chat, _prompt('CLARIFY', 'c1')), isTrue);
    await waitFor(
      () => chat.pendingInteractivePrompt != null,
      what: 'clarify card',
    );
    final prompt = chat.pendingInteractivePrompt!;
    final request = prompt.request! as ClarifyPromptRequest;
    expect(request.question, 'Colour for c1$_run?');
    expect(request.isBatch, isFalse);
    expect(prompt.key.requestId, startsWith('srq-'));

    await chat.respondToClarify(prompt.key, 'blue');
    await waitFor(
      () => assistantSays(chat, 'clarified c1$_run'),
      what: 'turn after the answer',
    );
    expect(chat.pendingInteractivePrompt, isNull);
    final answer = phone.meter.sockets.single.sent.where(
      (f) => f['id'] == prompt.key.requestId && f.containsKey('result'),
    );
    expect(answer.single['result'], {'answer': 'blue'});
  }, skip: skip);

  test('clarify (batch, one open-ended question with choices: null) locks '
      'every answer', () async {
    final chat = await openIdle('e2e-chat-03');
    expect(await send(chat, _prompt('BATCH', 'b1')), isTrue);
    await waitFor(
      () => chat.pendingInteractivePrompt != null,
      what: 'batch clarify card',
    );
    final prompt = chat.pendingInteractivePrompt!;
    final request = prompt.request! as ClarifyPromptRequest;
    expect(request.isBatch, isTrue);
    expect(request.questions, hasLength(2));
    final open = request.questions.singleWhere((q) => q.choices.isEmpty);
    final closed = request.questions.singleWhere((q) => q.choices.isNotEmpty);
    // The real wire carries `"choices": null` for the open question.
    final frame = phone.meter.sockets.single.received.firstWhere(
      (f) => f['id'] == prompt.key.requestId,
    );
    final wireQuestions = (frame['params'] as Map)['questions'] as List;
    expect(wireQuestions.any((q) => (q as Map)['choices'] == null), isTrue);

    await chat.respondToClarifyBatch(prompt.key, {
      closed.qid: 'red',
      open.qid: 'Ada',
    });
    await waitFor(
      () => assistantSays(chat, 'batch done b1$_run'),
      what: 'turn after the batch',
    );
    expect(phone.meter.sockets.single.count('clarify.lock'), 2);
  }, skip: skip);

  test('a clarify open across a socket cut comes back from the reconnect '
      'snapshot open_requests and is answered exactly once', () async {
    final proxy = await SeverableProxy.start(_env.dashboard);
    phone.meter.proxy = proxy;
    final chat = await openIdle('e2e-chat-04');
    expect(await send(chat, _prompt('CLARIFY', 'r1')), isTrue);
    await waitFor(
      () => chat.pendingInteractivePrompt != null,
      what: 'first clarify card',
    );
    final requestId = chat.pendingInteractivePrompt!.key.requestId;

    proxy.severAll();
    await waitFor(
      () =>
          phone.meter.sockets.length >= 2 &&
          chat.pendingInteractivePrompt != null &&
          phone.meter.sockets.last.received.any((f) {
            final result = f['result'];
            return result is Map && result['open_requests'] is List;
          }),
      timeout: const Duration(seconds: 45),
      what: 'reconnect + open_requests replay',
    );
    final replayed = chat.pendingInteractivePrompt!;
    expect(replayed.key.requestId, requestId);
    final carried = phone.meter.sockets.last.received.where((f) {
      final result = f['result'];
      return result is Map &&
          result['open_requests'] is List &&
          (result['open_requests'] as List).any(
            (r) => (r as Map)['id'] == requestId,
          );
    });
    expect(carried, isNotEmpty, reason: 'snapshot must carry the request');

    await chat.respondToClarify(replayed.key, 'red');
    await waitFor(
      () => assistantSays(chat, 'clarified r1$_run'),
      what: 'turn after the replayed answer',
    );
    final last = phone.meter.sockets.last;
    final viaProxy = last.count('request.answer');
    final direct = last.sent
        .where((f) => f['id'] == requestId && f.containsKey('result'))
        .length;
    expect(viaProxy + direct, 1, reason: 'answered exactly once');
    expect(phone.meter.openSockets, _socketsPerChat);
  }, skip: skip);

  test('reconnect mid-stream replays the turn: one final reply, one '
      'model turn, one socket', () async {
    final proxy = await SeverableProxy.start(_env.dashboard);
    phone.meter.proxy = proxy;
    final chat = await openIdle('e2e-chat-05');
    expect(await send(chat, _prompt('SLOW', 'k1')), isTrue);
    await waitFor(
      () => phone.meter.sockets.single.received.any(
        (f) => (f['params'] as Map?)?['type'] == 'message.delta',
      ),
      what: 'first delta',
    );
    proxy.severAll();
    await waitFor(
      () =>
          assistantSays(chat, 'slow reply k1$_run') &&
          chat.state == ChatPipelineState.completed,
      timeout: const Duration(seconds: 60),
      what: 'turn completion after the cut',
      chat: chat,
    );
    await _settle();
    final replayRpcs = phone.meter.sockets
        .skip(1)
        .expand((s) => s.sentMethods())
        .where(
          (m) =>
              m == 'session.events.since' ||
              m == 'session.resume' ||
              m == 'session.activate',
        )
        .toList();
    reportBudget('reconnect', {
      'sockets': phone.meter.sockets.length,
      'replayRpc': replayRpcs.join('+'),
      'pages': phone.meter.http.where((r) => r.isTranscriptPage).length,
    });
    expect(replayRpcs, isNotEmpty, reason: 'the new socket must replay');
    final finals = chat.messages
        .where(
          (m) =>
              m['role'] == 'assistant' &&
              '${m['content']}'.contains('slow reply k1$_run'),
        )
        .length;
    expect(finals, 1, reason: 'the reply must not be painted twice');
    final prompts = chat.messages
        .where(
          (m) =>
              m['role'] == 'user' &&
              '${m['content']}'.contains(_tag('SLOW', 'k1')),
        )
        .length;
    expect(prompts, 1, reason: 'the prompt must not be painted twice');
    expect(chat.messages.where((m) => m['role'] == 'assistant_error'), isEmpty);
    expect(await _env.modelTurnsFor(_tag('SLOW', 'k1')), 1);
    expect(phone.meter.openSockets, _socketsPerChat);
  }, skip: skip);

  test(
    'a prompt queued during a turn reaches the model exactly once',
    () async {
      final chat = await openIdle('e2e-chat-06');
      expect(await send(chat, _prompt('SLOW', 'q0')), isTrue);
      await waitFor(() => chat.isStreaming, what: 'turn start');
      expect(chat.enqueue(_prompt('STREAM', 'q1')), isTrue);
      expect(chat.queuedMessages, hasLength(1));
      await waitFor(
        () =>
            assistantSays(chat, 'streamed reply q1$_run') &&
            chat.state == ChatPipelineState.completed,
        timeout: const Duration(seconds: 60),
        what: 'queued turn completion',
        chat: chat,
      );
      await _settle(const Duration(seconds: 3));
      expect(chat.queuedMessages, isEmpty);
      expect(await _env.modelTurnsFor(_tag('STREAM', 'q1')), 1);
      expect(await _env.modelTurnsFor(_tag('SLOW', 'q0')), 1);
      final submits = phone.meter.sockets
          .expand((s) => s.sent)
          .where(
            (f) =>
                f['method'] == 'prompt.submit' &&
                '${(f['params'] as Map?)?['text']}'.contains(
                  _tag('STREAM', 'q1'),
                ),
          )
          .length;
      expect(submits, 1);
    },
    skip: skip,
  );

  test('a mid-turn compaction re-inserts the prompt; Console paints it '
      'once, live and on a cold reopen', () async {
    final chat = await openIdle('e2e-chat-07');
    final tag = _tag('COMPACT', 'm1');
    expect(await send(chat, '$tag read the files'), isTrue);
    await waitFor(
      () =>
          assistantSays(chat, 'compact report m1$_run') &&
          chat.state == ChatPipelineState.completed,
      timeout: const Duration(seconds: 150),
      what: 'compacting turn completion',
      chat: chat,
    );
    await _settle(const Duration(seconds: 3));
    expect(
      await _env.compactedRows('e2e-chat-07'),
      greaterThan(0),
      reason: 'the scripted turn must really compact mid-turn',
    );
    final cold = E2eConsole(_env, id: 'e2e-phone-cold');
    addTearDown(cold.close);
    final reopened = cold.open('e2e-chat-07');
    await reopened.loadMessages();
    for (final view in [chat, reopened]) {
      final prompts = view.messages
          .where((m) => m['role'] == 'user' && '${m['content']}'.contains(tag))
          .length;
      expect(prompts, 1, reason: 'the re-inserted prompt shows once');
    }
  }, skip: skip);

  test('a sessions.changed burst from another chat costs an idle chat at '
      'most $_sessionsChangedReadBudget transcript reads', () async {
    final chat = await openIdle('e2e-chat-08');
    final other = await openIdle('e2e-chat-09');
    await _settle();
    phone.meter.mark();
    final ticksBefore = chat.durableSessionsChangeRevision;
    for (var i = 0; i < 3; i++) {
      expect(await send(other, _prompt('STREAM', 'w$i')), isTrue);
      await waitFor(
        () =>
            other.state == ChatPipelineState.completed &&
            assistantSays(other, 'streamed reply w$i$_run'),
        what: 'writer turn $i',
      );
    }
    await _settle(const Duration(seconds: 5));
    final ticks = chat.durableSessionsChangeRevision - ticksBefore;
    final idleReads = phone.meter.transcriptPagesSinceMark
        .where((r) => r.url.path.contains('e2e-chat-08'))
        .length;
    reportBudget('sessions.changed', {'ticks': ticks, 'idleReads': idleReads});
    expect(ticks, greaterThan(0), reason: 'the backend must broadcast');
    expect(idleReads, lessThanOrEqualTo(_sessionsChangedReadBudget));
    expect(phone.meter.openSockets, 2 * _socketsPerChat);
  }, skip: skip);
}
