import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/project_move_targets.dart';
import 'package:hermes_android/core/utils/server_path.dart';
import 'package:hermes_android/core/utils/short_server_path.dart';
import 'package:hermes_android/core/widgets/projects/project_files_browser.dart';

/// Hostile and odd server paths. None of these may throw, and a path that is
/// accepted must stay inside its drive, share or POSIX root.
void main() {
  group('rejected without throwing', () {
    final hostile = <String>[
      '',
      '   ',
      '\u0000',
      'D:\\proj\u0000\\x',
      '/srv/pro\u0000j',
      'D:\\proj\nx',
      'D:\\proj\tx',
      '/srv/a\u001bb',
      '/srv/a\u007fb',
      '~',
      '~/project',
      '%USERPROFILE%\\project',
      '%TEMP%',
      r'D:',
      r'D:project',
      r'D:..\x',
      r'\project',
      r'\\',
      r'\\server',
      r'\\server\',
      r'\\server\\share',
      r'\\\server\share',
      r'\\?\C:\x',
      r'\\?\UNC\server\share',
      r'\\.\COM1',
      r'\\.\pipe\x',
      '//?/C:/x',
      '//./pipe/x',
      '//?',
      r'D:\proj\..\..',
      r'D:\..',
      r'\\server\share\..',
      r'\\server\share\a\..\..\..\x',
      '/..',
      '/a/../..',
      r'D:\proj\CON',
      r'D:\proj\con.txt',
      r'D:\proj\NUL',
      r'D:\proj\Aux.log',
      r'D:\proj\PRN',
      r'D:\proj\COM1',
      r'D:\proj\lpt9.x',
      'D:\\proj\\COM\u00B9',
      r'D:\proj\CONIN$',
      r'D:\proj\CONOUT$',
      r'D:\proj\name.',
      r'D:\proj\name \x',
      r'D:\proj\...',
      r'D:\proj\.. \x',
      r'D:\proj\file.txt:stream',
      r'D:\proj\file.txt::$DATA',
      r'D:\proj\a<b',
      r'D:\proj\a>b',
      r'D:\proj\a"b',
      r'D:\proj\a|b',
      r'D:\proj\a?b',
      r'D:\proj\a*b',
      r'D:\C:\x',
      r'\\ser:ver\share',
      r'\\server\sh*re',
      'file:///D:/proj',
      'smb://server/share',
      'http://x/y',
    ];
    test('every shape is refused by the whole helper surface', () {
      for (final path in hostile) {
        expect(isAbsoluteServerPath(path), isFalse, reason: path);
        // None of these may throw, whatever the second argument is.
        expect(() => normalizeServerPath(path), returnsNormally);
        expect(() => serverPathRoot(path), returnsNormally);
        expect(() => serverPathParent(path), returnsNormally);
        expect(() => serverPathBaseName(path), returnsNormally);
        expect(() => serverPathKey(path), returnsNormally);
        expect(() => shortServerPath(path), returnsNormally);
        expect(serverPathTryChild(path, 'child'), isNull, reason: path);
        expect(serverPathsEqual(path, path), isFalse, reason: path);
        expect(serverPathIsWithin(path, '/'), isFalse, reason: path);
        expect(serverPathIsWithin('/', path), isFalse, reason: path);
        expect(serverPathIsWithin(r'D:\', path), isFalse, reason: path);
        expect(serverPathIsWithin(r'\\server\share', path), isFalse);
        expect(() => serverPathBreadcrumbs(r'D:\', path), returnsNormally);
        expect(serverPathBreadcrumbs(r'D:\proj', path), hasLength(1));
      }
    });

    test('a very long path is refused, not walked', () {
      final long = '/${'a' * 40000}';
      expect(isAbsoluteServerPath(long), isFalse);
      expect(isAbsoluteServerPath('D:\\${'a/' * 20000}'), isFalse);
      final okName = '/${'a' * 255}';
      expect(isAbsoluteServerPath(okName), isTrue);
      expect(isAbsoluteServerPath('/${'a' * 256}'), isFalse);
    });

    test('child names with separators, dots or control characters', () {
      for (final parent in ['/srv', r'D:\proj', r'\\server\share\proj']) {
        for (final name in [
          '',
          '.',
          '..',
          'a/b',
          '../x',
          'x\u0000',
          'x\ny',
          'a' * 256,
        ]) {
          expect(
            serverPathTryChild(parent, name),
            isNull,
            reason: '$parent|$name',
          );
          expect(() => serverPathChild(parent, name), throwsArgumentError);
        }
      }
      for (final name in [
        r'a\b',
        r'..\x',
        'a:b',
        'CON',
        'nul.txt',
        'x.',
        'x ',
        'a|b',
      ]) {
        expect(serverPathTryChild(r'D:\proj', name), isNull, reason: name);
        expect(
          serverPathTryChild(r'\\server\share', name),
          isNull,
          reason: name,
        );
      }
      expect(serverPathTryChild('relative', 'x'), isNull);
    });
  });

  group('accepted paths never leave their root', () {
    test('Windows ..  and mixed separators stay inside the drive', () {
      expect(normalizeServerPath(r'D:\a\b\..\..\c'), r'D:\c');
      expect(normalizeServerPath(r'D:/a\b//c/./d'), r'D:\a\b\c\d');
      expect(normalizeServerPath(r'D:\\\\a'), r'D:\a');
      expect(serverPathIsWithin(r'D:\', r'D:\a\..\b'), isTrue);
      expect(serverPathIsWithin(r'D:\proj', r'D:\proj\a\..\..\other'), isFalse);
      expect(serverPathIsWithin(r'D:\proj', r'D:\proj\..\proj\x'), isTrue);
      expect(serverPathIsWithin(r'D:\', r'E:\x'), isFalse);
      expect(serverPathIsWithin(r'D:\', r'\\server\share\x'), isFalse);
      expect(serverPathIsWithin(r'D:\', '/x'), isFalse);
      expect(serverPathIsWithin('/', r'D:\x'), isFalse);
      expect(
        serverPathIsWithin(r'\\server\share', r'\\server\share2\x'),
        isFalse,
      );
      expect(
        serverPathIsWithin(r'\\server\share', r'\\server2\share\x'),
        isFalse,
      );
      // Walking up from any depth stops at the root.
      var path = r'D:\a\b\c';
      for (var i = 0; i < 6; i++) {
        path = serverPathParent(path);
      }
      expect(path, r'D:\');
      path = r'\\server\share\a\b';
      for (var i = 0; i < 6; i++) {
        path = serverPathParent(path);
      }
      expect(path, r'\\server\share\');
      path = '/a/b';
      for (var i = 0; i < 6; i++) {
        path = serverPathParent(path);
      }
      expect(path, '/');
    });

    test('Windows comparison folds case, trailing separators and slashes', () {
      expect(serverPathsEqual(r'D:\Proj', r'd:/PROJ//'), isTrue);
      expect(serverPathsEqual(r'\\SRV\Share\P', r'\\srv\share\p\'), isTrue);
      expect(serverPathKey(r'D:\Proj\'), serverPathKey('d:/proj'));
      expect(serverPathIsWithin(r'D:\Proj', r'D:\proj\Sub'), isTrue);
      expect(serverPathIsWithin(r'D:\Proj', r'D:\ProjX'), isFalse);
    });

    test('% and ~ are literal characters, never expanded', () {
      expect(isAbsoluteServerPath(r'D:\%USERPROFILE%\x'), isTrue);
      expect(normalizeServerPath(r'D:\%USERPROFILE%\x'), r'D:\%USERPROFILE%\x');
      expect(isAbsoluteServerPath('/srv/~root/%HOME%'), isTrue);
      expect(normalizeServerPath('/srv/~root/%HOME%'), '/srv/~root/%HOME%');
      expect(isAbsoluteServerPath(r'D:\PROGRA~1\x'), isTrue);
      expect(serverPathsEqual(r'D:\PROGRA~1', r'D:\Program Files'), isFalse);
    });

    test('UNC admin shares and drive letters in any case', () {
      expect(isAbsoluteServerPath(r'\\server\c$\x'), isTrue);
      expect(serverPathRoot(r'\\server\c$\x'), r'\\server\c$\');
      expect(serverPathRoot('d:/x'), r'd:\');
      expect(serverPathRoot('Z:\\'), r'Z:\');
    });

    test('a trailing space or newline around the whole path is trimmed', () {
      expect(normalizeServerPath('  D:\\proj \n'), r'D:\proj');
      expect(normalizeServerPath('  /srv/proj \n'), '/srv/proj');
    });
  });

  group('POSIX stays POSIX', () {
    test('backslashes are literal name characters', () {
      expect(isAbsoluteServerPath(r'/srv/a\b'), isTrue);
      expect(normalizeServerPath(r'/srv/a\b\..\c'), r'/srv/a\b\..\c');
      expect(serverPathParent(r'/srv/a\b'), '/srv');
      expect(serverPathBaseName(r'/srv/a\b'), r'a\b');
      expect(serverPathIsWithin('/srv/a', r'/srv/a\b'), isFalse);
      expect(serverPathChild('/srv', r'a\b'), r'/srv/a\b');
      expect(serverPathTryChild('/srv', r'a\b'), r'/srv/a\b');
      expect(isAbsoluteServerPath(r'/C:\x'), isTrue);
      expect(serverPathRoot(r'/C:\x'), '/');
    });

    test('case matters and Windows-only names are valid names', () {
      expect(serverPathsEqual('/srv/App', '/srv/app'), isFalse);
      expect(serverPathIsWithin('/srv/App', '/srv/app/x'), isFalse);
      expect(isAbsoluteServerPath('/srv/CON'), isTrue);
      expect(isAbsoluteServerPath('/srv/file:stream'), isTrue);
      expect(isAbsoluteServerPath('/srv/trail.'), isTrue);
      expect(isAbsoluteServerPath('/srv/a?b*c'), isTrue);
      expect(serverPathTryChild('/srv', 'nul'), '/srv/nul');
      expect(serverPathTryChild('/srv', 'a:b'), '/srv/a:b');
      expect(serverPathKey('/srv/App/'), '/srv/App');
    });

    test('.. cannot climb above the root', () {
      expect(serverPathIsWithin('/srv/a', '/srv/a/../b'), isFalse);
      expect(normalizeServerPath('/a/b/../../c'), '/c');
      expect(isAbsoluteServerPath('/a/../../c'), isFalse);
    });
  });

  group('callers that used to be POSIX only', () {
    test('session membership follows the server of the project', () {
      expect(
        sessionInProjectFolder(r'D:\Work\App', cwd: r'd:\work\app\src'),
        isTrue,
      );
      expect(
        sessionInProjectFolder(r'D:\Work\App', gitRepoRoot: 'D:/Work/App/'),
        isTrue,
      );
      expect(
        sessionInProjectFolder(r'D:\Work\App', cwd: r'D:\Work\AppOther'),
        isFalse,
      );
      expect(
        sessionInProjectFolder(r'D:\Work\App', cwd: r'D:\Work\App\..\x'),
        isFalse,
      );
      expect(
        sessionInProjectFolder(r'\\srv\share\p', cwd: r'\\SRV\Share\p\a'),
        isTrue,
      );
      expect(sessionInProjectFolder('/srv/App', cwd: '/srv/app/x'), isFalse);
      expect(sessionInProjectFolder('/srv/App', cwd: '/srv/App/x'), isTrue);
    });

    test('shortServerPath keeps POSIX output and shortens native paths', () {
      expect(shortServerPath('/home/demo/code/app'), '~/code/app');
      expect(shortServerPath('/srv/a/b/c/d'), '…/c/d');
      expect(shortServerPath(r'D:\Projects\demo'), r'D:\Projects\demo');
      expect(shortServerPath('D:/Projects/demo/'), r'D:\Projects\demo');
      expect(shortServerPath(r'D:\a\b\c\d'), r'…\c\d');
      expect(shortServerPath(r'\\srv\share\a\b\c'), r'…\b\c');
      expect(shortServerPath(r'D:\'), r'D:\');
    });

    test('entry names are checked against the host of the folder', () {
      expect(validProjectEntryName('notes.md'), 'notes.md');
      expect(validProjectEntryName('a:b'), 'a:b');
      expect(validProjectEntryName('a:b', parent: '/srv'), 'a:b');
      expect(validProjectEntryName('a:b', parent: r'D:\proj'), isNull);
      expect(validProjectEntryName('NUL', parent: r'D:\proj'), isNull);
      expect(validProjectEntryName('nul', parent: '/srv'), 'nul');
      expect(validProjectEntryName('x.', parent: r'D:\proj'), isNull);
      expect(validProjectEntryName(r'a\b', parent: '/srv'), isNull);
      expect(validProjectEntryName(' ok ', parent: r'D:\proj'), 'ok');
      expect(isValidServerEntryName(r'D:\proj', 'src'), isTrue);
    });
  });

  test('the helpers never ask the phone what a server path means', () {
    for (final file in [
      'lib/core/utils/server_path.dart',
      'lib/core/utils/short_server_path.dart',
      'lib/core/models/project_move_targets.dart',
    ]) {
      final source = File(file).readAsStringSync();
      expect(source.contains('dart:io'), isFalse, reason: file);
      expect(source.contains('package:path/'), isFalse, reason: file);
      expect(source.contains('Platform.'), isFalse, reason: file);
      expect(source.contains('defaultTargetPlatform'), isFalse, reason: file);
    }
  });
}
