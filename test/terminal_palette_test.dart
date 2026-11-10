import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/terminal_palette.dart';

void main() {
  group('hermesTerminalTheme (gap 2, Desktop selection.ts)', () {
    test('light app: VS Code light palette on the light surface', () {
      final theme = AppTheme.hermesRedLight;
      final t = hermesTerminalTheme(theme);
      expect(theme.brightness, Brightness.light);
      expect(t.background, theme.hermes.surface);
      expect(t.foreground, const Color(0xFF333333));
      expect(t.cursor, const Color(0xFF333333));
      expect(t.selection, const Color(0x80ADD6FF));
      expect(t.green, const Color(0xFF00BC00));
      expect(t.yellow, const Color(0xFF949800));
      expect(t.blue, const Color(0xFF0451A5));
      expect(t.white, const Color(0xFF555555));
      expect(t.brightWhite, const Color(0xFFA5A5A5));
    });

    test('dark app: VS Code dark palette on the dark surface', () {
      final theme = AppTheme.hermesRedDark;
      final t = hermesTerminalTheme(theme);
      expect(theme.brightness, Brightness.dark);
      expect(t.background, theme.hermes.surface);
      expect(t.foreground, const Color(0xFFCCCCCC));
      expect(t.selection, const Color(0x66264F78));
      expect(t.green, const Color(0xFF0DBC79));
      expect(t.yellow, const Color(0xFFE5E510));
      expect(t.brightWhite, const Color(0xFFE5E5E5));
    });

    test('text reads on its background in both themes (WCAG AA)', () {
      double luminance(Color c) => c.computeLuminance();
      double contrast(Color a, Color b) {
        final la = luminance(a), lb = luminance(b);
        final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      for (final theme in [AppTheme.hermesRedLight, AppTheme.hermesRedDark]) {
        final t = hermesTerminalTheme(theme);
        expect(
          contrast(t.foreground, t.background),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.brightness}',
        );
      }
    });
  });
}
