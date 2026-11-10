import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:hermes_android/core/services/mission_snapshot_prewarm.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/inter_font.dart';
import '../support/spec070_fixtures.dart';

/// Counts loads/closes; load() waits for the test to release it.
final class _CountingSource implements MissionControlDataSource {
  _CountingSource({this.fails = false});
  final bool fails;
  var loads = 0;
  var closes = 0;
  Completer<void> gate = Completer<void>();

  @override
  Future<MissionBackendSnapshot> load() async {
    loads++;
    await gate.future;
    if (fails) throw StateError('offline');
    return MissionBackendSnapshot(
      profiles: spec070Profiles(),
      profilesCapability: MissionCapabilityState.available,
      loadedAt: DateTime(2026),
    );
  }

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;
  @override
  void close() => closes++;
}

final _connection = SavedConnection(
  id: 'warm',
  label: 'Warm',
  host: 'localhost',
  port: 8642,
  apiKey: 'k',
);

Finder get _rosterRows => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('roster-'),
);

void main() {
  setUpAll(loadInterFont);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<SharedPreferences> prefsWith({required bool opened}) async {
    SharedPreferences.setMockInitialValues({
      if (opened) MissionSnapshotPrewarm.flagKey(_connection.id): true,
    });
    return SharedPreferences.getInstance();
  }

  group('MissionSnapshotPrewarm', () {
    testWidgets('flag unset: nothing is read', (tester) async {
      final prefs = await prefsWith(opened: false);
      final source = _CountingSource();
      var built = 0;
      final warm = MissionSnapshotPrewarm(
        cache: MissionSnapshotCache(),
        sourceFactory: (_) {
          built++;
          return source;
        },
      );
      warm.schedule(
        prefs: prefs,
        connection: _connection,
        stillIdle: () => true,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(built, 0);
      expect(source.loads, 0);
    });

    testWidgets('flag set: one idle read fills the cache, once per process', (
      tester,
    ) async {
      final prefs = await prefsWith(opened: true);
      final cache = MissionSnapshotCache();
      final source = _CountingSource()..gate.complete();
      final warm = MissionSnapshotPrewarm(
        cache: cache,
        sourceFactory: (_) => source,
      );
      warm.schedule(
        prefs: prefs,
        connection: _connection,
        stillIdle: () => true,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(source.loads, 0, reason: 'waits for Home to be idle');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(source.loads, 1);
      expect(cache.read(_connection), isNotNull);
      expect(source.closes, 1, reason: 'its sockets are released');

      cache.clear();
      warm.schedule(
        prefs: prefs,
        connection: _connection,
        stillIdle: () => true,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(source.loads, 1, reason: 'never periodic');
    });

    testWidgets('homeNeedsIt: the board has Bots/Salas, no flag needed', (
      tester,
    ) async {
      final prefs = await prefsWith(opened: false);
      final cache = MissionSnapshotCache();
      final source = _CountingSource()..gate.complete();
      final warm = MissionSnapshotPrewarm(
        cache: cache,
        sourceFactory: (_) => source,
      );
      warm.schedule(
        prefs: prefs,
        connection: _connection,
        stillIdle: () => true,
        homeNeedsIt: true,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(source.loads, 1);
      expect(cache.read(_connection), isNotNull);
    });

    testWidgets('a failed warm read does not use up the process', (
      tester,
    ) async {
      final prefs = await prefsWith(opened: true);
      final cache = MissionSnapshotCache();
      final source = _CountingSource(fails: true)..gate.complete();
      var clock = DateTime(2026, 1, 1, 12);
      final warm = MissionSnapshotPrewarm(
        cache: cache,
        sourceFactory: (_) => source,
        now: () => clock,
      );
      warm.schedule(
        prefs: prefs,
        connection: _connection,
        stillIdle: () => true,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(source.loads, 1);
      expect(cache.read(_connection), isNull);
      // Same limiter as Home: a failing server is not re-read 2 s later.
      clock = clock.add(const Duration(seconds: 10));
      warm.schedule(
        prefs: prefs,
        connection: _connection,
        stillIdle: () => true,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(source.loads, 1, reason: 'inside the minute');
      clock = clock.add(const Duration(minutes: 1));
      warm.schedule(
        prefs: prefs,
        connection: _connection,
        stillIdle: () => true,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(source.loads, 2, reason: 'the failure left the next try open');
    });

    group('Home refresh: schedule() then refreshForHome() each time', () {
      // Mirrors home_dashboard_screen: _scheduleMissionPrewarm followed by
      // _refreshBoardExtras on every ~10 s status refresh.
      Future<void> homeRefresh(
        WidgetTester tester,
        MissionSnapshotPrewarm warm,
        SharedPreferences prefs,
        DateTime Function() clock,
      ) async {
        warm.schedule(
          prefs: prefs,
          connection: _connection,
          stillIdle: () => true,
          homeNeedsIt: true,
        );
        warm.refreshForHome(connection: _connection, now: clock);
        await tester.pump(const Duration(seconds: 10));
      }

      testWidgets('a slow read finishes and is not relaunched', (tester) async {
        final prefs = await prefsWith(opened: false);
        final cache = MissionSnapshotCache();
        final sources = <_CountingSource>[];
        var clock = DateTime(2026, 1, 1, 12);
        final warm = MissionSnapshotPrewarm(
          cache: cache,
          sourceFactory: (_) {
            final source = _CountingSource();
            sources.add(source);
            return source;
          },
          now: () => clock,
        );
        for (var i = 0; i < 5; i++) {
          await homeRefresh(tester, warm, prefs, () => clock);
          clock = clock.add(const Duration(seconds: 10));
        }
        expect(sources, hasLength(1), reason: 'one read, never relaunched');
        expect(sources.single.closes, 0, reason: 'never cancelled');
        sources.single.gate.complete();
        await tester.pump();
        expect(cache.read(_connection), isNotNull, reason: 'it finished');
        await homeRefresh(tester, warm, prefs, () => clock);
        expect(sources, hasLength(1), reason: 'still inside the minute');
      });

      testWidgets('a failing server is read at most once a minute', (
        tester,
      ) async {
        final prefs = await prefsWith(opened: false);
        final source = _CountingSource(fails: true)..gate.complete();
        var clock = DateTime(2026, 1, 1, 12);
        final warm = MissionSnapshotPrewarm(
          cache: MissionSnapshotCache(),
          sourceFactory: (_) => source,
          now: () => clock,
        );
        for (var i = 0; i < 6; i++) {
          await homeRefresh(tester, warm, prefs, () => clock);
          clock = clock.add(const Duration(seconds: 10));
        }
        expect(source.loads, 1, reason: 'no 2 s idle-timer retry either');
        await homeRefresh(tester, warm, prefs, () => clock);
        expect(source.loads, 2, reason: 'a minute later');
      });
    });

    group('refreshForHome', () {
      test('reads, then waits a minute, then reads again', () async {
        final cache = MissionSnapshotCache();
        final source = _CountingSource()..gate.complete();
        final warm = MissionSnapshotPrewarm(
          cache: cache,
          sourceFactory: (_) => source,
        );
        var clock = DateTime(2026, 1, 1, 12);
        warm.refreshForHome(connection: _connection, now: () => clock);
        await Future<void>.delayed(Duration.zero);
        expect(source.loads, 1);
        expect(cache.read(_connection), isNotNull);

        clock = clock.add(const Duration(seconds: 30));
        warm.refreshForHome(connection: _connection, now: () => clock);
        await Future<void>.delayed(Duration.zero);
        expect(source.loads, 1, reason: 'inside the minute');

        clock = clock.add(const Duration(seconds: 31));
        warm.refreshForHome(connection: _connection, now: () => clock);
        await Future<void>.delayed(Duration.zero);
        expect(
          source.loads,
          2,
          reason: 'the snapshot is old and a minute passed',
        );
      });

      test('a fresh cached snapshot (Bot Mode just read) is not re-read', () {
        final cache = MissionSnapshotCache();
        final source = _CountingSource()..gate.complete();
        final warm = MissionSnapshotPrewarm(
          cache: cache,
          sourceFactory: (_) => source,
        );
        final clock = DateTime(2026, 1, 1, 12);
        cache.write(
          _connection,
          MissionBackendSnapshot(
            profiles: spec070Profiles(),
            profilesCapability: MissionCapabilityState.available,
            loadedAt: clock.subtract(const Duration(seconds: 20)),
          ),
        );
        warm.refreshForHome(connection: _connection, now: () => clock);
        expect(source.loads, 0);
      });

      test('a failed read is retried only after the minute', () async {
        final source = _CountingSource(fails: true)..gate.complete();
        final warm = MissionSnapshotPrewarm(
          cache: MissionSnapshotCache(),
          sourceFactory: (_) => source,
        );
        var clock = DateTime(2026, 1, 1, 12);
        warm.refreshForHome(connection: _connection, now: () => clock);
        await Future<void>.delayed(Duration.zero);
        clock = clock.add(const Duration(seconds: 10));
        warm.refreshForHome(connection: _connection, now: () => clock);
        await Future<void>.delayed(Duration.zero);
        expect(source.loads, 1, reason: 'no read every 10 s while offline');
        clock = clock.add(const Duration(seconds: 55));
        warm.refreshForHome(connection: _connection, now: () => clock);
        await Future<void>.delayed(Duration.zero);
        expect(source.loads, 2);
      });

      test('a read in flight is not started twice', () async {
        final source = _CountingSource();
        final warm = MissionSnapshotPrewarm(
          cache: MissionSnapshotCache(),
          sourceFactory: (_) => source,
        );
        var clock = DateTime(2026, 1, 1, 12);
        warm.refreshForHome(connection: _connection, now: () => clock);
        clock = clock.add(const Duration(minutes: 5));
        warm.refreshForHome(connection: _connection, now: () => clock);
        await Future<void>.delayed(Duration.zero);
        expect(source.loads, 1);
        source.gate.complete();
        await Future<void>.delayed(Duration.zero);
      });

      test('cancel (background) lets the next refresh retry at once', () async {
        final source = _CountingSource();
        final warm = MissionSnapshotPrewarm(
          cache: MissionSnapshotCache(),
          sourceFactory: (_) => source,
        );
        final clock = DateTime(2026, 1, 1, 12);
        warm.refreshForHome(connection: _connection, now: () => clock);
        await Future<void>.delayed(Duration.zero);
        warm.cancel();
        source.gate.complete();
        warm.refreshForHome(connection: _connection, now: () => clock);
        await Future<void>.delayed(Duration.zero);
        expect(source.loads, 2);
      });
    });

    testWidgets('not idle when the timer fires (background/other screen)', (
      tester,
    ) async {
      final prefs = await prefsWith(opened: true);
      final source = _CountingSource()..gate.complete();
      final warm = MissionSnapshotPrewarm(
        cache: MissionSnapshotCache(),
        sourceFactory: (_) => source,
      );
      warm.schedule(
        prefs: prefs,
        connection: _connection,
        stillIdle: () => false,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(source.loads, 0);
    });

    testWidgets(
      'cancel (background/connection change) drops an in-flight read',
      (tester) async {
        final prefs = await prefsWith(opened: true);
        final cache = MissionSnapshotCache();
        final source = _CountingSource();
        final warm = MissionSnapshotPrewarm(
          cache: cache,
          sourceFactory: (_) => source,
        );
        warm.schedule(
          prefs: prefs,
          connection: _connection,
          stillIdle: () => true,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(source.loads, 1);
        warm.cancel();
        expect(source.closes, 1, reason: 'the read is torn down');
        source.gate.complete();
        await tester.pump();
        expect(
          cache.read(_connection),
          isNull,
          reason: 'nothing late is cached',
        );
      },
    );

    testWidgets('cancel before the timer fires: no read at all', (
      tester,
    ) async {
      final prefs = await prefsWith(opened: true);
      final source = _CountingSource()..gate.complete();
      final warm = MissionSnapshotPrewarm(
        cache: MissionSnapshotCache(),
        sourceFactory: (_) => source,
      );
      warm.schedule(
        prefs: prefs,
        connection: _connection,
        stillIdle: () => true,
      );
      await tester.pump(const Duration(seconds: 1));
      warm.cancel();
      await tester.pump(const Duration(seconds: 5));
      expect(source.loads, 0);
    });
  });

  group('Bot Mode with a prewarm', () {
    Widget screen(
      ConnectionManager manager,
      MissionControlDataSource source,
      MissionSnapshotCache cache,
      MissionSnapshotPrewarm warm,
    ) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: MissionControlScreen(
        connection: _connection,
        connManager: manager,
        dataSource: source,
        snapshotCache: cache,
        prewarm: warm,
      ),
    );

    testWidgets('opening Bot Mode records the flag for this connection', (
      tester,
    ) async {
      final prefs = await prefsWith(opened: false);
      final manager = await ConnectionManager.create(prefs);
      addTearDown(manager.dispose);
      final cache = MissionSnapshotCache();
      final source = _CountingSource()..gate.complete();
      final warm = MissionSnapshotPrewarm(
        cache: cache,
        sourceFactory: (_) => _CountingSource(),
      );
      await tester.pumpWidget(screen(manager, source, cache, warm));
      await tester.pump();
      expect(MissionSnapshotPrewarm.wasOpened(prefs, _connection.id), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'cold start, prewarm done: first frame shows the roster and refreshes',
      (tester) async {
        final prefs = await prefsWith(opened: true);
        final manager = await ConnectionManager.create(prefs);
        addTearDown(manager.dispose);
        final cache = MissionSnapshotCache();
        final warmSource = _CountingSource()..gate.complete();
        final warm = MissionSnapshotPrewarm(
          cache: cache,
          sourceFactory: (_) => warmSource,
        );
        warm.schedule(
          prefs: prefs,
          connection: _connection,
          stillIdle: () => true,
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(warmSource.loads, 1);

        final source = _CountingSource();
        await tester.pumpWidget(screen(manager, source, cache, warm));
        expect(find.text('Loading profiles…'), findsNothing);
        expect(_rosterRows, findsWidgets);
        expect(source.loads, 1, reason: 'still refreshes in the background');
        source.gate.complete();
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('opening during an in-flight prewarm reuses the same read', (
      tester,
    ) async {
      final prefs = await prefsWith(opened: true);
      final manager = await ConnectionManager.create(prefs);
      addTearDown(manager.dispose);
      final cache = MissionSnapshotCache();
      final warmSource = _CountingSource();
      final warm = MissionSnapshotPrewarm(
        cache: cache,
        sourceFactory: (_) => warmSource,
      );
      warm.schedule(
        prefs: prefs,
        connection: _connection,
        stillIdle: () => true,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(warmSource.loads, 1);

      final source = _CountingSource();
      await tester.pumpWidget(screen(manager, source, cache, warm));
      await tester.pump();
      expect(source.loads, 0, reason: 'no second read while one is in flight');
      warmSource.gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('Loading profiles…'), findsNothing);
      expect(_rosterRows, findsWidgets);
      expect(warmSource.loads + source.loads, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed in-flight prewarm falls back to a normal read', (
      tester,
    ) async {
      final prefs = await prefsWith(opened: true);
      final manager = await ConnectionManager.create(prefs);
      addTearDown(manager.dispose);
      final cache = MissionSnapshotCache();
      final warmSource = _CountingSource(fails: true);
      final warm = MissionSnapshotPrewarm(
        cache: cache,
        sourceFactory: (_) => warmSource,
      );
      warm.schedule(
        prefs: prefs,
        connection: _connection,
        stillIdle: () => true,
      );
      await tester.pump(const Duration(seconds: 2));
      final source = _CountingSource()..gate.complete();
      await tester.pumpWidget(screen(manager, source, cache, warm));
      warmSource.gate.complete();
      await tester.pump();
      await tester.pump();
      expect(source.loads, 1);
      expect(_rosterRows, findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
