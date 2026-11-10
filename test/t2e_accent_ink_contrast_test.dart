// Wave 8 (audit 1.4.0 §2.13, §2.14): accent text and badge labels painted
// in the raw accent (or accentHover) fell under 4.5:1 on light pages
// (#F0A848 on #F7F7F7 is 1.88:1). A label on its own tinted pill now
// reaches 4.5:1 over any surface of every preset.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart' show HermesChrome;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/readable_ink.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';

void main() {
  test('an ink on its tint reads at 4.5:1 over every surface', () {
    final fails = <String>[];
    for (final preset in AppTheme.presets) {
      final c = preset.colors;
      final cases = <(String, Color, Color)>[
        for (final (name, ink) in [
          ('accent', c.accent),
          ('accentHover', c.accentHover),
          ('accentText', c.accentText),
          ('success', c.success),
          ('warning', c.warning),
          ('error', c.error),
          ('textSecondary', c.textSecondary),
        ])
          ('badge $name', ink, ink.withValues(alpha: HermesBadge.tint)),
        ('choice', c.accentText, c.accent.withValues(alpha: 0.16)),
        ('voice pill', c.accent, c.accent.withValues(alpha: 0.12)),
        // Round 3 (voice v2 and the tool pills).
        for (final (name, tone) in [
          ('accent', c.accent),
          ('error', c.error),
          ('warning', c.warning),
        ])
          ('voice line action $name', tone, tone.withValues(alpha: 0.2)),
        ('tool pill done', c.textSecondary, c.success.withValues(alpha: 0.12)),
        ('tool pill failed', c.textSecondary, c.error.withValues(alpha: 0.12)),
      ];
      for (final (what, ink, tint) in cases) {
        final readable = readableInkOnTint(ink, tint, c);
        for (final surface in [
          c.background,
          c.surface,
          c.surfaceVariant,
          HermesChrome.of(c).opaque,
        ]) {
          final behind = ThemeContrast.composite(tint, surface);
          final ratio = ThemeContrast.ratio(readable, behind);
          if (ratio + 1e-9 < 4.5) fails.add('${preset.id} $what $ratio');
        }
      }
    }
    expect(fails, isEmpty, reason: fails.join('\n'));
  });

  test('an ink that already reads is left as it is', () {
    final c = AppTheme.fromId('console').hermes;
    const white = Color(0xFFFFFFFF);
    expect(
      readableInkOnTint(white, white.withValues(alpha: 0.07), c),
      white,
    );
  });

  testWidgets('a badge in a light theme paints its readable ink', (
    tester,
  ) async {
    final theme = AppTheme.fromId('console-light');
    final colors = theme.hermes;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Center(
            child: HermesBadge('login', color: colors.accent, dot: false),
          ),
        ),
      ),
    );

    final label = tester.widget<Text>(find.text('LOGIN'));
    expect(label.style?.color, HermesBadge.readableInk(colors.accent, colors));
    final behind = ThemeContrast.composite(
      colors.accent.withValues(alpha: HermesBadge.tint),
      colors.surfaceVariant,
    );
    expect(
      ThemeContrast.ratio(label.style!.color!, behind),
      greaterThanOrEqualTo(4.5),
    );
  });
}
