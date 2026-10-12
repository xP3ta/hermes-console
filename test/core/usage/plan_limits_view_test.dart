import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/usage/plan_limits_view.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../../support/account_usage_fixtures.dart' as fx;

// QA 9494 P2 (privacy): one shared builder for the plan limits, so the
// model sheet and Home say the same thing and neither leaks raw lines.
void main() {
  late Strings es;
  late Strings en;
  setUpAll(() async {
    es = await Strings.delegate.load(const Locale('es'));
    en = await Strings.delegate.load(const Locale('en'));
  });

  PlanLimitsView view(List<String> account, {Strings? s, String lang = 'es'}) =>
      planLimitsView(
        AccountUsageLimits.fromGateway(fx.usage(account: account)),
        s ?? es,
        languageCode: lang,
      );

  test('Codex windows: localized labels, percentages and reset times', () {
    final v = view(fx.codexLines);
    final rows = [for (final r in v.rows) (r.label, r.value, r.detail)];
    expect(rows, [
      ('Cuenta', null, null),
      ('Sesión actual', 'Quedan 72 %', 'Se reinicia en 2 h 13 min'),
      ('Semana', 'Quedan 9 %', 'Se reinicia en 3 d 4 h'),
    ]);
    expect(v.rows[2].usedPercent, 91);
    expect(v.notes, ['Tienes 1 reinicio guardado']);
    expect(v.providerDetails, isEmpty);
  });

  test(
    'renewal rejects synthetic account identifier in the owning constructor',
    () {
      const identifier = 'acct-77aa88bb99cc';
      expect(scrubProviderText('Renews: $identifier'), isNull);
      final v = view(['Renews: $identifier']);
      expect(v.rows, isEmpty);
      expect(v.notes, isEmpty);
      expect(v.providerDetails, isEmpty);
    },
  );

  test('renewal accepts calendar dates and discards invalid free text', () {
    for (final date in ['2026-11-01', '2024-02-29', 'Nov 1, 2026']) {
      final v = view(['Renews: $date']);
      expect(v.rows.last.value, date);
      expect(v.providerDetails, isEmpty);
    }
    for (final invalid in [
      '2026-02-29',
      '2026-04-31',
      '2026-13-01',
      '0000-01-01',
      'Feb 30, 2026',
      '11/01',
      'tomorrow',
      'Nov 1, 2026 acct-77aa88bb99cc',
      'a1b2c3d4e5f6',
      'https://example.com',
      'owner@example.com',
    ]) {
      final v = view(['Renews: $invalid']);
      expect(v.isEmpty, isTrue, reason: invalid);
    }
  });

  test('recognized windows discard invalid percentages and reset tails', () {
    for (final text in [
      'Session: 999% remaining (1% used)',
      'Session: 72% remaining (99% used)',
    ]) {
      expect(view([text]).rows, isEmpty, reason: text);
    }
    for (final tail in [
      'resets in 2h (acct-77aa88bb99cc)',
      'resets in 99999999999999999999999999999h',
      'resets now acct-77aa88bb99cc',
      'resets in 2h (2026-02-30 18:00 WEST)',
      'resets in 2h (2026-10-06 99:00 WEST)',
    ]) {
      final v = view(['Session: 72% remaining (28% used) • $tail']);
      expect(v.rows.last.detail, isNull, reason: tail);
      expect(v.providerDetails, isEmpty);
    }
    final valid = view(['Session: 72% remaining (28% used) • resets now']);
    expect(valid.rows.last.detail, 'Se reinicia ahora');
  });

  test('recognized money and usage fields reject malformed values', () {
    for (final line in [
      r'Subscription credits: $12,34',
      r'Subscription credits: $1.234',
      'Extra usage: 4.20 / 50.00 ABC',
      'Extra usage: 99999999999999999999999999999 / 50.00 USD',
    ]) {
      expect(view([line]).isEmpty, isTrue, reason: line);
    }
    final invalidTail = view([
      r'Subscription: 60% remaining (40% used) • $12,34 of $20.00 left',
    ]);
    expect(invalidTail.rows.last.detail, isNull);
    final valid = view(fx.nousLines);
    expect(valid.rows.last.value, '2026-11-01');
    expect(valid.rows[1].detail, r'$12.00 de $20.00');
    expect(view([r'Rollover: $1,234.50']).rows.last.value, r'$1,234.50');
  });

  test('banked reset count rejects oversized provider numbers fail closed', () {
    final v = view(['You have 999999999999999999999999 resets banked']);
    expect(v.isEmpty, isTrue);
  });

  test('English labels', () {
    final v = view(fx.claudeLines, s: en, lang: 'en');
    expect(
      [for (final r in v.rows) r.label],
      ['Account', 'Current session', 'Week', 'Week · Opus', 'Extra usage'],
    );
    expect(v.rows[1].detail, 'Resets in 4h 2m');
  });

  test('a fake org URL and ids never survive, not even in the details', () {
    const org = 'org_9f8e7d6c5b4a3921';
    final v = view([
      'Top up: https://portal.example/billing?org=$org',
      'Unavailable: billing for $org is paused, see https://x.example/o/1',
      'Contact owner@example.com about acct-77aa88bb99cc',
      'Plan note: 9f8e7d6c-1234-4abc-9def-0123456789ab expires soon',
      'Ref a1b2c3d4e5f6a7b8c9d0 pending',
      'Rate: 95%',
      'Billing org_ab12 paused',
    ]);
    final all = [
      for (final r in v.rows) ...[r.label, ?r.value, ?r.detail],
      ...v.notes,
      ...v.providerDetails,
    ].join('\n');
    for (final leak in [
      'http',
      'example',
      org,
      '9f8e7d6c',
      'a1b2c3d4',
      '77aa88bb',
      '@',
      'Unavailable',
      'Top up',
      'org_',
      'ab12',
    ]) {
      expect(all, isNot(contains(leak)), reason: leak);
    }
    expect(v.providerDetails, [
      'billing for is paused, see',
      'Contact about',
      'expires soon',
      'Ref pending',
      'Billing paused',
    ]);
  });

  test('scrubProviderText keeps plain words and drops empty leftovers', () {
    expect(
      scrubProviderText('Status: maintenance window'),
      'maintenance window',
    );
    expect(scrubProviderText('https://a.example/x'), isNull);
    expect(scrubProviderText('Rate: 95%'), isNull);
  });
}
