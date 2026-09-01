import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification delivery never re-presents historical platform state', () {
    final sources = <String>[
      'lib/main.dart',
      'lib/core/services/active_chat_service.dart',
      'lib/core/services/notifications/notification_service.dart',
      'lib/core/services/notifications/notification_delivery_coordinator.dart',
    ].map((path) => File(path).readAsStringSync()).join('\n');

    for (final unsafe in <String>[
      'reassertRecent',
      'reassertPresented',
      'reassertApprovalPending',
      'reassertPendingApprovalNotification',
    ]) {
      expect(sources, isNot(contains(unsafe)), reason: unsafe);
    }
  });
}
