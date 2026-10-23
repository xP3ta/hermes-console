import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_dart_literals.dart';

Map<String, int> _counts(Iterable<String> literals) {
  final counts = <String, int>{};
  for (final literal in literals) {
    counts.update(literal, (count) => count + 1, ifAbsent: () => 1);
  }
  return counts;
}

void main() {
  test('all lib literals have an explicit reviewed allowlist entry', () {
    final raw = jsonDecode(File('tool/l10n/literal_allowlist.json').readAsStringSync()) as Map<String, dynamic>;
    final expected = <String, Map<String, int>>{};
    for (final entry in raw.entries) {
      final counts = <String, int>{};
      for (final item in entry.value as List) {
        final row = item as Map<String, dynamic>;
        final literal = row['literal'] as String;
        expect(row['reason'], isA<String>());
        expect((row['reason'] as String).trim(), isNotEmpty);
        expect(row['count'], isPositive);
        expect(counts.containsKey(literal), isFalse);
        counts[literal] = row['count'] as int;
      }
      expected[entry.key] = counts;
    }
    const generated = {
      'lib/l10n/app_localizations.dart',
      'lib/l10n/app_localizations_es.dart',
      'lib/l10n/app_localizations_en.dart',
      'lib/l10n/app_localizations_pt.dart',
      'lib/l10n/app_localizations_de.dart',
      'lib/l10n/app_localizations_fr.dart',
      'lib/l10n/app_localizations_it.dart',
      'lib/l10n/app_localizations_ja.dart',
      'lib/l10n/app_localizations_ko.dart',
      'lib/l10n/app_localizations_zh.dart',
    };
    final actual = <String, Map<String, int>>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (generated.contains(path)) continue;
      final counts = _counts(dartStringLiterals(entity.readAsStringSync()));
      if (counts.isNotEmpty) actual[path] = counts;
    }
    expect(actual.keys.toSet(), expected.keys.toSet());
    for (final path in actual.keys) {
      expect(actual[path], expected[path], reason: 'Review new copy and remove stale entries in $path');
    }
  });

  test('lexer includes helpers, ternaries, nested strings and raw/triple strings', () {
    const source = r'''// Text('comment')
/* outer /* 'comment' */ comment */
Text("hello ${name ?? 'world'}");
return 'new helper';
final x = flag ? 'yes' : r'$raw';
final y = """triple ${f('nested')}""";
''';
    expect(_counts(dartStringLiterals(source)), {
      r'''"hello ${name ?? 'world'}"''': 1,
      "'world'": 1,
      "'new helper'": 1,
      "'yes'": 1,
      "r'\$raw'": 1,
      r'''"""triple ${f('nested')}"""''': 1,
      "'nested'": 1,
    });
  });

  test('additional occurrences of an approved spelling still fail', () {
    final approved = _counts(dartStringLiterals("Text('Hermes');"));
    final mutant = _counts(dartStringLiterals("Text('Hermes'); Text('Hermes');"));
    expect(mutant, isNot(equals(approved)));
  });
}
