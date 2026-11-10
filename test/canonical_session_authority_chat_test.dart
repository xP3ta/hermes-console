// SPDX-License-Identifier: MIT
//
// Capability-negotiated canonical session authority: the real ActiveChat and
// the real TuiGatewayClient talk to a source-faithful fake `/api/ws`
// (public Hermes v0.22.5 contract, see support/canonical_authority_server.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/canonical_authority_server.dart';
import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

class _RealHttp extends HttpOverrides {}

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'fixture');
}

SavedConnection _connection(
  CanonicalAuthorityServer server, {
  InstanceKind kind = InstanceKind.localhost,
}) => SavedConnection(
  kind: kind,
  id: 'c',
  label: 'fixture',
  host: '127.0.0.1',
  port: server.server.port,
  dashboardUrl: 'http://127.0.0.1:${server.server.port}',
  apiKey: 'fixture',
);

String _dump(ActiveChat chat) =>
    'state=${chat.state} streaming=${chat.isStreaming} '
    'transport=${chat.transportStatus.state} rows=${[for (final m in chat.messages) '${m['role']}:${m['content'] ?? m['text']}']}';

Future<void> _until(
  bool Function() condition, {
  String what = 'condition',
  Duration timeout = const Duration(seconds: 6),
  ActiveChat? dump,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what${dump == null ? '' : ' | ${_dump(dump)}'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

int _countText(ActiveChat chat, String text) => chat.messages
    .where((m) => '${m['content'] ?? m['text']}'.trim() == text)
    .length;

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 150));

class _Rig {
  _Rig(this.server, this.service, this.chat) {
    sub = chat.changes.listen(events.add);
  }
  final CanonicalAuthorityServer server;
  final ActiveChatService service;
  final ActiveChat chat;
  final List<ActiveChatEvent> events = [];
  late final StreamSubscription<ActiveChatEvent> sub;

  int get doneCount => events.where((e) => e == ActiveChatEvent.done).length;

  Future<bool> send(String text, {bool queued = false}) =>
      chat.send(fullText: text, model: 'm', history: const [], queued: queued);

  /// A composer turn with its durable outbox record, as ChatScreen sends it.
  TurnOutboxStore? outbox;
  Future<bool> sendDurable(String text, String turnId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final prepared = PreparedTurn(
      connectionId: 'c',
      sessionId: 's',
      clientTurnId: turnId,
      createdAtMs: now,
      updatedAtMs: now,
      text: text,
      fullText: text,
      desktopText: text,
      attachments: const [],
      model: 'm',
      profile: 'default',
      state: PreparedTurnState.prepared,
    );
    await outbox!.save(prepared);
    return chat.send(
      fullText: text,
      model: 'm',
      history: const [],
      profile: 'default',
      delivery: ActiveTurnDelivery(prepared: prepared, store: outbox!),
    );
  }

  Future<void> dispose() async {
    await sub.cancel();
    service.dispose();
  }
}

Future<_Rig> _rig(
  CanonicalAuthorityServer server, {
  bool withOutbox = false,
  String sessionId = 's',
  InstanceKind kind = InstanceKind.localhost,
}) async {
  final service = ActiveChatService(
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  LocalConversationLifecycle? lifecycle;
  if (withOutbox) {
    lifecycle = LocalConversationCleanupFence.beginLifecycle(
      connectionId: 'c',
      profile: 'default',
      sessionId: 's',
    );
    expect(LocalConversationCleanupFence.rehydrate(lifecycle), isTrue);
  }
  final chat = service.attach(
    connection: _connection(server, kind: kind),
    sessionId: sessionId,
    sessionTitle: 'fixture',
    sessionProfile: withOutbox ? 'default' : '',
    localConversationLifecycle: lifecycle,
    disableForegroundKeepAlive: true,
  );
  final rig = _Rig(server, service, chat);
  if (lifecycle != null) rig.outbox = TurnOutboxStore(lifecycle: lifecycle);
  return rig;
}

/// Turn ids currently held by the encrypted outbox (discard tombstones are
/// not turns).
Set<String> _outboxIds(Map<String, String> secure) {
  final raw = secure[TurnOutboxStore.storageKeyForTesting];
  if (raw == null || raw.isEmpty) return <String>{};
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return {
    for (final entry in decoded.entries)
      if (!(entry.value as Map).containsKey('record_type')) entry.key,
  };
}

/// One storage-plugin effect on the outbox key, additive to [_outboxIds]:
/// the complete key, the effect index and the durable `state` of every turn
/// row (storage id -> state) the value held after the effect.
class _OutboxEffect {
  _OutboxEffect(this.index, this.method, this.key, this.rows);
  final int index;
  final String method;
  final String key;
  final Map<String, String> rows;

  /// Durable state of the row whose storage id contains [needle], or
  /// `absent`.
  String stateOf(String needle) {
    for (final entry in rows.entries) {
      if (entry.key.contains(needle)) return entry.value;
    }
    return 'absent';
  }
}

Map<String, String> _outboxRowStates(Map<String, String> secure) {
  final raw = secure[TurnOutboxStore.storageKeyForTesting];
  if (raw == null || raw.isEmpty) return <String, String>{};
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return {
    for (final entry in decoded.entries)
      if (!(entry.value as Map).containsKey('record_type'))
        entry.key: '${(entry.value as Map)['state']}',
  };
}

/// Durable state of [needle] after each effect from [from] on.
List<String> _stateTrail(
  List<_OutboxEffect> effects,
  String needle, {
  int from = 0,
}) => [for (final effect in effects.skip(from)) effect.stateOf(needle)];

/// A storage-plugin interception point for the outbox key: it may delay the
/// effect (return a future) or fail it (throw), before it is applied.
typedef _OutboxInterceptor = Future<void>? Function(String method, String? raw);

bool _rawHasState(String? raw, String needle, String state) {
  if (raw == null || raw.isEmpty) return false;
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return decoded.entries.any(
    (entry) =>
        entry.key.contains(needle) &&
        entry.value is Map &&
        (entry.value as Map)['state'] == state,
  );
}

PreparedTurn _queuedPrepared(String id, String text) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return PreparedTurn(
    connectionId: 'c',
    sessionId: 's',
    clientTurnId: id,
    createdAtMs: now,
    updatedAtMs: now,
    text: text,
    fullText: text,
    desktopText: text,
    attachments: const [],
    model: 'm',
    profile: 'default',
    state: PreparedTurnState.prepared,
    queued: true,
  );
}

/// Polls like [_until] but reports instead of failing.
Future<bool> _tryUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  // Every write/delete of the outbox key, as the set of turn ids it held.
  final outboxHistory = <Set<String>>[];
  // Same effects with the durable row state and the effect index.
  final outboxEffects = <_OutboxEffect>[];
  _OutboxInterceptor? outboxInterceptor;
  setUp(() {
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    SharedPreferences.setMockInitialValues({});
    secure.clear();
    outboxHistory.clear();
    outboxEffects.clear();
    outboxInterceptor = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map).cast<String, dynamic>();
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'readAll':
                return Map<String, String>.of(secure);
              case 'write':
                if (args['key'] == TurnOutboxStore.storageKeyForTesting) {
                  await outboxInterceptor?.call('write', args['value']);
                }
                secure[args['key']] = args['value'];
                if (args['key'] == TurnOutboxStore.storageKeyForTesting) {
                  outboxHistory.add(_outboxIds(secure));
                  outboxEffects.add(
                    _OutboxEffect(
                      outboxEffects.length,
                      'write',
                      '${args['key']}',
                      _outboxRowStates(secure),
                    ),
                  );
                }
              case 'delete':
                if (args['key'] == TurnOutboxStore.storageKeyForTesting) {
                  await outboxInterceptor?.call('delete', null);
                }
                secure.remove(args['key']);
                if (args['key'] == TurnOutboxStore.storageKeyForTesting) {
                  outboxHistory.add(<String>{});
                  outboxEffects.add(
                    _OutboxEffect(
                      outboxEffects.length,
                      'delete',
                      '${args['key']}',
                      <String, String>{},
                    ),
                  );
                }
            }
            return null;
          },
        );
  });

  Future<void> withServer(
    Object? advertise,
    Future<void> Function(CanonicalAuthorityServer server) body, {
    bool legacy = false,
  }) => HttpOverrides.runZoned(() async {
    final server = await CanonicalAuthorityServer.start(advertise: advertise);
    server.legacyBackend = legacy;
    addTearDown(server.close);
    await body(server);
    expect(
      server.unmodelled,
      isEmpty,
      reason: 'the client sent methods the authority fake does not model',
    );
  }, createHttpClient: _RealHttp().createHttpClient);

  group('capability negotiation', () {
    test(
      'advertised true: the chat speaks the canonical wire',
      () => withServer(true, (server) async {
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        final sending = rig.send('hello');
        await server.waitFor('prompt.submit');
        final submit = server.framesOf('prompt.submit').single['params'] as Map;
        expect(submit['session_id'], 's');
        expect(submit['text'], 'hello');
        expect(submit['submission_id'], isA<String>());
        expect(submit, isNot(contains('client_turn_id')));
        expect(await sending, isTrue);
        // The receipt is an admission, not a terminal: the turn is still open.
        expect(rig.chat.isStreaming, isTrue);
        expect(rig.doneCount, 0);
        server.startTurn(admission: 'adm-1', gen: 4);
        server.completeTurn(text: 'reply', admission: 'adm-1', gen: 4);
        await _until(() => rig.doneCount == 1, what: 'done');
        await _settle();
        expect(rig.doneCount, 1);
        expect(server.framesOf('prompt.submit'), hasLength(1));
        // One durable final: no duplicate bubble, no second turn appended.
        expect(_countText(rig.chat, 'reply'), 1);
        expect(_countText(rig.chat, 'hello'), 1);
      }),
    );

    for (final value in <Object?>[false, 'absent', 'yes', 1]) {
      test(
        'advertised $value: standalone wire, no canonical keys',
        () => withServer(value, (server) async {
          final rig = await _rig(server);
          addTearDown(rig.dispose);
          expect(await rig.send('hello'), isTrue);
          final submit =
              server.framesOf('prompt.submit').single['params'] as Map;
          expect(submit['session_id'], 'runtime-legacy');
          expect(submit, isNot(contains('submission_id')));
          expect(submit, isNot(contains('execution_generation')));
        }, legacy: true),
      );
    }
  });

  group('snapshot and prompts', () {
    test(
      'cold open with a question: actionable, then server timeout clears it without any send',
      () => withServer(true, (server) async {
        server.history.addAll([
          {'role': 'user', 'text': 'q', 'content': 'q', 'row_id': 1},
        ]);
        server.running = true;
        server.runningAdmission = 'adm-9';
        server.openPrompt(
          server.prompt('clarify', 'p-1', question: 'Which one?'),
        );
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        expect(
          await rig.chat.ensureDesktopRuntime(acquireForExplicitAction: true),
          isTrue,
        );
        await _until(
          () => rig.chat.needsInput,
          what: 'question restored from snapshot',
        );
        // Server gives up on the question and ends the turn (timeout).
        server.settlePrompt('p-1');
        server.completeTurn(text: 'timed out reply', admission: 'adm-9');
        await _until(() => !rig.chat.needsInput, what: 'Needs you cleared');
        await _settle();
        expect(rig.chat.needsInput, isFalse);
        expect(_countText(rig.chat, 'timed out reply'), lessThanOrEqualTo(1));
        expect(server.framesOf('prompt.submit'), isEmpty);
        expect(server.framesOf('clarify.respond'), isEmpty);
        expect(server.framesOf('approval.respond'), isEmpty);
      }),
    );

    test(
      'still-open approval stays actionable and is answered with prompt id and generation',
      () => withServer(true, (server) async {
        server.running = true;
        server.runningAdmission = 'adm-9';
        server.openPrompt(server.prompt('approval', 'ap-1', gen: 3));
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        expect(
          await rig.chat.ensureDesktopRuntime(acquireForExplicitAction: true),
          isTrue,
        );
        await _until(() => rig.chat.pendingApproval != null, what: 'approval');
        await _settle();
        expect(
          server.framesOf('approval.respond'),
          isEmpty,
          reason: 'no unsolicited response',
        );
        await rig.chat.resolveApproval('once');
        final respond =
            server.framesOf('approval.respond').single['params'] as Map;
        expect(respond['prompt_id'], 'ap-1');
        expect(respond['execution_generation'], 3);
        expect(respond['choice'], 'once');
        expect(respond['session_id'], 's');
        await _until(
          () => rig.chat.pendingApproval == null,
          what: 'approval settled',
        );
      }),
    );
  });

  group('positive controls', () {
    test(
      'approval answered mid-turn: the turn continues and closes once, nothing re-sent',
      () => withServer(true, (server) async {
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        expect(await rig.send('run it'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        server.openPrompt(server.prompt('approval', 'ap-1', gen: 4));
        await _until(
          () => rig.chat.pendingApproval != null,
          what: 'approval card',
        );
        await rig.chat.resolveApproval('once');
        await _until(
          () => rig.chat.pendingApproval == null,
          what: 'approval settled',
        );
        server.publish('message.delta', {'text': 'after approval'});
        server.completeTurn(text: 'finished', admission: 'adm-1', gen: 4);
        await _until(() => rig.doneCount == 1, what: 'done');
        await _settle();
        expect(rig.doneCount, 1);
        expect(server.framesOf('approval.respond'), hasLength(1));
        expect(server.framesOf('prompt.submit'), hasLength(1));
        expect(_countText(rig.chat, 'finished'), 1);
      }),
    );

    test(
      'clarify answered mid-turn continues the same turn',
      () => withServer(true, (server) async {
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        expect(await rig.send('ask me'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        server.openPrompt(
          server.prompt('clarify', 'cl-1', gen: 4, question: 'Which one?'),
        );
        await _until(() => rig.chat.needsInput, what: 'clarify card');
        final entry = rig.chat.pendingInteractivePrompt!;
        await rig.chat.respondToClarify(entry.key, 'the blue one');
        final frame =
            server.framesOf('clarify.respond').single['params'] as Map;
        expect(frame['prompt_id'], 'cl-1');
        expect(frame['execution_generation'], 4);
        expect(frame['answer'], 'the blue one');
        await _until(() => !rig.chat.needsInput, what: 'clarify settled');
        server.completeTurn(text: 'blue done', admission: 'adm-1', gen: 4);
        await _until(() => rig.doneCount == 1, what: 'done');
        await _settle();
        expect(rig.doneCount, 1);
        expect(server.framesOf('prompt.submit'), hasLength(1));
      }),
    );

    test(
      'partial streamed bubble then an empty terminal text: one durable final',
      () => withServer(true, (server) async {
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        expect(await rig.send('stream'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        server.publish('message.delta', {'text': 'par'});
        server.publish('message.delta', {'text': 'tial'});
        await _settle();
        server.history.add({
          'role': 'assistant',
          'text': 'durable reply',
          'content': 'durable reply',
          'row_id': 99,
        });
        server.publish(
          'message.complete',
          {'text': '', 'status': 'complete'},
          'adm-1',
          4,
        );
        server.running = false;
        server.runningAdmission = null;
        await _until(() => rig.doneCount == 1, what: 'done');
        await _settle();
        expect(rig.doneCount, 1);
        expect(_countText(rig.chat, 'durable reply'), 1);
        expect(
          rig.chat.messages.where(
            (m) => m['role'] == 'assistant' && '${m['content']}'.trim().isEmpty,
          ),
          isEmpty,
        );
        expect(
          server.framesOf('prompt.submit'),
          hasLength(1),
          reason: 'no automatic resend',
        );
      }),
    );
  });

  group('replay failure', () {
    test(
      'epoch change mid-turn: the frame is withheld, the chat re-attaches from a fresh snapshot and converges once',
      () => withServer(true, (server) async {
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        expect(await rig.send('A'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        server.publish('message.delta', {'text': 'partial'});
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        final resumesBefore = server.framesOf('session.resume').length;
        // The authority's ring was rebuilt: the terminal frame arrives in an
        // epoch this connection never proved.
        server.replayEpoch = 'ring-2';
        server.seq = 0;
        server.completeTurn(text: 'final A', admission: 'adm-1', gen: 4);
        await _until(
          () => server.framesOf('session.resume').length > resumesBefore,
          what: 're-attach from a fresh snapshot',
        );
        await _until(() => rig.doneCount >= 1, what: 'converged');
        await _settle();
        expect(rig.doneCount, 1);
        expect(_countText(rig.chat, 'final A'), 1);
        expect(
          server.framesOf('prompt.submit'),
          hasLength(1),
          reason: 'no automatic resend',
        );
      }),
    );
  });

  group('admission fences', () {
    test(
      'R1: A terminal overtaking B\'s ack never closes B (asserted before B starts)',
      () => withServer(true, (server) async {
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        expect(await rig.send('A'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        server.publish('message.delta', {'text': 'partial A'});
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        // B becomes the followed turn (non-queued submit); the authority puts it
        // behind A. A's terminal frame was queued before the ack and lands after.
        expect(await rig.send('B'), isTrue);
        expect(server.framesOf('prompt.submit'), hasLength(2));
        final aComplete = server.publishDeferred(
          'message.complete',
          {'text': 'answer A', 'status': 'complete'},
          'adm-1',
          4,
        );
        server.deliver(aComplete);
        await _settle();
        // Intermediate state BEFORE B starts.
        expect(rig.doneCount, 0, reason: 'A terminal must not close B');
        expect(rig.chat.isStreaming, isTrue);
        // B really runs and finishes.
        server.runningAdmission = null;
        server.running = false;
        server.startTurn(admission: 'adm-2', gen: 5);
        server.completeTurn(text: 'answer B', admission: 'adm-2', gen: 5);
        await _until(() => rig.doneCount == 1, what: 'B done');
        await _settle();
        expect(rig.doneCount, 1);
      }),
    );

    test(
      'contiguous burst [A complete, B start]: B is neither closed nor reopened',
      () => withServer(true, (server) async {
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        expect(await rig.send('A'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        expect(await rig.send('B'), isTrue);
        final aDone = server.publishDeferred(
          'message.complete',
          {'text': 'answer A', 'status': 'complete'},
          'adm-1',
          4,
        );
        server.running = false;
        server.runningAdmission = null;
        final bStart = server.publishDeferred('message.start', {}, 'adm-2', 5);
        server.deliver(aDone);
        server.deliver(bStart);
        await _settle();
        expect(rig.doneCount, 0);
        expect(rig.chat.isStreaming, isTrue);
        server.generation = 5;
        server.runningAdmission = 'adm-2';
        server.running = true;
        server.completeTurn(text: 'answer B', admission: 'adm-2', gen: 5);
        await _until(() => rig.doneCount == 1, what: 'B done');
        await _settle();
        expect(rig.doneCount, 1);
      }),
    );

    test(
      'control: a queued follow-up runs after A closes legitimately',
      () => withServer(true, (server) async {
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        expect(await rig.send('A'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        expect(await rig.send('B', queued: true), isTrue);
        server.completeTurn(text: 'answer A', admission: 'adm-1', gen: 4);
        await _until(() => rig.doneCount == 1, what: 'A done');
        server.startTurn(admission: 'adm-2', gen: 5);
        server.completeTurn(text: 'answer B', admission: 'adm-2', gen: 5);
        await _until(() => rig.doneCount == 2, what: 'B done');
        await _settle();
        expect(rig.doneCount, 2);
        expect(server.framesOf('prompt.submit'), hasLength(2));
      }),
    );
  });

  group('B2 reconnect and recovery on the production gateway', () {
    Future<void> drop(CanonicalAuthorityServer server, int sockets) async {
      await server.sockets.last.close();
      await _until(
        () => server.sockets.length > sockets,
        what: 'the chat socket redials by itself',
        timeout: const Duration(seconds: 30),
      );
    }

    test(
      'B2.1 idle chat: the production redial re-attaches canonically and shows a question opened elsewhere, with no send',
      () => withServer(true, (server) async {
        server.history.add({
          'role': 'user',
          'text': 'hi',
          'content': 'hi',
          'row_id': 1,
        });
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(
          await rig.chat.ensureDesktopRuntime(acquireForExplicitAction: true),
          isTrue,
        );
        final resumes = server.framesOf('session.resume').length;
        await drop(server, server.sockets.length);
        await _until(
          () => server.framesOf('session.resume').length > resumes,
          what: 'canonical session.resume on the new socket',
          timeout: const Duration(seconds: 30),
        );
        // Another surface starts a turn and asks something.
        server.startTurn(admission: 'ext-1', gen: 4);
        server.openPrompt(
          server.prompt('clarify', 'p-ext', gen: 4, question: 'Which?'),
        );
        await _until(
          () => rig.chat.needsInput,
          what: 'question from another surface',
          timeout: const Duration(seconds: 30),
        );
        expect(server.framesOf('prompt.submit'), isEmpty);
        expect(server.framesOf('clarify.respond'), isEmpty);
      }),
    );

    test(
      'B2.2 own turn cut mid-stream with a question open: recovery adopts the canonical snapshot, restores the question, settles once, outbox kept until the final',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(await rig.sendDurable('A', 'turn-a'), isTrue);
        const aId = 'turn-a';
        server.startTurn(admission: 'adm-1', gen: 4);
        server.openPrompt(
          server.prompt('clarify', 'cl-1', gen: 4, question: 'Which?'),
        );
        await _until(() => rig.chat.needsInput, what: 'question shown');
        expect(outboxHistory.last.any((id) => id.contains(aId)), isTrue);
        final resumes = server.framesOf('session.resume').length;
        await drop(server, server.sockets.length);
        await _until(
          () => server.framesOf('session.resume').length > resumes,
          what: 'canonical re-attach',
          timeout: const Duration(seconds: 30),
        );
        await _until(
          () => rig.chat.needsInput,
          what: 'question restored after the cut',
          timeout: const Duration(seconds: 30),
        );
        expect(rig.doneCount, 0);
        expect(
          outboxHistory.last.any((id) => id.contains(aId)),
          isTrue,
          reason: 'the entry stays until the final',
        );
        server.settlePrompt('cl-1');
        server.completeTurn(text: 'final A', admission: 'adm-1', gen: 4);
        await _until(() => rig.doneCount == 1, what: 'done once');
        await _settle();
        expect(rig.doneCount, 1);
        expect(_countText(rig.chat, 'final A'), 1);
        expect(server.framesOf('prompt.submit'), hasLength(1));
        expect(server.framesOf('clarify.respond'), isEmpty);
        final removals = [
          for (var i = 1; i < outboxHistory.length; i++)
            if (outboxHistory[i - 1].any((id) => id.contains(aId)) &&
                !outboxHistory[i].any((id) => id.contains(aId)))
              i,
        ];
        expect(removals, hasLength(1), reason: 'deleted exactly once');
      }),
    );

    test(
      'B2.3 question timed out and the turn finished while disconnected: no stale Needs you, one final, nothing re-sent',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(await rig.sendDurable('A', 'turn-a'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        server.openPrompt(
          server.prompt('clarify', 'cl-1', gen: 4, question: 'Which?'),
        );
        await _until(() => rig.chat.needsInput, what: 'question shown');
        final sockets = server.sockets.length;
        await server.sockets.last.close();
        // The authority settles it while nobody is attached.
        server.settlePrompt('cl-1');
        server.completeTurn(text: 'final A', admission: 'adm-1', gen: 4);
        await _until(
          () => server.sockets.length > sockets,
          what: 'redial',
          timeout: const Duration(seconds: 30),
        );
        await _until(
          () => rig.doneCount == 1,
          what: 'converged to the durable final',
          timeout: const Duration(seconds: 30),
        );
        await _settle();
        expect(rig.chat.needsInput, isFalse);
        expect(_countText(rig.chat, 'final A'), 1);
        expect(server.framesOf('prompt.submit'), hasLength(1));
        expect(outboxHistory.last.any((id) => id.isNotEmpty), isFalse);
      }),
    );

    test(
      'B2.4 idle viewer with a sequence gap stays attached: re-attaches in place and shows the next question',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(
          await rig.chat.ensureDesktopRuntime(acquireForExplicitAction: true),
          isTrue,
        );
        final resumes = server.framesOf('session.resume').length;
        final sockets = server.sockets.length;
        // Two frames the socket never carried, then one it does.
        server.publishDeferred('session.info', {'revision': 12});
        server.publishDeferred('session.info', {'revision': 13});
        server.deliver(server.publishDeferred('session.info', {'x': 1}));
        await _until(
          () => server.framesOf('session.resume').length > resumes,
          what: 're-attach after the gap',
          timeout: const Duration(seconds: 30),
        );
        await _settle();
        expect(server.sockets.length, sockets, reason: 'socket is healthy');
        server.startTurn(admission: 'ext-1', gen: 4);
        server.openPrompt(
          server.prompt('clarify', 'p-ext', gen: 4, question: 'Which?'),
        );
        await _until(
          () => rig.chat.needsInput,
          what: 'the chat still follows the session',
          timeout: const Duration(seconds: 30),
        );
        expect(server.framesOf('prompt.submit'), isEmpty);
      }),
    );

    // C1 source proof (public upstream MIT v0.22.5, read-only):
    // gateway/session_events.py `SessionEvents.publish` (lines 38-54) only ever
    // raises `sequence` inside one `replay_epoch`; if a stamped seq is not above
    // it the epoch is rotated first. `watermark()` (29-36) and the attach cut
    // (gateway/session_authority.py `attach`, 335-349) both read under the same
    // `event_stream.lock` the publisher holds. A same-epoch resume therefore
    // cannot return a cut older than a terminal already published (so "cut 5
    // after an observed seq 10 in the same epoch" is not a response a legitimate
    // authority can produce, and the client adds no heuristic for it). What a
    // legitimate reconnect can do is cut at/after the terminal and then see a
    // stale replay of the old frames; that must stay inert.
    test(
      'C1 same-epoch reconnect after A completed: the snapshot cut is not older than the terminal, so a stale replay of A (with and without admission, incl. tool.complete) is inert, and a new external turn is still followed',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(await rig.sendDurable('A', 'turn-a'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        server.publish(
          'tool.start',
          {'tool_id': 't1', 'name': 'terminal'},
          'adm-1',
          4,
        );
        server.publish('message.delta', {'text': 'par'}, 'adm-1', 4);
        server.publish(
          'tool.complete',
          {'tool_id': 't1', 'name': 'terminal'},
          'adm-1',
          4,
        );
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        server.completeTurn(text: 'answer A', admission: 'adm-1', gen: 4);
        await _until(() => rig.doneCount == 1, what: 'A done', dump: rig.chat);
        await _settle();
        final stale = [
          for (final e in server.ring) Map<String, dynamic>.of(e),
        ];
        expect(server.snapshotJson['last_sequence'], server.seq);
        expect(server.snapshotJson['replay_epoch'], stale.last['replay_epoch']);
        final sockets = server.sockets.length;
        final resumes = server.framesOf('session.resume').length;
        await server.sockets.last.close();
        await _until(
          () =>
              server.sockets.length > sockets &&
              server.framesOf('session.resume').length > resumes,
          what: 'redial and canonical re-attach in the same replay epoch',
          timeout: const Duration(seconds: 30),
        );
        await _settle();
        expect(rig.doneCount, 1);
        final toolEvents = rig.events
            .where((e) => e == ActiveChatEvent.toolProgress)
            .length;
        for (final withAdmission in const [true, false]) {
          for (final params in stale) {
            final replay = Map<String, dynamic>.of(params);
            if (!withAdmission) replay.remove('admission_id');
            server.deliver({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': replay,
            });
          }
        }
        await _settle();
        expect(rig.doneCount, 1, reason: 'no second done from the replay');
        expect(_countText(rig.chat, 'answer A'), 1, reason: 'no duplicate A');
        expect(rig.chat.isStreaming, isFalse, reason: 'no active state');
        expect(
          rig.events.where((e) => e == ActiveChatEvent.toolProgress).length,
          toolEvents,
          reason: 'a replayed tool.complete does nothing',
        );
        expect(server.framesOf('prompt.submit'), hasLength(1));
        // A legitimate new turn from another surface is still followed.
        server.startTurn(admission: 'ext-2', gen: 5);
        await _until(
          () => rig.chat.isStreaming,
          what: 'the new external turn is followed',
          dump: rig.chat,
        );
        server.completeTurn(text: 'answer ext', admission: 'ext-2', gen: 5);
        await _until(
          () => _countText(rig.chat, 'answer ext') == 1,
          what: 'external final',
          dump: rig.chat,
        );
        await _settle();
        expect(_countText(rig.chat, 'answer ext'), 1);
        expect(_countText(rig.chat, 'answer A'), 1);
        expect(server.framesOf('prompt.submit'), hasLength(1));
      }),
    );

    // B2.5 (raw `chat.send` of B while A streams, B admitted `queued` by the
    // authority before A's terminal) is not an ActiveChat entry: ChatScreen
    // queues the second message as a prepared turn (`enqueuePreparedTurn`,
    // sent only after the terminal by `_drainQueue`), `sendQueuedNow`
    // interrupts A before draining and `redirectPreparedComposerTurn` uses
    // steer. The server-admitted-B-before-A-terminal contract is pinned at the
    // client/admission level (session_authority_client_test.dart, "B2.5
    // client-level"), the service path below keeps every end-to-end guarantee
    // and B2.6 drives the interrupt / send-now action.
    test(
      'B2.5 service path (enqueuePreparedTurn, as ChatScreen calls it; no widget mounted): B typed while A streams goes to the prepared queue, is NOT server-admitted before the A terminal, then each answer once',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(await rig.sendDurable('A', 'turn-a'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        // ChatScreen (`_sending` => enqueuePreparedTurn): the composer turn is
        // written to the outbox and queued locally; `_drainQueue` returns while
        // `isStreaming`.
        final now = DateTime.now().millisecondsSinceEpoch;
        final prepared = PreparedTurn(
          connectionId: 'c',
          sessionId: 's',
          clientTurnId: 'turn-b',
          createdAtMs: now,
          updatedAtMs: now,
          text: 'B',
          fullText: 'B',
          desktopText: 'B',
          attachments: const [],
          model: 'm',
          profile: 'default',
          state: PreparedTurnState.prepared,
          queued: true,
        );
        expect(
          await rig.chat.enqueuePreparedTurn(
            ActiveTurnDelivery(prepared: prepared, store: rig.outbox!),
          ),
          isTrue,
        );
        await _settle();
        expect(
          server.framesOf('prompt.submit'),
          hasLength(1),
          reason: 'B is not server-admitted while A streams (queue UI path)',
        );
        expect(outboxHistory.last.any((id) => id.contains('turn-b')), isTrue);
        server.history.add({
          'role': 'assistant',
          'text': 'answer A',
          'content': 'answer A',
          'row_id': server.history.length + 1,
        });
        final lateA = server.publishDeferred(
          'message.complete',
          {'text': 'answer A', 'status': 'complete'},
          'adm-1',
          4,
        );
        server.settleTerminal('adm-1');
        server.deliver(lateA);
        await _until(
          () => _countText(rig.chat, 'answer A') == 1,
          what: 'A final applied',
          dump: rig.chat,
        );
        await _until(
          () => server.framesOf('prompt.submit').length == 2,
          what: 'B submitted after the A terminal',
          dump: rig.chat,
        );
        expect(outboxHistory.last.any((id) => id.contains('turn-b')), isTrue);
        final doneAfterA = rig.doneCount;
        server.startTurn(admission: 'adm-2', gen: 5);
        expect(
          outboxHistory.last.any((id) => id.contains('turn-b')),
          isTrue,
          reason: 'B stays in the outbox until its own final',
        );
        server.completeTurn(text: 'answer B', admission: 'adm-2', gen: 5);
        await _until(
          () => _countText(rig.chat, 'answer B') == 1,
          what: 'B final applied',
          dump: rig.chat,
        );
        await _until(
          () => rig.doneCount == doneAfterA + 1,
          what: 'B own done, distinct from A',
        );
        await _settle();
        expect(rig.doneCount, doneAfterA + 1, reason: 'A did not satisfy B');
        expect(_countText(rig.chat, 'answer A'), 1);
        expect(_countText(rig.chat, 'answer B'), 1);
        expect(server.framesOf('prompt.submit'), hasLength(2));
        final removals = [
          for (var i = 1; i < outboxHistory.length; i++)
            if (outboxHistory[i - 1].any((id) => id.contains('turn-b')) &&
                !outboxHistory[i].any((id) => id.contains('turn-b')))
              i,
        ];
        expect(removals, hasLength(1), reason: 'B deleted exactly once');
        expect(
          outboxHistory.last.any((id) => id.contains('turn-b')),
          isFalse,
          reason: 'and it never comes back',
        );
      }),
    );

    // R-1 (R4 section 6): the accepted write of B is in flight in the real
    // storage seam while B's own start+complete are delivered. The terminal
    // edge and `_finishTurnDelivery` both close the same delivery; storage
    // must see exactly one terminal save and one delete for B, and no later
    // row of B.
    test(
      'R-1 B accepted write held while B start+complete arrive: B closes exactly once in storage (terminal then absent), reopened outbox has no B, A and B once, 2 submits',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(await rig.sendDurable('A', 'turn-a'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        final held = Completer<void>();
        final release = Completer<void>();
        var armed = true;
        var heldIndex = -1;
        outboxInterceptor = (method, raw) {
          if (!armed ||
              method != 'write' ||
              !_rawHasState(raw, 'turn-b', 'accepted')) {
            return null;
          }
          armed = false;
          heldIndex = outboxEffects.length;
          held.complete();
          return release.future;
        };
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        expect(
          await rig.chat.enqueuePreparedTurn(
            ActiveTurnDelivery(
              prepared: _queuedPrepared('turn-b', 'B'),
              store: rig.outbox!,
            ),
          ),
          isTrue,
        );
        await _settle();
        server.history.add({
          'role': 'assistant',
          'text': 'answer A',
          'content': 'answer A',
          'row_id': server.history.length + 1,
        });
        final lateA = server.publishDeferred(
          'message.complete',
          {'text': 'answer A', 'status': 'complete'},
          'adm-1',
          4,
        );
        server.settleTerminal('adm-1');
        server.deliver(lateA);
        await _until(
          () => held.isCompleted,
          what: 'B accepted write held in storage',
          dump: rig.chat,
        );
        final doneAfterA = rig.doneCount;
        // Frozen release point: B's own start+complete are delivered with the
        // accepted write still in flight.
        server.startTurn(admission: 'adm-2', gen: 5);
        server.completeTurn(text: 'answer B', admission: 'adm-2', gen: 5);
        final terminalEdgeWhileHeld = await _tryUntil(
          () => _countText(rig.chat, 'answer B') == 1,
        );
        release.complete();
        await _until(
          () => _countText(rig.chat, 'answer B') == 1,
          what: 'B final applied',
          dump: rig.chat,
        );
        await _until(
          () => rig.doneCount == doneAfterA + 1,
          what: 'B own done',
        );
        await _settle();
        expect(
          terminalEdgeWhileHeld,
          isTrue,
          reason: 'precondition: B terminal edge passed while the write was held',
        );
        expect(heldIndex, greaterThanOrEqualTo(0));
        expect(
          outboxEffects[heldIndex].stateOf('turn-b'),
          'accepted',
          reason: 'the held effect is the accepted write of B',
        );
        expect(
          _stateTrail(outboxEffects, 'turn-b', from: heldIndex + 1),
          ['terminal', 'absent'],
          reason: 'one terminal save + one delete of B after accepted; '
              'full trail=${[for (final e in outboxEffects) '${e.index}:${e.method}:${e.stateOf('turn-b')}']}',
        );
        final reopened = TurnOutboxStore(lifecycle: rig.outbox!.lifecycle);
        expect(
          (await reopened.loadAllForChat('c', 's', profile: 'default'))
              .where((t) => t.clientTurnId == 'turn-b'),
          isEmpty,
          reason: 'a reopened store holds no B',
        );
        expect(_outboxRowStates(secure).keys.any((k) => k.contains('turn-b')),
            isFalse);
        expect(server.framesOf('prompt.submit'), hasLength(2));
        expect(_countText(rig.chat, 'answer A'), 1);
        expect(_countText(rig.chat, 'answer B'), 1);
        expect(rig.doneCount, doneAfterA + 1, reason: 'B own done once');
      }),
    );

    // R-2a: the same in-flight accepted write, but the terminal arrives
    // through `_beginDesktopAcceptedQueuedTurn` (a `session.steer` queued
    // behind A), which closes A's delivery and moves the chat to the queued
    // turn; the suspended `_finishTurnDelivery` then reads the NEXT turn's
    // pipeline state and must not mark the closed delivery `running`.
    test(
      'R-2a A accepted write held, steer queued, A terminal begins the queued turn: A never returns to running after the close; reopened outbox has no A',
      () => withServer(true, (server) async {
        final rig = await _rig(
          server,
          withOutbox: true,
          kind: InstanceKind.vps,
        );
        addTearDown(rig.dispose);
        final held = Completer<void>();
        final release = Completer<void>();
        var armed = true;
        var heldIndex = -1;
        outboxInterceptor = (method, raw) {
          if (!armed ||
              method != 'write' ||
              !_rawHasState(raw, 'turn-a', 'accepted')) {
            return null;
          }
          armed = false;
          heldIndex = outboxEffects.length;
          held.complete();
          return release.future;
        };
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final send = rig.sendDurable('A', 'turn-a');
        await _until(() => held.isCompleted, what: 'A accepted write held');
        server.startTurn(admission: 'adm-1', gen: 4);
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        await rig.chat.steer('use blue', interrupt: false);
        server.history.add({
          'role': 'assistant',
          'text': 'answer A',
          'content': 'answer A',
          'row_id': server.history.length + 1,
        });
        final lateA = server.publishDeferred(
          'message.complete',
          {'text': 'answer A', 'status': 'complete'},
          'adm-1',
          4,
        );
        server.settleTerminal('adm-1');
        server.deliver(lateA);
        final terminalEdgeWhileHeld = await _tryUntil(
          () => _countText(rig.chat, 'answer A') == 1,
        );
        await _settle();
        release.complete();
        await send;
        await _settle();
        expect(
          terminalEdgeWhileHeld,
          isTrue,
          reason: 'precondition: A terminal edge passed while the write was held',
        );
        expect(outboxEffects[heldIndex].stateOf('turn-a'), 'accepted');
        expect(
          _stateTrail(outboxEffects, 'turn-a', from: heldIndex + 1),
          ['terminal', 'absent'],
          reason: 'no write of A after its close; '
              'full trail=${[for (final e in outboxEffects) '${e.index}:${e.method}:${e.stateOf('turn-a')}']}',
        );
        final reopened = TurnOutboxStore(lifecycle: rig.outbox!.lifecycle);
        expect(
          (await reopened.loadAllForChat('c', 's', profile: 'default'))
              .where((t) => t.clientTurnId == 'turn-a'),
          isEmpty,
        );
      }),
    );

    // CHANGES-1: upstream `error` is a session-level failure OUTSIDE a turn
    // (tui_gateway/contracts/events.py); a failed turn closes with
    // `message.complete status:error`. The chat must not take it for the
    // terminal of the interrupted A and drain B behind a live admission.
    test(
      'B2.7 send-now: interrupt ACKed, A terminal held, an error frame for A arrives first: B is NOT submitted and stays durable until the authoritative A terminal',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(await rig.sendDurable('A', 'turn-a'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        expect(
          await rig.chat.enqueuePreparedTurn(
            ActiveTurnDelivery(
              prepared: _queuedPrepared('turn-b', 'B'),
              store: rig.outbox!,
            ),
          ),
          isTrue,
        );
        expect(server.framesOf('prompt.submit'), hasLength(1));
        expect(
          await rig.chat.sendQueuedNow(
            'prepared:turn-b',
            queueIfInterruptUnsupported: true,
          ),
          isTrue,
        );
        expect(server.framesOf('session.interrupt'), hasLength(1));
        await _settle();
        expect(server.framesOf('prompt.submit'), hasLength(1),
            reason: 'precondition: B waits for the A terminal');
        server.publish(
          'error',
          {'message': 'session-level failure'},
          'adm-1',
          4,
        );
        await _settle();
        final submitsAfterError = server.framesOf('prompt.submit').length;
        final bDurable = _outboxRowStates(secure).keys.any(
          (k) => k.contains('turn-b'),
        );
        expect(submitsAfterError, 1,
            reason: 'error(A) is not the terminal of A: B must not drain');
        expect(bDurable, isTrue, reason: 'B stays in the outbox');
        server.history.add({
          'role': 'assistant',
          'text': 'answer A',
          'content': 'answer A',
          'row_id': server.history.length + 1,
        });
        final lateA = server.publishDeferred(
          'message.complete',
          {'text': 'answer A', 'status': 'complete'},
          'adm-1',
          4,
        );
        server.settleTerminal('adm-1');
        server.deliver(lateA);
        await _until(
          () => server.framesOf('prompt.submit').length == 2,
          what: 'B submitted only after the authoritative A terminal',
          dump: rig.chat,
        );
        // Observed, out of scope here: after an `error` frame the late
        // complete of A is not rendered as answer text by the chat; only the
        // queue hold is pinned by this test.
        expect(server.framesOf('prompt.submit'), hasLength(2));
      }),
    );

    // CHANGES-2: after the interrupt ACK the A terminal is held and the socket
    // is lost; the resume keeps failing, so the ledger is NOT ready (unknown,
    // not closed). An explicit send-now retry while it is unknown must not
    // submit B; once a fresh snapshot/complete proves A closed, B goes once.
    test(
      'B2.8 control (CHANGES-2 window NOT reached on this fixture): interrupt ACKed, A terminal held, socket lost and resumes failing, explicit send-now retry: B is not submitted and stays durable, then goes once after the A terminal',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(await rig.sendDurable('A', 'turn-a'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        expect(
          await rig.chat.enqueuePreparedTurn(
            ActiveTurnDelivery(
              prepared: _queuedPrepared('turn-b', 'B'),
              store: rig.outbox!,
            ),
          ),
          isTrue,
        );
        expect(server.framesOf('prompt.submit'), hasLength(1));
        expect(
          await rig.chat.sendQueuedNow(
            'prepared:turn-b',
            queueIfInterruptUnsupported: true,
          ),
          isTrue,
        );
        expect(server.framesOf('session.interrupt'), hasLength(1));
        await _settle();
        expect(server.framesOf('prompt.submit'), hasLength(1),
            reason: 'precondition: B waits for the A terminal');
        server.failResumes = 3;
        await server.sockets.last.close();
        await _until(
          () => server.framesOf('session.resume').length >= 2,
          what: 'rehydration attempt',
        );
        // Explicit user retry while the ledger is not ready.
        await rig.chat.sendQueuedNow(
          'prepared:turn-b',
          queueIfInterruptUnsupported: true,
        );
        await _settle();
        expect(server.framesOf('prompt.submit'), hasLength(1),
            reason: 'unknown ledger is not proof that A closed: no B submit');
        expect(
          _outboxRowStates(secure).keys.any((k) => k.contains('turn-b')),
          isTrue,
          reason: 'B stays durable',
        );
        server.history.add({
          'role': 'assistant',
          'text': 'answer A',
          'content': 'answer A',
          'row_id': server.history.length + 1,
        });
        final lateA = server.publishDeferred(
          'message.complete',
          {'text': 'answer A', 'status': 'complete'},
          'adm-1',
          4,
        );
        server.settleTerminal('adm-1');
        server.deliver(lateA);
        await _until(
          () => server.framesOf('prompt.submit').length == 2,
          what: 'B submitted only after the authoritative A terminal',
          dump: rig.chat,
        );
        expect(server.framesOf('prompt.submit'), hasLength(2));
      }),
    );

    test(
      'B2.6 send-now with interrupt (sendQueuedNow, queueIfInterruptUnsupported): interrupt ACKed, A terminal held, B waits for it and is never completed by A; A and B once each, B outbox removed once after B final, no resend',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(await rig.sendDurable('A', 'turn-a'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        final now = DateTime.now().millisecondsSinceEpoch;
        final prepared = PreparedTurn(
          connectionId: 'c',
          sessionId: 's',
          clientTurnId: 'turn-b',
          createdAtMs: now,
          updatedAtMs: now,
          text: 'B',
          fullText: 'B',
          desktopText: 'B',
          attachments: const [],
          model: 'm',
          profile: 'default',
          state: PreparedTurnState.prepared,
          queued: true,
        );
        expect(
          await rig.chat.enqueuePreparedTurn(
            ActiveTurnDelivery(prepared: prepared, store: rig.outbox!),
          ),
          isTrue,
        );
        expect(server.framesOf('prompt.submit'), hasLength(1));
        // The row action: interrupt A (ACKed at once by the fake, terminal
        // held) and send B now.
        final sent = await rig.chat.sendQueuedNow(
          'prepared:turn-b',
          queueIfInterruptUnsupported: true,
        );
        expect(sent, isTrue);
        expect(server.framesOf('session.interrupt'), hasLength(1));
        await _settle();
        final submitsBeforeATerminal = server.framesOf('prompt.submit').length;
        // Chosen chronology: B waits for A's terminal. Admitting it `queued`
        // behind A would let A's late terminal (same chat, no per-admission
        // identity) close B's delivery.
        expect(
          submitsBeforeATerminal,
          1,
          reason: 'B is not submitted before the A terminal',
        );
        expect(
          outboxHistory.last.any((id) => id.contains('turn-b')),
          isTrue,
          reason: 'B is not deleted by the interrupt or by A',
        );
        expect(_countText(rig.chat, 'answer B'), 0);
        // A's late terminal.
        server.history.add({
          'role': 'assistant',
          'text': 'answer A',
          'content': 'answer A',
          'row_id': server.history.length + 1,
        });
        final lateA = server.publishDeferred(
          'message.complete',
          {'text': 'answer A', 'status': 'complete'},
          'adm-1',
          4,
        );
        server.settleTerminal('adm-1');
        server.deliver(lateA);
        await _until(
          () => server.framesOf('prompt.submit').length == 2,
          what: 'B submitted after the A terminal',
          dump: rig.chat,
        );
        await _settle();
        expect(
          outboxHistory.last.any((id) => id.contains('turn-b')),
          isTrue,
          reason: 'A terminal does not close B',
        );
        final doneAfterA = rig.doneCount;
        server.startTurn(admission: 'adm-2', gen: 5);
        expect(outboxHistory.last.any((id) => id.contains('turn-b')), isTrue);
        server.completeTurn(text: 'answer B', admission: 'adm-2', gen: 5);
        await _until(
          () => _countText(rig.chat, 'answer B') == 1,
          what: 'B final applied',
          dump: rig.chat,
        );
        await _until(
          () => rig.doneCount > doneAfterA,
          what: 'B own done',
          dump: rig.chat,
        );
        await _settle();
        expect(rig.doneCount, doneAfterA + 1, reason: 'one done for B');
        expect(_countText(rig.chat, 'answer A'), 1);
        expect(_countText(rig.chat, 'answer B'), 1);
        expect(
          server.framesOf('prompt.submit'),
          hasLength(2),
          reason: 'no automatic resend or duplicate submit',
        );
        final removals = [
          for (var i = 1; i < outboxHistory.length; i++)
            if (outboxHistory[i - 1].any((id) => id.contains('turn-b')) &&
                !outboxHistory[i].any((id) => id.contains('turn-b')))
              i,
        ];
        expect(removals, hasLength(1), reason: 'B deleted exactly once');
        expect(outboxHistory.last.any((id) => id.contains('turn-b')), isFalse);
      }),
    );

    test(
      'B7 repeated storage_unavailable: bounded attempts, visible unresolved state, never auth-required, recovers on the next link-up with the outbox intact',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(
          await rig.chat.ensureDesktopRuntime(acquireForExplicitAction: true),
          isTrue,
        );
        final resumes = server.framesOf('session.resume').length;
        server.failResumes = 1000;
        server.publishDeferred('session.info', {'revision': 12});
        server.deliver(server.publishDeferred('session.info', {'x': 1}));
        await _until(
          () => rig.chat.transportStatus.state != ChatTransportState.connected,
          what: 'a visible recovering/offline state',
          timeout: const Duration(seconds: 30),
        );
        // The budget ends: attempts stop (quiet for longer than the largest
        // backoff step) and the state is an honest, retryable offline.
        var lastCount = -1;
        var quietSince = DateTime.now();
        await _until(
          () {
            final count = server.framesOf('session.resume').length - resumes;
            if (count != lastCount) {
              lastCount = count;
              quietSince = DateTime.now();
            }
            return DateTime.now().difference(quietSince) >
                const Duration(seconds: 20);
          },
          what: 'the attempts to stop (budget spent), saw $lastCount',
          timeout: const Duration(seconds: 150),
        );
        final attempts = server.framesOf('session.resume').length - resumes;
        expect(attempts, inInclusiveRange(2, 8), reason: 'bounded: $attempts');
        expect(rig.chat.dashboardAuthRequired, isFalse);
        expect(rig.chat.transportStatus.state, ChatTransportState.offline);
        // The authority answers again and the socket links up: the chat is
        // resynchronized without any send and without losing the outbox.
        server.failResumes = 0;
        await server.sockets.last.close();
        server.startTurn(admission: 'ext-1', gen: 4);
        server.openPrompt(
          server.prompt('clarify', 'p-ext', gen: 4, question: 'Which?'),
        );
        await _until(
          () => rig.chat.needsInput,
          what: 'the chat re-synchronizes after the exhaustion',
          timeout: const Duration(seconds: 60),
        );
        expect(rig.chat.transportStatus.state, ChatTransportState.connected);
        expect(server.framesOf('prompt.submit'), isEmpty);
      }),
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });

  group('B1/B6 production operations on the faithful authority', () {
    test(
      'B1 first message of a brand-new chat creates the session canonically and completes once',
      () => withServer(true, (server) async {
        final rig = await _rig(server, sessionId: 'mob-new');
        addTearDown(rig.dispose);
        expect(await rig.send('hello'), isTrue);
        final create =
            server.framesOf('session.create').single['params'] as Map;
        expect(create['source'], 'gui');
        final submit = server.framesOf('prompt.submit').single['params'] as Map;
        expect(submit['session_id'], 's');
        expect(submit['text'], 'hello');
        final order = server.frames.map((f) => f['method']).toList();
        expect(
          order.indexOf('session.create'),
          lessThan(order.indexOf('prompt.submit')),
        );
        server.startTurn(admission: 'adm-1', gen: 4);
        server.completeTurn(text: 'hi there', admission: 'adm-1', gen: 4);
        await _until(() => rig.doneCount == 1, what: 'done');
        await _settle();
        expect(rig.doneCount, 1);
        expect(_countText(rig.chat, 'hi there'), 1);
        expect(server.framesOf('prompt.submit'), hasLength(1));
      }),
    );

    test(
      'B6 cold viewer open of a LIVE session (active_list lists it): attaches with the canonical resume, never session.activate',
      () => withServer(true, (server) async {
        server.live = true;
        server.running = true;
        server.runningAdmission = 'adm-9';
        server.openPrompt(
          server.prompt('clarify', 'p-1', question: 'Which one?'),
        );
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        expect(await rig.chat.attachExistingRuntimeViewer(), isTrue);
        await _until(() => rig.chat.needsInput, what: 'question restored');
        expect(server.framesOf('session.active_list'), isNotEmpty);
        expect(server.framesOf('session.activate'), isEmpty);
        expect(server.framesOf('session.resume'), hasLength(1));
        expect(server.framesOf('prompt.submit'), isEmpty);
      }),
    );

    test(
      'B1 steering a busy turn carries the execution generation and the busy chat stays on one turn',
      () => withServer(true, (server) async {
        final rig = await _rig(server, kind: InstanceKind.vps);
        addTearDown(rig.dispose);
        expect(await rig.send('A'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        await rig.chat.steer('use blue', interrupt: false);
        final steer = server.framesOf('session.steer').single['params'] as Map;
        expect(steer['execution_generation'], 4);
        expect(steer['text'], 'use blue');
        await rig.chat.steer('switch plan', interrupt: true);
        final redirect =
            server.framesOf('session.redirect').single['params'] as Map;
        expect(redirect['execution_generation'], 4);
        expect(server.framesOf('prompt.submit'), hasLength(1));
        server.completeTurn(text: 'blue done', admission: 'adm-1', gen: 4);
        await _until(() => rig.doneCount == 1, what: 'done');
        await _settle();
        expect(rig.doneCount, 1);
      }),
    );

    test(
      'B3 own-turn recovery: a terminal that arrives while the owner is still reading the transcript is applied, not lost',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(await rig.sendDurable('A', 'turn-a'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        // The transcript reads of the recovery hang until released.
        final gate = Completer<void>();
        server.messagesGate = gate;
        server.beforeReply = (frame) async {
          if (frame['method'] == 'session.history') await gate.future;
        };
        final resumes = server.framesOf('session.resume').length;
        await server.sockets.last.close();
        await _until(
          () => server.framesOf('session.resume').length > resumes,
          what: 'canonical re-attach',
          timeout: const Duration(seconds: 30),
        );
        // Between the cut and the owner applying it, the turn ends.
        server.completeTurn(text: 'final A', admission: 'adm-1', gen: 4);
        await _settle();
        gate.complete();
        await _until(
          () => rig.doneCount == 1,
          what: 'converged on the final',
          timeout: const Duration(seconds: 30),
        );
        await _settle();
        expect(rig.doneCount, 1);
        expect(_countText(rig.chat, 'final A'), 1);
        expect(server.framesOf('prompt.submit'), hasLength(1));
      }),
    );
  });

  group('R2 owner adoption and single recovery owner', () {
    /// Holds every transcript read (REST page and `session.history`).
    Completer<void> holdReads(CanonicalAuthorityServer server) {
      final gate = Completer<void>();
      server.messagesGate = gate;
      server.beforeReply = (frame) async {
        if (frame['method'] == 'session.history') await gate.future;
      };
      return gate;
    }

    Future<void> cut(CanonicalAuthorityServer server) async {
      final resumes = server.framesOf('session.resume').length;
      await server.sockets.last.close();
      await _until(
        () => server.framesOf('session.resume').length > resumes,
        what: 'canonical re-attach (snapshot acquired)',
        timeout: const Duration(seconds: 30),
      );
    }

    for (final kind in const ['terminal', 'terminal-at-cut', 'clarify']) {
      final terminal = kind != 'clarify';
      // `terminal-at-cut`: the frame follows the snapshot reply on the wire
      // (the window the owner-adoption hold exists for); `terminal`: it
      // arrives while the REST/history read is still held, after the chat
      // adopted the resume snapshot.
      final atCut = kind == 'terminal-at-cut';
      test(
        'R2a cold open of a running session: a $kind delivered before the final transcript read lands is applied once, never lost',
        () => withServer(true, (server) async {
          server.history.add({
            'role': 'user',
            'text': 'q',
            'content': 'q',
            'row_id': 1,
          });
          server.running = true;
          server.runningAdmission = 'adm-9';
          // The authority lists the running admission as a started row.
          server.pending.add({
            'admission_id': 'adm-9',
            'ref': {'profile_id': 'default', 'session_id': 's'},
            'sequence': 1,
            'status': 'started',
            'outcome': null,
            'authority_epoch': 7,
            'execution_generation': 3,
            'input_id': 'in-9',
            'text': 'q',
          });
          final snapshotAcquired = Completer<void>();
          void finishTurnA() {
            server.history.add({
              'role': 'assistant',
              'text': 'final cold',
              'content': 'final cold',
              'row_id': server.history.length + 1,
            });
            // Terminal bookkeeping as `completeTurn`: adm-9 leaves pending,
            // running=false, runningAdmission=null, receipt terminal.
            final cold = server.publishDeferred(
              'message.complete',
              {'text': 'final cold', 'status': 'complete'},
              'adm-9',
              3,
            );
            server.settleTerminal('adm-9');
            server.deliver(cold);
          }

          server.afterReply = (frame, result) {
            if (frame['method'] == 'session.resume' &&
                !snapshotAcquired.isCompleted) {
              snapshotAcquired.complete();
              if (atCut) finishTurnA();
            }
          };
          final gate = holdReads(server);
          final rig = await _rig(server);
          addTearDown(rig.dispose);
          // The public cold-open entry ChatScreen uses (chat_screen.dart
          // `_chat.loadMessages(...)`, reaching the ActiveChat resume/REST/
          // adoption section), not an explicit-action acquire.
          final Future<Object?> open = terminal
              ? rig.chat.loadMessages(expectedMessageCount: 1)
              : rig.chat.ensureDesktopRuntime(acquireForExplicitAction: true);
          await snapshotAcquired.future.timeout(const Duration(seconds: 30));
          await _settle();
          if (terminal) {
            if (!atCut) finishTurnA();
          } else {
            server.openPrompt(
              server.prompt('clarify', 'p-hold', gen: 3, question: 'Which?'),
            );
          }
          await _settle();
          // For the terminal the intermediate safety check and the final
          // transcript contract are collected together, so a failed
          // intermediate expectation cannot hide the final state.
          final problems = <String>[];
          if (terminal) {
            // Whether the chat adopted the snapshot before the terminal is
            // decided by the transport (trace `r2a`); the viewer `done` is not
            // the contract. The held-REST interval may never duplicate.
            if (rig.doneCount > 1) {
              problems.add('doneCount=${rig.doneCount} before the read lands');
            }
            if (_countText(rig.chat, 'final cold') > 1) {
              problems.add('final cold duplicated before the read lands');
            }
          } else {
            expect(rig.doneCount, 0, reason: 'nothing adopted yet');
          }
          gate.complete();
          if (terminal) {
            // The viewer `done` is only a trace; the contract is the final
            // transcript row.
            try {
              await _until(
                () => _countText(rig.chat, 'final cold') == 1,
                what: 'the final reaches the cold-opened chat transcript',
                dump: rig.chat,
              );
            } catch (error) {
              problems.add('final wait: $error');
            }
          } else {
            await _until(() => rig.chat.needsInput, what: 'the question');
          }
          try {
            await open;
          } catch (error) {
            if (!terminal) rethrow;
            problems.add('open: $error');
          }
          await _settle();
          if (terminal) {
            if (_countText(rig.chat, 'final cold') != 1) {
              problems.add(
                'final cold count=${_countText(rig.chat, 'final cold')} '
                '(want exactly 1)',
              );
            }
            if (rig.chat.isStreaming) problems.add('still streaming');
            if (rig.chat.needsInput) problems.add('Needs you shown');
            expect(problems, isEmpty, reason: _dump(rig.chat));
          } else {
            expect(rig.chat.needsInput, isTrue);
          }
          expect(server.framesOf('prompt.submit'), isEmpty);
          expect(server.framesOf('clarify.respond'), isEmpty);
        }),
      );
    }

    for (final owned in const [true, false]) {
      test(
        'R2b recovery abandoned by the durable transcript, then a second ${owned ? 'own' : 'external'} turn on the same socket streams its delta BEFORE the final, no orphan hold and no hidden resend',
        () => withServer(true, (server) async {
          final rig = await _rig(server, withOutbox: true);
          addTearDown(rig.dispose);
          expect(await rig.sendDurable('A', 'turn-a'), isTrue);
          server.startTurn(admission: 'adm-1', gen: 4);
          await _until(() => rig.chat.isStreaming, what: 'A streaming');
          final sockets = server.sockets.length;
          await server.sockets.last.close();
          // The authority finished A while nobody was attached.
          server.completeTurn(text: 'final A', admission: 'adm-1', gen: 4);
          await _until(
            () => server.sockets.length > sockets,
            what: 'redial',
            timeout: const Duration(seconds: 30),
          );
          await _until(
            () => rig.doneCount == 1,
            what: 'A converged on the durable transcript',
            timeout: const Duration(seconds: 30),
          );
          await _settle();
          final socketsAfter = server.sockets.length;
          if (owned) {
            expect(await rig.send('B'), isTrue);
            server.startTurn(admission: 'adm-2', gen: 5);
          } else {
            server.startTurn(admission: 'ext-2', gen: 5);
          }
          if (owned) {
            await _until(() => rig.chat.isStreaming, what: 'own turn live');
          } else {
            await _settle();
          }
          server.publish(
            'message.delta',
            {'text': 'partial two'},
            owned ? 'adm-2' : 'ext-2',
            5,
          );
          await _until(
            () => rig.chat.messages.any(
              (m) => '${m['content'] ?? m['text']}'.contains('partial two'),
            ),
            what: 'the delta is shown BEFORE any final',
            dump: rig.chat,
          );
          expect(rig.doneCount, 1);
          server.completeTurn(
            text: 'final two',
            admission: owned ? 'adm-2' : 'ext-2',
            gen: 5,
          );
          await _until(() => rig.doneCount == 2, what: 'second turn done');
          await _settle();
          expect(rig.doneCount, 2);
          expect(_countText(rig.chat, 'final two'), 1);
          expect(server.sockets.length, socketsAfter);
          expect(
            server.framesOf('prompt.submit'),
            hasLength(owned ? 2 : 1),
            reason: 'no hidden resend',
          );
        }),
      );
    }

    test(
      'C3 a stale or snapshot-less adoption cannot release the post-cut terminal held for the recovery attach: only the owner that applies THAT snapshot does, once',
      () => withServer(true, (server) async {
        final client = TuiGatewayClient(
          SavedConnection(
            id: 'c',
            label: 'fixture',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'fixture',
            dashboardUrl: 'http://127.0.0.1:${server.server.port}',
          ),
          dashboard: _TicketDashboardClient(),
          heartbeatInterval: const Duration(hours: 1),
          heartbeatDeadline: const Duration(hours: 2),
        );
        final seen = <TuiGatewayEvent>[];
        final sub = client.events.listen(seen.add, onError: (Object _) {});
        addTearDown(() async {
          await sub.cancel();
          await client.close();
        });
        final service = ActiveChatService(
          compressionRestoreStore: testCompressionRestoreStore(),
        );
        final chat = service.attach(
          connection: _connection(server),
          sessionId: 's',
          sessionTitle: 'fixture',
          desktopGateway: client,
          disableForegroundKeepAlive: true,
          allowUnownedDesktopSnapshotForTesting: true,
        );
        final rig = _Rig(server, service, chat);
        addTearDown(rig.dispose);
        expect(
          await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
          isTrue,
        );
        expect(client.hasCanonicalOwner('s'), isTrue);
        final ledger = client.canonicalLedgerForTesting('s')!;
        await _until(() => !ledger.awaitingAdoption, what: 'attach 1 adopted');
        // The recovery attach 2: its snapshot is held, not yet applied.
        // Same profile as the chat's attach: another profile would build a
        // different ledger (profile isolation) and prove nothing.
        final attach2 = await client.resumeExistingForRecovery(
          's',
          profile: ledger.profile,
        );
        expect(
          identical(client.canonicalLedgerForTesting('s'), ledger),
          isTrue,
          reason: 'attach 2 hydrates the same ledger',
        );
        expect(ledger.awaitingAdoption, isTrue);
        server.startTurn(admission: 'ext-1', gen: 4);
        server.completeTurn(text: 'answer ext', admission: 'ext-1', gen: 4);
        await _settle();
        int completes() =>
            seen.where((e) => e.type == 'message.complete').length;
        expect(completes(), 0, reason: 'held after the cut of attach 2');
        // A stale adoption without a snapshot (another flow of the chat).
        chat.adoptDesktopRuntimeForTesting('s');
        await _settle();
        expect(
          ledger.awaitingAdoption,
          isTrue,
          reason: 'only the owner of the snapshot can commit it',
        );
        expect(completes(), 0, reason: 'the terminal stays held');
        // The owner applies THAT snapshot: released once.
        expect(client.commitCanonicalAdoption(attach2), isTrue);
        await _until(() => completes() == 1, what: 'terminal after adoption');
        await _settle();
        expect(completes(), 1, reason: 'final once');
        expect(ledger.awaitingAdoption, isFalse);
      }),
    );

    // C3 residual (R4 section 7): a cold load obtains the deferred canonical
    // attach, then its authorization is revoked before it adopts the snapshot.
    // The exit must release exactly that attach; otherwise the ledger keeps
    // `awaitingAdoption` and later live frames of the session stay held.
    test(
      'C3 abandoned cold load: authorization revoked after the deferred snapshot and before adoption releases that exact attach; a later live turn is not frozen',
      () => withServer(true, (server) async {
        final client = TuiGatewayClient(
          SavedConnection(
            id: 'c',
            label: 'fixture',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'fixture',
            dashboardUrl: 'http://127.0.0.1:${server.server.port}',
          ),
          dashboard: _TicketDashboardClient(),
          heartbeatInterval: const Duration(hours: 1),
          heartbeatDeadline: const Duration(hours: 2),
        );
        final seen = <TuiGatewayEvent>[];
        final sub = client.events.listen(seen.add, onError: (Object _) {});
        addTearDown(() async {
          await sub.cancel();
          await client.close();
        });
        final privacyEntered = Completer<void>();
        final privacyGate = Completer<void>();
        var visible = true;
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: _connection(server),
          sessionId: 's',
          sessionTitle: 'fixture',
          notifications: null,
          onTerminal: () {},
          api: testApiClient(
            baseUrl: 'https://example.invalid',
            httpClient: MockClient(
              (_) async => http.Response('{"messages":[]}', 200),
            ),
          ),
          desktopGateway: client,
          attachDesktopRuntimeOnLoad: true,
          allowUnownedDesktopSnapshotForTesting: true,
          beforePrivacySnapshotLoad: () async {
            if (!privacyEntered.isCompleted) privacyEntered.complete();
            await privacyGate.future;
          },
        );
        addTearDown(chat.dispose);
        final loading = chat.loadMessages(stillOwningVisible: () => visible);
        await privacyEntered.future;
        final held = await _tryUntil(
          () => client.canonicalLedgerForTesting('s')?.awaitingAdoption == true,
          timeout: const Duration(seconds: 5),
        );
        visible = false;
        privacyGate.complete();
        await loading;
        await _settle();
        final ledger = client.canonicalLedgerForTesting('s');
        expect(held, isTrue,
            reason: 'precondition: the cold load holds a deferred attach');
        expect(ledger, isNotNull);
        expect(
          ledger!.awaitingAdoption,
          isFalse,
          reason: 'the abandoned load released its exact attach',
        );
        // The release leaves the ledger fail-closed until the next explicit
        // attach (by design); the next explicit attach is not frozen and the
        // live stream is followed again.
        expect(
          await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
          isTrue,
        );
        await _until(
          () => !ledger.awaitingAdoption && ledger.isSendReady,
          what: 'next explicit attach adopted',
        );
        server.startTurn(admission: 'ext-1', gen: 4);
        server.completeTurn(text: 'answer ext', admission: 'ext-1', gen: 4);
        await _until(
          () => seen.where((e) => e.type == 'message.complete').length == 1,
          what: 'a later live terminal is delivered, not held',
        );
      }),
    );

    // Overlapping authorized cold loads: the stale
    // first load's cleanup must not disturb the adoption of the second.
    for (final mode in const [0, 1, 2]) {
      final overlap = mode == 0;
      final sendLocal = mode == 2;
      test(
        overlap
            ? 'C3b overlapping authorized cold loads: the superseded load releases only its own attach; the adopted second load keeps following live turns'
            : sendLocal
                ? 'C3d a local send immediately after an idle cold load submits once without an external turn'
                : 'C3c single authorized cold load follows a later external turn without an explicit attach',
        () => withServer(true, (server) async {
          server.live = true;
          server.history.add({
            'role': 'assistant',
            'text': 'previous answer',
            'content': 'previous answer',
            'row_id': 1,
          });
          final client = TuiGatewayClient(
            SavedConnection(
              id: 'c',
              label: 'fixture',
              host: '127.0.0.1',
              port: 8642,
              apiKey: 'fixture',
              dashboardUrl: 'http://127.0.0.1:${server.server.port}',
            ),
            dashboard: _TicketDashboardClient(),
            heartbeatInterval: const Duration(hours: 1),
            heartbeatDeadline: const Duration(hours: 2),
          );
          final seen = <TuiGatewayEvent>[];
          final sub = client.events.listen(seen.add, onError: (Object _) {});
          addTearDown(() async {
            await sub.cancel();
            await client.close();
          });
          await client.connect();
          final firstEntered = Completer<void>();
          final firstGate = Completer<void>();
          final secondGate = Completer<void>();
          var privacyCalls = 0;
          const visible = true;
          final chat = ActiveChat(
            compressionRestoreStore: testCompressionRestoreStore(),
            connection: _connection(server),
            sessionId: 's',
            sessionTitle: 'fixture',
            notifications: null,
            onTerminal: () {},
            api: testApiClient(
              baseUrl: 'https://example.invalid',
              httpClient: MockClient(
                (_) async => http.Response(
                  jsonEncode({'messages': server.history}),
                  200,
                ),
              ),
            ),
            desktopGateway: client,
            attachDesktopRuntimeOnLoad: true,
            beforePrivacySnapshotLoad: () async {
              // Observe each transport cut before releasing its privacy read.
              if (++privacyCalls != 1) {
                await secondGate.future;
                return;
              }
              firstEntered.complete();
              await firstGate.future;
            },
          );
          addTearDown(chat.dispose);
          final first = chat.loadMessages(stillOwningVisible: () => visible);
          addTearDown(() async {
            if (!firstGate.isCompleted) firstGate.complete();
            if (!secondGate.isCompleted) secondGate.complete();
            await first;
          });
          await _until(
            () => firstEntered.isCompleted,
            what: 'first authorized load entered the privacy read',
            dump: chat,
          );
          await _until(
            () => client.canonicalLedgerForTesting('s')?.awaitingAdoption == true,
            what: 'first load holds a deferred attach',
          );
          final ledger = client.canonicalLedgerForTesting('s')!;
          final firstToken = ledger.adoptionToken;
          expect(firstToken, greaterThan(0));
          if (overlap) {
            final second = chat.loadMessages(stillOwningVisible: () => visible);
            // Privacy reads start before the resume; observe the second cut only
            // after the transport has installed its distinct adoption token.
            await _until(
              () => ledger.awaitingAdoption && ledger.adoptionToken != firstToken,
              what: 'second load holds a distinct deferred attach',
              dump: chat,
            );
            final secondToken = ledger.adoptionToken;
            secondGate.complete();
            await second;
            expect(secondToken, isNotNull);
            expect(secondToken, greaterThan(0));
            expect(secondToken, isNot(firstToken));
            await _until(
              () => !ledger.awaitingAdoption && ledger.isSendReady,
              what: 'second load adopted',
            );
          }
          firstGate.complete();
          await first;
          await _settle();
          expect(identical(client.canonicalLedgerForTesting('s'), ledger), isTrue);
          expect(ledger.awaitingAdoption, isFalse);
          expect(ledger.isSendReady, isTrue);
          expect(ledger.snapshotRequiredReason, isNull);
          expect(_countText(chat, 'previous answer'), 1);
          if (sendLocal) {
            expect(
              await chat.send(fullText: 'local prompt', model: 'm', history: const []),
              isTrue,
            );
            expect(server.framesOf('prompt.submit'), hasLength(1));
            expect(
              chat.messages.where((message) => message['_pipeline'] == true),
              hasLength(1),
            );
            final params = server.framesOf('prompt.submit').single['params'] as Map;
            final receipt = server.receipts[params['submission_id']]!;
            final admission = receipt['admission_id'] as String;
            server.startTurn(admission: admission, gen: 4);
            await _until(
              () => seen.any((event) => event.type == 'message.start'),
              what: 'own start received after cold load',
            );
            await _settle();
            expect(
              chat.messages.where((message) => message['_pipeline'] == true),
              hasLength(1),
            );
            server.completeTurn(text: 'local answer', admission: admission, gen: 4);
            await _until(
              () => _countText(chat, 'local answer') == 1,
              what: 'own final after cold load',
              dump: chat,
            );
            await _settle();
            expect(_countText(chat, 'local answer'), 1);
            expect(_countText(chat, 'previous answer'), 1);
            expect(server.framesOf('prompt.submit'), hasLength(1));
            expect(server.framesOf('clarify.respond'), isEmpty);
            expect(server.framesOf('approval.respond'), isEmpty);
            return;
          }
          server.startTurn(admission: 'ext-1', gen: 4);
          await _until(
            () => chat.isStreaming &&
                chat.messages.any((message) => message['_pipeline'] == true),
            what: 'external turn opens its own pipeline boundary',
            dump: chat,
          );
          server.completeTurn(text: 'answer ext', admission: 'ext-1', gen: 4);
          await _until(
            () => _countText(chat, 'answer ext') == 1,
            what: 'remote final in the transcript',
            dump: chat,
          );
          await _settle();
          expect(_countText(chat, 'answer ext'), 1);
          expect(_countText(chat, 'previous answer'), 1);
          expect(
            seen.where((event) => event.type == 'message.complete'),
            hasLength(1),
          );
          expect(server.framesOf('prompt.submit'), isEmpty);
          expect(server.framesOf('clarify.respond'), isEmpty);
          expect(server.framesOf('approval.respond'), isEmpty);
          expect(server.framesOf('session.resume'), hasLength(overlap ? 2 : 1));
        }),
      );
    }

    test(
      'R2c more than 256 deltas while the owner adoption read is held, then the terminal: one final, bounded resumes, nothing lost',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(await rig.sendDurable('A', 'turn-a'), isTrue);
        server.startTurn(admission: 'adm-1', gen: 4);
        await _until(() => rig.chat.isStreaming, what: 'A streaming');
        final gate = holdReads(server);
        final resumes = server.framesOf('session.resume').length;
        await cut(server);
        for (var i = 0; i < 300; i++) {
          server.publish('message.delta', {'text': 'd$i '}, 'adm-1', 4);
        }
        server.completeTurn(text: 'final A', admission: 'adm-1', gen: 4);
        await _settle();
        gate.complete();
        await _until(
          () => rig.doneCount == 1,
          what: 'one final after the overflow',
          timeout: const Duration(seconds: 30),
        );
        await _settle();
        expect(rig.doneCount, 1);
        expect(_countText(rig.chat, 'final A'), 1);
        expect(server.framesOf('prompt.submit'), hasLength(1));
        expect(
          server.framesOf('session.resume').length - resumes,
          lessThanOrEqualTo(3),
          reason: 'bounded resumes',
        );
      }),
    );

    test(
      'R2d idle viewer sequence gap: exactly one recovery owner and one new resume, and the next question still arrives',
      () => withServer(true, (server) async {
        final rig = await _rig(server, withOutbox: true);
        addTearDown(rig.dispose);
        expect(
          await rig.chat.ensureDesktopRuntime(acquireForExplicitAction: true),
          isTrue,
        );
        final resumes = server.framesOf('session.resume').length;
        final sockets = server.sockets.length;
        final hold = Completer<void>();
        server.beforeReply = (frame) async {
          if (frame['method'] == 'session.resume') await hold.future;
        };
        server.publishDeferred('session.info', {'revision': 12});
        server.publishDeferred('session.info', {'revision': 13});
        server.deliver(server.publishDeferred('session.info', {'x': 1}));
        await _until(
          () => server.framesOf('session.resume').length > resumes,
          what: 'the recovery resume',
          timeout: const Duration(seconds: 30),
        );
        await _settle();
        await _settle();
        expect(
          server.framesOf('session.resume').length - resumes,
          1,
          reason: 'one recovery owner while its resume is in flight',
        );
        hold.complete();
        server.startTurn(admission: 'ext-1', gen: 4);
        server.openPrompt(
          server.prompt('clarify', 'p-ext', gen: 4, question: 'Which?'),
        );
        await _until(
          () => rig.chat.needsInput,
          what: 'the question after the single recovery',
          timeout: const Duration(seconds: 30),
        );
        await _settle();
        expect(server.framesOf('session.resume').length - resumes, 1);
        expect(server.sockets.length, sockets);
        expect(server.framesOf('prompt.submit'), isEmpty);
      }),
    );
  });

  group('remote live turn (another surface)', () {
    // A viewer attached idle that follows ext-1 and then loses its socket.
    Future<_Rig> followThenDrop(
      CanonicalAuthorityServer server, {
      void Function()? whileDown,
    }) async {
      server.live = true;
      server.history.add({
        'role': 'assistant',
        'text': 'previous answer',
        'content': 'previous answer',
        'row_id': 1,
      });
      final rig = await _rig(server);
      addTearDown(rig.dispose);
      await rig.chat.loadMessages(expectedMessageCount: 1);
      await _until(
        () => rig.chat.desktopRuntimeSessionId != null,
        what: 'idle viewer attached',
        dump: rig.chat,
      );
      await _settle();
      server.startTurn(admission: 'ext-1', gen: 4);
      server.publish('message.delta', {'text': 'uno'}, 'ext-1', 4);
      await _until(
        () => rig.chat.assistantContent.contains('uno'),
        what: 'remote delta before the drop',
        dump: rig.chat,
      );
      final sockets = server.sockets.length;
      final resumes = server.framesOf('session.resume').length;
      await server.sockets.last.close();
      whileDown?.call();
      await _until(
        () =>
            server.sockets.length > sockets &&
            server.framesOf('session.resume').length > resumes,
        what: 'redial and re-attach',
        timeout: const Duration(seconds: 30),
      );
      await _settle();
      await _settle();
      return rig;
    }

    test(
      'RL3 deltas lost while the socket was down leave no stale partial: the final shows once, one extra resume, not connecting',
      () => withServer(true, (server) async {
        final resumesBefore = server.framesOf('session.resume').length;
        final rig = await followThenDrop(
          server,
          whileDown: () =>
              server.publish('message.delta', {'text': ' perdido'}, 'ext-1', 4),
        );
        final resumesAfterRejoin = server.framesOf('session.resume').length;
        expect(rig.chat.desktopRuntimeSessionId, isNotNull);
        expect(rig.chat.state, isNot(ChatPipelineState.connecting));
        expect(rig.chat.isStreaming, isTrue);
        server.publish('message.delta', {'text': ' dos'}, 'ext-1', 4);
        await _until(
          () => rig.chat.assistantContent.contains('dos'),
          what: 'delta after rejoin',
          dump: rig.chat,
        );
        server.completeTurn(
          text: 'uno perdido dos',
          admission: 'ext-1',
          gen: 4,
        );
        await _until(() => !rig.chat.isStreaming, what: 'end', dump: rig.chat);
        await _settle();
        await _settle();
        expect(
          _countText(rig.chat, 'uno perdido dos'),
          1,
          reason: _dump(rig.chat),
        );
        expect(
          rig.chat.messages.where(
            (m) =>
                '${m['content'] ?? m['text']}'.startsWith('uno') &&
                '${m['content'] ?? m['text']}' != 'uno perdido dos',
          ),
          isEmpty,
          reason: 'no stale partial bubble: ${_dump(rig.chat)}',
        );
        expect(_countText(rig.chat, 'previous answer'), 1);
        expect(rig.doneCount, lessThanOrEqualTo(1));
        expect(
          server.framesOf('session.resume').length,
          resumesAfterRejoin,
          reason: 'no further resume after the rejoin',
        );
        expect(
          resumesAfterRejoin - resumesBefore,
          2,
          reason: 'open + one rejoin',
        );
        expect(server.framesOf('prompt.submit'), isEmpty);
      }),
    );

    test(
      'RL4 the turn followed before the cut ended and another started meanwhile: no merged or duplicated bubble once the second ends',
      () => withServer(true, (server) async {
        final rig = await followThenDrop(
          server,
          whileDown: () {
            server.completeTurn(text: 'final A', admission: 'ext-1', gen: 4);
            server.history.add({
              'role': 'user',
              'text': 'pregunta B',
              'content': 'pregunta B',
              'row_id': server.history.length + 1,
            });
            server.startTurn(admission: 'ext-2', gen: 5);
          },
        );
        server.publish('message.delta', {'text': 'parcial B'}, 'ext-2', 5);
        await _settle();
        server.completeTurn(text: 'final B', admission: 'ext-2', gen: 5);
        await _until(() => !rig.chat.isStreaming, what: 'end', dump: rig.chat);
        await _settle();
        // ChatScreen reads the durable store once the turn ends.
        // The durable store is the authority once the turn ended.
        await rig.chat.loadMessages();
        await _until(
          () => _countText(rig.chat, 'final A') == 1,
          what: 'durable A after the end',
          dump: rig.chat,
          timeout: const Duration(seconds: 10),
        );
        await _settle();
        await _settle();
        expect(_countText(rig.chat, 'final A'), 1, reason: _dump(rig.chat));
        expect(_countText(rig.chat, 'final B'), 1, reason: _dump(rig.chat));
        expect(_countText(rig.chat, 'pregunta B'), lessThanOrEqualTo(1));
        expect(
          rig.chat.messages.where((m) {
            final t = '${m['content'] ?? m['text']}';
            return t.contains('uno') || t.contains('parcial B');
          }),
          isEmpty,
          reason: 'no merged/stale bubble: ${_dump(rig.chat)}',
        );
      }),
    );

    test(
      'RL5 the other surface goes away without a terminal frame: the rejoined viewer settles from the roster, no loop',
      () => withServer(true, (server) async {
        final rig = await followThenDrop(server);
        final resumes = server.framesOf('session.resume').length;
        expect(rig.chat.desktopRuntimeSessionId, isNotNull);
        await rig.chat.refreshPassiveRemoteActivity();
        server.running = false;
        server.runningAdmission = null;
        server.live = false;
        for (var i = 0; i < 4 && rig.chat.isStreaming; i++) {
          await rig.chat.refreshPassiveRemoteActivity();
          await _settle();
        }
        expect(rig.chat.isStreaming, isFalse, reason: _dump(rig.chat));
        await _settle();
        expect(server.framesOf('session.resume').length, resumes);
        expect(server.framesOf('prompt.submit'), isEmpty);
      }),
    );

    test(
      'RL6 backgrounded mid-turn with the socket parked: on resume the viewer paints the rest of the other surface\'s turn, final once',
      () => withServer(true, (server) async {
        server.live = true;
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        await rig.chat.loadMessages();
        await _until(
          () => rig.chat.desktopRuntimeSessionId != null,
          what: 'idle viewer attached',
          dump: rig.chat,
        );
        await _settle();
        server.startTurn(admission: 'ext-1', gen: 4);
        server.publish('message.delta', {'text': 'uno'}, 'ext-1', 4);
        await _until(
          () => rig.chat.assistantContent.contains('uno'),
          what: 'remote delta before background',
          dump: rig.chat,
        );
        rig.chat.didChangeAppLifecycleState(AppLifecycleState.paused);
        await server.sockets.last.close();
        await _settle();
        server.publish('message.delta', {'text': ' fondo'}, 'ext-1', 4);
        final resumes = server.framesOf('session.resume').length;
        rig.chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await _until(
          () => server.framesOf('session.resume').length > resumes,
          what: 'resume after foreground',
          timeout: const Duration(seconds: 30),
        );
        await _settle();
        await _settle();
        server.publish('message.delta', {'text': ' dos'}, 'ext-1', 4);
        await _until(
          () => rig.chat.assistantContent.contains('dos'),
          what: 'delta after resume',
          dump: rig.chat,
        );
        server.completeTurn(text: 'uno fondo dos', admission: 'ext-1', gen: 4);
        await _until(() => !rig.chat.isStreaming, what: 'end', dump: rig.chat);
        await _settle();
        expect(
          _countText(rig.chat, 'uno fondo dos'),
          1,
          reason: _dump(rig.chat),
        );
        expect(server.framesOf('prompt.submit'), isEmpty);
      }),
    );

    test(
      'RL2 a chat opened while another surface\'s turn runs paints its deltas and its final once',
      () => withServer(true, (server) async {
        server.live = true;
        server.history.add({
          'role': 'user',
          'text': 'hola',
          'content': 'hola',
          'row_id': 1,
        });
        server.startTurn(admission: 'ext-1', gen: 4);
        server.publish('message.delta', {'text': 'uno'}, 'ext-1', 4);
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        await rig.chat.loadMessages(expectedMessageCount: 1);
        await _until(
          () => rig.chat.desktopRuntimeSessionId != null,
          what: 'attached',
          dump: rig.chat,
        );
        await _settle();
        server.publish('message.delta', {'text': ' dos'}, 'ext-1', 4);
        await _until(
          () => rig.chat.assistantContent.contains('dos'),
          what: 'remote delta after open',
          dump: rig.chat,
        );
        server.completeTurn(text: 'uno dos tres', admission: 'ext-1', gen: 4);
        await _until(() => !rig.chat.isStreaming, what: 'end', dump: rig.chat);
        await _settle();
        expect(
          _countText(rig.chat, 'uno dos tres'),
          1,
          reason: _dump(rig.chat),
        );
      }),
    );
    test(
      'RL1 a viewer following another surface\'s turn keeps painting it after its socket drops mid-turn',
      () => withServer(true, (server) async {
        server.live = true;
        server.history.add({
          'role': 'assistant',
          'text': 'previous answer',
          'content': 'previous answer',
          'row_id': 1,
        });
        final rig = await _rig(server);
        addTearDown(rig.dispose);
        await rig.chat.loadMessages(expectedMessageCount: 1);
        await _until(
          () => rig.chat.desktopRuntimeSessionId != null,
          what: 'idle viewer attached',
          dump: rig.chat,
        );
        await _settle();
        server.startTurn(admission: 'ext-1', gen: 4);
        server.publish('message.delta', {'text': 'uno'}, 'ext-1', 4);
        await _until(
          () => rig.chat.assistantContent.contains('uno'),
          what: 'remote delta before the drop',
          dump: rig.chat,
        );
        final sockets = server.sockets.length;
        final resumes = server.framesOf('session.resume').length;
        await server.sockets.last.close();
        await _until(
          () =>
              server.sockets.length > sockets &&
              server.framesOf('session.resume').length > resumes,
          what: 'redial and re-attach',
          timeout: const Duration(seconds: 30),
        );
        await _settle();
        await _settle();
        server.publish('message.delta', {'text': ' dos'}, 'ext-1', 4);
        await _until(
          () => rig.chat.assistantContent.contains('dos'),
          what: 'remote delta after the drop',
          dump: rig.chat,
        );
        server.completeTurn(text: 'uno dos tres', admission: 'ext-1', gen: 4);
        await _until(() => !rig.chat.isStreaming, what: 'end', dump: rig.chat);
        await _settle();
        expect(
          _countText(rig.chat, 'uno dos tres'),
          1,
          reason: _dump(rig.chat),
        );
      }),
    );
  });
}
