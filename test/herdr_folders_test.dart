import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_folders.dart';

void main() {
  group('the name of a new folder', () {
    test('plain names pass, with spaces and accents', () {
      for (final name in ['app', 'my project', 'año 2026', 'a.b', '.hidden']) {
        expect(herdrFolderNameProblem(name), isNull, reason: name);
      }
    });

    test('each kind of bad name is told apart', () {
      expect(herdrFolderNameProblem(''), HerdrFolderNameProblem.empty);
      expect(herdrFolderNameProblem('   '), HerdrFolderNameProblem.empty);
      expect(herdrFolderNameProblem('a/b'), HerdrFolderNameProblem.slash);
      expect(herdrFolderNameProblem('/'), HerdrFolderNameProblem.slash);
      expect(herdrFolderNameProblem(r'a\b'), HerdrFolderNameProblem.slash);
      expect(herdrFolderNameProblem('../x'), HerdrFolderNameProblem.slash);
      expect(herdrFolderNameProblem('.'), HerdrFolderNameProblem.dots);
      expect(herdrFolderNameProblem('..'), HerdrFolderNameProblem.dots);
      for (final bad in [
        'a\nb',
        'a\rb',
        'a\tb',
        'a\u0000b',
        'a\u001bb',
        'a\u007fb',
        'a\u0085b',
      ]) {
        expect(
          herdrFolderNameProblem(bad),
          HerdrFolderNameProblem.control,
          reason: bad.codeUnits.toString(),
        );
      }
    });

    test('the length is counted in bytes', () {
      expect(herdrFolderNameProblem('x' * herdrFolderNameMaxBytes), isNull);
      expect(
        herdrFolderNameProblem('x' * (herdrFolderNameMaxBytes + 1)),
        HerdrFolderNameProblem.tooLong,
      );
      // 61 two-byte letters are 122 bytes.
      expect(herdrFolderNameProblem('é' * 61), HerdrFolderNameProblem.tooLong);
      expect(herdrFolderNameProblem('é' * 60), isNull);
    });
  });

  group('paths', () {
    test('joining never doubles a slash and trims the name', () {
      expect(herdrJoinPath('/', 'srv'), '/srv');
      expect(herdrJoinPath('/home/demo', 'app'), '/home/demo/app');
      expect(herdrJoinPath('/home/demo', ' app '), '/home/demo/app');
    });

    test('the parent of a path', () {
      expect(herdrParentPath('/home/demo/app'), '/home/demo');
      expect(herdrParentPath('/home'), '/');
      expect(herdrParentPath('/'), '/');
    });

    test('breadcrumbs: the root and each step, with its own path', () {
      final crumbs = herdrBreadcrumbs('/home/demo/app');
      expect(crumbs.map((c) => c.label), ['/', 'home', 'demo', 'app']);
      expect(crumbs.map((c) => c.path), [
        '/',
        '/home',
        '/home/demo',
        '/home/demo/app',
      ]);
      expect(herdrBreadcrumbs('/').single.path, '/');
    });
  });
}
