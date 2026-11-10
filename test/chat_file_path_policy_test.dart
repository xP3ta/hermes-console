import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/chat_file_path_policy.dart';
import 'package:hermes_android/core/utils/chat_inline_refs.dart';

List<String> _paths(
  String raw, {
  String? cwd,
  List<String> roots = const [],
}) => [
  for (final c in chatResolveFilePath(raw, cwd: cwd, roots: roots).candidates)
    c.path,
];

ChatPathProblem? _problem(String raw, {String? cwd}) =>
    chatResolveFilePath(raw, cwd: cwd).problem;

void main() {
  group('resolving a path', () {
    test('an absolute path is asked as it is', () {
      expect(_paths('/home/ana/artifacts/informe.md'), [
        '/home/ana/artifacts/informe.md',
      ]);
      expect(_paths('/home/ana/artifacts/informe.md', cwd: '/srv/p'), [
        '/home/ana/artifacts/informe.md',
      ]);
    });

    test('a relative path is tried in the folder, then in the other roots', () {
      expect(_paths('docs/a.md', cwd: '/srv/p', roots: ['/srv/q', '/srv/p']), [
        '/srv/p/docs/a.md',
        '/srv/q/docs/a.md',
      ]);
      expect(_paths('./a.md', cwd: '/srv/p'), ['/srv/p/a.md']);
      expect(_paths('../a.md', cwd: '/srv/p'), ['/srv/a.md']);
      expect(_paths('push-lockdown-and-reopen.md', cwd: '/home/x/proj'), [
        '/home/x/proj/push-lockdown-and-reopen.md',
      ]);
    });

    test('a relative path with no absolute folder is refused, not guessed', () {
      expect(_problem('a.md'), ChatPathProblem.noBase);
      expect(_problem('a.md', cwd: 'relativo'), ChatPathProblem.noBase);
      expect(_problem('a.md', cwd: ''), ChatPathProblem.noBase);
    });

    test('home resolves only when the home follows from the folders', () {
      expect(_paths('~/notas/a.md', cwd: '/home/ana/proj'), [
        '/home/ana/notas/a.md',
      ]);
      expect(_paths('~/a.md', cwd: '/Users/ana/x'), ['/Users/ana/a.md']);
      expect(_paths('~/a.md', cwd: '/root/x'), ['/root/a.md']);
      expect(_paths('~/a.md', cwd: '/srv/p', roots: ['/home/bea/y']), [
        '/home/bea/a.md',
      ]);
      expect(_problem('~/a.md', cwd: '/srv/p'), ChatPathProblem.noBase);
      expect(_problem('~/a.md'), ChatPathProblem.noBase);
    });

    test('.. is applied and never travels', () {
      expect(_paths('/srv/p/../q/./a.md'), ['/srv/q/a.md']);
      expect(_paths('/srv//p///a.md'), ['/srv/p/a.md']);
      for (final raw in ['/../etc/passwd', '/srv/../../etc/passwd']) {
        expect(_problem(raw), ChatPathProblem.escapesRoot, reason: raw);
      }
      expect(
        _problem('../../../x.md', cwd: '/srv'),
        ChatPathProblem.escapesRoot,
      );
      for (final c in chatResolveFilePath(
        '../b/../c.md',
        cwd: '/a/d',
      ).candidates) {
        expect(c.path.contains('..'), isFalse);
      }
    });

    test('a NUL, controls, schemes and Windows forms are refused', () {
      expect(_problem('/srv/a\u0000.md'), ChatPathProblem.control);
      expect(_problem('/srv/a\n.md'), ChatPathProblem.control);
      expect(_problem('/srv/a\u202Emd.txt'), ChatPathProblem.control);
      for (final raw in [
        'file:///etc/passwd',
        'file:/etc/passwd',
        'http://x/a.md',
        'ssh://h/a.md',
        r'C:\Users\x\a.md',
        'C:/Users/x/a.md',
        r'\\server\share\a.md',
        r'/srv/p\a.md',
      ]) {
        expect(_problem(raw, cwd: '/srv'), ChatPathProblem.scheme, reason: raw);
      }
      expect(_problem(''), ChatPathProblem.empty);
      expect(_problem('/${'a' * 5000}'), ChatPathProblem.tooLong);
    });

    test('spaces and unicode are kept', () {
      expect(_paths('/srv/mis docs/informe final.md'), [
        '/srv/mis docs/informe final.md',
      ]);
      expect(_paths('notas/ñandú — 日本語.md', cwd: '/srv/p'), [
        '/srv/p/notas/ñandú — 日本語.md',
      ]);
    });

    test('the line is taken from the text', () {
      ChatResolvedPath only(String raw) =>
          chatResolveFilePath(raw, cwd: '/srv/p').candidates.single;
      expect(
        only('lib/a.dart:120'),
        const ChatResolvedPath('/srv/p/lib/a.dart', line: 120),
      );
      expect(
        only('lib/a.dart:10-20'),
        const ChatResolvedPath('/srv/p/lib/a.dart', line: 10, endLine: 20),
      );
      expect(only('lib/a.dart:10:5').line, 10);
      expect(only('lib/a.dart#L10').line, 10);
      expect(
        only('lib/a.dart#L10-L20'),
        const ChatResolvedPath('/srv/p/lib/a.dart', line: 10, endLine: 20),
      );
      expect(only('lib/a.dart#L10-20').endLine, 20);
      expect(only('lib/a.dart:20-10').endLine, isNull);
      expect(only('lib/a.dart:0').line, isNull);
      expect(only('a.dart:120').path, '/srv/p/a.dart');
    });
  });

  group('lines in references', () {
    test('a chip carries its line and range', () {
      final one = chatFileRefFor('lib/main.dart:42')!;
      expect((one.path, one.line, one.endLine), ('lib/main.dart', 42, null));
      final range = chatFileRefFor('/srv/a.json:3-9')!;
      expect((range.line, range.endLine), (3, 9));
      final anchor = chatFileRefFor('lib/a.dart#L10-L20')!;
      expect(anchor.path, 'lib/a.dart');
      expect((anchor.line, anchor.endLine), (10, 20));
      expect(anchor.name, 'a.dart#L10-L20');
      expect(chatFileRefFor('lib/a.dart')!.line, isNull);
      expect(
        chatFileRefFor('lib/a.dart:42') == chatFileRefFor('lib/a.dart'),
        isFalse,
      );
    });

    test('prose keeps the line it was given', () {
      final all = RegExp(chatFilePattern, caseSensitive: false);
      String? first(String text) => all.firstMatch(text)?[0];
      expect(first('mira lib/main.dart:42 y sigue'), 'lib/main.dart:42');
      expect(first('mira lib/main.dart:42.'), 'lib/main.dart:42');
      expect(first('mira lib/main.dart: ahí'), 'lib/main.dart');
      expect(first('mira lib/main.dart#L5-L9, ahí'), 'lib/main.dart#L5-L9');
      expect(first('mira lib/main.dart:abc'), 'lib/main.dart');
    });

    test('a NUL or a control character is no reference', () {
      expect(chatFileRefFor('/srv/a\u0000b.md'), isNull);
      expect(chatFileRefFor('/srv/a\u202Eb.md'), isNull);
    });

    test('the root of a path that is resolved is kept', () {
      final r = chatResolveRef(
        chatFileRefFor('lib/a.dart:7')!,
        cwd: '/srv/p',
        roots: const ['/srv/q'],
      );
      expect(r.candidates.map((c) => '${c.path}:${c.line}'), [
        '/srv/p/lib/a.dart:7',
        '/srv/q/lib/a.dart:7',
      ]);
    });
  });

  group('sensitive files', () {
    test('the usual secrets are told apart', () {
      for (final path in [
        '/srv/p/.env',
        '/srv/p/.env.production',
        '/srv/p/.env.local',
        '/srv/p/prod.env',
        '/home/a/.ssh/id_rsa',
        '/home/a/.ssh/id_ed25519',
        '/home/a/.ssh/config',
        '/home/a/id_rsa',
        '/srv/server.pem',
        '/srv/tls/private.key',
        '/srv/cert.p12',
        '/home/a/.aws/credentials',
        '/srv/credentials.json',
        '/srv/Credentials.JSON',
        '/home/a/.netrc',
        '/home/a/.npmrc',
        '/home/a/.git-credentials',
        '/srv/secrets.yaml',
        '/srv/terraform.tfvars',
        '/home/a/.kube/config',
        '/home/a/.gnupg/pubring.kbx',
        '/srv/app.keystore',
        '/srv/.pgpass',
      ]) {
        expect(isSensitiveChatPath(path), isTrue, reason: path);
      }
    });

    test('ordinary files and templates are not', () {
      for (final path in [
        '/srv/p/README.md',
        '/srv/p/.env.example',
        '/srv/p/.env.sample',
        '/srv/p/env.md',
        '/srv/p/lib/main.dart',
        '/home/a/.ssh/id_rsa.pub',
        '/srv/p/keys.md',
        '/srv/p/secrets.md',
        '/srv/p/environment.json',
        '/srv/p/push-lockdown-and-reopen.md',
        '/',
        '',
      ]) {
        expect(isSensitiveChatPath(path), isFalse, reason: path);
      }
    });
  });

  group('where the server says the file is', () {
    bool escapes(
      String asked,
      String served, {
      List<String> roots = const ['/srv/p'],
      bool relative = true,
    }) => chatServedPathEscapes(
      asked: asked,
      served: served,
      roots: roots,
      askedWasRelative: relative,
    );

    test('the same path, or one inside the folders, is fine', () {
      expect(escapes('/srv/p/a.md', '/srv/p/a.md'), isFalse);
      expect(escapes('/srv/p/a.md', '/srv/p/docs/a.md'), isFalse);
      expect(escapes('/srv/p/a.md', '/srv/p/../p/a.md'), isFalse);
    });

    test('a link that leaves the folders is caught', () {
      expect(escapes('/srv/p/a.md', '/etc/passwd'), isTrue);
      expect(escapes('/srv/p/a.md', '/srv/other/b.md'), isTrue);
      expect(escapes('/srv/p/a.md', '/srv/p/../../etc/x'), isTrue);
    });

    test('a folder named by its real path is not a way out', () {
      expect(
        escapes(
          '/home/a/p/docs/a.md',
          '/mnt/a/p/docs/a.md',
          roots: ['/home/a/p'],
        ),
        isFalse,
      );
    });

    test('an absolute path the user was shown has no such expectation', () {
      expect(escapes('/srv/x/a.md', '/etc/passwd', relative: false), isFalse);
    });
  });
}
