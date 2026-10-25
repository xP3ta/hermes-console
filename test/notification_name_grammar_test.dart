import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';

void main() {
  const pairs = <String, String>{
    "es": "A y B",
    "en": "A and B",
    "pt": "A e B",
    "de": "A und B",
    "fr": "A et B",
    "it": "A e B",
    "ja": "AとB",
    "ko": "A 및 B",
    "zh": "A和B",
  };
  const heads = <String, String>{
    "es": "A, B",
    "en": "A, B",
    "pt": "A, B",
    "de": "A, B",
    "fr": "A, B",
    "it": "A, B",
    "ja": "A・B",
    "ko": "A · B",
    "zh": "A、B",
  };
  for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
    test('$lang owns pair and list punctuation templates', () {
      final copy = NotifL10n(lang);
      expect(notificationCatalogs[lang]!['joinNamesPair'], isNotNull);
      expect(notificationCatalogs[lang]!['joinNamesHead'], isNotNull);
      final pair = copy.roundDone(['A', 'B']);
      expect(pair, contains(pairs[lang]!));
      expect(copy.roundDone(['A', 'A', 'B']), pair);
      expect(copy.roundDone(['A', 'B', 'C']), contains(heads[lang]!));
      expect(copy.roundDone(['{rest}', 'B']), contains('{rest}'));
    });
  }
}
