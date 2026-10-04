import 'dart:io';

import 'package:hermes_android/core/services/backup_restore_flow.dart';

/// Scriptable [HermesBackupGateway]. Every call is recorded as a short string
/// (`create:<profile>`, `upload:<profile>:force=<bool>`, ...); [failOn] can
/// return an exception to throw for a given call.
class FakeBackupGateway implements HermesBackupGateway {
  final List<String> calls = [];
  Object? Function(String call)? failOn;
  int createdCount = 0;

  /// Exit code each action ends with.
  int backupExit = 0;
  int importExit = 0;
  List<String> importLines = const ['restored 12 files'];
  List<String> backupLines = const ['backup written'];

  /// Status reads that answer "running" before the terminal one.
  int runningReads = 1;
  final Map<String, int> _reads = {};

  void _record(String call) {
    calls.add(call);
    final error = failOn?.call(call);
    if (error != null) throw error;
  }

  @override
  Future<BackupCreated> createBackup(String profile) async {
    _record('create:$profile');
    createdCount += 1;
    return BackupCreated(
      archive: '/srv/backups/b$createdCount.zip',
      name: 'backup',
    );
  }

  @override
  Future<void> downloadBackup(
    String archive,
    String profile,
    File target,
  ) async {
    _record('download:$profile:$archive');
    await target.writeAsBytes([1, 2, 3]);
  }

  @override
  Future<void> importUpload(
    String profile,
    File zip, {
    required bool force,
  }) async {
    _record('upload:$profile:force=$force');
  }

  @override
  Future<Map<String, dynamic>> actionStatus(String name) async {
    _record('status:$name');
    final reads = _reads[name] = (_reads[name] ?? 0) + 1;
    if (reads <= runningReads) {
      return {
        'running': true,
        'exit_code': null,
        'lines': ['working'],
      };
    }
    _reads[name] = 0;
    return {
      'running': false,
      'exit_code': name == 'backup' ? backupExit : importExit,
      'lines': name == 'backup' ? backupLines : importLines,
    };
  }
}
