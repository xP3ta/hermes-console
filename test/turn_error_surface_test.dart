import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/provider_auth_failure.dart';
import 'package:hermes_android/core/models/turn_error_surface.dart';

TurnErrorSurface surfaceOf(
  String code, {
  String layer = 'provider',
  bool retryable = true,
  Map<String, Object?> extra = const {},
}) => TurnErrorSurface.parse({
  'layer': layer,
  'code': code,
  'retryable': retryable,
  ...extra,
})!;

ErrorRecoveryPlan planOf(
  String code, {
  String layer = 'provider',
  bool retryable = true,
  ProviderAuthFailure? authFailure,
}) => errorRecoveryPlan(
  surface: surfaceOf(code, layer: layer, retryable: retryable),
  authFailure: authFailure,
);

void main() {
  group('TurnErrorSurface.parse', () {
    test('keeps layer, code and retryable of a well formed surface', () {
      final surface = TurnErrorSurface.parse({
        'layer': 'provider',
        'code': 'rate_limit',
        'retryable': true,
        'provider': 'anthropic',
        'provider_label': 'Anthropic',
        'model': 'claude-example',
      })!;
      expect(surface.layer, 'provider');
      expect(surface.code, 'rate_limit');
      expect(surface.retryable, isTrue);
      expect(surface.provider, 'anthropic');
      expect(surface.providerLabel, 'Anthropic');
      expect(surface.model, 'claude-example');
      expect(surface.resetsAt, isNull);
      expect(surface.message, isNull);
    });

    test('an unknown layer or a non-map is no surface', () {
      expect(TurnErrorSurface.parse({'layer': 'nope', 'code': 'x'}), isNull);
      expect(TurnErrorSurface.parse({'code': 'x'}), isNull);
      expect(TurnErrorSurface.parse('provider'), isNull);
      expect(TurnErrorSurface.parse(null), isNull);
    });

    test('knows the eight layers of the gateway', () {
      for (final layer in const [
        'provider',
        'endpoint',
        'streaming',
        'auth',
        'billing',
        'gateway',
        'runtime',
        'disk',
      ]) {
        expect(
          TurnErrorSurface.parse({'layer': layer, 'code': 'c'}),
          isNotNull,
          reason: layer,
        );
      }
    });

    test('an empty code becomes unknown', () {
      expect(
        TurnErrorSurface.parse({'layer': 'provider', 'code': '  '})!.code,
        'unknown',
      );
      expect(TurnErrorSurface.parse({'layer': 'provider'})!.code, 'unknown');
    });

    test('an oversized code is dropped to unknown, never stored', () {
      final surface = TurnErrorSurface.parse({
        'layer': 'provider',
        'code': 'x' * 10000000,
        'retryable': true,
      })!;
      expect(surface.code, 'unknown');
      expect(jsonEncode(surface.toJson()).length, lessThan(200));
    });

    test('a code at the limit is kept, one more is not', () {
      expect(surfaceOf('c' * 64).code, 'c' * 64);
      expect(surfaceOf('c' * 65).code, 'unknown');
    });

    test('an oversized code cannot grow the copied details', () {
      final text = formatErrorDiagnostics(
        now: DateTime.utc(2026, 10, 4),
        surface: surfaceOf('x' * 5000000),
        composerProvider: null,
        composerModel: null,
        appVersion: '1.2.15',
        error: 'Boom',
      );
      expect(text.length, lessThan(400));
      expect(text, contains('code: unknown'));
    });

    test('retryable is true unless the gateway says false', () {
      expect(
        TurnErrorSurface.parse({'layer': 'provider', 'code': 'c'})!.retryable,
        isTrue,
      );
      expect(
        TurnErrorSurface.parse({
          'layer': 'provider',
          'code': 'c',
          'retryable': null,
        })!.retryable,
        isTrue,
      );
      expect(
        TurnErrorSurface.parse({
          'layer': 'provider',
          'code': 'c',
          'retryable': false,
        })!.retryable,
        isFalse,
      );
    });

    test('resets_at needs a finite number above zero', () {
      double? resetOf(Object? value) => TurnErrorSurface.parse({
        'layer': 'provider',
        'code': 'rate_limit',
        'resets_at': value,
      })!.resetsAt;
      expect(resetOf(1790000000), 1790000000);
      expect(resetOf(1790000000.5), 1790000000.5);
      expect(resetOf(0), isNull);
      expect(resetOf(-5), isNull);
      expect(resetOf(double.nan), isNull);
      expect(resetOf(double.infinity), isNull);
      expect(resetOf('1790000000'), isNull);
      expect(resetOf(null), isNull);
    });

    test('message is trimmed, dropped when blank and capped at 500', () {
      String? messageOf(Object? value) => TurnErrorSurface.parse({
        'layer': 'provider',
        'code': 'free_tier_rate_limited',
        'message': value,
      })!.message;
      expect(messageOf('  Free tier is busy  '), 'Free tier is busy');
      expect(messageOf('   '), isNull);
      expect(messageOf(42), isNull);
      expect(messageOf(null), isNull);
      expect(messageOf('x' * 900)!.length, 500);
    });

    test('null in every optional field does not break the parse', () {
      final surface = TurnErrorSurface.parse({
        'layer': 'auth',
        'code': 'auth',
        'retryable': null,
        'provider': null,
        'provider_label': null,
        'model': null,
        'auth_kind': null,
        'api_key_env': null,
        'message': null,
        'resets_at': null,
      })!;
      expect(surface.provider, isNull);
      expect(surface.authKind, isNull);
      expect(surface.apiKeyEnv, isNull);
    });

    test(
      'reads auth_kind and the key variable name only on the auth layer',
      () {
        final auth = TurnErrorSurface.parse({
          'layer': 'auth',
          'code': 'auth',
          'auth_kind': 'api_key',
          'api_key_env': 'EXAMPLE_API_KEY',
        })!;
        expect(auth.authKind, ProviderAuthKind.apiKey);
        expect(auth.apiKeyEnv, 'EXAMPLE_API_KEY');
        final other = TurnErrorSurface.parse({
          'layer': 'provider',
          'code': 'rate_limit',
          'auth_kind': 'oauth',
          'api_key_env': 'EXAMPLE_API_KEY',
        })!;
        expect(other.authKind, isNull);
        expect(other.apiKeyEnv, isNull);
      },
    );

    test('free tier codes are recognised by prefix', () {
      expect(surfaceOf('free_tier_outage').isFreeTier, isTrue);
      expect(surfaceOf('rate_limit').isFreeTier, isFalse);
    });

    test('round-trips through its sanitized JSON', () {
      final surface = TurnErrorSurface.parse({
        'layer': 'provider',
        'code': 'rate_limit',
        'retryable': true,
        'provider': 'anthropic',
        'provider_label': 'Anthropic',
        'model': 'claude-example',
        'resets_at': 1790000000.0,
        'message': 'Try later',
        'unexpected': 'dropped',
      })!;
      final json = surface.toJson();
      expect(json.containsKey('unexpected'), isFalse);
      expect(TurnErrorSurface.parse(json)!.toJson(), json);
    });

    test('long identity strings are dropped, not truncated', () {
      final surface = TurnErrorSurface.parse({
        'layer': 'provider',
        'code': 'rate_limit',
        'provider': 'p' * 200,
        'model': 'm' * 200,
      })!;
      expect(surface.provider, isNull);
      expect(surface.model, isNull);
    });
  });

  group('errorRecoveryPlan', () {
    test('no surface keeps the legacy plan: retry only', () {
      final plan = errorRecoveryPlan(surface: null);
      expect(plan.retry, isTrue);
      expect(plan.switchProvider, isFalse);
      expect(plan.compress, isFalse);
      expect(plan.startNewSession, isFalse);
    });

    test('context_overflow compacts or starts over, never retries', () {
      final plan = planOf('context_overflow');
      expect(plan.compress, isTrue);
      expect(plan.startNewSession, isTrue);
      expect(plan.retry, isFalse);
    });

    test('payload_too_large behaves like context_overflow', () {
      final plan = planOf('payload_too_large');
      expect(plan.compress, isTrue);
      expect(plan.startNewSession, isTrue);
      expect(plan.retry, isFalse);
    });

    test('model_not_found picks a model and never retries', () {
      final plan = planOf('model_not_found');
      expect(plan.chooseModel, isTrue);
      expect(plan.retry, isFalse);
    });

    test('content_policy_blocked edits the message and never retries', () {
      final plan = planOf('content_policy_blocked');
      expect(plan.editMessage, isTrue);
      expect(plan.retry, isFalse);
    });

    test('SESSION_NOT_OWNED starts a new session and never retries', () {
      final plan = planOf('SESSION_NOT_OWNED', layer: 'gateway');
      expect(plan.startNewSession, isTrue);
      expect(plan.retry, isFalse);
    });

    test('loop_error starts a new session and keeps the layer retry', () {
      final plan = planOf('loop_error', layer: 'gateway');
      expect(plan.startNewSession, isTrue);
      expect(plan.retry, isTrue);
    });

    test('disk_full opens the Hermes folder and may retry', () {
      final plan = planOf('disk_full', layer: 'disk', retryable: false);
      expect(plan.openHermesFolder, isTrue);
      expect(plan.retry, isTrue);
    });

    test('retry follows retryable when no code plan overrides it', () {
      expect(planOf('server_error').retry, isTrue);
      expect(planOf('server_error', retryable: false).retry, isFalse);
    });

    test('provider, endpoint, auth and billing layers may switch provider', () {
      for (final layer in const ['auth', 'billing', 'endpoint', 'provider']) {
        expect(planOf('x', layer: layer).switchProvider, isTrue, reason: layer);
      }
      for (final layer in const ['streaming', 'gateway', 'runtime', 'disk']) {
        expect(
          planOf('x', layer: layer).switchProvider,
          isFalse,
          reason: layer,
        );
      }
    });

    test('an OAuth credential failure signs in again and retries', () {
      final plan = planOf(
        'auth',
        layer: 'auth',
        retryable: false,
        authFailure: const ProviderAuthFailure(
          provider: 'anthropic',
          label: 'Anthropic',
          kind: ProviderAuthKind.oauth,
        ),
      );
      expect(plan.signInAgain, isTrue);
      expect(plan.updateApiKey, isFalse);
      expect(plan.retry, isTrue);
    });

    test('a rejected API key updates the key and retries', () {
      final plan = planOf(
        'auth',
        layer: 'auth',
        retryable: false,
        authFailure: const ProviderAuthFailure(
          provider: 'openai',
          label: 'OpenAI',
          kind: ProviderAuthKind.apiKey,
        ),
      );
      expect(plan.updateApiKey, isTrue);
      expect(plan.signInAgain, isFalse);
      expect(plan.retry, isTrue);
    });

    test('free tier codes offer the free sign-in', () {
      expect(planOf('free_tier_rate_limited').signInFreeTier, isTrue);
      expect(planOf('rate_limit').signInFreeTier, isFalse);
    });

    test('every other action stays off for a plain provider failure', () {
      final plan = planOf('overloaded');
      expect(plan.chooseModel, isFalse);
      expect(plan.compress, isFalse);
      expect(plan.editMessage, isFalse);
      expect(plan.openHermesFolder, isFalse);
      expect(plan.startNewSession, isFalse);
      expect(plan.signInAgain, isFalse);
      expect(plan.updateApiKey, isFalse);
    });
  });

  group('primary and secondary actions', () {
    List<ErrorRecoveryAction> order(ErrorRecoveryPlan plan) =>
        errorRecoveryActions(plan);

    test('context_overflow: compact first, new chat second, no retry', () {
      // Its layer is `provider`, so switching provider stays last, as in the
      // Desktop table.
      expect(order(planOf('context_overflow')), [
        ErrorRecoveryAction.compress,
        ErrorRecoveryAction.startNewSession,
        ErrorRecoveryAction.switchProvider,
      ]);
    });

    test('model_not_found: choose model, no retry', () {
      expect(order(planOf('model_not_found')), [
        ErrorRecoveryAction.chooseModel,
        ErrorRecoveryAction.switchProvider,
      ]);
    });

    test('content_policy_blocked: edit message first', () {
      expect(
        order(planOf('content_policy_blocked')).first,
        ErrorRecoveryAction.editMessage,
      );
    });

    test('OAuth auth: sign in again first, retry after', () {
      final actions = order(
        planOf(
          'auth',
          layer: 'auth',
          authFailure: const ProviderAuthFailure(
            provider: 'anthropic',
            label: 'Anthropic',
            kind: ProviderAuthKind.oauth,
          ),
        ),
      );
      expect(actions.first, ErrorRecoveryAction.signInAgain);
      expect(actions, contains(ErrorRecoveryAction.retry));
      expect(actions, isNot(contains(ErrorRecoveryAction.updateApiKey)));
    });

    test('API key auth: review the key first', () {
      final actions = order(
        planOf(
          'auth',
          layer: 'auth',
          authFailure: const ProviderAuthFailure(
            provider: 'openai',
            label: 'OpenAI',
            kind: ProviderAuthKind.apiKey,
          ),
        ),
      );
      expect(actions.first, ErrorRecoveryAction.updateApiKey);
    });

    test('priority is sign-in, key, compact, model, edit, retry, new chat, '
        'switch provider', () {
      const everything = ErrorRecoveryPlan(
        retry: true,
        signInAgain: true,
        signInFreeTier: false,
        switchProvider: true,
        updateApiKey: true,
        chooseModel: true,
        compress: true,
        editMessage: true,
        openHermesFolder: false,
        startNewSession: true,
      );
      expect(errorRecoveryActions(everything), [
        ErrorRecoveryAction.signInAgain,
        ErrorRecoveryAction.updateApiKey,
        ErrorRecoveryAction.compress,
        ErrorRecoveryAction.chooseModel,
        ErrorRecoveryAction.editMessage,
        ErrorRecoveryAction.retry,
        ErrorRecoveryAction.startNewSession,
        ErrorRecoveryAction.switchProvider,
      ]);
    });

    test('openHermesFolder is never an action on mobile', () {
      final plan = planOf('disk_full', layer: 'disk', retryable: false);
      expect(plan.openHermesFolder, isTrue);
      expect(errorRecoveryActions(plan), [ErrorRecoveryAction.retry]);
    });
  });

  group('formatLimitReset', () {
    final now = DateTime(2026, 10, 4, 12, 0);

    test('names the local time and the remaining hours and minutes', () {
      final resetsAt = now.add(const Duration(minutes: 65));
      final reset = formatLimitReset(
        resetsAt.millisecondsSinceEpoch / 1000,
        now,
      )!;
      expect(reset.clock, '13:05');
      expect(reset.remaining, '1 h 05 min');
    });

    test('under an hour shows minutes only', () {
      final reset = formatLimitReset(
        now.add(const Duration(minutes: 7)).millisecondsSinceEpoch / 1000,
        now,
      )!;
      expect(reset.remaining, '7 min');
    });

    test('whole hours keep the zero minutes', () {
      final reset = formatLimitReset(
        now.add(const Duration(hours: 2)).millisecondsSinceEpoch / 1000,
        now,
      )!;
      expect(reset.remaining, '2 h 00 min');
    });

    test('rounds a partial minute up so it never reads 0 min', () {
      final reset = formatLimitReset(
        now.add(const Duration(seconds: 20)).millisecondsSinceEpoch / 1000,
        now,
      )!;
      expect(reset.remaining, '1 min');
    });

    test('a reset in the past or now is not shown', () {
      expect(formatLimitReset(now.millisecondsSinceEpoch / 1000, now), isNull);
      expect(
        formatLimitReset(
          now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch /
              1000,
          now,
        ),
        isNull,
      );
      expect(formatLimitReset(null, now), isNull);
    });
  });

  group('scheduledRetryDelay', () {
    final now = DateTime(2026, 10, 4, 12, 0);
    double at(Duration after) => now.add(after).millisecondsSinceEpoch / 1000;

    test('is the time left until the reset', () {
      expect(
        scheduledRetryDelay(at(const Duration(minutes: 65)), now),
        const Duration(minutes: 65),
      );
    });

    test('is not offered for a reset in the past or without a reset', () {
      expect(scheduledRetryDelay(null, now), isNull);
      expect(scheduledRetryDelay(at(const Duration(seconds: -1)), now), isNull);
      expect(
        scheduledRetryDelay(now.millisecondsSinceEpoch / 1000, now),
        isNull,
      );
    });

    test('a delay of exactly 2^31-1 ms is the last one offered', () {
      const maxMs = 2147483647;
      expect(
        scheduledRetryDelay(at(const Duration(milliseconds: maxMs)), now),
        const Duration(milliseconds: maxMs),
      );
      expect(
        scheduledRetryDelay(
          at(const Duration(milliseconds: maxMs + 1000)),
          now,
        ),
        isNull,
      );
    });
  });

  group('formatErrorDiagnostics', () {
    final now = DateTime.utc(2026, 10, 4, 12, 30, 5);

    test('writes the exact block Desktop copies', () {
      final surface = surfaceOf(
        'rate_limit',
        extra: {
          'provider': 'anthropic',
          'model': 'claude-example',
          'resets_at':
              DateTime.utc(2026, 10, 4, 13, 35).millisecondsSinceEpoch / 1000,
          'api_key_env': 'EXAMPLE_API_KEY',
        },
      );
      expect(
        formatErrorDiagnostics(
          now: now,
          surface: surface,
          composerProvider: 'openai',
          composerModel: 'gpt-example',
          appVersion: '1.2.15',
          error: 'Rate limited by the provider',
        ),
        '── Hermes error details ──\n'
        'time: 2026-10-04T12:30:05.000Z\n'
        'layer: provider\n'
        'code: rate_limit\n'
        'retryable: true\n'
        'resets_at: 2026-10-04T13:35:00.000Z\n'
        'provider: anthropic\n'
        'model: claude-example\n'
        'app: 1.2.15\n'
        'error: Rate limited by the provider',
      );
    });

    test('the surface provider wins over the composer provider', () {
      final text = formatErrorDiagnostics(
        now: now,
        surface: surfaceOf('rate_limit', extra: {'provider': 'anthropic'}),
        composerProvider: 'openai',
        composerModel: 'gpt-example',
        appVersion: '1.2.15',
        error: 'x',
      );
      expect(text, contains('provider: anthropic'));
      expect(text, isNot(contains('provider: openai')));
      expect(text, contains('model: gpt-example'));
    });

    test('without a surface it keeps only what is known', () {
      expect(
        formatErrorDiagnostics(
          now: now,
          surface: null,
          composerProvider: 'openai',
          composerModel: 'gpt-example',
          appVersion: '1.2.15',
          error: 'Boom',
        ),
        '── Hermes error details ──\n'
        'time: 2026-10-04T12:30:05.000Z\n'
        'provider: openai\n'
        'model: gpt-example\n'
        'app: 1.2.15\n'
        'error: Boom',
      );
    });

    test('never prints the key variable, a billing URL or the message', () {
      final text = formatErrorDiagnostics(
        now: now,
        surface: TurnErrorSurface.parse({
          'layer': 'auth',
          'code': 'auth',
          'api_key_env': 'EXAMPLE_API_KEY',
          'message': 'Sign in at https://billing.example.test/pay',
        }),
        composerProvider: null,
        composerModel: null,
        appVersion: '1.2.15',
        error: 'Rejected',
      );
      expect(text, isNot(contains('EXAMPLE_API_KEY')));
      expect(text, isNot(contains('billing.example.test')));
    });
  });

  group('TurnBillingBlock.parse', () {
    test('keeps the label, Nous flag, https URL and first message line', () {
      final block = TurnBillingBlock.parse({
        'provider': 'example',
        'provider_label': 'Example AI',
        'model': 'm',
        'billing_url': 'https://billing.example.test/top-up',
        'is_nous': false,
        'message': 'Out of credits.\nAdd funds to keep going.',
      })!;
      expect(block.providerLabel, 'Example AI');
      expect(block.isNous, isFalse);
      expect(block.billingUrl, 'https://billing.example.test/top-up');
      expect(block.firstLine, 'Out of credits.');
    });

    test('only an https URL is kept', () {
      TurnBillingBlock? parse(Object? url) => TurnBillingBlock.parse({
        'provider_label': 'Example AI',
        'billing_url': url,
        'is_nous': false,
        'message': 'Out of credits.',
      });
      expect(parse('http://billing.example.test')!.billingUrl, isNull);
      expect(parse('javascript:alert(1)')!.billingUrl, isNull);
      expect(parse('file:///etc/passwd')!.billingUrl, isNull);
      expect(parse(null)!.billingUrl, isNull);
      expect(parse('https://')!.billingUrl, isNull);
    });

    test('no block, or a block without a provider name, is no block', () {
      expect(TurnBillingBlock.parse(null), isNull);
      expect(TurnBillingBlock.parse('x'), isNull);
      expect(TurnBillingBlock.parse({'message': 'Out'}), isNull);
    });

    test('round-trips through its sanitized JSON', () {
      final block = TurnBillingBlock.parse({
        'provider_label': 'Example AI',
        'billing_url': 'https://billing.example.test/top-up',
        'is_nous': true,
        'message': 'Out of credits.\nMore',
      })!;
      expect(TurnBillingBlock.parse(block.toJson())!.toJson(), block.toJson());
    });
  });

  group('providerWaitText', () {
    test('accepts the notices the core explains', () {
      for (final text in const [
        '⏳ waiting on provider…',
        '⏳ still waiting on provider (45s)',
        '⚠ no output for 30s',
        '⚠ no response from provider',
        '↻ rate limited — retrying in 5s',
        '⚙ loading model',
        '⚙ processing prompt',
        '⚠ model returned an empty response',
        '↻ provider overloaded, retrying',
        '↻ provider temporarily unavailable',
      ]) {
        expect(providerWaitText(text), isNotNull, reason: text);
      }
    });

    test('drops the decorative spinner phrases', () {
      for (final text in const [
        'pondering…',
        '(｡•́︿•̀｡) thinking',
        'Let me think about waiting on you',
        '⏳ computing',
        '',
      ]) {
        expect(providerWaitText(text), isNull, reason: text);
      }
    });

    test('is case insensitive and tolerates leading space after the glyph', () {
      expect(providerWaitText('⏳   WAITING ON provider'), isNotNull);
    });

    test('returns one clean, capped line', () {
      expect(
        providerWaitText('⏳ waiting on provider…\n'),
        '⏳ waiting on provider…',
      );
      expect(providerWaitText('⏳ waiting on ${'x' * 400}')!.length, 160);
    });
  });
}
