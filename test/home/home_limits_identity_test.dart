// «Límites del plan» says whose limits they are: the provider Hermes reports
// for them, its mark, and the plan only when the provider names one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/home/board/home_limits.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/widgets/provider_logo.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/account_usage_fixtures.dart';
import '../support/home_board_fixtures.dart';

AccountUsageLimits _limits({
  List<Object?>? account,
  List<Object?>? credits,
  Map<String, dynamic>? bars,
}) => AccountUsageLimits.fromGateway(
  usage(account: account, credits: credits),
  usageBars: bars,
);

final Finder _who = find.byKey(const ValueKey('home-limit-who'));

String _plain(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((t) => t.text.toPlainText())
    .join(' | ');

void main() {
  late Strings es;
  setUpAll(() async {
    es = await Strings.delegate.load(const Locale('es'));
  });

  group('the model reads whose limits they are', () {
    test('Codex: the provider and the plan Hermes reports', () {
      final who = _limits(account: codexLines).accountIdentity;
      expect(who?.provider, 'openai-codex');
      expect(who?.plan, 'Plus');
    });

    test('Claude without a plan: the provider alone', () {
      final who = _limits(account: claudeLines).accountIdentity;
      expect(who?.provider, 'anthropic');
      expect(who?.plan, isNull);
    });

    test('credits lines name Nous; the bars keep Nous and its plan name', () {
      expect(_limits(credits: nousLines).creditsIdentity?.provider, 'nous');
      final withBars = _limits(credits: nousLines, bars: barsAvailable);
      expect(withBars.creditsIdentity?.provider, 'nous');
      expect(withBars.creditsIdentity?.plan, 'Pro');
    });

    test('no Provider line, no identity', () {
      final none = _limits(
        account: const ['Session: 50% remaining (50% used)'],
      );
      expect(none.accountIdentity, isNull);
    });
  });

  group('Home rows carry it', () {
    List<HomeLimitRow> rows(AccountUsageLimits l) =>
        homeLimitRows(l, es, languageCode: 'es');

    test('provider name as Hermes names it, plan as the provider reports', () {
      final who = rows(_limits(account: codexLines)).first.who!;
      expect(who.name, 'OpenAI Codex');
      expect(who.plan, 'Plus');
      expect(who.provider, 'openai-codex');
      final claude = rows(_limits(account: claudeLines)).first.who!;
      expect(claude.name, 'Anthropic');
      expect(claude.plan, isNull);
    });

    test('an unknown provider is written out; a plan carrying an id or a '
        'URL is dropped, never replaced by a guess', () {
      final other = rows(
        _limits(
          account: const [
            'Provider: some-new_provider',
            'Session: 50% remaining (50% used)',
          ],
        ),
      ).first.who!;
      expect(other.name, 'Some New Provider');
      final leaky = rows(_limits(account: leakyLines)).first.who!;
      expect(leaky.name, 'Anthropic');
      expect(leaky.plan, isNull);
    });

    test('the account in use comes first, the credits after it', () {
      final all = rows(
        _limits(account: codexLines, credits: nousLines, bars: barsAvailable),
      );
      final groups = homeLimitGroups(all);
      expect(groups.map((g) => g.who?.name), ['OpenAI Codex', 'Nous']);
      expect(groups.last.who?.plan, 'Pro');
      expect(groups.first.rows.map((r) => r.window).toSet(), {
        HomeLimitWindow.line,
      });
      expect(groups.last.rows.map((r) => r.window), [
        HomeLimitWindow.planBar,
        HomeLimitWindow.topupBar,
      ]);
    });
  });

  test('the launcher widgets get the same identity: ids, names, plan', () {
    final groups = homeWidgetLimits(
      _limits(account: codexLines, credits: nousLines),
      es,
      languageCode: 'es',
    );
    expect(groups.map((g) => g.provider), ['openai-codex', 'nous']);
    expect(groups.map((g) => g.providerName), ['OpenAI Codex', 'Nous']);
    expect(groups.map((g) => g.plan), ['Plus', 'Pro']);
    expect(groups.map((g) => g.inUse), [true, false]);
    expect(groups.first.windows.first.label, 'Sesión actual');
    expect(groups.first.windows.first.usedPercent, 28);
    final noPlan = homeWidgetLimits(
      _limits(account: claudeLines),
      es,
      languageCode: 'es',
    );
    expect(noPlan.single.plan, isNull);
  });

  group('the tile shows it at every size', () {
    final codex = homeData(limits: _limits(account: codexLines));
    final claude = homeData(limits: _limits(account: claudeLines));
    final both = homeData(
      limits: _limits(account: codexLines, credits: nousLines),
    );

    for (final size in HomeWidgetSize.values) {
      testWidgets('${size.name}: provider, plan and its mark', (tester) async {
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.planLimits,
          size: size,
          data: codex,
        );
        expect(_who, findsOneWidget);
        expect(_plain(tester), contains('OpenAI Codex · Plus'));
        expect(find.byType(ProviderLogo), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('${size.name}: no plan reported, only the provider', (
        tester,
      ) async {
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.planLimits,
          size: size,
          data: claude,
        );
        expect(_who, findsOneWidget);
        final text = _plain(tester);
        expect(text, contains('Anthropic'));
        expect(text, isNot(contains('Anthropic ·')));
      });

      testWidgets('${size.name}: still named at twice the text size', (
        tester,
      ) async {
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.planLimits,
          size: size,
          data: codex,
          textScale: 2,
        );
        expect(_who, findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('small: the window under the name, the reset in the wider '
        'sizes', (tester) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.planLimits,
        size: HomeWidgetSize.small,
        data: codex,
      );
      expect(find.text('Semana'), findsOneWidget);
      expect(_plain(tester), isNot(contains('reinicia')));
    });

    testWidgets('large lists every account that reports limits, the one in '
        'use first', (tester) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.planLimits,
        size: HomeWidgetSize.large,
        data: both,
      );
      expect(_who, findsNWidgets(2));
      final text = _plain(tester);
      expect(text.indexOf('OpenAI Codex'), lessThan(text.indexOf('Nous')));
    });

    testWidgets('wide never leaves a limit unattributed', (tester) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.planLimits,
        size: HomeWidgetSize.wide,
        data: both,
      );
      expect(_who, findsAtLeastNWidgets(1));
      expect(
        tester.getTopLeft(_who.first).dy,
        lessThan(tester.getTopLeft(find.text('Sesión actual')).dy),
      );
    });
  });
}
