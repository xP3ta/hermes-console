// the owner, style 1 of the action buttons («Detener», «Reintentar», «Abrir
// conversación»): glass pills as the turn's, 34 dp to look at and 48 to
// tap, no coloured fill; colour only on the icon and the words, and only
// for what destroys.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';

Widget _app(Widget child, {ThemeData? theme, double textScale = 1}) =>
    MaterialApp(
      theme: theme ?? AppTheme.hermesRedDark,
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: home!,
      ),
      home: Scaffold(body: Center(child: child)),
    );

const _key = ValueKey('test-action');

TextButton _button(WidgetTester tester) => tester.widget<TextButton>(
  find.descendant(of: find.byKey(_key), matching: find.byType(TextButton)),
);

/// The colour the words of [label] are drawn in.
Color? _ink(WidgetTester tester, String label) => tester
    .widget<RichText>(
      find.descendant(of: find.text(label), matching: find.byType(RichText)),
    )
    .text
    .style
    ?.color;

void main() {
  for (final (name, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$name: a raised glass pill with its hairline, no fill of '
        'colour; 34 dp to look at, 48 to tap', (tester) async {
      await tester.pumpWidget(
        _app(
          HermesGlassActionButton(
            key: _key,
            icon: Icons.refresh_rounded,
            label: 'Reintentar',
            onPressed: () {},
          ),
          theme: theme,
        ),
      );
      final colors = theme.hermes;
      final chrome = HermesChrome.of(colors);
      final button = _button(tester);
      final style = button.style!;
      expect(style.backgroundColor!.resolve(const {}), chrome.raised);
      final shape = style.shape!.resolve(const {})!;
      expect(shape, isA<StadiumBorder>());
      expect((shape as StadiumBorder).side.color, chrome.line);
      // «Reintentar» is not yellow: the ink of every other action.
      expect(style.foregroundColor!.resolve(const {}), chrome.ink);
      final target = tester.getSize(find.byKey(_key));
      expect(target.height, greaterThanOrEqualTo(48));
      final pill = tester.getSize(
        find.descendant(of: find.byKey(_key), matching: find.byType(Material)),
      );
      expect(pill.height, HermesGlassActionButton.height);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('what destroys: the error colour on its icon and words only', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        HermesGlassActionButton(
          key: _key,
          icon: Icons.crop_square_rounded,
          label: 'Detener',
          destructive: true,
          onPressed: () {},
        ),
      ),
    );
    final colors = AppTheme.hermesRedDark.hermes;
    final style = _button(tester).style!;
    // REVIEW-Q9-VENT P2-1: the error's red, readable (4.5:1) on the pill,
    // its hue kept (the raw token gave 2.45:1 in Console dark).
    final chrome = HermesChrome.of(colors);
    final red = style.foregroundColor!.resolve(const {})!;
    final hue = (HSLColor.fromColor(red).hue -
            HSLColor.fromColor(colors.error).hue)
        .abs();
    expect(hue > 180 ? 360 - hue : hue, lessThan(2));
    expect(
      ThemeContrast.ratio(red, chrome.raised),
      greaterThanOrEqualTo(4.5 - 0.01),
    );
    expect(
      style.backgroundColor!.resolve(const {}),
      HermesChrome.of(colors).raised,
      reason: 'no red fill',
    );
    expect(_ink(tester, 'Detener'), red);
  });

  testWidgets('disabled: the muted ink, no tap; TalkBack hears a button', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const HermesGlassActionButton(
          key: _key,
          label: 'Deteniendo…',
          onPressed: null,
        ),
      ),
    );
    final style = _button(tester).style!;
    expect(
      style.foregroundColor!.resolve(const {WidgetState.disabled}),
      HermesChrome.of(AppTheme.hermesRedDark.hermes).mutedInk,
    );
    expect(
      tester.getSemantics(find.byKey(_key)),
      isSemantics(
        label: 'Deteniendo…',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    semantics.dispose();
  });

  for (final scale in const [1.0, 1.3, 2.0]) {
    testWidgets('text ${scale}x at 320 dp: whole, nothing overflows', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var taps = 0;
      await tester.pumpWidget(
        _app(
          HermesGlassActionButton(
            key: _key,
            icon: Icons.forum_outlined,
            label: 'Abrir conversación',
            onPressed: () => taps++,
          ),
          textScale: scale,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(_key)).width, lessThanOrEqualTo(320));
      await tester.tap(find.byKey(_key));
      expect(taps, 1);
    });
  }
}
