import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/ambient_backdrop.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/component_profile.dart';

/// QA 1.4.0: the terminal component profile drew 6 dp rectangles for its
/// action buttons (the SSH screens). They are pills; icon buttons and every
/// other profile keep what they had.
void main() {
  OutlinedBorder? resolved(ButtonStyle? style) =>
      style?.shape?.resolve(const <WidgetState>{});

  test('terminal profile action buttons are pills, icon buttons are not', () {
    for (final preset in AppTheme.presets) {
      final theme = AppTheme.fromId(
        preset.id,
        componentProfile: ComponentProfiles.terminal,
      );
      final reason = preset.id;
      for (final style in [
        theme.filledButtonTheme.style,
        theme.elevatedButtonTheme.style,
        theme.outlinedButtonTheme.style,
        theme.textButtonTheme.style,
      ]) {
        expect(resolved(style), isA<StadiumBorder>(), reason: reason);
      }
      expect(
        resolved(theme.iconButtonTheme.style),
        isA<RoundedRectangleBorder>(),
        reason: 'icon $reason',
      );
    }
  });

  test('the other profiles keep their button radius', () {
    for (final profile in ComponentProfiles.values) {
      if (profile.id == ComponentProfiles.terminal.id ||
          profile.id == ComponentProfiles.minimal.id) {
        continue;
      }
      final theme = AppTheme.fromId(
        AppTheme.presets.first.id,
        componentProfile: profile,
      );
      final shape = resolved(theme.filledButtonTheme.style);
      expect(shape, isA<RoundedRectangleBorder>(), reason: profile.id);
      expect(
        (shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(profile.shape.buttonRadius),
        reason: profile.id,
      );
    }
  });

  test('themes with a small corner radius draw pill action buttons', () {
    for (final preset in AppTheme.presets) {
      final theme = AppTheme.fromId(preset.id);
      for (final style in [
        theme.filledButtonTheme.style,
        theme.elevatedButtonTheme.style,
      ]) {
        final shape = resolved(style);
        if (preset.radius < 12) {
          expect(shape, isA<StadiumBorder>(), reason: preset.id);
        } else {
          expect(shape, isA<RoundedRectangleBorder>(), reason: preset.id);
        }
      }
    }
  });

  testWidgets('the glass gradient of a filled button stays inside its pill', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: hermesAmbientTheme(
          AppTheme.fromId(AppTheme.presets.first.id),
          level: GlassLevel.full,
        ),
        home: Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey('b'),
              onPressed: () {},
              style: FilledButton.styleFrom(shape: const StadiumBorder()),
              child: const Text('Configurar'),
            ),
          ),
        ),
      ),
    );
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byKey(const ValueKey('b')),
        matching: find.byType(Material),
      ),
    );
    expect(material.shape, isA<StadiumBorder>());
    final ink = tester.widget<Ink>(
      find.descendant(
        of: find.byKey(const ValueKey('b')),
        matching: find.byType(Ink),
      ),
    );
    final decoration = ink.decoration! as ShapeDecoration;
    expect(decoration.shape, isA<StadiumBorder>());
  });
}
