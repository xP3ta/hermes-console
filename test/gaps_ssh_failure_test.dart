import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/utils/ssh_error.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  final en = lookupStrings(const Locale('en'));
  final es = lookupStrings(const Locale('es'));

  group('typed SSH/SFTP failures (gap 1)', () {
    test('a rejected host key is named, also wrapped in an auth abort', () {
      final direct = SSHHostkeyError('Hostkey verification failed');
      final wrapped = SSHAuthAbortError(
        'Connection closed before authentication',
        direct,
      );
      for (final e in [direct, wrapped]) {
        expect(SshManager.classifyError(e), SshFailure.hostKeyRejected);
        expect(SshManager.isTransientFailure(e), isFalse);
        expect(
          localizedSshError(en, e),
          'The server key is not trusted: not connected.',
        );
      }
      expect(
        localizedSshError(es, wrapped),
        'La clave del servidor no es de confianza: no se ha conectado.',
      );
    });

    test('SFTP permission denied and no such file are named', () {
      final denied = SftpStatusError(
        SftpStatusCode.permissionDenied,
        'Permission denied',
      );
      final missing = SftpStatusError(
        SftpStatusCode.noSuchFile,
        'No such file',
      );
      expect(SshManager.classifyError(denied), SshFailure.permissionDenied);
      expect(SshManager.classifyError(missing), SshFailure.noSuchFile);
      expect(localizedSshError(en, denied), 'Permission denied.');
      expect(localizedSshError(es, denied), 'Permiso denegado.');
      expect(
        localizedSshError(es, missing),
        'No existe (se borró o se movió).',
      );
      // Neither is worth an automatic retry.
      expect(SshManager.isTransientFailure(denied), isFalse);
      expect(SshManager.isTransientFailure(missing), isFalse);
    });

    test('other SFTP statuses stay generic', () {
      expect(
        SshManager.classifyError(SftpStatusError(4, 'Failure')),
        SshFailure.unknown,
      );
    });

    test('every failure has copy in every catalog language', () {
      const langs = ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];
      for (final lang in langs) {
        final strings = lookupStrings(Locale(lang));
        for (final failure in SshFailure.values) {
          expect(
            localizedSshFailure(strings, failure).trim(),
            isNotEmpty,
            reason: '$lang:$failure',
          );
        }
      }
    });
  });
}
