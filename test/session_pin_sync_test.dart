import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session _row(
  String id, {
  bool? pinned,
  String? profile,
  int messageCount = 1,
  String? root,
  String? parent,
}) => Session(
  id: id,
  lineageRootId: root,
  parentSessionId: parent,
  title: 'Conversation',
  model: 'model-a',
  source: 'mobile',
  messageCount: messageCount,
  isActive: false,
  preview: '',
  startedAt: 1,
  profile: profile,
  pinned: pinned,
);

typedef _Write = (String, bool, String?);

/// One app process: its own preferences instance (restored from what the
/// previous process persisted), shared archive store and pin sync, as after a
/// cold start or a fresh mount of the sessions screen.
final class _Launch {
  _Launch(this.prefs, this.archive, this.sync, this.writes);

  final SharedPreferences prefs;
  final SessionArchive archive;
  final SessionPinSync sync;
  final List<_Write> writes;

  /// [previous] carries what the last process persisted; [seed] replaces it
  /// with raw preferences (an older build's data).
  static Future<_Launch> start(
    _Launch? previous, {
    Map<String, Object> seed = const {},
    String connection = 'conn-a',
    Future<void> Function(String id, bool pinned, String? profile)? writer,
    bool Function(Object error)? isUnsupported,
    DateTime Function()? now,
    int maxPinned = SessionPinSync.defaultMaxPinned,
    bool readOnly = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (previous != null)
        for (final key in previous.prefs.getKeys())
          key: previous.prefs.get(key)!,
      ...seed,
    });
    return _open(
      await SharedPreferences.getInstance(),
      connection,
      writer: writer,
      isUnsupported: isUnsupported,
      now: now,
      maxPinned: maxPinned,
      readOnly: readOnly,
    );
  }

  /// Another connection in the same preferences.
  static Future<_Launch> alongside(_Launch other, String connection) =>
      _open(other.prefs, connection);

  static Future<_Launch> _open(
    SharedPreferences prefs,
    String connection, {
    Future<void> Function(String id, bool pinned, String? profile)? writer,
    bool Function(Object error)? isUnsupported,
    DateTime Function()? now,
    int maxPinned = SessionPinSync.defaultMaxPinned,
    bool readOnly = false,
  }) async {
    final archive = await SessionArchive.load(prefs, connection);
    final writes = <_Write>[];
    final sync = SessionPinSync(
      archive,
      writeRemote: readOnly
          ? null
          : (id, pinned, profile) async {
              writes.add((id, pinned, profile));
              await writer?.call(id, pinned, profile);
            },
      isUnsupported: isUnsupported,
      now: now,
      maxPinned: maxPinned,
    );
    return _Launch(prefs, archive, sync, writes);
  }

  /// A live page of `/api/sessions`, read as the list screen does.
  Future<void> read(List<Session> rows) async {
    await sync.updateSessions(rows, readFence: sync.beginRemoteRead());
    await Future<void>.delayed(Duration.zero);
  }

  Set<String> get pinned => archive.pinnedIds;

  List<String>? get syncState => prefs.getStringList('pinned_sync_conn-a');
}

void main() {
  test(
    'a cold start with the server in agreement sends no pin PATCH',
    () async {
      final first = await _Launch.start(null);
      await first.read([_row('a', pinned: true), _row('b', pinned: true)]);
      final mine = _row('c', pinned: false);
      await first.read([
        _row('a', pinned: true),
        _row('b', pinned: true),
        mine,
      ]);
      await first.sync.setLocalPinned(mine, true);
      await Future<void>.delayed(Duration.zero);
      expect(first.writes, [('c', true, null)]);

      final second = await _Launch.start(first);
      final rows = [
        _row('a', pinned: true),
        _row('b', pinned: true),
        _row('c', pinned: true),
      ];
      await second.read(rows);
      expect(second.writes, isEmpty);
      expect(second.pinned, {'a', 'b', 'c'});

      // Mounting the screen again (a fresh sync over the same store) is the
      // same: nothing is re-asserted.
      final third = await _Launch.start(second);
      await third.read(rows);
      expect(third.writes, isEmpty);
    },
  );

  test(
    'a pin released on the server stays released after reconnecting',
    () async {
      final first = await _Launch.start(null);
      await first.read([_row('a', pinned: true), _row('b', pinned: true)]);

      final second = await _Launch.start(first);
      await second.read([_row('a', pinned: true), _row('b', pinned: false)]);
      expect(second.writes, isEmpty);
      expect(second.archive.isPinned('a'), isTrue);
      expect(second.archive.isPinned('b'), isFalse);

      final third = await _Launch.start(second);
      await third.read([_row('a', pinned: true), _row('b', pinned: false)]);
      expect(third.writes, isEmpty);
      expect(third.archive.isPinned('b'), isFalse);
    },
  );

  test('pins that only the server holds are not local intent', () async {
    final first = await _Launch.start(null);
    final rows = [
      for (final id in ['s1', 's2', 's3']) _row(id, pinned: true),
    ];
    await first.read(rows);
    expect(first.pinned, {'s1', 's2', 's3'});
    expect(first.writes, isEmpty);

    // The server released all of them while the app was closed.
    final second = await _Launch.start(first);
    await second.read([
      for (final id in ['s1', 's2', 's3']) _row(id, pinned: false),
    ]);
    expect(second.writes, isEmpty);
    expect(second.pinned, isEmpty);
    expect(second.prefs.getStringList('pinned_sessions_conn-a'), isEmpty);
  });

  group('pins made in the app', () {
    test('online: sent once, then confirmed', () async {
      final first = await _Launch.start(null);
      await first.read([_row('x', pinned: false)]);
      await first.sync.setLocalPinned(_row('x', pinned: false), true);
      await Future<void>.delayed(Duration.zero);
      expect(first.writes, [('x', true, null)]);
      expect(first.syncState, contains('c:x'));

      await first.read([_row('x', pinned: true)]);
      await first.read([_row('x', pinned: true)]);
      expect(first.writes, hasLength(1));

      final second = await _Launch.start(first);
      await second.read([_row('x', pinned: true)]);
      expect(second.writes, isEmpty);
      expect(second.pinned, {'x'});
    });

    test('offline: kept, and sent once when the app is back', () async {
      Future<void> offline(String id, bool pinned, String? profile) =>
          Future.error(StateError('offline'));
      final first = await _Launch.start(null, writer: offline);
      await first.read([_row('x', pinned: false)]);
      await first.sync.setLocalPinned(_row('x', pinned: false), true);
      await Future<void>.delayed(Duration.zero);
      expect(first.pinned, {'x'});
      expect(first.syncState, isNot(contains('c:x')));

      // The process dies offline; the next one reaches the server.
      final second = await _Launch.start(first);
      expect(second.pinned, {'x'});
      await second.read([_row('x', pinned: false)]);
      expect(second.writes, [('x', true, null)]);
      await second.read([_row('x', pinned: true)]);
      expect(second.writes, hasLength(1));
      expect(second.syncState, contains('c:x'));

      final third = await _Launch.start(second);
      await third.read([_row('x', pinned: true)]);
      expect(third.writes, isEmpty);
    });

    test('a pin set without the sync (archive.pin) is still sent', () async {
      final first = await _Launch.start(null);
      await first.archive.pin('x');
      final second = await _Launch.start(first);
      await second.read([_row('x', pinned: false)]);
      expect(second.writes, [('x', true, null)]);
      expect(second.pinned, {'x'});
    });

    test('unpin: sent once, also for a pin the server made', () async {
      final first = await _Launch.start(null);
      await first.read([_row('x', pinned: true)]);
      await first.sync.setLocalPinned(_row('x', pinned: true), false);
      await Future<void>.delayed(Duration.zero);
      expect(first.writes, [('x', false, null)]);
      expect(first.pinned, isEmpty);
      expect(first.syncState, isNot(contains('c:x')));

      final second = await _Launch.start(first);
      await second.read([_row('x', pinned: false)]);
      expect(second.writes, isEmpty);
      expect(second.pinned, isEmpty);
    });

    test(
      'archiving a pinned chat does not repeat what the server did',
      () async {
        final first = await _Launch.start(null);
        await first.read([_row('x', pinned: true)]);
        await first.archive.archive('x');
        await first.read([_row('x', pinned: false)]);
        expect(first.writes, isEmpty);
        expect(first.pinned, isEmpty);
        expect(first.syncState, isNot(contains('c:x')));
      },
    );
  });

  group('migration from the unversioned pin set', () {
    final old = <String, Object>{
      'pinned_sessions_conn-a': ['a', 'b', 'c'],
    };

    test(
      'shows what was pinned, sends nothing, lets the server settle',
      () async {
        final first = await _Launch.start(null, seed: old);
        expect(first.pinned, {'a', 'b', 'c'});
        await first.read([_row('a', pinned: true), _row('b', pinned: false)]);
        expect(first.writes, isEmpty);
        expect(first.pinned, {'a', 'c'});
        expect(first.syncState, ['v2', 'c:a', 'l:c']);

        final second = await _Launch.start(first);
        await second.read([_row('c', pinned: true)]);
        expect(second.writes, isEmpty);
        expect(second.syncState, ['v2', 'c:a', 'c:c']);

        // The server's `false` settles an id seen for the first time.
        final third = await _Launch.start(null, seed: old);
        await third.read([_row('c', pinned: false)]);
        expect(third.pinned, {'a', 'b'});
        expect(third.writes, isEmpty);
      },
    );

    test('an old pin of a chat not stored yet is sent once it is', () async {
      final seed = {
        'pinned_sessions_conn-a': ['mob-1'],
      };
      final first = await _Launch.start(null, seed: seed);
      final draft = _row('mob-1', messageCount: 0);
      await first.read([draft]);
      expect(first.writes, isEmpty);
      await first.read([_row('mob-1', pinned: false)]);
      expect(first.writes, [('mob-1', true, null)]);
    });

    test('a pin moved to the lineage root stays a legacy one', () async {
      final seed = {
        'pinned_sessions_conn-a': ['tip-1'],
      };
      final first = await _Launch.start(null, seed: seed);
      final tip = _row('tip-2', root: 'root-1', parent: 'tip-1', pinned: false);
      await first.archive.migrateLogicalIdentity(
        tip,
        knownPhysicalIds: const ['tip-1'],
      );
      expect(first.archive.isPinned('root-1'), isTrue);
      await first.read([tip]);
      expect(first.writes, isEmpty);
      expect(first.archive.isSessionPinned(tip), isFalse);
      expect(first.pinned, isEmpty);
    });

    test('an unpin of an old pin still reaches the server', () async {
      final first = await _Launch.start(null, seed: old);
      await first.archive.unpin('a');
      await first.read([_row('a', pinned: true)]);
      expect(first.writes, [('a', false, null)]);
      expect(first.pinned, {'b', 'c'});
    });
  });

  group('no server support', () {
    test('keeps the local pins and stops asking', () async {
      var attempts = 0;
      final first = await _Launch.start(
        null,
        writer: (id, pinned, profile) async {
          attempts++;
          throw const FormatException('404');
        },
        isUnsupported: (error) => error is FormatException,
      );
      final row = _row('x');
      await first.read([row]);
      await first.sync.setLocalPinned(row, true);
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1);
      expect(first.sync.remoteUnsupported, isTrue);
      expect(first.pinned, {'x'});

      await first.read([row]);
      await first.sync.setLocalPinned(_row('y'), true);
      expect(attempts, 1);
      expect(first.pinned, {'x', 'y'});
      await first.sync.setLocalPinned(row, false);
      expect(first.pinned, {'y'});
    });

    test('rows without the flag are not probed on launch', () async {
      final seed = {
        'pinned_sessions_conn-a': ['x'],
      };
      final first = await _Launch.start(null, seed: seed);
      await first.read([_row('x')]);
      expect(first.writes, isEmpty);
      expect(first.pinned, {'x'});
    });

    test('a read-only connection keeps its local pins', () async {
      final first = await _Launch.start(null, readOnly: true);
      await first.sync.setLocalPinned(_row('x'), true);
      await first.read([_row('x', pinned: false)]);
      expect(first.sync.remoteUnsupported, isTrue);
      expect(first.pinned, {'x'});
    });
  });

  group('failed writes', () {
    test('retry with backoff, then stay quiet', () async {
      var clock = DateTime(2026, 1, 1);
      final first = await _Launch.start(
        null,
        writer: (id, pinned, profile) => Future.error(StateError('503')),
        now: () => clock,
      );
      final row = _row('x', pinned: false);
      await first.read([row]);
      await first.sync.setLocalPinned(row, true);
      await Future<void>.delayed(Duration.zero);
      expect(first.writes, hasLength(1));

      Future<int> readAt(Duration after) async {
        clock = DateTime(2026, 1, 1).add(after);
        await first.read([row]);
        return first.writes.length;
      }

      expect(await readAt(Duration.zero), 2);
      expect(await readAt(const Duration(seconds: 14)), 2);
      expect(await readAt(const Duration(seconds: 15)), 3);
      expect(await readAt(const Duration(seconds: 74)), 3);
      expect(await readAt(const Duration(seconds: 75)), 4);
      expect(await readAt(const Duration(seconds: 374)), 4);
      expect(await readAt(const Duration(seconds: 375)), 5);
      expect(await readAt(const Duration(seconds: 1275)), 6);
      expect(await readAt(const Duration(days: 2)), 6);
      expect(first.pinned, {'x'});

      // A new process tries again; the user's own toggle does too.
      final second = await _Launch.start(first);
      await second.read([row]);
      expect(second.writes, hasLength(1));
    });
  });

  group('isolation', () {
    test('connections keep their own pins', () async {
      final a = await _Launch.start(null);
      final b = await _Launch.alongside(a, 'conn-b');
      await a.read([_row('x', pinned: true)]);
      await b.read([_row('y', pinned: true)]);
      expect(a.pinned, {'x'});
      expect(b.pinned, {'y'});
      expect(a.prefs.getStringList('pinned_sessions_conn-a'), ['x']);
      expect(a.prefs.getStringList('pinned_sessions_conn-b'), ['y']);
      expect(a.writes, isEmpty);
      expect(b.writes, isEmpty);
    });

    test(
      'a release is sent with its own profile, when that page is read',
      () async {
        Future<void> offline(String id, bool pinned, String? profile) =>
            Future.error(StateError('offline'));
        final coding = _row('p', pinned: true, profile: 'coding');
        final first = await _Launch.start(null, writer: offline);
        await first.read([coding]);
        await first.sync.setLocalPinned(coding, false);
        await Future<void>.delayed(Duration.zero);

        final second = await _Launch.start(first);
        await second.read([_row('q', pinned: true, profile: 'default')]);
        expect(second.writes, isEmpty);
        await second.read([coding]);
        expect(second.writes, [('p', false, 'coding')]);
      },
    );
  });

  group('bounds', () {
    test(
      'the oldest settled pins out of the page go past the maximum',
      () async {
        final first = await _Launch.start(null, maxPinned: 3);
        await first.read([
          for (final id in ['s1', 's2', 's3', 's4', 's5'])
            _row(id, pinned: true),
        ]);
        // Everything on the page being read stays.
        expect(first.pinned, hasLength(5));

        await first.read([_row('s5', pinned: true)]);
        expect(first.pinned, {'s3', 's4', 's5'});
        expect(first.syncState, ['v2', 'c:s3', 'c:s4', 'c:s5']);
        expect(first.writes, isEmpty);
      },
    );

    test(
      'an unsent pin is never evicted; deleted chats are forgotten',
      () async {
        final first = await _Launch.start(null, maxPinned: 2);
        await first.read([
          for (final id in ['s1', 's2']) _row(id, pinned: true),
        ]);
        await first.archive.pin('mine');
        await first.read([_row('s2', pinned: true)]);
        expect(first.pinned, contains('mine'));
        expect(first.pinned, hasLength(2));

        await first.archive.markSessionDeleted(_row('mine'));
        expect(first.pinned, isNot(contains('mine')));
      },
    );
  });
}
