import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/project_files.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/utils/chat_file_path_policy.dart';
import 'package:hermes_android/core/widgets/chat/chat_file_loader.dart';
import 'package:hermes_android/core/widgets/chat/chat_file_search.dart';

/// A tree of folders and files; every listing and read is recorded.
class TreeFiles implements HermesProjectFilesGateway {
  TreeFiles(
    this.files, {
    this.links = const {},
    this.denied = const {},
    this.unsupported = false,
    this.listDelay = Duration.zero,
  });

  /// Absolute file path → text.
  final Map<String, String> files;

  /// Folder → entry reported with a path outside it (a link out).
  final Map<String, ProjectFsEntry> links;

  /// Folders whose listing the server refuses.
  final Set<String> denied;
  final bool unsupported;
  final Duration listDelay;
  final List<String> listed = [];
  final List<String> reads = [];

  @override
  bool get projectFilesKnownUnsupported => unsupported;

  Set<String> get _folders {
    final out = <String>{};
    for (final file in files.keys) {
      var folder = file.substring(0, file.lastIndexOf('/'));
      while (folder.isNotEmpty) {
        out.add(folder);
        folder = folder.substring(0, folder.lastIndexOf('/'));
      }
    }
    return out;
  }

  @override
  Future<ProjectDirectoryListing> listProjectDirectory(String path) async {
    listed.add(path);
    if (listDelay > Duration.zero) await Future<void>.delayed(listDelay);
    if (unsupported) {
      throw const DesktopControlFailure(DesktopControlFailureKind.unsupported);
    }
    if (denied.contains(path)) {
      throw const DesktopControlFailure(
        DesktopControlFailureKind.forbidden,
        code: 403,
      );
    }
    if (!_folders.contains(path)) {
      return const ProjectDirectoryListing(entries: [], error: 'ENOENT');
    }
    final entries = <ProjectFsEntry>[];
    final seen = <String>{};
    for (final file in files.keys) {
      if (!file.startsWith('$path/')) continue;
      final rest = file.substring(path.length + 1);
      final slash = rest.indexOf('/');
      final name = slash < 0 ? rest : rest.substring(0, slash);
      if (!seen.add(name)) continue;
      entries.add(
        ProjectFsEntry(
          name: name,
          path: '$path/$name',
          isDirectory: slash >= 0,
        ),
      );
    }
    final link = links[path];
    if (link != null) entries.add(link);
    return ProjectDirectoryListing(entries: entries);
  }

  @override
  Future<ProjectFilePreview> readProjectFileText(String path) async {
    reads.add(path);
    final text = files[path];
    if (text == null) {
      throw const DesktopControlFailure(
        DesktopControlFailureKind.unavailable,
        code: 404,
      );
    }
    return ProjectFilePreview(
      path: path,
      text: text,
      binary: false,
      truncated: false,
      byteSize: utf8.encode(text).length,
      mimeType: 'text/plain',
    );
  }

  @override
  Future<Uint8List> readProjectFileBytes(String path) =>
      throw UnimplementedError();
}

Future<ChatFileSearchResult> _find(
  TreeFiles tree,
  String name,
  List<String> folders, {
  int maxDepth = chatFileSearchMaxDepth,
  int maxEntries = chatFileSearchMaxEntries,
  Duration timeout = chatFileSearchTimeout,
  bool Function()? cancelled,
}) => chatFindFileByName(
  files: tree,
  relative: name,
  folders: folders,
  maxDepth: maxDepth,
  maxEntries: maxEntries,
  timeout: timeout,
  cancelled: cancelled,
);

void main() {
  group('chatFindFileByName', () {
    test('one match: the bare name is found under a learned folder', () async {
      final tree = TreeFiles({
        '/home/u/a/README.md': 'a',
        '/home/u/b/sub/pair.py': 'x',
        '/home/u/b/manifest.json': '{}',
      });
      final result = await _find(tree, 'pair.py', ['/home/u/b']);
      expect(result.hits, ['/home/u/b/sub/pair.py']);
      expect(result.searched, ['/home/u/b']);
      expect(result.exhausted, isFalse);
      // Nothing outside the learned folder was listed.
      expect(tree.listed, isNot(contains('/home/u/a')));
      expect(tree.listed, isNot(contains('/home/u')));
    });

    test('a relative path matches on its whole tail', () async {
      final tree = TreeFiles({
        '/home/u/b/docs/sync/CONTRATO.md': 'c',
        '/home/u/b/other/CONTRATO.md': 'o',
      });
      final result = await _find(tree, 'docs/sync/CONTRATO.md', ['/home/u/b']);
      expect(result.hits, ['/home/u/b/docs/sync/CONTRATO.md']);
      expect((await _find(tree, 'CONTRATO.md', ['/home/u/b'])).hits.length, 2);
    });

    test('no match says which folders were searched', () async {
      final tree = TreeFiles({'/home/u/b/x.py': 'x', '/home/u/c/y.py': 'y'});
      final result = await _find(tree, 'pair.py', ['/home/u/b', '/home/u/c']);
      expect(result.hits, isEmpty);
      expect(result.searched, ['/home/u/b', '/home/u/c']);
    });

    test('several matches come in folder order, capped', () async {
      final tree = TreeFiles({
        for (var i = 0; i < 12; i++) '/srv/p/d$i/pair.py': '$i',
        '/srv/q/pair.py': 'q',
      });
      final result = await _find(tree, 'pair.py', ['/srv/q', '/srv/p']);
      expect(result.hits.first, '/srv/q/pair.py');
      expect(result.hits.length, chatFileSearchMaxHits);
    });

    test('depth, skipped folders and links out are respected', () async {
      final tree = TreeFiles(
        {
          '/srv/p/a/b/c/d/e/pair.py': 'deep',
          '/srv/p/node_modules/x/pair.py': 'nm',
          '/srv/p/.git/pair.py': 'git',
          '/srv/p/build/pair.py': 'b',
          '/srv/p/.dart_tool/pair.py': 'dt',
          '/srv/p/venv/pair.py': 'v',
          '/srv/p/ok/keep.txt': 'k',
          '/etc/secret/pair.py': 's',
        },
        links: {
          '/srv/p/ok': const ProjectFsEntry(
            name: 'link',
            path: '/etc/secret',
            isDirectory: true,
          ),
        },
      );
      final result = await _find(tree, 'pair.py', ['/srv/p']);
      expect(result.hits, isEmpty);
      expect(tree.listed, isNot(contains('/etc/secret')));
      expect(tree.listed, isNot(contains('/srv/p/node_modules')));
      expect(tree.listed, isNot(contains('/srv/p/.git')));
      expect(tree.listed, isNot(contains('/srv/p/build')));
      expect(tree.listed, isNot(contains('/srv/p/.dart_tool')));
      expect(tree.listed, isNot(contains('/srv/p/venv')));
      // Depth 4 below the start: /srv/p/a/b/c/d is listed, e is not.
      expect(tree.listed, contains('/srv/p/a/b/c/d'));
      expect(tree.listed, isNot(contains('/srv/p/a/b/c/d/e')));
      // A file link reported outside the folder is not a hit either.
      final fileLink = TreeFiles(
        {'/srv/p/x.txt': 'x', '/etc/pair.py': 's'},
        links: {
          '/srv/p': const ProjectFsEntry(
            name: 'pair.py',
            path: '/etc/pair.py',
            isDirectory: false,
          ),
        },
      );
      expect((await _find(fileLink, 'pair.py', ['/srv/p'])).hits, isEmpty);
    });

    test('the entry budget ends the walk and says so', () async {
      final tree = TreeFiles({
        for (var i = 0; i < 400; i++) '/srv/p/f$i.txt': '$i',
        '/srv/p/zz/pair.py': 'late',
      });
      final result = await _find(tree, 'pair.py', ['/srv/p'], maxEntries: 50);
      expect(result.hits, isEmpty);
      expect(result.exhausted, isTrue);
      expect(tree.listed.length, 1);
    });

    test(
      'a folder listed once is not listed again from another start',
      () async {
        final tree = TreeFiles({'/srv/p/sub/pair.py': 'x'});
        await _find(tree, 'pair.py', ['/srv/p/sub', '/srv/p']);
        expect(tree.listed.where((f) => f == '/srv/p/sub').length, 1);
      },
    );

    test('a denied folder is skipped; no route ends the search', () async {
      final tree = TreeFiles(
        {'/srv/p/pair.py': 'p', '/srv/q/pair.py': 'q'},
        denied: {'/srv/p'},
      );
      final result = await _find(tree, 'pair.py', ['/srv/p', '/srv/q']);
      expect(result.hits, ['/srv/q/pair.py']);
      expect(result.searched, ['/srv/q']);
      final none = TreeFiles({'/srv/p/pair.py': 'p'}, unsupported: true);
      expect((await _find(none, 'pair.py', ['/srv/p', '/srv/q'])).hits, []);
      expect(none.listed, ['/srv/p']);
    });

    testWidgets('the deadline and a cancellation stop the walk', (
      tester,
    ) async {
      final tree = TreeFiles({
        for (var i = 0; i < 30; i++) '/srv/p/d$i/x.txt': '$i',
        '/srv/p/d29/pair.py': 'late',
      }, listDelay: const Duration(seconds: 1));
      final pending = _find(tree, 'pair.py', [
        '/srv/p',
      ], timeout: const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 10));
      final result = await pending;
      expect(result.hits, isEmpty);
      expect(result.exhausted, isTrue);
      expect(tree.listed.length, lessThan(6));

      var cancelled = false;
      final second = TreeFiles({
        for (var i = 0; i < 30; i++) '/srv/q/d$i/pair.py': '$i',
      }, listDelay: const Duration(milliseconds: 100));
      final late = _find(second, 'pair.py', [
        '/srv/q',
      ], cancelled: () => cancelled);
      await tester.pump(const Duration(milliseconds: 150));
      cancelled = true;
      await tester.pump(const Duration(seconds: 5));
      await late;
      expect(second.listed.length, lessThan(5));
    });

    test('hostile names and folders are not searched', () async {
      final tree = TreeFiles({'/srv/p/pair.py': 'p'});
      for (final name in ['../pair.py', '/srv/p/pair.py', 'a/../pair.py', '']) {
        final result = await _find(tree, name, ['/srv/p']);
        expect(result.hits, isEmpty, reason: name);
      }
      final folders = await _find(tree, 'pair.py', [
        'relative',
        '/srv/\u0000p',
        '/../srv',
      ]);
      expect(folders.hits, isEmpty);
      expect(tree.listed, isEmpty);
    });
  });

  group('loadChatFile with a search scope', () {
    ChatFileSearchScope scope(String name, List<String> folders) =>
        ChatFileSearchScope(relative: name, folders: folders);

    test('the real case: cwd is one repo, the file sits in another', () async {
      final tree = TreeFiles({
        '/home/u/a/README.md': 'a',
        '/home/u/b/sub/pair.py': 'print(1)',
      });
      final found = <String>[];
      final content = await loadChatFile(
        files: tree,
        resolution: chatResolveFilePath('pair.py', cwd: '/home/u/a'),
        roots: ['/home/u/a'],
        askedRelative: true,
        search: scope('pair.py', ['/home/u/b/sub', '/home/u/b']),
        onFound: found.add,
      );
      expect(content.path, '/home/u/b/sub/pair.py');
      expect(utf8.decode(content.bytes), 'print(1)');
      expect(found, ['/home/u/b/sub/pair.py']);
      expect(tree.reads, ['/home/u/a/pair.py', '/home/u/b/sub/pair.py']);
    });

    test('a miss names every folder tried, candidates first', () async {
      final tree = TreeFiles({'/home/u/b/x.py': 'x'});
      await expectLater(
        loadChatFile(
          files: tree,
          resolution: chatResolveFilePath(
            'pair.py',
            cwd: '/home/u/a',
            roots: ['/home/u/b'],
          ),
          roots: ['/home/u/a', '/home/u/b'],
          askedRelative: true,
          search: scope('pair.py', ['/home/u/b', '/home/u/c']),
        ),
        throwsA(
          isA<ChatFileLoadException>()
              .having((e) => e.kind, 'kind', ChatFileErrorKind.notFound)
              .having((e) => e.tried, 'tried', ['/home/u/a', '/home/u/b']),
        ),
      );
    });

    test('several matches ask for a choice', () async {
      final tree = TreeFiles({
        '/srv/p/x/pair.py': '1',
        '/srv/p/y/pair.py': '2',
      });
      await expectLater(
        loadChatFile(
          files: tree,
          resolution: chatResolveFilePath('pair.py', cwd: '/srv/q'),
          roots: ['/srv/q'],
          askedRelative: true,
          search: scope('pair.py', ['/srv/p']),
        ),
        throwsA(
          isA<ChatFileChoiceException>().having((e) => e.paths, 'paths', [
            '/srv/p/x/pair.py',
            '/srv/p/y/pair.py',
          ]),
        ),
      );
    });

    test('a denial stops before any search', () async {
      final tree = TreeFiles({'/srv/p/pair.py': 'p'});
      final denying = _Denying(tree);
      await expectLater(
        loadChatFile(
          files: denying,
          resolution: chatResolveFilePath('pair.py', cwd: '/srv/q'),
          roots: ['/srv/q'],
          askedRelative: true,
          search: scope('pair.py', ['/srv/p']),
        ),
        throwsA(
          isA<ChatFileLoadException>().having(
            (e) => e.kind,
            'kind',
            ChatFileErrorKind.forbidden,
          ),
        ),
      );
      expect(tree.listed, isEmpty);
    });

    test('a found file that usually holds secrets still asks first', () async {
      final tree = TreeFiles({'/srv/p/cfg/.env': 'KEY=1'});
      Future<ChatFileContent> load({required bool confirmed}) => loadChatFile(
        files: tree,
        resolution: chatResolveFilePath('.env', cwd: '/srv/q'),
        roots: ['/srv/q'],
        askedRelative: true,
        confirmedSensitive: confirmed,
        search: scope('.env', ['/srv/p']),
      );
      // The relative `.env` is sensitive by name: nothing is read or listed.
      await expectLater(
        load(confirmed: false),
        throwsA(
          isA<ChatFileLoadException>().having(
            (e) => e.kind,
            'kind',
            ChatFileErrorKind.needsConfirmation,
          ),
        ),
      );
      expect(tree.reads, isEmpty);
      expect(tree.listed, isEmpty);
      final content = await load(confirmed: true);
      expect(content.path, '/srv/p/cfg/.env');
      expect(content.sensitive, isTrue);
    });

    test('a bare name with no learned folder is a plain miss', () async {
      final tree = TreeFiles({'/srv/p/pair.py': 'p'});
      await expectLater(
        loadChatFile(
          files: tree,
          resolution: chatResolveFilePath('pair.py', cwd: '/srv/q'),
          roots: ['/srv/q'],
          askedRelative: true,
        ),
        throwsA(
          isA<ChatFileLoadException>()
              .having((e) => e.kind, 'kind', ChatFileErrorKind.notFound)
              .having((e) => e.tried, 'tried', ['/srv/q']),
        ),
      );
      expect(tree.listed, isEmpty);
    });
  });
}

/// Refuses every read, lists like the tree it wraps.
class _Denying implements HermesProjectFilesGateway {
  _Denying(this.inner);

  final TreeFiles inner;

  @override
  bool get projectFilesKnownUnsupported => false;

  @override
  Future<ProjectDirectoryListing> listProjectDirectory(String path) =>
      inner.listProjectDirectory(path);

  @override
  Future<ProjectFilePreview> readProjectFileText(String path) async {
    throw const DesktopControlFailure(
      DesktopControlFailureKind.forbidden,
      code: 403,
    );
  }

  @override
  Future<Uint8List> readProjectFileBytes(String path) =>
      throw UnimplementedError();
}
