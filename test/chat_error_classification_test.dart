// Tests del mapeo de errores del chat.
//
// Verifica que los mensajes humanizados (generados por _humanizeBridgeError y
// otros) se clasifiquen correctamente y NO mezclen categorías:
// · Un timeout local no debe clasificarse como error de modelo/API.
// · Un agente local caído no debe sugerir revisar credenciales.
// · Un 401 remoto sí debe clasificarse como error de modelo/API.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/utils/chat_error.dart';

void main() {
  group('classifyChatError — local agent errors', () {
    test('timeout del agente local → localColdStart (no model)', () {
      const msg =
          'El agente local tardó demasiado en responder. El modelo puede '
          'estar cargándose; espera unos segundos y reintenta.';
      expect(classifyChatError(msg), ChatErrorKind.localColdStart);
    });

    test('agente local caído (proceso cerrado) → local', () {
      const msg =
          'El agente local se detuvo durante la respuesta (el proceso se '
          'cerró, normalmente por falta de memoria). Vuelve a arrancar el '
          'agente local y reintenta.';
      expect(classifyChatError(msg), ChatErrorKind.local);
    });

    test('un texto antiguo sobre el agente local → local', () {
      const msg =
          'No se pudo conectar con el agente local (Mobile Bridge). '
          'Arranca el agente y reintenta.';
      expect(classifyChatError(msg), ChatErrorKind.local);
    });

    test('the word «bridge» alone no longer means the local agent is down', () {
      // Hermes has tools of its own called bridges; an error that names one
      // is not about a local agent.
      for (final msg in [
        'tool_call bridge failed: connector unavailable',
        'Mobile Bridge returned an unexpected answer',
      ]) {
        expect(classifyChatError(msg), isNot(ChatErrorKind.local));
      }
    });

    test('SocketException de conexión rechazada → connection', () {
      const msg = 'SocketException: Connection refused (host:127.0.0.1)';
      // 127.0.0.1 activaría "local", pero connection refused es más específico
      // y debe activar "connection" antes (o el orden garantiza local primero).
      // El mensaje humanizado usa "agente local", que cae en local.
      // Este test cubre el caso donde solo llega la excepción sin humanizar.
      final kind = classifyChatError(msg);
      expect(
        kind,
        anyOf(ChatErrorKind.local, ChatErrorKind.connection),
        reason: 'La IP local puede detectarse antes que "connection refused"',
      );
    });
  });

  group('classifyChatError — what the turn was missing', () {
    test('the Dashboard refused this phone → a sign-in, not a retry', () {
      expect(
        classifyChatError(dashboardSignInRequiredError),
        ChatErrorKind.dashboardSignInRequired,
      );
      expect(isChatErrorCode(dashboardSignInRequiredError), isTrue);
    });

    test('the live channel was not there → a connection error', () {
      expect(
        classifyChatError(officialChannelUnavailableError),
        ChatErrorKind.connection,
      );
      expect(isChatErrorCode(officialChannelUnavailableError), isTrue);
    });

    test('the same failures as older builds stored them, in English', () {
      for (final stored in [
        'Hermes Desktop session lifecycle is required',
        'Official Hermes gateway unavailable; reconnect and retry',
      ]) {
        expect(classifyChatError(stored), ChatErrorKind.connection);
        expect(isChatErrorCode(stored), isFalse);
      }
    });

    test('ordinary text is never taken for a code', () {
      expect(isChatErrorCode('No se pudo enviar el mensaje.'), isFalse);
      expect(isChatErrorCode('  $dashboardSignInRequiredError\n'), isTrue);
    });
  });

  group('classifyChatError — remote API errors', () {
    test('401 Unauthorized → model', () {
      expect(
        classifyChatError('HTTP 401: {"detail":"Unauthorized"}'),
        ChatErrorKind.model,
      );
    });

    test('403 Forbidden → model', () {
      expect(classifyChatError('403 Forbidden'), ChatErrorKind.model);
    });

    test('429 rate limit → model', () {
      expect(
        classifyChatError('429 Too Many Requests / rate limit exceeded'),
        ChatErrorKind.model,
      );
    });

    test('api key inválida → model', () {
      expect(
        classifyChatError('Invalid API key provided'),
        ChatErrorKind.model,
      );
    });

    test('"model" en inglés → model (NO false-positive con "modelo")', () {
      // Verifica que la palabra inglesa "model" siga siendo detectada para
      // mensajes remotos reales, pero no se active antes que los checks locales.
      expect(
        classifyChatError('The model gpt-4 is not available'),
        ChatErrorKind.model,
      );
    });
  });

  group('classifyChatError — "modelo" español no debe clasificar como model', () {
    test(
      '"modelo" en mensaje local no activa model si hay señal local primero',
      () {
        // Caso que fallaba antes del fix: "modelo" contenía "model" en inglés.
        const msg =
            'El agente local tardó demasiado. El modelo puede estar cargándose.';
        expect(classifyChatError(msg), ChatErrorKind.localColdStart);
      },
    );

    test('"modelo" sin señal local → model (comportamiento esperado)', () {
      // Un mensaje genérico sobre el modelo sin señal local sí debe ir a model.
      const msg = 'Error al cargar el modelo configurado en el servidor.';
      expect(classifyChatError(msg), ChatErrorKind.model);
    });
  });

  group('classifyChatError — connection errors', () {
    test('timeout de red → connection', () {
      expect(
        classifyChatError('Request timeout after 30s'),
        ChatErrorKind.connection,
      );
    });

    test('DNS no resuelve → connection', () {
      expect(
        classifyChatError('Failed host lookup: hermes.local'),
        ChatErrorKind.connection,
      );
    });

    test('TLS/handshake → connection', () {
      expect(
        classifyChatError('HandshakeException: TLS handshake failed'),
        ChatErrorKind.connection,
      );
    });
  });

  group('classifyChatError — tool errors', () {
    test('tool error → tool', () {
      expect(
        classifyChatError('Tool execute_code failed: exit code 1'),
        ChatErrorKind.tool,
      );
    });
  });

  group('classifyChatError — sessionTooLarge (context_overflow)', () {
    test('mensaje real del backend → sessionTooLarge, no model', () {
      expect(
        classifyChatError(
          "Context compression could not bring this session under the "
          "model's context window (~247,480 tokens vs 128,000). The provider "
          'call was not sent. Start a new session with /new; this session is '
          'too large to compress further.',
        ),
        ChatErrorKind.sessionTooLarge,
      );
    });

    test('código tipado context_overflow → sessionTooLarge', () {
      expect(
        classifyChatError('context_overflow'),
        ChatErrorKind.sessionTooLarge,
      );
    });
  });

  group('classifyChatError — unknown fallback', () {
    test('mensaje genérico sin señales → unknown', () {
      expect(classifyChatError('Something went wrong'), ChatErrorKind.unknown);
    });
  });

  group('classifyChatError — firstTokenTimeout (remoto)', () {
    test(
      'prefijo firstTokenTimeout emitido por active_chat_service → firstTokenTimeout',
      () {
        const msg =
            'firstTokenTimeout: El servidor conectó pero no empezó a generar '
            'respuesta en 90 s. El modelo puede estar cargando.';
        expect(classifyChatError(msg), ChatErrorKind.firstTokenTimeout);
      },
    );
  });

  group('classifyChatError — searchToolUnavailable', () {
    test('search tool unavailable en inglés → searchToolUnavailable', () {
      expect(
        classifyChatError('search tool unavailable for this model'),
        ChatErrorKind.searchToolUnavailable,
      );
    });

    test('búsqueda no disponible en español → searchToolUnavailable', () {
      expect(
        classifyChatError('búsqueda no disponible en esta configuración'),
        ChatErrorKind.searchToolUnavailable,
      );
    });

    test('web search not available → searchToolUnavailable', () {
      expect(
        classifyChatError('web search not available on this provider'),
        ChatErrorKind.searchToolUnavailable,
      );
    });
  });

  test('a named profile without Dashboard access has its own kind', () {
    expect(
      classifyChatError(const ProfileTranscriptAccessRequired().toString()),
      ChatErrorKind.profileDashboardAccess,
    );
    expect(
      classifyChatError('HTTP 401'),
      isNot(ChatErrorKind.profileDashboardAccess),
    );
  });
}
