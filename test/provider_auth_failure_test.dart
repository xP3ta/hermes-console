import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/provider_auth_failure.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/provider_reauth.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

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

  group('compaction banner wording', () {
    // A refused compaction only stops the automatic summary; the owner must
    // not read it as "the chat is broken".
    Future<void> pumpBanner(
      WidgetTester tester,
      Locale locale,
      ProviderAuthFailure failure,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          locale: locale,
          theme: AppTheme.hermesRedDark,
          home: Scaffold(
            body: ProviderAuthBanner(
              failure: failure,
              onAction: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    const compaction = ProviderAuthFailure(
      provider: 'anthropic',
      label: 'Anthropic',
      kind: ProviderAuthKind.oauth,
      origin: ProviderAuthOrigin.compaction,
    );

    testWidgets('Spanish says only compaction is affected', (tester) async {
      await pumpBanner(tester, const Locale('es'), compaction);
      expect(
        find.text(
          'La compactación no puede usar Anthropic; el chat sigue funcionando',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('puedes seguir escribiendo'), findsOneWidget);
      expect(find.textContaining('fallarán'), findsNothing);
      expect(find.text('Volver a iniciar sesión'), findsOneWidget);
    });

    testWidgets('English says only compaction is affected', (tester) async {
      await pumpBanner(tester, const Locale('en'), compaction);
      expect(
        find.text('Compaction cannot use Anthropic; the chat keeps working'),
        findsOneWidget,
      );
      expect(find.textContaining('you can keep writing'), findsOneWidget);
      expect(find.textContaining('will fail'), findsNothing);
    });

    testWidgets('without a label it names no provider', (tester) async {
      await pumpBanner(
        tester,
        const Locale('es'),
        const ProviderAuthFailure(
          provider: '',
          label: '',
          kind: ProviderAuthKind.oauth,
          origin: ProviderAuthOrigin.compaction,
        ),
      );
      expect(
        find.text(
          'La compactación no puede usar el proveedor; el chat sigue funcionando',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a failed turn keeps the sign-in expired title', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        const Locale('es'),
        const ProviderAuthFailure(
          provider: 'anthropic',
          label: 'Anthropic',
          kind: ProviderAuthKind.oauth,
        ),
      );
      expect(find.text('La sesión de Anthropic ha caducado'), findsOneWidget);
    });
  });

  group('providerSignedIn', () {
    Map<String, dynamic> card(
      String id,
      bool loggedIn, {
      bool freeTier = false,
    }) => {
      'id': id,
      'status': {'logged_in': loggedIn, 'free_tier': freeTier},
    };

    test('a Claude Code login counts for the anthropic runtime', () {
      expect(
        providerSignedIn([
          card('anthropic', false),
          card('claude-code', true),
        ], 'anthropic'),
        isTrue,
      );
    });

    test('both Anthropic cards signed out is signed out', () {
      expect(
        providerSignedIn([
          card('anthropic', false),
          card('claude-code', false),
        ], 'anthropic'),
        isFalse,
      );
    });

    test('other providers only trust their own card', () {
      expect(
        providerSignedIn([
          card('nous', false),
          card('claude-code', true),
        ], 'nous'),
        isFalse,
      );
      expect(providerSignedIn([card('nous', true)], 'nous'), isTrue);
    });

    test('a free-tier Nous identity is not a connected account', () {
      expect(
        providerSignedIn([card('nous', true, freeTier: true)], 'nous'),
        isFalse,
      );
    });
  });
}
