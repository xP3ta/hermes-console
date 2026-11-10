// The last lines of a thought being written never show the Markdown around
// them: only well-formed pairs go, a lone `*` or a snake_case name stays.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/reasoning_plain.dart';

void main() {
  test('a bold line on its own is its text, no asterisks', () {
    expect(
      cleanReasoningTail('**Checking router DNS**'),
      'Checking router DNS',
    );
    expect(
      cleanReasoningTail('**Checking router DNS**\nProbando la ruta.'),
      'Checking router DNS Probando la ruta.',
    );
  });

  test('inline code, links, headings, bullets and quotes lose their marks', () {
    expect(
      cleanReasoningTail('Abro `main.dart` ahora'),
      'Abro main.dart ahora',
    );
    expect(
      cleanReasoningTail('Leo [la guia](https://x.dev/a) y sigo'),
      'Leo la guia y sigo',
    );
    expect(
      cleanReasoningTail('## Plan\n- uno\n* dos\n+ tres'),
      'Plan uno dos tres',
    );
    expect(cleanReasoningTail('> nota'), 'nota');
    expect(
      cleanReasoningTail('Esto es __muy claro__ ya'),
      'Esto es muy claro ya',
    );
  });

  test('legitimate asterisks, underscores, numbers and emoji stay', () {
    expect(cleanReasoningTail('calculo 2*3*4 = 24'), 'calculo 2*3*4 = 24');
    expect(cleanReasoningTail('2**3 es 8'), '2**3 es 8');
    expect(
      cleanReasoningTail('abro /srv/my_app/run_all.sh y snake_case'),
      'abro /srv/my_app/run_all.sh y snake_case',
    );
    expect(
      cleanReasoningTail('llama a __init__ luego'),
      'llama a __init__ luego',
    );
    expect(
      cleanReasoningTail('1. primero 🙂 2. luego'),
      '1. primero 🙂 2. luego',
    );
    expect(cleanReasoningTail('un guion - suelto'), 'un guion - suelto');
  });

  test('a half-written pair at the end is dropped, not shown', () {
    expect(cleanReasoningTail('**Checking rou'), 'Checking rou');
    expect(cleanReasoningTail('Reviso `ls -'), 'Reviso ls -');
    expect(cleanReasoningTail('termina el titulo**'), 'termina el titulo');
  });

  test('empty and mark-only text give nothing', () {
    expect(cleanReasoningTail(''), '');
    expect(cleanReasoningTail('   \n  '), '');
    expect(cleanReasoningTail('****'), '');
    expect(cleanReasoningTail('## \n- \n**'), '');
  });

  test('long text keeps only its tail, never splits an emoji, never leaves '
      'a dangling pair', () {
    final long = '${'palabra ' * 400}**Titulo final**';
    final out = cleanReasoningTail(long, keep: 40);
    expect(out.length, lessThanOrEqualTo(40));
    expect(out, endsWith('Titulo final'));
    expect(out, isNot(contains('*')));
    final emoji = '🙂' * 400;
    final cut = cleanReasoningTail(emoji, keep: 41);
    expect(cut.runes.every((r) => r == 0x1F642), isTrue);
    final windowed = cleanReasoningTail('${'🙂' * 900}fin', window: 701);
    expect(windowed.runes.every((r) => r == 0x1F642 || r < 0x80), isTrue);
  });
}
