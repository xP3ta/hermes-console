// Saving to the phone (orden SFTP-DESCARGAS, point 4; DESCARGAS-DIRECTAS):
// the name comes from the server (or a sender) and is never trusted. Only
// its last segment, without separators, NUL, control or bidirectional
// characters; nothing usable gives a safe name. It is the name Android's
// «Guardar como» suggests (save_to_device_test checks it reaches the
// dialog so).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/sftp_downloads.dart';

void main() {
  group('sftpSafeFileName', () {
    test('only the last segment of what the server sent', () {
      expect(sftpSafeFileName('/etc/passwd'), 'passwd');
      expect(sftpSafeFileName('../../.ssh/authorized_keys'), 'authorized_keys');
      expect(sftpSafeFileName(r'..\..\Windows\system.ini'), 'system.ini');
      expect(sftpSafeFileName('a\u0000/../b'), 'b');
      expect(sftpSafeFileName('carpeta/'), 'carpeta');
    });

    test('nothing usable gives a safe name', () {
      for (final raw in [
        '',
        '.',
        '..',
        '/',
        '//',
        ' ',
        ' .. ',
        '../..',
        '\u0000',
        '\u0000\u0001',
        '\u202e',
      ]) {
        expect(
          sftpSafeFileName(raw),
          sftpFallbackFileName,
          reason: jsonEncode(raw),
        );
      }
    });

    test('no NUL, control or bidirectional characters', () {
      expect(sftpSafeFileName('a\u0000b.txt'), 'ab.txt');
      expect(sftpSafeFileName('line\nbreak\r.txt'), 'linebreak.txt');
      expect(sftpSafeFileName('a\u007fb'), 'ab');
      // «photo», U+202E, «gpj.exe» would read as «photoexe.jpg».
      expect(sftpSafeFileName('photo\u202egpj.exe'), 'photogpj.exe');
    });

    test('characters a document provider refuses become _', () {
      expect(sftpSafeFileName('what?<>:"|*.txt'), 'what_______.txt');
    });

    test('at most 255 UTF-8 bytes, the extension kept', () {
      final safe = sftpSafeFileName('${'é' * 300}.pdf');
      expect(utf8.encode(safe).length, lessThanOrEqualTo(255));
      expect(safe, endsWith('.pdf'));
    });

    test('a plain name is kept as is', () {
      for (final name in [
        'informe.pdf',
        'Fotos 2026.zip',
        '.bashrc',
        'día_1.tar.gz',
        '名前.txt',
      ]) {
        expect(sftpSafeFileName(name), name);
      }
    });
  });

  test('a full disk is told apart from other write errors', () {
    expect(
      isNoSpaceError(
        const FileSystemException(
          'write failed',
          '/x',
          OSError('No space left on device', 28),
        ),
      ),
      isTrue,
    );
    expect(
      isNoSpaceError(
        const FileSystemException(
          'write failed',
          '/x',
          OSError('Permission denied', 13),
        ),
      ),
      isFalse,
    );
    expect(isNoSpaceError(StateError('x')), isFalse);
  });
}
