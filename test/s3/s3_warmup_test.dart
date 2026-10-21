// SPDX-License-Identifier: GPL-3.0-only
// S3: the bounded «server starting» wait (Desktop backend-health.ts:7-14,
// :126-180). Fake clock; synthetic fixtures only.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/native_session_store.dart';
import 'package:hermes_android/core/services/server_warmup.dart';

class _Clock {
  DateTime t = DateTime.utc(2026, 10, 18);
  DateTime now() => t;
  int calls = 0;
  Future<void> delay(Duration d) async {
    // A wait without a limit would spin here forever: fail fast instead.
    if (++calls > 400) throw StateError('runaway wait');
    t = t.add(d);
    await Future<void>.value();
  }
}

void main() {
  group('classification', () {
    test('502/503/504 are starting; 401/403/500/404 never are', () {
      for (final code in [502, 503, 504]) {
        expect(isServerStartingError(DashboardHttpException(code)), isTrue);
        expect(
          isServerStartingError(
            DashboardWebSocketAuthException(
              DashboardWebSocketAuthFailureCode.unavailable,
              statusCode: code,
            ),
          ),
          isTrue,
        );
      }
      for (final code in [401, 403, 404, 500, 429]) {
        expect(isServerStartingError(DashboardHttpException(code)), isFalse);
        expect(
          isServerStartingError(
            DashboardWebSocketAuthException(
              DashboardWebSocketAuthFailureCode.unavailable,
              statusCode: code,
            ),
          ),
          isFalse,
        );
      }
    });

    test('a refresh 503 (transient) is neither starting nor reauth', () {
      expect(isServerStartingError(const NativeRefreshTransient()), isFalse);
      expect(isServerStartingError(const NativeSessionExpired()), isFalse);
      expect(
        isServerStartingError(
          DashboardAuthException(DashboardAuthFailureCode.loginRequired),
        ),
        isFalse,
      );
    });

    test('refused connection is a restart only after a good answer', () {
      const refused = SocketException(
        'x',
        osError: OSError('Connection refused', 111),
      );
      expect(isConnectionRefused(refused), isTrue);
      expect(isConnectionRefused(const SocketException('x')), isFalse);
      expect(isConnectionRefused(StateError('x')), isFalse);
    });

    test('Nous Cloud hosts only', () {
      expect(isNousCloudHost('ares-3009.agents.nousresearch.com'), isTrue);
      expect(isNousCloudHost('agents.nousresearch.com'), isFalse);
      expect(isNousCloudHost('example.com'), isFalse);
      expect(
        isNousCloudHost('evil-agents.nousresearch.com.example.com'),
        false,
      );
    });
  });

  group('bounded wait', () {
    test('503 for 20 s then 200: starting, then ready, probes bounded', () async {
      final c = _Clock();
      final start = c.t;
      var probes = 0;
      final phases = <ServerWarmupPhase>[];
      final w = ServerWarmup(
        probe: () async {
          probes++;
          return c.t.difference(start) >= const Duration(seconds: 20);
        },
        now: c.now,
        delay: c.delay,
      )..addListener(() {});
      w.addListener(() => phases.add(w.phase));
      expect(await w.run(), isTrue);
      expect(w.phase, ServerWarmupPhase.ready);
      expect(phases, contains(ServerWarmupPhase.waiting));
      // 1 s steps for the first 10 s, 3 s after: 11 + 4 = 15 probes, never 20+.
      expect(probes, inInclusiveRange(12, 16));
    });

    test(
      'permanent 503: gives up at 180 s, no probes after, retry restarts',
      () async {
        final c = _Clock();
        final start = c.t;
        var probes = 0;
        final w = ServerWarmup(
          probe: () async {
            probes++;
            return false;
          },
          now: c.now,
          delay: c.delay,
        );
        expect(await w.run(), isFalse);
        expect(w.phase, ServerWarmupPhase.gaveUp);
        final elapsed = c.t.difference(start);
        expect(elapsed, greaterThanOrEqualTo(const Duration(seconds: 180)));
        expect(elapsed, lessThan(const Duration(seconds: 184)));
        final atGiveUp = probes;
        expect(atGiveUp, lessThanOrEqualTo(10 + 1 + (170 ~/ 3) + 2));
        // Nothing is scheduled any more.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        c.t = c.t.add(const Duration(minutes: 10));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(probes, atGiveUp);
        // Retry starts a fresh wait.
        expect(await w.run(), isFalse);
        expect(probes, greaterThan(atGiveUp));
        expect(w.phase, ServerWarmupPhase.gaveUp);
      },
    );

    test(
      'background: no probe while hidden, paused time is not counted',
      () async {
        final c = _Clock();
        var probes = 0;
        late ServerWarmup w;
        w = ServerWarmup(
          probe: () async {
            probes++;
            if (probes == 3) w.setForeground(false);
            return probes >= 5;
          },
          now: c.now,
          delay: c.delay,
        );
        final done = w.run();
        await pumpEventQueue();
        expect(probes, 3, reason: 'hidden: the loop must stop probing');
        // An hour passes while hidden; it must not eat the 180 s budget.
        c.t = c.t.add(const Duration(hours: 1));
        await pumpEventQueue();
        expect(probes, 3);
        expect(w.phase, ServerWarmupPhase.waiting);
        w.setForeground(true);
        expect(await done, isTrue);
        expect(probes, 5);
      },
    );

    test(
      'hidden time is not counted but the active time before it is',
      () async {
        final c = _Clock();
        final start = c.t;
        var probes = 0;
        late ServerWarmup w;
        w = ServerWarmup(
          probe: () async {
            probes++;
            if (probes == 20) w.setForeground(false);
            return false;
          },
          now: c.now,
          delay: c.delay,
        );
        final done = w.run();
        await pumpEventQueue();
        expect(probes, 20);
        c.t = c.t.add(const Duration(hours: 1));
        w.setForeground(true);
        expect(await done, isFalse);
        final active = c.t.difference(start) - const Duration(hours: 1);
        expect(active, greaterThanOrEqualTo(const Duration(seconds: 180)));
        expect(active, lessThan(const Duration(seconds: 184)));
      },
    );

    test('starts hidden: 0 probes until the app is back', () async {
      final c = _Clock();
      var probes = 0;
      final w = ServerWarmup(
        probe: () async {
          probes++;
          return true;
        },
        now: c.now,
        delay: c.delay,
        foreground: false,
      );
      final done = w.run();
      await pumpEventQueue();
      expect(probes, 0);
      w.setForeground(true);
      expect(await done, isTrue);
      expect(probes, 1);
    });

    test('a probe that throws or hangs counts as not ready', () async {
      final c = _Clock();
      var n = 0;
      final w = ServerWarmup(
        probe: () async {
          n++;
          if (n == 1) throw const SocketException('down');
          return true;
        },
        now: c.now,
        delay: c.delay,
      );
      expect(await w.run(), isTrue);
      expect(n, 2);
    });

    test('cancel ends the wait without a verdict', () async {
      final c = _Clock();
      late ServerWarmup w;
      var probes = 0;
      w = ServerWarmup(
        probe: () async {
          probes++;
          if (probes == 2) w.cancel();
          return false;
        },
        now: c.now,
        delay: c.delay,
      );
      expect(await w.run(), isFalse);
      expect(w.phase, ServerWarmupPhase.idle);
      expect(probes, 2);
    });
  });
}
