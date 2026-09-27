import 'package:hermes_android/core/models/hosted_groups.dart';

/// Builders for hosted room fixtures (contract shapes from
/// `test/fixtures/spec070`), kept small for Room screen tests.
const roomId = 'room-devs';
const gatewayId = 'gw-home-1';

Map<String, dynamic> memberJson(
  String id,
  String handle, {
  String? displayName,
  String? peer,
}) => {
  'member_id': id,
  'profile': handle,
  'handle': handle,
  'display_name': ?displayName,
  'target': peer == null
      ? {'kind': 'local', 'profile': handle}
      : {
          'kind': 'peer',
          'peer_id': peer,
          'installation_id': 'inst-$peer',
          'profile': handle,
          'capability_digest': 'a' * 64,
        },
};

HostedGroupRoom buildRoom({
  List<Map<String, dynamic>>? members,
  int latestSeq = 0,
  int revision = 1,
  String name = 'Console Devs',
  bool disbanded = false,
}) => HostedGroupRoom.fromJson({
  'room_id': roomId,
  'name': name,
  'members':
      members ??
      [
        memberJson('m-builder', 'builder', displayName: 'console-builder'),
        memberJson('m-review', 'review', displayName: 'console-review'),
        memberJson('m-lead', 'lead', displayName: 'console-lead'),
        memberJson('m-radar', 'radar', displayName: 'console-radar'),
      ],
  'authority_gateway_id': gatewayId,
  'authority_epoch': 2,
  'revision': revision,
  'created_at': 1790000000.0,
  'updated_at': 1790000500.0,
  'latest_seq': latestSeq,
  'disbanded_at': ?(disbanded ? 1790000600.0 : null),
});

final class EventSeq {
  int seq = 0;
  double at = 1790000100.0;

  Map<String, dynamic> _event(
    String kind,
    Map<String, dynamic> actor,
    Map<String, dynamic> payload, {
    String? id,
    double? atSeconds,
  }) {
    seq++;
    at = atSeconds ?? at + 10;
    return {
      'room_id': roomId,
      'seq': seq,
      'event_id': id ?? '$kind-$seq',
      'kind': kind,
      'actor': actor,
      'authority_epoch': 2,
      'payload': payload,
      'created_at': at,
      'idempotent': false,
    };
  }

  Map<String, dynamic> user(
    String text, {
    String thread = 'thread-1',
    String? id,
    double? atSeconds,
  }) => _event(
    'message.user',
    {'kind': 'user', 'id': 'desktop'},
    {'text': text, 'thread_id': thread},
    id: id ?? 'user:$seq',
    atSeconds: atSeconds,
  );

  Map<String, dynamic> _coords(
    String member,
    String discussion, {
    int round = 0,
    String thread = 'thread-1',
    String? task,
  }) => {
    'discussion_event_id': discussion,
    'member_id': member,
    'member_index': 0,
    'round_index': round,
    'task_id': task ?? 'task-$member-$round',
    'thread_id': thread,
    'turn_id': 'turn-$member-$round',
  };

  Map<String, dynamic> member(
    String member,
    String handle,
    String text,
    String discussion, {
    int round = 0,
    String thread = 'thread-1',
    double? atSeconds,
  }) => _event(
    'message.member',
    {'kind': 'member', 'id': member, 'profile': handle},
    {
      ..._coords(member, discussion, round: round, thread: thread),
      'text': text,
    },
    atSeconds: atSeconds,
  );

  Map<String, dynamic> started(
    String member,
    String discussion, {
    int round = 0,
    String? task,
  }) => _event('turn.started', {
    'kind': 'gateway',
    'id': gatewayId,
  }, _coords(member, discussion, round: round, task: task));

  Map<String, dynamic> settled(
    String member,
    String discussion, {
    int round = 0,
    bool passed = false,
    String? messageId,
  }) => _event(
    'turn.settled',
    {'kind': 'gateway', 'id': gatewayId},
    {
      ..._coords(member, discussion, round: round),
      'seen_through_seq': seq,
      'message_event_id': messageId,
      'passed': passed,
    },
  );

  Map<String, dynamic> failed(
    String member,
    String discussion, {
    int round = 0,
    String? task,
  }) => _event(
    'turn.failed',
    {'kind': 'gateway', 'id': gatewayId},
    {
      ..._coords(member, discussion, round: round, task: task),
      'seen_through_seq': seq,
      'error': 'provider timeout',
      'reason_code': 'provider_timeout',
    },
  );

  /// Gateway round verdict (`room.activity`, status settled|bounded).
  Map<String, dynamic> activity(
    String discussion, {
    String status = 'settled',
    String reason = 'silent_round',
    String thread = 'thread-1',
  }) => _event(
    'room.activity',
    {'kind': 'gateway', 'id': gatewayId},
    {
      'status': status,
      'reason_code': reason,
      'thread_id': thread,
      'discussion_event_id': discussion,
    },
    id: 'dactivity:$discussion:$reason',
  );
}

HostedGroupLogPage buildLog(
  List<Map<String, dynamic>> events, {
  int sinceSeq = 0,
}) {
  final latest = events.isEmpty ? sinceSeq : events.last['seq'] as int;
  return HostedGroupLogPage.fromJson(
    {
      'events': events,
      'cursor': latest,
      'latest_seq': latest,
      'has_more': false,
      'authority': {'gateway_id': gatewayId, 'epoch': 2},
    },
    expectedRoomId: roomId,
    sinceSeq: sinceSeq,
  );
}

RoomDriverStatus driver({
  bool working = false,
  bool blocked = false,
  Map<String, int> counts = const {},
  List<Map<String, dynamic>> pending = const [],
}) => RoomDriverStatus.tryParse({
  'running': true,
  'working': working,
  'blocked': blocked,
  'counts': counts,
  'pending_actions': pending,
})!;

Map<String, dynamic> approvalAction({
  String member = 'm-lead',
  String task = 'task-m-lead-0',
  String request = 'apr-1',
  List<String> choices = const ['once', 'deny'],
  String command = 'gh pr ready 51',
}) => {
  'kind': 'approval',
  'task_id': task,
  'execution_generation': 1,
  'run_id': 'run-1',
  'session_id': 'sess-1',
  'request_id': request,
  'member_id': member,
  'approval': {
    'request_id': request,
    'command': command,
    'description': 'dangerous command',
    'choices': choices,
  },
};
