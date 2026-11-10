import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/chat_folder_learning.dart';

Map<String, dynamic> _call(String tool, Object args) => {
  'role': 'assistant',
  'content': '',
  'tool_calls': [
    {
      'id': 'c1',
      'type': 'function',
      'function': {
        'name': tool,
        'arguments': args is String ? args : jsonEncode(args),
      },
    },
  ],
};

Map<String, dynamic> _say(String text) => {
  'role': 'assistant',
  'content': text,
};

void main() {
  group('chatCleanAbsolutePath', () {
    test('cleans a Posix path and refuses what is no path', () {
      expect(
        chatCleanAbsolutePath('/home/u/b/./sub//pair.py'),
        '/home/u/b/sub/pair.py',
      );
      expect(chatCleanAbsolutePath('/home/u/b/'), '/home/u/b');
      expect(chatCleanAbsolutePath('/home/u/b/../c/x.py'), '/home/u/c/x.py');
      expect(chatCleanAbsolutePath('relative/x.py'), isNull);
      expect(chatCleanAbsolutePath('~/x.py'), isNull);
      expect(chatCleanAbsolutePath('/../etc/passwd'), isNull);
      expect(chatCleanAbsolutePath('/'), isNull);
      expect(chatCleanAbsolutePath('/home/u/a\u0000b'), isNull);
      expect(chatCleanAbsolutePath('/home/u/\u202eevil'), isNull);
      expect(chatCleanAbsolutePath(r'C:\x\y'), isNull);
      expect(chatCleanAbsolutePath('/home\\u/x'), isNull);
      expect(chatCleanAbsolutePath('/dev/null'), isNull);
      expect(chatCleanAbsolutePath('/proc/self/cwd'), isNull);
      expect(chatCleanAbsolutePath('/${'a' * 5000}'), isNull);
    });
  });

  group('chatAbsolutePathsInText', () {
    test('finds the absolute paths a reply cites, once each, in order', () {
      const text =
          'He trabajado en /home/u/b/sub/ y he tocado `/home/u/b/sub/pair.py` '
          'y /home/u/b/manifest.json. Luego otra vez /home/u/b/sub/pair.py.';
      expect(chatAbsolutePathsInText(text), [
        '/home/u/b/sub',
        '/home/u/b/sub/pair.py',
        '/home/u/b/manifest.json',
      ]);
    });

    test('a URL, a relative path, a lone root segment are not paths', () {
      expect(
        chatAbsolutePathsInText(
          'Mira https://example.com/a/b.py y docs/sync/CONTRATO.md y /tmp y '
          'a/b/c.txt y ~/x/y.md',
        ),
        isEmpty,
      );
    });

    test('a sentence hanging on the path is not part of it', () {
      expect(chatAbsolutePathsInText('Está en (/srv/p/a/b.py).'), [
        '/srv/p/a/b.py',
      ]);
      expect(chatAbsolutePathsInText('Está en /srv/p/a/b.py, y /srv/p/c:'), [
        '/srv/p/a/b.py',
        '/srv/p/c',
      ]);
    });

    test('control characters and `..` are refused; the limit holds', () {
      expect(chatAbsolutePathsInText('/srv/p/a\u0007/b.py'), ['/srv/p/a']);
      expect(chatAbsolutePathsInText('/../../etc/x.py'), isEmpty);
      final many = [for (var i = 0; i < 40; i++) '/srv/p/f$i.py'].join(' ');
      expect(chatAbsolutePathsInText(many).length, 16);
    });
  });

  group('chatToolArgumentPaths', () {
    test('reads the path-like arguments of the Hermes tools', () {
      expect(
        chatToolArgumentPaths('terminal', {
          'command': 'cd /home/u/b && python pair.py',
          'workdir': '/home/u/b/sub',
        }),
        ['/home/u/b/sub', '/home/u/b'],
      );
      expect(chatToolArgumentPaths('read_file', '{"path":"/home/u/b/x.py"}'), [
        '/home/u/b/x.py',
      ]);
      expect(
        chatToolArgumentPaths('write_file', {
          'file_path': '/home/u/b/y.py',
          'content': 'see /nowhere/z.py',
        }),
        ['/home/u/b/y.py'],
      );
    });

    test('a relative or hostile argument is skipped', () {
      expect(chatToolArgumentPaths('read_file', {'path': 'x.py'}), isEmpty);
      expect(
        chatToolArgumentPaths('read_file', {'path': '/../etc/x'}),
        isEmpty,
      );
      expect(chatToolArgumentPaths('read_file', {'path': 7}), isEmpty);
      expect(chatToolArgumentPaths('read_file', 'not json'), isEmpty);
      expect(chatToolArgumentPaths('read_file', null), isEmpty);
    });

    test('a deferred-tool bridge yields the paths of what it wraps', () {
      expect(
        chatToolArgumentPaths('tool_call', {
          'calls': [
            {
              'name': 'read_file',
              'arguments': {'path': '/home/u/b/x.py'},
            },
            {
              'name': 'terminal',
              'arguments': {'command': 'ls', 'workdir': '/home/u/c'},
            },
          ],
        }),
        ['/home/u/b/x.py', '/home/u/c'],
      );
    });
  });

  group('chatTranscriptFilePaths', () {
    test('newest first, tool calls before prose, each path once', () {
      final rows = [
        _say('Listo. Edité /home/u/b/sub/pair.py y /home/u/b/manifest.json.'),
        _call('patch', {'path': '/home/u/b/sub/pair.py'}),
        _call('terminal', {'command': 'pytest', 'workdir': '/home/u/b'}),
        {'role': 'user', 'content': 'arregla /home/u/evil/x.py'},
        {'role': 'tool', 'content': '/home/u/tool-output/x.py'},
        _say('Empiezo en /home/u/a.'),
      ];
      expect(chatTranscriptFilePaths(rows), [
        '/home/u/b/sub/pair.py',
        '/home/u/b/manifest.json',
        '/home/u/b',
        '/home/u/a',
      ]);
    });

    test('rows and paths are bounded', () {
      final rows = [for (var i = 0; i < 500; i++) _say('ver /srv/p/f$i.py')];
      expect(chatTranscriptFilePaths(rows).length, chatLearnedPathLimit);
      expect(chatTranscriptFilePaths(rows, maxRows: 3).length, 3);
    });
  });

  group('chatLearnFolders', () {
    test('the file folder first, then its parents, never the home', () {
      expect(chatLearnFolders(['/home/u/b/sub/pair.py']), [
        '/home/u/b/sub',
        '/home/u/b',
      ]);
      expect(chatLearnFolders(['/home/u/w/sync-v3/sync/plugin/x/pair.py']), [
        '/home/u/w/sync-v3/sync/plugin/x',
        '/home/u/w/sync-v3/sync/plugin',
        '/home/u/w/sync-v3/sync',
        '/home/u/w/sync-v3',
        '/home/u/w',
      ]);
      // A folder (no extension) is a candidate itself.
      expect(chatLearnFolders(['/srv/p/sub']), ['/srv/p/sub', '/srv/p']);
      expect(chatLearnFolders(['/srv/p/x.py']), ['/srv/p']);
    });

    test('known folders are left out; order is newest first, no repeats', () {
      expect(
        chatLearnFolders(
          ['/home/u/b/sub/pair.py', '/home/u/a/lib/x.dart', '/home/u/b/y.py'],
          known: ['/home/u/a', '/home/u/a/'],
        ),
        ['/home/u/b/sub', '/home/u/b', '/home/u/a/lib'],
      );
    });

    test('hostile paths are dropped and the limit holds', () {
      expect(
        chatLearnFolders([
          '../x.py',
          '/../etc/x',
          '/home/u/a\u0000/x.py',
          'C:\\x\\y.py',
          '/dev/sda',
        ]),
        isEmpty,
      );
      final many = [for (var i = 0; i < 50; i++) '/srv/p$i/d/x.py'];
      expect(chatLearnFolders(many).length, chatLearnedFolderLimit);
    });
  });
}
