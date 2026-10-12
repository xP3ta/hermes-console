import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_limits.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/account_usage_fixtures.dart';

// QA 9495: Home reads the text lines through the model sheet's builder
// (planLimitsView), so both surfaces use the same localized labels.
void main() {
  late Strings es;
  late Strings en;
  setUpAll(() async {
    es = await Strings.delegate.load(const Locale('es'));
    en = await Strings.delegate.load(const Locale('en'));
  });

  List<HomeLimitRow> rowsOf(
    AccountUsageLimits limits, {
    Strings? s,
    String lang = 'es',
  }) => homeLimitRows(limits, s ?? es, languageCode: lang);

  group('Home plan limits read session.usage like the model sheet', () {
    test('Claude: session and week windows, reset times; no provider, no '
        'unavailable or raw lines', () {
      final rows = rowsOf(
        AccountUsageLimits.fromGateway(usage(account: claudeLines)),
      );
      expect(rows.map((r) => r.label), [
        'Sesión actual',
        'Semana',
        'Uso extra',
      ]);
      expect(rows.map((r) => r.window).toSet(), {HomeLimitWindow.line});
      expect(rows[0].used, 0);
      expect(rows[0].detail, 'Se reinicia en 4 h 2 min');
      expect(rows[1].used, 45);
      expect(rows[1].detail, 'Se reinicia en 2 d 1 h');
      expect(rows[2].used, closeTo(8.4, 0.01));
    });

    test('Codex: Session and Weekly; 91 % is near, the banked reset line '
        'is not a row', () {
      final rows = rowsOf(
        AccountUsageLimits.fromGateway(usage(account: codexLines)),
      );
      expect(rows.map((r) => r.label), ['Sesión actual', 'Semana']);
      expect(rows[0].used, 28);
      expect(rows[0].near, isFalse);
      expect(rows[1].used, 91);
      expect(rows[1].near, isTrue);
      expect(rows[1].reached, isFalse);
      expect(rows[1].detail, 'Se reinicia en 3 d 4 h');
    });

    test('Nous credits: the subscription with what is left', () {
      final rows = rowsOf(
        AccountUsageLimits.fromGateway(usage(credits: nousLines)),
      );
      expect(rows.single.window, HomeLimitWindow.line);
      expect(rows.single.label, es.plv1215Subscription);
      expect(rows.single.used, 40);
      expect(rows.single.detail, contains(r'$12.00'));
      expect(rows.single.detail, contains(r'$20.00'));
    });

    test('usage.bars replace the credits lines: plan (named) and top-up', () {
      final rows = rowsOf(
        AccountUsageLimits.fromGateway(
          usage(credits: nousLines),
          usageBars: barsAvailable,
        ),
      );
      expect(rows.map((r) => r.window), [
        HomeLimitWindow.planBar,
        HomeLimitWindow.topupBar,
      ]);
      expect(rows[0].name, 'Pro');
      expect(rows[0].used, closeTo(85, 0.01));
      expect(rows[0].near, isTrue);
      expect(rows[0].left, r'$3.00');
      expect(rows[1].used, closeTo(50, 0.01));
    });

    test('a model week names its model; 100 % is reached', () {
      final rows = rowsOf(
        AccountUsageLimits.fromGateway(
          usage(
            account: const [
              'Opus week: 0% remaining (100% used) • resets in 35m',
              'Some window nobody knows: 12% used',
              'Provider: anthropic',
            ],
          ),
        ),
      );
      expect(rows.single.label, es.plv1215WeekOpus);
      expect(rows.single.reached, isTrue);
      expect(rows.single.detail, 'Se reinicia en 35 min');
    });

    test('durations read short and calm, in each language', () {
      final limits = AccountUsageLimits.fromGateway(
        usage(
          account: const [
            'Session: 50% remaining (50% used) • resets in 4h 2m',
            'Weekly: 50% remaining (50% used) • resets in 3d',
          ],
        ),
      );
      expect(rowsOf(limits).map((r) => r.detail), [
        'Se reinicia en 4 h 2 min',
        'Se reinicia en 3 d',
      ]);
      final english = rowsOf(limits, s: en, lang: 'en');
      expect(english.map((r) => r.label), ['Current session', 'Week']);
      expect(english.map((r) => r.detail), ['Resets in 4h 2m', 'Resets in 3d']);
    });
  });

  group('privacy: no provider text, URLs or ids ever reach Home', () {
    test('a fake organization URL and id in every free-text slot is '
        'dropped', () {
      for (final (s, lang) in [(es, 'es'), (en, 'en')]) {
        final rows = rowsOf(
          AccountUsageLimits.fromGateway(
            usage(account: leakyLines, credits: leakyCredits),
            usageBars: leakyBars,
          ),
          s: s,
          lang: lang,
        );
        final painted = [
          for (final r in rows) ...[
            ?r.label,
            ?r.detail,
            ?r.name,
            ?r.left,
            ?r.total,
          ],
        ];
        for (final text in painted) {
          expect(text, isNot(contains('http')));
          expect(text, isNot(contains(fakeOrg)));
          expect(text, isNot(contains('example')));
        }
        // The windows themselves still read.
        expect(rows.map((r) => r.label), contains(s.plv1215Session));
        // The bar whose amount is an id is rejected whole by the model
        // (AccountUsageLimits.fromGateway), so it never becomes a row.
        expect(rows.map((r) => r.window).toSet(), {HomeLimitWindow.line});
      }
    });

    test('a bar that reaches Home with an unsafe name and amount keeps '
        'only its percentage', () {
      // Home's own guard, independent of the model's: built directly so the
      // unsafe values get as far as homeLimitRows.
      const limits = AccountUsageLimits(
        bars: [
          AccountUsageBar(
            kind: AccountUsageBarKind.plan,
            remaining: fakeOrg,
            total: 'https://y.example',
            usedFraction: 0.3,
            pctUsed: 30,
          ),
        ],
        planName: 'Pro $fakeOrg',
        renews: 'https://billing.example/$fakeOrg',
      );
      for (final (s, lang) in [(es, 'es'), (en, 'en')]) {
        final row = rowsOf(limits, s: s, lang: lang).single;
        expect(row.window, HomeLimitWindow.planBar);
        expect(row.used, closeTo(30, 0.01));
        expect(row.name, isNull, reason: 'plan name carried an id');
        expect(row.left, isNull, reason: 'amount carried an id');
        expect(row.total, isNull, reason: 'amount carried a URL');
        expect(row.label, isNull);
        expect(row.detail, isNull);
      }
    });
  });
}
