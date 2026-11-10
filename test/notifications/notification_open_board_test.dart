// A Kanban card notice carries its board to the board screen; nothing else
// does. (Moved from an earlier notice suite: the payload is local.)
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';

void main() {
  test('a board travels only with its card', () {
    const withBoard = NotificationOpen(connId: 'c', taskId: 't', boardId: 'b');
    expect(NotificationOpen.tryParse(withBoard.toPayload())!.boardId, 'b');
    const noTask = NotificationOpen(connId: 'c', sessionId: 's', boardId: 'b');
    expect(noTask.toPayload(), isNot(contains('board')));
    expect(NotificationOpen.tryParse(noTask.toPayload())!.boardId, isNull);
    expect(
      NotificationOpen.tryParse('{"conn":"c","tid":"t","board":7}')!.boardId,
      isNull,
    );
  });
}
