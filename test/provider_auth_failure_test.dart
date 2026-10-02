import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/provider_auth_failure.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';

/// hr1215: port of Desktop `lib/error-surface.ts` auth rules.
void main() {
  const revoked =
      'HTTP 401: {"type":"error","error":{"type":"authentication_error",'
      '"message":"OAuth access token has been revoked."}}';

  group('ProviderAuthFailure.classify', () {
    test('auth layer + oauth names the provider and asks to sign in', () {
      final failure = ProviderAuthFailure.classify(
        errorSurface: const {
          'layer': 'auth',
          'code': 'auth',
          'retryable': false,
          'provider': 'openai-codex',
          'provider_label': 'ChatGPT',
          'auth_kind': 'oauth',
        },
      )!;
      expect(failure.provider, 'openai-codex');
      expect(failure.label, 'ChatGPT');
      expect(failure.kind, ProviderAuthKind.oauth);
    });

    test('auth layer + api_key asks for the key', () {
      final failure = ProviderAuthFailure.classify(
        errorSurface: const {
          'layer': 'auth',
          'code': 'auth',
          'provider': 'openrouter',
          'auth_kind': 'api_key',
        },
        errorText: 'invalid x-api-key',
      )!;
      expect(failure.kind, ProviderAuthKind.apiKey);
      expect(failure.label, 'openrouter');
    });

    test('a revoked OAuth token wins over a declared api_key', () {
      final failure = ProviderAuthFailure.classify(
        errorSurface: const {
          'layer': 'auth',
          'code': 'auth',
          'provider': 'anthropic',
          'auth_kind': 'api_key',
        },
        errorText: revoked,
      )!;
      expect(failure.kind, ProviderAuthKind.oauth);
    });

    test('a valid non-auth surface is authoritative even with 401 text', () {
      expect(
        ProviderAuthFailure.classify(
          errorSurface: const {'layer': 'provider', 'code': 'server_error'},
          errorText: revoked,
        ),
        isNull,
      );
    });

    test('no surface: the provider 401 wording is sniffed', () {
      final failure = ProviderAuthFailure.classify(
        errorText: revoked,
        sessionProvider: 'anthropic',
      )!;
      expect(failure.provider, 'anthropic');
      expect(failure.kind, ProviderAuthKind.oauth);
    });

    test('a garbled surface falls back to the text', () {
      expect(
        ProviderAuthFailure.classify(
          errorSurface: const {'layer': 'nonsense'},
          errorText: revoked,
        ),
        isNotNull,
      );
    });

    test('a bare 401 or Dashboard unauthorized is not a provider failure', () {
      for (final text in const [
        'HTTP 401',
        'Unauthorized',
        'No se pudo completar la respuesta',
        'session token expired for the dashboard login',
      ]) {
        expect(
          ProviderAuthFailure.classify(errorText: text),
          isNull,
          reason: text,
        );
      }
    });

    test('round-trips through the row metadata', () {
      const failure = ProviderAuthFailure(
        provider: 'nous',
        label: 'Nous Portal',
        kind: ProviderAuthKind.oauth,
        origin: ProviderAuthOrigin.compaction,
      );
      final back = ProviderAuthFailure.fromJson(failure.toJson())!;
      expect(back.toJson(), failure.toJson());
    });
  });

  test('a resumed failed turn keeps its classified credential failure', () {
    final snapshot = DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-auth',
        'session_key': 'stored-1',
        'info': {'provider': 'anthropic'},
        'inflight': {
          'user': 'resume',
          'assistant': '',
          'streaming': false,
          'error': revoked,
          'status': 'error',
          'recoverable': true,
          'error_surface': {
            'layer': 'auth',
            'code': 'auth',
            'provider': 'anthropic',
            'provider_label': 'Anthropic',
            'auth_kind': 'api_key',
          },
        },
        'running': false,
        'status': 'idle',
      },
      requestedStoredSessionId: 'stored-1',
      created: false,
      method: 'session.resume',
    );
    final projected = const DesktopSessionReconciler().project(snapshot);
    final error = projected.messagesNewestFirst.first;
    expect(error['role'], 'assistant_error');
    expect(
      ProviderAuthFailure.fromJson(error[providerAuthFailureKey])?.toJson(),
      {
        'provider': 'anthropic',
        'label': 'Anthropic',
        'kind': 'oauth',
        'origin': 'turn',
      },
    );
    final normalized = normalizeTranscriptMessageForDisplay(
      error,
      retainProjectionState: true,
    )!;
    expect(normalized[providerAuthFailureKey], error[providerAuthFailureKey]);
  });
}
