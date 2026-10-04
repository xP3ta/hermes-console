import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/services/model_presets_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('uses provider::model keys and merges dimensions', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ModelPresetsStore(prefs, connectionId: 'server-a');

    expect(modelPresetKey('nous', 'model-a'), 'nous::model-a');
    await store.merge('nous', 'model-a', effort: DesktopReasoningEffort.high);
    await store.merge('nous', 'model-a', fast: DesktopFastMode.fast);

    expect(
      store.read('nous', 'model-a'),
      const ModelPreset(
        effort: DesktopReasoningEffort.high,
        fast: DesktopFastMode.fast,
      ),
    );
  });

  test('corrupt JSON loads as empty', () async {
    SharedPreferences.setMockInitialValues({
      'model_presets_v1.server-a': '{not-json',
    });
    final prefs = await SharedPreferences.getInstance();
    final store = ModelPresetsStore(prefs, connectionId: 'server-a');

    expect(store.read('nous', 'model-a'), isNull);
  });

  test('connections are isolated', () async {
    final prefs = await SharedPreferences.getInstance();
    final first = ModelPresetsStore(prefs, connectionId: 'server-a');
    final second = ModelPresetsStore(prefs, connectionId: 'server-b');

    await first.merge('nous', 'model-a', fast: DesktopFastMode.fast);

    expect(first.read('nous', 'model-a'), isNotNull);
    expect(second.read('nous', 'model-a'), isNull);
  });

  test('applies both dimensions only when the catalog supports them', () async {
    final applied = <String>[];

    await applyModelPresetForCapabilities(
      preset: const ModelPreset(
        effort: DesktopReasoningEffort.high,
        fast: DesktopFastMode.fast,
      ),
      capabilities: const DesktopModelCapabilities(reasoning: true, fast: true),
      applyEffort: (effort) async => applied.add('reasoning:${effort.wire}'),
      applyFast: (fast) async => applied.add('fast:${fast.wire}'),
    );

    expect(applied, ['reasoning:high', 'fast:fast']);

    applied.clear();
    await applyModelPresetForCapabilities(
      preset: const ModelPreset(
        effort: DesktopReasoningEffort.high,
        fast: DesktopFastMode.fast,
      ),
      capabilities: const DesktopModelCapabilities(
        reasoning: false,
        fast: true,
      ),
      applyEffort: (effort) async => applied.add('reasoning:${effort.wire}'),
      applyFast: (fast) async => applied.add('fast:${fast.wire}'),
    );

    expect(applied, ['fast:fast']);
  });
}
