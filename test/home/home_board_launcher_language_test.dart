import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_board_kit.dart';
import 'package:hermes_android/core/home/board/home_board_tiles.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_geometry.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_palette.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_text.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_words.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/soft_tokens.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/design_shots.dart' show loadDesignFonts;
import '../support/home_board_fixtures.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';

void main() {
  setUpAll(loadDesignFonts);

  for (final theme in [
    'console',
    'console-light',
    'midnight',
    'midnight-light',
  ]) {
    testWidgets('$theme shares the launcher palette, typography and geometry', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId(theme),
          home: Builder(
            builder: (context) {
              final p = HomePalette.ofContext(context);
              final outside = LauncherWidgetPalette.of(
                Theme.of(context).hermes,
                fontFamily: Theme.of(context).textTheme.bodyMedium!.fontFamily!,
              );
              expect(p.text, outside.ink);
              expect(p.textMuted, outside.ink2);
              expect(HomeType.live(p), outside.accentText);
              expect(p.failure, outside.error);
              expect(p.surface.a, 1, reason: 'floating sheets stay opaque');
              for (final hue in SoftHue.values.where(
                (h) => h != SoftHue.neutral,
              )) {
                expect(p.tint(hue).ink, outside.accentText);
              }
              expect(
                HomeType.row(p),
                LwType.rowTitle.style(
                  fontFamily: outside.fontFamily,
                  color: outside.ink,
                ),
              );
              expect(
                HomeType.cap(p),
                LwType.eyebrow.style(
                  fontFamily: outside.fontFamily,
                  color: outside.ink2,
                ),
              );
              expect(HomeType.huge(context, p).fontSize, LwGrid.big);
              expect(HomeCard.contentPadding, const EdgeInsets.all(LwGrid.pad));
              expect(
                HomeCard.radiusOf(context),
                BorderRadius.circular(LwGrid.radius),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('$theme whole figures at ${scale}x on phone and Fold', (
        tester,
      ) async {
        for (final width in [320.0, 360.0, 412.0, 600.0, 840.0]) {
          final columns = width >= 840 ? 4 : 2;
          final cell = (width - 34 - 11 * (columns - 1)) / columns;
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.fromId(theme),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: cell,
                      height: 165,
                      child: const HomeCard(
                        child: HomeFigure('18:30', unit: 'horas restantes'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(find.text('18:30'), findsOneWidget);
          final number = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.text('18:30'),
              matching: find.byType(RichText),
            ),
          );
          expect(number.didExceedMaxLines, isFalse, reason: '$width at $scale');
          expect(
            number.textSize.width,
            lessThanOrEqualTo(number.size.width + .01),
          );
          final text = tester.widget<Text>(find.text('18:30'));
          expect(
            text.style!.fontFamily,
            theme.startsWith('midnight') ? 'JetBrainsMono' : 'Inter',
          );
        }
      });
    }
  }

  testWidgets('a short wide Ahora keeps its approval buttons', (tester) async {
    final calls = await pumpHomeTile(
      tester,
      kind: HomeWidgetKind.now,
      size: HomeWidgetSize.wide,
      cell: homeCell(HomeWidgetSize.wide, row: 140),
      data: homeData(approvals: [homeApproval()]),
    );
    expect(find.text('Permitir'), findsOneWidget);
    expect(find.text('Rechazar'), findsOneWidget);
    await tester.tap(find.text('Permitir'));
    await tester.pump();
    expect(calls.answers, [('a1', true)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('live times use the launcher calendar at 12 h and 24 h', (
    tester,
  ) async {
    final now = DateTime(2026, 11, 3, 16);
    final later = now.add(const Duration(hours: 2, minutes: 14));
    for (final language in ['es', 'en', 'ja']) {
      for (final use24h in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(alwaysUse24HourFormat: use24h),
              child: Builder(
                builder: (context) {
                  final words = LwWords(
                    Strings.of(context),
                    locale: Locale(language),
                    use24h: use24h,
                    nowMs: now.millisecondsSinceEpoch,
                  );
                  expect(
                    homeWhen(context, later, now),
                    words.time(later.millisecondsSinceEpoch),
                  );
                  expect(
                    homeCountdown(context, later.difference(now)),
                    words.inTime(later.millisecondsSinceEpoch),
                  );
                  expect(
                    homeCountdown(context, Duration.zero),
                    words.s.lwpInMinutes(0),
                  );
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
      }
    }
  });
}
