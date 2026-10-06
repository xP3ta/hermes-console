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
}
