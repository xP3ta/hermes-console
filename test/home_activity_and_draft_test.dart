import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Inicio › conversaciones recientes.
///
/// Dos quejas reales del mantenedor sobre este tile:
///  1. El borrador se anunciaba con una píldora "BORRADOR" en mayúsculas junto
///     al título ("cajitas feas"). El mockup de Conversaciones lo resuelve como
///     texto descriptivo hilado en la línea de vista previa.
///  2. La actividad en curso se pintaba con `colors.secondary` a pelo, al mismo
///     tamaño y peso que una vista previa normal: "se ve en blanco y no se sabe
///     ni qué está haciendo porque no se aprecia la diferencia con el título".
void main() {
  group('readableActivityTone', () {
    test('todos los temas del catálogo cruzan el umbral AA sobre su fondo', () {
      for (final preset in AppTheme.presets) {
        final colors = AppTheme.fromId(preset.id).hermes;
        final tone = resolveActivityTone(colors);
        final ratio = _contrast(tone, colors.background);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              'el tema "${preset.name}" (${preset.id}) deja la actividad en '
              '${ratio.toStringAsFixed(2)}:1',
        );
      }
    });

    test(
      'en ningún tema la actividad acaba con el color exacto del título',
      () {
        for (final preset in AppTheme.presets) {
          final colors = AppTheme.fromId(preset.id).hermes;
          final tone = resolveActivityTone(colors);
          // El caso Mono: `secondary` ya es el gris del título, y aclararlo
          // para cumplir AA lo deja idéntico — justo la queja original.
          expect(
            _contrast(tone, colors.textPrimary),
            greaterThanOrEqualTo(1.3),
            reason: 'el tema "${preset.name}" (${preset.id})',
          );
        }
      },
    );

    test('un tono que ya contrasta no se toca', () {
      const background = Color(0xFF0B0B0B);
      const tone = Color(0xFF4FB8C9); // secondary de Amber, ya legible
      expect(readableActivityTone(tone, background), tone);
    });

    test('un tono oscuro sobre fondo oscuro se aclara', () {
      const background = Color(0xFF0B0B0B);
      const tone = Color(0xFF1540B1); // secondary de Nous claro, lavado aquí
      final fixed = readableActivityTone(tone, background);
      expect(fixed, isNot(tone));
      expect(fixed.computeLuminance(), greaterThan(tone.computeLuminance()));
    });

    test('un tono claro sobre fondo claro se oscurece', () {
      const background = Color(0xFFFFFFFF);
      const tone = Color(0xFFFFE600);
      final fixed = readableActivityTone(tone, background);
      expect(fixed.computeLuminance(), lessThan(tone.computeLuminance()));
      expect(_contrast(fixed, background), greaterThanOrEqualTo(4.5));
    });
  });

  group('el tile de conversación reciente', () {
    Widget host(Widget child, {String themeId = 'dark'}) => MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId(themeId),
      home: Scaffold(body: child),
    );

    testWidgets('el borrador va hilado en la vista previa, sin píldora', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          HomeRecentSessionTileForTesting(
            sessionId: 'chat-1',
            title: 'Notas de la release',
            userPreview: 'Resume los cambios de la 1.2.10 en inglés',
            hasLocalDraft: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Ninguna "cajita" junto al título.
      expect(find.byType(HermesPill), findsNothing);
      expect(find.byKey(const ValueKey('home-draft-chat-1')), findsOneWidget);
      expect(
        find.text('Borrador · Resume los cambios de la 1.2.10 en inglés'),
        findsOneWidget,
      );
    });

    testWidgets('sin borrador la vista previa queda intacta', (tester) async {
      await tester.pumpWidget(
        host(
          HomeRecentSessionTileForTesting(
            sessionId: 'chat-2',
            title: 'Deploy a staging',
            userPreview: 'Desplegado, healthcheck en verde',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Desplegado, healthcheck en verde'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-draft-chat-2')), findsNothing);
    });

    testWidgets(
      'la actividad se distingue del título: tinte propio, punto y peso',
      (tester) async {
        for (final themeId in [
          'amber',
          'claude',
          'mono',
          'nous-dark',
          'cyberpunk',
        ]) {
          await tester.pumpWidget(
            host(
              HomeRecentSessionTileForTesting(
                sessionId: 'chat-3',
                title: 'Migrar tests de pagos',
                userPreview: 'Lo vemos mañana',
                activityLabel: 'ejecutando tarea',
              ),
              themeId: themeId,
            ),
          );
          await tester.pumpAndSettle();

          final chip = find.byKey(const ValueKey('home-activity-chat-3'));
          expect(chip, findsOneWidget, reason: 'tema $themeId');
          // La vista previa normal cede el sitio a la actividad.
          expect(find.text('Lo vemos mañana'), findsNothing);

          final context = tester.element(chip);
          final colors = Theme.of(context).hermes;
          final title = tester.widget<Text>(find.text('Migrar tests de pagos'));
          final label = tester.widget<Text>(find.text('ejecutando tarea'));

          // Color distinto del título y contraste suficiente sobre el fondo.
          expect(
            label.style!.color,
            isNot(title.style!.color),
            reason: 'tema $themeId',
          );
          expect(
            _contrast(label.style!.color!, colors.background),
            greaterThanOrEqualTo(4.5),
            reason: 'tema $themeId',
          );
          // Y un tinte de fondo propio: la señal no depende solo del color del
          // texto (que es lo que se veía "lavado").
          final decorated = tester.widget<Container>(
            find.descendant(of: chip, matching: find.byType(Container)).first,
          );
          final decoration = decorated.decoration as BoxDecoration;
          expect(decoration.color, isNotNull, reason: 'tema $themeId');
          expect(decoration.color!.a, greaterThan(0), reason: 'tema $themeId');
        }
      },
    );
  });
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
