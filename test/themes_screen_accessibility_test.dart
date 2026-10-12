import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/themes_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  Widget themesApp({double textScale = 1}) => MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.fromId('amber'),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: const ThemesScreen(),
  );

  testWidgets('muestra los doce temas oficiales de Hermes Desktop', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(themesApp());
    await tester.pump();

    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    for (
      var i = 0;
      i < 5 && find.text('Hermes Desktop · 12').evaluate().isEmpty;
      i++
    ) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pump();
    }
    expect(find.text('Hermes Desktop · 12'), findsOneWidget);
    for (var i = 0; i < 12 && find.text('Cyberpunk').evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pump();
    }
    expect(find.text('Cyberpunk'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('galería resiste texto 2x y elimina animaciones decorativas', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(themesApp(textScale: 2));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byKey(const Key('themes_create')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const Key('themes_create')),
        matching: find.byType(ListView),
      ),
      findsNothing,
    );
    final createSize = tester.getSize(find.byKey(const Key('themes_create')));
    expect(createSize.width, greaterThanOrEqualTo(48));
    expect(createSize.height, greaterThanOrEqualTo(48));
    expect(find.byKey(const Key('component_profile_terminal')), findsNothing);
    expect(find.byType(GridView), findsNothing);
    final nousDark = find.byKey(const ValueKey('desktop-theme-nous-dark'));
    await tester.scrollUntilVisible(
      nousDark,
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 20,
    );
    expect(
      find.byKey(const ValueKey('desktop-theme-nous-light')),
      findsOneWidget,
    );
    expect(nousDark, findsOneWidget);
    for (final container in tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    )) {
      expect(container.duration, Duration.zero);
    }
  });

  testWidgets('one card per family, each with a Light/Dark selector', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(themesApp());
    await tester.pump();

    final families = <String, List<HermesThemePreset>>{};
    for (final preset in AppTheme.presets) {
      families.putIfAbsent(preset.familyId, () => []).add(preset);
    }
    expect(families, hasLength(20));
    final scrollable = find.byType(Scrollable).first;
    for (final entry in families.entries) {
      final section = entry.value.first.desktopOfficial ? 'desktop' : 'console';
      final dark = find.byKey(ValueKey('$section-theme-${entry.key}-dark'));
      await tester.scrollUntilVisible(
        dark,
        200,
        scrollable: scrollable,
        maxScrolls: 60,
      );
      expect(dark, findsOneWidget, reason: entry.key);
      expect(
        find.byKey(ValueKey('$section-theme-${entry.key}-light')),
        findsOneWidget,
        reason: entry.key,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Claude shows as a single card with both modes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(themesApp());
    await tester.pump();

    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('Claude Light'), findsNothing);
    expect(
      find.byKey(const ValueKey('console-theme-claude-light')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('console-theme-claude-dark')),
      findsOneWidget,
    );
    expect(find.text('Hermes Console · 8'), findsOneWidget);
    // Quiet UI: no "N themes · tap to apply" hint under the header.
    expect(find.text('20 temas incluidos · toca para aplicar'), findsNothing);
  });
}
