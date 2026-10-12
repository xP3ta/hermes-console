import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/embed_settings_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_consent_store.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_detector.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late EmbedConsentStore consent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    consent = EmbedConsentStore.forTesting(
      await SharedPreferences.getInstance(),
    );
  });

  Widget app() => MaterialApp(
    theme: AppTheme.fromId('dark'),
    locale: const Locale('en'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: EmbedSettingsScreen(store: consent),
  );

  testWidgets('one switch per type, all off, no Mermaid without approval', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    for (final type in EmbedType.values) {
      if (type == EmbedType.mermaid) {
        expect(find.byKey(const ValueKey('embed-type-mermaid')), findsNothing);
        continue;
      }
      expect(find.byKey(ValueKey('embed-type-${type.name}')), findsOneWidget);
      expect(
        tester
            .widget<Switch>(
              find.byKey(ValueKey('embed-type-${type.name}-switch')),
            )
            .value,
        isFalse,
        reason: type.name,
      );
    }
    expect(find.text('Always'), findsNothing);
    expect(find.byKey(const ValueKey('embed-clear-allowed')), findsNothing);
  });

  testWidgets('enabling a type asks each time; Always persists', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('embed-type-youtube-switch')));
    await tester.pump();
    expect(consent.modeFor(EmbedType.youtube), EmbedMode.ask);
    expect(find.text('Ask each time'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('embed-type-youtube-always-switch')),
    );
    await tester.pump();
    expect(consent.modeFor(EmbedType.youtube), EmbedMode.always);
    expect(consent.modeFor(EmbedType.vimeo), EmbedMode.off);
  });

  testWidgets('Clear allowed services sends always back to ask', (
    tester,
  ) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.always);
    await tester.pumpWidget(app());
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('embed-clear-allowed')),
      200,
    );
    await tester.tap(find.byKey(const ValueKey('embed-clear-allowed')));
    await tester.pump();
    expect(consent.modeFor(EmbedType.youtube), EmbedMode.ask);
    expect(find.byKey(const ValueKey('embed-clear-allowed')), findsNothing);
  });

  testWidgets('turning a type off hides its Always row', (tester) async {
    await consent.setMode(EmbedType.spotify, EmbedMode.always);
    await tester.pumpWidget(app());
    expect(
      find.byKey(const ValueKey('embed-type-spotify-always')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('embed-type-spotify-switch')));
    await tester.pump();
    expect(consent.modeFor(EmbedType.spotify), EmbedMode.off);
    expect(
      find.byKey(const ValueKey('embed-type-spotify-always')),
      findsNothing,
    );
  });
}
