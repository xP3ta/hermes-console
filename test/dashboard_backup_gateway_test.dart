// The Dashboard side of backups: exact routes, `?profile=` on every call
// (default included), force as a form field, and 404/405 meaning "no backups
// on this server".
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/backup_restore_flow.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dashboard_backup_gateway.dart';

final class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  final List<String> calls = [];
  Map<String, String>? lastFields;
  int? failStatus;
  Map<String, dynamic> answer = {};

  void _maybeFail() {
    final status = failStatus;
    if (status != null) throw DashboardHttpException(status);
  }

  @override
  Future<Map<String, dynamic>> apiPost(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add('POST $endpoint ${body ?? ''}');
    _maybeFail();
    return answer;
  }

  @override
  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    calls.add('GET $endpoint');
    _maybeFail();
    return answer;
  }

  @override
  Future<Map<String, dynamic>> apiPostMultipartFile(
    String endpoint, {
    required String fieldName,
    required String filePath,
    required String filename,
    Map<String, String> fields = const {},
    bool retried = false,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    calls.add('MULTIPART $endpoint $fieldName');
    lastFields = fields;
    _maybeFail();
    return answer;
  }

  @override
  Future<Map<String, String>> apiDownloadToFile(
    String endpoint,
    File target, {
    required int maxBytes,
    String? profile,
    bool retried = false,
    Duration timeout = const Duration(minutes: 3),
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    calls.add('DOWNLOAD $endpoint');
    _maybeFail();
    return const {};
  }
}

void main() {
  late _Dashboard dashboard;
  late DashboardBackupGateway gateway;

  setUp(() {
    dashboard = _Dashboard();
    gateway = DashboardBackupGateway(dashboard);
  });

  test('create posts an empty body with ?profile= even for default', () async {
    dashboard.answer = {
      'ok': true,
      'pid': 1,
      'name': 'backup',
      'archive': '/srv/hermes/backups/hermes-backup-1.zip',
    };
    final created = await gateway.createBackup('default');
    expect(dashboard.calls.single, 'POST ops/backup?profile=default {}');
    expect(created.archive, '/srv/hermes/backups/hermes-backup-1.zip');
  });

  test('a named profile is query-encoded', () async {
    dashboard.answer = {'ok': true, 'archive': '/a.zip', 'name': 'backup'};
    await gateway.createBackup('my team');
    expect(dashboard.calls.single, contains('?profile=my+team'));
  });

  test('a create answer without an archive is refused', () async {
    dashboard.answer = {'ok': true};
    await expectLater(gateway.createBackup('default'), throwsStateError);
    dashboard.answer = {'ok': false, 'archive': '/a.zip'};
    await expectLater(gateway.createBackup('default'), throwsStateError);
  });

  test('download names the archive and the profile', () async {
    await gateway.downloadBackup(
      '/srv/hermes/backups/a b.zip',
      'default',
      File('${Directory.systemTemp.path}/x.zip'),
    );
    expect(
      dashboard.calls.single,
      'DOWNLOAD ops/backup/download?archive=%2Fsrv%2Fhermes%2Fbackups%2Fa+b.zip&profile=default',
    );
  });

  test('import-upload sends the file field, force and the profile', () async {
    await gateway.importUpload('work', File('/tmp/x.zip'), force: true);
    expect(
      dashboard.calls.single,
      'MULTIPART ops/import-upload?profile=work file',
    );
    expect(dashboard.lastFields, {'force': 'true'});
  });

  test('force false is sent as false', () async {
    await gateway.importUpload('work', File('/tmp/x.zip'), force: false);
    expect(dashboard.lastFields, {'force': 'false'});
  });

  test('status reads actions/<name>/status', () async {
    dashboard.answer = {'running': false};
    await gateway.actionStatus('import');
    expect(dashboard.calls.single, 'GET actions/import/status');
  });

  for (final status in [404, 405]) {
    test('$status on create means the server has no backups', () async {
      dashboard.failStatus = status;
      await expectLater(
        gateway.createBackup('default'),
        throwsA(isA<BackupRouteMissing>()),
      );
    });
  }

  test('a 500 is not "missing"', () async {
    dashboard.failStatus = 500;
    await expectLater(
      gateway.createBackup('default'),
      throwsA(isA<DashboardHttpException>()),
    );
  });

  group('availability probe', () {
    test('a 422 from the download route proves it exists', () async {
      dashboard.failStatus = 422;
      expect(await gateway.available(), isTrue);
      expect(dashboard.calls.single, 'GET ops/backup/download');
    });

    test('404 and 405 mean unavailable', () async {
      for (final status in [404, 405]) {
        dashboard.failStatus = status;
        expect(await gateway.available(), isFalse, reason: '$status');
      }
    });

    test('an unrelated failure is not read as unavailable', () async {
      dashboard.failStatus = 500;
      expect(await gateway.available(), isTrue);
    });

    test('the probe never creates a backup', () async {
      dashboard.failStatus = 422;
      await gateway.available();
      expect(dashboard.calls.where((c) => c.startsWith('POST')), isEmpty);
    });
  });
}
