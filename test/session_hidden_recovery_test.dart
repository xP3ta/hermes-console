import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _conn = 'conn-a';

Session _row(
  String id, {
  String title = 'Server title',
  bool? hidden = false,
  String? profile = 'default',
}) => Session(
  id: id,
  title: title,
  model: 'model-a',
  source: 'cli',
  messageCount: 3,
  isActive: false,
  preview: '',
  startedAt: 1,
  profile: profile,
  hidden: hidden,
);

class _HttpError implements Exception {
  final int status;
  const _HttpError(this.status);
}

class _Server {
  final List<(String, Map<String, Object>)> calls = [];
  FutureOr<Map<String, Object?>> Function(Map<String, Object> fields) answer;
  _Server([FutureOr<Map<String, Object?>> Function(Map<String, Object>)? a])
    : answer = a ?? ((fields) => {'ok': true, ...fields});

  Future<Map<String, Object?>> write(
    String id,
    Map<String, Object> fields,
    String? profile,
  ) async {
    calls.add((id, Map.of(fields)));
    return answer(fields);
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

Future<SessionArchive> _restart(_Server server) async {
  final old = await SharedPreferences.getInstance();
  SharedPreferences.setMockInitialValues({
    for (final key in old.getKeys()) key: old.get(key)!,
  });
  return _open(server);
}

void _read(SessionArchive archive, List<Session> rows) =>
    archive.beginListRead().end(rows: rows);

List<String> _ids(Iterable<Session> rows) => [for (final r in rows) r.id];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a chat hidden on the server stays listed as hidden after a restart, '
      'and a search row of it (no hidden flag) reads hidden', () async {
    final server = _Server();
    var archive = await _open(server);
    await archive.hideSession(_row('s1', title: 'QA ping'));
    await archive.remoteStateSettled;

    archive = await _restart(server);
    expect(_ids(archive.hiddenSessions), ['s1']);
    expect(archive.hiddenSessions.single.title, 'QA ping');
    expect(
      archive.isSessionHiddenOnServer(archive.hiddenSessions.single),
      isTrue,
    );
    // Search results carry no hidden flag.
    final searchRow = _row('s1', hidden: null);
    expect(archive.isSessionHidden(searchRow), isTrue);
    expect(archive.isSessionHiddenOnServer(searchRow), isTrue);
  });

  test('showing a server-hidden chat PATCHes hidden:false once, drops it '
      'from the hidden list and keeps it revealed until a later read '
      'carries it', () async {
    final server = _Server();
    var archive = await _open(server);
    await archive.hideSession(_row('s1'));
    await archive.remoteStateSettled;
    archive = await _restart(server);
    server.calls.clear();

    await archive.unhideSession(_row('s1', hidden: null));
    expect(archive.hiddenSessions, isEmpty);
    await archive.remoteStateSettled;

    expect(server.calls, hasLength(1));
    expect(server.calls.single.$2, {'hidden': false});
    expect(archive.isSessionHidden(_row('s1', hidden: null)), isFalse);
    expect(_ids(archive.revealedSessions), ['s1']);

    _read(archive, [_row('s1')]);
    expect(archive.revealedSessions, isEmpty);
    expect(archive.isSessionHidden(_row('s1')), isFalse);

    archive = await _restart(server);
    expect(archive.hiddenSessions, isEmpty);
    expect(archive.isSessionHidden(_row('s1', hidden: null)), isFalse);
  });

  test('a legacy local-hidden chat seen in a read is listed and can be '
      'shown again', () async {
    SharedPreferences.setMockInitialValues({
      'hidden_sessions_$_conn': ['old'],
    });
    final server = _Server();
    final archive = await _open(server);
    // An older server: its rows do not publish the flag.
    final row = _row('old', title: 'Old chat', hidden: null);
    _read(archive, [row]);
    expect(_ids(archive.hiddenSessions), ['old']);
    expect(archive.hiddenSessions.single.title, 'Old chat');
    expect(archive.isSessionHiddenOnServer(row), isFalse);

    await archive.unhideSession(row);
    await archive.remoteStateSettled;
    expect(server.calls, isEmpty);
    expect(archive.isSessionHidden(row), isFalse);
    expect(archive.hiddenSessions, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('hidden_sessions_$_conn'), isEmpty);
  });

  test('a legacy local id with no row seen yet is still listed', () async {
    SharedPreferences.setMockInitialValues({
      'hidden_sessions_$_conn': ['ghost'],
    });
    final archive = await _open(_Server());
    expect(_ids(archive.hiddenSessions), ['ghost']);
    await archive.unhideSession(archive.hiddenSessions.single);
    expect(archive.hiddenSessions, isEmpty);
  });

  test('a list read begun before the unhide answer cannot hide the chat '
      'again', () async {
    final server = _Server();
    final archive = await _open(server);
    await archive.hideSession(_row('s1'));
    await archive.remoteStateSettled;

    final stale = archive.beginListRead();
    await archive.unhideSession(_row('s1', hidden: null));
    await archive.remoteStateSettled;
    stale.end(rows: [_row('s1', hidden: true)]);

    expect(archive.isSessionHidden(_row('s1', hidden: true)), isFalse);
    expect(archive.isSessionHidden(_row('s1', hidden: null)), isFalse);
    expect(archive.hiddenSessions, isEmpty);
    expect(_ids(archive.revealedSessions), ['s1']);
    expect(
      [for (final c in server.calls) c.$2],
      [
        {'hidden': true},
        {'hidden': false},
      ],
    );
  });

  test('a search hit begun after the show answer (no hidden flag) keeps '
      'the chat revealed until a listing carries it', () async {
    final server = _Server();
    final archive = await _open(server);
    await archive.hideSession(_row('s1'));
    await archive.remoteStateSettled;
    await archive.unhideSession(_row('s1', hidden: null));
    await archive.remoteStateSettled;

    // The search starts after the answer; the listing still omits the row.
    _read(archive, [_row('s1', hidden: null)]);
    expect(_ids(archive.revealedSessions), ['s1']);
    expect(archive.isSessionHidden(_row('s1', hidden: null)), isFalse);

    _read(archive, [_row('s1')]);
    expect(archive.revealedSessions, isEmpty);
  });

  test('a chat shown again only locally is settled by any row of it', () async {
    SharedPreferences.setMockInitialValues({
      'hidden_sessions_$_conn': ['old'],
    });
    final archive = await _open(_Server());
    final row = _row('old', hidden: null);
    _read(archive, [row]);
    await archive.unhideSession(row);
    expect(_ids(archive.revealedSessions), ['old']);
    _read(archive, [row]);
    expect(archive.revealedSessions, isEmpty);
  });

  test('a read showing the chat visible (shown elsewhere, or pinned on '
      'Desktop) drops it from the hidden list', () async {
    final server = _Server();
    final archive = await _open(server);
    await archive.hideSession(_row('s1'));
    await archive.remoteStateSettled;
    _read(archive, [_row('s1', hidden: true)]);
    expect(_ids(archive.hiddenSessions), ['s1']);

    _read(archive, [_row('s1', hidden: false)]);
    expect(archive.hiddenSessions, isEmpty);
    expect(archive.isSessionHidden(_row('s1', hidden: null)), isFalse);
  });

  test('a hide still pending is not dropped by a read that does not show '
      'it hidden yet', () async {
    final gate = Completer<Map<String, Object?>>();
    final server = _Server((_) => gate.future);
    final archive = await _open(server);
    await archive.hideSession(_row('s1', title: 'Pending'));
    _read(archive, [_row('s1', title: 'Pending', hidden: false)]);
    expect(_ids(archive.hiddenSessions), ['s1']);
    expect(archive.hiddenSessions.single.title, 'Pending');
    gate.complete({'ok': true, 'hidden': true});
    await archive.remoteStateSettled;
    expect(_ids(archive.hiddenSessions), ['s1']);
  });

  test('a failed show puts the chat back in the hidden list', () async {
    final server = _Server();
    final archive = await _open(server);
    await archive.hideSession(_row('s1'));
    await archive.remoteStateSettled;
    server.answer = (_) => throw const _HttpError(503);

    await archive.unhideSession(_row('s1', hidden: null));
    await archive.remoteStateSettled;
    expect(_ids(archive.hiddenSessions), ['s1']);
    expect(archive.isSessionHidden(_row('s1', hidden: null)), isTrue);
    expect(archive.revealedSessions, isEmpty);
  });
}
