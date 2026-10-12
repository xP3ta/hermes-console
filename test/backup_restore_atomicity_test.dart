// A restore that fails at any step leaves every local store byte-identical,
// and a refresh after a finished one replaces the roster from the server read
// instead of appending to it. Local stores: saved connections, credentials,
// the bot roster cache, cold-start recents, drafts, the outbox and archive
// overlays.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/action_follower.dart';
import 'package:hermes_android/core/services/backup_restore_flow.dart';
import 'package:hermes_android/core/services/bot_roster_cache.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/restore_refresh.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backup_gateway.dart';

final _conn = SavedConnection(
  id: 'conn-1',
  label: 'Home',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: 'k',
);

AgentProfile _p(String name) => AgentProfile(name: name);

final _fixed = DateTime.utc(2026, 10, 4, 12);

Future<File> _zip(Directory dir) async {
  final archive = Archive()
    ..addFile(ArchiveFile('config.yaml', 3, Uint8List(3)));
  final file = File('${dir.path}/r.zip');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

/// Everything local a restore must not disturb, as comparable text.
Future<String> _snapshot(
  SharedPreferences prefs,
  BotRosterRegistry roster,
) async {
  final keys = prefs.getKeys().toList()..sort();
  final secure = await const FlutterSecureStorage().readAll();
  final secureKeys = secure.keys.toList()..sort();
  return jsonEncode({
    'prefs': {for (final k in keys) k: prefs.get(k)},
    'secure': {for (final k in secureKeys) k: secure[k]},
    'roster': [for (final p in roster.store(_conn.id).profiles) p.name],
  });
}

void main() {
  late Directory dir;
  late SharedPreferences prefs;
  late BotRosterRegistry roster;
  late FakeBackupGateway gateway;
  late List<AgentProfile> serverRoster;

  Future<void> refreshRoster() => refreshAfterRestore(
    connection: _conn,
    readProfiles: () async => serverRoster,
    roster: roster,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bk-atomic-');
    SharedPreferences.setMockInitialValues({
      'connections': jsonEncode([
        {'id': 'conn-1', 'label': 'Home'},
      ]),
      'draft.conn-1.s1': 'half-written message',
      'outbox.conn-1': jsonEncode(['queued']),
      'archive.overlay.conn-1': jsonEncode(['s9']),
      'cold_start.recents.conn-1': jsonEncode(['s1', 's2']),
    });
    FlutterSecureStorage.setMockInitialValues({'cred.conn-1': 'token-123'});
    prefs = await SharedPreferences.getInstance();
    roster = BotRosterRegistry(now: () => _fixed)
      ..attachPersistence(prefs, [_conn]);
    gateway = FakeBackupGateway();
    serverRoster = [_p('default'), _p('work')];
    await refreshRoster();
  });

  tearDown(() async => dir.delete(recursive: true));

  BackupRestoreFlow flow({Future<void> Function()? refresh}) {
    final f = BackupRestoreFlow(
      gateway: gateway,
      profile: 'default',
      verify: (_) async => true,
      refresh: refresh ?? refreshRoster,
      tempDirectory: () async => dir,
      saveToPhone: (_) async {},
      isVisible: () => true,
      followerFor: (read) => ActionFollower(read: read, delay: (_) async {}),
    );
    addTearDown(f.dispose);
    return f;
  }

  // The server's roster changed, so a refresh that ran too early (or at all,
  // on a failure) would show up in the snapshot.
  void serverChanged() => serverRoster = [_p('default'), _p('work'), _p('new')];

  final modes = <String, Object Function()>{
    'throw': () => StateError('boom'),
    'http 500': () => DashboardHttpException(500),
    'socket drop': () => const SocketException('connection reset'),
  };

  // Failure after every step of the machine, in every way a step can fail.
  for (final entry in modes.entries) {
    for (final step in ['create', 'status:backup', 'upload', 'status:import']) {
      test(
        '${entry.key} at $step leaves every local store identical',
        () async {
          final before = await _snapshot(prefs, roster);
          gateway.failOn = (call) =>
              call.startsWith(step) ? entry.value() : null;
          final f = flow();
          await f.inspect(await _zip(dir), deleteSourceWhenDone: true);
          await f.restore(confirmed: true, safetyBackup: true);
          expect(f.step, BackupFlowStep.failed, reason: step);
          expect(await _snapshot(prefs, roster), before);
        },
      );
    }
  }

  test('a refresh that throws leaves every local store identical', () async {
    final before = await _snapshot(prefs, roster);
    serverChanged();
    final f = flow(
      refresh: () async => throw StateError('profiles read failed'),
    );
    await f.inspect(await _zip(dir), deleteSourceWhenDone: true);
    await f.restore(confirmed: true, safetyBackup: true);
    expect(await _snapshot(prefs, roster), before);
  });

  test(
    'exit 1 at the safety backup leaves every local store identical',
    () async {
      final before = await _snapshot(prefs, roster);
      serverChanged();
      gateway.backupExit = 1;
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: true);
      await f.restore(confirmed: true, safetyBackup: true);
      expect(await _snapshot(prefs, roster), before);
    },
  );

  test(
    'exit 1 at the import re-reads an unchanged server and changes nothing',
    () async {
      final before = await _snapshot(prefs, roster);
      gateway.importExit = 1;
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: true);
      await f.restore(confirmed: true, safetyBackup: true);
      expect(f.step, BackupFlowStep.failed);
      expect(await _snapshot(prefs, roster), before);
    },
  );

  test('a corrupt zip leaves every local store identical', () async {
    final before = await _snapshot(prefs, roster);
    serverChanged();
    final bad = File('${dir.path}/bad.zip')..writeAsStringSync('nope');
    final f = flow();
    await f.inspect(bad, deleteSourceWhenDone: true);
    expect(await _snapshot(prefs, roster), before);
    expect(gateway.calls, isEmpty);
  });

  test(
    'cancelling the confirmation leaves every local store identical',
    () async {
      final before = await _snapshot(prefs, roster);
      serverChanged();
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: true);
      f.cancel();
      expect(await _snapshot(prefs, roster), before);
    },
  );

  test(
    'nothing local changes before the import reports a terminal status',
    () async {
      final before = await _snapshot(prefs, roster);
      serverChanged();
      gateway.runningReads = 2;
      final during = <Future<String>>[];
      gateway.failOn = (call) {
        if (call.startsWith('upload') || call == 'status:import') {
          during.add(_snapshot(prefs, roster));
        }
        return null;
      };
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: true);
      await f.restore(confirmed: true, safetyBackup: false);
      expect(during.length, greaterThanOrEqualTo(3));
      expect((await Future.wait(during)).toSet(), {before});
    },
  );

  test(
    'a successful restore replaces the roster; a repeated profile appears once',
    () async {
      serverRoster = [
        _p('default'),
        _p('work'),
        _p('work'),
        _p('default'),
        _p('new'),
      ];
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: true);
      await f.restore(confirmed: true, safetyBackup: true);
      expect(f.step, BackupFlowStep.done);
      final names = [for (final p in roster.store(_conn.id).profiles) p.name];
      expect(names, ['default', 'work', 'new']);
      final cached = BotRosterCache(
        prefs,
      ).read(_conn).map((p) => p.name).toList();
      expect(cached, ['default', 'work', 'new']);
    },
  );

  test(
    'a successful restore does not duplicate or rewrite the connection',
    () async {
      final before = prefs.getString('connections');
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: true);
      await f.restore(confirmed: true, safetyBackup: true);
      expect(prefs.getString('connections'), before);
      expect(prefs.getString('draft.conn-1.s1'), 'half-written message');
      expect(prefs.getString('outbox.conn-1'), jsonEncode(['queued']));
    },
  );

  test('profiles that disappeared on the server disappear locally', () async {
    serverRoster = [_p('default')];
    final f = flow();
    await f.inspect(await _zip(dir), deleteSourceWhenDone: true);
    await f.restore(confirmed: true, safetyBackup: false);
    expect(
      [for (final p in roster.store(_conn.id).profiles) p.name],
      ['default'],
    );
  });

  test(
    'refresh replaces, never appends: running it twice is the same as once',
    () async {
      serverRoster = [_p('default'), _p('work')];
      await refreshRoster();
      await refreshRoster();
      expect(
        [for (final p in roster.store(_conn.id).profiles) p.name],
        ['default', 'work'],
      );
    },
  );
}
