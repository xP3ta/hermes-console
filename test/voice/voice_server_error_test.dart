import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/utils/voice_error.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  final es = lookupStrings(const Locale('es'));
  final en = lookupStrings(const Locale('en'));

  const nousDetail =
      'TTS configuration error (openai): tts is configured to use nous '
      'but it is not available';

  test('a server TTS 400 shows the detail reported by Hermes', () {
    final error = DashboardHttpException(
      400,
      body: jsonEncode({'detail': nousDetail}),
    );

    final es1 = localizedVoiceError(es, error);
    final en1 = localizedVoiceError(en, error);

    expect(es1, contains(nousDetail));
    expect(en1, contains(nousDetail));
    expect(es1, isNot(es.voiceErrorUnexpected));
    expect(es1, es.v1215VoiceServerError(nousDetail));
  });

  test('a 5xx plain-text detail is surfaced trimmed', () {
    const error = DashboardHttpException(
      500,
      body: '  Speech synthesis failed  ',
    );
    expect(
      localizedVoiceError(es, error),
      es.v1215VoiceServerError('Speech synthesis failed'),
    );
  });

  test('long details are capped and secrets are redacted', () {
    final detail =
        'provider rejected api_key=abcdef123456 Bearer abcdefghijklmnop '
        'sk-ABCDEFGH12345678 ${'x' * 400}';
    final message = localizedVoiceError(
      es,
      DashboardHttpException(400, body: jsonEncode({'detail': detail})),
    );
    expect(message, isNot(contains('abcdef123456')));
    expect(message, isNot(contains('abcdefghijklmnop')));
    expect(message, isNot(contains('sk-ABCDEFGH12345678')));
    expect(message.length, lessThan(es.v1215VoiceServerError('').length + 205));
  });

  test('without a usable detail the generic copy remains', () {
    for (final body in const ['', '{}', '<html><body>502</body></html>']) {
      expect(
        localizedVoiceError(es, DashboardHttpException(502, body: body)),
        es.voiceErrorUnexpected,
        reason: body,
      );
    }
    expect(
      localizedVoiceError(es, TimeoutException('t')),
      es.voiceErrorPreviewTimeout,
    );
  });
}
