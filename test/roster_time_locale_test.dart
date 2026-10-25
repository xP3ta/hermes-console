import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_rows.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

void main() {
  setUpAll(() => initializeDateFormatting());
  for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
    testWidgets('$lang roster time boundaries and calendar formatting', (tester) async {
      final now = DateTime(2026, 7, 26, 21);
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        locale: Locale(lang),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Builder(builder: (value) {
          context = value;
          return const SizedBox.shrink();
        }),
      ));
      await tester.pumpAndSettle();
      final (current, yesterday) = switch (lang) {
        "de" => ("jetzt", "gestern"),
        "fr" => ("à l’instant", "hier"),
        "it" => ("ora", "ieri"),
        "ja" => ("今", "昨日"),
        "ko" => ("지금", "어제"),
        "zh" => ("现在", "昨天"),
        'es' => ('ahora', 'ayer'),
        'pt' => ('agora', 'ontem'),
        _ => ('now', 'yesterday'),
      };
      expect(rosterTime(context, now.subtract(const Duration(seconds: 59)), now: now), current);
      expect(rosterTime(context, now.add(const Duration(seconds: 59)), now: now), current);
      expect(rosterTime(context, now.subtract(const Duration(minutes: 1)), now: now), '20:59');
      expect(rosterTime(context, now.subtract(const Duration(days: 1)), now: now), yesterday);
      final weekday = now.subtract(const Duration(days: 2));
      expect(rosterTime(context, weekday, now: now), DateFormat.E(lang).format(weekday));
      final older = now.subtract(const Duration(days: 7));
      expect(rosterTime(context, older, now: now), DateFormat.MMMd(lang).format(older));
    });
  }
}
