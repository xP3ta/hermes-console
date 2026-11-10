import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/approval_display.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  final strings = lookupStrings(const Locale('es'));
  test('execution objectives keep all absolute paths, including Windows', () {
    for (final target in [
      '/home/ana/proyectos',
      '/etc',
      '/root',
      '/var/log',
      '/tmp/build',
      '/opt/app',
      '/srv/app',
      '/mnt/disk',
      '/data/app',
      '/run/service',
      '/users/name',
      r'C:\Users\Name\proyectos',
      r'D:\data\backup',
    ]) {
      final command = 'rm -rf $target';
      expect(approvalDisplayText(command, strings), command);
    }
    expect(
      approvalDisplayText('chmod -R 777 /etc', strings),
      'chmod -R 777 /etc',
    );
  });

  final credentials = <String>[
    'AWS_SECRET_ACCESS_KEY=SYNTHETIC_CREDENTIAL',
    'AWS_ACCESS_KEY_ID=SYNTHETIC_CREDENTIAL',
    'client_secret_value="SYNTHETIC_CREDENTIAL"',
    'curl -u user:SYNTHETIC_CREDENTIAL https://example.test',
    'curl -uuser:SYNTHETIC_CREDENTIAL https://example.test',
    'curl -U "user:SYNTHETIC_CREDENTIAL" https://example.test',
    "sshpass -p 'SYNTHETIC_CREDENTIAL' ssh -p 22 example.test",
    'mysql -pSYNTHETIC_CREDENTIAL -h example.test',
    'mysql -p SYNTHETIC_CREDENTIAL -h example.test',
    'curl --password SYNTHETIC_CREDENTIAL https://example.test',
    'curl --password=SYNTHETIC_CREDENTIAL https://example.test',
    'curl -H "Cookie: sid=SYNTHETIC_CREDENTIAL; other=SECOND_CREDENTIAL" https://example.test',
    'curl -H "X-Api-Key: SYNTHETIC_CREDENTIAL" https://example.test',
    "curl -H 'X-Api-Key: SYNTHETIC_CREDENTIAL' https://example.test",
    'curl -H X-Api-Key:SYNTHETIC_CREDENTIAL https://example.test',
    'curl -H "Authorization: Bearer SYNTHETIC_CREDENTIAL" https://example.test',
    '{"Cookie":"sid=SYNTHETIC_CREDENTIAL; other=SECOND_CREDENTIAL"}',
    'Cookie: sid=SYNTHETIC_CREDENTIAL; other=SECOND_CREDENTIAL',
    'curl https://user:SYNTHETIC_CREDENTIAL@example.test',
  ];
  for (var i = 0; i < credentials.length; i++) {
    test(
      'credential form $i is covered without hiding the execution target',
      () {
        final result = approvalDisplayText(
          '${credentials[i]}\nrm -rf /home/ana/proyectos',
          strings,
        );
        expect(result, isNot(contains('SYNTHETIC_CREDENTIAL')));
        expect(result, isNot(contains('SECOND_CREDENTIAL')));
        expect(result, contains('/home/ana/proyectos'));
      },
    );
  }
  test('credential short options do not hide unrelated command targets', () {
    const command = 'mkdir -p /home/ana/proyectos\nchmod -u /etc';
    expect(approvalDisplayText(command, strings), command);
    const curl =
        'curl -u user:SYNTHETIC_CREDENTIAL -o /tmp/result https://example.test';
    expect(approvalDisplayText(curl, strings), contains('-o /tmp/result'));
    expect(
      approvalDisplayText(
        "sshpass -p 'SYNTHETIC_CREDENTIAL' ssh -p 22 host",
        strings,
      ),
      contains('ssh -p 22 host'),
    );
  });
}
