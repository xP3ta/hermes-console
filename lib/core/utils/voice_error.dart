import 'dart:async';
import 'dart:convert';

import '../../l10n/app_localizations.dart';
import '../services/connection_manager.dart';
import '../services/voice/tts_engine.dart';

/// Traduce errores conocidos de voz sin exponer `toString()` técnico ni copy
/// fijado dentro de servicios.
String localizedVoiceError(Strings strings, Object error) {
  if (error is TimeoutException) return strings.voiceErrorPreviewTimeout;
  if (error is TtsUserException) {
    return switch (error.code) {
      TtsUserError.invalidKokoroAddress =>
        strings.voiceErrorInvalidKokoroAddress,
      TtsUserError.invalidKokoroPort => strings.voiceErrorInvalidKokoroPort,
      TtsUserError.kokoroUnavailable => strings.voiceErrorKokoroUnavailable,
      TtsUserError.kokoroNoVoices => strings.voiceErrorKokoroNoVoices,
      TtsUserError.invalidAudio => strings.voiceErrorInvalidAudio,
      TtsUserError.invalidCustomConfiguration =>
        strings.voiceCustomInvalidConfiguration,
      TtsUserError.customResponseMissingAudio =>
        strings.voiceErrorCustomResponseMissingAudio,
      TtsUserError.customHttpFailure => strings.voiceErrorCustomHttpFailure(
        error.statusCode?.toString() ?? '—',
      ),
    };
  }
  if (error is DashboardAuthException &&
      error.code == DashboardAuthFailureCode.loginRequired) {
    return strings.voiceErrorDashboardLogin;
  }
  final detail = serverVoiceErrorDetail(error);
  if (detail != null) return strings.v1215VoiceServerError(detail);
  if (error is StateError) return strings.voiceErrorUnavailable;
  return strings.voiceErrorUnexpected;
}

const int _kServerVoiceDetailMaxLength = 200;

/// Motivo que Hermes devolvió en una respuesta 4xx/5xx de `/api/audio/*`
/// (`detail`/`message`/`error` de FastAPI o texto plano), recortado, acotado y
/// sin credenciales. Devuelve null si el cuerpo no trae un motivo legible.
String? serverVoiceErrorDetail(Object error) {
  if (error is! DashboardHttpException || error.statusCode < 400) return null;
  final body = error.body.trim();
  if (body.isEmpty) return null;
  String? detail;
  if (body.startsWith('{')) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        for (final key in const ['detail', 'message', 'error']) {
          final value = decoded[key];
          if (value is String && value.trim().isNotEmpty) {
            detail = value;
            break;
          }
          if (value is List && value.isNotEmpty) {
            final first = value.first;
            if (first is Map && first['msg'] is String) {
              detail = first['msg'] as String;
              break;
            }
          }
        }
      }
    } on FormatException {
      return null;
    }
  } else if (!body.startsWith('<')) {
    detail = body;
  }
  if (detail == null) return null;
  var safe = detail.replaceAll(RegExp(r'\s+'), ' ').trim();
  safe = safe.replaceAll(
    RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]{6,}', caseSensitive: false),
    'Bearer [redacted]',
  );
  safe = safe.replaceAllMapped(
    RegExp(
      r'\b(api[_ -]?key|token|password|secret)\s*[:=]\s*[^\s,;]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}=[redacted]',
  );
  safe = safe.replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]{6,}'), '[redacted]');
  if (safe.isEmpty) return null;
  return safe.length > _kServerVoiceDetailMaxLength
      ? '${safe.substring(0, _kServerVoiceDetailMaxLength)}…'
      : safe;
}
