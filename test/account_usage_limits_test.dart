import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart'
    show SubscriptionLimitLevel;

import 'support/account_usage_fixtures.dart';

void main() {
  group('parseUsedPercent: only unambiguous lines get a number', () {
    test('Hermes window line: remaining + used agree', () {
      expect(
        AccountUsageLimits.parseUsedPercent(
          'Session: 72% remaining (28% used) • resets in 2h 13m',
        ),
        28,
      );
      expect(
        AccountUsageLimits.parseUsedPercent('Weekly: 0% remaining (100% used)'),
        100,
      );
    });

    test('remaining and used that do not add up are ambiguous', () {
      expect(
        AccountUsageLimits.parseUsedPercent(
          'Session: 70% remaining (40% used)',
        ),
        isNull,
      );
    });

    test('a bare percentage without "used" is ambiguous', () {
      expect(AccountUsageLimits.parseUsedPercent('Rate: 50%'), isNull);
      expect(
        AccountUsageLimits.parseUsedPercent('Session: 72% remaining'),
        isNull,
      );
    });

    test('two "used" percentages are ambiguous', () {
      expect(
        AccountUsageLimits.parseUsedPercent('A: 10% used, B: 20% used'),
        isNull,
      );
    });

    test('an extra unrelated percentage makes it ambiguous', () {
      expect(
        AccountUsageLimits.parseUsedPercent(
          'Session: 72% remaining (28% used) • 5% discount',
        ),
        isNull,
      );
    });

    test('X / Y on a usage line', () {
      expect(
        AccountUsageLimits.parseUsedPercent('Extra usage: 4.20 / 50.00 USD'),
        closeTo(8.4, 1e-9),
      );
      expect(AccountUsageLimits.parseUsedPercent('Requests used: 45/50'), 90);
    });

    test('X / Y without a usage word, with a zero total, or twice: none', () {
      expect(AccountUsageLimits.parseUsedPercent('Renews: 10/06'), isNull);
      expect(AccountUsageLimits.parseUsedPercent('Usage: 3 / 0'), isNull);
      expect(
        AccountUsageLimits.parseUsedPercent('Usage: 1/2 today, 3/4 week'),
        isNull,
      );
      expect(
        AccountUsageLimits.parseUsedPercent('Usage since 2026/10/06'),
        isNull,
      );
    });

    test('unavailable and plain detail lines', () {
      expect(
        AccountUsageLimits.parseUsedPercent('Session: unavailable'),
        isNull,
      );
      expect(
        AccountUsageLimits.parseUsedPercent(r'Subscription credits: $12.00'),
        isNull,
      );
    });
  });

  group('fromGateway', () {
    test('Codex lines: one row each, heading, bars only on windows', () {
      final limits = AccountUsageLimits.fromGateway(usage(account: codexLines));
      expect(
        limits.lines.map((l) => l.text),
        codexLines.skip(0).map((t) {
          return t == '📈 Account limits' ? 'Account limits' : t;
        }),
      );
      expect(limits.lines.first.heading, isTrue);
      expect(limits.lines.where((l) => l.heading), hasLength(1));
      expect(limits.lines.map((l) => l.usedPercent).toList(), [
        null,
        null,
        28,
        91,
        null,
      ]);
      final session = limits.lines[2];
      expect(session.primary, 'Session: 72% remaining (28% used)');
      expect(session.secondary, 'resets in 2h 13m (2026-10-06 18:00 WEST)');
      expect(limits.level, SubscriptionLimitLevel.near);
      expect(limits.isEmpty, isFalse);
    });

    test('Claude lines: unavailable stays text, extra usage X/Y bar', () {
      final limits = AccountUsageLimits.fromGateway(
        usage(account: claudeLines),
      );
      final used = {for (final l in limits.lines) l.text: l.usedPercent};
      expect(used['Opus week: unavailable'], isNull);
      expect(used['Extra usage: 4.20 / 50.00 USD'], closeTo(8.4, 1e-9));
      expect(used.values.whereType<double>(), hasLength(3));
      expect(limits.level, SubscriptionLimitLevel.none);
    });

    test('account lines first, then credits lines (Desktop order)', () {
      final limits = AccountUsageLimits.fromGateway(
        usage(account: codexLines, credits: nousLines),
      );
      expect(limits.lines.first.source, AccountLimitSource.account);
      expect(limits.lines.last.source, AccountLimitSource.credits);
      expect(limits.lines.last.text, '(or run /topup)');
      expect(limits.lines.where((l) => l.heading), hasLength(2));
    });

    test('credits lines only (Nous)', () {
      final limits = AccountUsageLimits.fromGateway(usage(credits: nousLines));
      expect(limits.lines, hasLength(nousLines.length));
      final sub = limits.lines[2];
      expect(sub.usedPercent, 40);
      expect(sub.secondary, r'$12.00 of $20.00 left');
      expect(limits.level, SubscriptionLimitLevel.none);
    });

    test('blank and non-string entries are dropped, bad shapes ignored', () {
      final limits = AccountUsageLimits.fromGateway({
        'account_lines': ['  ', 7, null, 'Session: unavailable'],
        'credits_lines': 'not a list',
      });
      expect(limits.lines.map((l) => l.text), ['Session: unavailable']);
    });

    test('markdown bold headings are cleaned', () {
      final limits = AccountUsageLimits.fromGateway(
        usage(account: ['📈 **Account limits**']),
      );
      expect(limits.lines.single.text, 'Account limits');
      expect(limits.lines.single.heading, isTrue);
    });

    test('no limits at all: empty, no level', () {
      final limits = AccountUsageLimits.fromGateway(usage());
      expect(limits.isEmpty, isTrue);
      expect(limits.level, SubscriptionLimitLevel.none);
    });

    test('usage.bars available: structured bars replace the credits lines', () {
      final limits = AccountUsageLimits.fromGateway(
        usage(account: codexLines, credits: nousLines),
        usageBars: barsAvailable,
      );
      expect(
        limits.lines.where((l) => l.source == AccountLimitSource.credits),
        isEmpty,
      );
      expect(limits.lines, hasLength(codexLines.length));
      expect(limits.bars, hasLength(2));
      final plan = limits.bars.first;
      expect(plan.kind, AccountUsageBarKind.plan);
      expect(plan.remaining, r'$3.00');
      expect(plan.total, r'$20.00');
      expect(plan.pctUsed, 85);
      expect(plan.usedFraction, closeTo(0.85, 1e-9));
      final topup = limits.bars.last;
      expect(topup.kind, AccountUsageBarKind.topup);
      expect(topup.pctUsed, isNull);
      expect(topup.usedFraction, closeTo(0.5, 1e-9));
      expect(limits.planName, 'Pro');
      expect(limits.renews, 'Nov 1, 2026');
    });

    test(
      'structured provider values cannot bypass validation or redaction',
      () {
        const id = 'acct-77aa88bb99cc';
        final limits = AccountUsageLimits.fromGateway(
          usage(),
          usageBars: {
            ...barsAvailable,
            'plan_name': 'Pro $id owner@example.com https://example.com',
            'renews_display': id,
          },
        );
        expect(limits.planName, 'Pro');
        expect(limits.renews, isNull);
        for (final field in ['remaining_display', 'total_display']) {
          for (final invalid in [id, r'$12,34', r'$1.00 acct-77aa88bb99cc']) {
            final rejected = AccountUsageLimits.fromGateway(
              usage(),
              usageBars: {
                'available': true,
                'plan_bar': {
                  ...(barsAvailable['plan_bar'] as Map<String, dynamic>),
                  field: invalid,
                },
              },
            );
            expect(rejected.bars, isEmpty, reason: '$field: $invalid');
            expect(rejected.renews, isNull);
            expect(rejected.planName, isNull);
          }
        }
      },
    );

    test('usage.bars unavailable: credits lines stay, no bars', () {
      final limits = AccountUsageLimits.fromGateway(
        usage(credits: nousLines),
        usageBars: const {'ok': true, 'available': false},
      );
      expect(limits.bars, isEmpty);
      expect(limits.lines, hasLength(nousLines.length));
      expect(limits.renews, isNull);
    });

    test('a malformed bar is skipped, never guessed', () {
      final limits = AccountUsageLimits.fromGateway(
        usage(),
        usageBars: const {
          'available': true,
          'plan_bar': {
            'kind': 'plan',
            'remaining_display': r'$3.00',
            'total_display': r'$20.00',
            'fill_fraction': 'lots',
          },
          'topup_bar': {
            'kind': 'topup',
            'remaining_display': r'$1.00',
            'total_display': r'$2.00',
            'fill_fraction': 1.7,
          },
        },
      );
      expect(limits.bars, isEmpty);
      expect(limits.isEmpty, isTrue);
    });
  });

  group('level (amber hint in the pill)', () {
    AccountUsageLimits withUsed(double used) => AccountUsageLimits.fromGateway(
      usage(account: ['Weekly: ${100 - used}% remaining ($used% used)']),
    );

    test('threshold is 80 % from parsed lines', () {
      expect(withUsed(79).level, SubscriptionLimitLevel.none);
      expect(withUsed(80).level, SubscriptionLimitLevel.near);
      expect(withUsed(99).level, SubscriptionLimitLevel.near);
      expect(withUsed(100).level, SubscriptionLimitLevel.reached);
    });

    test('usage.bars plan pct_used drives the hint; topup never does', () {
      final plan = AccountUsageLimits.fromGateway(
        usage(),
        usageBars: barsAvailable,
      );
      expect(plan.level, SubscriptionLimitLevel.near);
      final topupOnly = AccountUsageLimits.fromGateway(
        usage(),
        usageBars: {
          'available': true,
          'topup_bar': {
            'kind': 'topup',
            'remaining_display': r'$0.10',
            'total_display': r'$10.00',
            'fill_fraction': 0.01,
          },
        },
      );
      expect(topupOnly.bars, hasLength(1));
      expect(topupOnly.level, SubscriptionLimitLevel.none);
    });

    test('ambiguous percentages never raise the hint', () {
      final limits = AccountUsageLimits.fromGateway(
        usage(account: ['Rate: 95%', 'Session: 5% remaining (60% used)']),
      );
      expect(limits.lines.every((l) => l.usedPercent == null), isTrue);
      expect(limits.level, SubscriptionLimitLevel.none);
    });
  });
}
