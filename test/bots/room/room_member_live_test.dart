import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/room_member_live.dart';

import 'room_fixtures.dart';

/// Live view of a local room member's turn, read without attaching to its
/// hidden `Group: <room_id>` session: `session.active_list` finds the
/// working runtime, `session.events.since` reads the replay ring
/// (`tui_gateway/event_replay.py`), bounded to the last frames.
Map<String, dynamic> _frame(String type, [Map<String, dynamic>? payload]) => {
  'type': type,
  'session_id': 'rt-lead',
  'payload': payload ?? const {},
};

void main() {
  group('reduceRoomMemberFrames', () {
    test('builds ordered steps; reasoning and message text never kept', () {
      final live = reduceRoomMemberFrames([
        _frame('reasoning.delta', {'text': 'secret plan'}),
        _frame('reasoning.delta', {'text': ' more'}),
        _frame('tool.start', {
          'tool_id': 't1',
          'name': 'read_file',
          'context': 'CHANGELOG.md',
          'args': {'path': '/home/x/token.txt'},
        }),
        _frame('tool.complete', {'tool_id': 't1', 'name': 'read_file'}),
        _frame('tool.start', {
          'tool_id': 't2',
          'name': 'terminal',
          'context':
              'flutter test --plain-name "a very long name that goes on"',
        }),
      ]);
      expect(live.steps.map((s) => s.kind), [
        RoomLiveStepKind.thinking,
        RoomLiveStepKind.tool,
        RoomLiveStepKind.tool,
      ]);
      expect(live.steps[0].done, isTrue);
      expect(live.steps[1].done, isTrue);
      expect(live.current?.tool, 'terminal');
      expect(live.current!.context!.length, lessThanOrEqualTo(48));
      final dump = live.steps.map((s) => '${s.tool} ${s.context}').join();
      expect(dump, isNot(contains('secret')));
      expect(dump, isNot(contains('token.txt')));
    });

    test('a reply being written closes the open tool phase', () {
      final live = reduceRoomMemberFrames([
        _frame('tool.start', {'tool_id': 't1', 'name': 'web_search'}),
        _frame('message.delta', {'text': 'Hello'}),
        _frame('message.delta', {'text': ' world'}),
      ]);
      expect(live.steps, hasLength(2));
      expect(live.steps.first.done, isTrue);
      expect(live.current?.kind, RoomLiveStepKind.writing);
    });

    test('keeps only the last steps', () {
      final live = reduceRoomMemberFrames([
        for (var i = 0; i < 20; i++) ...[
          _frame('tool.start', {'tool_id': 't$i', 'name': 'tool$i'}),
          _frame('tool.complete', {'tool_id': 't$i'}),
        ],
      ]);
      expect(live.steps.length, lessThanOrEqualTo(8));
      expect(live.steps.last.tool, 'tool19');
    });
  });

  group('GatewayRoomMemberLive', () {
    test(
      'reads only working local members, bounded to the last frames',
      () async {
        final calls = <(String, Map<String, dynamic>)>[];
        var sinceCalls = 0;
        final room = buildRoom(
          members: [
            memberJson('m-lead', 'lead'),
            memberJson('m-builder', 'builder'),
            memberJson('m-peer', 'peer', peer: 'p1'),
          ],
        );
        Future<Map<String, dynamic>> rpc(
          String method,
          Map<String, dynamic> params,
        ) async {
          calls.add((method, params));
          switch (method) {
            case 'session.active_list':
              return {
                'sessions': [
                  {
                    'id': 'rt-lead',
                    'session_key': 'stored-lead',
                    'status': 'working',
                  },
                  {
                    'id': 'rt-b',
                    'session_key': 'stored-builder',
                    'status': 'idle',
                  },
                ],
              };
            case 'session.list':
              final profile = params['profile'];
              return {
                'sessions': [
                  {'id': 'stored-$profile'},
                ],
              };
            case 'session.events.since':
              sinceCalls++;
              return {
                'events': [
                  if (sinceCalls > 1)
                    _frame('tool.start', {'tool_id': 't', 'name': 'terminal'}),
                ],
                'latest_seq': 1000,
              };
            default:
              fail('unexpected $method');
          }
        }

        final live = await GatewayRoomMemberLive(rpc).read(room);
        expect(live.keys, ['m-lead']);
        expect(live['m-lead']!.current?.tool, 'terminal');
        final since = [
          for (final c in calls)
            if (c.$1 == 'session.events.since') c.$2,
        ];
        expect(since, hasLength(2));
        expect(since.every((p) => p['session_id'] == 'rt-lead'), isTrue);
        // Bounded: never replays the whole ring.
        expect(since.last['last_seen'], 1000 - roomLiveFrameWindow);
        // The peer member has no session on this gateway.
        expect(
          calls.where(
            (c) => c.$1 == 'session.list' && c.$2['profile'] == 'peer',
          ),
          isEmpty,
        );
      },
    );

    test('nothing working: one cheap call and no session reads', () async {
      final methods = <String>[];
      final live = await GatewayRoomMemberLive((method, params) async {
        methods.add(method);
        return {'sessions': const []};
      }).read(buildRoom());
      expect(live, isEmpty);
      expect(methods, ['session.active_list']);
    });
  });
}
