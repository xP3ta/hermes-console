import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/room_member_prompts.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'room_fixtures.dart';

void main() {
  test(
    'compress calls list, resume, and compress with exact parameters',
    () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final compressor = GatewayRoomMemberCompressor((method, params) async {
        calls.add((method, params));
        return switch (method) {
          'session.list' => {
            'sessions': [
              {'id': 'stored-old', 'resolved_id': 'stored-builder'},
            ],
          },
          'session.resume' => {'session_id': 'runtime-builder'},
          'session.compress' => {
            'status': 'compressed',
            'before_messages': 42,
            'after_messages': 8,
            'summary': {'headline': 'Room summary'},
          },
          _ => <String, dynamic>{},
        };
      });
      final room = buildRoom();
      final member = room.members.first;

      final result = await compressor.compress(room, member);

      expect(calls.map((call) => call.$1), [
        'session.list',
        'session.resume',
        'session.compress',
      ]);
      expect(calls[0].$2, {
        'profile': 'builder',
        'title': 'Group: room-devs',
        'include_hidden': true,
      });
      expect(calls[1].$2, {
        'session_id': 'stored-builder',
        'profile': 'builder',
        'source': 'bot_room',
        'omit_messages': true,
      });
      expect(calls[2].$2, {'session_id': 'runtime-builder'});
      expect(result.kind, RoomMemberCompressionKind.compressed);
      expect(result.detail, 'Room summary');
    },
  );

  test('missing session returns nothing before resume', () async {
    final calls = <String>[];
    final compressor = GatewayRoomMemberCompressor((method, params) async {
      calls.add(method);
      return {'sessions': const []};
    });

    final result = await compressor.compress(
      buildRoom(),
      buildRoom().members.first,
    );

    expect(result.kind, RoomMemberCompressionKind.nothing);
    expect(calls, ['session.list']);
  });

  test('maps pending, lock, aborted, false, and count success', () async {
    Future<RoomMemberCompressionResult> run(Map<String, dynamic> reply) {
      final compressor = GatewayRoomMemberCompressor((method, params) async {
        return switch (method) {
          'session.list' => {
            'sessions': [
              {'id': 'stored-builder'},
            ],
          },
          'session.resume' => {'session_id': 'runtime-builder'},
          _ => reply,
        };
      });
      final room = buildRoom();
      return compressor.compress(room, room.members.first);
    }

    expect(
      (await run({'status': 'pending'})).kind,
      RoomMemberCompressionKind.pending,
    );
    final locked = await run({
      'compressed': false,
      'lock_held': true,
      'message': 'Compression already running',
    });
    expect(locked.kind, RoomMemberCompressionKind.nothing);
    expect(locked.detail, 'Compression already running');
    expect(
      (await run({'status': 'aborted'})).kind,
      RoomMemberCompressionKind.nothing,
    );
    expect(
      (await run({
        'status': 'compressed',
        'summary': {'aborted': true},
      })).kind,
      RoomMemberCompressionKind.nothing,
    );
    final counts = await run({
      'status': 'compressed',
      'before_messages': 12,
      'after_messages': 4,
    });
    expect(counts.kind, RoomMemberCompressionKind.compressed);
    expect(counts.detail, '12 → 4 messages');
  });

  test('peer members are rejected without an RPC', () async {
    var calls = 0;
    final compressor = GatewayRoomMemberCompressor((method, params) async {
      calls++;
      return const {};
    });
    final room = buildRoom(
      members: [memberJson('m-peer', 'peer', peer: 'gw-peer')],
    );

    final result = await compressor.compress(room, room.members.single);

    expect(result.kind, RoomMemberCompressionKind.nothing);
    expect(calls, 0);
  });

  test(
    'resume 4007 becomes nothing and compress 4009 stays actionable',
    () async {
      final room = buildRoom();
      final member = room.members.first;
      final missing = GatewayRoomMemberCompressor((method, params) async {
        if (method == 'session.list') {
          return {
            'sessions': [
              {'id': 'stored-builder'},
            ],
          };
        }
        throw const TuiGatewayRpcError('session.resume', 'gone', code: 4007);
      });
      expect(
        (await missing.compress(room, member)).kind,
        RoomMemberCompressionKind.nothing,
      );

      final busy = GatewayRoomMemberCompressor((method, params) async {
        return switch (method) {
          'session.list' => {
            'sessions': [
              {'id': 'stored-builder'},
            ],
          },
          'session.resume' => {'session_id': 'runtime-builder'},
          _ => throw const TuiGatewayRpcError(
            'session.compress',
            'busy',
            code: 4009,
          ),
        };
      });
      await expectLater(
        busy.compress(room, member),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
    },
  );
}
