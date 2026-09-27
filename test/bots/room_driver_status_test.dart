import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';

import '../support/spec070_fixtures.dart';

void main() {
  group('RoomDriverStatus (groups.state.driver_status)', () {
    test('parses running/working/blocked, counts and pending actions', () {
      final status = spec070DriverStatus();
      expect(status.running, isTrue);
      expect(status.working, isTrue);
      expect(status.blocked, isFalse);
      expect(status.counts['indeterminate'], 1);
      expect(status.retries.single.taskId, 'task-radar-1');
      final approval = status.approvals.single;
      expect(approval.taskId, 'task-astra-2');
      expect(approval.memberId, 'member-astra');
      expect(approval.executionGeneration, 1);
      expect(approval.requestId, 'apr-1');
      expect(approval.runId, 'run-77');
      expect(approval.sessionId, '20260925_101500_abcd12');
      expect(approval.choices, ['once', 'deny']);
      expect(approval.command, 'git push origin main');
      expect(status.needsUser, isTrue);
      expect(status.offersRetry('task-radar-1'), isTrue);
      expect(status.offersRetry('task-astra-2'), isFalse);
      expect(
        status.approvalFor(taskId: 'task-astra-2', requestId: 'apr-1'),
        approval,
      );
    });

    test('rejects malformed status and ignores unknown action kinds', () {
      expect(RoomDriverStatus.tryParse(null), isNull);
      expect(RoomDriverStatus.tryParse({'running': 'yes'}), isNull);
      final status = RoomDriverStatus.tryParse({
        'running': false,
        'working': false,
        'blocked': true,
        'counts': {'running': -1, 'settled': 2, 3: 4},
        'pending_actions': [
          {'kind': 'future_kind', 'task_id': 't'},
          {'kind': 'retry'},
          {'kind': 'retry', 'task_id': 't1'},
          {'kind': 'retry', 'task_id': 't1'},
          {
            'kind': 'approval',
            'task_id': 't2',
            'member_id': 'm',
            'execution_generation': -1,
            'request_id': 'r',
          },
        ],
      })!;
      expect(status.counts, {'settled': 2});
      expect(status.pendingActions, [const RoomRetryAction(taskId: 't1')]);
    });

    test('approval falls back to approval.request_id and filters choices', () {
      final action =
          RoomPendingAction.tryParse({
                'kind': 'approval',
                'task_id': 't',
                'member_id': 'm',
                'execution_generation': 0,
                'approval': {
                  'request_id': 'nested',
                  'choices': ['once', 'bogus', 'always'],
                },
              })!
              as RoomApprovalAction;
      expect(action.requestId, 'nested');
      expect(action.choices, ['once', 'always']);
      expect(action.offers('bogus'), isFalse);
    });
  });

  test('HostedGroupsSnapshot exposes driver status per room', () {
    final snapshot = HostedGroupsSnapshot(
      rooms: [spec070Room()],
      driverStatuses: {'room-devs': spec070DriverStatus()},
    );
    expect(snapshot.driverStatusFor('room-devs')?.working, isTrue);
    expect(snapshot.driverStatusFor('other'), isNull);
  });
}
