import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/services/account_limits_controller.dart';

AccountUsageLimits _limits(double used) => AccountUsageLimits.fromGateway({
  'account_lines': ['Weekly: ${100 - used}% remaining ($used% used)'],
});

void main() {
  setUp(AccountLimitsController.debugClearCache);

  test('refresh loads and publishes', () async {
    var calls = 0;
    final c = AccountLimitsController(
      cacheKey: 'conn|s1',
      load: () async {
        calls++;
        return _limits(40);
      },
      isLocked: () => false,
    );
    addTearDown(c.dispose);
    expect(c.limits.value, isNull);
    await c.refresh();
    expect(calls, 1);
    expect(c.limits.value!.lines.single.usedPercent, 40);
  });

  test('nothing is fetched while App Lock is locked', () async {
    var calls = 0;
    var locked = true;
    final c = AccountLimitsController(
      cacheKey: 'conn|s1',
      load: () async {
        calls++;
        return _limits(40);
      },
      isLocked: () => locked,
    );
    addTearDown(c.dispose);
    await c.refresh();
    await c.refresh(afterTurn: true);
    expect(calls, 0);
    expect(c.limits.value, isNull);
    locked = false;
    await c.refresh();
    expect(calls, 1);
  });

  test('cache is per session and survives a new controller', () async {
    final a = AccountLimitsController(
      cacheKey: 'conn|s1',
      load: () async => _limits(85),
      isLocked: () => false,
    );
    await a.refresh();
    a.dispose();
    final again = AccountLimitsController(
      cacheKey: 'conn|s1',
      load: () async => null,
      isLocked: () => false,
    );
    addTearDown(again.dispose);
    expect(again.limits.value!.lines.single.usedPercent, 85);
    final other = AccountLimitsController(
      cacheKey: 'conn|s2',
      load: () async => null,
      isLocked: () => false,
    );
    addTearDown(other.dispose);
    expect(other.limits.value, isNull);
  });

  test('a failed or unavailable load keeps the last known value', () async {
    var next = Future<AccountUsageLimits?>.value(_limits(30));
    final c = AccountLimitsController(
      cacheKey: 'conn|s1',
      load: () => next,
      isLocked: () => false,
    );
    addTearDown(c.dispose);
    await c.refresh();
    next = Future<AccountUsageLimits?>.value(null);
    await c.refresh();
    expect(c.limits.value!.lines.single.usedPercent, 30);
    next = Future<AccountUsageLimits?>.error(StateError('offline'));
    await c.refresh();
    expect(c.limits.value!.lines.single.usedPercent, 30);
  });

  test(
    'an empty answer clears the section (provider without limits)',
    () async {
      var next = _limits(30);
      final c = AccountLimitsController(
        cacheKey: 'conn|s1',
        load: () async => next,
        isLocked: () => false,
      );
      addTearDown(c.dispose);
      await c.refresh();
      next = AccountUsageLimits.fromGateway(const {'calls': 1});
      await c.refresh();
      expect(c.limits.value!.isEmpty, isTrue);
    },
  );

  test('concurrent refreshes share one request', () async {
    var calls = 0;
    final gate = Completer<AccountUsageLimits?>();
    final c = AccountLimitsController(
      cacheKey: 'conn|s1',
      load: () {
        calls++;
        return gate.future;
      },
      isLocked: () => false,
    );
    addTearDown(c.dispose);
    final first = c.refresh();
    final second = c.refresh();
    gate.complete(_limits(10));
    await Future.wait([first, second]);
    expect(calls, 1);
  });

  test(
    'after-turn refreshes are throttled; opening the sheet is not',
    () async {
      var calls = 0;
      var now = DateTime(2026, 10, 6, 12);
      final c = AccountLimitsController(
        cacheKey: 'conn|s1',
        load: () async {
          calls++;
          return _limits(10);
        },
        isLocked: () => false,
        now: () => now,
      );
      addTearDown(c.dispose);
      await c.refresh(afterTurn: true);
      expect(calls, 1);
      now = now.add(const Duration(seconds: 30));
      await c.refresh(afterTurn: true);
      expect(calls, 1);
      await c.refresh();
      expect(calls, 2);
      now = now.add(const Duration(seconds: 61));
      await c.refresh(afterTurn: true);
      expect(calls, 3);
    },
  );

  test('a result arriving after dispose is dropped', () async {
    final gate = Completer<AccountUsageLimits?>();
    final c = AccountLimitsController(
      cacheKey: 'conn|s1',
      load: () => gate.future,
      isLocked: () => false,
    );
    final pending = c.refresh();
    c.dispose();
    gate.complete(_limits(10));
    await pending;
  });
}
