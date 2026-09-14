import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Chat and Voice boundaries never expose raw exception details', () {
    const files = <String>[
      'lib/core/services/active_chat_service.dart',
      'lib/core/services/local_transcript_store.dart',
      'lib/core/services/voice/neural_tts_worker.dart',
      'lib/core/services/voice/sherpa_stt_worker.dart',
      'lib/core/services/voice/stt_engine.dart',
      'lib/core/services/voice/stt_hermes_server.dart',
      'lib/core/services/voice/stt_remote.dart',
      'lib/core/services/voice/stt_sherpa.dart',
      'lib/core/services/voice/tts_engine.dart',
      'lib/core/services/voice/voice_service.dart',
    ];
    final rawInterpolation = RegExp(r'\$(?:e|error)\b(?!\.)');
    final directSink = RegExp(
      r'(?:controller\.)?addError\((?:e|error)\s*\)|'
      r'lastError\s*=\s*message\s*;|'
      r'workerError\s*=\s*error\.toString\(\)',
    );
    final violations = <String>[];

    for (final path in files) {
      final source = File(path).readAsStringSync();
      for (final match in rawInterpolation.allMatches(source)) {
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        violations.add('$path:$line raw exception interpolation');
      }
      for (final match in directSink.allMatches(source)) {
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        violations.add('$path:$line raw exception sink');
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
