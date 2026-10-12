import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/theme_studio_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_profile.dart';
import 'package:hermes_android/core/theme/theme_profile_derivation.dart';
import 'package:hermes_android/core/theme/theme_profile_store.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/theme_profile_fixtures.dart';
import 'support/quiet_feedback.dart';

Future<ThemeProfileStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  return ThemeProfileStore(await SharedPreferences.getInstance());
}

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: home,
);

Widget _scaledApp(Widget home, {double scale = 2}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('cyberpunk'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: home,
);

void main() {
  testWidgets('edits basic/advanced modes and persists a local draft', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await _store();
    var changed = 0;

    await tester.pumpWidget(
      _app(
        ThemeStudioScreen(
          initialProfile: validCustomTheme(
            id: 'theme-studio-draft',
            name: 'Tema de prueba',
            draft: true,
          ),
          store: store,
          onChanged: () async => changed++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('theme_studio_preview')), findsOneWidget);
    expect(find.byKey(const Key('theme_studio_palette')), findsOneWidget);
    expect(find.byKey(const Key('theme_color_background')), findsNothing);
    expect(find.byKey(const Key('theme_color_surface_variant')), findsNothing);
    expect(find.byKey(const Key('theme_studio_components')), findsNothing);
    expect(find.textContaining('0,99'), findsNothing);
    expect(find.text('Preparando una respuesta limpia…'), findsOneWidget);

    await tester.tap(find.byKey(const Key('theme_studio_palette')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('theme_color_background')), findsOneWidget);

    await tester.tap(find.text('Avanzado'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('theme_color_surface_variant')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('theme_color_accent_hover')), findsOneWidget);

    await tester.tap(find.text('Básico'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('theme_studio_name')),
      'Tema guardado',
    );
    await tester.ensureVisible(
      find.byKey(const Key('theme_studio_save_draft')),
    );
    await tester.tap(find.byKey(const Key('theme_studio_save_draft')));
    await tester.pumpAndSettle();

    final snapshot = await store.load();
    expect(snapshot.activeProfileId, AppTheme.defaultThemeId);
    expect(snapshot.customProfiles, hasLength(1));
    expect(snapshot.customProfiles.single.name, 'Tema guardado');
    expect(snapshot.customProfiles.single.draft, isTrue);
    expect(changed, 1);
    expectRoutineFeedback(tester, 'Borrador guardado.');
  });

  testWidgets('save and activate keeps the single Android component style', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await _store();
    var changed = 0;
    final profile = validCustomTheme(
      id: 'theme-studio-active',
      name: 'Tema activo',
      draft: true,
    ).copyWith(componentProfileId: 'soft');

    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => ThemeStudioScreen(
                      initialProfile: profile,
                      store: store,
                      onChanged: () async => changed++,
                    ),
                  ),
                ),
                child: const Text('Abrir estudio'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir estudio'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('theme_studio_save_activate')),
    );
    await tester.tap(find.byKey(const Key('theme_studio_save_activate')));
    await tester.pumpAndSettle();

    final snapshot = await store.load();
    expect(snapshot.activeProfileId, profile.id);
    expect(snapshot.activeComponentProfileId, 'minimal');
    expect(snapshot.customProfiles.single.draft, isFalse);
    expect(snapshot.customProfiles.single.componentProfileId, 'minimal');
    expect(changed, 1);
    expect(find.text('Abrir estudio'), findsOneWidget);
  });

  testWidgets('unsafe contrast remains draft-only in the editor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await _store();
    final original = validCustomTheme(draft: true);
    final invalid = original.copyWith(
      palette: original.palette.copyWith(
        accentText: original.palette.background,
      ),
    );

    await tester.pumpWidget(
      _app(ThemeStudioScreen(initialProfile: invalid, store: store)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('theme_studio_save_activate')),
    );

    final activate = tester.widget<FilledButton>(
      find.byKey(const Key('theme_studio_save_activate')),
    );
    expect(activate.onPressed, isNull);
    expect(find.byKey(const Key('theme_studio_repair')), findsOneWidget);

    await tester.tap(find.byKey(const Key('theme_studio_save_draft')));
    await tester.pumpAndSettle();
    expect((await store.load()).customProfiles.single.draft, isTrue);
  });

  testWidgets('exact reported draft is repaired and becomes activatable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await _store();
    const seeds = ThemeBasicSeeds(
      background: Color(0xFFDDA1FF),
      surface: Color(0xFF141414),
      accent: Color(0xFFDCD5FF),
      secondary: Color(0xFFFFFFEB),
      textPrimary: Color(0xFF7F7F7F),
    );
    final derived = ThemeProfileDeriver.deriveBasicPalette(
      seeds,
      brightness: ThemeProfileBrightness.dark,
    );
    final exactDraft = validCustomTheme(draft: true).copyWith(
      brightness: ThemeProfileBrightness.dark,
      palette: derived.palette,
    );

    await tester.pumpWidget(
      _app(ThemeStudioScreen(initialProfile: exactDraft, store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('theme_studio_repair')), findsOneWidget);
    var activate = tester.widget<FilledButton>(
      find.byKey(const Key('theme_studio_save_activate')),
    );
    expect(activate.onPressed, isNull);

    await tester.tap(find.byKey(const Key('theme_studio_repair')));
    await tester.pumpAndSettle();
    expect(find.textContaining('#FFDDA1FF'), findsOneWidget);
    expect(find.textContaining('#FF1B131F'), findsOneWidget);
    await tester.tap(find.text('Aplicar reparación'));
    await tester.pumpAndSettle();

    expect(find.text('Contraste listo para activar.'), findsOneWidget);
    expectRoutineFeedback(
      tester,
      'Contraste reparado. Revisa la vista previa antes de guardar.',
    );
    activate = tester.widget<FilledButton>(
      find.byKey(const Key('theme_studio_save_activate')),
    );
    expect(activate.onPressed, isNotNull);
  });

  testWidgets('font dropdown stays compact and selectable at 2x text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await _store();
    final profile = validCustomTheme(draft: true);

    await tester.pumpWidget(
      _scaledApp(ThemeStudioScreen(initialProfile: profile, store: store)),
    );
    await tester.pumpAndSettle();

    final dropdown = find.byKey(const ValueKey('theme_studio_font_Inter'));
    for (
      var attempt = 0;
      attempt < 5 && dropdown.evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -450));
      await tester.pumpAndSettle();
    }
    expect(dropdown, findsOneWidget);
    await tester.ensureVisible(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Nunito').last);
    await tester.pumpAndSettle();
    expect(find.text('Nunito'), findsWidgets);
    expect(find.textContaining('0,99'), findsNothing);
    expect(
      find.byKey(const ValueKey('theme_studio_font_Nunito')),
      findsOneWidget,
    );
    expect(
      tester
          .widgetList<Theme>(find.byType(Theme))
          .any(
            (theme) => theme.data.textTheme.bodyMedium?.fontFamily == 'Nunito',
          ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('light mode converts the palette live and dark restores it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await _store();
    final profile = validCustomTheme(draft: true);

    await tester.pumpWidget(
      _app(ThemeStudioScreen(initialProfile: profile, store: store)),
    );
    await tester.pumpAndSettle();

    Color previewBackground() {
      final preview = tester.widget<AnimatedContainer>(
        find.byKey(const Key('theme_studio_preview')),
      );
      return (preview.decoration! as BoxDecoration).color!;
    }

    final darkBackground = previewBackground();
    await tester.ensureVisible(
      find.byKey(const Key('theme_studio_brightness_light')),
    );
    await tester.tap(find.byKey(const Key('theme_studio_brightness_light')));
    await tester.pumpAndSettle();

    final lightBackground = previewBackground();
    expect(lightBackground, isNot(darkBackground));
    expect(lightBackground.computeLuminance(), greaterThan(0.7));

    await tester.tap(find.byKey(const Key('theme_studio_brightness_dark')));
    await tester.pumpAndSettle();
    expect(previewBackground(), darkBackground);
    expect(tester.takeException(), isNull);
  });
}
