import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _conn = 'conn-a';
const _hiddenKey = 'hidden_sessions_$_conn';

Session _row(
  String id, {
  String title = 'Server title',
  bool? hidden = false,
  bool? unread,
  String? profile = 'default',
  String? root,
}) => Session(
  id: id,
  lineageRootId: root,
  title: title,
  model: 'model-a',
  source: 'cli',
  messageCount: 3,
  isActive: false,
  preview: '',
  startedAt: 1,
  profile: profile,
  hidden: hidden,
  unread: unread,
);

class _HttpError implements Exception {
  final int status;
  const _HttpError(this.status);
}

/// One PATCH /api/sessions/{id} as the server would answer it.
typedef _Answer =
    FutureOr<Map<String, Object?>> Function(_Call call, int index);

class _Call {
  final String id;
  final Map<String, Object> fields;
  final String? profile;
  _Call(this.id, this.fields, this.profile);
  @override
  String toString() => 'PATCH $id $fields';
}

/// Echoes every field back, like the current Hermes handler.
Map<String, Object?> _echo(_Call call, int _) => {
  'ok': true,
  'title': call.fields['title'] ?? 'Server title',
  ...call.fields,
};

class _Server {
  final List<_Call> calls = [];
  _Answer answer;
  _Server([this.answer = _echo]);

  Future<Map<String, Object?>> write(
    String id,
    Map<String, Object> fields,
    String? profile,
  ) async {
    final call = _Call(id, Map.of(fields), profile);
    final index = calls.length;
    calls.add(call);
    return answer(call, index);
  }
}

Future<SessionArchive> _open(_Server server) async {
  final prefs = await SharedPreferences.getInstance();
  final archive = await SessionArchive.load(prefs, _conn);
  archive.attachRemoteState(
    server.write,
    httpStatusOf: (e) => e is _HttpError ? e.status : null,
  );
  return archive;
}

/// A process restart: a new preferences instance over what was persisted.
Future<SessionArchive> _restart(_Server server) async {
  final old = await SharedPreferences.getInstance();
  final values = <String, Object>{
    for (final key in old.getKeys()) key: old.get(key)!,
  };
  SharedPreferences.setMockInitialValues(values);
  return _open(server);
}

void _read(SessionArchive archive, List<Session> rows) =>
    archive.beginListRead().end(rows: rows);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('rows carry the server hidden and unread flags when published', () {
    final published = Session.fromJson({
      'id': 's1',
      'hidden': 0,
      'unread': true,
    });
    expect(published.hidden, isFalse);
    expect(published.unread, isTrue);
    expect(Session.fromJson({'id': 's1', 'hidden': 1}).hidden, isTrue);
    expect(Session.fromJson({'id': 's1', 'hidden': true}).hidden, isTrue);
    final legacy = Session.fromJson({'id': 's1', 'hidden': 'yes'});
    expect(legacy.hidden, isNull);
    expect(legacy.unread, isNull);
  });

  group('hidden', () {
    test('hiding writes hidden=true and drops the local copy once '
        'the server confirms', () async {
      final server = _Server();
      final archive = await _open(server);
      final row = _row('s1');

      await archive.hideSession(row);
      expect(archive.isSessionHidden(row), isTrue);
      await archive.remoteStateSettled;

      expect(server.calls.single.fields, {'hidden': true});
      expect(server.calls.single.profile, 'default');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_hiddenKey), isEmpty);
      // Still hidden: the server's copy now holds it.
      expect(archive.isSessionHidden(row), isTrue);
    });

    test('a failed write keeps the local id (never cleared before '
        'confirmation) and the session stays hidden', () async {
      final server = _Server((_, _) => throw const _HttpError(503));
      final archive = await _open(server);
      final row = _row('s1');

      await archive.hideSession(row);
      await archive.remoteStateSettled;

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_hiddenKey), ['s1']);
      expect(archive.isSessionHidden(row), isTrue);
    });

    test('the local id survives while the PATCH is in flight '
        '(crash before the answer loses nothing)', () async {
      final gate = Completer<Map<String, Object?>>();
      final server = _Server((_, _) => gate.future);
      final archive = await _open(server);

      await archive.hideSession(_row('s1'));
      await pumpEventQueue();
      expect(server.calls, hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_hiddenKey), ['s1']);
      gate.complete({'ok': true, 'title': '', 'hidden': true});
      await archive.remoteStateSettled;
      expect(prefs.getStringList(_hiddenKey), isEmpty);
    });

    test('(a) an interrupted migration ends with every id hidden on the '
        'server and none lost', () async {
      SharedPreferences.setMockInitialValues({
        _hiddenKey: ['s1', 's2', 's3', 's4'],
      });
      final serverHidden = <String>{};
      // The network drops after two confirmed PATCHes.
      final first = _Server((call, index) {
        if (index >= 2) throw const _HttpError(502);
        serverHidden.add(call.id);
        return {'ok': true, 'title': '', 'hidden': true};
      });
      final rows = [
        for (final id in ['s1', 's2', 's3', 's4']) _row(id),
      ];
      var archive = await _open(first);
      _read(archive, rows);
      await archive.remoteStateSettled;
      expect(first.calls, hasLength(4));
      var prefs = await SharedPreferences.getInstance();
      final remaining = prefs.getStringList(_hiddenKey)!.toSet();
      expect(remaining, {'s3', 's4'});
      expect(remaining.union(serverHidden), {'s1', 's2', 's3', 's4'});

      // Restart: only the ids the server never confirmed are retried.
      final second = _Server((call, _) {
        serverHidden.add(call.id);
        return {'ok': true, 'title': '', 'hidden': true};
      });
      archive = await _restart(second);
      _read(archive, [
        for (final row in rows)
          if (!serverHidden.contains(row.id)) row,
      ]);
      await archive.remoteStateSettled;
      expect(second.calls.map((c) => c.id).toSet(), {'s3', 's4'});
      expect(serverHidden, {'s1', 's2', 's3', 's4'});
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_hiddenKey), isEmpty);
    });

    test('(b) rerunning a finished migration sends no PATCH', () async {
      SharedPreferences.setMockInitialValues({
        _hiddenKey: ['s1'],
      });
      final server = _Server();
      var archive = await _open(server);
      _read(archive, [_row('s1')]);
      await archive.remoteStateSettled;
      expect(server.calls, hasLength(1));

      final again = _Server();
      archive = await _restart(again);
      // Even a stale row still saying hidden=false triggers nothing.
      _read(archive, [_row('s1')]);
      _read(archive, [_row('s1')]);
      await archive.remoteStateSettled;
      expect(again.calls, isEmpty);
    });

    test('(c) a chat unhidden on Desktop after the migration is not '
        're-hidden by Console', () async {
      SharedPreferences.setMockInitialValues({
        _hiddenKey: ['s1'],
      });
      final server = _Server();
      final archive = await _open(server);
      _read(archive, [_row('s1')]);
      await archive.remoteStateSettled;
      expect(server.calls, hasLength(1));

      // Desktop unhides: the default listing carries the row again.
      final unhidden = _row('s1', hidden: false);
      _read(archive, [unhidden]);
      await archive.remoteStateSettled;
      expect(server.calls, hasLength(1));
      expect(archive.isSessionHidden(unhidden), isFalse);
    });

    test(
      'the migration never un-hides and skips ids with no server row',
      () async {
        SharedPreferences.setMockInitialValues({
          _hiddenKey: ['gone', 's1'],
        });
        final server = _Server();
        final archive = await _open(server);
        _read(archive, [_row('s1'), _row('s2')]);
        await archive.remoteStateSettled;
        expect(server.calls.map((c) => c.id), ['s1']);
        expect(server.calls.every((c) => c.fields['hidden'] == true), isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList(_hiddenKey), ['gone']);
      },
    );

    test('a server whose rows lack the field keeps the local hide and '
        'sends nothing', () async {
      final server = _Server();
      final archive = await _open(server);
      final legacy = _row('s1', hidden: null);
      await archive.hideSession(legacy);
      _read(archive, [legacy]);
      await archive.remoteStateSettled;
      expect(server.calls, isEmpty);
      expect(archive.isSessionHidden(legacy), isTrue);
    });

    test('a PATCH that rejects the field falls back to local silently and '
        'stops writing it', () async {
      SharedPreferences.setMockInitialValues({
        _hiddenKey: ['s1', 's2'],
      });
      // An older handler: unknown field ignored -> "Nothing to update".
      final server = _Server((_, _) => throw const _HttpError(400));
      final archive = await _open(server);
      _read(archive, [_row('s1')]);
      await archive.remoteStateSettled;
      _read(archive, [_row('s1'), _row('s2')]);
      await archive.remoteStateSettled;
      expect(server.calls, hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_hiddenKey)!.toSet(), {'s1', 's2'});
    });

    test('a list read that shows the row hidden confirms a pending local '
        'hide without a PATCH', () async {
      SharedPreferences.setMockInitialValues({
        _hiddenKey: ['s1'],
      });
      final server = _Server();
      final archive = await _open(server);
      // The archived view lists archived rows even when hidden.
      _read(archive, [_row('s1', hidden: true)]);
      await archive.remoteStateSettled;
      expect(server.calls, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_hiddenKey), isEmpty);
    });

    test('an answer that does not confirm hidden keeps the local id', () async {
      SharedPreferences.setMockInitialValues({
        _hiddenKey: ['s1'],
      });
      // A handler that ignores the key and echoes only ok/title.
      final server = _Server((_, _) => {'ok': true, 'title': 'Server title'});
      final archive = await _open(server);
      _read(archive, [_row('s1')]);
      await archive.remoteStateSettled;
      _read(archive, [_row('s1')]);
      await archive.remoteStateSettled;
      expect(server.calls, hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_hiddenKey), ['s1']);
      expect(archive.isSessionHidden(_row('s1')), isTrue);
    });

    test('a late hide answer does not undo a newer local unhide', () async {
      final gates = <Completer<Map<String, Object?>>>[];
      final server = _Server((call, _) {
        final gate = Completer<Map<String, Object?>>();
        gates.add(gate);
        return gate.future;
      });
      final archive = await _open(server);
      final row = _row('s1');

      await archive.hideSession(row);
      await pumpEventQueue();
      await archive.unhideSession(row);
      expect(archive.isSessionHidden(row), isFalse);
      // The unhide waits for the hide: one write per session at a time.
      expect(server.calls, hasLength(1));
      gates.first.complete({'ok': true, 'title': '', 'hidden': true});
      await pumpEventQueue();
      expect(archive.isSessionHidden(row), isFalse);
      expect(server.calls.map((c) => c.fields['hidden']), [true, false]);
      gates.last.complete({'ok': true, 'title': '', 'hidden': false});
      await archive.remoteStateSettled;
      expect(archive.isSessionHidden(row), isFalse);
      // A page read before the unhide landed cannot hide it again.
      _read(archive, [row]);
      expect(archive.isSessionHidden(row), isFalse);
    });

    test('a page read before the hide was confirmed cannot show the row '
        'again', () async {
      final gate = Completer<Map<String, Object?>>();
      final server = _Server((_, _) => gate.future);
      final archive = await _open(server);
      final row = _row('s1');
      await archive.hideSession(row);
      final staleRead = archive.beginListRead();
      gate.complete({'ok': true, 'title': '', 'hidden': true});
      await archive.remoteStateSettled;
      staleRead.end(rows: [row]);
      expect(archive.isSessionHidden(row), isTrue);
    });
  });

  group('title', () {
    test('rename goes through PATCH title and the list shows the server '
        'title', () async {
      final server = _Server();
      final archive = await _open(server);
      final row = _row('s1', title: 'Old');

      final rename = archive.renameSession(row, '  New name ');
      // Optimistic overlay while the write is in flight.
      expect(archive.titleForSession(row), 'New name');
      await rename;
      expect(server.calls.single.fields, {'title': 'New name'});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('session_titles_$_conn') ?? [], isEmpty);

      // A later read carries the server title; a Desktop rename after it
      // wins on Console too.
      _read(archive, [_row('s1', title: 'New name')]);
      final renamedOnDesktop = _row('s1', title: 'From Desktop');
      _read(archive, [renamedOnDesktop]);
      expect(archive.titleForSession(renamedOnDesktop), 'From Desktop');
    });

    test('a page read before the rename was confirmed keeps the new '
        'title', () async {
      final gate = Completer<Map<String, Object?>>();
      final server = _Server((_, _) => gate.future);
      final archive = await _open(server);
      final row = _row('s1', title: 'Old');
      final staleRead = archive.beginListRead();
      final rename = archive.renameSession(row, 'New');
      gate.complete({'ok': true, 'title': 'New'});
      await rename;
      staleRead.end(rows: [row]);
      expect(archive.titleForSession(row), 'New');
    });

    test('a rejected title rolls back and reports the failure', () async {
      final server = _Server((_, _) => throw const _HttpError(409));
      final archive = await _open(server);
      final row = _row('s1', title: 'Old');
      await expectLater(
        archive.renameSession(row, 'Taken'),
        throwsA(isA<_HttpError>()),
      );
      expect(archive.titleForSession(row), 'Old');
    });

    test('without a writable server the rename stays local', () async {
      final prefs = await SharedPreferences.getInstance();
      final archive = await SessionArchive.load(prefs, _conn);
      final row = _row('s1', title: 'Old');
      await archive.renameSession(row, 'Local');
      expect(archive.titleForSession(row), 'Local');
    });

    test('the chat auto-title only stands in for a placeholder server '
        'title', () async {
      final prefs = await SharedPreferences.getInstance();
      final archive = await SessionArchive.load(prefs, _conn);
      final untitled = _row('s1', title: 'Untitled');
      await archive.autoTitleIfPlaceholder(
        sessionId: 's1',
        currentTitle: 'Untitled',
        prompt: 'Plan the trip to Lisbon',
      );
      expect(archive.titleForSession(untitled), isNot('Untitled'));
      final titled = _row('s1', title: 'Lisbon trip plan');
      expect(archive.titleForSession(titled), 'Lisbon trip plan');
    });
  });

  group('writers', () {
    test('a closing screen detaches its writer and the earlier one takes '
        'over', () async {
      final home = _Server();
      final list = _Server();
      final prefs = await SharedPreferences.getInstance();
      final archive = await SessionArchive.load(prefs, _conn);
      archive.attachRemoteState(home.write);
      archive.attachRemoteState(list.write);
      await archive.setSessionUnread(_row('s1', unread: false), true);
      archive.detachRemoteState(list.write);
      await archive.setSessionUnread(_row('s2', unread: false), true);
      archive.detachRemoteState(home.write);
      expect(archive.canToggleUnread(_row('s3', unread: false)), isFalse);
      expect(list.calls.map((c) => c.id), ['s1']);
      expect(home.calls.map((c) => c.id), ['s2']);
    });
  });

  group('unread', () {
    test('opening an unread session marks it read on the server', () async {
      final server = _Server();
      final archive = await _open(server);
      final row = _row('s1', unread: true);
      expect(archive.isSessionUnread(row), isTrue);

      await archive.markSessionReadOnOpen(row);
      expect(server.calls.single.fields, {'unread': false});
      expect(archive.isSessionUnread(row), isFalse);

      await archive.markSessionReadOnOpen(_row('s2', unread: false));
      await archive.markSessionReadOnOpen(_row('s3'));
      expect(server.calls, hasLength(1));
    });

    test('mark as unread survives a page read before the write landed, '
        'then the server value wins', () async {
      final gate = Completer<Map<String, Object?>>();
      final server = _Server((_, _) => gate.future);
      final archive = await _open(server);
      final row = _row('s1', unread: false);
      final staleRead = archive.beginListRead();
      final toggle = archive.setSessionUnread(row, true);
      gate.complete({'ok': true, 'title': '', 'unread': true});
      await toggle;
      staleRead.end(rows: [row]);
      expect(archive.isSessionUnread(row), isTrue);

      // Desktop opens it afterwards: a fresh read says read.
      final readOnDesktop = _row('s1', unread: false);
      _read(archive, [readOnDesktop]);
      expect(archive.isSessionUnread(readOnDesktop), isFalse);
    });

    test('a failed toggle rolls back visibly and throws', () async {
      final server = _Server((_, _) => throw const _HttpError(503));
      final archive = await _open(server);
      final row = _row('s1', unread: false);
      await expectLater(
        archive.setSessionUnread(row, true),
        throwsA(isA<_HttpError>()),
      );
      expect(archive.isSessionUnread(row), isFalse);
    });

    test('the toggle exists only when the server advertises unread', () async {
      final server = _Server();
      final archive = await _open(server);
      expect(archive.canToggleUnread(_row('s1', unread: false)), isTrue);
      expect(archive.canToggleUnread(_row('s1')), isFalse);
      final offline = await SessionArchive.load(
        await SharedPreferences.getInstance(),
        'no-writer',
      );
      expect(offline.canToggleUnread(_row('s1', unread: false)), isFalse);
    });

    test('a late read answer does not override a newer mark-unread', () async {
      final gates = <Completer<Map<String, Object?>>>[];
      final server = _Server((call, _) {
        final gate = Completer<Map<String, Object?>>();
        gates.add(gate);
        return gate.future;
      });
      final archive = await _open(server);
      final row = _row('s1', unread: true);
      final open = archive.markSessionReadOnOpen(row);
      await pumpEventQueue();
      final toggle = archive.setSessionUnread(row, true);
      gates.first.complete({'ok': true, 'title': '', 'unread': false});
      await open;
      expect(archive.isSessionUnread(row), isTrue);
      await pumpEventQueue();
      gates.last.complete({'ok': true, 'title': '', 'unread': true});
      await toggle;
      expect(server.calls.map((c) => c.fields['unread']), [false, true]);
      expect(archive.isSessionUnread(row), isTrue);
    });
  });
}
