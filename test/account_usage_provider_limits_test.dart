import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_limits.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/account_limits_section.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart'
    show SubscriptionLimitLevel;
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/account_usage_fixtures.dart' as fx;

final _now = DateTime.utc(2026, 10, 22, 12);
const _in2h13 = '2026-10-22T14:13:30+00:00';

Map<String, dynamic> _window(
  String label,
  num used, {
  String? resets,
  String? scope,
}) => {
  'label': label,
  'used_percent': used,
  'resets_at': resets,
  'scope': ?scope,
};

ModelProvider _p(
  String slug,
  String name,
  Map<String, dynamic>? usage, {
  bool current = false,
  List<String> aliases = const [],
}) => ModelProvider.fromJson({
  'slug': slug,
  'name': name,
  'authenticated': true,
  'is_current': current,
  'aliases': aliases,
  'usage': ?usage,
});

ModelProvider get _codex => _p('openai-codex', 'OpenAI Codex', {
  'windows': [
    _window('Session', 28.0, resets: _in2h13, scope: 'account'),
    _window('Weekly', 91.0, scope: 'account'),
  ],
});

ModelProvider get _claude => _p('anthropic', 'Anthropic', {
  'windows': [
    _window('Current session', 0.0),
    _window('Opus week', 100.0, scope: 'model'),
  ],
});

AccountUsageLimits _build(
  List<ModelProvider> providers, {
  String? route,
  String? skip,
}) => AccountUsageLimits.fromProviderUsage(
  providers,
  sessionProvider: route,
  skipProvider: skip,
  now: _now,
);

List<String> _texts(AccountUsageLimits l) => [for (final x in l.lines) x.text];

void main() {
  group('fromProviderUsage: one provider', () {
    test('windows become account_lines-shaped lines under its name', () {
      final limits = _build([_codex], route: 'openai-codex');
      final lines = limits.lines;
      expect(lines.first.heading, isTrue);
      expect(lines.first.groupHeading, isTrue);
      expect(lines.first.text, 'OpenAI Codex');
      expect(lines[1].text, startsWith('Session: 72% remaining (28% used) • '));
      expect(lines[1].text, contains('resets in 2h 13m ('));
      expect(lines[2].text, 'Weekly: 9% remaining (91% used)');
      expect(lines.map((l) => l.usedPercent).toList(), [null, 28, 91]);
      expect(lines.every((l) => l.source == AccountLimitSource.account), true);
      expect(limits.accountIdentity?.provider, 'openai-codex');
      expect(limits.accountIdentity?.plan, isNull);
      expect(limits.level, SubscriptionLimitLevel.near);
    });

    test('same text the old account_lines had parses to the same percent', () {
      final fromLines = AccountUsageLimits.fromGateway(
        fx.usage(account: fx.codexLines),
      ).lines.where((l) => l.usedPercent != null).map((l) => l.usedPercent);
      final fromCatalog = _build([_codex], route: 'openai-codex').lines
          .where((l) => l.usedPercent != null)
          .map((l) => l.usedPercent);
      expect(fromCatalog, fromLines);
    });

    test('a window already past says "resets now"', () {
      final limits = _build([
        _p('openai-codex', 'OpenAI Codex', {
          'windows': [
            _window('Session', 100, resets: '2026-10-22T11:00:00+00:00'),
          ],
        }),
      ], route: 'openai-codex');
      expect(limits.lines[1].text, contains('• resets now ('));
      expect(limits.level, SubscriptionLimitLevel.reached);
    });

    test('days, hours and minutes follow the Hermes format', () {
      String reset(Duration d) => _build([
        _p('p', 'P', {
          'windows': [
            _window('Weekly', 5, resets: _now.add(d).toIso8601String()),
          ],
        }),
      ]).lines[1].text;
      expect(reset(const Duration(days: 3, hours: 4)), contains('in 3d 4h ('));
      expect(reset(const Duration(minutes: 42)), contains('in 42m ('));
    });

    test('a label that is not plain words is dropped, not shown raw', () {
      final limits = _build([
        _p('p', 'P', {
          'windows': [
            _window('12345', 5),
            _window('org_9f8e7d6c5b4a: x', 5),
            _window('Session', 5),
          ],
        }),
      ]);
      expect(_texts(limits).where((t) => t.contains('%')), hasLength(1));
      expect(_texts(limits).join(), isNot(contains('9f8e')));
    });

    test('rows without usage, or with an empty one, give nothing', () {
      expect(_build([_p('p', 'P', null)]).lines, isEmpty);
      expect(_build([_p('p', 'P', {'windows': <Object>[]})]).lines, isEmpty);
      expect(_build(const []).lines, isEmpty);
      expect(_build(const []).isEmpty, isTrue);
    });
  });

  group('fromProviderUsage: choosing the provider', () {
    test('the session route goes first, not the catalog current row', () {
      final limits = _build([
        _p('openai-codex', 'OpenAI Codex', {
          'windows': [_window('Weekly', 95)],
        }, current: true),
        _claude,
      ], route: 'anthropic');
      final headings = limits.lines.where((l) => l.heading).toList();
      expect(headings.map((l) => l.text), ['Anthropic', 'OpenAI Codex']);
      expect(headings.map((l) => l.inUse), [true, false]);
      expect(limits.accountIdentity?.provider, 'anthropic');
      // Codex at 95 % is not this chat's account: the pill ignores it.
      expect(limits.level, SubscriptionLimitLevel.none);
    });

    test('every line of another provider is flagged as not in use', () {
      final limits = _build([_codex, _claude], route: 'anthropic');
      final other = limits.lines.skipWhile((l) => l.inUse).toList();
      expect(other.first.text, 'OpenAI Codex');
      expect(other.every((l) => !l.inUse), isTrue);
    });

    test('matching ignores case and also takes an alias', () {
      expect(
        _build([_codex], route: ' OpenAI-Codex ').accountIdentity?.provider,
        'openai-codex',
      );
      expect(
        _build([
          _p('mine', 'Mine', {
            'windows': [_window('Weekly', 5)],
          }, aliases: const ['custom:mine']),
        ], route: 'custom:mine').accountIdentity?.provider,
        'mine',
      );
    });

    for (final route in <String?>[null, '', '  ', 'custom', 'some-other']) {
      test('route "$route" decides nothing: all providers, labelled, '
          'none feeds the pill or the identity', () {
        final limits = _build([_codex, _claude], route: route);
        expect(limits.lines.where((l) => l.heading).map((l) => l.text), [
          'OpenAI Codex',
          'Anthropic',
        ]);
        expect(limits.lines.every((l) => !l.inUse), isTrue);
        expect(limits.accountIdentity, isNull);
        expect(limits.level, SubscriptionLimitLevel.none);
        expect(limits.isEmpty, isFalse);
      });
    }

    test('two rows claiming the route decide nothing', () {
      final limits = _build([_codex, _codex], route: 'openai-codex');
      expect(limits.accountIdentity, isNull);
      expect(limits.lines.every((l) => !l.inUse), isTrue);
    });

    test('a route without usage still shows the other providers labelled', () {
      final limits = _build([
        _p('openrouter', 'OpenRouter', null),
        _codex,
      ], route: 'openrouter');
      expect(limits.lines.first.text, 'OpenAI Codex');
      expect(limits.accountIdentity, isNull);
      expect(limits.level, SubscriptionLimitLevel.none);
    });

    test('skipProvider leaves out limits that are shown elsewhere', () {
      final nous = _p('nous', 'Nous', {
        'windows': [_window('Subscription', 40)],
      });
      final limits = _build([nous, _codex], route: 'nous', skip: 'Nous');
      expect(limits.lines.where((l) => l.heading).map((l) => l.text), [
        'OpenAI Codex',
      ]);
    });
  });

  group('fromProviderUsage: scope', () {
    test('a model-scoped window never makes the account "reached"', () {
      final limits = _build([_claude], route: 'anthropic');
      final opus = limits.lines.firstWhere((l) => l.text.startsWith('Opus'));
      expect(opus.modelScoped, isTrue);
      expect(opus.usedPercent, 100);
      expect(limits.level, SubscriptionLimitLevel.none);
    });

    test('an account-scoped window at 100 % does', () {
      final limits = _build([
        _p('anthropic', 'Anthropic', {
          'windows': [_window('Current week', 100, scope: 'account')],
        }),
      ], route: 'anthropic');
      expect(limits.level, SubscriptionLimitLevel.reached);
    });
  });

  group('fromProviderUsage: credential pools', () {
    ModelProvider pool() => _p('openai-codex', 'OpenAI Codex', {
      'windows': <Object>[],
      'accounts': [
        {
          'id': 'a1',
          'label': 'Work',
          'state': 'ready',
          'windows': [_window('Session', 20, resets: _in2h13)],
        },
        {
          'id': 'a2',
          'label': '',
          'state': 'limited',
          'resets_at': _in2h13,
          'windows': [_window('Session', 100, resets: _in2h13)],
        },
        {
          'id': 'a3',
          'label': 'me@example.com',
          'state': 'unknown',
          // Even if windows were sent, an unknown account draws no gauge.
          'windows': [_window('Session', 77)],
        },
        {'id': 'a4', 'label': 'Old', 'state': 'unavailable'},
      ],
    });

    test('one heading per account, no provider-wide heading or average', () {
      final limits = _build([pool()], route: 'openai-codex');
      final headings = limits.lines.where((l) => l.heading).toList();
      expect(headings.map((l) => l.text), [
        'OpenAI Codex · Work',
        'OpenAI Codex',
        'OpenAI Codex',
        'OpenAI Codex · Old',
      ]);
      expect(headings.map((l) => l.accountNumber), [null, 2, 3, null]);
      expect(headings.every((l) => l.groupHeading), isTrue);
    });

    test('a private label (an email) is not shown', () {
      final texts = _texts(_build([pool()], route: 'openai-codex'));
      expect(texts.join('|'), isNot(contains('example.com')));
      expect(texts.join('|'), isNot(contains('me@')));
    });

    test('limited keeps its windows and shows the reset on a status row', () {
      final lines = _build([pool()], route: 'openai-codex').lines;
      final limited = lines.firstWhere(
        (l) => l.status == AccountLimitStatus.limited,
      );
      expect(limited.text, contains('resets in 2h 13m ('));
      expect(limited.usedPercent, isNull);
      final at = lines.indexOf(limited);
      expect(lines[at - 1].text, startsWith('Session: 0% remaining (100% used)'));
    });

    test('unknown and unavailable: a status row, no number, no window', () {
      final lines = _build([pool()], route: 'openai-codex').lines;
      for (final status in [
        AccountLimitStatus.unknown,
        AccountLimitStatus.unavailable,
      ]) {
        final row = lines.firstWhere((l) => l.status == status);
        expect(row.usedPercent, isNull);
        expect(row.text, isNot(contains('%')));
      }
      // 20 % (ready), 100 % (limited): the unknown account's 77 % is absent.
      expect(
        lines.map((l) => l.usedPercent).whereType<double>().toList(),
        [20, 100],
      );
      expect(lines.any((l) => l.text.contains('77')), isFalse);
    });

    test('a limited pool account drives the pill to "reached"', () {
      expect(
        _build([pool()], route: 'openai-codex').level,
        SubscriptionLimitLevel.reached,
      );
    });

    test('a limited account without a reset still shows its state', () {
      final lines = _build([
        _p('p', 'P', {
          'accounts': [
            {'id': 'a', 'state': 'limited'},
          ],
        }),
      ]).lines;
      expect(lines.last.status, AccountLimitStatus.limited);
      expect(lines.last.text, 'limited');
    });

    test('"ready" with no windows is shown as unknown, not as a gauge', () {
      final lines = _build([
        _p('p', 'P', {
          'accounts': [
            {'id': 'a', 'state': 'ready'},
          ],
        }),
      ]).lines;
      expect(lines.last.status, AccountLimitStatus.unknown);
    });
  });

  group('withProviderLines', () {
    test('keeps Nous credits and bars, puts provider windows first', () {
      final credits = AccountUsageLimits.fromGateway(
        fx.usage(credits: fx.nousLines),
      );
      final merged = credits.withProviderLines(
        _build([_codex], route: 'openai-codex'),
      );
      expect(merged.lines.first.text, 'OpenAI Codex');
      expect(merged.lines.last.text, fx.nousLines.last);
      expect(merged.creditsIdentity, credits.creditsIdentity);
      expect(merged.accountIdentity?.provider, 'openai-codex');
    });
  });

  group('rendering', () {
    Widget app(Widget child, {Locale locale = const Locale('es')}) =>
        MaterialApp(
          locale: locale,
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        );

    List<String> texts(WidgetTester tester) => [
      for (final w in tester.widgetList<Text>(find.byType(Text)))
        w.data ?? w.textSpan?.toPlainText() ?? '',
    ];

    final bars = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('account-limit-bar-'),
    );

    testWidgets('a pool shows headed groups and state rows, bars only on '
        'windows', (tester) async {
      final limits = _build([
        _p('openai-codex', 'OpenAI Codex', {
          'accounts': [
            {
              'id': 'a1',
              'label': 'Work',
              'state': 'ready',
              'windows': [_window('Session', 20)],
            },
            {
              'id': 'a2',
              'state': 'limited',
              'resets_at': _in2h13,
              'windows': [_window('Weekly', 100, resets: _in2h13)],
            },
            {'id': 'a3', 'state': 'unknown'},
            {'id': 'a4', 'label': 'Old', 'state': 'unavailable'},
          ],
        }),
      ], route: 'openai-codex');
      await tester.pumpWidget(app(AccountLimitsSection(limits: limits)));
      final all = texts(tester);
      expect(all, contains('OpenAI Codex · Work'));
      expect(all, contains('OpenAI Codex · Cuenta 2'));
      expect(all, contains('OpenAI Codex · Cuenta 3'));
      expect(all, contains('OpenAI Codex · Old'));
      expect(all, contains('Límite alcanzado'));
      expect(all, contains('Se reinicia en 2 h 13 min'));
      expect(all, contains('Uso aún sin informar'));
      expect(all, contains('No disponible'));
      expect(all, isNot(contains('Cuenta'))); // no generic heading
      expect(bars, findsNWidgets(2));
    });

    testWidgets('English catalog strings are used', (tester) async {
      final limits = _build([
        _p('p', 'Prov', {
          'accounts': [
            {'id': 'a', 'state': 'unknown'},
          ],
        }),
      ]);
      await tester.pumpWidget(
        app(AccountLimitsSection(limits: limits), locale: const Locale('en')),
      );
      expect(texts(tester), contains('Prov · Account 1'));
      expect(texts(tester), contains('Usage not reported yet'));
    });

    testWidgets('a single provider is headed by its name', (tester) async {
      await tester.pumpWidget(
        app(
          AccountLimitsSection(
            limits: _build([_codex, _claude], route: 'anthropic'),
          ),
        ),
      );
      final all = texts(tester);
      expect(all.indexOf('Anthropic'), lessThan(all.indexOf('OpenAI Codex')));
      expect(all, contains('Quedan 72 %'));
      expect(all, isNot(contains('Cuenta')));
    });

    testWidgets('legacy account_lines still render without any group heading',
        (tester) async {
      final limits = AccountUsageLimits.fromGateway(
        fx.usage(account: fx.codexLines),
      );
      await tester.pumpWidget(app(AccountLimitsSection(limits: limits)));
      expect(texts(tester), contains('Cuenta'));
      expect(texts(tester), contains('Sesión actual'));
    });

    testWidgets('Home lists only the account in use', (tester) async {
      late Strings strings;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) {
              strings = Strings.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      final rows = homeLimitRows(
        _build([_codex, _claude], route: 'anthropic'),
        strings,
        languageCode: 'es',
      );
      expect(rows.every((r) => r.who?.provider == 'anthropic'), isTrue);
      expect(rows.map((r) => r.label), isNot(contains('Semana')));
      expect(
        homeLimitRows(
          _build([_codex, _claude], route: null),
          strings,
          languageCode: 'es',
        ),
        isEmpty,
      );
    });
  });
}
