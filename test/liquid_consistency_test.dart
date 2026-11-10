import 'package:hermes_android/core/design/floating.dart';
// The chat and the lists wear the same liquid material as the buttons that
// already had it: the gel (rims, sheen, press) over the theme's own grey,
// never over a smoked or darker one. And the segmented control is a pill
// whose selected pill slides.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BackdropFilterLayer;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/gel_surface.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/chat/chat_pinned_prompt_header.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(
  Widget child, {
  String themeId = 'classic-dark',
  bool reduceMotion = false,
  double textScale = 1,
  Alignment alignment = Alignment.center,
}) => MaterialApp(
  theme: AppTheme.fromId(themeId),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      textScaler: TextScaler.linear(textScale),
    ),
    child: home!,
  ),
  home: Scaffold(
    body: Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: child,
      ),
    ),
  ),
);

Finder _gel(String key) => find.byKey(ValueKey(key));

void main() {
  test('the sheen a piece paints over its text keeps every ink at AA (or at '
      'the contrast it had) on the grey chrome, in every preset', () {
    var lightKeepsAll = true;
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final chrome = HermesChrome.of(colors);
      for (final kind in HermesGelInks.values) {
        final scale = HermesGel.textSheenScale(colors, kind);
        expect(scale, inInclusiveRange(0, 1), reason: preset.id);
        final peak = HermesGel.of(colors).sheen;
        final lit = ThemeContrast.composite(
          peak.withValues(alpha: peak.a * scale),
          chrome.opaque,
        );
        for (final ink in HermesGel.inksOf(colors, kind)) {
          final base = ThemeContrast.ratio(ink, chrome.opaque);
          final got = ThemeContrast.ratio(ink, lit);
          expect(
            got,
            greaterThanOrEqualTo((base < 4.5 ? base : 4.5) - 1e-6),
            reason: '${preset.id} $kind: $base -> $got at $scale',
          );
        }
        if (!chrome.dark && scale < 1) lightKeepsAll = false;
      }
    }
    expect(lightKeepsAll, isTrue, reason: 'a light sheen only helps dark ink');
  });

  test('a round header button keeps its icon at AA under the sheen that '
      'reaches the glyph\'s nearest corner', () {
    const button = Size.square(FloatingChatHeader.buttonSize);
    const glyph = 24.0;
    final (from, to) = HermesGel.line(button, HermesGel.sheenAngle);
    final corner = Offset(
      (button.width - glyph) / 2,
      (button.height - glyph) / 2,
    );
    final axis = to - from;
    final along =
        ((corner - from).dx * axis.dx + (corner - from).dy * axis.dy) /
        (axis.dx * axis.dx + axis.dy * axis.dy);
    final share = (1 - along / HermesGel.sheenStop).clamp(0.0, 1.0);
    // The centre of the button is clear of the sheen altogether.
    expect(HermesGel.sheenStop, lessThan(0.5));
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final chrome = HermesChrome.of(colors);
      final peak = HermesGel.of(colors).sheen;
      final lit = ThemeContrast.composite(
        peak.withValues(alpha: peak.a * share),
        chrome.opaque,
      );
      final base = ThemeContrast.ratio(chrome.ink, chrome.opaque);
      expect(
        ThemeContrast.ratio(chrome.ink, lit),
        greaterThanOrEqualTo(base < 4.5 ? base : 4.5),
        reason: '${preset.id} at $share',
      );
    }
  });

  for (final themeId in const ['classic-dark', 'classic']) {
    group(themeId, () {
      testWidgets('a header button is the gel over the chrome grey, not a '
          'smoked one', (tester) async {
        var taps = 0;
        await tester.pumpWidget(
          _host(
            FloatingHeaderButton(
              icon: Icons.menu_rounded,
              tooltip: 'Menú',
              onPressed: () => taps++,
            ),
            themeId: themeId,
          ),
        );
        final chrome = HermesChrome.of(AppTheme.fromId(themeId).hermes);
        expect(_gel('floating-header-button-gel'), findsOneWidget);
        expect(
          tester.widget<HermesGelSurface>(_gel('floating-header-button-gel')),
          isA<HermesGelSurface>().having(
            (g) => g.tone,
            'tone',
            HermesGelTone.glass,
          ),
        );
        final face =
            tester
                    .widget<DecoratedBox>(
                      find.byKey(const ValueKey('floating-header-button-face')),
                    )
                    .decoration
                as ShapeDecoration;
        expect(face.color, chrome.fill);
        expect(
          tester.getSize(_gel('floating-header-button-gel')),
          const Size(48, 48),
        );
        await tester.tap(find.byIcon(Icons.menu_rounded));
        expect(taps, 1);
      });

      testWidgets('the name pill and the round prompt arrow share the chrome', (
        tester,
      ) async {
        await tester.pumpWidget(
          _host(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const IslandSurface(child: SizedBox(height: 32, width: 120)),
                const IslandSurface(
                  behind: true,
                  child: SizedBox(height: 32, width: 120),
                ),
                ChatPinnedPromptHeader(
                  youLabel: 'Tú',
                  text: 'Gracias',
                  attachmentCount: 0,
                  semanticLabel: 'Prompt',
                  hideLabel: 'Ocultar',
                  onTap: () {},
                  onHide: () {},
                ),
              ],
            ),
            themeId: themeId,
          ),
        );
        // The one waiting behind stays quieter: no gel.
        expect(_gel('island-gel'), findsOneWidget);
        final arrow = find.byKey(const ValueKey('chat-jump-to-prompt'));
        expect(tester.getSize(arrow), const Size(48, 48));
        final floating = find.descendant(
          of: arrow,
          matching: find.byType(HermesFloatingSurface),
        );
        expect(floating, findsOneWidget);
        expect(
          tester.widget<HermesFloatingSurface>(floating).shape,
          isA<StadiumBorder>(),
        );
        final face = tester.widget<Material>(
          find.descendant(of: floating, matching: find.byType(Material)).first,
        );
        expect(
          face.color,
          HermesChrome.of(AppTheme.fromId(themeId).hermes).fill,
        );
        // Still the solid chrome underneath: nothing translucent over the
        // transcript.
        final chrome = HermesChrome.of(AppTheme.fromId(themeId).hermes);
        final material = tester.widget<Material>(
          find
              .descendant(
                of: _gel('island-gel'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(material.color, chrome.opaque);
      });

      testWidgets('the foot: the input and the status pill are gel over the '
          'opaque grey, with no blur and no smoked tone', (tester) async {
        final text = TextEditingController();
        final focus = FocusNode();
        final metrics = ValueNotifier(const SessionContextMetrics(percent: 14));
        addTearDown(text.dispose);
        addTearDown(focus.dispose);
        addTearDown(metrics.dispose);
        await tester.pumpWidget(
          _host(
            ConsoleComposer(
              controller: text,
              focusNode: focus,
              onSend: (_, _) {},
              footer: ChatStatusPill(
                metrics: metrics,
                onOpenContext: () {},
                modelLabel: 'Modelo',
                onOpenModel: () {},
              ),
            ),
            themeId: themeId,
            alignment: Alignment.bottomCenter,
          ),
        );
        await tester.pumpAndSettle();
        final chrome = HermesChrome.of(AppTheme.fromId(themeId).hermes);
        final composerGel = tester.widget<HermesGelSurface>(
          _gel('hermes-composer-gel'),
        );
        expect(composerGel.shape, isA<RoundedRectangleBorder>());
        expect(
          (composerGel.shape as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(HermesRadius.pane),
        );
        expect(composerGel.tone, HermesGelTone.glass);
        final pillGel = tester.widget<HermesGelSurface>(
          _gel('status-pill-gel'),
        );
        expect(
          (pillGel.shape as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(HermesRadius.tag),
        );
        // The base is the theme's opaque grey, as before.
        final composer =
            tester
                    .widget<AnimatedContainer>(
                      find.byKey(
                        const ValueKey('hermes-composer-visible-surface'),
                      ),
                    )
                    .decoration!
                as BoxDecoration;
        expect(composer.color, chrome.opaque);
        final capsule =
            tester
                    .widget<Container>(
                      find.byKey(const ValueKey('status-pill-capsule')),
                    )
                    .decoration!
                as BoxDecoration;
        expect(capsule.color, chrome.opaque);
        // The gel never blurs.
        expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
      });
    });
  }

  group('segmented control', () {
    Widget control({required ValueNotifier<int> value}) =>
        ValueListenableBuilder(
          valueListenable: value,
          builder: (context, current, _) => HermesSegmentedControl<int>(
            value: current,
            onChanged: (v) => value.value = v,
            segments: const [
              HermesSegment(value: 0, label: 'Chats'),
              HermesSegment(value: 1, label: 'Automatización'),
              HermesSegment(value: 2, label: 'Todo'),
            ],
          ),
        );

    testWidgets('the selected segment is a full pill and it slides to the '
        'next one', (tester) async {
      final value = ValueNotifier(0);
      addTearDown(value.dispose);
      await tester.pumpWidget(_host(control(value: value)));
      final indicator = find.byKey(
        const ValueKey('hermes-segmented-indicator'),
      );
      final decoration =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: indicator,
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(999));
      expect((decoration.border! as Border).top.width, greaterThan(0));
      expect(
        tester.widget<Text>(find.text('Chats')).style!.fontWeight,
        FontWeight.w700,
      );
      final from = tester.getRect(indicator);
      await tester.tap(find.text('Todo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final middle = tester.getRect(indicator);
      await tester.pumpAndSettle();
      final to = tester.getRect(indicator);
      expect(to.left, greaterThan(from.left));
      expect(middle.left, greaterThan(from.left));
      expect(
        middle.left,
        lessThan(to.left),
        reason: 'it slides, it does not jump',
      );
      expect(
        tester.getRect(find.text('Todo')).center.dx,
        closeTo(to.center.dx, to.width / 2),
      );
      expect(value.value, 2);
    });

    testWidgets('reduced motion: the pill is at the new segment at once', (
      tester,
    ) async {
      final value = ValueNotifier(0);
      addTearDown(value.dispose);
      await tester.pumpWidget(_host(control(value: value), reduceMotion: true));
      final indicator = find.byKey(
        const ValueKey('hermes-segmented-indicator'),
      );
      final from = tester.getRect(indicator);
      await tester.tap(find.text('Automatización'));
      await tester.pump();
      final to = tester.getRect(indicator);
      expect(to.left, greaterThan(from.left));
      await tester.pump();
      expect(tester.getRect(indicator), to);
    });

    testWidgets('large text: the segments scroll and the selected one is '
        'still a pill', (tester) async {
      final value = ValueNotifier(1);
      addTearDown(value.dispose);
      await tester.pumpWidget(_host(control(value: value), textScale: 1.6));
      expect(
        find.byKey(const ValueKey('hermes-segmented-indicator')),
        findsNothing,
      );
      final selected =
          tester
                  .widget<AnimatedContainer>(
                    find
                        .ancestor(
                          of: find.text('Automatización'),
                          matching: find.byType(AnimatedContainer),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      expect(selected.borderRadius, BorderRadius.circular(999));
      expect(selected.border, isNotNull);
    });
  });
}
