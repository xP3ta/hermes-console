import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/server_path.dart';

void main() {
  test('absolute paths belong to the server, not the Android platform', () {
    for (final path in [
      '/',
      '//',
      '///home/demo',
      '/home/demo',
      'D:\\',
      r'D:\Hermes\workspace',
      'd:/Hermes/workspace',
      r'\\server\share\workspace',
      '//server/share/workspace',
    ]) {
      expect(isAbsoluteServerPath(path), isTrue, reason: path);
    }
    for (final path in [
      '',
      '.',
      'workspace',
      r'D:workspace',
      r'\workspace',
      r'D:\..\outside',
      r'\\server\share\..\outside',
      r'\\?\D:\workspace',
      r'\\.\pipe\name',
      '/../../outside',
    ]) {
      expect(isAbsoluteServerPath(path), isFalse, reason: path);
    }
  });

  test(
    'Windows roots, parents and child joins preserve absolute semantics',
    () {
      expect(serverPathRoot(r'D:\Hermes\workspace'), 'D:\\');
      expect(
        serverPathRoot(r'\\server\share\workspace'),
        '\\\\server\\share\\',
      );
      expect(serverPathParent(r'D:\Hermes\workspace'), r'D:\Hermes');
      expect(serverPathParent('D:\\'), 'D:\\');
      expect(serverPathParent('\\\\server\\share\\'), '\\\\server\\share\\');
      expect(serverPathChild('D:\\', 'child'), r'D:\child');
      expect(
        serverPathChild(r'\\server\share\workspace', 'child'),
        r'\\server\share\workspace\child',
      );
      expect(serverPathBaseName(r'D:\Hermes\workspace'), 'workspace');
      expect(
        normalizeServerPath('D:/Hermes/workspace/'),
        r'D:\Hermes\workspace',
      );
    },
  );

  test('Windows equality and containment use whole components', () {
    expect(
      serverPathsEqual(r'D:\Hermes\workspace', 'd:/HERMES/Workspace/'),
      isTrue,
    );
    expect(
      serverPathIsWithin(r'D:\Hermes\workspace', 'd:/HERMES/Workspace/child'),
      isTrue,
    );
    for (final path in [
      r'D:\Hermes\workspace-other',
      r'E:\Hermes\workspace',
      r'D:\Hermes\workspace\..\outside',
      r'\\server\share\workspace',
    ]) {
      expect(
        serverPathIsWithin(r'D:\Hermes\workspace', path),
        isFalse,
        reason: path,
      );
    }
    expect(
      serverPathIsWithin(
        r'\\server\share\workspace',
        r'\\SERVER\SHARE\Workspace\child',
      ),
      isTrue,
    );
    expect(
      serverPathIsWithin(
        r'\\server\share\workspace',
        r'\\server\other\workspace',
      ),
      isFalse,
    );
    expect(
      normalizeServerPath(r'D:\Hermes\.\workspace\child\..'),
      r'D:\Hermes\workspace',
    );
  });

  test('breadcrumbs preserve drive and UNC roots', () {
    expect(serverPathBreadcrumbs('D:\\', r'D:\Hermes\workspace'), [
      ('D:\\', 'D:\\'),
      ('Hermes', r'D:\Hermes'),
      ('workspace', r'D:\Hermes\workspace'),
    ]);
    expect(
      serverPathBreadcrumbs('\\\\server\\share\\', r'\\server\share\workspace'),
      [
        ('\\\\server\\share\\', '\\\\server\\share\\'),
        ('workspace', r'\\server\share\workspace'),
      ],
    );
  });

  test('double-slash POSIX paths are not inferred to be Windows UNC', () {
    expect(normalizeServerPath('//srv/project'), '/srv/project');
    expect(serverPathRoot('//srv/project'), '/');
    expect(serverPathIsWithin('/', '//srv/project'), isTrue);
    expect(serverPathsEqual('//srv/project', '//SRV/Project'), isFalse);
    expect(serverPathsEqual(r'\\srv\project', '//srv/project'), isFalse);
  });

  test('Unix paths retain case sensitivity and backslashes in names', () {
    expect(normalizeServerPath('//'), '/');
    expect(normalizeServerPath('///home//demo/'), '/home/demo');
    expect(serverPathIsWithin('/', '///home/demo'), isTrue);
    expect(serverPathRoot('/home/demo'), '/');
    expect(serverPathParent('/home/demo'), '/home');
    expect(serverPathParent('/'), '/');
    expect(serverPathChild('/', 'demo'), '/demo');
    expect(serverPathsEqual('/home/demo', '/home/Demo'), isFalse);
    expect(serverPathIsWithin('/home/demo', '/home/demo/child'), isTrue);
    expect(serverPathIsWithin('/home/demo', '/home/demo-other'), isFalse);
    expect(serverPathIsWithin('/home/demo', '/home/demo/../outside'), isFalse);
    expect(normalizeServerPath(r'/home/a\b/'), r'/home/a\b');
    expect(serverPathBreadcrumbs('/', '/home/demo'), [
      ('/', '/'),
      ('home', '/home'),
      ('demo', '/home/demo'),
    ]);
  });
}
