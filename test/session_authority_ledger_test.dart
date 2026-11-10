// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/json_rpc_wire.dart';
import 'package:hermes_android/core/services/session_authority.dart';

Map<String, dynamic> _snapshotJson({
  int seq = 10,
  String epoch = 'ring-1',
  int authority = 7,
  int generation = 3,
  bool running = false,
  List<Map<String, dynamic>> prompts = const [],
  List<Map<String, dynamic>> pending = const [],
}) => {
  'session_id': 's',
  'stored_session_id': 's',
  'messages': <Object>[],
  'message_count': 0,
  'running': running,
  'authority_epoch': authority,
  'replay_epoch': epoch,
  'last_sequence': seq,
  'subscription_id': 'sub-1',
  'revision': 5,
  'execution_generation': generation,
  'pending': pending,
  'prompts': prompts,
  'info': {'desktop_protocol': 'hermes-gateway-v1'},
};

CanonicalSessionLedger _ready({
  int seq = 10,
  int generation = 3,
  bool running = false,
  List<Map<String, dynamic>> prompts = const [],
}) {
  final ledger = CanonicalSessionLedger(sessionId: 's', profile: '');
  ledger.beginHydration();
  ledger.completeHydration(
    CanonicalSnapshot.parse(
      _snapshotJson(
        seq: seq,
        generation: generation,
        running: running,
        prompts: prompts,
      ),
    ),
  );
  return ledger;
}

SessionGatewayEvent _event(
  String type,
  int seq, {
  String? admission,
  int? generation,
  String epoch = 'ring-1',
  int? authority = 7,
  Map<String, dynamic> payload = const {},
}) {
  final fields = <String, dynamic>{
    'type': type,
    'session_id': 's',
    'payload': payload,
    'replay_epoch': epoch,
    'seq': seq,
    'authority_epoch': ?authority,
    'execution_generation': ?generation,
    'admission_id': ?admission,
  };
  return EventEnvelopeParser.parse(fields, replayCapable: true)
      as SessionGatewayEvent;
}

CanonicalAdmissionReceipt _receipt(
  String id,
  String status, {
  int? generation,
}) => CanonicalAdmissionReceipt.parse({
  'admission_id': id,
  'ref': {'profile_id': 'default', 'session_id': 's'},
  'sequence': 1,
  'status': status,
  'outcome': null,
  'authority_epoch': 7,
  'execution_generation': generation,
});

void main() {
  group('capability', () {
    SessionAuthorityCapability read(Map<String, dynamic> p) =>
        SessionAuthorityCapability.fromReadyPayload(p);
    test('true / false / absent / null / malformed are distinct', () {
      expect(
        read({'session_authority': true}),
        SessionAuthorityCapability.supported,
      );
      expect(
        read({'session_authority': false}),
        SessionAuthorityCapability.declaredFalse,
      );
      expect(read({}), SessionAuthorityCapability.unsupported);
      expect(
        read({'session_authority': null}),
        SessionAuthorityCapability.unsupported,
      );
      for (final bad in <Object>['true', 1, 0, {}, []]) {
        final c = read({'session_authority': bad});
        expect(c, SessionAuthorityCapability.malformed, reason: '$bad');
        expect(c.isCanonical, isFalse);
      }
      expect(SessionAuthorityCapability.unknown.isCanonical, isFalse);
    });
  });

  group('snapshot', () {
    test('a faithful snapshot parses with its cut and prompts', () {
      final snap = CanonicalSnapshot.parse(
        _snapshotJson(
          prompts: [
            {
              'kind': 'clarify',
              'prompt_id': 'p-1',
              'execution_generation': 3,
              'question': 'Which?',
              'choices': <String>[],
              'multi_select': false,
            },
          ],
          pending: [
            {
              'admission_id': 'adm-2',
              'ref': {'profile_id': 'default', 'session_id': 's'},
              'sequence': 2,
              'status': 'queued',
              'outcome': null,
              'authority_epoch': 7,
              'execution_generation': null,
              'input_id': 'sub-2',
              'text': 'later',
            },
          ],
        ),
      );
      expect(snap.lastSequence, 10);
      expect(snap.replayEpoch, 'ring-1');
      expect(snap.prompts.single.toLegacyRequestPayload()['request_id'], 'p-1');
      expect(snap.pending.single.executionGeneration, isNull);
      expect(
        CanonicalSnapshot.parse(
          _snapshotJson(),
        ).toBindingJson(_snapshotJson())['pending_clarify'],
        isNull,
        reason: 'no open question: the snapshot explicitly clears the card',
      );
    });

    test('malformed snapshots fail closed', () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (j) => j.remove('replay_epoch'),
        (j) => j['last_sequence'] = -1,
        (j) => j['last_sequence'] = '10',
        (j) => j['stored_session_id'] = 'other',
        (j) => j['subscription_id'] = '',
        (j) => j['prompts'] = 'x',
        (j) => j['running'] = 'no',
        (j) => j['prompts'] = [
          {
            'kind': 'sudo',
            'prompt_id': 'p',
            'execution_generation': 1,
            'choices': <String>[],
          },
        ],
      ]) {
        final json = _snapshotJson();
        mutate(json);
        expect(() => CanonicalSnapshot.parse(json), throwsFormatException);
      }
    });
  });

  group('ledger fences', () {
    test(
      'events during hydration are held and replayed in order against the cut',
      () {
        final ledger = CanonicalSessionLedger(sessionId: 's', profile: '');
        ledger.beginHydration();
        final a = _event('message.delta', 9, admission: 'a1', generation: 3);
        final b = _event('message.delta', 11, admission: 'a1', generation: 3);
        final c = _event('message.delta', 12, admission: 'a1', generation: 3);
        expect(ledger.judge(a), CanonicalFrameDisposition.hold);
        expect(ledger.judge(b), CanonicalFrameDisposition.hold);
        expect(ledger.judge(c), CanonicalFrameDisposition.hold);
        final held = ledger.completeHydration(
          CanonicalSnapshot.parse(_snapshotJson(seq: 10, running: true)),
        );
        expect(held.map((e) => e.sequence), [9, 11, 12]);
        expect(ledger.judge(held[0]), CanonicalFrameDisposition.drop);
        expect(ledger.judge(held[1]), CanonicalFrameDisposition.dispatch);
        expect(ledger.judge(held[2]), CanonicalFrameDisposition.dispatch);
        expect(ledger.watermark, 12);
      },
    );

    test(
      'never advances to an unproven sequence: a gap requires a snapshot',
      () {
        final ledger = _ready(seq: 10);
        expect(
          ledger.judge(
            _event('message.delta', 12, admission: 'a', generation: 4),
          ),
          CanonicalFrameDisposition.snapshotRequired,
        );
        expect(ledger.watermark, 10, reason: 'the watermark did not jump');
        expect(ledger.phase, CanonicalLedgerPhase.snapshotRequired);
        // Everything after is withheld until a new snapshot.
        expect(
          ledger.judge(
            _event('message.delta', 11, admission: 'a', generation: 4),
          ),
          CanonicalFrameDisposition.drop,
        );
      },
    );

    test('replay epoch and authority epoch changes fail closed', () {
      var ledger = _ready();
      expect(
        ledger.judge(
          _event(
            'message.delta',
            11,
            epoch: 'ring-2',
            admission: 'a',
            generation: 3,
          ),
        ),
        CanonicalFrameDisposition.snapshotRequired,
      );
      ledger = _ready();
      expect(
        ledger.judge(
          _event(
            'message.delta',
            11,
            authority: 8,
            admission: 'a',
            generation: 3,
          ),
        ),
        CanonicalFrameDisposition.snapshotRequired,
      );
    });

    test(
      'a frame without proof (no epoch, malformed stamps, replay gap) fails closed',
      () {
        var ledger = _ready();
        final bare =
            EventEnvelopeParser.parse({
                  'type': 'message.delta',
                  'session_id': 's',
                  'payload': <String, dynamic>{},
                  'seq': 11,
                }, replayCapable: true)
                as SessionGatewayEvent;
        expect(ledger.judge(bare), CanonicalFrameDisposition.snapshotRequired);
        ledger = _ready();
        final bad =
            EventEnvelopeParser.parse({
                  'type': 'message.delta',
                  'session_id': 's',
                  'payload': <String, dynamic>{},
                  'seq': 11,
                  'replay_epoch': 'ring-1',
                  'execution_generation': 'three',
                }, replayCapable: true)
                as SessionGatewayEvent;
        expect(bad.envelope.malformed, isTrue);
        expect(ledger.judge(bad), CanonicalFrameDisposition.snapshotRequired);
        ledger = _ready();
        final gap =
            EventEnvelopeParser.parse({
                  'type': 'session.replay_gap',
                  'session_id': 's',
                  'payload': {'replay_epoch': 'ring-1', 'latest_seq': 40},
                  'seq': 11,
                  'replay_epoch': 'ring-1',
                }, replayCapable: true)
                as SessionGatewayEvent;
        expect(ledger.judge(gap), CanonicalFrameDisposition.snapshotRequired);
      },
    );

    test(
      'A terminal arriving while B is the followed admission never closes B (checked BEFORE B.start)',
      () {
        final ledger = _ready(seq: 10, generation: 4, running: true);
        // A was running (adopted), then the chat followed A, then B was admitted
        // as the followed turn (a non-queued submit after Stop).
        ledger.noteReceipt(
          _receipt('A', 'started', generation: 4),
          queued: false,
        );
        ledger.noteReceipt(_receipt('B', 'queued'), queued: false);
        expect(ledger.trackedAdmission, 'B');
        final cancel = ledger.judge(
          _event(
            'message.complete',
            11,
            admission: 'A',
            generation: 4,
            payload: {'status': 'cancelled'},
          ),
        );
        final complete = ledger.judge(
          _event('message.complete', 12, admission: 'A', generation: 4),
        );
        expect(cancel, CanonicalFrameDisposition.drop);
        expect(complete, CanonicalFrameDisposition.drop);
        // Intermediate state, before B.start: B is still followed and open.
        expect(ledger.trackedAdmission, 'B');
        expect(ledger.isClosed('B'), isFalse);
        expect(ledger.isClosed('A'), isTrue);
        expect(
          ledger.judge(
            _event('message.start', 13, admission: 'B', generation: 5),
          ),
          CanonicalFrameDisposition.dispatch,
        );
        expect(ledger.trackedAdmission, 'B');
        expect(
          ledger.judge(
            _event('message.complete', 14, admission: 'B', generation: 5),
          ),
          CanonicalFrameDisposition.dispatch,
        );
        expect(ledger.trackedAdmission, isNull);
        expect(ledger.isClosed('B'), isTrue);
      },
    );

    test(
      'contiguous burst [A cancel, A complete, B start]: B untouched, then B closes once',
      () {
        final ledger = _ready(seq: 10, generation: 4, running: true);
        ledger.noteReceipt(_receipt('B', 'queued'), queued: false);
        final out = [
          ledger.judge(
            _event('message.complete', 11, admission: 'A', generation: 4),
          ),
          ledger.judge(
            _event('message.complete', 12, admission: 'A', generation: 4),
          ),
          ledger.judge(
            _event('message.start', 13, admission: 'B', generation: 5),
          ),
        ];
        expect(out, [
          CanonicalFrameDisposition.drop,
          CanonicalFrameDisposition.drop,
          CanonicalFrameDisposition.dispatch,
        ]);
        expect(ledger.trackedAdmission, 'B');
        expect(ledger.maxGeneration, 5);
      },
    );

    test(
      'a terminal that names no turn while one is followed is not guessed',
      () {
        final ledger = _ready(running: true, generation: 4);
        ledger.noteReceipt(
          _receipt('B', 'started', generation: 4),
          queued: false,
        );
        expect(
          ledger.judge(_event('message.complete', 11)),
          CanonicalFrameDisposition.snapshotRequired,
        );
        expect(ledger.isClosed('B'), isFalse);
      },
    );

    test(
      'legitimate terminal without message.start (own started admission, external turn) is dispatched once',
      () {
        final ledger = _ready();
        ledger.noteReceipt(
          _receipt('A', 'started', generation: 4),
          queued: false,
        );
        expect(
          ledger.judge(
            _event('message.complete', 11, admission: 'A', generation: 4),
          ),
          CanonicalFrameDisposition.dispatch,
        );
        // An external turn the chat never followed also closes normally.
        final other = _ready();
        expect(
          other.judge(
            _event('message.complete', 11, admission: 'X', generation: 4),
          ),
          CanonicalFrameDisposition.dispatch,
        );
        // A duplicate of an applied terminal is not dispatched again.
        expect(
          other.judge(
            _event('message.complete', 12, admission: 'X', generation: 4),
          ),
          CanonicalFrameDisposition.drop,
        );
      },
    );

    test(
      'an acknowledgement is admission, not completion; a terminal receipt closes only itself',
      () {
        final ledger = _ready();
        ledger.noteReceipt(_receipt('A', 'queued'), queued: false);
        expect(ledger.isClosed('A'), isFalse);
        expect(ledger.trackedAdmission, 'A');
        ledger.noteReceipt(_receipt('Q', 'queued'), queued: true);
        expect(ledger.queuedAdmissions, {'Q'});
        expect(ledger.trackedAdmission, 'A');
        ledger.noteReceipt(
          _receipt('T', 'terminal', generation: 2),
          queued: false,
        );
        expect(ledger.isClosed('T'), isTrue);
        expect(ledger.trackedAdmission, 'A');
        expect(
          ledger.maxGeneration,
          3,
          reason: 'an old generation never lowers the proven one',
        );
      },
    );

    test(
      'prompts: stale generation is ignored, duplicates deduped, settled retires once',
      () {
        final ledger = _ready(seq: 10, generation: 5, running: true);
        Map<String, dynamic> prompt(String id, int gen) => {
          'prompt_id': id,
          'execution_generation': gen,
          'question': 'q',
          'choices': <String>[],
          'multi_select': false,
        };
        expect(
          ledger.judge(
            _event(
              'clarify.request',
              11,
              generation: 4,
              payload: prompt('old', 4),
            ),
          ),
          CanonicalFrameDisposition.drop,
        );
        expect(ledger.prompts, isEmpty);
        expect(
          ledger.judge(
            _event(
              'clarify.request',
              12,
              generation: 5,
              payload: prompt('p', 5),
            ),
          ),
          CanonicalFrameDisposition.dispatch,
        );
        expect(
          ledger.judge(
            _event(
              'clarify.request',
              13,
              generation: 5,
              payload: prompt('p', 5),
            ),
          ),
          CanonicalFrameDisposition.drop,
        );
        expect(
          ledger.judge(
            _event(
              'clarify.settled',
              14,
              payload: {'prompt_id': 'p', 'execution_generation': 5},
            ),
          ),
          CanonicalFrameDisposition.dispatch,
        );
        expect(
          ledger.judge(
            _event(
              'clarify.settled',
              15,
              payload: {'prompt_id': 'p', 'execution_generation': 5},
            ),
          ),
          CanonicalFrameDisposition.drop,
        );
        expect(ledger.prompts, isEmpty);
      },
    );

    test(
      'a new snapshot replaces the prompt set; a stopped runtime ends the followed turn',
      () {
        final ledger = _ready(seq: 10, generation: 4, running: true);
        ledger.noteReceipt(
          _receipt('A', 'started', generation: 4),
          queued: false,
        );
        ledger.beginHydration();
        ledger.completeHydration(
          CanonicalSnapshot.parse(
            _snapshotJson(seq: 20, generation: 4, running: false),
          ),
        );
        expect(ledger.trackedAdmission, isNull);
        expect(ledger.prompts, isEmpty);
        expect(ledger.watermark, 20);
        expect(ledger.isReady, isTrue);
      },
    );

    test(
      'a snapshot with an unknown admission keeps the honest unresolved state',
      () {
        final ledger = CanonicalSessionLedger(sessionId: 's', profile: '');
        ledger.beginHydration();
        final snap = CanonicalSnapshot.parse(
          _snapshotJson(
            pending: [
              {
                'admission_id': 'U',
                'ref': {'profile_id': 'default', 'session_id': 's'},
                'sequence': 1,
                'status': 'unknown',
                'outcome': null,
                'authority_epoch': 7,
                'execution_generation': null,
                'input_id': 'sub',
                'text': 'lost',
              },
            ],
          ),
        );
        ledger.completeHydration(snap);
        expect(snap.pending.single.status, 'unknown');
        expect(snap.pending.single.executionGeneration, isNull);
        expect(
          ledger.isClosed('U'),
          isFalse,
          reason: 'unknown is not terminal success',
        );
      },
    );

    test(
      'B4: a receipt that arrives after its own terminal does not re-track the closed admission',
      () {
        final ledger = _ready(seq: 10, generation: 3);
        expect(
          ledger.judge(
            _event('message.start', 11, admission: 'B', generation: 4),
          ),
          CanonicalFrameDisposition.dispatch,
        );
        expect(
          ledger.judge(
            _event('message.complete', 12, admission: 'B', generation: 4),
          ),
          CanonicalFrameDisposition.dispatch,
        );
        expect(ledger.isClosed('B'), isTrue);
        // The slow acknowledgement of B (status started) finally arrives.
        ledger.noteReceipt(
          _receipt('B', 'started', generation: 4),
          queued: false,
        );
        expect(ledger.trackedAdmission, isNull);
        // Another surface's turn C must still be projected end to end.
        expect(
          ledger.judge(
            _event('message.start', 13, admission: 'C', generation: 5),
          ),
          CanonicalFrameDisposition.dispatch,
        );
        expect(
          ledger.judge(
            _event('message.complete', 14, admission: 'C', generation: 5),
          ),
          CanonicalFrameDisposition.dispatch,
        );
      },
    );

    test(
      'B5: rehydrating with running=true drops a tracked admission that is no longer started and follows the listed own one',
      () {
        final ledger = _ready(seq: 10, generation: 3, running: true);
        ledger.noteReceipt(
          _receipt('A', 'started', generation: 3),
          queued: false,
        );
        ledger.noteReceipt(_receipt('D', 'queued'), queued: true);
        // Gap: A finished and D started while the stream was not attached.
        ledger.beginHydration();
        ledger.completeHydration(
          CanonicalSnapshot.parse(
            _snapshotJson(
              seq: 20,
              generation: 4,
              running: true,
              pending: [
                {
                  'admission_id': 'D',
                  'ref': {'profile_id': 'default', 'session_id': 's'},
                  'sequence': 2,
                  'status': 'started',
                  'outcome': null,
                  'authority_epoch': 7,
                  'execution_generation': 4,
                  'input_id': 'sub-d',
                  'text': 'follow-up',
                },
              ],
            ),
          ),
        );
        expect(ledger.trackedAdmission, 'D');
        for (final type in ['message.start', 'message.delta']) {
          expect(
            ledger.judge(
              _event(
                type,
                type == 'message.start' ? 21 : 22,
                admission: 'D',
                generation: 4,
              ),
            ),
            CanonicalFrameDisposition.dispatch,
            reason: type,
          );
        }
        expect(
          ledger.judge(
            _event('message.complete', 23, admission: 'D', generation: 4),
          ),
          CanonicalFrameDisposition.dispatch,
        );
        expect(ledger.trackedAdmission, isNull);
        expect(ledger.isClosed('D'), isTrue);
      },
    );

    test(
      'B5 control: rehydrating with running=true keeps a tracked admission that the snapshot still lists as started',
      () {
        final ledger = _ready(seq: 10, generation: 3, running: true);
        ledger.noteReceipt(
          _receipt('A', 'started', generation: 3),
          queued: false,
        );
        ledger.beginHydration();
        ledger.completeHydration(
          CanonicalSnapshot.parse(
            _snapshotJson(
              seq: 20,
              generation: 3,
              running: true,
              pending: [
                {
                  'admission_id': 'A',
                  'ref': {'profile_id': 'default', 'session_id': 's'},
                  'sequence': 1,
                  'status': 'started',
                  'outcome': null,
                  'authority_epoch': 7,
                  'execution_generation': 3,
                  'input_id': 'sub-a',
                  'text': 'first',
                },
              ],
            ),
          ),
        );
        expect(ledger.trackedAdmission, 'A');
      },
    );
  });
}
