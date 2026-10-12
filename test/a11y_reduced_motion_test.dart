import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_status_indicator.dart';
import 'package:hermes_android/core/widgets/status_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final entry in <String, Widget>{
    'HermesStatusPulse': const HermesStatusPulse(),
    'StatusPill(checking)': const StatusPill(status: InstanceStatus.checking),
  }.entries) {
    testWidgets('${entry.key} stops and resumes for reduced motion', (
      tester,
    ) async {
      await tester.pumpWidget(_host(entry.value, disableAnimations: true));
      await tester.pump();

      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(_host(entry.value, disableAnimations: false));
      await tester.pump();

      expect(tester.hasRunningAnimations, isTrue);
    });
  }

  testWidgets('onboarding glow stops and resumes for reduced motion', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final screen = OnboardingScreen(connManager: manager, onDone: () {});

    await tester.pumpWidget(_host(screen, disableAnimations: true));
    await tester.pump();

    expect(tester.hasRunningAnimations, isFalse);

    await tester.pumpWidget(_host(screen, disableAnimations: false));
    await tester.pump();

    expect(tester.hasRunningAnimations, isTrue);
  });
}

Widget _host(Widget child, {required bool disableAnimations}) => MaterialApp(
  locale: const Locale('en'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: child!,
  ),
  home: Scaffold(body: Center(child: child)),
);
