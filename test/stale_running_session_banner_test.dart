import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/stale_running_session_banner.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host({
  required Locale locale,
  required String themeId,
  required VoidCallback onStop,
  VoidCallback? onDismiss,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId(themeId),
  home: MediaQuery(
    data: const MediaQueryData(
      size: Size(320, 800),
      textScaler: TextScaler.linear(2),
      disableAnimations: true,
    ),
    child: Scaffold(
      body: StaleRunningSessionBanner(
        enabled: true,
        onStop: onStop,
        onDismiss: onDismiss ?? () {},
      ),
    ),
  ),
);

void main() {
  testWidgets('localized stale Stop banner fits and stops once', (
    tester,
  ) async {
    var stopCalls = 0;
    for (final fixture in <({Locale locale, String theme, String action})>[
      (locale: const Locale('en'), theme: 'light', action: 'Stop this session'),
      (
        locale: const Locale('es'),
        theme: 'dark',
        action: 'Detener esta sesión',
      ),
    ]) {
      await tester.pumpWidget(
        _host(
          locale: fixture.locale,
          themeId: fixture.theme,
          onStop: () => stopCalls++,
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('stale-running-session-stop-banner')),
        findsOneWidget,
      );
      expect(find.text(fixture.action), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    }

    await tester.tap(find.byKey(const ValueKey('stale-running-session-stop')));
    await tester.pump();
    expect(stopCalls, 1);
  });

  testWidgets('the notice can be closed without stopping the session', (
    tester,
  ) async {
    var stopCalls = 0;
    var dismissCalls = 0;
    for (final key in const [
      ValueKey('stale-running-session-dismiss'),
      ValueKey('stale-running-session-keep'),
    ]) {
      await tester.pumpWidget(
        _host(
          locale: const Locale('es'),
          themeId: 'dark',
          onStop: () => stopCalls++,
          onDismiss: () => dismissCalls++,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (key.value == 'stale-running-session-dismiss') {
        // The compact close icon keeps a full 48 dp touch target.
        expect(
          tester.getSize(find.byKey(key)).height,
          greaterThanOrEqualTo(48),
        );
      }
      await tester.tap(find.byKey(key));
      await tester.pump();
    }
    expect(dismissCalls, 2);
    expect(stopCalls, 0);
  });
}
