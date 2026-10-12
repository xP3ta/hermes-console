// The pre-restore summary is built on the phone from the zip's central
// directory only: nothing is extracted, nothing is sent.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/backup_zip_summary.dart';

Future<File> _zip(
  Directory dir,
  Map<String, int> entries, {
  String name = 'backup.zip',
}) async {
  final archive = Archive();
  entries.forEach((path, size) {
    archive.addFile(ArchiveFile(path, size, Uint8List(size)));
  });
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('bk-zip-'));
  tearDown(() async => dir.delete(recursive: true));

  test('lists what the restore will replace and what it keeps', () async {
    final file = await _zip(dir, {
      'config.yaml': 10,
      '.env': 20,
      'auth.json': 30,
      'state.db': 4000,
      'memories/a.md': 5,
      'memories/b.md': 5,
      'skills/x/SKILL.md': 7,
      'cron/jobs.json': 3,
      'profiles/work/config.yaml': 11,
      'profiles/work/state.db': 12,
      'profiles/play/config.yaml': 13,
      'notes.txt': 2,
      'gateway.pid': 1,
      'gateway_state.json': 1,
    });
    final summary = await BackupZipSummary.inspect(file, profile: 'default');
    expect(summary.profile, 'default');
    expect(summary.fileCount, 14);
    expect(
      summary.totalBytes,
      10 + 20 + 30 + 4000 + 5 + 5 + 7 + 3 + 11 + 12 + 13 + 2 + 1 + 1,
    );
    expect(
      summary.replaces,
      containsAll([
        BackupItem.config,
        BackupItem.env,
        BackupItem.auth,
        BackupItem.sessions,
        BackupItem.memories,
        BackupItem.skills,
        BackupItem.cron,
        BackupItem.profiles,
      ]),
    );
    expect(summary.profileNames, ['play', 'work']);
    expect(summary.otherFiles, 1);
    expect(summary.keptRuntimeFiles, ['gateway.pid', 'gateway_state.json']);
  });

  test('runtime files are kept, not counted as replaced', () async {
    final file = await _zip(dir, {
      'config.yaml': 1,
      'gateway.pid': 1,
      'cron.pid': 1,
      'gateway.lock': 1,
      'processes.json': 1,
    });
    final summary = await BackupZipSummary.inspect(file, profile: 'p');
    expect(summary.keptRuntimeFiles.length, 4);
    expect(summary.otherFiles, 0);
    expect(summary.replaces, [BackupItem.config]);
  });

  test('a leading ./ is ignored', () async {
    final file = await _zip(dir, {'./config.yaml': 1, './state.db': 2});
    final summary = await BackupZipSummary.inspect(file, profile: 'p');
    expect(
      summary.replaces,
      containsAll([BackupItem.config, BackupItem.sessions]),
    );
  });

  test('a file that is not a zip is refused', () async {
    final file = File('${dir.path}/x.zip')..writeAsStringSync('not a zip');
    await expectLater(
      BackupZipSummary.inspect(file, profile: 'p'),
      throwsA(
        isA<BackupZipRefused>().having(
          (e) => e.reason,
          'reason',
          BackupZipProblem.notAZip,
        ),
      ),
    );
  });

  test('an empty zip is refused', () async {
    final file = await _zip(dir, {});
    await expectLater(
      BackupZipSummary.inspect(file, profile: 'p'),
      throwsA(
        isA<BackupZipRefused>().having(
          (e) => e.reason,
          'reason',
          BackupZipProblem.empty,
        ),
      ),
    );
  });

  test('a file over the size cap is refused before it is read', () async {
    final file = await _zip(dir, {'config.yaml': 1});
    await expectLater(
      BackupZipSummary.inspect(file, profile: 'p', maxBytes: 10),
      throwsA(
        isA<BackupZipRefused>().having(
          (e) => e.reason,
          'reason',
          BackupZipProblem.tooLarge,
        ),
      ),
    );
  });

  test('the default cap is 2 GB', () {
    expect(BackupZipSummary.defaultMaxBytes, 2 * 1024 * 1024 * 1024);
  });

  test('paths that escape the profile are refused', () async {
    for (final bad in ['../evil', 'a/../../evil', '/etc/passwd']) {
      final file = await _zip(dir, {
        'config.yaml': 1,
        bad: 1,
      }, name: 'b${bad.hashCode}.zip');
      await expectLater(
        BackupZipSummary.inspect(file, profile: 'p'),
        throwsA(
          isA<BackupZipRefused>().having(
            (e) => e.reason,
            'reason',
            BackupZipProblem.unsafePath,
          ),
        ),
        reason: bad,
      );
    }
  });

  test('inspecting never writes anything next to the zip', () async {
    final file = await _zip(dir, {'config.yaml': 1});
    final before = dir.listSync().map((e) => e.path).toSet();
    await BackupZipSummary.inspect(file, profile: 'p');
    expect(dir.listSync().map((e) => e.path).toSet(), before);
  });
}
