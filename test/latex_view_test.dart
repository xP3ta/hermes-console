import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/latex/latex_layout.dart';
import 'package:hermes_android/core/utils/latex/latex_parser.dart';
import 'package:hermes_android/core/utils/markdown_math.dart';
import 'package:hermes_android/core/widgets/latex/latex_view.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _red = Color(0xFFFF0000);

LatexBox _box(String source, {double size = 20, bool display = false}) =>
    layoutLatex(
      parseLatex(source),
      LatexLayoutStyle(fontSize: size, color: _red, display: display),
    );

Widget _app(Widget child, {double scale = 1, ThemeData? theme}) {
  return MaterialApp(
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    locale: const Locale('es'),
    theme: theme ?? AppTheme.hermesRedDark,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 360, child: child),
      ),
    ),
  );
}

void main() {
  group('layoutLatex metrics', () {
    testWidgets('every node kind gets a positive box', (tester) async {
      for (final source in const [
        'x',
        r'x^2 + y_i^2',
        r'\frac{a+b}{c}',
        r'\sqrt{x}',
        r'\sqrt[3]{x^2}',
        r'\sum_{i=1}^{n} i',
        r'\int_0^1 f(x)\,dx',
        r'\lim_{x\to 0} \frac{\sin x}{x}',
        r'\left( \frac{a}{b} \right)',
        r'\left\{ x \right.',
        r'\left\langle x \right\rangle',
        r'\left\lfloor x \right\rfloor',
        r'\left| x \right|',
        r'\left\| x \right\|',
        r'\binom{n}{k}',
        r'\begin{pmatrix} a & b \\ c & d \end{pmatrix}',
        r'\begin{cases} x & x>0 \\ 0 & \text{otherwise} \end{cases}',
        r'\begin{aligned} a &= b \\ c &= d \end{aligned}',
        r'\hat{x} + \bar{y} + \vec{v} + \tilde{w} + \dot{a} + \ddot{b}',
        r'\overline{AB} + \underline{CD}',
        r'\mathbb{R} \mathbf{v} \mathrm{d}x \mathcal{L}',
        r'\text{si } x > 0',
        r'\alpha + \beta \leq \Gamma',
        r'a \, b \quad c',
      ]) {
        final box = _box(source);
        expect(box.width, greaterThan(0), reason: source);
        expect(box.height, greaterThan(0), reason: source);
        final display = _box(source, display: true);
        expect(display.width, greaterThan(0), reason: source);
        final recorder = ui.PictureRecorder();
        box.paint(ui.Canvas(recorder), Offset(0, box.ascent));
        recorder.endRecording();
      }
    });

    testWidgets('a fraction is taller than a letter', (tester) async {
      final x = _box('x');
      final frac = _box(r'\frac{a}{b}');
      expect(frac.ascent, greaterThan(x.ascent));
      expect(frac.descent, greaterThan(x.descent));
    });

    testWidgets('scripts widen the base and move off the baseline', (
      tester,
    ) async {
      final x = _box('x');
      final sup = _box('x^2');
      final sub = _box('x_i');
      expect(sup.width, greaterThan(x.width));
      expect(sup.ascent, greaterThan(x.ascent));
      expect(sub.descent, greaterThan(x.descent));
    });

    testWidgets('a root is wider and taller than its body', (tester) async {
      final x = _box('x');
      final root = _box(r'\sqrt{x}');
      expect(root.width, greaterThan(x.width));
      expect(root.ascent, greaterThan(x.ascent));
    });

    testWidgets('delimiters grow with their content', (tester) async {
      final small = _box(r'\left( x \right)');
      final tall = _box(r'\left( \frac{a}{\frac{b}{c}} \right)');
      expect(tall.height, greaterThan(small.height));
    });

    testWidgets('display style stacks the limits of a sum', (tester) async {
      final inline = _box(r'\sum_{i=1}^{n} i');
      final display = _box(r'\sum_{i=1}^{n} i', display: true);
      expect(display.height, greaterThan(inline.height));
      expect(display.width, lessThan(inline.width));
    });

    testWidgets('a matrix is as tall as its rows', (tester) async {
      final one = _box(r'\begin{matrix} a \end{matrix}');
      final two = _box(r'\begin{matrix} a \\ b \end{matrix}');
      expect(two.height, greaterThan(one.height));
      final wide = _box(r'\begin{matrix} a & b \end{matrix}');
      expect(wide.width, greaterThan(one.width));
    });

    testWidgets('the box scales with the font size', (tester) async {
      final small = _box(r'\frac{a}{b}', size: 20);
      final big = _box(r'\frac{a}{b}', size: 40);
      expect(big.height / small.height, closeTo(2, 0.1));
      expect(big.width / small.width, closeTo(2, 0.1));
    });

    testWidgets('painting uses the style colour', (tester) async {
      final box = _box(r'\frac{a}{b} + \sqrt{x}');
      final width = box.width.ceil() + 4;
      final height = box.height.ceil() + 4;
      final recorder = ui.PictureRecorder();
      box.paint(ui.Canvas(recorder), Offset(2, box.ascent + 2));
      final picture = recorder.endRecording();
      final hasRed = await tester.runAsync(() async {
        final image = await picture.toImage(width, height);
        final data = (await image.toByteData())!;
        for (var i = 0; i < data.lengthInBytes; i += 4) {
          final r = data.getUint8(i);
          final g = data.getUint8(i + 1);
          final b = data.getUint8(i + 2);
          final a = data.getUint8(i + 3);
          if (a > 200 && r > 200 && g < 60 && b < 60) return true;
        }
        return false;
      });
      expect(hasRed, isTrue);
    });
  });

  group('LatexView', () {
    testWidgets('paints a valid formula natively', (tester) async {
      await tester.pumpWidget(_app(const LatexView(source: r'\frac{a}{b}')));
      expect(find.byType(LatexFormula), findsOneWidget);
      expect(tester.getSize(find.byType(LatexFormula)).height, greaterThan(20));
    });

    testWidgets('an invalid formula falls back to its source text', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const LatexView(source: r'\frac{a')));
      expect(find.byType(LatexFormula), findsNothing);
      expect(find.text(r'\frac{a'), findsOneWidget);
    });

    testWidgets('selection and copy carry the TeX source', (tester) async {
      await tester.pumpWidget(_app(const LatexView(source: r'x^2')));
      expect(find.text(r'$x^2$'), findsOneWidget);
      await tester.pumpWidget(
        _app(const LatexView(source: r'x^2', display: true)),
      );
      expect(find.text(r'$$x^2$$'), findsOneWidget);
    });

    testWidgets('exposes the formula to accessibility', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(const LatexView(source: r'x^2')));
      expect(find.bySemanticsLabel('Fórmula: x^2'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a rebuild does not lay the formula out again', (tester) async {
      Widget app() => _app(const LatexView(source: r'\frac{a}{b}'));
      await tester.pumpWidget(app());
      final first = tester
          .renderObject<RenderLatexFormula>(find.byType(LatexFormula))
          .box;
      await tester.pumpWidget(app());
      final second = tester
          .renderObject<RenderLatexFormula>(find.byType(LatexFormula))
          .box;
      expect(identical(first, second), isTrue);
    });

    testWidgets('a new key does not lay the same formula out again', (
      tester,
    ) async {
      Widget app(int key) =>
          _app(LatexView(key: ValueKey(key), source: r'\frac{a}{b} + x^2'));
      await tester.pumpWidget(app(1));
      final first = tester
          .renderObject<RenderLatexFormula>(find.byType(LatexFormula))
          .box;
      await tester.pumpWidget(app(2));
      final second = tester
          .renderObject<RenderLatexFormula>(find.byType(LatexFormula))
          .box;
      expect(identical(first, second), isTrue);
    });

    testWidgets('a formula wider than its slot shrinks to fit', (tester) async {
      final wide = List.filled(12, r'\alpha + \beta').join(' + ');
      await tester.pumpWidget(
        _app(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 120,
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Un valor '),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: LatexView(source: wide, scaleText: false),
                    ),
                  ],
                ),
              ),
            ),
          ),
          scale: 2,
        ),
      );
      final shownWidth =
          tester.getBottomRight(find.byType(LatexFormula)).dx -
          tester.getTopLeft(find.byType(LatexFormula)).dx;
      expect(shownWidth, lessThanOrEqualTo(120.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('follows the theme colour and the text scale', (tester) async {
      await tester.pumpWidget(_app(const LatexView(source: r'x^2')));
      final dark = tester
          .renderObject<RenderLatexFormula>(find.byType(LatexFormula))
          .box;
      final darkSize = tester.getSize(find.byType(LatexFormula));
      await tester.pumpWidget(
        _app(const LatexView(source: r'x^2'), theme: ThemeData.light()),
      );
      // The theme change is animated.
      await tester.pumpAndSettle();
      final light = tester
          .renderObject<RenderLatexFormula>(find.byType(LatexFormula))
          .box;
      expect(identical(dark, light), isFalse);
      await tester.pumpWidget(_app(const LatexView(source: r'x^2'), scale: 2));
      final scaled = tester.getSize(find.byType(LatexFormula));
      expect(scaled.height / darkSize.height, closeTo(2, 0.15));
    });

    testWidgets('a display formula scrolls sideways when it is too wide', (
      tester,
    ) async {
      final wide = List.filled(40, r'\alpha + \beta').join(' + ');
      await tester.pumpWidget(_app(LatexView(source: wide, display: true)));
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(tester.getSize(find.byType(LatexFormula)).width, greaterThan(360));
      expect(tester.takeException(), isNull);
    });
  });

  group('in the assistant markdown', () {
    Widget view(String data) =>
        _app(SingleChildScrollView(child: AssistantMarkdownView(data: data)));

    String visibleText(WidgetTester tester) => tester
        .widgetList<RichText>(find.byType(RichText))
        .map((w) => w.text.toPlainText())
        .join('\n');

    testWidgets('an inline formula flows inside the paragraph', (tester) async {
      await tester.pumpWidget(view(r'Sea $x^2 + 1$ el valor de la curva.'));
      expect(find.byType(LatexFormula), findsOneWidget);
      expect(visibleText(tester), contains('Sea'));
      expect(visibleText(tester), contains('el valor de la curva.'));
      expect(visibleText(tester), isNot(contains(kMathInlineMarker)));
    });

    testWidgets('a display formula is painted as a block', (tester) async {
      await tester.pumpWidget(view('Antes\n\n\$\$\\frac{a}{b}\$\$\n\nDespués'));
      expect(find.byType(LatexFormula), findsOneWidget);
      expect(find.text(r'$$\frac{a}{b}$$'), findsOneWidget);
      expect(find.byTooltip('Copiar código'), findsNothing);
    });

    testWidgets(r'\( \) and \[ \] delimiters are rendered too', (tester) async {
      await tester.pumpWidget(view('Vale \\(a_1\\) y\n\n\\[\\sqrt{x}\\]'));
      expect(find.byType(LatexFormula), findsNWidgets(2));
    });

    testWidgets('a formula alone on its line is still painted', (tester) async {
      await tester.pumpWidget(view('Resultado:\n\n\$E = mc^2\$\n\nfin'));
      expect(find.byType(LatexFormula), findsOneWidget);
      expect(visibleText(tester), isNot(contains(kMathInlineMarker)));
      expect(find.byTooltip('Copiar código'), findsNothing);
    });

    testWidgets('an invalid inline formula keeps its source as code', (
      tester,
    ) async {
      await tester.pumpWidget(view(r'Esto $\foo{$ no rompe el mensaje.'));
      expect(find.byType(LatexFormula), findsNothing);
      final text = visibleText(tester);
      expect(text, contains(r'\foo{'));
      expect(text, contains('no rompe el mensaje.'));
      expect(text, isNot(contains(kMathInlineMarker)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an invalid display formula stays a code block', (
      tester,
    ) async {
      await tester.pumpWidget(view('Antes\n\n\$\$\\frac{a\$\$\n\nDespués'));
      expect(find.byType(LatexFormula), findsNothing);
      expect(visibleText(tester), contains(r'\frac{a'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('money and ordinary code are not formulas', (tester) async {
      await tester.pumpWidget(
        view('Cuesta \$5 and \$10 y usa `x^2` en código.'),
      );
      expect(find.byType(LatexFormula), findsNothing);
      expect(visibleText(tester), contains('x^2'));
    });

    testWidgets('a math fence is drawn as a formula', (tester) async {
      await tester.pumpWidget(view('```math\n\\frac{1}{2}\n```'));
      expect(find.byType(LatexFormula), findsOneWidget);
    });

    testWidgets('a latex fence stays source code', (tester) async {
      await tester.pumpWidget(view('```latex\n\\frac{1}{2}\n```'));
      expect(find.byType(LatexFormula), findsNothing);
    });

    testWidgets('the formula respects the large text scale', (tester) async {
      Widget app(double scale) => _app(
        SingleChildScrollView(
          child: AssistantMarkdownView(data: r'Un valor $x^2$ aquí.'),
        ),
        scale: scale,
      );
      double shownHeight() =>
          tester.getBottomRight(find.byType(LatexFormula)).dy -
          tester.getTopLeft(find.byType(LatexFormula)).dy;
      await tester.pumpWidget(app(1));
      final normal = shownHeight();
      final normalLayout = tester.getSize(find.byType(LatexFormula)).height;
      await tester.pumpWidget(app(2));
      // The paragraph scales the inline widget: twice as tall on screen...
      expect(shownHeight() / normal, closeTo(2, 0.2));
      // ...from the same layout: the formula did not scale itself as well.
      expect(
        tester.getSize(find.byType(LatexFormula)).height / normalLayout,
        closeTo(1, 0.05),
      );
    });
  });
}
