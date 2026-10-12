// QA 9494 P2: the Themes screen showed the family subtitles in English
// («graphite · terracotta», «soft graphite · the signature»…) in a Spanish
// UI. Every built-in preset has a Spanish and an English subtitle.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/themes_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_profile_store.dart';
import 'package:hermes_android/core/theme/theme_tagline.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  test('every built-in preset has its own Spanish subtitle', () async {
    final es = await Strings.delegate.load(const Locale('es'));
    final en = await Strings.delegate.load(const Locale('en'));
    for (final preset in AppTheme.presets) {
      final spanish = themeTagline(es, preset);
      expect(spanish, isNot(preset.tagline), reason: preset.id);
      expect(spanish.trim(), isNotEmpty, reason: preset.id);
      expect(themeTagline(en, preset), preset.tagline, reason: preset.id);
    }
  });

  testWidgets('the Themes screen in Spanish shows no English subtitle', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 6000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('console'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: ThemesScreen(
          snapshotForTesting: const ThemeProfileStoreSnapshot(
            customProfiles: [],
            activeProfileId: 'console',
            activeComponentProfileId: 'minimal',
          ),
          onSelectForTesting: (id, {followSystem = false}) async {},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('grafito · terracota'), findsOneWidget);
    expect(find.text('carbón cálido · arcilla coral'), findsOneWidget);
    for (final english in [
      'graphite · terracotta',
      'soft graphite · the signature',
      'warm charcoal · coral clay',
    ]) {
      expect(find.text(english), findsNothing, reason: english);
    }
    expect(tester.takeException(), isNull);
  });
}
