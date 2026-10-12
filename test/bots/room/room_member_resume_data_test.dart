import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/room_member_prompts.dart';

import 'room_fixtures.dart';

/// Fake gateway for the stalled-member probe: `session.active_list` rows
/// (with the live `title` upstream reports) and the exact-title
/// `session.list` lookup of a member's `Group: <room_id>` session.
final class _Rpc {
  final List<(String, Map<String, dynamic>)> calls = [];
  final List<Map<String, dynamic>> active = [];
  final Map<String, String> storedByProfile = {
    'review': 'stored-review',
    'builder': 'stored-builder',
  };
  Map<String, dynamic> resumeResult = {
    'session_id': 'rt-new',
    'resumed': 'stored-review',
  };
  Object? resumeError;

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add((method, params));
    switch (method) {
      case 'session.active_list':
        return {'sessions': active};
      case 'session.list':
        final stored = storedByProfile[params['profile']];
        if (params['title'] != 'Group: $roomId' || stored == null) {
          return {'sessions': const []};
        }
        return {
          'sessions': [
            {'id': stored, 'title': 'Group: $roomId'},
          ],
        };
      case 'session.resume':
        if (resumeError case final Object e) throw e;
        return resumeResult;
    }
    throw StateError('unexpected $method');
  }

  List<String> get methods => [for (final c in calls) c.$1];
}

void main() {
  final room = buildRoom();
  final review = room.members.firstWhere((m) => m.memberId == 'm-review');

  test('no live runtime for the member room session: stalled', () async {
    final rpc = _Rpc()
      ..active.add({
        'id': 'rt-builder',
        'session_key': 'stored-builder',
        'status': 'idle',
        'title': 'Group: $roomId',
      });
    final stall = await GatewayRoomMemberPrompts(
      rpc.call,
    ).findStall(room, review);
    expect(stall, isNotNull);
    expect(stall!.memberId, 'm-review');
    expect(stall.profile, 'review');
    expect(stall.storedSessionId, 'stored-review');
    expect(rpc.methods, ['session.active_list', 'session.list']);
    expect(rpc.calls.last.$2, {
      'profile': 'review',
      'title': 'Group: $roomId',
      'include_hidden': true,
    });
  });

  test('a live runtime for that session, idle or not: not stalled', () async {
    for (final status in const ['idle', 'working', 'waiting', 'starting']) {
      final rpc = _Rpc()
        ..active.add({
          'id': 'rt-review',
          'session_key': 'stored-review',
          'status': status,
          'title': 'Group: $roomId',
        });
      expect(
        await GatewayRoomMemberPrompts(rpc.call).findStall(room, review),
        isNull,
        reason: status,
      );
    }
  });

  test('another member of this room is executing: not stalled', () async {
    final rpc = _Rpc()
      ..active.add({
        'id': 'rt-builder',
        'session_key': 'stored-builder',
        'status': 'working',
        'title': 'Group: $roomId',
      });
    expect(
      await GatewayRoomMemberPrompts(rpc.call).findStall(room, review),
      isNull,
    );
    // Decided from the live rows alone: no per-member lookup.
    expect(rpc.methods, ['session.active_list']);
  });

  test('a busy session of another room does not hide the stall', () async {
    final rpc = _Rpc()
      ..active.add({
        'id': 'rt-x',
        'session_key': 'stored-x',
        'status': 'working',
        'title': 'Group: other-room',
      });
    expect(
      await GatewayRoomMemberPrompts(rpc.call).findStall(room, review),
      isNotNull,
    );
  });

  test('no durable room session yet: nothing to resume', () async {
    final rpc = _Rpc()..storedByProfile.remove('review');
    expect(
      await GatewayRoomMemberPrompts(rpc.call).findStall(room, review),
      isNull,
    );
  });

  test('a member hosted by another gateway is never probed', () async {
    final peerRoom = buildRoom(
      members: [
        memberJson('m-builder', 'builder'),
        memberJson('m-review', 'review', peer: 'peer-1'),
      ],
    );
    final peer = peerRoom.members.firstWhere((m) => m.memberId == 'm-review');
    final rpc = _Rpc();
    expect(
      await GatewayRoomMemberPrompts(rpc.call).findStall(peerRoom, peer),
      isNull,
    );
    expect(rpc.calls, isEmpty);
  });

  test('resume sends the driver\'s exact shape once', () async {
    final rpc = _Rpc();
    await GatewayRoomMemberPrompts(rpc.call).resumeStalled(
      const RoomMemberStall(
        memberId: 'm-review',
        profile: 'review',
        storedSessionId: 'stored-review',
      ),
    );
    expect(rpc.calls, hasLength(1));
    expect(rpc.calls.single.$1, 'session.resume');
    expect(rpc.calls.single.$2, {
      'session_id': 'stored-review',
      'profile': 'review',
      'source': 'bot_room',
      'omit_messages': true,
    });
  });

  test('a resume without a runtime id is a failure', () async {
    final rpc = _Rpc()..resumeResult = {'resumed': 'stored-review'};
    await expectLater(
      GatewayRoomMemberPrompts(rpc.call).resumeStalled(
        const RoomMemberStall(
          memberId: 'm-review',
          profile: 'review',
          storedSessionId: 'stored-review',
        ),
      ),
      throwsStateError,
    );
  });
}
