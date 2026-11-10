// The legibility matrix as a test: every theme the app can wear (the 42
// presets and the Look & Feel derivation on its five backgrounds and ten
// accents), every pair the widgets paint, measured with the WCAG formulas
// (support/legibility_matrix.dart). Text reads at AA, icons and control
// boundaries at 3:1, the contour of a box and the divider between rows at
// their own floors, a disabled label at 3:1. One failing pair fails the
// test and names itself; the table it prints is the inventory.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/hermes_style.dart';

import 'support/legibility_matrix.dart';

void main() {
  setUp(() {
    GlassLookPrefs.debugUse(GlassLookPrefs.inMemory(GlassLevel.full));
    HermesStylePrefs.debugUse(HermesStylePrefs.inMemory());
  });
  tearDown(() {
    GlassLookPrefs.debugUse(null);
    HermesStylePrefs.debugUse(null);
  });

  late final List<MatrixTheme> themes;
  late final List<MatrixPair> pairs;

  setUpAll(() {
    themes = matrixThemes();
    pairs = measureMatrix(themes);
  });

  test('the matrix covers the catalogue and the Look & Feel derivation', () {
    expect(themes.where((t) => t.family == 'catalog'), hasLength(42));
    // 2 light backgrounds x 10 accents + 3 dark backgrounds x 10 accents.
    expect(themes.where((t) => t.family == 'look-feel'), hasLength(50));
    expect(themes.where((t) => t.dark).length, greaterThan(40));
    expect(themes.where((t) => !t.dark).length, greaterThan(30));
  });

  test('prints the inventory, worst cases first', () {
    final markdown = matrixMarkdown(
      pairs,
      title: 'Matriz de legibilidad (tema x modo x par)',
    );
    // ignore: avoid_print
    print(markdown);
    writeMatrix(markdown);
  });

  for (final kind in PairKind.values) {
    test(
      '${kind.name}: every pair reaches ${kind.target}:1 in every theme',
      () {
        final bad = failing(pairs.where((p) => p.kind == kind).toList());
        expect(
          bad,
          isEmpty,
          reason: '${bad.length} below target:\n${bad.take(60).join('\n')}',
        );
      },
    );
  }
}
