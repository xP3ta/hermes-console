import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification delivery never re-presents historical platform state', () {
    // Globbed, not listed: active_chat_service is a multi-file library, and a
    // forbidden symbol must not be able to hide in one of its `part` files.
    final sources = <String>[
      'lib/main.dart',
      ...Directory('lib/core/services')
          .listSync()
          .whereType<File>()
          .map((entry) => entry.path)
          .where((path) => path.contains('active_chat_')),
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
