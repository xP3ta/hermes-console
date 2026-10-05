import 'dart:async';

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

  test('concurrent merges on one connection keep both dimensions', () async {
    final prefs = _CommitLaterPrefs();
    final reasoning = ModelPresetsStore(prefs, connectionId: 'server-a');
    final fast = ModelPresetsStore(prefs, connectionId: 'server-a');

    await Future.wait([
      reasoning.merge('nous', 'model-a', effort: DesktopReasoningEffort.high),
      fast.merge('nous', 'model-a', fast: DesktopFastMode.fast),
      reasoning.merge('nous', 'model-b', fast: DesktopFastMode.fast),
    ]);

    const expected = ModelPreset(
      effort: DesktopReasoningEffort.high,
      fast: DesktopFastMode.fast,
    );
    expect(reasoning.read('nous', 'model-a'), expected);
    expect(
      fast.read('nous', 'model-b'),
      const ModelPreset(fast: DesktopFastMode.fast),
    );
    final reread = ModelPresetsStore(prefs, connectionId: 'server-a');
    expect(reread.read('nous', 'model-a'), expected);
  });

  test('a merge queued behind a restore sees the restored value', () async {
    final prefs = _CommitLaterPrefs();
    final store = ModelPresetsStore(prefs, connectionId: 'server-a');
    await store.merge('nous', 'model-a', effort: DesktopReasoningEffort.low);

    await Future.wait([
      store.restore('nous', 'model-a', null),
      store.merge('nous', 'model-a', fast: DesktopFastMode.fast),
    ]);

    expect(
      store.read('nous', 'model-a'),
      const ModelPreset(fast: DesktopFastMode.fast),
    );
  });

  test(
    'a failed write does not poison later writes on the connection',
    () async {
      final prefs = _FailOnceCommitLaterPrefs();
      final store = ModelPresetsStore(prefs, connectionId: 'server-a');
      final uncaught = <Object>[];
      final outcome = Completer<(Object?, Object?)>();

      runZonedGuarded(() async {
        final first = store.merge(
          'nous',
          'model-a',
          effort: DesktopReasoningEffort.high,
        );
        final second = store.merge(
          'nous',
          'model-a',
          fast: DesktopFastMode.fast,
        );
        Object? firstError;
        Object? secondError;
        try {
          await first;
        } catch (error) {
          firstError = error;
        }
        try {
          await second;
        } catch (error) {
          secondError = error;
        }
        outcome.complete((firstError, secondError));
      }, (error, _) => uncaught.add(error));

      final (firstError, secondError) = await outcome.future;
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(firstError, same(prefs.failure));
      expect(secondError, isNull);
      expect(
        store.read('nous', 'model-a'),
        const ModelPreset(fast: DesktopFastMode.fast),
      );
      expect(uncaught, isEmpty);
    },
  );

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

/// Commits writes after an async gap, like a store without a synchronous
/// in-memory cache: a read issued before the commit sees the old blob.
final class _CommitLaterPrefs implements SharedPreferences {
  final Map<String, String> _committed = {};

  @override
  String? getString(String key) => _committed[key];

  @override
  Future<bool> setString(String key, String value) async {
    await Future<void>.delayed(Duration.zero);
    _committed[key] = value;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fails the first write, then behaves like [_CommitLaterPrefs].
final class _FailOnceCommitLaterPrefs extends _CommitLaterPrefs {
  final StateError failure = StateError('disk full');
  bool _failed = false;

  @override
  Future<bool> setString(String key, String value) async {
    if (!_failed) {
      _failed = true;
      await Future<void>.delayed(Duration.zero);
      throw failure;
    }
    return super.setString(key, value);
  }
}
