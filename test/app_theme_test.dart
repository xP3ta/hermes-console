import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';

void main() {
  test('teal theme exposes teal colors through Material colorScheme', () {
    final theme = AppTheme.hermesTealTheme;
    final colors = theme.hermes;
    final scheme = theme.colorScheme;

    expect(scheme.brightness, Brightness.dark);
    expect(scheme.primary, colors.accent);
    expect(scheme.onPrimary, colors.onAccent);
    expect(scheme.secondary, colors.accentHover);
    expect(scheme.onSecondary, colors.onAccent);
    expect(scheme.surface, colors.surface);
    expect(scheme.onSurface, colors.textPrimary);
    expect(scheme.onSurfaceVariant, colors.textSecondary);
    expect(scheme.surfaceContainer, colors.surface);
    expect(scheme.surfaceContainerHighest, colors.surfaceVariant);
    expect(scheme.outline, colors.divider);
    expect(scheme.surfaceTint, colors.accent);
  });

  test('switches are the standard M3 switch on the accent track', () {
    for (final preset in AppTheme.presets) {
      final theme = AppTheme.fromId(preset.id);
      final colors = theme.hermes;
      final switchTheme = theme.switchTheme;
      final selected = <WidgetState>{WidgetState.selected};
      final idle = <WidgetState>{};

      // No glyph thumb: an icon font glyph painted a black square on device.
      expect(
        switchTheme.thumbIcon?.resolve(selected),
        isNull,
        reason: preset.id,
      );
      expect(switchTheme.thumbIcon?.resolve(idle), isNull, reason: preset.id);
      expect(switchTheme.thumbColor!.resolve(selected), Colors.white);
      expect(switchTheme.thumbColor!.resolve(idle), colors.textSecondary);
      expect(switchTheme.trackColor!.resolve(selected), colors.accent);
      expect(switchTheme.trackColor!.resolve(idle), colors.surfaceVariant);
      expect(
        switchTheme.thumbColor!.resolve(selected)!.a,
        1.0,
        reason: 'the thumb must be opaque, never transparent',
      );
    }
  });

  test('los avisos transitorios son superficies flotantes en cada tema', () {
    for (final preset in AppTheme.presets) {
      final theme = AppTheme.fromId(preset.id);
      final snack = theme.snackBarTheme;
      final shape = snack.shape;

      expect(snack.behavior, SnackBarBehavior.floating, reason: preset.id);
      expect(snack.elevation, greaterThanOrEqualTo(6), reason: preset.id);
      expect(snack.backgroundColor, theme.hermes.surface, reason: preset.id);
      expect(
        snack.insetPadding,
        const EdgeInsets.fromLTRB(16, 0, 16, 18),
        reason: preset.id,
      );
      expect(shape, isA<RoundedRectangleBorder>(), reason: preset.id);
      expect(
        (shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(16),
        reason: preset.id,
      );
    }
  });

  testWidgets('HermesInfoBanner usa una superficie elevada y sigue accesible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        home: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: HermesInfoBanner(
                'El servidor ofrece una lista limitada; pueden faltar conversaciones.',
              ),
            ),
          ),
        ),
      ),
    );

    final surface = tester.widget<Material>(
      find.byKey(const ValueKey('hermes-info-banner-surface')),
    );
    expect(surface.elevation, greaterThanOrEqualTo(3));
    expect(surface.shape, isA<RoundedRectangleBorder>());
    expect(tester.takeException(), isNull);
  });

  test('toggles y filas de ajustes comparten una sola jerarquía visual', () {
    final theme = AppTheme.hermesRedDark;
    expect(theme.listTileTheme.titleTextStyle?.fontSize, 14);
    expect(theme.listTileTheme.titleTextStyle?.fontWeight, FontWeight.w600);
    expect(theme.listTileTheme.titleTextStyle?.letterSpacing, 0);
    expect(theme.listTileTheme.subtitleTextStyle?.fontSize, 12);
    expect(theme.listTileTheme.subtitleTextStyle?.height, 1.35);

    for (final entity in Directory('lib/core').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      expect(source, isNot(contains('activeThumbColor')), reason: entity.path);
      if (entity.path.endsWith('/widgets/hermes_ui.dart')) continue;
      expect(
        source,
        isNot(contains('SwitchListTile')),
        reason: '${entity.path} debe usar HermesSwitchTile',
      );
    }
  });

  test('desplegables y menús usan tipografía neutral en todos los temas', () {
    for (final preset in AppTheme.presets) {
      final theme = AppTheme.fromId(preset.id);
      final colors = theme.hermes;
      final styles = [
        theme.dropdownMenuTheme.textStyle,
        theme.popupMenuTheme.textStyle,
        theme.popupMenuTheme.labelTextStyle?.resolve(const {}),
      ];
      for (final style in styles) {
        expect(style, isNotNull, reason: preset.id);
        expect(style!.fontSize, 14, reason: preset.id);
        expect(style.fontWeight, FontWeight.w500, reason: preset.id);
        expect(style.letterSpacing, 0, reason: preset.id);
        expect(style.color, colors.textPrimary, reason: preset.id);
      }
    }
  });

  testWidgets('un desplegable cabe a 320 dp con texto al 200 %', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 288,
                child: Builder(
                  builder: (context) => DropdownButtonFormField<String>(
                    initialValue: 'Servidor Hermes',
                    isExpanded: true,
                    style: Theme.of(context).dropdownMenuTheme.textStyle,
                    items: const [
                      DropdownMenuItem(
                        value: 'Servidor Hermes',
                        child: Text('Servidor Hermes'),
                      ),
                      DropdownMenuItem(
                        value: 'Este móvil',
                        child: Text('Este móvil'),
                      ),
                    ],
                    onChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final inherited = DefaultTextStyle.of(
      tester.element(find.text('Servidor Hermes')),
    ).style;
    expect(inherited.fontSize, 14);
    expect(inherited.fontWeight, FontWeight.w500);

    await tester.tap(find.text('Servidor Hermes'));
    await tester.pumpAndSettle();
    expect(find.text('Este móvil'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Razón de contraste WCAG entre dos colores (1 = nulo, 21 = máximo).
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  group('Todos los presets aplican su paleta de forma uniforme', () {
    for (final p in AppTheme.presets) {
      test('${p.id}: el colorScheme refleja los tokens hermes', () {
        final theme = AppTheme.fromId(p.id);
        final c = theme.hermes;
        final s = theme.colorScheme;
        expect(s.brightness, p.brightness, reason: p.id);
        expect(s.primary, c.accent, reason: p.id);
        expect(s.onPrimary, c.onAccent, reason: p.id);
        expect(s.surface, c.surface, reason: p.id);
        expect(s.onSurface, c.textPrimary, reason: p.id);
        expect(s.outline, c.divider, reason: p.id);
      });

      test('${p.id}: onAccent es legible sobre accent (contraste ≥ 3)', () {
        // Blinda la clase de bug "texto/icono negro hardcodeado sobre un botón
        // de acento": con tokens, todo tema debe garantizar contraste. 3.0 es el
        // mínimo WCAG AA para texto grande / componentes de UI.
        final c = AppTheme.fromId(p.id).hermes;
        expect(
          contrast(c.onAccent, c.accent),
          greaterThanOrEqualTo(3.0),
          reason: '${p.id}: onAccent ${c.onAccent} sobre accent ${c.accent}',
        );
      });
    }
  });
}
