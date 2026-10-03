import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';

void main() {
  group('DesktopModelSelection', () {
    test('construye el valor session-scoped exacto', () {
      final selection = DesktopModelSelection(
        modelId: 'openai/gpt-5.5-codex',
        providerSlug: 'openai-codex',
      );

      expect(
        selection.sessionWireValue,
        'openai/gpt-5.5-codex --provider openai-codex --session',
      );
    });

    test('rechaza whitespace, controles y delimitadores de flags', () {
      for (final model in [
        'gpt-5 --provider hostile',
        'gpt-5\nnext',
        'model\tvalue',
      ]) {
        expect(
          () => DesktopModelSelection(modelId: model, providerSlug: 'provider'),
          throwsFormatException,
        );
      }
      expect(
        () => DesktopModelSelection(
          modelId: 'gpt-5',
          providerSlug: 'provider --session',
        ),
        throwsFormatException,
      );
    });
  });

  group('DesktopConfigSetResult', () {
    test('acepta una confirmación session-scoped válida', () {
      final result = DesktopConfigSetResult.fromJson(const {
        'key': 'model',
        'value': 'current-model',
        'scope': 'session',
        'confirm_required': true,
        'confirm_message': 'This model may be expensive',
      }, expectedKey: DesktopSessionConfigKey.model);

      expect(result.confirmRequired, isTrue);
      expect(result.confirmMessage, 'This model may be expensive');
    });

    test('rechaza scope global, clave cruzada y confirmación malformada', () {
      expect(
        () => DesktopConfigSetResult.fromJson(const {
          'key': 'model',
          'value': 'gpt-5',
          'scope': 'global',
        }, expectedKey: DesktopSessionConfigKey.model),
        throwsFormatException,
      );
      expect(
        () => DesktopConfigSetResult.fromJson(const {
          'key': 'fast',
          'value': 'fast',
          'scope': 'session',
        }, expectedKey: DesktopSessionConfigKey.reasoning),
        throwsFormatException,
      );
    });

    test('a guard without its own text still asks, using the warning', () {
      // ConfigSetResult types confirm_message `str | null`; Desktop opens the
      // confirmation dialog whatever it carries (use-model-controls.ts).
      final fromWarning = DesktopConfigSetResult.fromJson(const {
        'key': 'model',
        'value': 'gpt-5',
        'confirm_required': true,
        'warning': 'Expensive model',
        'confirm_message': null,
      }, expectedKey: DesktopSessionConfigKey.model);
      expect(fromWarning.confirmRequired, isTrue);
      expect(fromWarning.confirmMessage, 'Expensive model');

      final bare = DesktopConfigSetResult.fromJson(const {
        'key': 'model',
        'value': 'gpt-5',
        'confirm_required': true,
      }, expectedKey: DesktopSessionConfigKey.model);
      expect(bare.confirmRequired, isTrue);
      expect(bare.confirmMessage, isNull);
    });
  });

  test('reasoning y fast solo exponen valores deterministas 0.19', () {
    expect(DesktopReasoningEffort.values.map((value) => value.wire), [
      'none',
      'minimal',
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
      'ultra',
    ]);
    expect(DesktopFastMode.values.map((value) => value.wire), [
      'fast',
      'normal',
    ]);
    expect(DesktopFastMode.fast.enabled, isTrue);
    expect(DesktopFastMode.normal.enabled, isFalse);
  });

  test('create config distingue herencia de fast normal explícito', () {
    const inherited = DesktopSessionCreateConfig();
    const normal = DesktopSessionCreateConfig(
      reasoningEffort: DesktopReasoningEffort.high,
      fastMode: DesktopFastMode.normal,
    );

    expect(inherited.isEmpty, isTrue);
    expect(normal.isEmpty, isFalse);
    expect(normal.fastMode?.enabled, isFalse);
    expect(normal, isNot(inherited));
  });

  test('create config conserva la identidad de un Bot Chat oculto', () {
    const config = DesktopSessionCreateConfig(title: 'Bot Chat', hidden: true);

    expect(config.isEmpty, isFalse);
    expect(config.title, 'Bot Chat');
    expect(config.hidden, isTrue);
    expect(config, isNot(const DesktopSessionCreateConfig()));
  });

  test('un pin oficial ausente se marca como no-creable', () {
    const config = DesktopSessionCreateConfig(
      createIfMissing: false,
      allowTransportFallback: false,
    );

    expect(config.isEmpty, isFalse);
    expect(config.createIfMissing, isFalse);
    expect(config.allowTransportFallback, isFalse);
    expect(config, isNot(const DesktopSessionCreateConfig()));
  });

  test('Room puede crear pero prohíbe degradar el transporte', () {
    const config = DesktopSessionCreateConfig(
      title: '#homelab',
      createIfMissing: true,
      allowTransportFallback: false,
    );

    expect(config.isEmpty, isFalse);
    expect(config.createIfMissing, isTrue);
    expect(config.allowTransportFallback, isFalse);
  });
}
