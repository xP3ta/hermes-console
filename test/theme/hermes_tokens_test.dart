import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart';
import 'package:hermes_android/core/theme/motion.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/chat_notch.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/pill_morph.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';

void main() {
  group('the owner’s defaults for 1.4.0', () {
    test('sheet 32, page margin 18, reading 15/1.5, header button 44', () {
      expect(HermesRadius.sheet, 32);
      expect(HermesSpace.pageH, 18);
      expect(HermesType.reading.fontSize, 15);
      expect(HermesType.reading.fontWeight, FontWeight.w400);
      expect(HermesType.reading.height, 1.5);
      expect(HermesSize.iconButton, 44);
    });
  });

  group('one radius scale', () {
    test('from the largest down, as in mock 136 v2-A', () {
      final scale = [
        HermesRadius.tag,
        HermesRadius.sheet,
        HermesRadius.pane,
        HermesRadius.card,
        HermesRadius.row,
        HermesRadius.control,
        HermesRadius.chip,
      ];
      expect(scale, [999, 32, 28, 22, 16, 12, 6]);
    });

    test('the older names keep their values', () {
      expect(HermesRadius.group, HermesRadius.row);
      expect(HermesRadius.floating, HermesRadius.card);
      expect(HermesRadius.dialog, HermesRadius.card);
    });

    test('the work pane’s v2-A tokens are the same values', () {
      expect(ChatWorkspaceTokens.paneRadius, HermesRadius.pane);
      expect(ChatWorkspaceTokens.cardRadius, HermesRadius.card);
      expect(ChatWorkspaceTokens.rowRadius, HermesRadius.row);
      expect(ChatWorkspaceTokens.sheetRadius, HermesRadius.sheet);
      expect(ChatWorkspaceTokens.gap, HermesSpace.gap);
      expect(ChatWorkspaceTokens.inset, HermesSpace.inset);
      expect(ChatWorkspaceTokens.target, HermesSize.tap);
    });
  });

  group('sizes', () {
    test('touch target 48 whatever is drawn; pill 44, segment 40', () {
      expect(HermesSize.tap, 48);
      expect(HermesSize.pill, 44);
      expect(HermesSize.segment, 40);
    });

    test('four icon sizes', () {
      expect(
        [HermesIcon.sm, HermesIcon.md, HermesIcon.lg, HermesIcon.xl],
        [16, 18, 20, 24],
      );
    });
  });

  group('mono', () {
    test('the family is the bundled JetBrains Mono', () {
      expect(HermesType.monoFamily, 'JetBrainsMono');
      expect(HermesType.mono.fontFamily, HermesType.monoFamily);
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('family: ${HermesType.monoFamily}'));
    });
  });

  group('motion', () {
    test('the scale', () {
      expect(HermesMotion.fast, const Duration(milliseconds: 120));
      expect(HermesMotion.base, const Duration(milliseconds: 200));
      expect(HermesMotion.page, const Duration(milliseconds: 260));
      expect(HermesMotion.sheetOpen, const Duration(milliseconds: 300));
      expect(HermesMotion.sheetClose, const Duration(milliseconds: 260));
      expect(HermesMotion.breath, const Duration(milliseconds: 2000));
      expect(HermesMotion.emphasized, const Cubic(0.2, 0.8, 0.2, 1));
      expect(HermesMotion.standard, Curves.easeOutCubic);
    });

    test('spec 041’s Motion reads the same values', () {
      expect(Motion.fast, HermesMotion.fast);
      expect(Motion.base, HermesMotion.base);
      expect(Motion.page, HermesMotion.page);
      expect(Motion.enter, HermesMotion.standard);
      expect(Motion.exit, HermesMotion.exit);
      expect(Motion.size, HermesMotion.size);
    });

    Future<Duration> effective(WidgetTester tester, bool reduce) async {
      late Duration result;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: Builder(
            builder: (context) {
              result = HermesMotion.duration(context, HermesMotion.sheetOpen);
              return const SizedBox();
            },
          ),
        ),
      );
      return result;
    }

    testWidgets('reduce motion turns a duration off', (tester) async {
      expect(await effective(tester, true), Duration.zero);
      expect(await effective(tester, false), HermesMotion.sheetOpen);
    });
  });

  group('loose constants read the tokens', () {
    test('pill morph, notch breath, chat code and header buttons', () {
      expect(kPillMorphOpen, HermesMotion.sheetOpen);
      expect(kPillMorphClose, HermesMotion.sheetClose);
      expect(kPillMorphFade, HermesMotion.fast);
      expect(kChatNotchBreathPeriod, HermesMotion.breath);
      expect(kChatCodeFontFamily, HermesType.monoFamily);
      expect(FloatingChatHeader.buttonSize, HermesSize.iconButton);
    });
  });

  group('the raised level of floating chrome', () {
    final presets = AppTheme.presets;

    test('on a dark page it sits one step above the opaque surface', () {
      for (final preset in presets) {
        if (preset.brightness != Brightness.dark) continue;
        final chrome = HermesChrome.of(preset.colors);
        expect(
          chrome.raised.computeLuminance(),
          greaterThan(chrome.opaque.computeLuminance()),
          reason: preset.id,
        );
      }
    });

    test('on a light page it is surfaceVariant over the page', () {
      for (final preset in presets) {
        if (preset.brightness != Brightness.light) continue;
        final colors = preset.colors;
        expect(
          HermesChrome.of(colors).raised,
          ThemeContrast.composite(colors.surfaceVariant, colors.background),
          reason: preset.id,
        );
      }
      final console = AppTheme.fromId('console-light').hermes;
      final chrome = HermesChrome.of(console);
      expect(
        chrome.raised.computeLuminance(),
        lessThan(chrome.opaque.computeLuminance()),
      );
    });
  });

  group('scrollbar', () {
    test('a thin thumb in the tertiary ink', () {
      final colors = AppTheme.fromId('console').hermes;
      final theme = HermesScrollbar.theme(colors);
      expect(theme.thickness?.resolve(const {}), HermesScrollbar.thickness);
      expect(
        theme.thumbColor?.resolve(const {}),
        colors.textTertiary.withValues(alpha: HermesScrollbar.thumbOpacity),
      );
    });
  });
}
