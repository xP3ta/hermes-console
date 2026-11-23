import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/widgets/workspace/profile_rail_chats.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The rail's reads of the profiles the list of chats is not scoped to: one
// sweep per scope at most once a minute, one request at a time, a failing
// profile skipped (its previous value kept; a few failures in a row end the
// sweep), dropped on cancel, App Lock or a new scope, and bounded in
// profiles. Another screen's cancel does not cut the sweep, and a sweep cut
// before any page does not hold the next one for a minute.

Session _session(String id, String profile) => Session(
  id: id,
  title: id,
  model: 'm',
  source: 'mobile',
  messageCount: 2,
  isActive: false,
  preview: '',
  startedAt: 1,
  profile: profile,
);

/// A loader whose answers the test releases one by one.
class _Server {
  final requests = <String>[];
  final pending = <String, Completer<ProfileRailPage>>{};
  int inFlight = 0;
  int maxInFlight = 0;

  Future<ProfileRailPage> load(String owner) {
    requests.add(owner);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    final done = Completer<ProfileRailPage>();
    pending[owner] = done;
    return done.future.whenComplete(() => inFlight--);
  }

  Future<void> answer(
    String owner, {
    int rows = 2,
    bool more = false,
    Object? error,
  }) async {
    final done = pending.remove(owner)!;
    if (error != null) {
      done.completeError(error);
    } else {
      done.complete(
        ProfileRailPage(
          sessions: [
            for (var i = 1; i <= rows; i++) _session('$owner-$i', owner),
          ],
          more: more,
        ),
      );
    }
    await pumpEventQueue();
  }
}

void main() {
  late DateTime now;
  ProfileRailChats store({int maxProfiles = 16}) => ProfileRailChats(
    spacing: Duration.zero,
    maxProfiles: maxProfiles,
    now: () => now,
  );

  setUp(() => now = DateTime(2026, 11, 8, 12));

  test('one request at a time, in the order given; the pages are shown '
      'together when the sweep ends, with one notification', () async {
    final server = _Server();
    final rail = store();
    var notified = 0;
    rail.addListener(() => notified++);
    rail.refresh(
      scope: 'chats',
      owners: const ['forja', 'pi', 'oficina'],
      load: server.load,
    );
    expect(notified, 0, reason: 'never notifies inside the call');
    await pumpEventQueue();
    expect(server.requests, ['forja']);
    await server.answer('forja', rows: 3, more: true);
    // Read, not shown yet: a count per answer made the strip fill in one
    // face at a time and re-sort on each.
    expect(rail.page('chats', 'forja'), isNull);
    expect(notified, 0);
    expect(server.requests, ['forja', 'pi']);
    await server.answer('pi', rows: 1);
    expect(notified, 0);
    await server.answer('oficina', rows: 0);
    expect(server.maxInFlight, 1);
    expect(notified, 1);
    expect(rail.page('chats', 'forja')!.sessions, hasLength(3));
    expect(rail.page('chats', 'forja')!.more, isTrue);
    expect(rail.page('chats', 'pi')!.sessions, hasLength(1));
    expect(rail.page('chats', 'pi')!.more, isFalse);
    expect(rail.page('chats', 'oficina')!.sessions, isEmpty);
    expect(rail.sweeping, isFalse);
  });

  test('a later sweep keeps the previous pages on show until it ends', () async {
    final server = _Server();
    final rail = store();
    rail.refresh(scope: 'chats', owners: const ['forja', 'pi'], load: server.load);
    await pumpEventQueue();
    await server.answer('forja', rows: 2);
    await server.answer('pi', rows: 2);
    now = now.add(const Duration(minutes: 2));
    var notified = 0;
    rail.addListener(() => notified++);
    rail.refresh(scope: 'chats', owners: const ['forja', 'pi'], load: server.load);
    await pumpEventQueue();
    await server.answer('forja', rows: 5);
    expect(rail.page('chats', 'forja')!.sessions, hasLength(2));
    await server.answer('pi', rows: 6);
    expect(notified, 1);
    expect(rail.page('chats', 'forja')!.sessions, hasLength(5));
    expect(rail.page('chats', 'pi')!.sessions, hasLength(6));
  });

  test('a sweep cut short shows what it had read', () async {
    final server = _Server();
    final rail = store();
    final screen = Object();
    rail.refresh(
      scope: 'chats',
      owners: const ['forja', 'pi', 'oficina'],
      load: server.load,
      requester: screen,
    );
    await pumpEventQueue();
    await server.answer('forja', rows: 4);
    rail.cancel(screen);
    await server.answer('pi', rows: 1);
    expect(rail.page('chats', 'forja')!.sessions, hasLength(4));
    expect(rail.page('chats', 'pi'), isNull, reason: 'answered after cancel');
    expect(server.requests, ['forja', 'pi']);
  });

  group('hints kept between runs', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<ProfileRailChats> open() async {
      final rail = ProfileRailChats(
        spacing: Duration.zero,
        connectionId: 'c1',
        now: () => now,
      );
      await pumpEventQueue();
      return rail;
    }

    test('numbers only: no title and no id reach the disk', () async {
      final rail = await open();
      rail.rememberHints('chats|all', const {
        'forja': ProfileRailHint(count: 7, more: true, newestAt: 1700000500),
        'pi': ProfileRailHint(count: 0, more: false, newestAt: 0),
      });
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(ProfileRailChats.hintsKey('c1'))!;
      expect(stored, isNot(contains('chats|all')), reason: 'a digest only');
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      expect(decoded.values.single, {
        'forja': [7, true, 1700000500.0],
        'pi': [0, false, 0.0],
      });
    });

    test('a new process starts with the last counts and order', () async {
      final first = await open();
      first.rememberHints('chats|all', const {
        'forja': ProfileRailHint(count: 7, more: true, newestAt: 1700000500),
      });
      await pumpEventQueue();

      final second = await open();
      expect(
        second.hint('chats|all', 'forja'),
        const ProfileRailHint(count: 7, more: true, newestAt: 1700000500),
      );
      expect(second.hint('chats|archived', 'forja'), isNull);
      expect(second.hint('chats|all', 'pi'), isNull);
    });

    test('unchanged values are not written again; old scopes are dropped', (
    ) async {
      final rail = await open();
      const hint = ProfileRailHint(count: 1, more: false, newestAt: 5);
      rail.rememberHints('s0', const {'a': hint});
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      final before = prefs.getString(ProfileRailChats.hintsKey('c1'));
      rail.rememberHints('s0', const {'a': hint});
      await pumpEventQueue();
      expect(prefs.getString(ProfileRailChats.hintsKey('c1')), before);

      for (var i = 1; i <= ProfileRailChats.maxHintScopes; i++) {
        rail.rememberHints('s$i', const {'a': hint});
      }
      await pumpEventQueue();
      expect(rail.hint('s0', 'a'), isNull);
      expect(rail.hint('s1', 'a'), hint);
    });

    test('a removed connection forgets them; a damaged value is no hints', (
    ) async {
      final rail = await open();
      rail.rememberHints('s', const {
        'a': ProfileRailHint(count: 1, more: false, newestAt: 5),
      });
      await pumpEventQueue();
      await ProfileRailChats.forgetConnection('c1');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ProfileRailChats.hintsKey('c1')), isNull);

      await prefs.setString(ProfileRailChats.hintsKey('c1'), '{not json');
      final again = await open();
      expect(again.hint('s', 'a'), isNull);
    });
  });

  test(
    'at most one sweep a minute per scope; a later one reads again',
    () async {
      final server = _Server();
      final rail = store();
      void refresh() => rail.refresh(
        scope: 'chats',
        owners: const ['forja'],
        load: server.load,
      );
      refresh();
      await pumpEventQueue();
      await server.answer('forja');
      for (var i = 0; i < 20; i++) {
        now = now.add(const Duration(seconds: 2));
        refresh();
        await pumpEventQueue();
      }
      expect(server.requests, hasLength(1));
      now = now.add(const Duration(seconds: 21));
      refresh();
      await pumpEventQueue();
      expect(server.requests, hasLength(2));
    },
  );

  test('a failing profile is skipped: the others are still read and it '
      'keeps its value', () async {
    final server = _Server();
    final rail = store();
    rail.refresh(
      scope: 'chats',
      owners: const ['forja', 'pi'],
      load: server.load,
    );
    await pumpEventQueue();
    await server.answer('forja', rows: 5);
    await server.answer('pi', rows: 4);
    now = now.add(const Duration(minutes: 2));
    rail.refresh(
      scope: 'chats',
      owners: const ['forja', 'pi', 'oficina'],
      load: server.load,
    );
    await pumpEventQueue();
    await server.answer('forja', error: StateError('403'));
    // Skipped, not stopped: «pi» and «oficina» are read.
    expect(server.requests, ['forja', 'pi', 'forja', 'pi']);
    await server.answer('pi', rows: 7);
    await server.answer('oficina', rows: 1);
    expect(server.requests, ['forja', 'pi', 'forja', 'pi', 'oficina']);
    expect(rail.page('chats', 'forja')!.sessions, hasLength(5), reason: 'kept');
    expect(rail.page('chats', 'pi')!.sessions, hasLength(7));
    expect(rail.page('chats', 'oficina')!.sessions, hasLength(1));
    expect(rail.sweeping, isFalse);
    // And the sweep counts for the minute.
    rail.refresh(
      scope: 'chats',
      owners: const ['forja', 'pi'],
      load: server.load,
    );
    await pumpEventQueue();
    expect(server.requests, hasLength(5));
  });

  test('a server that fails every profile: the sweep ends after a few and '
      'waits for the minute', () async {
    final server = _Server();
    final rail = store();
    final owners = [for (var i = 0; i < 8; i++) 'p$i'];
    rail.refresh(scope: 'chats', owners: owners, load: server.load);
    for (var i = 0; i < 8; i++) {
      await pumpEventQueue();
      final waiting = server.pending.keys.toList();
      if (waiting.isEmpty) break;
      await server.answer(waiting.single, error: StateError('502'));
    }
    expect(server.requests, hasLength(ProfileRailChats.maxConsecutiveFailures));
    expect(rail.sweeping, isFalse);
    rail.refresh(scope: 'chats', owners: owners, load: server.load);
    await pumpEventQueue();
    expect(
      server.requests,
      hasLength(ProfileRailChats.maxConsecutiveFailures),
      reason: 'no retry on every build',
    );
  });

  test('another screen\'s cancel does not cut the sweep; a sweep cut before '
      'any page does not hold the next one', () async {
    final server = _Server();
    final rail = store();
    final screenA = Object();
    final screenB = Object();
    rail.refresh(
      scope: 'chats',
      owners: const ['forja', 'pi'],
      load: server.load,
      requester: screenA,
    );
    await pumpEventQueue();
    rail.cancel(screenB);
    expect(rail.sweeping, isTrue);
    await server.answer('forja');
    expect(server.requests, ['forja', 'pi']);
    await server.answer('pi');
    expect(rail.page('chats', 'forja'), isNotNull);

    // Its own screen cuts it before any page: the next build sweeps again
    // at once, not a minute later.
    now = now.add(const Duration(minutes: 2));
    rail.refresh(
      scope: 'chats',
      owners: const ['oficina'],
      load: server.load,
      requester: screenA,
    );
    await pumpEventQueue();
    rail.cancel(screenA);
    expect(rail.sweeping, isFalse);
    await server.answer('oficina');
    expect(rail.page('chats', 'oficina'), isNull, reason: 'dropped');
    rail.refresh(
      scope: 'chats',
      owners: const ['oficina'],
      load: server.load,
      requester: screenB,
    );
    await pumpEventQueue();
    expect(server.requests, ['forja', 'pi', 'oficina', 'oficina']);
    await server.answer('oficina');
    expect(rail.page('chats', 'oficina'), isNotNull);
  });

  test('cancel drops the answer on the wire; the next sweep waits for it '
      'and never overlaps it', () async {
    final server = _Server();
    final rail = store();
    rail.refresh(
      scope: 'chats',
      owners: const ['forja', 'pi'],
      load: server.load,
    );
    await pumpEventQueue();
    rail.cancel();
    // Another scope (the archived view) starts a sweep right away…
    rail.refresh(
      scope: 'archived',
      owners: const ['oficina'],
      load: server.load,
    );
    await pumpEventQueue();
    // …but only once the cancelled request is answered.
    expect(server.requests, ['forja']);
    await server.answer('forja');
    expect(rail.page('chats', 'forja'), isNull);
    expect(rail.page('archived', 'forja'), isNull);
    expect(server.requests, ['forja', 'oficina']);
    await server.answer('oficina');
    expect(rail.page('archived', 'oficina'), isNotNull);
    expect(server.maxInFlight, 1);
  });

  test('a new scope forgets the pages of the old one', () async {
    final server = _Server();
    final rail = store();
    rail.refresh(scope: 'chats', owners: const ['forja'], load: server.load);
    await pumpEventQueue();
    await server.answer('forja');
    expect(rail.pages('chats'), hasLength(1));
    rail.refresh(scope: 'cron', owners: const ['forja'], load: server.load);
    expect(rail.page('chats', 'forja'), isNull);
    expect(rail.pages('cron'), isEmpty);
  });

  test(
    'App Lock: nothing is read while locked, and locking stops a sweep',
    () async {
      final server = _Server();
      final rail = store();
      final locked = ValueNotifier<bool>(true);
      rail.refresh(
        scope: 'chats',
        owners: const ['forja', 'pi'],
        load: server.load,
        locked: locked,
      );
      await pumpEventQueue();
      expect(server.requests, isEmpty);
      locked.value = false;
      rail.refresh(
        scope: 'chats',
        owners: const ['forja', 'pi'],
        load: server.load,
        locked: locked,
      );
      await pumpEventQueue();
      expect(server.requests, ['forja']);
      locked.value = true;
      await server.answer('forja');
      expect(rail.page('chats', 'forja'), isNull, reason: 'locked: dropped');
      expect(server.requests, ['forja']);
    },
  );

  test('fourteen profiles, a bounded sweep: no more than maxProfiles '
      'requests, never two at once', () async {
    final server = _Server();
    final rail = store(maxProfiles: 10);
    final owners = [for (var i = 0; i < 14; i++) 'p$i'];
    rail.refresh(scope: 'chats', owners: owners, load: server.load);
    for (var i = 0; i < 14; i++) {
      await pumpEventQueue();
      final waiting = server.pending.keys.toList();
      if (waiting.isEmpty) break;
      await server.answer(waiting.single);
    }
    expect(server.requests, hasLength(10));
    expect(server.maxInFlight, 1);
    expect(rail.pages('chats'), hasLength(10));
  });

  test('the shared cache of a connection outlives a screen: a rebuilt rail '
      'paints what was read without asking again', () async {
    addTearDown(ProfileRailChats.debugReset);
    final server = _Server();
    final first = ProfileRailChats.of('conn-a');
    first.refresh(scope: 'chats', owners: const ['forja'], load: server.load);
    await pumpEventQueue();
    await server.answer('forja', rows: 6);
    final again = ProfileRailChats.of('conn-a');
    expect(identical(first, again), isTrue);
    expect(again.page('chats', 'forja')!.sessions, hasLength(6));
    again.refresh(scope: 'chats', owners: const ['forja'], load: server.load);
    await pumpEventQueue();
    expect(server.requests, hasLength(1));
    expect(ProfileRailChats.of('conn-b').page('chats', 'forja'), isNull);
  });
}
