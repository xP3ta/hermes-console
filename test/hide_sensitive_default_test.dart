import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "Hide sensitive content" is on by default. Every read of the preference
/// must fall back to true, including the Bot Mode snapshot that the background
/// listener builds while the app is closed.
void main() {
  test('every read of notif_hide_sensitive_content defaults to true', () {
    final read = RegExp(
      r"getBool\(\s*'notif_hide_sensitive_content'\s*\)\s*(\?\?\s*\w+)?",
    );
    var reads = 0;
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      for (final m in read.allMatches(entity.readAsStringSync())) {
        reads++;
        expect(m.group(1)?.replaceAll(RegExp(r'\s'), ''), '??true',
            reason: entity.path);
      }
    }
    expect(reads, greaterThanOrEqualTo(3));
    expect(
      File('lib/core/services/notifications/notification_service.dart')
          .readAsStringSync(),
      contains('_prefs.getBool(_kHideSensitive) ?? true'),
    );
  });
}
