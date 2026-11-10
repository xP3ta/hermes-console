// OPUS-CRISTAL: the chat foot's strip contract, outside ChatScreen. One
// toned strip in FrostedZone.bottom holds the composer and the context pill
// as its two pieces: one backdrop layer, the smoked glass's veil where every
// ink reads, the opaque chrome of before everywhere else. Never the shader.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show BackdropFilterLayer, RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/design/smoked_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _composer = ValueKey('hermes-composer-visible-surface');
const _capsule = ValueKey('status-pill-capsule');
const _shotKey = ValueKey('chat-foot-glass-root');

class _Fixture {
  final text = TextEditingController(text: 'Borrador conservado');
  final focus = FocusNode();
  final metrics = ValueNotifier(const SessionContextMetrics(percent: 23));

  Widget app({
    required String themeId,
    bool strip = true,
    bool reducedMotion = false,
    bool highContrast = false,
    List<Color> extraInks = const [],
    bool rivalStrip = false,
    bool plainStrip = false,
    ValueListenable<bool>? rival,
  }) {
    final theme = AppTheme.fromId(themeId);
    final colors = theme.hermes;
    final chrome = HermesChrome.of(colors);
    Widget foot = ConsoleComposer(
      controller: text,
      focusNode: focus,
      onSend: (_, _) {},
      footer: ChatStatusPill(
        metrics: metrics,
        onOpenContext: () {},
        modelLabel: 'Modelo',
        onOpenModel: () {},
      ),
    );
    if (plainStrip) {
      // A header's or an overlay's strip: untoned.
      foot = HermesGlassStrip(zone: FrostedZone.bottom, child: foot);
    } else if (strip) {
      foot = HermesGlassStrip(
        zone: FrostedZone.bottom,
        priority: 1,
        tone: HermesSmokedGlass.of(chrome),
        toneInks: [...HermesSmokedGlass.footInks(colors), ...extraInks],
        child: foot,
      );
    }
    final app = MaterialApp(
      theme: theme,
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reducedMotion,
          highContrast: highContrast,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Stack(
          children: [
            // Something real behind the foot for the one blur to sample.
            Positioned.fill(
              child: ListView(
                children: [
                  for (var i = 0; i < 40; i++)
                    Container(
                      height: 36,
                      color: i.isEven ? Colors.white : colors.accent,
                    ),
                ],
              ),
            ),
            if (rivalStrip)
              Align(
                alignment: Alignment.topCenter,
                child: HermesGlassStrip(
                  zone: FrostedZone.bottom,
                  tone: HermesSmokedGlass.of(chrome),
                  toneInks: HermesSmokedGlass.footInks(colors),
                  child: const HermesComposerSurface(
                    key: ValueKey('rival'),
                    child: SizedBox(height: 48, width: 200),
                  ),
                ),
              ),
            // A strip of higher priority that comes and goes on its own:
            // the foot is not rebuilt when it does.
            if (rival != null)
              ValueListenableBuilder<bool>(
                valueListenable: rival,
                builder: (context, on, _) => on
                    ? Align(
                        alignment: Alignment.topCenter,
                        child: HermesGlassStrip(
                          zone: FrostedZone.bottom,
                          priority: 2,
                          tone: HermesSmokedGlass.of(chrome),
                          toneInks: HermesSmokedGlass.footInks(colors),
                          child: const HermesComposerSurface(
                            key: ValueKey('higher'),
                            child: SizedBox(height: 48, width: 200),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            Align(alignment: Alignment.bottomCenter, child: foot),
          ],
        ),
      ),
    );
    return RepaintBoundary(key: _shotKey, child: app);
  }

  void dispose() {
    text.dispose();
    focus.dispose();
    metrics.dispose();
  }
}

/// The visible surface of the composer inside [scope]: the foot's own
/// (ConsoleComposer) unless another one is named. A rival strip's
/// HermesComposerSurface carries the same key, so never look it up bare.
Finder _surface([Finder? scope]) => find.descendant(
  of: scope ?? find.byType(ConsoleComposer),
  matching: find.byKey(_composer),
);

BoxDecoration _composerBox(WidgetTester tester, [Finder? scope]) =>
    tester.widget<AnimatedContainer>(_surface(scope)).decoration!
        as BoxDecoration;

BoxDecoration _capsuleBox(WidgetTester tester) =>
    tester.widget<Container>(find.byKey(_capsule)).decoration! as BoxDecoration;

/// The pixels of [rect] (logical, the test view's 1:1 ratio) as painted.
Future<List<Color>> _pixels(WidgetTester tester, Rect rect) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shotKey),
  );
  final ratio = tester.view.devicePixelRatio;
  late ui.Image image;
  late ByteData data;
  await tester.runAsync(() async {
    image = await boundary.toImage(pixelRatio: ratio);
    data = (await image.toByteData())!;
  });
  final width = image.width;
  final pixels = <Color>[];
  final top = (rect.top * ratio).ceil();
  final bottom = (rect.bottom * ratio).floor();
  final left = (rect.left * ratio).ceil();
  final right = (rect.right * ratio).floor();
  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      final i = (y * width + x) * 4;
      pixels.add(
        Color.fromARGB(
          255,
          data.getUint8(i),
          data.getUint8(i + 1),
          data.getUint8(i + 2),
        ),
      );
    }
  }
  image.dispose();
  return pixels;
}

/// The band of a composer's body above its text line, between its
/// controls: within [field] (the text field, between «+» and the primary
/// action), never across a button. A ROI that crossed the round send button
/// read its accent as "content" (measured: 179/215, and the rival's
/// 69,67,75 is 5 % of that accent at its anti-aliased edge).
Rect _band(Rect composer, Rect field) {
  final left = composer.left + composer.height / 2;
  final right = composer.right - composer.height / 2;
  return Rect.fromLTRB(
    left > field.left ? left : field.left,
    composer.top + 3,
    right < field.right ? right : field.right,
    composer.top + 9,
  );
}

int _filters(WidgetTester tester) =>
    tester.layers.whereType<BackdropFilterLayer>().length;

void main() {
  void resetPolicy() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = false;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
  }

  setUp(() {
    resetPolicy();
    FrostedBackdropPolicy.knownHighEnd.value = true;
  });
  tearDown(resetPolicy);

  for (final themeId in const ['classic-dark', 'classic']) {
    testWidgets('$themeId: one toned blur, both pieces wear its veil', (
      tester,
    ) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.app(themeId: themeId, strip: false));
      await tester.pumpAndSettle();
      final composerRect = tester.getRect(_surface());
      final capsuleRect = tester.getRect(find.byKey(_capsule));
      expect(_composerBox(tester).color!.a, 1);
      expect(_filters(tester), 0);

      await tester.pumpWidget(fixture.app(themeId: themeId));
      await tester.pumpAndSettle();
      final colors = AppTheme.fromId(themeId).hermes;
      final chrome = HermesChrome.of(colors);
      final veil = HermesSmokedGlass.of(chrome).veilOf(chrome);
      expect(_composerBox(tester).color, veil);
      expect(_capsuleBox(tester).color, veil);
      expect(veil.a, lessThan(1));
      expect(_composerBox(tester).boxShadow, isNull);
      expect(_capsuleBox(tester).boxShadow, isNull);
      expect(_filters(tester), 1);
      // The glass changes the material, never the geometry.
      expect(tester.getRect(_surface()), composerRect);
      expect(tester.getRect(find.byKey(_capsule)), capsuleRect);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final (name, reduced, contrast) in const [
    ('reduced motion', true, false),
    ('high contrast', false, true),
  ]) {
    testWidgets('$name keeps the opaque chrome and no filter', (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.app(
          themeId: 'classic-dark',
          reducedMotion: reduced,
          highContrast: contrast,
        ),
      );
      await tester.pumpAndSettle();
      expect(_composerBox(tester).color!.a, 1);
      expect(_capsuleBox(tester).color!.a, 1);
      expect(_composerBox(tester).boxShadow, isNotNull);
      expect(_filters(tester), 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('policy fallback is opaque and keeps the draft and focus', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(themeId: 'classic-dark'));
    fixture.focus.requestFocus();
    await tester.pumpAndSettle();
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    final value = fixture.text.value;
    expect(_filters(tester), 1);
    FrostedBackdropPolicy.reducedPerformance.value = true;
    await tester.pumpAndSettle();
    expect(_composerBox(tester).color!.a, 1);
    expect(_capsuleBox(tester).color!.a, 1);
    expect(_filters(tester), 0);
    expect(
      tester.state<EditableTextState>(find.byType(EditableText)),
      editable,
    );
    expect(fixture.focus.hasFocus, isTrue);
    expect(fixture.text.value, value);
    FrostedBackdropPolicy.reducedPerformance.value = false;
    await tester.pumpAndSettle();
    expect(_composerBox(tester).color!.a, lessThan(1));
    expect(_filters(tester), 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a veto is opaque from its first frame, not an easing veil', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(themeId: 'classic-dark'));
    fixture.focus.requestFocus();
    await tester.pumpAndSettle();
    final base = find.byKey(const ValueKey('hermes-composer-glass-base'));
    expect(tester.widget<CustomPaint>(base).painter, isNull);
    expect(_filters(tester), 1);
    FrostedBackdropPolicy.reducedPerformance.value = true;
    // One frame: the blur is gone and the opaque base is already under the
    // fill that is still easing from the veil.
    await tester.pump();
    expect(_filters(tester), 0);
    expect(tester.widget<CustomPaint>(base).painter, isNotNull);
    expect(fixture.focus.hasFocus, isTrue);
    await tester.pumpAndSettle();
    expect(_composerBox(tester).color!.a, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // Git R1, OPUS-WIRING-ZONE-FIRST-PAINT-1: a higher strip takes the zone
  // while the foot is retained. The foot loses its blur at once but its
  // scope only rebuilds after the frame: that very paint must not show a
  // bare veil over the content behind.
  testWidgets('a rival takes the zone: the foot is opaque in that paint', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final rival = ValueNotifier(false);
    addTearDown(rival.dispose);
    await tester.pumpWidget(fixture.app(themeId: 'classic-dark', rival: rival));
    await tester.pumpAndSettle();
    expect(_filters(tester), 1);
    final composer = tester.getRect(_surface());
    final field = tester.getRect(
      find.descendant(of: _surface(), matching: find.byType(TextField)),
    );
    final veiled = _composerBox(tester).color!;
    expect(veiled.a, lessThan(1));
    rival.value = true;
    await tester.pump();
    // The traced case: the foot was not rebuilt and still wears its veil.
    expect(_composerBox(tester).color, veiled);
    // One filter, the rival's; the foot shows no content behind it.
    expect(_filters(tester), 1);
    final colors = AppTheme.fromId('classic-dark').hermes;
    final opaque = HermesChrome.of(colors).opaque;
    // The gel's sheen lights the top-left of the foot: the band is read only
    // where the sheen is gone (160 degrees: it grows with x and with y), so
    // nothing of the content behind may show there, as before.
    final (from, to) = HermesGel.line(composer.size, HermesGel.sheenAngle);
    final axis = to - from;
    final whole = _band(composer, field);
    final clearX =
        (HermesGel.sheenStop * (axis.dx * axis.dx + axis.dy * axis.dy) +
                from.dx * axis.dx +
                from.dy * axis.dy -
                (whole.top - composer.top) * axis.dy) /
            axis.dx +
        composer.left +
        2;
    final band = await _pixels(
      tester,
      Rect.fromLTRB(
        clearX > whole.left ? clearX : whole.left,
        whole.top,
        whole.right,
        whole.bottom,
      ),
    );
    expect(band, isNotEmpty);
    for (final c in band) {
      expect(ThemeContrast.ratio(c, opaque), lessThan(1.02), reason: '$c');
    }
    // After the frame: the opaque chrome of before, still one filter.
    await tester.pumpAndSettle();
    expect(_composerBox(tester).color!.a, 1);
    expect(_filters(tester), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an untoned strip losing its zone keeps its veil (legacy C2)', (
    tester,
  ) async {
    final rival = ValueNotifier(false);
    addTearDown(rival.dispose);
    final colors = AppTheme.fromId('classic-dark').hermes;
    final chrome = HermesChrome.of(colors);
    const legacy = ValueKey('legacy-piece');
    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: AppTheme.fromId('classic-dark'),
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: ListView(
                    children: [
                      for (var i = 0; i < 40; i++)
                        Container(
                          height: 36,
                          color: i.isEven ? Colors.white : colors.accent,
                        ),
                    ],
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: rival,
                  builder: (context, on, _) => on
                      ? Align(
                          alignment: Alignment.topCenter,
                          child: HermesGlassStrip(
                            zone: FrostedZone.bottom,
                            priority: 2,
                            child: Builder(
                              builder: (context) => HermesGlassPiece(
                                shape: const RoundedRectangleBorder(),
                                child: ColoredBox(
                                  color:
                                      HermesGlassStrip.of(context)?.veil ??
                                      chrome.opaque,
                                  child: const SizedBox(height: 48, width: 200),
                                ),
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: HermesGlassStrip(
                    zone: FrostedZone.bottom,
                    priority: 1,
                    child: Builder(
                      builder: (context) => HermesGlassPiece(
                        shape: const RoundedRectangleBorder(),
                        child: ColoredBox(
                          key: legacy,
                          color:
                              HermesGlassStrip.of(context)?.veil ??
                              chrome.opaque,
                          child: const SizedBox(height: 48, width: 300),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_filters(tester), 1);
    final rect = tester.getRect(find.byKey(legacy)).deflate(4);
    rival.value = true;
    await tester.pump();
    expect(_filters(tester), 1);
    // No opaque backing for an untoned strip: what is behind still tints
    // its veil, as before this change.
    final pixels = await _pixels(tester, rect);
    expect(
      pixels.any((c) => ThemeContrast.ratio(c, chrome.opaque) > 1.2),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an ink the glass cannot hold keeps the opaque chrome', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    // Black on the dark chrome: 1.9:1 today, lower on the darker glass.
    await tester.pumpWidget(
      fixture.app(
        themeId: 'classic-dark',
        extraInks: const [Color(0xFF000000)],
      ),
    );
    await tester.pumpAndSettle();
    expect(_composerBox(tester).color!.a, 1);
    expect(_capsuleBox(tester).color!.a, 1);
    expect(_filters(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('one filter in the zone: the lower strip keeps opaque chrome', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      fixture.app(themeId: 'classic-dark', rivalStrip: true),
    );
    await tester.pumpAndSettle();
    expect(_filters(tester), 1);
    expect(_composerBox(tester).color!.a, lessThan(1));
    // A toned strip that does not own the blur never shows a bare veil.
    expect(
      _composerBox(tester, find.byKey(const ValueKey('rival'))).color!.a,
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an untoned strip never dresses the foot pieces', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      fixture.app(themeId: 'classic-dark', plainStrip: true),
    );
    await tester.pumpAndSettle();
    expect(_composerBox(tester).color!.a, 1);
    expect(_capsuleBox(tester).color!.a, 1);
    expect(_composerBox(tester).boxShadow, isNotNull);
    // Not pieces of it: the untoned strip has nothing to frost.
    expect(_filters(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a validated GPU still never loads the shader for the foot', (
    tester,
  ) async {
    FrostedBackdropPolicy.liquidGpuValidated.value = true;
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final attempts = HermesLiquidShader.loadAttempts;
    await tester.pumpWidget(fixture.app(themeId: 'classic-dark'));
    await tester.pumpAndSettle();
    expect(HermesLiquidShader.loadAttempts, attempts);
    expect(
      HermesGlassStrip.debugShaderActive(tester.element(_surface())),
      isFalse,
    );
    expect(_filters(tester), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // f241a8c7: on the light glass the pill's status inks are adjusted, just
  // enough, instead of lowering AA; off the glass they are the ones of before.
  testWidgets('classic: the pill paints its adapted status inks on the glass', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final colors = AppTheme.fromId('classic').hermes;
    final adapted = HermesSmokedGlass.of(
      HermesChrome.of(colors),
    ).adaptedInks(colors);
    expect(adapted.warning, isNot(colors.warning));
    await tester.pumpWidget(fixture.app(themeId: 'classic'));
    await tester.pumpAndSettle();
    HermesThemeColors inPill() =>
        Theme.of(tester.element(find.byKey(_capsule))).hermes;
    expect(inPill().warning, adapted.warning);
    expect(inPill().error, adapted.error);
    expect(inPill().accentText, adapted.accentText);
    expect(inPill().textSecondary, colors.textSecondary);
    FrostedBackdropPolicy.reducedPerformance.value = true;
    await tester.pumpAndSettle();
    expect(inPill().warning, colors.warning);
    expect(inPill().error, colors.error);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // Review: the warning and error states, not only the normal one; and the
  // first paint of a lost zone (the foot not rebuilt) keeps an adapted ink
  // for a frame over the opaque backing: it must still read there.
  testWidgets('classic: warning and error states, lost zone first paint', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final rival = ValueNotifier(false);
    addTearDown(rival.dispose);
    final colors = AppTheme.fromId('classic').hermes;
    final chrome = HermesChrome.of(colors);
    final adapted = HermesSmokedGlass.of(chrome).adaptedInks(colors);
    Color usage() => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('context-pill-usage')),
            matching: find.byType(Text),
          ),
        )
        .style!
        .color!;
    await tester.pumpWidget(fixture.app(themeId: 'classic', rival: rival));
    await tester.pumpAndSettle();
    fixture.metrics.value = const SessionContextMetrics(percent: 80);
    await tester.pump();
    expect(usage(), adapted.warning);
    fixture.metrics.value = const SessionContextMetrics(percent: 95);
    await tester.pump();
    expect(usage(), adapted.error);
    // A higher strip takes the zone; the foot keeps its scope this frame.
    rival.value = true;
    await tester.pump();
    expect(usage(), adapted.error);
    for (final (before, after) in [
      (colors.warning, adapted.warning),
      (colors.error, adapted.error),
    ]) {
      final floor = [
        ThemeContrast.ratio(before, chrome.opaque),
        4.5,
      ].reduce((a, b) => a < b ? a : b);
      expect(
        ThemeContrast.ratio(after, chrome.opaque),
        greaterThanOrEqualTo(floor),
        reason: 'an adapted ink still reads on the opaque backing',
      );
    }
    await tester.pumpAndSettle();
    expect(usage(), colors.error, reason: 'off the glass, the ink of before');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
