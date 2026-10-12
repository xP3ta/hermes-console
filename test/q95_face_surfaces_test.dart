import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/home/board/home_board_data.dart';
import 'package:hermes_android/core/home/board/home_board_tiles.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/soft_tokens.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/core/widgets/profile_face.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/face_halo.dart';

/// QA 9494 owner report (black halo around the room pill faces), audited
/// on every other surface that draws a bot face. Shared rule (lib/core/widgets/face_marks.dart): a face
/// is drawn straight on whatever holds it — no separator ring, no backing,
/// no shadow; its state is a plain dot. Every pixel in a 3 dp band around
/// each face that the face itself does not paint must be exactly what is
/// behind (ΔE ≤ 3), on dark and light themes and on every surface a face
/// sits on (page, card, sheet).
final _themes = <String, ThemeData Function()>{
  'dark': () => AppTheme.fromId('console'),
  'light': () => AppTheme.fromId('console-light'),
  'oled': () => AppTheme.hermesRedOled,
};

Widget _shell(ThemeData theme, Widget child, {Color? backing}) =>
    RepaintBoundary(
      key: haloShotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: theme,
        home: Scaffold(
          backgroundColor: backing,
          body: Align(alignment: Alignment.topCenter, child: child),
        ),
      ),
    );

Future<void> _size(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('every face surface: no ring, backing or shadow', () {
    // (name, widget, face finder, dots)
    final cases =
        <
          String,
          (
            Widget Function(),
            List<ExpectedDot> Function(ThemeData theme, BuildContext ctx),
          )
        >{
          // Home widgets: a face with its waiting dot.
          'home-face': (
            () => HomeFace(
              profileName: 'astra',
              data: HomeBoardData(now: DateTime(2026, 10, 7)),
              state: HomeBotState.waiting,
              size: 40,
            ),
            (theme, ctx) => [
              ExpectedDot(
                find.byKey(const ValueKey('home-face-dot-astra')),
                homeBotDotColor(
                  SoftPalette.ofContext(ctx),
                  HomeBotState.waiting,
                )!,
              ),
            ],
          ),
          // Bots home grid and pinned row: the calm face and its dot.
          'bots-home-calm': (
            () => const LivingBotFace(
              profileName: 'radar',
              profile: AgentProfile(
                name: 'radar',
                botModeUiMeta: {'shape': 'blobatar::hexagon'},
              ),
              signal: BotFaceSignal.working,
              size: 56,
              entrance: false,
              style: LivingBotFaceStyle.calm,
            ),
            (theme, ctx) => [
              ExpectedDot(
                find.byKey(const ValueKey('calm-face-dot-working')),
                theme.hermes.accent,
                tolerance: 25,
              ),
            ],
          ),
          // Bots home room stacks and Home widgets at 40 dp and more.
          'dots-face': (
            () => const LivingBotFace(
              profileName: 'forja',
              signal: BotFaceSignal.idle,
              size: 48,
              entrance: false,
              style: LivingBotFaceStyle.dots,
            ),
            (theme, ctx) => const [],
          ),
          // Drawer list and profile switcher rows: a working profile.
          'profile-face': (
            () => const ProfileFace(
              profileName: 'argos',
              profile: AgentProfile(
                name: 'argos',
                botModeUiMeta: {'shape': 'blobatar::cloud'},
              ),
              working: true,
              size: 30,
            ),
            (theme, ctx) => [
              ExpectedDot(
                find.byKey(const ValueKey('profile-face-working-argos')),
                theme.hermes.success,
              ),
            ],
          ),
        };
    for (final themeEntry in _themes.entries) {
      for (final c in cases.entries) {
        for (final backing in const ['page', 'surface', 'surfaceVariant']) {
          testWidgets('${c.key} on $backing (${themeEntry.key})', (
            tester,
          ) async {
            final theme = themeEntry.value();
            final colors = theme.hermes;
            final color = switch (backing) {
              'page' => colors.background,
              'surface' => colors.surface,
              _ => colors.surfaceVariant,
            };
            await _size(tester, const Size(120, 120));
            await tester.pumpWidget(
              _shell(
                theme,
                Padding(
                  padding: const EdgeInsets.only(top: 30),
                  child: c.value.$1(),
                ),
                backing: color,
              ),
            );
            await tester.pump(const Duration(seconds: 1));
            final ctx = tester.element(find.byType(Scaffold));
            final dots = c.value.$2(theme, ctx);
            for (final d in dots) {
              expect(d.finder, findsOneWidget);
            }
            final report = await probeHalo(
              tester,
              faces: find.byType(HermesBotFace),
              behind: (_, _) => color,
              theme: theme,
              dots: dots,
              saveAs: '${c.key}-$backing-${themeEntry.key}',
            );
            expect(report.checked, greaterThan(1000), reason: '$report');
            expect(report.bad, lessThanOrEqualTo(report.checked ~/ 100),
                reason: '$report');
            if (dots.isNotEmpty) {
              expect(report.dotChecked, greaterThan(60), reason: '$report');
              expect(
                report.dotBad,
                lessThanOrEqualTo(report.dotChecked ~/ 50),
                reason: '$report',
              );
            }
          });
        }
      }
    }
  });

  // QA 9494: a contact shadow under the face read as a dark smudge on light
  // pages; no face paints a gradient or shadow of its own around it.
  testWidgets('no face paints a contact shadow or a backing of its own', (
    tester,
  ) async {
    for (final themeEntry in _themes.entries) {
      for (final style in LivingBotFaceStyle.values) {
        await _size(tester, const Size(120, 120));
        await tester.pumpWidget(
          _shell(
            themeEntry.value(),
            LivingBotFace(
              profileName: 'forja',
              signal: BotFaceSignal.idle,
              size: 56,
              entrance: false,
              style: style,
            ),
            backing: themeEntry.value().hermes.background,
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        // Around the face, not the face's own drawing.
        final painted = find
            .descendant(
              of: find.byType(LivingBotFace),
              matching: find.byType(DecoratedBox),
            )
            .evaluate()
            .where(
              (e) => e.findAncestorWidgetOfExactType<HermesBotFace>() == null,
            )
            .map((e) => (e.widget as DecoratedBox).decoration)
            .whereType<BoxDecoration>()
            .where(
              (d) =>
                  d.gradient != null ||
                  (d.boxShadow?.isNotEmpty ?? false) ||
                  d.border != null,
            );
        expect(painted, isEmpty, reason: '$style (${themeEntry.key})');
      }
    }
  });
}
