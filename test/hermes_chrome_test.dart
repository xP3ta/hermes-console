import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/floating.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';

/// CIE L* of [color] (perceptual lightness, 0–100).
double _lightness(Color color) {
  final y = ThemeContrast.luminance(color);
  return y > 0.008856 ? 116 * math.pow(y, 1 / 3).toDouble() - 16 : 903.3 * y;
}

void main() {
  group('floating chrome, every preset', () {
    test('the catalog is the one this rule was measured on', () {
      expect(AppTheme.presets.length, greaterThanOrEqualTo(40));
    });

    for (final preset in AppTheme.presets) {
      test('${preset.id}: lifted, legible and with an edge', () {
        final colors = AppTheme.fromId(preset.id).hermes;
        final chrome = HermesChrome.of(colors);

        expect(chrome.dark, preset.isDark);
        expect(
          chrome.fill.a,
          closeTo(
            preset.isDark
                ? HermesChrome.darkOpacity
                : HermesChrome.lightOpacity,
            0.005,
          ),
        );
        expect(chrome.opaque.a, 1.0);
        expect(chrome.ink, colors.textPrimary);

        // Inks on the chrome: primary at AAA, secondary at AA.
        expect(
          ThemeContrast.ratio(chrome.ink, chrome.opaque),
          greaterThanOrEqualTo(7.0),
          reason: 'primary ink',
        );
        expect(
          ThemeContrast.ratio(chrome.mutedInk, chrome.opaque),
          greaterThanOrEqualTo(4.5),
          reason: 'secondary ink',
        );

        // The step away from the page. Dark: about twice what the old
        // `surfaceVariant` at 92 % gave (7.5 L*). Light: white is close to
        // the page, so the hairline and the shadow carry the edge.
        final step = _lightness(chrome.opaque) - _lightness(colors.background);
        if (preset.isDark) {
          expect(step, greaterThanOrEqualTo(12.0), reason: 'lift');
          expect(step, lessThanOrEqualTo(16.0), reason: 'lift');
        } else {
          expect(step, greaterThanOrEqualTo(0.0), reason: 'never darker');
        }
        expect(chrome.line.a, greaterThan(0.1));
        expect(
          ThemeContrast.ratio(
            ThemeContrast.composite(chrome.line, chrome.opaque),
            colors.background,
          ),
          greaterThanOrEqualTo(preset.isDark ? 1.5 : 1.05),
          reason: 'hairline against the page',
        );
        expect(chrome.shadow, isNotEmpty);
      });
    }

    test('one object per palette', () {
      final colors = AppTheme.fromId('classic-dark').hermes;
      expect(identical(HermesChrome.of(colors), HermesChrome.of(colors)), true);
    });
  });

  group('floating chrome, custom palettes', () {
    HermesThemeColors palette({
      required Color background,
      required Color surfaceVariant,
      required Color textPrimary,
      required Color textSecondary,
    }) => HermesThemeColors(
      background: background,
      surface: surfaceVariant,
      surfaceVariant: surfaceVariant,
      accent: const Color(0xFF3F7DD8),
      accentHover: const Color(0xFF3F7DD8),
      onAccent: const Color(0xFFFFFFFF),
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      textDisabled: const Color(0xFF808080),
      error: const Color(0xFFD04040),
      success: const Color(0xFF40A060),
      warning: const Color(0xFFC08A20),
      divider: const Color(0xFF606060),
    );

    test('a weak secondary ink is lifted until it reads', () {
      final colors = palette(
        background: const Color(0xFF101014),
        surfaceVariant: const Color(0xFF3A3A44),
        textPrimary: const Color(0xFFF2F2F2),
        textSecondary: const Color(0xFF77777F),
      );
      final chrome = HermesChrome.of(colors);
      expect(
        ThemeContrast.ratio(colors.textSecondary, chrome.opaque),
        lessThan(4.5),
      );
      expect(
        ThemeContrast.ratio(chrome.mutedInk, chrome.opaque),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('a translucent token is read over the page', () {
      final colors = palette(
        background: const Color(0xFF1B1B22),
        surfaceVariant: const Color(0x80404050),
        textPrimary: const Color(0xFFF2F2F2),
        textSecondary: const Color(0xFFB8B8C0),
      );
      final chrome = HermesChrome.of(colors);
      expect(chrome.opaque.a, 1.0);
      expect(chrome.fill.a, closeTo(HermesChrome.darkOpacity, 0.005));
      expect(
        _lightness(chrome.opaque),
        greaterThan(_lightness(colors.background)),
      );
    });

    test('a light page gets white chrome', () {
      final colors = palette(
        background: const Color(0xFFEFEDE6),
        surfaceVariant: const Color(0xFFE2DFD5),
        textPrimary: const Color(0xFF2A2822),
        textSecondary: const Color(0xFF5E5A4E),
      );
      final chrome = HermesChrome.of(colors);
      expect(chrome.dark, isFalse);
      expect(chrome.fill.withValues(alpha: 1), const Color(0xFFFFFFFF));
      expect(chrome.line.a, closeTo(0.11, 0.005));
    });
  });

  test('scrims: a menu keeps the page readable, a dialog does not', () {
    expect(HermesChrome.scrimMenu, 0.22);
    expect(HermesChrome.scrimSheet, 0.42);
    expect(HermesChrome.scrimDialog, 0.50);
  });

  group('HermesFloatingSurface', () {
    Future<void> pump(WidgetTester tester, String themeId, Widget child) =>
        tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.fromId(themeId),
            home: Scaffold(body: Center(child: child)),
          ),
        );

    Material surfaceOf(WidgetTester tester) => tester.widget<Material>(
      find
          .descendant(
            of: find.byType(HermesFloatingSurface),
            matching: find.byType(Material),
          )
          .first,
    );

    for (final id in const ['classic-dark', 'classic', 'console']) {
      testWidgets('$id: paints the chrome of the theme, never a blur', (
        tester,
      ) async {
        await pump(
          tester,
          id,
          const HermesFloatingSurface(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text('Voz'),
          ),
        );
        final chrome = HermesChrome.of(AppTheme.fromId(id).hermes);
        final material = surfaceOf(tester);
        expect(material.color, chrome.fill);
        expect(
          material.shape,
          StadiumBorder(side: BorderSide(color: chrome.line)),
        );
        final shadow = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(HermesFloatingSurface),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect((shadow.decoration as ShapeDecoration).shadows, chrome.shadow);
        expect(find.byType(BackdropFilter), findsNothing);
        final text = tester.widget<RichText>(
          find.descendant(
            of: find.text('Voz'),
            matching: find.byType(RichText),
          ),
        );
        expect(text.text.style?.color, chrome.ink);
      });
    }

    testWidgets('a modal surface is opaque, and a nested one has no shadow', (
      tester,
    ) async {
      await pump(
        tester,
        'classic-dark',
        HermesFloatingSurface(
          modal: true,
          shadow: false,
          shape: HermesFloatingSurface.rounded(),
          child: const SizedBox(width: 120, height: 80),
        ),
      );
      final chrome = HermesChrome.of(AppTheme.fromId('classic-dark').hermes);
      expect(surfaceOf(tester).color, chrome.opaque);
      expect(
        find.descendant(
          of: find.byType(HermesFloatingSurface),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
    });

    testWidgets('a tap goes to the surface and splashes on it', (tester) async {
      var taps = 0;
      await pump(
        tester,
        'classic-dark',
        HermesFloatingSurface(
          onTap: () => taps++,
          padding: const EdgeInsets.all(12),
          child: const Text('Chats'),
        ),
      );
      await tester.tap(find.text('Chats'));
      expect(taps, 1);
      expect(
        find.descendant(
          of: find.byType(HermesFloatingSurface),
          matching: find.byType(InkWell),
        ),
        findsOneWidget,
      );
    });
  });
}
