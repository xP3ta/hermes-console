import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_board_tiles.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const expected = <String, (String, String)>{
    "es": ("hace 20 min", "en 5 h"),
    "en": ("20m ago", "in 5 h"),
    "pt": ("há 20 min", "em 5 h"),
    "de": ("vor 20 Min.", "in 5 Std."),
    "fr": ("il y a 20 min", "dans 5 h"),
    "it": ("20 min fa", "tra 5 h"),
    "ja": ("20分前", "5時間後"),
    "ko": ("20분 전", "5시간 후"),
    "zh": ("20分钟前", "5小时后"),
  };
  for (final entry in expected.entries) {
    testWidgets('${entry.key} complete past and future Home phrases', (tester) async {
      final now = DateTime(2026, 7, 26, 21);
      await tester.pumpWidget(MaterialApp(
        locale: Locale(entry.key),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Builder(builder: (context) => Text(
          '${homeSince(context, now.subtract(const Duration(minutes: 20)), now)}|'
          '${homeCountdown(context, const Duration(hours: 5))}',
        )),
      ));
      await tester.pumpAndSettle();
      expect(find.text('${entry.value.$1}|${entry.value.$2}'), findsOneWidget);
    });
  }
}
