import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The owner retired the "Spark" mascot: the default companion is now the
/// profile's own face. Nothing in the shipped app (code, strings, bundled
/// assets, provenance/SBOM) may name it again.
final _sparkName = RegExp(r'\b[Ss]park\b|HermesSpark|hermesSpark|spark_mark');

Iterable<File> _files(String dir, bool Function(String) include) => Directory(
  dir,
).listSync(recursive: true).whereType<File>().where((f) => include(f.path));

List<String> _hits(Iterable<File> files) {
  final hits = <String>[];
  for (final file in files) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (_sparkName.hasMatch(lines[i])) {
        hits.add('${file.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
  }
  return hits;
}

void main() {
  test('no Dart source or string table under lib/ names Spark', () {
    final hits = _hits(
      _files('lib', (p) => p.endsWith('.dart') || p.endsWith('.arb')),
    );
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('pubspec, provenance and SBOM carry no Spark asset', () {
    final hits = _hits([
      File('pubspec.yaml'),
      File('ASSET_PROVENANCE.md'),
      ..._files('sbom', (p) => p.endsWith('.json')),
    ]);
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('the Spark mark files are gone from assets/', () {
    final leftovers = _files(
      'assets',
      (p) => p.contains('spark_mark'),
    ).map((f) => f.path).toList();
    expect(leftovers, isEmpty);
    expect(
      File('lib/core/widgets/hermes_spark_mascot.dart').existsSync(),
      isFalse,
    );
  });

  test('the guard pattern does not flag unrelated words', () {
    // `_preparedTurnsParked` and `sparkle` are not the mascot.
    expect(_sparkName.hasMatch('_preparedTurnsParkedThisProcess'), isFalse);
    expect(_sparkName.hasMatch('sparkle'), isFalse);
    expect(_sparkName.hasMatch('Default (Spark)'), isTrue);
    expect(_sparkName.hasMatch('HermesSparkMood.idle'), isTrue);
  });
}
