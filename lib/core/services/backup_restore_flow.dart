import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'action_follower.dart';
import 'backup_zip_summary.dart';

/// A backup the server just wrote. [archive] is a server path kept in memory
/// for the life of the page only.
class BackupCreated {
  const BackupCreated({required this.archive, required this.name});

  final String archive;
  final String name;
}

/// The server has no backup route (404 or 405).
class BackupRouteMissing implements Exception {
  const BackupRouteMissing();
}

/// The Dashboard calls a backup needs. Every call carries the profile it acts
/// on, `default` included.
abstract class HermesBackupGateway {
  Future<BackupCreated> createBackup(String profile);

  Future<void> downloadBackup(String archive, String profile, File target);

  Future<void> importUpload(String profile, File zip, {required bool force});

  Future<Map<String, dynamic>> actionStatus(String name);
}

enum BackupFlowStep {
  idle,
  backupRunning,
  backupDone,
  inspect,
  confirm,
  safetyBackup,
  upload,
  importing,
  status,
  refresh,
  done,
  failed,
}

enum BackupFailureKind {
  lockDenied,
  unsupported,
  badArchive,
  backupFailed,
  safetyBackupFailed,
  importFailed,
  timedOut,
  network,
  cancelled,
  refreshFailed,
}

/// Why a step failed. Carries a kind only: never server text or a path.
class BackupFailure {
  const BackupFailure(this.kind);

  final BackupFailureKind kind;

  @override
  String toString() => 'BackupFailure(${kind.name})';
}

/// Create, download and restore server backups.
///
/// Restore is an explicit state machine
/// (`inspect → confirm → safetyBackup → upload → importing → status →
/// refresh`). Until `status` reports a terminal result nothing local is
/// touched: the only thing this class ever calls outside the Dashboard is
/// [refresh], and only after that terminal status. Temp files are always
/// deleted; archive paths live in memory for the life of the page.
class BackupRestoreFlow extends ChangeNotifier {
  BackupRestoreFlow({
    required this.gateway,
    required this.profile,
    required this.verify,
    required this.refresh,
    required this.tempDirectory,
    required this.saveToPhone,
    required this.isVisible,
    ActionFollower Function(
      Future<Map<String, dynamic>> Function(String name) read,
    )?
    followerFor,
  }) : _followerFor =
           followerFor ?? ((read) => ActionFollower(read: read, maxReads: 240));

  final HermesBackupGateway gateway;
  final String profile;

  /// App Lock verification; the argument is the reason shown to the user.
  final Future<bool> Function(String reason) verify;

  /// Re-reads profiles, sessions and connection-scoped caches from the
  /// server, replacing (never merging) what was cached.
  final Future<void> Function() refresh;

  final Future<Directory> Function() tempDirectory;

  /// Hands a downloaded file to the system save/share sheet.
  final Future<void> Function(File file) saveToPhone;

  /// False while the page is covered or the app is in the background.
  final bool Function() isVisible;

  final ActionFollower Function(
    Future<Map<String, dynamic>> Function(String name) read,
  )
  _followerFor;

  BackupFlowStep _step = BackupFlowStep.idle;
  BackupFailure? _failure;
  BackupZipSummary? _summary;
  List<String> _lines = const [];
  String? _archive;
  String? _safetyArchive;
  File? _picked;
  bool _deletePicked = false;
  bool _busy = false;
  bool _disposed = false;

  BackupFlowStep get step => _step;
  BackupFailure? get failure => _failure;
  BackupZipSummary? get summary => _summary;

  /// Last status lines of the running or finished server action.
  List<String> get lines => _lines;

  /// Server path of the last backup made on this page.
  String? get archive => _archive;

  /// The safety backup made before a restore, offered after a failed import.
  String? get safetyArchive => _safetyArchive;

  bool get busy => _busy;

  bool _alive() => !_disposed && isVisible();

  void _set(BackupFlowStep step, {BackupFailure? failure}) {
    _step = step;
    _failure = failure;
    if (!_disposed) notifyListeners();
  }

  BackupFailure _failureFor(Object error) => switch (error) {
    BackupRouteMissing() => const BackupFailure(BackupFailureKind.unsupported),
    _ => const BackupFailure(BackupFailureKind.network),
  };

  Future<bool> _verified(String reason) async {
    try {
      if (await verify(reason)) return true;
    } catch (_) {}
    _failure = const BackupFailure(BackupFailureKind.lockDenied);
    if (!_disposed) notifyListeners();
    return false;
  }

  /// Makes a backup of the profile. Nothing is sent until [confirmed] says the
  /// user accepted the warning about what the file contains.
  Future<void> createBackup({required bool confirmed}) async {
    if (!confirmed || _busy || _disposed) return;
    _busy = true;
    try {
      if (!await _verified('backup')) return;
      _set(BackupFlowStep.backupRunning);
      final result = await _runBackup();
      switch (result.state) {
        case _BackupRun.ok:
          _archive = result.archive;
          _set(BackupFlowStep.backupDone);
        case _BackupRun.failed:
          _set(
            BackupFlowStep.failed,
            failure: const BackupFailure(BackupFailureKind.backupFailed),
          );
        case _BackupRun.timedOut:
          _set(
            BackupFlowStep.failed,
            failure: const BackupFailure(BackupFailureKind.timedOut),
          );
        case _BackupRun.cancelled:
          _set(
            BackupFlowStep.failed,
            failure: const BackupFailure(BackupFailureKind.cancelled),
          );
      }
    } catch (error) {
      _set(BackupFlowStep.failed, failure: _failureFor(error));
    } finally {
      _busy = false;
    }
  }

  Future<({_BackupRun state, String? archive})> _runBackup() async {
    final created = await gateway.createBackup(profile);
    final outcome = await _followerFor(gateway.actionStatus).follow(
      'backup',
      keepGoing: _alive,
      onLines: (lines) {
        _lines = lines;
        if (!_disposed) notifyListeners();
      },
    );
    return switch (outcome.state) {
      ActionFollowState.cancelled => (
        state: _BackupRun.cancelled,
        archive: null,
      ),
      ActionFollowState.timedOut => (state: _BackupRun.timedOut, archive: null),
      ActionFollowState.finished when outcome.succeeded => (
        state: _BackupRun.ok,
        archive: created.archive,
      ),
      ActionFollowState.finished => (state: _BackupRun.failed, archive: null),
    };
  }

  /// Downloads the last backup to a temp file, hands it to the save/share
  /// sheet and deletes it again.
  Future<void> downloadToPhone() async {
    final path = _archive;
    if (path == null || _busy || _disposed) return;
    _busy = true;
    File? target;
    try {
      if (!await _verified('download')) return;
      final dir = await tempDirectory();
      final token = Random.secure().nextInt(1 << 32).toRadixString(16);
      target = File('${dir.path}/hermes-backup-$token.zip');
      await gateway.downloadBackup(path, profile, target);
      await saveToPhone(target);
      _failure = null;
    } catch (error) {
      _failure = _failureFor(error);
    } finally {
      await _deleteQuietly(target);
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Reads the zip's central directory and prepares the confirmation.
  /// Sends nothing. When [deleteSourceWhenDone] the file is removed when the
  /// flow ends, is cancelled or refuses it.
  Future<void> inspect(File zip, {required bool deleteSourceWhenDone}) async {
    if (_busy || _disposed) return;
    await _dropPicked();
    _picked = zip;
    _deletePicked = deleteSourceWhenDone;
    _summary = null;
    _set(BackupFlowStep.inspect);
    try {
      _summary = await BackupZipSummary.inspect(zip, profile: profile);
      _set(BackupFlowStep.confirm);
    } on BackupZipRefused {
      await _dropPicked();
      _set(
        BackupFlowStep.failed,
        failure: const BackupFailure(BackupFailureKind.badArchive),
      );
    } catch (_) {
      await _dropPicked();
      _set(
        BackupFlowStep.failed,
        failure: const BackupFailure(BackupFailureKind.badArchive),
      );
    }
  }

  /// Runs the restore. Nothing is sent until [confirmed] says the user
  /// accepted the overwrite warning; `force=true` goes out only then.
  Future<void> restore({
    required bool confirmed,
    required bool safetyBackup,
  }) async {
    final zip = _picked;
    if (!confirmed ||
        _busy ||
        _disposed ||
        zip == null ||
        _step != BackupFlowStep.confirm) {
      return;
    }
    _busy = true;
    try {
      if (!await _verified('restore')) return;
      if (safetyBackup) {
        _set(BackupFlowStep.safetyBackup);
        final result = await _runBackup();
        if (result.state != _BackupRun.ok) {
          _set(
            BackupFlowStep.failed,
            failure: BackupFailure(
              result.state == _BackupRun.cancelled
                  ? BackupFailureKind.cancelled
                  : BackupFailureKind.safetyBackupFailed,
            ),
          );
          return;
        }
        _safetyArchive = result.archive;
      }
      _set(BackupFlowStep.upload);
      await gateway.importUpload(profile, zip, force: true);
      _set(BackupFlowStep.importing);
      _set(BackupFlowStep.status);
      final outcome = await _followerFor(gateway.actionStatus).follow(
        'import',
        keepGoing: _alive,
        onLines: (lines) {
          _lines = lines;
          if (!_disposed) notifyListeners();
        },
      );
      if (outcome.state == ActionFollowState.cancelled) {
        _set(
          BackupFlowStep.failed,
          failure: const BackupFailure(BackupFailureKind.cancelled),
        );
        return;
      }
      if (outcome.state == ActionFollowState.timedOut) {
        _set(
          BackupFlowStep.failed,
          failure: const BackupFailure(BackupFailureKind.timedOut),
        );
        return;
      }
      // Terminal status: the server may have restored some or all files, so
      // local caches are re-read once, whatever the exit code.
      _set(BackupFlowStep.refresh);
      var refreshFailed = false;
      try {
        await refresh();
      } catch (_) {
        refreshFailed = true;
      }
      if (!outcome.succeeded) {
        _set(
          BackupFlowStep.failed,
          failure: const BackupFailure(BackupFailureKind.importFailed),
        );
      } else {
        _set(
          BackupFlowStep.done,
          failure: refreshFailed
              ? const BackupFailure(BackupFailureKind.refreshFailed)
              : null,
        );
      }
    } catch (error) {
      _set(BackupFlowStep.failed, failure: _failureFor(error));
    } finally {
      _busy = false;
      if (_step == BackupFlowStep.done || _step == BackupFlowStep.failed) {
        await _dropPicked();
      }
      if (!_disposed) notifyListeners();
    }
  }

  /// Abandons the confirmation (or a finished result) and deletes the picked
  /// zip. Never touches the server.
  void cancel() {
    if (_busy) return;
    _summary = null;
    _lines = const [];
    _failure = null;
    unawaited(_dropPicked());
    _step = BackupFlowStep.idle;
    if (!_disposed) notifyListeners();
  }

  Future<void> _dropPicked() async {
    final file = _picked;
    final delete = _deletePicked;
    _picked = null;
    _deletePicked = false;
    if (delete) _deleteNow(file);
  }

  static Future<void> _deleteQuietly(File? file) async => _deleteNow(file);

  static void _deleteNow(File? file) {
    if (file == null) return;
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final picked = _picked;
    final delete = _deletePicked;
    _picked = null;
    _archive = null;
    _safetyArchive = null;
    if (delete && picked != null) {
      try {
        if (picked.existsSync()) picked.deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }
}

enum _BackupRun { ok, failed, timedOut, cancelled }
