import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_board_tiles.dart';
import 'package:hermes_android/core/services/startup_guard.dart';
import 'package:hermes_android/core/utils/relative_time.dart';
import 'package:hermes_android/core/widgets/activity_pill.dart';
import 'package:hermes_android/core/widgets/compaction_dock.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final now = DateTime(2026, 10, 23, 12);

  test('duration helpers keep Spanish and Portuguese decimal conventions', () {
    for (final entry in {'es': '0,7 s', 'pt': '0,7 s', 'en': '0.7 s',
      'de': '0,7 s', 'fr': '0,7 s', 'it': '0,7 s', 'ja': '0.7 s',
      'ko': '0.7 s', 'zh': '0.7 s', 'unknown': '0.7 s'}.entries) {
      const duration = Duration(milliseconds: 700);
      expect(formatStepDuration(duration, languageCode: entry.key), entry.value);
      expect(formatCompactionDuration(duration, languageCode: entry.key), entry.value);
    }
    expect(formatStepDuration(const Duration(seconds: 65)), '1:05');
    expect(formatCompactionDuration(const Duration(seconds: 65)), '65 s');
  });

  test('relative time keeps existing ES EN PT copy and accepts regional codes', () {
    final stamp = now.subtract(const Duration(minutes: 36)).millisecondsSinceEpoch / 1000;
    expect(relativeTime(stamp, languageCode: 'es', now: now), '36 min');
    expect(relativeTime(stamp, languageCode: 'pt_BR', now: now), '36 min');
    expect(relativeTime(stamp, languageCode: 'en', now: now), '36m ago');
    expect(relativeTime(stamp, languageCode: 'unknown', now: now), '36m ago');
    expect(relativeTime(0, languageCode: 'de', now: now), isEmpty);
  });

  testWidgets('home phrases preserve ES EN PT and do not add duplicate prefixes', (tester) async {
    for (final entry in {'es': ('hace 36 min', 'en 35 min'),
      'en': ('36m ago', 'in 35 min'), 'pt': ('há 36 min', 'em 35 min')}.entries) {
      await tester.pumpWidget(MaterialApp(
        locale: Locale(entry.key),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Builder(builder: (context) => Text(
          '${homeSince(context, now.subtract(const Duration(minutes: 36)), now)}|'
          '${homeCountdown(context, const Duration(minutes: 35))}',
        )),
      ));
      await tester.pumpAndSettle();
      expect(find.text('${entry.value.$1}|${entry.value.$2}'), findsOneWidget);
    }
  });

  testWidgets('startup recovery honors the explicit app preference', (tester) async {
    SharedPreferences.setMockInitialValues({'app_locale': 'de'});
    await runGuardedStartup(
      bootstrap: () async => throw const FormatException('fixture'),
      run: (app) => tester.pumpWidget(app),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byKey(StartupFailureApp.retryKey));
    expect(Localizations.localeOf(context).languageCode, 'de');
    expect(Strings.of(context).localeName, 'de');
  });
}
