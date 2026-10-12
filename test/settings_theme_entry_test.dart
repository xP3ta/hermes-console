import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/component_profile.dart';
import 'package:hermes_android/core/theme/theme_profile_store.dart';

import 'support/theme_profile_fixtures.dart';

void main() {
  test('Ajustes identifica y previsualiza el tema personalizado activo', () {
    final custom = validCustomTheme(
      id: 'tema-personalizado-activo',
      name: 'Océano propio',
      draft: false,
    );
    final presentation = settingsThemePresentation(
      ThemeProfileStoreSnapshot(
        customProfiles: [custom],
        activeProfileId: custom.id,
        activeComponentProfileId: ComponentProfiles.soft.id,
      ),
    );

    expect(presentation.name, 'Océano propio');
    expect(presentation.colors.accent, custom.palette.accent);
    expect(presentation.colors.background, custom.palette.background);
    expect(presentation.total, AppTheme.familyCount + 1);
  });
}
