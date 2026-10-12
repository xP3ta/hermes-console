// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unconsumed Bridge update banner is retired', () {
    expect(
      File('lib/core/widgets/bridge_update_banner.dart').existsSync(),
      isFalse,
    );
  });

  test('exclusive retired installer copy is absent in both catalogs', () {
    const retired = <String>[
      'ollStartFailed',
      'licOllamaNoTermux',
      'ollNotInstalledHint',
      'licStartTermuxRejected',
      'homeInstallingSub',
      'homeUninstallingSub',
      'homeLocalAgentInstalledNotRunning',
      'lasStartFirstBody',
      'lunLaunchError',
    ];
    for (final locale in ['en', 'es']) {
      final catalog =
          jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
              as Map<String, dynamic>;
      for (final key in retired) {
        expect(catalog.containsKey(key), isFalse, reason: '$locale:$key');
        expect(catalog.containsKey('@$key'), isFalse, reason: '$locale:@$key');
      }
    }
  });

  test('the pet surfaces nothing mounted are gone, with their copy', () {
    // The pet outside chats is the floating mascot now: Inicio's own pet,
    // its walk, the mini presence and the flagged build's settings page
    // were mounted nowhere.
    for (final path in const [
      'lib/core/companion/render/companion_home_mascot.dart',
      'lib/core/companion/render/companion_roaming_overlay.dart',
      'lib/core/companion/render/companion_presence.dart',
      'lib/core/widgets/mascot/float/mascot_settings_screen.dart',
    ]) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
    // No build flag decides whether the mascot exists: "Presencia" does.
    expect(
      File('lib/core/config/feature_flags.dart').readAsStringSync(),
      isNot(contains('HC_FLOATING_MASCOT')),
    );
    expect(
      File('lib/main.dart').readAsStringSync(),
      isNot(contains('FeatureFlags')),
    );
    const retired = <String>[
      'petPresenceMinimal',
      'petPresenceFull',
      'petPresenceOffDescription',
      'petPresenceMinimalDescription',
      'petPresenceFullDescription',
      'petRoamingTitle',
      'petRoamingSubtitle',
      'petShowOnHomeTitle',
      'petShowOnHomeSubtitle',
      'mascotTurnOff',
      'mascotOpenPets',
      'mascotSuggestionNotNow',
      'mascotMenuWhatsUp',
      'mascotMenuSuggest',
      'mascotMenuFloat',
      'mascotMenuKnowledge',
      'mascotMenuSettings',
      'mascotNothingRunning',
      'mascotNoSuggestions',
      'mascotSettingsTitle',
      'mascotSettingsSubtitle',
      'mascotSettingsEnabled',
      'mascotSettingsEnabledHint',
      'mascotSettingsPlacement',
      'mascotPlacementDock',
      'mascotPlacementFloat',
      'mascotSettingsSprite',
      'mascotSettingsSpriteAuto',
    ];
    const kept = <String>[
      'petPresenceOff',
      'petPresenceChat',
      'petPresenceEverywhere',
      'mascotMenuTalk',
      'mascotChange',
      'mascotMenuDock',
      'mascotMenuHide',
      'mascotSuggestionNever',
    ];
    for (final locale in ['en', 'es']) {
      final catalog =
          jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
              as Map<String, dynamic>;
      for (final key in retired) {
        expect(catalog.containsKey(key), isFalse, reason: '$locale:$key');
        expect(catalog.containsKey('@$key'), isFalse, reason: '$locale:@$key');
      }
      for (final key in kept) {
        expect(catalog.containsKey(key), isTrue, reason: '$locale:$key');
      }
    }
    final es =
        jsonDecode(File('lib/l10n/app_es.arb').readAsStringSync())
            as Map<String, dynamic>;
    expect(
      [
        es['petPresenceOff'],
        es['petPresenceChat'],
        es['petPresenceEverywhere'],
      ],
      ['Apagada', 'Solo en el chat', 'En toda la app'],
    );
  });
}
