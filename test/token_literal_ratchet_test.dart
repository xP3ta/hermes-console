// Polish wave 2 (audit 1.4.0, §1 and §3): literal design values may not
// grow. Every new size, radius, duration or colour takes a token from
// `lib/core/theme/hermes_tokens.dart`. The ceilings below are the counts
// when the tokens were published; the literal wave (wave 9) migrates the
// code and lowers them. A count under its ceiling passes, so another wave
// that removes literals is never blocked by this test.
//
// Scope: every Dart file in `lib/` except the generated catalogs
// (`lib/l10n/`) and the token sources (`lib/core/theme/` and
// `lib/core/design/tokens.dart`), with comments removed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ceilings: the counts after the last file wave 9 migrated (at first,
/// when the tokens were published: 990 sizes, 364 radii, 273 durations,
/// 142 colours). Each step of the wave lowers them to what is left.
abstract final class _Ceiling {
  static const fontSize = 828;
  static const fontSizeValues = 22;
  static const radius = 307;
  static const radiusValues = 27;
  static const duration = 271; // +2: poll/backoff pacing (not motion) added by bg-fallback and rail
  // +2 net: retry/busy pacing of the restored 1.3.1 listening (+3 in
  // feat/restore-listener, already over the ceiling at b1c8f4b8), -1 with
  // the push memory read timeout gone.
  static const durationValues = 68;
  static const color = 137;

  /// Non-zero numbers inside `EdgeInsets` (2642 when wave 9 began).
  static const insets = 2317;
}

String _withoutComments(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//[^\r\n]*'), '');

bool _inScope(String path) =>
    !path.startsWith('lib/l10n/') &&
    !path.startsWith('lib/core/theme/') &&
    path != 'lib/core/design/tokens.dart';

Map<String, String> _scan() {
  final sources = <String, String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll(r'\', '/');
    if (!_inScope(path)) continue;
    sources[path] = _withoutComments(entity.readAsStringSync());
  }
  return sources;
}

final Map<String, String> _sources = _scan();

class _Count {
  _Count(RegExp pattern, {bool values = true}) {
    for (final entry in _sources.entries) {
      for (final match in pattern.allMatches(entry.value)) {
        total++;
        perFile[entry.key] = (perFile[entry.key] ?? 0) + 1;
        if (values) {
          distinct.add(double.parse(match.group(1)!.replaceAll('_', '')));
        }
      }
    }
  }

  /// Nothing counted yet: a subclass counts in its own way.
  _Count.empty();

  int total = 0;
  final Map<String, int> perFile = {};
  final Set<double> distinct = {};

  String get top {
    final files = perFile.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return files.take(10).map((e) => '${e.key}: ${e.value}').join(', ');
  }
}

/// The numbers inside each `EdgeInsets.*(...)` call of [_sources].
class _InsetCount extends _Count {
  _InsetCount() : super.empty() {
    final call = RegExp(
      r'EdgeInsets(?:Directional)?\.(?:all|symmetric|only|fromLTRB|fromSTEB)\(',
    );
    final number = RegExp(r'(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])');
    for (final entry in _sources.entries) {
      final source = entry.value;
      for (final match in call.allMatches(source)) {
        final open = match.end - 1;
        var depth = 0;
        var close = open;
        for (var i = open; i < source.length; i++) {
          if (source[i] == '(') depth++;
          if (source[i] == ')' && --depth == 0) {
            close = i;
            break;
          }
        }
        for (final n in number.allMatches(source.substring(open + 1, close))) {
          if (double.parse(n.group(1)!) == 0) continue;
          total++;
          perFile[entry.key] = (perFile[entry.key] ?? 0) + 1;
        }
      }
    }
  }
}

void _expectAtMost(String what, int found, int ceiling, _Count count) {
  expect(
    found,
    lessThanOrEqualTo(ceiling),
    reason:
        '$what grew from $ceiling to $found. Use a token from '
        'lib/core/theme/hermes_tokens.dart instead. '
        'Files with the most: ${count.top}',
  );
}

void main() {
  test('the scan reads the app and skips the token sources', () {
    expect(_sources, contains('lib/main.dart'));
    expect(_sources.keys.where((p) => p.startsWith('lib/l10n/')), isEmpty);
    expect(_sources, isNot(contains('lib/core/design/tokens.dart')));
    expect(_sources, isNot(contains('lib/core/theme/hermes_tokens.dart')));
  });

  test('literal font sizes do not grow (HermesType)', () {
    final count = _Count(RegExp(r'fontSize:\s*(\d+(?:\.\d+)?)'));
    _expectAtMost('fontSize literals', count.total, _Ceiling.fontSize, count);
    _expectAtMost(
      'Distinct literal font sizes',
      count.distinct.length,
      _Ceiling.fontSizeValues,
      count,
    );
  });

  test('literal radii do not grow (HermesRadius)', () {
    final count = _Count(RegExp(r'Radius\.circular\(\s*(\d+(?:\.\d+)?)\s*\)'));
    _expectAtMost(
      'Radius.circular literals',
      count.total,
      _Ceiling.radius,
      count,
    );
    _expectAtMost(
      'Distinct literal radii',
      count.distinct.length,
      _Ceiling.radiusValues,
      count,
    );
  });

  test('literal durations do not grow (HermesMotion)', () {
    final count = _Count(RegExp(r'Duration\(\s*milliseconds:\s*([\d_]+)\s*\)'));
    _expectAtMost(
      'Duration(milliseconds:) literals',
      count.total,
      _Ceiling.duration,
      count,
    );
    _expectAtMost(
      'Distinct literal durations',
      count.distinct.length,
      _Ceiling.durationValues,
      count,
    );
  });

  // Wave 9: a padding or margin takes HermesSpace. Counted are the
  // non-zero numbers written inside EdgeInsets(...), nested calls included.
  test('literal insets do not grow (HermesSpace)', () {
    final count = _InsetCount();
    _expectAtMost(
      'EdgeInsets number literals',
      count.total,
      _Ceiling.insets,
      count,
    );
  });

  test('colour literals outside the theme do not grow', () {
    final count = _Count(
      RegExp(r'Color\(\s*0x[0-9A-Fa-f]{8}\s*\)'),
      values: false,
    );
    _expectAtMost(
      'Color(0x…) literals outside lib/core/theme',
      count.total,
      _Ceiling.color,
      count,
    );
  });
}
