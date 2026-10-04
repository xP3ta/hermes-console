// Connection prompts (`connection.request` / `connection.update` and the
// resume snapshot's `pending_connection`): normalisation and ordering rules
// ported from Hermes Desktop's connection-request store. Pure data; fixtures
// are synthetic and the links use an example host.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection_request.dart';

Map<String, dynamic> _target(
  String name, {
  String kind = 'connector',
  String state = 'pending',
  String? url,
  Map<String, dynamic>? extra,
}) => {
  'name': name,
  'kind': kind,
  'action': 'authorize',
  'state': state,
  'connect_url': ?url,
  ...?extra,
};

Map<String, dynamic> _payload({
  String opId = 'op-1',
  int seq = 1,
  Object? deadline = 1790000000.0,
  Object? toolCallId = 'call-1',
  Object? targets,
}) => {
  'op_id': opId,
  'seq': seq,
  'deadline_at': deadline,
  'timeout_seconds': 120,
  'tool_call_id': toolCallId,
  'targets': targets ?? [_target('gmail', url: 'https://connect.example.test/a')],
};

ConnectionRequest _request({String opId = 'op-1', int seq = 1}) =>
    normalizeConnectionRequest(_payload(opId: opId, seq: seq))!;

Map<String, dynamic> _update({
  String opId = 'op-1',
  int seq = 2,
  bool settled = false,
  String? settledBy,
  List<Map<String, dynamic>>? targets,
}) => {
  'op_id': opId,
  'seq': seq,
  'deadline_at': 1790000000.0,
  'settled': settled,
  'settled_by': ?settledBy,
  'targets': targets ?? [_target('gmail', state: 'connected')],
};

void main() {
  group('normalizeConnectionRequest', () {
    test('keeps the fields a card needs', () {
      final request = _request();
      expect(request.opId, 'op-1');
      expect(request.seq, 1);
      expect(request.toolCallId, 'call-1');
      expect(request.deadlineAt, 1790000000.0);
      expect(request.settled, isFalse);
      final target = request.targets.single;
      expect(target.name, 'gmail');
      expect(target.kind, ConnectionTargetKind.connector);
      expect(target.state, ConnectionTargetState.pending);
      expect(target.connectUrl, Uri.parse('https://connect.example.test/a'));
    });

    test('drops the payload when anything it is bound to is missing', () {
      final broken = <String, Map<String, dynamic>>{
        'op_id': _payload(opId: ''),
        'tool_call_id': _payload(toolCallId: null),
        'blank tool_call_id': _payload(toolCallId: '  '),
        'deadline zero': _payload(deadline: 0),
        'deadline absent': _payload(deadline: null),
        'deadline text': _payload(deadline: 'soon'),
        'no targets': _payload(targets: <Object>[]),
        'targets not a list': _payload(targets: 'gmail'),
        'nameless target': _payload(
          targets: [
            _target('gmail'),
            {'kind': 'connector', 'state': 'pending'},
          ],
        ),
      };
      broken.forEach((label, payload) {
        expect(normalizeConnectionRequest(payload), isNull, reason: label);
      });
    });

    test('unknown kind is a generic row, unknown state is pending', () {
      final request = normalizeConnectionRequest(
        _payload(
          targets: [
            _target('a', kind: 'quantum', state: 'teleporting'),
            _target('b', kind: 'mcp', state: 'not_connected'),
            _target('c', kind: 'plugin', state: 'expired'),
          ],
        ),
      )!;
      expect(request.targets[0].kind, ConnectionTargetKind.other);
      expect(request.targets[0].state, ConnectionTargetState.pending);
      expect(request.targets[1].kind, ConnectionTargetKind.mcp);
      expect(request.targets[1].state, ConnectionTargetState.notConnected);
      expect(request.targets[2].kind, ConnectionTargetKind.plugin);
      expect(request.targets[2].state, ConnectionTargetState.expired);
    });

    test('only https links without credentials survive', () {
      final request = normalizeConnectionRequest(
        _payload(
          targets: [
            _target('a', url: 'http://connect.example.test/a'),
            _target('b', url: 'javascript:alert(1)'),
            _target('c', url: 'https://user:pw@connect.example.test/c'),
            _target('d', url: 'https:///no-host'),
            _target('e', url: 'https://connect.example.test/e'),
          ],
        ),
      )!;
      expect(request.targets.map((t) => t.connectUrl?.toString()), [
        null,
        null,
        null,
        null,
        'https://connect.example.test/e',
      ]);
    });

    test('JSON nulls read as absent and secrets are never kept', () {
      final request = normalizeConnectionRequest(
        _payload(
          targets: [
            _target(
              'mcp-one',
              kind: 'mcp',
              extra: {
                'detail': null,
                'instructions': null,
                'connect_url': null,
                'required_env': [
                  {'name': 'API_KEY', 'secret': true, 'default': 'hunter2'},
                ],
              },
            ),
          ],
        ),
      )!;
      final target = request.targets.single;
      expect(target.detail, isNull);
      expect(target.instructions, isNull);
      expect(target.connectUrl, isNull);
      expect('$request', isNot(contains('API_KEY')));
      expect('$request', isNot(contains('hunter2')));
    });

    test('the link is never part of the printed form', () {
      expect('${_request()}', isNot(contains('connect.example.test')));
    });
  });

  group('connection.update and operation status', () {
    test('a higher seq replaces the whole target snapshot', () {
      final held = _request();
      final next = applyConnectionUpdate(held, _update());
      expect(next.seq, 2);
      expect(next.targets.single.state, ConnectionTargetState.connected);
    });

    test('older or equal seq, other op and settled requests change nothing', () {
      final held = _request(seq: 3);
      expect(
        identical(applyConnectionUpdate(held, _update(seq: 3)), held),
        isTrue,
      );
      expect(
        identical(applyConnectionUpdate(held, _update(seq: 2)), held),
        isTrue,
      );
      expect(
        identical(applyConnectionUpdate(held, _update(opId: 'op-2', seq: 9)), held),
        isTrue,
      );
      final settled = applyConnectionUpdate(
        held,
        _update(seq: 4, settled: true, settledBy: 'continue'),
      );
      expect(settled.settled, isTrue);
      expect(settled.settledBy, 'continue');
      expect(
        identical(applyConnectionUpdate(settled, _update(seq: 5)), settled),
        isTrue,
      );
    });

    test('operation status follows the same ordering', () {
      final held = _request();
      expect(applyOperationStatus(held, _update(seq: 2)).seq, 2);
      expect(
        identical(applyOperationStatus(held, _update(seq: 1)), held),
        isTrue,
      );
    });

    test('a frame without targets keeps the ones held', () {
      final held = _request();
      final next = applyConnectionUpdate(held, {
        'op_id': 'op-1',
        'seq': 2,
        'settled': false,
      });
      expect(next.seq, 2);
      expect(next.targets.single.name, 'gmail');
    });
  });

  group('ConnectionCardState', () {
    test('a request for an operation already settled is not shown again', () {
      var state = const ConnectionCardState().onRequest(_request());
      state = state.onUpdate(_update(seq: 2, settled: true, settledBy: 'continue'));
      state = state.onRequest(_request(seq: 9));
      expect(state.request!.settled, isTrue);
      expect(state.request!.seq, 2);
    });

    test('same operation: newer seq wins, older is ignored', () {
      var state = const ConnectionCardState().onRequest(_request(seq: 5));
      state = state.onRequest(_request(seq: 4));
      expect(state.request!.seq, 5);
      state = state.onRequest(_request(seq: 6));
      expect(state.request!.seq, 6);
    });

    test('a different operation replaces the open one', () {
      final state = const ConnectionCardState()
          .onRequest(_request())
          .onRequest(_request(opId: 'op-2'));
      expect(state.request!.opId, 'op-2');
    });

    test('resume restores a card, but never one that already settled', () {
      final restored = const ConnectionCardState().onResume(
        pending: _request(),
        heldAtStart: null,
      );
      expect(restored.request!.opId, 'op-1');

      var settled = const ConnectionCardState().onRequest(_request());
      settled = settled.onUpdate(_update(seq: 2, settled: true, settledBy: 'deadline'));
      settled = settled.onRequest(_request(opId: 'op-2'));
      final again = settled.onResume(pending: _request(), heldAtStart: null);
      expect(again.request!.opId, 'op-2');
    });

    test('resume never regresses a newer seq and advances an older one', () {
      final held = const ConnectionCardState().onRequest(_request(seq: 5));
      expect(
        held.onResume(pending: _request(seq: 3), heldAtStart: held.request)
            .request!
            .seq,
        5,
      );
      expect(
        held.onResume(pending: _request(seq: 8), heldAtStart: held.request)
            .request!
            .seq,
        8,
      );
    });

    test('an absent snapshot clears only a card that existed before resume', () {
      final before = const ConnectionCardState().onRequest(_request());
      expect(
        before.onResume(pending: null, heldAtStart: before.request).request,
        isNull,
      );

      // A card that arrived by event while the resume was in flight stays.
      final during = before.onRequest(_request(opId: 'op-2'));
      expect(
        during.onResume(pending: null, heldAtStart: before.request).request!.opId,
        'op-2',
      );

      // Nothing held at the start, nothing to clear.
      final late = const ConnectionCardState().onRequest(_request());
      expect(late.onResume(pending: null, heldAtStart: null).request, isNotNull);
    });
  });
}
