import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The permanent listening must be able to stay off: nothing may switch it
/// back on by itself, and session notices never sit behind its opt-in.
void main() {
  test('only the three explicit switches turn the listener opt-in on', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path;
      if (path.endsWith('background_listener.dart') ||
          path.endsWith('notification_settings_screen.dart')) {
        continue;
      }
      final text = entity.readAsStringSync();
      if (RegExp(r'BackgroundListener\.startForAutomation\(').hasMatch(text) ||
          RegExp(
            r'setBool\(\s*(BackgroundListener\.)?prefKey\s*,\s*true',
          ).hasMatch(text) ||
          RegExp(
            r'setBool\(\s*NotificationService\.backgroundListenPreferenceKey'
            r'\s*,\s*true',
          ).hasMatch(text)) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('approvals do not sit behind the automation opt-in', () {
    final service = File(
      'lib/core/services/notifications/notification_service.dart',
    ).readAsStringSync();
    expect(
      service,
      contains('bool get notifyApprovals => _prefs.getBool(_kApprovals)'),
    );
  });
}
