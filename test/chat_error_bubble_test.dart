// The error card of a failed turn follows the gateway's `error_surface`: one
// visible action, the rest behind "ver detalles", a usage-limit reset with an
// optional single armed retry, and "Copiar detalles".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/provider_auth_failure.dart';
import 'package:hermes_android/core/models/turn_error_surface.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _retry = '↺ reintentar';

TurnErrorSurface _surface(
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

Widget _host(Widget child, {Locale locale = const Locale('es')}) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: locale,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Future<void> _openDetails(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('te1215-error-details-toggle')));
  await tester.pump();
}

Finder _action(String name) =>
    find.byKey(ValueKey('te1215-error-action-$name'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('one visible action, the rest behind the details', () {
    testWidgets('context_overflow compacts first and never retries', (
      tester,
    ) async {
      var compressed = 0;
      var newChats = 0;
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'context too long',
            prompt: 'hola',
            onRetry: () {},
            onCompress: () => compressed++,
            onNewSession: () => newChats++,
            onChooseModel: () {},
            surface: _surface('context_overflow'),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('te1215-error-primary')),
        findsOneWidget,
      );
      expect(find.text('Compactar conversación'), findsOneWidget);
      expect(find.text('Chat nuevo'), findsNothing);
      expect(find.text(_retry), findsNothing);

      await _openDetails(tester);
      expect(find.text('Chat nuevo'), findsOneWidget);
      expect(find.text(_retry), findsNothing);
      expect(
        find.byKey(const ValueKey('te1215-error-primary')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('te1215-error-primary')));
      expect(compressed, 1);
      await tester.tap(find.text('Chat nuevo'));
      expect(newChats, 1);
    });

    testWidgets('model_not_found opens the model picker and never retries', (
      tester,
    ) async {
      var picked = 0;
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'no such model',
            prompt: 'hola',
            onRetry: () {},
            onChooseModel: () => picked++,
            surface: _surface('model_not_found'),
          ),
        ),
      );

      await tester.tap(find.text('Elegir modelo'));
      expect(picked, 1);
      await _openDetails(tester);
      expect(find.text(_retry), findsNothing);
      // The same picker is not offered twice.
      expect(find.text('Cambiar de proveedor'), findsNothing);
    });

    testWidgets('content_policy_blocked edits the previous message', (
      tester,
    ) async {
      var edited = 0;
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'blocked',
            prompt: 'hola',
            onRetry: () {},
            onEditMessage: () => edited++,
            surface: _surface('content_policy_blocked'),
          ),
        ),
      );

      await tester.tap(find.text('Editar mensaje'));
      expect(edited, 1);
      await _openDetails(tester);
      expect(find.text(_retry), findsNothing);
    });

    testWidgets(
      'an OAuth credential failure signs in again, retry in details',
      (tester) async {
        var signedIn = 0;
        var retried = 0;
        await tester.pumpWidget(
          _host(
            ChatErrorBubble(
              error: 'token revoked',
              prompt: 'hola',
              onRetry: () => retried++,
              surface: _surface(
                'auth',
                layer: 'auth',
                retryable: false,
                extra: {
                  'provider': 'anthropic',
                  'provider_label': 'Anthropic',
                  'auth_kind': 'oauth',
                },
              ),
              authFailure: const ProviderAuthFailure(
                provider: 'anthropic',
                label: 'Anthropic',
                kind: ProviderAuthKind.oauth,
              ),
              onReauth: () => signedIn++,
            ),
          ),
        );

        expect(find.text('Volver a iniciar sesión'), findsOneWidget);
        expect(find.text(_retry), findsNothing);
        await tester.tap(find.byKey(const ValueKey('te1215-error-primary')));
        expect(signedIn, 1);

        await _openDetails(tester);
        await tester.tap(find.text(_retry));
        expect(retried, 1);
      },
    );

    testWidgets('a rejected API key asks to check the key', (tester) async {
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'invalid x-api-key',
            prompt: 'hola',
            onRetry: () {},
            surface: _surface(
              'auth',
              layer: 'auth',
              retryable: false,
              extra: {'provider': 'openai', 'auth_kind': 'api_key'},
            ),
            authFailure: const ProviderAuthFailure(
              provider: 'openai',
              label: 'OpenAI',
              kind: ProviderAuthKind.apiKey,
            ),
            onReauth: () {},
          ),
        ),
      );

      expect(find.text('Revisar la clave'), findsOneWidget);
    });

    testWidgets('openHermesFolder is never painted on a phone', (tester) async {
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'No space left on device',
            prompt: 'hola',
            onRetry: () {},
            surface: _surface('disk_full', layer: 'disk', retryable: false),
          ),
        ),
      );

      expect(find.text('Disco del servidor lleno'), findsOneWidget);
      await _openDetails(tester);
      expect(find.textContaining('carpeta'), findsNothing);
      expect(find.textContaining('folder'), findsNothing);
    });

    testWidgets('an action without a handler is not painted', (tester) async {
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'context too long',
            prompt: 'hola',
            onRetry: null,
            surface: _surface('context_overflow'),
          ),
        ),
      );

      // No compress handler and no retry: nothing dead is shown.
      expect(find.byKey(const ValueKey('te1215-error-primary')), findsNothing);
    });

    testWidgets('titles come from the code, then the layer', (tester) async {
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'x',
            prompt: 'hola',
            onRetry: () {},
            surface: _surface('some_new_code', layer: 'gateway'),
          ),
        ),
      );
      expect(find.text('Error del gateway de Hermes'), findsOneWidget);

      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'x',
            prompt: 'hola',
            onRetry: () {},
            surface: _surface('overloaded'),
          ),
        ),
      );
      expect(find.text('Proveedor saturado'), findsOneWidget);
    });

    testWidgets('English copy follows the same plan', (tester) async {
      await tester.pumpWidget(
        _host(
          locale: const Locale('en'),
          ChatErrorBubble(
            error: 'context too long',
            prompt: 'hi',
            onRetry: () {},
            onCompress: () {},
            surface: _surface('context_overflow'),
          ),
        ),
      );
      expect(find.text('Compact conversation'), findsOneWidget);
      expect(find.text('Conversation too long'), findsOneWidget);
    });
  });

  group('without an error_surface the card is the one older servers get', () {
    testWidgets('keeps retry visible and the details toggle', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'No se pudo completar la respuesta. Inténtalo de nuevo.',
            prompt: 'hola',
            onRetry: () => retried++,
            onNewSession: () {},
          ),
        ),
      );

      expect(find.text(_retry), findsOneWidget);
      expect(find.byKey(const ValueKey('te1215-error-primary')), findsNothing);
      await tester.tap(find.text(_retry));
      expect(retried, 1);
    });

    testWidgets('a text-only auth failure still shows both actions', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'invalid x-api-key',
            prompt: 'hola',
            onRetry: () {},
            authFailure: const ProviderAuthFailure(
              provider: 'openai',
              label: 'OpenAI',
              kind: ProviderAuthKind.apiKey,
            ),
            onReauth: () {},
          ),
        ),
      );

      expect(find.byKey(const ValueKey('hr1215-error-reauth')), findsOneWidget);
      expect(find.text(_retry), findsOneWidget);
    });
  });

  group('usage limit', () {
    final start = DateTime(2026, 10, 4, 12, 0);
    late double resetsIn65;

    setUp(() {
      resetsIn65 =
          start.add(const Duration(minutes: 65)).millisecondsSinceEpoch / 1000;
    });

    Widget bubble({
      required DateTime Function() now,
      required VoidCallback onRetry,
      bool canArm = true,
      Object? scope = 'chat-1',
      double? resetsAt,
    }) => _host(
      ChatErrorBubble(
        error: 'rate limited',
        prompt: 'hola',
        onRetry: onRetry,
        canArmRetry: canArm,
        retryScope: scope,
        now: now,
        surface: _surface(
          'rate_limit',
          extra: {'resets_at': resetsAt ?? resetsIn65},
        ),
      ),
    );

    testWidgets('names the reset time and the time left', (tester) async {
      await tester.pumpWidget(bubble(now: () => start, onRetry: () {}));

      expect(
        find.text('Se restablece a las 13:05 (en 1 h 05 min)'),
        findsOneWidget,
      );
      expect(find.text('Reintentar a las 13:05'), findsNothing);
      await _openDetails(tester);
      expect(find.text('Reintentar a las 13:05'), findsOneWidget);
    });

    testWidgets('an armed retry fires exactly once when the time comes', (
      tester,
    ) async {
      var clock = start;
      var retried = 0;
      await tester.pumpWidget(
        bubble(now: () => clock, onRetry: () => retried++),
      );
      await _openDetails(tester);
      await tester.tap(find.text('Reintentar a las 13:05'));
      await tester.pump();

      expect(find.byKey(const ValueKey('te1215-error-armed')), findsOneWidget);
      expect(find.textContaining('en 1 h 05 min'), findsWidgets);

      clock = start.add(const Duration(minutes: 30));
      await tester.pump(const Duration(minutes: 30));
      expect(retried, 0);
      expect(find.textContaining('en 35 min'), findsWidgets);

      clock = start.add(const Duration(minutes: 65));
      await tester.pump(const Duration(minutes: 35));
      expect(retried, 1);

      await tester.pump(const Duration(hours: 3));
      expect(retried, 1);
      expect(find.byKey(const ValueKey('te1215-error-armed')), findsNothing);
    });

    testWidgets('cancel disarms it', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        bubble(now: () => start, onRetry: () => retried++),
      );
      await _openDetails(tester);
      await tester.tap(find.text('Reintentar a las 13:05'));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('te1215-error-cancel-arm')));
      await tester.pump();
      await tester.pump(const Duration(hours: 2));

      expect(retried, 0);
      expect(find.byKey(const ValueKey('te1215-error-armed')), findsNothing);
    });

    testWidgets('leaving the chat disarms it without touching a dead state', (
      tester,
    ) async {
      var retried = 0;
      await tester.pumpWidget(
        bubble(now: () => start, onRetry: () => retried++),
      );
      await _openDetails(tester);
      await tester.tap(find.text('Reintentar a las 13:05'));
      await tester.pump();

      await tester.pumpWidget(_host(const SizedBox()));
      await tester.pump(const Duration(hours: 2));

      expect(retried, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('another turn starting disarms it', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        bubble(now: () => start, onRetry: () => retried++),
      );
      await _openDetails(tester);
      await tester.tap(find.text('Reintentar a las 13:05'));
      await tester.pump();

      await tester.pumpWidget(
        bubble(now: () => start, onRetry: () => retried++, canArm: false),
      );
      await tester.pump(const Duration(hours: 2));

      expect(retried, 0);
      expect(find.byKey(const ValueKey('te1215-error-armed')), findsNothing);
    });

    testWidgets('a profile or chat change disarms it', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        bubble(now: () => start, onRetry: () => retried++),
      );
      await _openDetails(tester);
      await tester.tap(find.text('Reintentar a las 13:05'));
      await tester.pump();

      await tester.pumpWidget(
        bubble(now: () => start, onRetry: () => retried++, scope: 'chat-2'),
      );
      await tester.pump(const Duration(hours: 2));

      expect(retried, 0);
    });

    testWidgets('the app going to the background disarms it', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        bubble(now: () => start, onRetry: () => retried++),
      );
      await _openDetails(tester);
      await tester.tap(find.text('Reintentar a las 13:05'));
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(hours: 2));

      expect(retried, 0);
    });

    testWidgets('arming twice still fires once', (tester) async {
      var clock = start;
      var retried = 0;
      await tester.pumpWidget(
        bubble(now: () => clock, onRetry: () => retried++),
      );
      await _openDetails(tester);
      await tester.tap(find.text('Reintentar a las 13:05'));
      await tester.pump();
      // The arm entry is replaced by the armed row; nothing to tap twice.
      expect(find.text('Reintentar a las 13:05'), findsNothing);

      clock = start.add(const Duration(minutes: 65));
      await tester.pump(const Duration(minutes: 65));
      expect(retried, 1);
    });

    testWidgets('a reset in the past offers no schedule', (tester) async {
      await tester.pumpWidget(
        bubble(
          now: () => start,
          onRetry: () {},
          resetsAt:
              start
                  .subtract(const Duration(minutes: 1))
                  .millisecondsSinceEpoch /
              1000,
        ),
      );
      expect(find.textContaining('Se restablece'), findsNothing);
      await _openDetails(tester);
      expect(find.textContaining('Reintentar a las'), findsNothing);
    });

    testWidgets('a reset too far away is shown but cannot be armed', (
      tester,
    ) async {
      await tester.pumpWidget(
        bubble(
          now: () => start,
          onRetry: () {},
          resetsAt:
              start.add(const Duration(days: 40)).millisecondsSinceEpoch / 1000,
        ),
      );
      expect(find.textContaining('Se restablece a las'), findsOneWidget);
      await _openDetails(tester);
      expect(find.textContaining('Reintentar a las'), findsNothing);
    });

    testWidgets('no arming while the failed turn is not the last', (
      tester,
    ) async {
      await tester.pumpWidget(
        bubble(now: () => start, onRetry: () {}, canArm: false),
      );
      await _openDetails(tester);
      expect(find.textContaining('Reintentar a las'), findsNothing);
    });

    testWidgets('no arming when the plan has no retry', (tester) async {
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'x',
            prompt: 'hola',
            onRetry: () {},
            canArmRetry: true,
            now: () => start,
            surface: _surface(
              'context_overflow',
              extra: {'resets_at': resetsIn65},
            ),
          ),
        ),
      );
      await _openDetails(tester);
      expect(find.textContaining('Reintentar a las'), findsNothing);
    });
  });

  group('free tier', () {
    testWidgets('the body is the gateway message', (tester) async {
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'rate limited',
            prompt: 'hola',
            onRetry: () {},
            surface: _surface(
              'free_tier_rate_limited',
              extra: {'message': 'The free plan is busy, try in a minute.'},
            ),
          ),
        ),
      );
      expect(
        find.text('The free plan is busy, try in a minute.'),
        findsOneWidget,
      );
    });

    testWidgets('no sign-in button when nous cannot be opened', (tester) async {
      var checks = 0;
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'rate limited',
            prompt: 'hola',
            onRetry: () {},
            onSignInFreeTier: () {},
            freeTierSignInAvailable: () async {
              checks++;
              return false;
            },
            surface: _surface(
              'free_tier_rate_limited',
              extra: {'message': 'Busy'},
            ),
          ),
        ),
      );
      expect(
        checks,
        0,
        reason: 'nothing is asked until the user opens details',
      );
      await _openDetails(tester);
      await tester.pump();
      expect(checks, 1);
      expect(find.text('Iniciar sesión gratis'), findsNothing);
      await _openDetails(tester);
      await _openDetails(tester);
      expect(checks, 1, reason: 'asked once per card');
    });

    testWidgets('the sign-in button appears when nous is offered', (
      tester,
    ) async {
      var signedIn = 0;
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'rate limited',
            prompt: 'hola',
            onRetry: () {},
            onSignInFreeTier: () => signedIn++,
            freeTierSignInAvailable: () async => true,
            surface: _surface(
              'free_tier_rate_limited',
              extra: {'message': 'Busy'},
            ),
          ),
        ),
      );
      await _openDetails(tester);
      await tester.pump();
      await tester.tap(find.text('Iniciar sesión gratis'));
      expect(signedIn, 1);
    });

    testWidgets('a non-free code never asks', (tester) async {
      var checks = 0;
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'x',
            prompt: 'hola',
            onRetry: () {},
            onSignInFreeTier: () {},
            freeTierSignInAvailable: () async {
              checks++;
              return true;
            },
            surface: _surface('rate_limit'),
          ),
        ),
      );
      await _openDetails(tester);
      await tester.pump();
      expect(checks, 0);
    });
  });

  group('billing', () {
    TurnBillingBlock block({bool nous = false, String? url}) =>
        TurnBillingBlock.parse({
          'provider_label': 'Example AI',
          'billing_url': url,
          'is_nous': nous,
          'message': 'Out of credits.\nAdd funds to continue.',
        })!;

    testWidgets('names the provider and the first line, action opens billing', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'billing',
            prompt: 'hola',
            onRetry: () {},
            onOpenBilling: () => opened++,
            billing: block(url: 'https://billing.example.test/top-up'),
            surface: _surface('billing', layer: 'billing', retryable: false),
          ),
        ),
      );

      expect(find.text('Sin saldo en Example AI'), findsOneWidget);
      expect(find.text('Out of credits.'), findsOneWidget);
      expect(find.textContaining('Add funds'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('te1215-error-primary')));
      expect(opened, 1);
    });

    testWidgets('Nous opens the account screen instead', (tester) async {
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'billing',
            prompt: 'hola',
            onRetry: () {},
            onOpenBilling: () {},
            billing: block(nous: true),
            surface: _surface('billing', layer: 'billing', retryable: false),
          ),
        ),
      );
      expect(find.text('Revisar cuenta'), findsOneWidget);
    });

    testWidgets('a block without handler leaves the plan to decide', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'billing',
            prompt: 'hola',
            onRetry: () {},
            onChooseModel: () {},
            billing: block(),
            surface: _surface('billing', layer: 'billing', retryable: false),
          ),
        ),
      );
      expect(find.text('Sin saldo en Example AI'), findsOneWidget);
      expect(find.text('Cambiar de proveedor'), findsOneWidget);
    });
  });

  group('copy details', () {
    final now = DateTime.utc(2026, 10, 4, 12, 30, 5);
    final copied = <String>[];

    setUp(() {
      copied.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('copies the exact block, without secrets', (tester) async {
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'Rate limited by the provider',
            prompt: 'hola',
            onRetry: () {},
            now: () => now,
            composerProvider: 'openai',
            composerModel: 'gpt-example',
            appVersion: () async => '1.2.15+1215',
            surface: _surface(
              'rate_limit',
              extra: {
                'provider': 'anthropic',
                'model': 'claude-example',
                'resets_at':
                    DateTime.utc(2026, 10, 4, 13, 35).millisecondsSinceEpoch /
                    1000,
              },
            ),
            billing: TurnBillingBlock.parse({
              'provider_label': 'Example AI',
              'billing_url': 'https://billing.example.test/top-up',
              'message': 'Out',
            }),
          ),
        ),
      );
      await _openDetails(tester);
      await tester.tap(find.byKey(const ValueKey('te1215-error-copy')));
      await tester.pump();
      await tester.pump();

      expect(copied, [
        '── Hermes error details ──\n'
            'time: 2026-10-04T12:30:05.000Z\n'
            'layer: provider\n'
            'code: rate_limit\n'
            'retryable: true\n'
            'resets_at: 2026-10-04T13:35:00.000Z\n'
            'provider: anthropic\n'
            'model: claude-example\n'
            'app: 1.2.15+1215\n'
            'error: Rate limited by the provider',
      ]);
      expect(copied.single, isNot(contains('billing.example.test')));
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('copies even when the plan offers no action', (tester) async {
      await tester.pumpWidget(
        _host(
          ChatErrorBubble(
            error: 'Boom',
            prompt: 'hola',
            onRetry: null,
            now: () => now,
            composerProvider: 'openai',
            composerModel: 'gpt-example',
            appVersion: () async => '1.2.15+1215',
            surface: _surface('server_error'),
          ),
        ),
      );
      await _openDetails(tester);
      await tester.tap(find.byKey(const ValueKey('te1215-error-copy')));
      await tester.pump();
      await tester.pump();
      expect(copied.single, contains('code: server_error'));
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
