import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// JSON parsers keep the last value of a repeated key and `gen-l10n` does
/// not complain, so a merge that kept both sides of an ARB block can leave
/// duplicate keys that silently shadow each other. Read the raw token stream
/// and reject any key that appears twice at the top level.
List<String> _duplicateTopLevelKeys(String source) {
  final seen = <String>{};
  final duplicates = <String>[];
  var depth = 0;
  var i = 0;
  while (i < source.length) {
    final ch = source[i];
    if (ch == '"') {
      final start = i + 1;
      var j = start;
      while (j < source.length && source[j] != '"') {
        if (source[j] == r'\') j++;
        j++;
      }
      final token = source.substring(start, j);
      var k = j + 1;
      while (k < source.length && source[k].trim().isEmpty) {
        k++;
      }
      if (depth == 1 && k < source.length && source[k] == ':') {
        if (!seen.add(token)) duplicates.add(token);
      }
      i = j + 1;
      continue;
    }
    if (ch == '{' || ch == '[') depth++;
    if (ch == '}' || ch == ']') depth--;
    i++;
  }
  return duplicates;
}

void main() {
  for (final path in const ['lib/l10n/app_en.arb', 'lib/l10n/app_es.arb']) {
    test('$path has no duplicate keys', () {
      final source = File(path).readAsStringSync();
      expect(() => jsonDecode(source), returnsNormally);
      expect(_duplicateTopLevelKeys(source), isEmpty);
    });
  }

  test('the duplicate-key reader detects a repeated key', () {
    expect(_duplicateTopLevelKeys('{"a": "1", "b": {"a": 2}, "a": "3"}'), [
      'a',
    ]);
  });
}
