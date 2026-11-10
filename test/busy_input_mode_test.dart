import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/busy_input_mode.dart';

void main() {
  test('normalizes like Hermes, including unknown or absent modes', () {
    expect(normalizeBusyInputMode(' STEER '), BusyInputMode.steer);
    expect(normalizeBusyInputMode(' Queue '), BusyInputMode.queue);
    for (final value in [null, false, 'unexpected', 'interrupt', '']) {
      expect(normalizeBusyInputMode(value), BusyInputMode.interrupt);
    }
  });

  test(
    'profile and connection switches cannot borrow another owner mode',
    () async {
      final cache = BusyInputModeCache();
      Future<void> load(String connection, String profile, String mode) =>
          cache.refresh(
            connection,
            profile,
            () async => {
              'display': {'busy_input_mode': mode},
            },
          );
      expect(cache.mode('first', 'default'), BusyInputMode.queue);
      await load('first', 'default', 'interrupt');
      await load('first', 'research', 'steer');
      await load('second', 'research', 'queue');
      expect(cache.mode('first', ''), BusyInputMode.interrupt);
      expect(cache.mode('first', 'research'), BusyInputMode.steer);
      expect(cache.mode('second', 'research'), BusyInputMode.queue);
      await load('first', 'research', 'interrupt');
      expect(cache.mode('first', 'research'), BusyInputMode.interrupt);
      expect(cache.mode('second', 'research'), BusyInputMode.queue);
    },
  );

  test(
    'failed refresh falls back to queue without retaining an interrupt',
    () async {
      final cache = BusyInputModeCache();
      await cache.refresh(
        'connection',
        'default',
        () async => {
          'display': {'busy_input_mode': 'interrupt'},
        },
      );
      await cache.refresh(
        'connection',
        'default',
        () async => throw StateError('offline'),
      );
      expect(cache.mode('connection', 'default'), BusyInputMode.queue);
    },
  );

  test(
    'stale successful or failed reads cannot replace a newer snapshot',
    () async {
      final cache = BusyInputModeCache();
      final slow = Completer<Map<String, dynamic>>();
      final first = cache.refresh('connection', 'default', () => slow.future);
      await cache.refresh(
        'connection',
        'default',
        () async => {
          'display': {'busy_input_mode': 'steer'},
        },
      );
      slow.complete({
        'display': {'busy_input_mode': 'interrupt'},
      });
      await first;
      expect(cache.mode('connection', 'default'), BusyInputMode.steer);
      final failure = Completer<Map<String, dynamic>>();
      final second = cache.refresh(
        'connection',
        'default',
        () => failure.future,
      );
      await cache.refresh('connection', 'default', () async => {});
      failure.completeError(StateError('old read'));
      await second;
      expect(cache.mode('connection', 'default'), BusyInputMode.interrupt);
    },
  );
}
