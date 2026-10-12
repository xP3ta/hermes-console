import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/account_limits_section.dart';
import 'package:hermes_android/core/widgets/session_model_sheet.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/account_usage_fixtures.dart' as fx;

const _provider = ModelProvider(
  slug: 'openai-codex',
  name: 'OpenAI Codex',
  isCurrent: true,
  authenticated: true,
  authType: '',
  oauthProviderId: '',
  keyEnv: '',
  warning: '',
  models: ['gpt-6'],
);

Widget _app(Widget child, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Widget _sheet(ValueListenable<AccountUsageLimits?>? limits) =>
    SessionModelSheetBody(
      providers: const [_provider],
      isSelected: (_, _) => true,
      isSelectedProvider: (_) => true,
      cardInfo: (_, _) => const SessionModelCardInfo(),
      modelLabel: (id) => id,
      onPick: null,
      reasoning: DesktopReasoningEffort.medium,
      reasoningSupported: false,
      onReasoning: null,
      fastMode: DesktopFastMode.normal,
      fastSupported: false,
      onFastMode: null,
      accountLimits: limits,
    );

Finder _bars() => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('account-limit-bar-'),
);

/// Every Text and RichText string rendered under [root].
List<String> _texts(WidgetTester tester) => [
  for (final w in tester.widgetList<Text>(find.byType(Text)))
    w.data ?? w.textSpan?.toPlainText() ?? '',
  for (final w in tester.widgetList<RichText>(find.byType(RichText)))
    w.text.toPlainText(),
];

void main() {
  // QA 9494 P2 (privacy): the section showed the server's English lines as
  // is, with a top-up URL carrying the organization id. Only localized
  // labels from the structured data render; free text loses URLs and ids.
  group('QA 9494: no raw provider lines, URLs or ids', () {
    const orgId = 'org_9f8e7d6c5b4a3921';
    const uuid = '9f8e7d6c-1234-4abc-9def-0123456789ab';
    final codexDepleted = [
      ...fx.codexLines,
      r'Credits balance: $0.00',
      'Status: access depleted — top up to restore',
      'Top up: https://portal.example/billing?org=$orgId',
      'Unavailable: billing for $orgId is paused, see https://x.example/o/$uuid',
    ];

    for (final locale in const [Locale('es'), Locale('en')]) {
      testWidgets('${locale.languageCode}: localized rows, nothing raw', (
        tester,
      ) async {
        final limits = AccountUsageLimits.fromGateway(
          fx.usage(account: codexDepleted, credits: fx.nousLines),
        );
        await tester.pumpWidget(
          _app(AccountLimitsSection(limits: limits), locale: locale),
        );
        // Open the collapsed provider details too: they must be clean.
        final details = find.byKey(const ValueKey('plan-limits-details'));
        if (details.evaluate().isNotEmpty) {
          await tester.tap(details);
          await tester.pumpAndSettle();
        }
        final all = _texts(tester).join('\n');
        for (final raw in [
          'http',
          'portal.example',
          orgId,
          uuid,
          'Account limits',
          'Nous credits',
          'Provider:',
          'remaining',
          'resets in',
          'Status:',
          '/topup',
        ]) {
          expect(all, isNot(contains(raw)), reason: raw);
        }
        final es = locale.languageCode == 'es';
        expect(
          find.text(es ? 'Sesión actual' : 'Current session'),
          findsOneWidget,
        );
        expect(find.text(es ? 'Semana' : 'Week'), findsOneWidget);
        expect(find.text(es ? 'Quedan 72 %' : '72% left'), findsOneWidget);
        expect(
          find.text(es ? 'Se reinicia en 2 h 13 min' : 'Resets in 2h 13m'),
          findsOneWidget,
        );
        expect(
          find.text(es ? 'Se reinicia en 3 d 4 h' : 'Resets in 3d 4h'),
          findsOneWidget,
        );
        expect(find.text(es ? 'Créditos' : 'Credits'), findsWidgets);
        expect(
          find.text(
            es
                ? 'Sin saldo: recarga para seguir'
                : 'Out of credit: top up to continue',
          ),
          findsOneWidget,
        );
        expect(_bars(), findsNWidgets(3));
      });
    }
  });

  for (final locale in const [Locale('es'), Locale('en')]) {
    testWidgets(
      '${locale.languageCode}: renewal and structured fields have no privacy bypass',
      (tester) async {
        const id = 'acct-77aa88bb99cc';
        final limits = AccountUsageLimits.fromGateway(
          fx.usage(
            account: [
              'Renews: $id',
              'Renews: tomorrow',
              'Renews: 2026-02-30',
              'Renews: 2026-11-01',
              'Session: 72% remaining (28% used) • resets in 2h ($id)',
              r'Credits balance: $1.00 acct-77aa88bb99cc',
              'Status: access depleted $id',
              'You have 1 reset banked $id',
              'Plan note: $id maintenance window',
            ],
          ),
          usageBars: {
            ...fx.barsAvailable,
            'plan_name': 'Pro $id',
            'renews_display': id,
            'plan_bar': {
              ...(fx.barsAvailable['plan_bar'] as Map<String, dynamic>),
              'remaining_display': id,
            },
          },
        );
        await tester.pumpWidget(
          _app(AccountLimitsSection(limits: limits), locale: locale),
        );
        await tester.tap(find.byKey(const ValueKey('plan-limits-details')));
        await tester.pumpAndSettle();
        final text = _texts(tester).join('\n');
        for (final rejected in [
          id,
          'tomorrow',
          '2026-02-30',
          'resets in',
          'Renews:',
        ]) {
          expect(text, isNot(contains(rejected)), reason: rejected);
        }
        expect(find.text('2026-11-01'), findsOneWidget);
        expect(find.text('maintenance window'), findsOneWidget);
        expect(
          find.text(locale.languageCode == 'es' ? 'Se renueva' : 'Renews'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('account-usage-bar-plan')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('account-usage-bar-topup')),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('Codex lines: title, one row per line, bars only when parsed', (
    tester,
  ) async {
    final limits = AccountUsageLimits.fromGateway(
      fx.usage(account: fx.codexLines),
    );
    await tester.pumpWidget(_app(AccountLimitsSection(limits: limits)));
    expect(find.text('Límites de tu plan'), findsOneWidget);
    // Localized rows from the structured lines, never the raw English.
    expect(find.text('Account limits'), findsNothing);
    expect(find.text('Provider: openai-codex (Plus)'), findsNothing);
    expect(find.text('Cuenta'), findsOneWidget);
    expect(find.text('Sesión actual'), findsOneWidget);
    expect(find.text('Quedan 72 %'), findsOneWidget);
    expect(find.text('Se reinicia en 2 h 13 min'), findsOneWidget);
    expect(find.text('Tienes 1 reinicio guardado'), findsOneWidget);
    expect(_bars(), findsNWidgets(2));
    final weekly = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('account-limit-bar-2')),
    );
    expect(weekly.value, closeTo(0.91, 1e-9));
    final colors = AppTheme.fromId('dark').hermes;
    expect(weekly.color, colors.warning);
    final session = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('account-limit-bar-1')),
    );
    expect(session.color, colors.accent);
  });

  testWidgets('ambiguous lines are text only', (tester) async {
    final limits = AccountUsageLimits.fromGateway(
      fx.usage(account: ['Rate: 95%', 'Opus week: unavailable']),
    );
    await tester.pumpWidget(_app(AccountLimitsSection(limits: limits)));
    // An unknown free line is not shown; a known window that is
    // unavailable says so in Spanish.
    expect(find.textContaining('Rate'), findsNothing);
    expect(find.text('Semana · Opus'), findsOneWidget);
    expect(find.text('No disponible'), findsOneWidget);
    expect(_bars(), findsNothing);
  });

  testWidgets('usage.bars: structured bars with remaining of total', (
    tester,
  ) async {
    final limits = AccountUsageLimits.fromGateway(
      fx.usage(credits: fx.nousLines),
      usageBars: fx.barsAvailable,
    );
    await tester.pumpWidget(_app(AccountLimitsSection(limits: limits)));
    expect(find.text('Pro'), findsOneWidget);
    expect(find.text(r'$3.00 de $20.00 disponibles'), findsOneWidget);
    expect(find.text(r'$5.00 de $10.00 disponibles'), findsOneWidget);
    expect(find.text('Recargas'), findsOneWidget);
    expect(find.text('Se renueva: Nov 1, 2026'), findsOneWidget);
    expect(find.text('Provider: nous (Pro)'), findsNothing);
    final plan = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('account-usage-bar-plan')),
    );
    expect(plan.value, closeTo(0.85, 1e-9));
  });

  testWidgets('English copy', (tester) async {
    final limits = AccountUsageLimits.fromGateway(
      fx.usage(),
      usageBars: fx.barsAvailable,
    );
    await tester.pumpWidget(
      _app(AccountLimitsSection(limits: limits), locale: const Locale('en')),
    );
    expect(find.text('Your plan limits'), findsOneWidget);
    expect(find.text(r'$3.00 of $20.00 left'), findsOneWidget);
    expect(find.text('Top-up credits'), findsOneWidget);
    expect(find.text('Renews: Nov 1, 2026'), findsOneWidget);
  });

  testWidgets('empty limits paint nothing (no placeholder)', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountLimitsSection(
          limits: AccountUsageLimits.fromGateway(fx.usage()),
        ),
      ),
    );
    expect(find.text('Límites de tu plan'), findsNothing);
    expect(find.byKey(const ValueKey('account-limits-section')), findsNothing);
  });

  testWidgets('model sheet follows the live notifier', (tester) async {
    final notifier = ValueNotifier<AccountUsageLimits?>(null);
    addTearDown(notifier.dispose);
    await tester.pumpWidget(_app(_sheet(notifier)));
    expect(find.text('Límites de tu plan'), findsNothing);
    notifier.value = AccountUsageLimits.fromGateway(
      fx.usage(account: fx.claudeLines),
    );
    await tester.pump();
    expect(find.text('Límites de tu plan'), findsOneWidget);
    expect(find.text('Uso extra'), findsOneWidget);
    expect(find.text('4.20 de 50.00 USD'), findsOneWidget);
    expect(_bars(), findsNWidgets(3));
    notifier.value = AccountUsageLimits.fromGateway(fx.usage());
    await tester.pump();
    expect(find.text('Límites de tu plan'), findsNothing);
  });

  testWidgets('model sheet without a notifier shows no section', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_sheet(null)));
    expect(find.byType(AccountLimitsSection), findsNothing);
  });
}
