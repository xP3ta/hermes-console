// Spec 080: the Bot profile is the design reference. Its private `_Header`,
// `_Card` and `_Line` were replaced by the shared `HermesSectionHeader`,
// `HermesListGroup` and `HermesListRow`; this golden was recorded from the
// screen BEFORE that refactor, so it proves pixel parity of the primitives.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/bot_profile_screen.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/inter_font.dart';

void main() {
  setUpAll(loadInterFont);

  testWidgets('Bot profile pixel parity after moving onto design primitives', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const profile = AgentProfile(
      name: 'builder',
      model: 'gpt-5.5',
      provider: 'openai',
      description: 'Builds and tests Console',
      skillCount: 24,
      botModeUiMeta: {'title': 'Console Builder'},
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 1100),
            disableAnimations: true,
          ),
          child: BotProfileScreen(
            data: () => BotProfileData(
              profile: profile,
              signal: BotFaceSignal.working,
              now: [
                BotNowItem(
                  label: 'Working in «Design Review»',
                  detail: 'Room · 3 members',
                  onStop: () async {},
                ),
                const BotNowItem(
                  label: 'Waiting for approval',
                  attention: true,
                ),
              ],
              roomCount: 2,
              taskCount: 3,
            ),
            machineLabel: 'homelab',
            onChat: () {},
            onRoutines: () {},
            onSoul: () {},
            onSkills: () {},
            onMemory: () {},
            onTasks: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    // The living face animates; compare everything below the hero.
    await expectLater(
      find.byKey(const ValueKey('bot-profile-now')),
      matchesGoldenFile('goldens/bot_profile_now_group.png'),
    );
    await expectLater(
      find.byKey(const ValueKey('bot-profile-sections')),
      matchesGoldenFile('goldens/bot_profile_sections.png'),
    );
  });
}
