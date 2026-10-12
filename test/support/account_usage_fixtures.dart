/// Payload shapes copied from Hermes' `render_account_usage_lines`
/// (agent/account_usage.py) and the `usage.bars` serializer
/// (tui_gateway/billing_view.py).
const codexLines = [
  '📈 Account limits',
  'Provider: openai-codex (Plus)',
  'Session: 72% remaining (28% used) • resets in 2h 13m (2026-10-06 18:00 WEST)',
  'Weekly: 9% remaining (91% used) • resets in 3d 4h (2026-10-09 21:00 WEST)',
  'You have 1 reset banked - use /usage reset to activate',
];

const claudeLines = [
  '📈 Account limits',
  'Provider: anthropic',
  'Current session: 100% remaining (0% used) • resets in 4h 2m (2026-10-06 20:00 WEST)',
  'Current week: 55% remaining (45% used) • resets in 2d 1h (2026-10-08 17:00 WEST)',
  'Opus week: unavailable',
  'Extra usage: 4.20 / 50.00 USD',
];

const nousLines = [
  '📈 Nous credits',
  'Provider: nous (Pro)',
  r'Subscription: 60% remaining (40% used) • $12.00 of $20.00 left',
  r'Subscription credits: $12.00',
  r'Total usable: $12.00',
  'Renews: 2026-11-01',
  'Top up: https://portal.example/topup',
  '(or run /topup)',
];

Map<String, dynamic> usage({List<Object?>? account, List<Object?>? credits}) =>
    {
      'calls': 3,
      'input': 1200,
      'output': 300,
      'total': 1500,
      'account_lines': ?account,
      'credits_lines': ?credits,
    };

const barsAvailable = <String, dynamic>{
  'ok': true,
  'available': true,
  'plan_name': 'Pro',
  'renews_display': 'Nov 1, 2026',
  'plan_bar': {
    'kind': 'plan',
    'remaining_display': r'$3.00',
    'total_display': r'$20.00',
    'spent_display': r'$17.00',
    'pct_used': 85,
    'fill_fraction': 0.15,
  },
  'topup_bar': {
    'kind': 'topup',
    'remaining_display': r'$5.00',
    'total_display': r'$10.00',
    'spent_display': r'$5.00',
    'pct_used': null,
    'fill_fraction': 0.5,
  },
};

/// Privacy fixture: a fake organization URL and id in every free-text slot
/// Hermes could fill. None of it may reach a Home widget.
const fakeOrg = 'org_8f2a91c4';
const leakyLines = [
  '📈 Account limits',
  'Provider: anthropic (https://console.example.com/org/org_8f2a91c4)',
  'Organization: org_8f2a91c4',
  'Session: 70% remaining (30% used) • https://claude.example.com/settings/usage?org=org_8f2a91c4',
  'org_8f2a91c4 week: 50% used',
  'https://console.example.com/org_8f2a91c4 week: 40% used',
  'Top up: https://console.example.com/org/org_8f2a91c4/billing',
];
const leakyCredits = [
  'Subscription: 60% remaining (40% used) • https://x.example/org_8f2a91c4 of https://y.example left',
];
const leakyBars = <String, dynamic>{
  'available': true,
  'plan_name': 'Pro org_8f2a91c4',
  'renews_display': 'https://billing.example/org_8f2a91c4',
  'plan_bar': {
    'kind': 'plan',
    // Short enough to pass any length guard: only the shape check stops it.
    'remaining_display': fakeOrg,
    'total_display': r'$20.00',
    'pct_used': 30,
    'fill_fraction': 0.7,
  },
};
