// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The provider key list comes from `GET /api/env`, grouped like Desktop's
// Providers settings (`buildProviderKeyGroups`), not from the model
// inventory. What the Models screen does with it is in
// models_providers_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/provider_key_groups.dart';

Map<String, Object> _env({bool gammaSet = false}) => {
  'ACME_API_KEY': {
    'is_set': true,
    'redacted_value': 'sk-...syn',
    'category': 'provider',
    'is_password': true,
    'advanced': false,
    'provider': 'acme',
    'provider_label': 'Acme',
    'provider_profiles': <Object>[],
    'provider_primary': true,
  },
  'GAMMA_API_KEY': {
    'is_set': gammaSet,
    'redacted_value': null,
    'category': 'provider',
    'is_password': true,
    'advanced': false,
    'provider': 'gamma',
    'provider_label': 'Gamma',
    'provider_profiles': <Object>[],
    'provider_primary': true,
  },
  'GAMMA_BASE_URL': {
    'is_set': false,
    'category': 'provider',
    'is_password': false,
    'advanced': true,
    'provider': 'gamma',
    'provider_label': 'Gamma',
    'provider_profiles': <Object>[],
    'provider_primary': false,
  },
  'SEARCH_TOOL_KEY': {
    'is_set': false,
    'category': 'tool',
    'is_password': true,
    'provider': '',
    'provider_label': '',
  },
};

void main() {
  group('providerKeyGroupsFromEnv (Desktop buildProviderKeyGroups)', () {
    test('keeps provider credentials only, one card per provider', () {
      final groups = providerKeyGroupsFromEnv(_env());
      expect(groups.map((g) => g.name), ['Acme', 'Gamma']);
      final gamma = groups.last;
      expect(gamma.slug, 'gamma');
      expect(gamma.keyEnv, 'GAMMA_API_KEY');
      expect(gamma.isSet, isFalse);
      expect(groups.first.isSet, isTrue);
    });

    test('expands a shared credential into its provider profiles', () {
      final groups = providerKeyGroupsFromEnv({
        'SHARED_API_KEY': {
          'is_set': false,
          'category': 'provider',
          'is_password': true,
          'provider': 'shared',
          'provider_label': 'Shared',
          'provider_profiles': [
            {'provider': 'one', 'provider_label': 'One', 'primary': true},
            {'provider': 'two', 'provider_label': 'Two', 'primary': true},
          ],
        },
      });
      expect(groups.map((g) => (g.name, g.slug, g.keyEnv)), [
        ('One', 'one', 'SHARED_API_KEY'),
        ('Two', 'two', 'SHARED_API_KEY'),
      ]);
    });

    test('prefers the primary key, then a non-advanced key var', () {
      final groups = providerKeyGroupsFromEnv({
        'DELTA_TOKEN': {
          'category': 'provider',
          'advanced': true,
          'provider': 'delta',
          'provider_label': 'Delta',
        },
        'DELTA_API_KEY': {
          'category': 'provider',
          'advanced': false,
          'provider': 'delta',
          'provider_label': 'Delta',
        },
        'DELTA_REGION': {
          'category': 'provider',
          'provider': 'delta',
          'provider_label': 'Delta',
        },
      });
      expect(groups.single.keyEnv, 'DELTA_API_KEY');
    });

    test('skips rows without backend provider identity or key var', () {
      expect(
        providerKeyGroupsFromEnv({
          'MYSTERY_API_KEY': {'category': 'provider'},
          'OTHER_API_KEY': {'category': 'provider', 'provider_label': 'Other'},
          'ONLY_URL': {
            'category': 'provider',
            'provider': 'url',
            'provider_label': 'Url',
          },
        }),
        isEmpty,
      );
    });
  });
}
