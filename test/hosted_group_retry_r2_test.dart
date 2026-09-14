import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';

Map<String, Object?> _roomJson({String gateway = 'gateway-1', int epoch = 2}) =>
    {
      'room_id': 'room-1',
      'name': 'Room',
      'members': [
        {
          'member_id': 'member-1',
          'profile': 'builder',
          'handle': 'builder',
          'target': {'kind': 'local', 'profile': 'builder'},
        },
      ],
      'authority_gateway_id': gateway,
      'authority_epoch': epoch,
      'revision': 3,
      'created_at': 1,
      'updated_at': 2,
      'latest_seq': 1,
    };

HostedGroupRoom _room({int revision = 3, int latestSeq = 1}) =>
    HostedGroupRoom.fromJson({
      ..._roomJson(),
      'revision': revision,
      'latest_seq': latestSeq,
    });

Map<String, Object?> _deferredPayload() => {
  'discussion_event_id': 'discussion-1',
  'member_id': 'member-1',
  'member_index': 0,
  'round_index': 1,
  'task_id': 'private-task-opaque',
  'thread_id': 'thread-1',
  'turn_id': 'turn-1',
  'seen_through_seq': 1,
  'execution_generation': 2,
  'reason': 'private reason must not render',
};

Map<String, Object?> _deferredEvent({
  Map<String, Object?>? payload,
  String gateway = 'gateway-1',
  int epoch = 2,
}) => {
  'room_id': 'room-1',
  'seq': 1,
  'event_id': 'deferred-1',
  'kind': 'turn.deferred',
  'actor': {'kind': 'gateway', 'id': gateway},
  'authority_epoch': epoch,
  'payload': payload ?? _deferredPayload(),
  'created_at': 2,
  'idempotent': false,
};

HostedGroupLogPage _page({String gateway = 'gateway-1', int epoch = 2}) =>
    HostedGroupLogPage.fromJson(
      {
        'events': [_deferredEvent(gateway: gateway, epoch: epoch)],
        'cursor': 1,
        'latest_seq': 1,
        'has_more': false,
        'authority': {'gateway_id': gateway, 'epoch': epoch},
      },
      expectedRoomId: 'room-1',
      sinceSeq: 0,
    );

GroupsCapabilities _caps({bool retry = true, int generation = 7}) =>
    GroupsCapabilities.tryParse(
      {
        'protocol_version': 2,
        'driver': true,
        'methods': [
          'groups.capabilities',
          'groups.state',
          'groups.log',
          if (retry) 'groups.retry',
        ],
        'max_log_limit': 50,
      },
      connectionId: 'connection-1',
      generation: generation,
    )!;

void main() {
  test('retired retry is filtered and cannot emit a transport call', () {
    final capabilities = _caps();
    var transportCalls = 0;
    final gateway = MissionHostedGroupsGateway.callbacks(
      capabilities: () async => capabilities,
      list: ({required generation}) async => const [],
      state: (roomId, {required generation}) async => _room(),
      log: (roomId, {required generation}) async => _page(),
      retry: (roomId, {required taskId, required generation}) async {
        transportCalls += 1;
        return _room();
      },
    );

    expect(capabilities.supports(GroupMethod.retry), isFalse);
    expect(
      () => gateway.retry('room-1', taskId: 'task-1', generation: 7),
      throwsUnsupportedError,
    );
    expect(transportCalls, 0);
  });

  test(
    'turn.deferred parser accepts only the exact upstream payload schema',
    () {
      final event = HostedGroupEvent.fromJson(
        _deferredEvent(),
        roomId: 'room-1',
      );
      expect(event.kind, 'turn.deferred');

      final canonical = _deferredPayload();
      final malformed = <Map<String, Object?>>[
        for (final field in canonical.keys)
          Map<String, Object?>.from(canonical)..remove(field),
        {...canonical, 'extra': true},
        {...canonical, 'member_index': 0.0},
        {...canonical, 'round_index': -1},
        {...canonical, 'seen_through_seq': 0},
        {...canonical, 'execution_generation': '2'},
        {...canonical, 'reason': ''},
      ];
      for (final payload in malformed) {
        expect(
          () => HostedGroupEvent.fromJson(
            _deferredEvent(payload: payload),
            roomId: 'room-1',
          ),
          throwsFormatException,
          reason: '$payload',
        );
      }
    },
  );

  test('retired retry does not project an action from deferred state', () {
    expect(_page().retryActions(room: _room(), capabilities: _caps()), isEmpty);
  });
}
