import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/markdown_math.dart';

void main() {
  group('protectMarkdownMath', () {
    test('text without math delimiters is returned untouched', () {
      const text = 'Plain *text* with `code` and no formulas.';
      expect(identical(protectMarkdownMath(text), text), isTrue);
    });

    test('inline dollar math keeps its characters', () {
      expect(
        protectMarkdownMath(r'Sea $a_1 * b_2$ el valor.'),
        r'Sea `a_1 * b_2` el valor.',
      );
    });

    test('currency is prose, not math', () {
      const text = r'Cuesta $5 and $10 en total.';
      expect(protectMarkdownMath(text), text);
    });

    test('Brazilian reais are prose, not math', () {
      const text = r'De R$ 12.345 até R$ 98.765 no ano.';
      expect(protectMarkdownMath(text), text);
    });

    test('currency before a real formula does not swallow it', () {
      expect(
        protectMarkdownMath(r'Pago $5 and $10 y luego $x^2$.'),
        r'Pago $5 and $10 y luego `x^2`.',
      );
    });

    test('closing dollar followed by a digit is not math', () {
      const text = r'Entre $a$1 y nada.';
      expect(protectMarkdownMath(text), text);
    });

    test('escaped dollars are literal', () {
      const text = r'Un \$a_1 * b_2\$ escapado.';
      expect(protectMarkdownMath(text), text);
    });

    test(r'\( ... \) is normalised to an inline span', () {
      expect(
        protectMarkdownMath(r'Vale \(a_1 * b_2\) aquí.'),
        r'Vale `a_1 * b_2` aquí.',
      );
    });

    test('display dollars become a block on their own lines', () {
      expect(
        protectMarkdownMath('Antes\n\$\$\nx_1 * y_2\n\$\$\nDespués'),
        'Antes\n\n```\nx_1 * y_2\n```\n\nDespués',
      );
    });

    test(r'\[ ... \] is normalised to a display block', () {
      expect(
        protectMarkdownMath('Mira \\[a_1 * b_2\\] listo'),
        'Mira\n\n```\na_1 * b_2\n```\n\nlisto',
      );
    });

    test('math inside inline code or fences is left alone', () {
      const text =
          'Usa `\$a_1 * b_2\$` literal.\n\n```bash\necho \$HOME \$PATH\n```\n';
      expect(protectMarkdownMath(text), text);
    });

    test('latex and tex fences stay code blocks', () {
      const text = '```latex\n\$\$x_1 * y_2\$\$\n```\n\n```tex\n\$a\$\n```';
      expect(protectMarkdownMath(text), text);
    });

    test('unterminated display span stays as written', () {
      const text = 'Voy a escribir \$\$x_1 * y_2';
      expect(protectMarkdownMath(text), text);
    });

    test('backticks inside the formula widen the span fence', () {
      expect(protectMarkdownMath(r'Sea $a`b$ ok.'), r'Sea ``a`b`` ok.');
    });

    test('result is memoised per text', () {
      const text = r'Otra $a_1 * b_2$ fórmula.';
      expect(identical(protectMarkdownMath(text), protectMarkdownMath(text)), isTrue);
    });
  });
}
