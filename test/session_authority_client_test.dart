// SPDX-License-Identifier: MIT
//
// The real TuiGatewayClient against the source-faithful canonical fake:
// per-connection capability, snapshot cut, hydration before submit, frame
// fences on the event stream, and explicit refusal of unsupported operations.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_authority.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/canonical_authority_server.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'fixture');
}

class _RealHttp extends HttpOverrides {}

TuiGatewayClient _client(CanonicalAuthorityServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'authority-client',
    label: 'Authority client',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'fixture',
    dashboardUrl: 'http://127.0.0.1:${server.server.port}',
  ),
  dashboard: _TicketDashboardClient(),
  heartbeatInterval: const Duration(hours: 1),
  heartbeatDeadline: const Duration(hours: 2),
);

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 120));

void main() {
  Future<void> withClient(
    Future<void> Function(
      CanonicalAuthorityServer server,
      TuiGatewayClient client,
      List<TuiGatewayEvent> events,
      List<Object> errors,
    )
    body, {
    Object? advertise = true,
  }) => HttpOverrides.runZoned(() async {
    final server = await CanonicalAuthorityServer.start(advertise: advertise);
    addTearDown(server.close);
    final client = _client(server);
    final events = <TuiGatewayEvent>[];
    final errors = <Object>[];
    final sub = client.events.listen(events.add, onError: errors.add);
    addTearDown(() async {
      await sub.cancel();
      await client.close();
    });
    await body(server, client, events, errors);
  }, createHttpClient: _RealHttp().createHttpClient);

  test(
    'capability is read per connection and reset on redial to another backend',
    () => withClient((server, client, events, errors) async {
      expect(client.sessionAuthority, SessionAuthorityCapability.unknown);
      final first = await client.resumeExisting('s');
      expect(client.sessionAuthority, SessionAuthorityCapability.supported);
      expect(first.runtimeSessionId, 's');
      expect(client.canonicalLedgerForTesting('s')?.isReady, isTrue);

      // The endpoint behind the same address is now a standalone serve.
      server.advertise = 'absent';
      server.legacyBackend = true;
      await server.sockets.last.close();
      await _tick();
      await client.connectForeground();
      expect(client.sessionAuthority, SessionAuthorityCapability.unsupported);
      expect(
        client.canonicalLedgerForTesting('s'),
        isNull,
        reason: 'ledgers die with the connection',
      );
      final legacy = await client.resumeExisting('s');
      expect(legacy.runtimeSessionId, 'runtime-legacy');

      // And back: a malformed announcement is not canonical either.
      server.advertise = 'yes';
      await server.sockets.last.close();
      await _tick();
      await client.connectForeground();
      expect(client.sessionAuthority, SessionAuthorityCapability.malformed);
      expect(client.usesCanonicalSessions, isFalse);
      server.advertise = true;
      server.legacyBackend = false;
      await server.sockets.last.close();
      await _tick();
      await client.connectForeground();
      expect(client.sessionAuthority, SessionAuthorityCapability.supported);
    }),
  );

  test(
    'profile isolation: another profile never reuses the ledger and every control carries its profile',
    () => withClient((server, client, events, errors) async {
      await client.resumeExisting('s', profile: 'work');
      server.prompts.add(server.prompt('approval', 'ap-w'));
      final first = client.canonicalLedgerForTesting('s')!;
      expect(first.profile, 'work');
      await client.resumeExisting('s', profile: 'home');
      final second = client.canonicalLedgerForTesting('s')!;
      expect(identical(first, second), isFalse);
      expect(second.profile, 'home');
      await client.submitPrompt('s', 'hi');
      final submit = server.framesOf('prompt.submit').single['params'] as Map;
      expect(submit['profile'], 'home');
      expect(
        server
            .framesOf('session.resume')
            .map((f) => (f['params'] as Map)['profile']),
        ['work', 'home'],
      );
    }),
  );

  test(
    'connected is not hydrated: submit before a snapshot is refused locally',
    () => withClient((server, client, events, errors) async {
      await client.connectForeground();
      await expectLater(
        client.submitPrompt('s', 'too early'),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (e) => e.reason,
            'reason',
            'session_not_hydrated',
          ),
        ),
      );
      expect(server.framesOf('prompt.submit'), isEmpty);
    }),
  );

  test(
    'frames of a resume race are held, ordered after the cut, and older ones dropped',
    () => withClient((server, client, events, errors) async {
      server.running = true;
      server.runningAdmission = 'adm-9';
      server.duringResume = () {
        // seq 1 is inside the cut? No: the cut was taken first, so both are newer.
        server.publish('message.delta', {'text': 'one'});
        server.publish('message.delta', {'text': 'two'});
      };
      await client.resumeExisting('s');
      await _tick();
      expect(
        events
            .where((e) => e.type == 'message.delta')
            .map((e) => e.payload['text']),
        ['one', 'two'],
      );
      expect(client.canonicalLedgerForTesting('s')!.watermark, 2);
    }),
  );

  test(
    'strict adoption requires a current deferred snapshot, not a no-op or stale commit',
    () => withClient((server, client, events, errors) async {
      final standalone = await client.resumeExisting('s');
      expect(client.commitCanonicalAdoption(standalone), isTrue);
      expect(
        client.commitCanonicalAdoption(standalone, requirePending: true),
        isFalse,
      );
      client.claimCanonicalOwner('s', Object());
      final first = await client.resumeExisting('s');
      final second = await client.resumeExisting('s');
      expect(client.commitCanonicalAdoption(first, requirePending: true), isFalse);
      expect(client.commitCanonicalAdoption(second, requirePending: true), isTrue);
      expect(client.commitCanonicalAdoption(second, requirePending: true), isFalse);
      expect(client.canonicalLedgerForTesting('s')!.isSendReady, isTrue);
      expect(errors, isEmpty);
    }),
  );

  test(
    'R2 owned session: the attach is held until the owner commits THAT snapshot; a stale commit and a release are safe',
    () => withClient((server, client, events, errors) async {
      final owner = Object();
      client.claimCanonicalOwner('s', owner);
      server.running = true;
      server.runningAdmission = 'adm-9';
      server.duringResume = () {
        server.publish('message.delta', {'text': 'one'});
      };
      final first = await client.resumeExisting('s');
      await _tick();
      expect(events.where((e) => e.type == 'message.delta'), isEmpty);
      final ledger = client.canonicalLedgerForTesting('s')!;
      expect(ledger.awaitingAdoption, isTrue);
      expect(ledger.isSendReady, isFalse, reason: 'ready is not send-ready');
      await expectLater(
        client.submitPrompt('s', 'x'),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (e) => e.reason,
            'reason',
            'session_not_hydrated',
          ),
        ),
      );
      // A newer attach supersedes the first: the first owner is stale.
      server.duringResume = null;
      final second = await client.resumeExisting('s');
      expect(client.commitCanonicalAdoption(first), isFalse);
      expect(ledger.awaitingAdoption, isTrue);
      expect(client.commitCanonicalAdoption(second), isTrue);
      await _tick();
      expect(ledger.awaitingAdoption, isFalse);
      expect(ledger.isSendReady, isTrue);
      // Releasing an attach nobody adopted fail-closes it, silently.
      final third = await client.resumeExisting('s');
      server.publish('message.delta', {'text': 'held then dropped'});
      await _tick();
      client.releaseCanonicalAdoption(third);
      await _tick();
      expect(ledger.awaitingAdoption, isFalse);
      expect(ledger.isReady, isFalse);
      expect(
        events.where((e) => '${e.payload['text']}' == 'held then dropped'),
        isEmpty,
      );
      expect(errors, isEmpty, reason: 'a release asks for no re-attach');
    }),
  );

  test(
    'R2 one recovery owner: with an owner the client never re-attaches by itself, and re-attaches once when the owner asks',
    () => withClient((server, client, events, errors) async {
      final owner = Object();
      client.claimCanonicalOwner('s', owner);
      await client.resumeExisting('s');
      client.commitCanonicalAdoption(
        await client.resumeExisting('s', omitMessages: true),
      );
      final resumes = server.framesOf('session.resume').length;
      server.publishDeferred('session.info', {'revision': 12});
      server.deliver(server.publishDeferred('session.info', {'x': 1}));
      await _tick();
      await _tick();
      expect(errors, hasLength(1), reason: 'the owner is told');
      expect(
        server.framesOf('session.resume').length,
        resumes,
        reason: 'the client did not start a second recovery',
      );
      client.reattachCanonicalForOwner('s');
      await _tick();
      await _tick();
      expect(server.framesOf('session.resume').length, resumes + 1);
      expect(client.canonicalLedgerForTesting('s')!.isReady, isTrue);
      // The owner goes away: the standalone duty is back.
      client.releaseCanonicalOwner(owner);
      expect(client.hasCanonicalOwner('s'), isFalse);
      final again = server.framesOf('session.resume').length;
      server.publishDeferred('session.info', {'revision': 30});
      server.deliver(server.publishDeferred('session.info', {'x': 2}));
      await _tick();
      await _tick();
      expect(server.framesOf('session.resume').length, again + 1);
    }),
  );

  test(
    'replay failure: an unproven frame is withheld, submit waits for the new snapshot, then the client re-attaches itself',
    () => withClient((server, client, events, errors) async {
      await client.resumeExisting('s');
      final hold = Completer<void>();
      server.beforeReply = (frame) async {
        if (frame['method'] == 'session.resume') await hold.future;
      };
      server.replayEpoch = 'ring-2'; // the ring was rebuilt under us
      server.publish('message.delta', {'text': 'from another stream'});
      await _tick();
      expect(events.where((e) => e.type == 'message.delta'), isEmpty);
      expect(
        errors.single,
        isA<TuiGatewayRpcError>().having(
          (e) => e.data['session_id'],
          'session',
          's',
        ),
      );
      await expectLater(
        client.submitPrompt('s', 'x'),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (e) => e.reason,
            'reason',
            'session_not_hydrated',
          ),
        ),
      );
      expect(
        server.framesOf('prompt.submit'),
        isEmpty,
        reason: 'nothing was lost or sent',
      );
      hold.complete();
      await _tick();
      final ledger = client.canonicalLedgerForTesting('s')!;
      expect(ledger.isReady, isTrue);
      expect(ledger.replayEpoch, 'ring-2');
      await client.submitPrompt('s', 'x');
      expect(server.framesOf('prompt.submit'), hasLength(1));
    }),
  );

  test(
    'frames of a session that was never attached on this connection are ignored',
    () => withClient((server, client, events, errors) async {
      await client.connect();
      server.subscribed = true;
      server.publish('message.delta', {'text': 'stranger'});
      await _tick();
      expect(events.where((e) => e.type == 'message.delta'), isEmpty);
      expect(errors, isEmpty);
    }),
  );

  test(
    'a sequence hole is never bridged: the frame after it is withheld and the cut comes from a snapshot',
    () => withClient((server, client, events, errors) async {
      await client.resumeExisting('s');
      final cut = client.canonicalLedgerForTesting('s')!.watermark;
      server.stamp('message.delta', {'text': 'lost'}); // never delivered
      server.publish('message.delta', {'text': 'after the hole'});
      await _tick();
      expect(events.where((e) => e.type == 'message.delta'), isEmpty);
      expect(errors, hasLength(1));
      expect(server.framesOf('session.resume'), hasLength(2));
      final ledger = client.canonicalLedgerForTesting('s')!;
      expect(ledger.watermark, server.seq, reason: 'proven by the snapshot');
      expect(ledger.watermark, greaterThan(cut + 1));
    }),
  );

  test(
    'R1 on the event stream: A terminal after B\'s ack is not projected, B closes once',
    () => withClient((server, client, events, errors) async {
      await client.resumeExisting('s');
      await client.submitPrompt('s', 'A');
      server.startTurn(admission: 'adm-1', gen: 4);
      await client.submitPrompt('s', 'B'); // followed turn, queued behind A
      server.publish('message.complete', {'text': 'answer A'}, 'adm-1', 4);
      server.settleTerminal('adm-1');
      await _tick();
      expect(events.where((e) => e.type == 'message.complete'), isEmpty);
      server.startTurn(admission: 'adm-2', gen: 5);
      server.completeTurn(text: 'answer B', admission: 'adm-2', gen: 5);
      await _tick();
      expect(events.where((e) => e.type == 'message.complete'), hasLength(1));
      expect(
        events
            .where((e) => e.type == 'message.complete')
            .single
            .payload['text'],
        'answer B',
      );
    }),
  );

  test(
    'B2.5 client-level: B admitted queued (queued:true) before the A terminal; A terminal projected once, B starts and closes once, exactly two submits',
    () => withClient((server, client, events, errors) async {
      await client.resumeExisting('s');
      await client.submitPrompt('s', 'A');
      server.startTurn(admission: 'adm-1', gen: 4);
      final queued = await client.submitQueuedPromptIdempotent(
        's',
        'B',
        'turn-b',
      );
      expect(queued.state, DesktopTurnState.accepted);
      expect(
        [for (final p in server.pending) p['status']],
        contains('queued'),
        reason: 'B admitted queued behind the running A',
      );
      expect(server.framesOf('prompt.submit'), hasLength(2));
      // Terminal bookkeeping of A as `completeTurn`; the queued adm-2 stays.
      server.publish('message.complete', {'text': 'answer A'}, 'adm-1', 4);
      server.settleTerminal('adm-1');
      await _tick();
      expect(
        [for (final p in server.pending) p['admission_id']],
        ['adm-2'],
      );
      expect(
        [
          for (final e in events)
            if (e.type == 'message.complete') e.payload['text'],
        ],
        ['answer A'],
        reason: 'A terminal projected once while B is only queued',
      );
      server.startTurn(admission: 'adm-2', gen: 5);
      server.completeTurn(text: 'answer B', admission: 'adm-2', gen: 5);
      await _tick();
      expect(
        [
          for (final e in events)
            if (e.type == 'message.complete') e.payload['text'],
        ],
        ['answer A', 'answer B'],
      );
      expect(server.framesOf('prompt.submit'), hasLength(2));
      expect(errors, isEmpty);
    }),
  );

  test(
    'legitimate terminal without message.start is projected exactly once',
    () => withClient((server, client, events, errors) async {
      await client.resumeExisting('s');
      server.publish('message.complete', {'text': 'muted turn'}, 'adm-x', 4);
      await _tick();
      expect(events.where((e) => e.type == 'message.complete'), hasLength(1));
    }),
  );

  test(
    'prompts: a settled retirement closes the card once and there is no duplicate on re-attach',
    () => withClient((server, client, events, errors) async {
      server.running = true;
      server.runningAdmission = 'adm-9';
      server.prompts.add(server.prompt('clarify', 'p-1'));
      final binding = await client.resumeExisting('s');
      expect(binding.pendingClarify?['request_id'], 'p-1');
      expect(binding.pendingClarifyProvided, isTrue);
      // A second attach returns the same single prompt (deduped by id).
      final again = await client.openServerRequests('s');
      expect(again.map((e) => e['id']), ['p-1']);
      server.settlePrompt('p-1');
      await _tick();
      expect(events.where((e) => e.type == 'clarify.expire'), hasLength(1));
      expect(await client.openServerRequests('s'), isEmpty);
      final response = await client.respondToClarify('p-1', 'late');
      expect(response.isExpired, isTrue);
      expect(
        server.framesOf('clarify.respond'),
        isEmpty,
        reason: 'retired prompt: nothing sent',
      );
    }),
  );

  test(
    'answers carry the prompt generation and id; a stale generation is refused by the authority',
    () => withClient((server, client, events, errors) async {
      server.running = true;
      server.runningAdmission = 'adm-9';
      server.prompts.add(server.prompt('clarify', 'p-2', gen: 3));
      await client.resumeExisting('s');
      final response = await client.respondToClarify('p-2', 'blue');
      expect(response.isExpired, isFalse);
      final frame = server.framesOf('clarify.respond').single['params'] as Map;
      expect(frame, {
        'session_id': 's',
        'execution_generation': 3,
        'prompt_id': 'p-2',
        'answer': 'blue',
      });
    }),
  );

  test(
    'unsupported canonical operations fail explicitly and send nothing',
    () => withClient((server, client, events, errors) async {
      server.prompts.add(server.prompt('approval', 'ap-1'));
      await client.resumeExisting('s');
      await expectLater(
        client.resolveApproval('s', 'once', resolveAll: true),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (e) => e.reason,
            'reason',
            'canonical_operation_unsupported',
          ),
        ),
      );
      await expectLater(
        client.skipClarify('p'),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (e) => e.reason,
            'reason',
            'canonical_operation_unsupported',
          ),
        ),
      );
      expect(server.framesOf('approval.respond'), isEmpty);
      expect(server.framesOf('clarify.respond'), isEmpty);
    }),
  );

  test(
    'B1 create: both first-submit forms use the closed canonical create, keep profile/model/settings and attach the new session',
    () => withClient((server, client, events, errors) async {
      final plain = await client.createForFirstSubmit(
        profile: 'work',
        model: 'gpt-x',
      );
      expect(plain.runtimeSessionId, 's');
      expect(plain.created, isTrue);
      final first = server.framesOf('session.create').single['params'] as Map;
      expect(first['source'], 'gui');
      expect(first['profile'], 'work');
      expect(first['model'], 'gpt-x');
      expect(first['request_id'], isA<String>());
      expect(first, isNot(contains('close_on_disconnect')));
      expect(first, isNot(contains('messages')));
      final ledger = client.canonicalLedgerForTesting('s')!;
      expect(ledger.isReady, isTrue);
      expect(ledger.profile, 'work');
      // The new session is attached: its first submit needs no extra resume.
      await client.submitPromptIdempotent('s', 'hello', 'turn-1');
      expect(server.framesOf('session.resume'), isEmpty);

      final configured = await client.createForFirstSubmitConfigured(
        profile: 'work',
        config: DesktopSessionCreateConfig(
          model: DesktopModelSelection(
            modelId: 'gpt-x',
            providerSlug: 'openai',
          ),
          title: 'Plan',
          hidden: true,
          followProfileConfig: true,
          workspace: '/home/ana/project',
        ),
      );
      expect(configured.created, isTrue);
      final second = server.framesOf('session.create').last['params'] as Map;
      expect(second['source'], 'gui');
      expect(second['title'], 'Plan');
      expect(second['hidden'], isTrue);
      expect(second['follow_profile_config'], isTrue);
      expect(second['cwd'], '/home/ana/project');
      expect(second['cwd_explicit'], isTrue);
      expect(second['model'], 'gpt-x');
      expect(second['provider'], 'openai');
      expect(second['profile'], 'work');
      expect(second, isNot(contains('close_on_disconnect')));
      expect(second, isNot(contains('fast')));
      // Seeded rows have no canonical field: refused, nothing sent.
      final creates = server.framesOf('session.create').length;
      await expectLater(
        client.createForFirstSubmit(
          seedMessages: [
            {'role': 'user', 'content': 'old'},
          ],
        ),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (e) => e.reason,
            'reason',
            'canonical_operation_unsupported',
          ),
        ),
      );
      expect(server.framesOf('session.create'), hasLength(creates));
    }),
  );

  test(
    'B1 steer/redirect carry the proven execution generation; a rejected correction is not a success',
    () => withClient((server, client, events, errors) async {
      await client.resumeExisting('s', profile: 'work');
      await client.submitPrompt('s', 'A');
      server.startTurn(admission: 'adm-1', gen: 4);
      await _tick();
      await client.steer('s', 'use blue');
      final steer = server.framesOf('session.steer').single['params'] as Map;
      expect(steer, {
        'session_id': 's',
        'execution_generation': 4,
        'text': 'use blue',
        'profile': 'work',
      });
      expect(
        await client.redirect('s', 'switch plan'),
        DesktopRedirectDisposition.redirected,
      );
      expect(
        (server.framesOf('session.redirect').single['params']
            as Map)['execution_generation'],
        4,
      );
      expect(server.corrections.map((c) => c['verb']), [
        'session.steer',
        'session.redirect',
      ]);
      // Nothing running: the authority rejects, the client says so.
      server.running = false;
      server.runningAdmission = null;
      await expectLater(
        client.steer('s', 'too late'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
    }),
  );

  test(
    'B3 recovery: frames after the cut are held until the owner consumes the recovery, then projected in order',
    () => withClient((server, client, events, errors) async {
      server.startTurn(admission: 'adm-9', gen: 4);
      final recovery = await client.resumeAdvertisedExistingForRecovery('s');
      expect(recovery.snapshot, isNot(isA<DesktopSessionBinding>()));
      expect(recovery.snapshot.running, isTrue);
      expect(
        server.framesOf('session.active_list'),
        isEmpty,
        reason: 'the canonical snapshot is the ownership proof',
      );
      // The owner is still reading the transcript: the turn ends meanwhile.
      server.publish('message.delta', {'text': 'tail'});
      server.completeTurn(text: 'late final', admission: 'adm-9', gen: 4);
      await _tick();
      expect(
        events.where((e) => e.type.startsWith('message.')),
        isEmpty,
        reason: 'nothing may be consumed before the owner can apply it',
      );
      expect(
        client.consumeRosterBoundViewerAttachment(recovery),
        isTrue,
        reason: 'the recovery is consumed exactly once',
      );
      expect(client.consumeRosterBoundViewerAttachment(recovery), isFalse);
      await _tick();
      expect(
        events.where((e) => e.type.startsWith('message.')).map((e) => e.type),
        ['message.delta', 'message.complete'],
      );
    }),
  );

  test(
    'B3 recovery: a recovery cut on a dead socket cannot be consumed',
    () => withClient((server, client, events, errors) async {
      final recovery = await client.resumeAdvertisedExistingForRecovery('s');
      await server.sockets.last.close();
      await _tick();
      expect(client.consumeRosterBoundViewerAttachment(recovery), isFalse);
    }),
  );

  test(
    'admission receipts: queued is not started, unknown is unresolved (never terminal success)',
    () => withClient((server, client, events, errors) async {
      await client.resumeExisting('s');
      final started = await client.submitPromptIdempotent('s', 'one', 'turn-1');
      expect(started.state, DesktopTurnState.running);
      expect(started.clientTurnId, 'turn-1');
      server.startTurn(admission: 'adm-1', gen: 4);
      final queued = await client.submitQueuedPromptIdempotent(
        's',
        'two',
        'turn-2',
      );
      expect(
        queued.state,
        DesktopTurnState.accepted,
        reason: 'an ack proves admission only',
      );
      expect(
        client.canonicalLedgerForTesting('s')!.queuedAdmissions,
        hasLength(1),
      );
      // A replay of the same submission id returns the same admission.
      final replay = await client.submitPromptIdempotent('s', 'one', 'turn-1');
      expect(replay.serverTurnId, started.serverTurnId);
      // The authority loses a turn across a restart: unresolved, not success.
      server.receipts['turn-3'] = {
        'admission_id': 'adm-lost',
        'ref': {'profile_id': 'default', 'session_id': 's'},
        'sequence': 9,
        'status': 'unknown',
        'outcome': null,
        'authority_epoch': 7,
        'execution_generation': null,
      };
      await expectLater(
        client.submitPromptIdempotent('s', 'three', 'turn-3'),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (e) => e.reason,
            'reason',
            'admission_unknown',
          ),
        ),
      );
    }),
  );

  test(
    'interrupt is bound to the proven execution generation',
    () => withClient((server, client, events, errors) async {
      await client.resumeExisting('s');
      await client.submitPrompt('s', 'A');
      server.startTurn(admission: 'adm-1', gen: 4);
      await _tick();
      await client.interrupt('s');
      final frame =
          server.framesOf('session.interrupt').single['params'] as Map;
      expect(frame, {'session_id': 's', 'execution_generation': 4});
    }),
  );

  test(
    'B1 attachments: an image is only staged, the admitted submit names it in attachments once; detach drops it; a file reference needs no staging',
    () => withClient((server, client, events, errors) async {
      await client.resumeExisting('s');
      final staged = await client.attachImageBytes(
        's',
        filename: 'a.png',
        contentBase64: 'AAAA',
      );
      expect(staged.path, '/home/ana/cache/images/a.png');
      final dropped = await client.attachImageBytes(
        's',
        filename: 'b.png',
        contentBase64: 'AAAA',
      );
      await client.detachImage('s', dropped.path!);
      expect(server.framesOf('image.detach'), isEmpty);
      final file = await client.attachFileBytes(
        's',
        filename: 'note.txt',
        mimeType: 'text/plain',
        contentBase64: 'AAAA',
      );
      expect(file.refText, '@file:attachments/note.txt');
      await client.submitPromptIdempotent('s', 'look', 'turn-img');
      expect(server.submittedAttachments, hasLength(1));
      expect(server.submittedAttachments.single, [
        {'path': '/home/ana/cache/images/a.png', 'mime': 'image/png'},
      ]);
      // Consumed: the next admitted submit names nothing.
      server.startTurn(admission: 'adm-1', gen: 4);
      await client.submitQueuedPromptIdempotent('s', 'again', 'turn-2');
      expect(server.submittedAttachments, hasLength(1));
    }),
  );
}
