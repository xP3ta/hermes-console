import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/latex/latex_ast.dart';
import 'package:hermes_android/core/utils/latex/latex_parser.dart';

String _dbg(String source) => parseLatex(source).debug;

void main() {
  group('parseLatex valid', () {
    const cases = <String, String>{
      'x': '{x}',
      'x^2': '{x^{2}}',
      'x_i': '{x_{i}}',
      'x_i^2': '{x_{i}^{2}}',
      'x^{n+1}': '{x^{{n + 1}}}',
      'x^23': '{x^{2} 3}',
      'a+b': '{a + b}',
      'a-b': '{a − b}',
      'a=b': '{a = b}',
      '12.5x': '{12.5 x}',
      r'\frac{a}{b}': '{frac(a,b)}',
      r'\frac12': '{frac(1,2)}',
      r'\dfrac{x+1}{2}': '{frac({x + 1},2)}',
      r'\frac{1}{\frac{2}{3}}': '{frac(1,frac(2,3))}',
      r'\sqrt{x}': '{sqrt(x)}',
      r'\sqrt x': '{sqrt(x)}',
      r'\sqrt[3]{x}': '{sqrt[3](x)}',
      r'\sqrt{a^2+b^2}': '{sqrt({a^{2} + b^{2}})}',
      r'\alpha+\beta': '{α + β}',
      r'\Omega': '{Ω}',
      r'\sum_{i=1}^{n} i': '{op(∑)_{{i = 1}}^{n} i}',
      r'\sum\limits_{i}^{n}': '{op(∑)_{i}^{n}}',
      r'\prod_{k}': '{op(∏)_{k}}',
      r'\int_0^1 f(x)\,dx': '{op(∫)_{0}^{1} f ( x ) space(0.1667) d x}',
      r'\lim_{x\to 0} f': '{op(lim)_{{x → 0}} f}',
      r'\sin x': '{op(sin) x}',
      r'\operatorname{rank} A': '{op(rank) A}',
      r'\left( x \right)': '{delim((,{x},))}',
      r'\left[\frac{a}{b}\right]': '{delim([,{frac(a,b)},])}',
      r'\left\{ x \right.': '{delim({,{x},.)}',
      r'\left| x \right|': '{delim(|,{x},|)}',
      r'\left\langle x \right\rangle': '{delim(⟨,{x},⟩)}',
      r'\binom{n}{k}': '{delim((,stack(n,k),))}',
      r'\text{hello world}': '{text(hello world)}',
      r'x \text{ si } y': '{x text( si ) y}',
      r'\text{50\% de }x': '{text(50% de ) x}',
      r'\mathbb{R}': '{blackboard(R)}',
      r'\mathbf{v}': '{bold(v)}',
      r'\mathrm{d}x': '{roman(d) x}',
      r"f'(x)": '{f^{′} ( x )}',
      r"f''": '{f^{{′ ′}}}',
      r"x'^2": '{x^{{′ 2}}}',
      r'\hat{x}': '{hat(x)}',
      r'\vec v': '{vec(v)}',
      r'\overline{AB}': '{overline({A B})}',
      r'a \leq b': '{a ≤ b}',
      r'a \neq b \approx c': '{a ≠ b ≈ c}',
      r'x \in \mathbb{N}': '{x ∈ blackboard(N)}',
      r'\infty': '{∞}',
      r'a \times b \cdot c': '{a × b ⋅ c}',
      r'\forall x \exists y': '{∀ x ∃ y}',
      r'A \Rightarrow B': '{A ⇒ B}',
      r'1\ 2': '{1 space(0.3333) 2}',
      r'a\quad b': '{a space(1.0) b}',
      r'\$5 \& \% \_': r'{$ 5 & % _}',
      r'^2': '{{}^{2}}',
      r'{}^{14}C': '{{}^{14} C}',
      r'\displaystyle x': '{{} x}',
      r'\big( x \big)': '{( x )}',
      r'\begin{matrix}a&b\\c&d\end{matrix}': '{grid:matrix[{a},{b};{c},{d}]}',
      r'\begin{pmatrix} 1 & 0 \\ 0 & 1 \end{pmatrix}':
          '{grid:matrix[{1},{0};{0},{1}]}',
      r'\begin{bmatrix}a\\b\end{bmatrix}': '{grid:matrix[{a};{b}]}',
      r'\begin{cases} x & x>0 \\ 0 & \text{otherwise} \end{cases}':
          '{grid:cases[{x},{x > 0};{0},{text(otherwise)}]}',
      r'\begin{aligned} a &= b \\ c &= d \end{aligned}':
          '{grid:aligned[{a},{= b};{c},{= d}]}',
      r'\begin{array}{lcr} a & b & c \end{array}': '{grid:matrix[{a},{b},{c}]}',
      r'\begin{matrix}a&b\\\end{matrix}': '{grid:matrix[{a},{b}]}',
      'x\n+\ny': '{x + y}',
      '  x  ': '{x}',
      'α + β ≤ γ': '{α + β ≤ γ}',
      r'e^{i\pi}+1=0': '{e^{{i π}} + 1 = 0}',
      r'\frac{-b\pm\sqrt{b^2-4ac}}{2a}':
          '{frac({− b ± sqrt({b^{2} − 4 a c})},{2 a})}',
    };
    cases.forEach((source, expected) {
      test(source.replaceAll('\n', r'\n'), () {
        expect(_dbg(source), expected);
      });
    });

    test('limits and nolimits are kept on the node', () {
      final a = parseLatex(r'\sum\limits_i') as LatexRow;
      expect((a.children.single as LatexScripts).limits, LatexLimits.limits);
      final b = parseLatex(r'\int\nolimits_0') as LatexRow;
      expect((b.children.single as LatexScripts).limits, LatexLimits.noLimits);
    });

    test('matrix environment carries its delimiters', () {
      final root = parseLatex(r'\begin{vmatrix}a\end{vmatrix}') as LatexRow;
      final grid = root.children.single as LatexGrid;
      expect(grid.left, '|');
      expect(grid.right, '|');
    });

    test('array keeps the column alignment', () {
      final root = parseLatex(r'\begin{array}{l|r}a&b\end{array}') as LatexRow;
      expect((root.children.single as LatexGrid).aligns, ['l', 'r']);
    });
  });

  group('parseLatex invalid', () {
    const invalid = <String>[
      '',
      '   ',
      '{',
      '}',
      'a}',
      '{a',
      '{{a}',
      r'\frac{a}',
      r'\frac',
      r'\frac{a}{',
      r'\sqrt',
      r'\sqrt[3',
      'x^',
      'x_',
      'x^{',
      'x^a^b',
      'x_a_b',
      r'x^\',
      r'\left( x',
      r'x \right)',
      r'\left',
      r'\left\foo x \right)',
      r'\left( x \right',
      r'\foo',
      r'\unknowncommand{x}',
      r'\begin{matrix} a',
      r'\begin{matrix}a\end{pmatrix}',
      r'\begin{foo}a\end{foo}',
      r'\begin{array}{z}a\end{array}',
      r'\begin{array}a\end{array}',
      'a & b',
      r'a \\ b',
      r'\\',
      r'\end{matrix}',
      r'\text{a',
      r'\text',
      r'\text{a \foo b}',
      r'\text{$x$}',
      r'\mathbb',
      r'\hat',
      r'\operatorname{}',
      r'x\limits',
      r'\sum\nolimits\limits',
      r'$x$',
      r'50% off',
      r'a # b',
      r'a ^',
      'a\x01b',
      r'x\',
    ];
    for (final source in invalid) {
      test('rejects "${source.replaceAll('\x01', r'\x01')}"', () {
        expect(() => parseLatex(source), throwsA(isA<LatexParseException>()));
        expect(tryParseLatex(source), isNull);
      });
    }

    test('rejects a source over the length cap', () {
      expect(tryParseLatex('${' ' * kLatexMaxLength}x'), isNull);
      expect(tryParseLatex('${' ' * (kLatexMaxLength - 1)}x'), isNotNull);
    });

    test('rejects nesting over the depth cap without overflowing', () {
      final deep = '${'{' * 500}x${'}' * 500}';
      expect(tryParseLatex(deep), isNull);
      final fine = '${'{' * 10}x${'}' * 10}';
      expect(tryParseLatex(fine), isNotNull);
      final frac = '${r'\frac{' * 200}x';
      expect(tryParseLatex(frac), isNull);
    });

    test('rejects a formula with too many nodes', () {
      expect(tryParseLatex('x' * (kLatexMaxNodes + 100)), isNull);
      expect(tryParseLatex('x' * (kLatexMaxNodes - 100)), isNotNull);
    });

    test('rejects a grid with too many cells', () {
      final cells = List.filled(kLatexMaxCells + 1, 'a').join('&');
      expect(tryParseLatex('\\begin{matrix}$cells\\end{matrix}'), isNull);
    });
  });

  group('tryParseLatex cache', () {
    test('returns the same tree for the same source', () {
      final a = tryParseLatex(r'\frac{1}{2}');
      final b = tryParseLatex(r'\frac{1}{2}');
      expect(identical(a, b), isTrue);
    });

    test('remembers a failure', () {
      expect(tryParseLatex(r'\nope'), isNull);
      expect(tryParseLatex(r'\nope'), isNull);
    });

    test('survives more sources than the cache holds', () {
      for (var i = 0; i < 400; i++) {
        expect(tryParseLatex('x_$i'), isNotNull);
      }
      expect(tryParseLatex('x_3')?.debug, '{x_{3}}');
    });
  });
}
