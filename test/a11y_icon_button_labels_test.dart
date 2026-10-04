import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every IconButton in lib has a tooltip', () {
    final missing = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in files) {
      final source = file.readAsStringSync();
      for (final match in RegExp(
        r'IconButton(?:\.[A-Za-z]+)?\s*\(',
      ).allMatches(source)) {
        if (match.group(0)!.startsWith('IconButton.styleFrom')) continue;
        final open = source.indexOf('(', match.start);
        final close = _matchingParen(source, open);
        if (close == null) {
          missing.add(
            '${file.path}:${_lineAt(source, match.start)} (unparsed)',
          );
          continue;
        }
        final invocation = source.substring(open + 1, close);
        if (!RegExp(r'\btooltip\s*:').hasMatch(invocation) &&
            !_hasLabelledWrapper(source, match.start, close)) {
          missing.add('${file.path}:${_lineAt(source, match.start)}');
        }
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'Icon-only controls need a localized tooltip:\n'
          '${missing.join('\n')}',
    );
  });
}

int _lineAt(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

bool _hasLabelledWrapper(String source, int buttonStart, int buttonEnd) {
  final wrappers = RegExp(
    r'\b(?:Semantics|Tooltip)\s*\(',
  ).allMatches(source.substring(0, buttonStart)).toList().reversed;
  for (final wrapper in wrappers) {
    final open = source.indexOf('(', wrapper.start);
    final close = _matchingParen(source, open);
    if (close == null || close < buttonEnd) continue;
    final invocation = source.substring(open + 1, close);
    return RegExp(r'\b(?:label|message)\s*:').hasMatch(invocation);
  }
  return false;
}

int? _matchingParen(String source, int open) {
  var depth = 0;
  String? quote;
  var escaped = false;

  for (var index = open; index < source.length; index++) {
    final char = source[index];
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (char == '\\') {
        escaped = true;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      continue;
    }
    if (char == '(') depth++;
    if (char == ')' && --depth == 0) return index;
  }
  return null;
}
