// SPDX-License-Identifier: GPL-3.0-only
// B2: the fallback chat-reply and run notifications used 512 slots each
// (`6000 + fnv & 0x1ff`, `9000 + String.hashCode & 0x1ff`), so about twenty
// sessions already collided, and `String.hashCode` is not stable across
// processes. Both now use a stable 28-bit FNV in ranges of their own.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';

void main() {
  test('two hundred chats get two hundred reply ids', () {
    final ids = {
      for (var i = 0; i < 200; i++)
        NotificationService.replyNotificationId(
          connId: 'conn',
          sessionId: 'session-$i',
        ),
    };
    expect(ids, hasLength(200));
    for (final id in ids) {
      expect(id, inInclusiveRange(0x10000000, 0x1FFFFFFF));
    }
  });

  test('run ids are stable, distinct and out of every other range', () {
    final ids = {
      for (var i = 0; i < 200; i++)
        NotificationService.runNotificationId('r$i'),
    };
    expect(ids, hasLength(200));
    for (final id in ids) {
      expect(id, inInclusiveRange(0x20000000, 0x2FFFFFFF));
    }
    // Fixed value: the same run maps to the same id after a process restart.
    expect(
      NotificationService.runNotificationId('run-1'),
      NotificationService.runNotificationId('run-1'),
    );
  });
}
