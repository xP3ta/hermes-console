// Backup and restore, step by step: confirmation before anything is sent,
// `?profile=` on every call (default included), the safety backup first and
// required to succeed, `force=true` only after the confirmation, the status
// follower tied to visibility, and every temp file deleted.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/action_follower.dart';
import 'package:hermes_android/core/services/backup_restore_flow.dart';
import 'package:hermes_android/core/services/backup_zip_summary.dart';

import 'support/fake_backup_gateway.dart';

Future<File> _zip(Directory dir) async {
  final archive = Archive()
    ..addFile(ArchiveFile('config.yaml', 3, Uint8List(3)))
    ..addFile(ArchiveFile('state.db', 5, Uint8List(5)));
  final file = File('${dir.path}/restore-me.zip');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

void main() {
  late Directory dir;
  late FakeBackupGateway gateway;
  late List<String> verifies;
  late int refreshes;
  late List<File> shared;
  var visible = true;
  var verifyResult = true;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bk-flow-');
    gateway = FakeBackupGateway();
    verifies = [];
    refreshes = 0;
    shared = [];
    visible = true;
    verifyResult = true;
  });

  tearDown(() async => dir.delete(recursive: true));

  BackupRestoreFlow flow({String profile = 'default'}) {
    final f = BackupRestoreFlow(
      gateway: gateway,
      profile: profile,
      verify: (reason) async {
        verifies.add(reason);
        return verifyResult;
      },
      refresh: () async => refreshes++,
      tempDirectory: () async => dir,
      saveToPhone: (file) async {
        // The file must exist while the share sheet has it.
        expect(file.existsSync(), isTrue);
        shared.add(file);
      },
      isVisible: () => visible,
      followerFor: (read) => ActionFollower(read: read, delay: (_) async {}),
    );
    addTearDown(f.dispose);
    return f;
  }

  group('create', () {
    test('nothing is sent until the user confirmed the warning', () async {
      final f = flow();
      await f.createBackup(confirmed: false);
      expect(gateway.calls, isEmpty);
      expect(verifies, isEmpty);
    });

    test(
      'verify, create with ?profile=default, follow, keep the archive',
      () async {
        final f = flow();
        await f.createBackup(confirmed: true);
        expect(verifies, hasLength(1));
        expect(gateway.calls.first, 'create:default');
        expect(gateway.calls.where((c) => c == 'status:backup'), isNotEmpty);
        expect(f.step, BackupFlowStep.backupDone);
        expect(f.archive, '/srv/backups/b1.zip');
      },
    );

    test('a failed verify sends nothing', () async {
      verifyResult = false;
      final f = flow();
      await f.createBackup(confirmed: true);
      expect(gateway.calls, isEmpty);
      expect(f.failure?.kind, BackupFailureKind.lockDenied);
    });

    test('a non-zero exit is a failed backup with the server lines', () async {
      gateway.backupExit = 1;
      gateway.backupLines = ['disk full'];
      final f = flow();
      await f.createBackup(confirmed: true);
      expect(f.step, BackupFlowStep.failed);
      expect(f.lines, ['disk full']);
      expect(f.archive, isNull);
    });

    test('a named profile is sent as is', () async {
      final f = flow(profile: 'work');
      await f.createBackup(confirmed: true);
      expect(gateway.calls.first, 'create:work');
    });
  });

  group('download', () {
    test('streams to a temp file, hands it over, then deletes it', () async {
      final f = flow();
      await f.createBackup(confirmed: true);
      await f.downloadToPhone();
      expect(gateway.calls, contains('download:default:/srv/backups/b1.zip'));
      expect(shared, hasLength(1));
      expect(shared.single.existsSync(), isFalse);
      expect(dir.listSync(), isEmpty);
    });

    test('the temp file is deleted even when the share sheet throws', () async {
      final f = BackupRestoreFlow(
        gateway: gateway,
        profile: 'default',
        verify: (_) async => true,
        refresh: () async {},
        tempDirectory: () async => dir,
        saveToPhone: (_) async => throw StateError('no share target'),
        isVisible: () => true,
        followerFor: (read) => ActionFollower(read: read, delay: (_) async {}),
      );
      addTearDown(f.dispose);
      await f.createBackup(confirmed: true);
      await f.downloadToPhone();
      expect(dir.listSync(), isEmpty);
      expect(f.failure, isNotNull);
    });

    test('the temp file is deleted when the download fails midway', () async {
      gateway.failOn = (c) =>
          c.startsWith('download') ? const SocketException('drop') : null;
      final f = flow();
      await f.createBackup(confirmed: true);
      await f.downloadToPhone();
      expect(dir.listSync(), isEmpty);
    });

    test('the safety backup can be downloaded after a failed import', () async {
      gateway.importExit = 1;
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
      await f.restore(confirmed: true, safetyBackup: true);
      await f.downloadToPhone(safety: true);
      expect(gateway.calls, contains('download:default:/srv/backups/b1.zip'));
      expect(shared, hasLength(1));
    });

    test('without a backup there is nothing to download', () async {
      final f = flow();
      await f.downloadToPhone();
      expect(gateway.calls, isEmpty);
    });

    test('download asks for verification again', () async {
      final f = flow();
      await f.createBackup(confirmed: true);
      await f.downloadToPhone();
      expect(verifies, hasLength(2));
    });
  });

  group('status follower', () {
    test('stops without more reads when the page is covered', () async {
      gateway.runningReads = 100;
      final f = BackupRestoreFlow(
        gateway: gateway,
        profile: 'default',
        verify: (_) async => true,
        refresh: () async {},
        tempDirectory: () async => dir,
        saveToPhone: (_) async {},
        isVisible: () => visible,
        followerFor: (read) => ActionFollower(
          read: (name) async {
            final answer = await read(name);
            visible = false; // the user covered the page after the first read
            return answer;
          },
          delay: (_) async {},
        ),
      );
      addTearDown(f.dispose);
      await f.createBackup(confirmed: true);
      expect(gateway.calls.where((c) => c == 'status:backup'), hasLength(1));
      expect(f.step, isNot(BackupFlowStep.backupDone));
    });

    test('stops after dispose', () async {
      gateway.runningReads = 100;
      late BackupRestoreFlow f;
      f = BackupRestoreFlow(
        gateway: gateway,
        profile: 'default',
        verify: (_) async => true,
        refresh: () async {},
        tempDirectory: () async => dir,
        saveToPhone: (_) async {},
        isVisible: () => true,
        followerFor: (read) => ActionFollower(
          read: (name) async {
            final answer = await read(name);
            f.dispose();
            return answer;
          },
          delay: (_) async {},
        ),
      );
      await f.createBackup(confirmed: true);
      expect(gateway.calls.where((c) => c == 'status:backup'), hasLength(1));
    });
  });

  group('restore', () {
    test('inspect builds the summary and sends nothing', () async {
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
      expect(f.step, BackupFlowStep.confirm);
      expect(f.summary?.fileCount, 2);
      expect(f.summary?.profile, 'default');
      expect(gateway.calls, isEmpty);
    });

    test('nothing is sent before the user confirms', () async {
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
      await f.restore(confirmed: false, safetyBackup: true);
      expect(gateway.calls, isEmpty);
      expect(verifies, isEmpty);
    });

    test(
      'order: verify, safety backup, upload with force, status, one refresh',
      () async {
        final f = flow();
        await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
        await f.restore(confirmed: true, safetyBackup: true);
        final order = gateway.calls
            .where((c) => !c.startsWith('status'))
            .toList();
        expect(order, ['create:default', 'upload:default:force=true']);
        final firstUpload = gateway.calls.indexOf('upload:default:force=true');
        final lastBackupStatus = gateway.calls.lastIndexOf('status:backup');
        expect(lastBackupStatus, lessThan(firstUpload));
        expect(gateway.calls.last, 'status:import');
        expect(refreshes, 1);
        expect(f.step, BackupFlowStep.done);
        expect(verifies, hasLength(1));
      },
    );

    test('force is never sent before the confirmation', () async {
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
      expect(gateway.calls.where((c) => c.contains('force')), isEmpty);
      await f.restore(confirmed: true, safetyBackup: false);
      expect(
        gateway.calls.where((c) => c.contains('force=true')),
        hasLength(1),
      );
      expect(gateway.calls.where((c) => c.contains('force=false')), isEmpty);
    });

    test('with the safety backup off, no backup is made', () async {
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
      await f.restore(confirmed: true, safetyBackup: false);
      expect(gateway.calls.where((c) => c.startsWith('create')), isEmpty);
    });

    test('a failed safety backup stops before the upload', () async {
      gateway.backupExit = 1;
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
      await f.restore(confirmed: true, safetyBackup: true);
      expect(gateway.calls.where((c) => c.startsWith('upload')), isEmpty);
      expect(f.step, BackupFlowStep.failed);
      expect(f.failure?.kind, BackupFailureKind.safetyBackupFailed);
      expect(refreshes, 0);
    });

    test(
      'exit 1 shows the server lines, offers the safety backup and still refreshes',
      () async {
        gateway.importExit = 1;
        gateway.importLines = ['incomplete restore: 2 files failed'];
        final f = flow();
        await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
        await f.restore(confirmed: true, safetyBackup: true);
        expect(f.step, BackupFlowStep.failed);
        expect(f.failure?.kind, BackupFailureKind.importFailed);
        expect(f.lines, ['incomplete restore: 2 files failed']);
        expect(f.safetyArchive, '/srv/backups/b1.zip');
        expect(
          refreshes,
          1,
          reason: 'a terminal status may mean a partial restore',
        );
      },
    );

    test('an upload failure never refreshes', () async {
      gateway.failOn = (c) =>
          c.startsWith('upload') ? StateError('http 500') : null;
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
      await f.restore(confirmed: true, safetyBackup: false);
      expect(refreshes, 0);
      expect(f.step, BackupFlowStep.failed);
    });

    test(
      'the picked zip is deleted when the flow ends or is cancelled',
      () async {
        final zip = await _zip(dir);
        final f = flow();
        await f.inspect(zip, deleteSourceWhenDone: true);
        f.cancel();
        expect(zip.existsSync(), isFalse);
        expect(f.step, BackupFlowStep.idle);
        expect(gateway.calls, isEmpty);
      },
    );

    test('the picked zip is deleted after a finished restore', () async {
      final zip = await _zip(dir);
      final f = flow();
      await f.inspect(zip, deleteSourceWhenDone: true);
      await f.restore(confirmed: true, safetyBackup: false);
      expect(zip.existsSync(), isFalse);
    });

    test('a refused zip is deleted and sends nothing', () async {
      final bad = File('${dir.path}/bad.zip')..writeAsStringSync('nope');
      final f = flow();
      await f.inspect(bad, deleteSourceWhenDone: true);
      expect(f.failure?.kind, BackupFailureKind.badArchive);
      expect(f.failure?.zipProblem, BackupZipProblem.notAZip);
      expect(bad.existsSync(), isFalse);
      expect(gateway.calls, isEmpty);
    });

    test('a failed verify at restore sends nothing', () async {
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
      verifyResult = false;
      await f.restore(confirmed: true, safetyBackup: true);
      expect(gateway.calls, isEmpty);
      expect(f.failure?.kind, BackupFailureKind.lockDenied);
    });

    test('a second restore cannot start while one runs', () async {
      gateway.runningReads = 3;
      final f = flow();
      await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
      final first = f.restore(confirmed: true, safetyBackup: false);
      await f.restore(confirmed: true, safetyBackup: false);
      await first;
      expect(gateway.calls.where((c) => c.startsWith('upload')), hasLength(1));
    });
  });

  test(
    'a 404 or 405 on the backup route marks the feature unsupported',
    () async {
      gateway.failOn = (c) =>
          c.startsWith('create') ? const BackupRouteMissing() : null;
      final f = flow();
      await f.createBackup(confirmed: true);
      expect(f.failure?.kind, BackupFailureKind.unsupported);
    },
  );

  test('no failure ever carries server text or a path', () async {
    gateway.failOn = (c) =>
        c.startsWith('upload') ? StateError('/srv/secret/path-marker') : null;
    final f = flow();
    await f.inspect(await _zip(dir), deleteSourceWhenDone: false);
    await f.restore(confirmed: true, safetyBackup: false);
    expect(f.failure.toString(), isNot(contains('path-marker')));
  });
}
