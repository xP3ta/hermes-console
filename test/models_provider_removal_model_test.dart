// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The data behind "Remove" of a provider: which key variables a provider
// card holds, the profile's exclusion list, which catalog rows that list
// reaches, and the chat picker's own copy of the catalog.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/model_active_info.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/models/provider_exclusions.dart';
import 'package:hermes_android/core/models/provider_key_groups.dart';
import 'package:hermes_android/core/services/model_picker_loader.dart';

Map<String, dynamic> _var(
  String provider, {
  bool set = false,
  bool primary = true,
  List<Map<String, dynamic>> profiles = const [],
}) => {
  'is_set': set,
  'category': 'provider',
  'is_password': true,
  'advanced': false,
  'provider': provider,
  'provider_label': provider.toUpperCase(),
  'provider_primary': primary,
  'provider_profiles': profiles,
};

ProviderKeyGroup _card(Map<String, dynamic> env, String slug) =>
    providerKeyGroupsFromEnv(env).firstWhere((group) => group.slug == slug);

void main() {
  group('the key variables of a provider card', () {
    test('a key under the second variable is a key that is set', () {
      final card = _card({
        'KIMI_API_KEY': _var('kimi'),
        'KIMI_CODING_API_KEY': _var('kimi', set: true, primary: false),
      }, 'kimi');
      expect(card.keyEnv, 'KIMI_API_KEY', reason: 'where a key is saved');
      expect(card.isSet, isTrue);
      expect(card.setKeys, ['KIMI_CODING_API_KEY']);
      expect(card.primarySet, isFalse);
    });

    test('every set variable is listed, the primary one first', () {
      final card = _card({
        'KIMI_CODING_API_KEY': _var('kimi', set: true, primary: false),
        'KIMI_API_KEY': _var('kimi', set: true),
        'KIMI_BASE_URL': {
          ..._var('kimi', set: true, primary: false),
          'is_password': false,
          'advanced': true,
        },
      }, 'kimi');
      expect(card.setKeys, ['KIMI_API_KEY', 'KIMI_CODING_API_KEY']);
      expect(card.primarySet, isTrue);
    });

    test('a card without a key of its own is not set', () {
      final card = _card({
        'KIMI_API_KEY': _var('kimi'),
        'KIMI_CODING_API_KEY': _var('kimi', primary: false),
      }, 'kimi');
      expect(card.isSet, isFalse);
      expect(card.setKeys, isEmpty);
    });

    test('a variable borrowed from another provider\'s card is not this '
        'card\'s to clear', () {
      // One variable, two cards: it is Dash's own key and only an extra way
      // in for Coder.
      final shared = _var(
        'dash',
        set: true,
        profiles: [
          {'provider': 'dash', 'provider_label': 'DASH', 'primary': true},
          {'provider': 'coder', 'provider_label': 'CODER', 'primary': false},
        ],
      );
      final env = {'DASH_API_KEY': shared, 'CODER_API_KEY': _var('coder')};
      expect(_card(env, 'dash').setKeys, ['DASH_API_KEY']);
      final coder = _card(env, 'coder');
      expect(coder.keyEnv, 'CODER_API_KEY');
      expect(coder.setKeys, isEmpty);
      expect(coder.isSet, isFalse);
    });
  });

  group('the exclusion list of a profile', () {
    test('is read as written, and a missing one is empty', () {
      expect(
        excludedProvidersOfConfigAnswer({
          'model_catalog': {
            'enabled': true,
            'excluded_providers': ['Copilot', ' openrouter ', '', null],
          },
        }),
        ['Copilot', 'openrouter'],
      );
      expect(excludedProvidersOfConfigAnswer({'model': 'x'}), isEmpty);
      expect(
        excludedProvidersOfConfigAnswer({'model_catalog': 'broken'}),
        isEmpty,
      );
    });

    test('an answer that is not a configuration is a failed read', () {
      expect(
        () => excludedProvidersOfConfigAnswer({'data': 'nope'}),
        throwsFormatException,
      );
    });

    test('a provider is added once and taken off whatever its case', () {
      const list = ['Copilot', 'openrouter'];
      expect(excludesProvider(list, 'copilot'), isTrue);
      expect(withProviderExcluded(list, 'copilot'), same(list));
      expect(withProviderExcluded(list, 'kimi'), [
        'Copilot',
        'openrouter',
        'kimi',
      ]);
      expect(withProviderIncluded(list, 'COPILOT'), ['openrouter']);
      expect(withProviderIncluded(list, 'kimi'), list);
    });

    test('only that one list is written', () {
      expect(excludedProvidersPatch(const ['copilot']), {
        'model_catalog': {
          'excluded_providers': ['copilot'],
        },
      });
    });
  });

  test('the exclusion list reaches the providers Hermes ships, not a user '
      'endpoint, the local runtime or Mixture of Agents', () {
    ModelProvider row(Map<String, dynamic> more) => ModelProvider.fromJson({
      'slug': 'x',
      'name': 'X',
      'authenticated': true,
      ...more,
    });
    expect(row({'source': 'built-in'}).excludable, isTrue);
    expect(row({'source': 'hermes'}).excludable, isTrue);
    expect(row(const {}).excludable, isTrue);
    expect(
      row({'source': 'user-config', 'is_user_defined': true}).excludable,
      isFalse,
    );
    expect(row({'source': 'local-runtime'}).excludable, isFalse);
    expect(row({'source': 'virtual'}).excludable, isFalse);
  });

  group('the chat picker\'s copy of the catalog', () {
    ModelProvider provider(String slug) => ModelProvider.fromJson({
      'slug': slug,
      'name': slug,
      'authenticated': true,
      'models': ['$slug-1'],
    });
    ModelPickerResult result() => ModelPickerResult(
      info: const ModelActiveInfo(
        model: 'acme-1',
        provider: 'acme',
        effectiveContextLength: 0,
      ),
      providers: [provider('acme'), provider('kimi')],
      source: ModelPickerSource.socket,
    );

    test('stops listing a removed provider at once and asks the server '
        'again on the next open', () {
      final cache = ModelPickerCache()..write('k', result());
      expect(cache.peek('k')!.fresh, isTrue);
      cache.retireProviders('k', {'KIMI'});
      final kept = cache.peek('k')!;
      expect([for (final row in kept.result.providers) row.slug], ['acme']);
      expect(kept.result.source, ModelPickerSource.socket);
      expect(kept.fresh, isFalse);
    });

    test('a profile without a copy has nothing to retire', () {
      final cache = ModelPickerCache()..retireProviders('k', {'kimi'});
      expect(cache.peek('k'), isNull);
    });
  });
}
