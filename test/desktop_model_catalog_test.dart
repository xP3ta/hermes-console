import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';

void main() {
  group('DesktopModelCatalog Hermes 0.19', () {
    test('parsea disponibilidad, capacidades y pricing por modelo', () {
      final catalog = DesktopModelCatalog.fromJson({
        'model': 'openai/gpt-5.5',
        'provider': 'openrouter',
        'providers': [
          {
            'slug': 'openrouter',
            'name': 'OpenRouter',
            'models': ['openai/gpt-5.5', 'paid/model'],
            'is_current': true,
            'authenticated': true,
            'auth_type': 'api_key',
            'key_env': 'OPENROUTER_API_KEY',
            'warning': '',
            'is_user_defined': false,
            'free_tier': true,
            'unavailable_models': ['paid/model'],
            'capabilities': {
              'openai/gpt-5.5': {'fast': true},
              'paid/model': {'fast': false, 'reasoning': false},
            },
            'pricing': {
              'openai/gpt-5.5': {
                'input': r'$3.00',
                'output': r'$15.00',
                'cache': r'$0.30',
                'free': false,
              },
              'paid/model': {
                'input': 'free',
                'output': 'free',
                'cache': null,
                'free': true,
              },
            },
          },
        ],
      });

      expect(catalog.currentModel, 'openai/gpt-5.5');
      expect(catalog.currentProvider, 'openrouter');
      final provider = catalog.providers.single;
      expect(provider.slug, 'openrouter');
      expect(provider.name, 'OpenRouter');
      expect(provider.isCurrent, isTrue);
      expect(provider.authenticated, isTrue);
      expect(provider.keyEnv, 'OPENROUTER_API_KEY');
      expect(provider.warning, isNull);
      expect(provider.freeTier, isTrue);
      expect(provider.models, ['openai/gpt-5.5', 'paid/model']);
      expect(provider.unavailableModels, ['paid/model']);
      expect(provider.isModelUsable('openai/gpt-5.5'), isTrue);
      expect(provider.isModelUsable('paid/model'), isFalse);

      final current = provider.optionFor('openai/gpt-5.5')!;
      expect(current.providerSlug, 'openrouter');
      expect(current.capabilities.fast, isTrue);
      expect(current.capabilities.reasoning, isNull);
      expect(current.pricing?.input, r'$3.00');
      expect(current.pricing?.output, r'$15.00');
      expect(current.pricing?.cache, r'$0.30');
      expect(current.pricing?.free, isFalse);

      final paid = catalog.optionFor('openrouter', 'paid/model')!;
      expect(paid.unavailable, isTrue);
      expect(paid.capabilities.fast, isFalse);
      expect(paid.capabilities.reasoning, isFalse);
    });

    test('un plan que Hermes aún comprueba no es un veredicto sobre los '
        'modelos (free_tier_pending)', () {
      final catalog = DesktopModelCatalog.fromJson(const {
        'providers': [
          {
            'slug': 'nous',
            'name': 'Nous Portal',
            'models': ['a', 'b'],
            'free_tier_pending': true,
            'unavailable_models': ['a', 'b'],
          },
          {
            'slug': 'openai',
            'name': 'OpenAI',
            'models': ['c'],
            'unavailable_models': ['c'],
          },
        ],
      });
      expect(catalog.providerFor('nous')!.entitlementPending, isTrue);
      expect(catalog.providerFor('openai')!.entitlementPending, isFalse);
      // The list itself is kept as the server sent it.
      expect(catalog.providerFor('nous')!.optionFor('a')!.unavailable, isTrue);
    });

    test('capability ausente o no booleana permanece unknown', () {
      final provider = DesktopModelCatalog.fromJson({
        'providers': [
          {
            'slug': 'opaque-provider',
            'authenticated': true,
            'models': ['missing', 'malformed'],
            'capabilities': {
              'malformed': {'fast': 'yes', 'reasoning': 1},
            },
          },
        ],
      }).providers.single;

      expect(provider.capabilities['missing']?.fast, isNull);
      expect(provider.capabilities['missing']?.reasoning, isNull);
      expect(provider.capabilities['malformed']?.fast, isNull);
      expect(provider.capabilities['malformed']?.reasoning, isNull);
    });

    test('deduplica slug+modelo y conserva la entrada autenticada rica', () {
      final catalog = DesktopModelCatalog.fromJson({
        'providers': [
          {
            'slug': 'same-provider',
            'name': 'Sin configurar',
            'authenticated': false,
            'warning': 'Necesita autenticación',
            'models': ['shared/model', 'legacy/model'],
            'unavailable_models': ['shared/model'],
            'capabilities': {
              'shared/model': {'fast': false},
            },
          },
          {
            'slug': 'same-provider',
            'name': 'Proveedor autenticado',
            'authenticated': true,
            'warning': '',
            'key_env': 'SAME_PROVIDER_API_KEY',
            'models': ['shared/model', 'shared/model', 'new/model'],
            'unavailable_models': <String>[],
            'capabilities': {
              'shared/model': {'fast': true, 'reasoning': true},
            },
            'pricing': {
              'shared/model': {
                'input': r'$1.00',
                'output': r'$2.00',
                'free': false,
              },
            },
          },
          {
            'slug': 'other-provider',
            'authenticated': true,
            'models': ['shared/model'],
          },
        ],
      });

      expect(catalog.providers, hasLength(2));
      final merged = catalog.providerFor('same-provider')!;
      expect(merged.authenticated, isTrue);
      expect(merged.name, 'Proveedor autenticado');
      expect(merged.warning, isNull);
      expect(merged.models, ['shared/model', 'legacy/model', 'new/model']);
      expect(
        merged.models.where((model) => model == 'shared/model'),
        hasLength(1),
      );
      final shared = merged.optionFor('shared/model')!;
      expect(shared.unavailable, isFalse);
      expect(shared.capabilities.fast, isTrue);
      expect(shared.capabilities.reasoning, isTrue);
      expect(shared.pricing?.input, r'$1.00');
      expect(
        catalog.optionFor('other-provider', 'shared/model'),
        isNotNull,
        reason: 'el dedupe incluye el slug; dos proveedores no se colapsan',
      );
    });

    test('auth, warning y unavailable bloquean sin ocultar las filas', () {
      final catalog = DesktopModelCatalog.fromJson({
        'providers': [
          {
            'slug': 'no-auth',
            'authenticated': false,
            'models': ['visible'],
          },
          {
            'slug': 'warning',
            'authenticated': true,
            'warning': 'Configuración incompleta',
            'models': ['visible'],
          },
          {
            'slug': 'tier',
            'authenticated': true,
            'models': ['free', 'paid'],
            'unavailable_models': ['paid'],
          },
          {
            'slug': 'unknown-auth',
            'models': ['visible'],
          },
        ],
      });

      expect(catalog.providers, hasLength(4));
      expect(catalog.providerFor('no-auth')?.isModelUsable('visible'), isFalse);
      expect(catalog.providerFor('warning')?.isModelUsable('visible'), isFalse);
      expect(catalog.providerFor('tier')?.isModelUsable('free'), isTrue);
      expect(catalog.providerFor('tier')?.isModelUsable('paid'), isFalse);
      expect(catalog.providerFor('unknown-auth')?.authenticated, isNull);
      expect(
        catalog.providerFor('unknown-auth')?.isModelUsable('visible'),
        isFalse,
      );
    });

    test('descarta filas e identificadores inválidos individualmente', () {
      final tooLong = List<String>.filled(300, 'x').join();
      final catalog = DesktopModelCatalog.fromJson({
        'model': ' invalid-current',
        'provider': 'bad\nprovider',
        'providers': [
          'not-a-map',
          {'name': 'sin slug', 'models': <String>[]},
          {'slug': 'bad slug', 'models': <String>[]},
          {'slug': 'bad\nslug', 'models': <String>[]},
          {'slug': 'wrong-model-shape', 'models': 'not-a-list'},
          {
            'slug': 'valid-provider',
            'authenticated': true,
            'models': [
              null,
              '',
              ' leading',
              'internal space',
              'line\nbreak',
              '--provider=evil',
              'model;command',
              r'model$expansion',
              tooLong,
              'valid/model',
              'valid/model',
            ],
          },
          {'slug': 'setup-only', 'authenticated': false, 'models': <String>[]},
        ],
      });

      expect(catalog.currentModel, isNull);
      expect(catalog.currentProvider, isNull);
      expect(catalog.providers.map((provider) => provider.slug), [
        'valid-provider',
        'setup-only',
      ]);
      expect(catalog.providers.first.models, ['valid/model']);
      expect(catalog.providers.last.models, isEmpty);
    });

    test('solo retiene key_env válido y pricing público estructurado', () {
      final longName = List<String>.filled(300, 'n').join();
      final longWarning = List<String>.filled(900, 'w').join();
      final provider = DesktopModelCatalog.fromJson({
        'api_key': 'top-level-secret',
        'providers': [
          {
            'slug': 'private-safe',
            'name': longName,
            'authenticated': true,
            'key_env': 'API_KEY=server-secret',
            'warning': longWarning,
            'credential': 'provider-secret',
            'models': ['model'],
            'pricing': {
              'model': {
                'input': 'secret-price-value',
                'output': r'$2.50',
                'token': 'pricing-secret',
                'free': 'false',
              },
            },
          },
        ],
      }).providers.single;

      expect(provider.keyEnv, isNull);
      expect(provider.name.length, 160);
      expect(provider.warning?.length, 512);
      expect(provider.pricing['model']?.input, isNull);
      expect(provider.pricing['model']?.output, r'$2.50');
      expect(provider.pricing['model']?.free, isNull);
      expect(provider.pricing['model'].toString(), isNot(contains('secret')));
    });

    test('acota colecciones y expone resultados inmutables', () {
      final oversizedModels = List<String>.generate(1100, (i) => 'model-$i');
      final providers = <Map<String, Object?>>[
        {
          'slug': 'large-provider',
          'authenticated': true,
          'models': oversizedModels,
        },
        for (var provider = 0; provider < 140; provider++)
          {
            'slug': 'provider-$provider',
            'authenticated': true,
            'models': [for (var model = 0; model < 20; model++) 'model-$model'],
          },
      ];

      final catalog = DesktopModelCatalog.fromJson({'providers': providers});

      expect(
        catalog.providers.length,
        lessThanOrEqualTo(DesktopModelCatalog.maxProviders),
      );
      expect(
        catalog.providers.first.models.length,
        lessThanOrEqualTo(DesktopModelCatalog.maxModelsPerProvider),
      );
      expect(
        catalog.providers.fold<int>(
          0,
          (total, provider) => total + provider.models.length,
        ),
        lessThanOrEqualTo(DesktopModelCatalog.maxModels),
      );
      expect(
        () => catalog.providers.add(catalog.providers.first),
        throwsUnsupportedError,
      );
      expect(
        () => catalog.providers.first.models.add('mutation'),
        throwsUnsupportedError,
      );
      expect(
        () => catalog.providers.first.capabilities['mutation'] =
            const DesktopModelCapabilities(fast: true),
        throwsUnsupportedError,
      );
    });

    test('payload raíz malformado degrada a catálogo vacío', () {
      expect(DesktopModelCatalog.fromJson(null).providers, isEmpty);
      expect(DesktopModelCatalog.fromJson('invalid').providers, isEmpty);
      expect(
        DesktopModelCatalog.fromJson({'providers': 'invalid'}).providers,
        isEmpty,
      );
    });
  });
}
