import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';

void main() {
  for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
    test('$lang owns pair and list punctuation templates', () {
      final copy = NotifL10n(lang);
      expect(notificationCatalogs[lang]!['joinNamesPair'], isNotNull);
      expect(notificationCatalogs[lang]!['joinNamesHead'], isNotNull);
      final conjunction = notificationCatalogs[lang]!['_joinNames']!;
      final pair = copy.roundDone(['A', 'B']);
      expect(pair, contains('A $conjunction B'));
      expect(copy.roundDone(['A', 'A', 'B']), pair);
      expect(copy.roundDone(['A', 'B', 'C']), contains('A, B'));
      expect(copy.roundDone(['{rest}', 'B']), contains('{rest}'));
    });
  }
}
