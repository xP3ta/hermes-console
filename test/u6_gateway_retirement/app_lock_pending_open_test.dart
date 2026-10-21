import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('App Lock reintenta la apertura pendiente exacta al desbloquear', () {
    final main = File('lib/main.dart').readAsStringSync();
    final start = main.indexOf('void _onAppLockNoticeGateChanged()');
    final end = main.indexOf(
      'final Set<String> _hydratingNotificationRuns',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final gate = main.substring(start, end);
    expect(gate, contains('widget.notifications.retryPendingOpen()'));
  });
}
