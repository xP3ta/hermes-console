import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<String> _localTranscriptInvocations(String source) sync* {
  final call = RegExp(
    r'LocalTranscriptStore\.(saveFromNewestFirst|load|loadSnapshot|clear|listForConnection)\s*\(',
  );
  for (final match in call.allMatches(source)) {
    var depth = 1;
    var cursor = match.end;
    while (cursor < source.length && depth > 0) {
      final char = source[cursor++];
      if (char == '(') depth++;
      if (char == ')') depth--;
    }
    yield source.substring(match.start, cursor);
  }
}

void main() {
  test('guard recognizes loadSnapshot as profile-sensitive', () {
    final calls = _localTranscriptInvocations(
      'LocalTranscriptStore.loadSnapshot('
      "'connection', 'session', profile: 'owner')",
    ).toList();

    expect(calls, hasLength(1));
  });

  test(
    'every production transcript save load snapshot clear and list binds profile',
    () {
      final production = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      final calls = <String>[];
      for (final file in production) {
        calls.addAll(_localTranscriptInvocations(file.readAsStringSync()));
      }

      expect(calls, isNotEmpty);
      for (final invocation in calls) {
        expect(
          invocation,
          contains('profile:'),
          reason: 'Unscoped local transcript call:\n$invocation',
        );
      }
    },
  );
}
