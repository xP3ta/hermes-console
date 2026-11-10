// QA 9709, dock-final (the owner: «el dock se ve mate»): the dock is real glass
// by default and only icons; «Nuevo chat» is a round piece of the same
// material beside the pill. The costs of glass are rules: a moderate blur,
// one glass layer per zone, isolated in its own repaint boundary, and no
// blur at all with reduced motion, high contrast or a constrained device.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show BackdropFilterLayer, RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/ssh_profile_presence.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

GestureDockController get _c => GestureDockController.instance;

const _shot = ValueKey('q9-glass-shot');

Widget _app({
  required String theme,
  GestureDockTab? current = GestureDockTab.home,
  Color? behind,
  double textScale = 1,
  bool reduceMotion = false,
  bool highContrast = false,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId(theme),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: reduceMotion,
        highContrast: highContrast,
      ),
      child: Scaffold(
        body: RepaintBoundary(
          key: _shot,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // What passes behind the dock: one solid colour, so what
              // shows through the glass can be read from a pixel.
              if (behind != null) ColoredBox(color: behind),
              GestureDock(
                current: current,
                onTab: {
                  for (final tab in GestureDockTab.values)
                    if (tab != current) tab: () {},
                },
                shortcuts: {
                  GestureDockTab.create: [
                    DockShortcut(
                      label: 'Atajo de nuevo',
                      icon: Icons.add,
                      onTap: () {},
                    ),
                  ],
                },
                onEdit: () {},
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

void _size(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Finder _tab(GestureDockTab tab) =>
    find.byKey(ValueKey('gesture-dock-tab-${tab.name}'));

/// How much redder than grey a colour is.
double _redness(ui.Color c) => (c.r - (c.g + c.b) / 2) * 255;

Future<ui.Color> _pixel(WidgetTester tester, Offset at) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shot),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    image.dispose();
    final i = (at.dy.round() * width + at.dx.round()) * 4;
    return [data!.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)];
  });
  return ui.Color.fromARGB(255, bytes![0], bytes[1], bytes[2]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.resetForTesting(gestureDock: true);
    _c.resetForTesting(
      settings: const GestureDockSettings(tabs: GestureDockTab.defaultLayout),
    );
    DockGeometry.instance.resetForTesting();
    // An SSH profile: the bar has its five places.
    SshProfilePresence.instance.value = true;
  });
  tearDown(() {
    FrostedBackdropPolicy.reducedPerformance.value = false;
    SshProfilePresence.instance.value = false;
  });

  final selectedEvidence = <Map<String, Object?>>[];
  for (final preset in AppTheme.presets) {
    for (final background in [Colors.white, Colors.black]) {
      final backdropName = background == Colors.white ? 'white' : 'black';
      testWidgets('LIQ-DOCK-AA-1 ${preset.id} on $backdropName', (
        tester,
      ) async {
        _size(tester, const Size(360, 780));
        await DockPreferencesController.instance.updateGeneral(
          (profile) => profile.copyWith(style: const DockStyle()),
          persist: false,
        );
        await tester.pumpWidget(
          _app(
            theme: preset.id,
            current: GestureDockTab.home,
            behind: background,
          ),
        );
        await tester.pumpAndSettle();
        expect(_c.light.strength, 0, reason: 'measure the selection at rest');
        final selected = _tab(GestureDockTab.home);
        expect(tester.widget<Semantics>(selected).properties.selected, isTrue);
        final ink = tester
            .widget<Icon>(
              find.descendant(of: selected, matching: find.byType(Icon)),
            )
            .color!;
        Color fill(Finder finder) =>
            (tester.widget<DecoratedBox>(finder).decoration as BoxDecoration)
                .color!;
        final veil = fill(find.byKey(const ValueKey('gesture-dock-glass')));
        final glassContext = tester.element(
          find.byKey(const ValueKey('gesture-dock-glass')),
        );
        final tone = HermesGlassStrip.of(glassContext)?.tone;
        final colors = AppTheme.fromId(preset.id).hermes;
        final chrome = HermesChrome.of(colors);
        final active = find.byKey(const ValueKey('gesture-dock-active'));
        // The active item is a glow from the bottom edge, not a flat fill:
        // its ink is certified against the glow's strongest tint under the
        // icon, so the sample (outside the icon) can only read better.
        final glow =
            (tester.widget<DecoratedBox>(active).decoration as BoxDecoration)
                    .gradient!
                as RadialGradient;
        expect(glow.colors.first.a, closeTo(HermesGel.dockGlowAlpha, 1e-6));
        expect(glow.colors.last.a, 0);
        final selection = colors.accent.withValues(
          alpha: HermesGel.dockGlowCertified(chrome.dark),
        );
        final under = ThemeContrast.composite(
          selection,
          ThemeContrast.composite(veil, background),
        );
        final rect = tester.getRect(active);
        // Inside the selection capsule, outside the 28 dp icon and dock rim.
        final sample = Offset(rect.center.dx - 18, rect.center.dy);
        final pixel = await _pixel(tester, sample);
        final modelRatio = tone == null
            ? ThemeContrast.ratio(ink, under)
            : tone.worstRatio(ink, chrome, over: selection);
        final pixelRatio = ThemeContrast.ratio(ink, pixel);
        final style = DockPreferencesController.instance.value.general.style;
        selectedEvidence.add({
          'theme': preset.id,
          'background': backdropName,
          'selected': GestureDockTab.home.name,
          'ink': ink.toARGB32(),
          'veil': veil.toARGB32(),
          'selection': selection.toARGB32(),
          'material': tone == null ? 'legacy' : 'smoked',
          'composite': tone == null ? under.toARGB32() : null,
          'tonedRange': tone == null
              ? null
              : [
                  tone.underRange(chrome, over: selection).$1,
                  tone.underRange(chrome, over: selection).$2,
                ],
          'pixel': pixel.toARGB32(),
          'sample': [sample.dx, sample.dy],
          'modelRatio': modelRatio,
          'pixelRatio': pixelRatio,
          'transparency': style.transparency,
          'transparencyChosen': style.transparencyChosen,
        });
        final out = Platform.environment['LIQ_DOCK_AA_OUT'];
        if (out != null) {
          File(out).writeAsStringSync(jsonEncode(selectedEvidence));
        }
        expect(style.transparency, DockStyle.glassTransparency);
        expect(style.transparencyChosen, isFalse);
        final iconRect = tester.getRect(
          find.descendant(of: selected, matching: find.byType(Icon)),
        );
        expect(rect.contains(sample), isTrue);
        expect(
          sample.dx,
          lessThan(iconRect.left - 1),
          reason: 'sample selection background, outside the icon',
        );
        expect(
          modelRatio,
          greaterThanOrEqualTo(3),
          reason: '${preset.id} selected icon over $backdropName, actual fills',
        );
        expect(
          pixelRatio,
          greaterThanOrEqualTo(3),
          reason:
              '${preset.id} selected icon over $backdropName, actual pixels',
        );
        if (tone != null) {
          expect(modelRatio, greaterThanOrEqualTo(3.05));
          expect(pixelRatio, greaterThanOrEqualTo(3.05));
          expect(
            tone.veil,
            greaterThanOrEqualTo(resolveDockVisual(colors, style).background.a),
          );
          final originalHue = HSLColor.fromColor(colors.accentText).hue;
          final adjustedHue = HSLColor.fromColor(ink).hue;
          final delta = (originalHue - adjustedHue).abs();
          expect(delta > 180 ? 360 - delta : delta, lessThan(10));
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }
  }

  group('the dock style: glass unless the user chose otherwise', () {
    test('by default: glass, a moderate blur under a light veil', () {
      const style = DockStyle();
      expect(style.transparencyChosen, isFalse);
      expect(style.transparency, DockStyle.glassTransparency);
      expect(style.toJson().containsKey('transparency'), isFalse);
      for (final theme in ['classic-dark', 'console-light']) {
        final colors = AppTheme.fromId(theme).hermes;
        final visual = resolveDockVisual(colors, style);
        expect(visual.blurSigma, inInclusiveRange(16, 20), reason: theme);
        expect(visual.background.a, inExclusiveRange(.4, .8), reason: theme);
        expect(visual.shadows, isNotEmpty, reason: theme);
      }
      // The veil is lighter than the surface it comes from (dark theme).
      final dark = AppTheme.fromId('classic-dark').hermes;
      final veil = resolveDockVisual(dark, style).background;
      expect(
        veil.withValues(alpha: 1).computeLuminance(),
        greaterThan(dark.surface.computeLuminance()),
      );
    });

    test('a value the user chose is kept, opaque included', () {
      final chosen = DockStyle.fromJson(
        const DockStyle(transparency: 0).toJson(),
      );
      expect(chosen.transparencyChosen, isTrue);
      expect(chosen.transparency, 0);
      expect(
        resolveDockVisual(
          AppTheme.fromId('classic-dark').hermes,
          chosen,
        ).blurSigma,
        0,
      );
      final some = DockStyle.fromJson(
        const DockStyle(transparency: .3).toJson(),
      );
      expect(some.transparency, .3);
    });

    test('before v3, a stored 0.0 was the old default, not a choice', () {
      for (final version in [1, 2]) {
        final old = DockStyle.fromJson({
          'schema_version': version,
          'border_shape': 'rounded',
          'transparency': 0.0,
          'depth': 'elevated',
        });
        expect(old.transparencyChosen, isFalse, reason: 'v$version');
        expect(old.transparency, DockStyle.glassTransparency);
        final chosen = DockStyle.fromJson({
          'schema_version': version,
          'transparency': 0.4,
        });
        expect(chosen.transparencyChosen, isTrue, reason: 'v$version');
        expect(chosen.transparency, .4);
      }
    });
  });

  group('the layout: a pill of places and «+» apart', () {
    test('items of 64 dp, down to the 48 dp target; never past the edges', () {
      for (final width in [320.0, 360.0, 412.0, 773.0]) {
        final available = width - gestureDockSideMargin * 2;
        for (final tabs in [
          GestureDockTab.defaultLayout,
          GestureDockTab.legacyDefaultLayout,
          const [
            GestureDockTab.home,
            GestureDockTab.search,
            GestureDockTab.bots,
            GestureDockTab.agents,
            GestureDockTab.settings,
          ],
        ]) {
          final layout = GestureDockLayout.of(tabs, available);
          final why = '$width dp, $tabs';
          expect(layout.slot, inInclusiveRange(48, 64), reason: why);
          // Five places and «+» on a 320 dp window compact their spacing
          // (a narrower gap, inset and side margin) instead of dropping a
          // destination; wider windows keep the roomy one.
          final limit = layout.tight
              ? width - gestureDockSideMarginTight * 2
              : available;
          expect(layout.width, lessThanOrEqualTo(limit), reason: why);
          if (width >= 360) {
            expect(layout.tight, isFalse, reason: why);
          }
          expect(
            layout.create,
            tabs.contains(GestureDockTab.create),
            reason: why,
          );
          expect(layout.places, isNot(contains(GestureDockTab.create)));
          for (final tab in tabs) {
            for (final rtl in [false, true]) {
              final x = layout.centerOf(tab, rtl: rtl);
              expect(layout.tabAt(x, rtl: rtl), tab, reason: '$why $tab');
            }
          }
        }
      }
    });
  });

  test('five places and «+» keep all five at 320 dp, with a compact gap', () {
    final layout = GestureDockLayout.of(
      GestureDockTab.defaultLayout,
      320 - gestureDockSideMargin * 2,
    );
    expect(layout.places, hasLength(5));
    expect(layout.tight, isTrue);
    expect(layout.slot, gestureDockSlotMin);
    expect(layout.gap, gestureDockGapTight);
    // And the roomy bar of a normal phone is untouched.
    final roomy = GestureDockLayout.of(
      GestureDockTab.defaultLayout,
      360 - gestureDockSideMargin * 2,
    );
    expect(roomy.tight, isFalse);
    expect(roomy.gap, gestureDockGap);
    expect(roomy.slot, greaterThanOrEqualTo(gestureDockSlotMin));
  });

  for (final theme in ['classic-dark', 'console-light']) {
    group(theme, () {
      for (final size in const [
        Size(320, 700),
        Size(360, 780),
        Size(412, 915),
      ]) {
        for (final scale in [1.0, 1.3, 2.0]) {
          testWidgets('${size.width.toInt()} dp, text ${scale}x: icons only, '
              'the same height, 48 dp targets, every name for TalkBack', (
            tester,
          ) async {
            _size(tester, size);
            final semantics = tester.ensureSemantics();
            await tester.pumpWidget(_app(theme: theme, textScale: scale));
            await tester.pump();
            expect(tester.takeException(), isNull);
            final strings = Strings.of(
              tester.element(find.byType(GestureDock)),
            );
            final pill = tester.getRect(
              find.byKey(const ValueKey('gesture-dock-glass')),
            );
            final create = tester.getRect(
              find.byKey(const ValueKey('gesture-dock-create-glass')),
            );
            // The dock does not grow with the text: it has none.
            expect(pill.height, gestureDockHeight);
            expect(create.size, const Size.square(gestureDockHeight));
            expect(
              find.descendant(
                of: find.byKey(const ValueKey('gesture-dock')),
                matching: find.byType(Text),
              ),
              findsNothing,
            );
            // Both pieces on screen, apart, centred. Five places on a 320 dp
            // window compact the margin and the gap instead of leaving one out.
            final layout = GestureDockLayout.of(
              gestureDockShownTabs(_c.value.tabs),
              size.width - gestureDockSideMargin * 2,
            );
            final margin = layout.tight
                ? gestureDockSideMarginTight
                : gestureDockSideMargin;
            expect(pill.left, greaterThanOrEqualTo(margin));
            expect(create.right, lessThanOrEqualTo(size.width - margin));
            expect(create.left - pill.right, layout.gap);
            expect(
              (pill.left + create.right) / 2,
              moreOrLessEquals(size.width / 2),
            );
            for (final tab in _c.value.tabs) {
              final item = tester.getRect(_tab(tab));
              expect(item.width, greaterThanOrEqualTo(48), reason: tab.name);
              expect(item.height, greaterThanOrEqualTo(48), reason: tab.name);
              expect(
                find.bySemanticsLabel(gestureDockTabLabel(strings, tab)),
                findsWidgets,
                reason: tab.name,
              );
            }
            semantics.dispose();
          });
        }
      }

      testWidgets('the selected place sits on a faint accent pill; «+» has no '
          'accent', (tester) async {
        _size(tester, const Size(360, 780));
        await tester.pumpWidget(
          _app(theme: theme, current: GestureDockTab.search),
        );
        await tester.pump();
        final colors = AppTheme.fromId(theme).hermes;
        final active = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('gesture-dock-active')),
        );
        final decoration = active.decoration as BoxDecoration;
        expect(decoration.color, isNull, reason: 'no solid background');
        final glow = decoration.gradient! as RadialGradient;
        expect(glow.center, Alignment.bottomCenter);
        expect(glow.colors.first.a, closeTo(HermesGel.dockGlowAlpha, 1e-6));
        expect(
          find.descendant(
            of: _tab(GestureDockTab.search),
            matching: find.byKey(const ValueKey('gesture-dock-active')),
          ),
          findsOneWidget,
        );
        final plus = tester.widget<Icon>(
          find.descendant(
            of: _tab(GestureDockTab.create),
            matching: find.byType(Icon),
          ),
        );
        expect(plus.color, colors.textPrimary);
        expect(plus.color, isNot(colors.accentText));
      });

      testWidgets('a long press on «+» opens its menu over the round piece', (
        tester,
      ) async {
        _size(tester, const Size(360, 780));
        await tester.pumpWidget(_app(theme: theme));
        await tester.pump();
        final plus = tester.getCenter(_tab(GestureDockTab.create));
        final hold = await tester.startGesture(plus);
        await tester.pump(dockLongPress + const Duration(milliseconds: 40));
        await hold.up();
        await tester.pump();
        final popover = find.byKey(const ValueKey('gesture-dock-popover'));
        expect(popover, findsOneWidget);
        final menu = tester.getRect(
          find.descendant(of: popover, matching: find.byType(Material)).first,
        );
        expect(menu.left, lessThanOrEqualTo(plus.dx));
        expect(menu.right, greaterThanOrEqualTo(plus.dx - 10));
        expect(menu.bottom, lessThan(plus.dy));
      });

      testWidgets('what passes behind shows through the glass, and not '
          'through the opaque dock', (tester) async {
        _size(tester, const Size(360, 780));
        const red = Color(0xFFE53935);
        await tester.pumpWidget(_app(theme: theme, current: null, behind: red));
        await tester.pump();
        final pill = tester.getRect(
          find.byKey(const ValueKey('gesture-dock-glass')),
        );
        final context = tester.element(
          find.byKey(const ValueKey('gesture-dock-glass')),
        );
        final material = HermesGlassStrip.of(context)!;
        final colors = AppTheme.fromId(theme).hermes;
        final ink = colors.textPrimary;
        if (material.tone != null) {
          expect(
            material.tone!.worstRatio(ink, HermesChrome.of(colors)),
            greaterThanOrEqualTo(4.5),
            reason: 'the toned icon band keeps AA across its entire range',
          );
        } else {
          for (final behind in [Colors.black, Colors.white]) {
            expect(
              ThemeContrast.ratio(
                ink,
                ThemeContrast.composite(material.veil, behind),
              ),
              greaterThanOrEqualTo(4.5),
              reason: 'the actual icon band keeps AA on either extreme',
            );
          }
        }
        // Above the icons, inside the pill and its 1 dp line.
        final probe = Offset(pill.center.dx, pill.top + 5);
        final glass = await _pixel(tester, probe);
        await _c.setOpaque(true);
        await tester.pump();
        final solid = await _pixel(tester, probe);
        expect(
          _redness(glass),
          greaterThan(_redness(solid) + 30),
          reason: 'glass $glass, opaque $solid',
        );
      });

      for (final (name, reduced, contrast, lowEnd) in [
        ('reduced motion', true, false, false),
        ('high contrast', false, true, false),
        ('a constrained device', false, false, true),
      ]) {
        testWidgets('$name: no blur; the veil over the page, its line of '
            'light and its shadow', (tester) async {
          _size(tester, const Size(360, 780));
          FrostedBackdropPolicy.reducedPerformance.value = lowEnd;
          await tester.pumpWidget(
            _app(theme: theme, reduceMotion: reduced, highContrast: contrast),
          );
          await tester.pump();
          expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
          final colors = AppTheme.fromId(theme).hermes;
          final chrome = HermesChrome.of(colors);
          final visual = resolveDockVisual(colors, const DockStyle());
          final key = contrast ? 'gesture-dock-opaque' : 'gesture-dock-glass';
          final fill =
              (tester.widget<DecoratedBox>(find.byKey(ValueKey(key))).decoration
                      as BoxDecoration)
                  .color!;
          expect(fill.a, 1, reason: 'nothing sharp shows through');
          expect(
            fill,
            contrast
                ? chrome.opaque
                : Color.alphaBlend(visual.background, colors.background),
          );
        });
      }
    });
  }
}
