import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/models/provider_usage.dart';

Map<String, dynamic> _row(Object? usage) => {
  'slug': 'openai-codex',
  'name': 'OpenAI Codex',
  'authenticated': true,
  'usage': ?usage,
};

void main() {
  group('ProviderUsage.tryParse', () {
    test('single-account windows, with scope and reset', () {
      final usage = ProviderUsage.tryParse({
        'windows': [
          {
            'label': 'Session',
            'used_percent': 28.5,
            'resets_at': '2026-10-22T14:13:00+00:00',
            'scope': 'account',
          },
          {'label': 'Opus week', 'used_percent': 10, 'scope': 'model'},
        ],
      })!;
      expect(usage.accounts, isEmpty);
      expect(usage.windows, hasLength(2));
      expect(usage.windows.first.usedPercent, 28.5);
      expect(usage.windows.first.resetsAt, DateTime.utc(2026, 10, 22, 14, 13));
      expect(usage.windows.first.scope, ProviderUsageScope.account);
      expect(usage.windows.last.scope, ProviderUsageScope.model);
      expect(usage.windows.last.resetsAt, isNull);
    });

    test('a window without scope is account-wide (the contract default)', () {
      final usage = ProviderUsage.tryParse({
        'windows': [
          {'label': 'Weekly', 'used_percent': 1.0},
        ],
      })!;
      expect(usage.windows.single.scope, ProviderUsageScope.account);
    });

    test('pool accounts keep id, label, state and reset', () {
      final usage = ProviderUsage.tryParse({
        'windows': <Object>[],
        'accounts': [
          {
            'id': 'acct-1',
            'label': 'Work',
            'state': 'limited',
            'resets_at': '2026-10-22T14:13:00Z',
            'windows': [
              {'label': 'Session', 'used_percent': 100.0},
            ],
          },
          {'id': 'acct-2', 'state': 'unknown', 'windows': <Object>[]},
          {'id': 'acct-3', 'state': 'unavailable'},
        ],
      })!;
      expect(usage.windows, isEmpty);
      expect(usage.accounts.map((a) => a.state), [
        ProviderUsageState.limited,
        ProviderUsageState.unknown,
        ProviderUsageState.unavailable,
      ]);
      expect(usage.accounts.first.label, 'Work');
      expect(usage.accounts.first.resetsAt, DateTime.utc(2026, 10, 22, 14, 13));
      expect(usage.accounts.first.windows.single.usedPercent, 100);
      expect(usage.accounts[1].label, isEmpty);
    });

    test('an unknown state is "unknown": never a gauge', () {
      final usage = ProviderUsage.tryParse({
        'accounts': [
          {'id': 'a', 'state': 'melting'},
          {'id': 'b'},
        ],
      })!;
      expect(usage.accounts.map((a) => a.state), [
        ProviderUsageState.unknown,
        ProviderUsageState.unknown,
      ]);
    });

    test('malformed input is ignored and never throws', () {
      for (final bad in <Object?>[
        null,
        42,
        'windows',
        <Object>[],
        <String, Object?>{},
        {'windows': 'x'},
        {'windows': <Object>[]},
        {'windows': <Object?>[null, 3, 'a', <Object>[]]},
        {
          'windows': [
            {'label': '', 'used_percent': 1},
            {'label': 'A', 'used_percent': '5'},
            {'label': 'A', 'used_percent': double.nan},
            {'label': 'A', 'used_percent': double.infinity},
            {'label': 5, 'used_percent': 5},
            {'used_percent': 5},
            {'label': 'A', 'used_percent': 5, 'scope': 'galaxy'},
          ],
        },
        {'accounts': 'x'},
        {
          'accounts': [
            null,
            {'label': 'no id'},
            {'id': '  '},
            {'id': 7},
          ],
        },
      ]) {
        expect(ProviderUsage.tryParse(bad), isNull, reason: '$bad');
      }
    });

    test('a bad sibling does not drop the good window', () {
      final usage = ProviderUsage.tryParse({
        'windows': [
          {'label': 'A', 'used_percent': 'x'},
          {'label': 'Session', 'used_percent': 10, 'resets_at': 'soon'},
        ],
      })!;
      expect(usage.windows.single.label, 'Session');
      expect(usage.windows.single.resetsAt, isNull);
    });

    test('percent is clamped to 0..100', () {
      final usage = ProviderUsage.tryParse({
        'windows': [
          {'label': 'A', 'used_percent': 140},
          {'label': 'B', 'used_percent': -3},
        ],
      })!;
      expect(usage.windows.map((w) => w.usedPercent), [100, 0]);
    });

    test('windows and accounts are bounded', () {
      final usage = ProviderUsage.tryParse({
        'windows': [
          for (var i = 0; i < 60; i++) {'label': 'W', 'used_percent': 1},
        ],
        'accounts': [
          for (var i = 0; i < 90; i++) {'id': 'a$i', 'state': 'unknown'},
        ],
      })!;
      expect(usage.windows, hasLength(16));
      expect(usage.accounts, hasLength(32));
    });
  });

  group('ModelProvider.usage', () {
    test('is parsed from the row and survives copyWith', () {
      final provider = ModelProvider.fromJson(
        _row({
          'windows': [
            {'label': 'Session', 'used_percent': 5},
          ],
        }),
      );
      expect(provider.usage!.windows.single.label, 'Session');
      expect(provider.copyWith(models: const ['m']).usage, isNotNull);
    });

    test('a row without usage, or with a malformed one, has none', () {
      expect(ModelProvider.fromJson(_row(null)).usage, isNull);
      expect(ModelProvider.fromJson(_row('x')).usage, isNull);
      expect(ModelProvider.fromJson(_row({'windows': 3})).usage, isNull);
    });
  });
}
