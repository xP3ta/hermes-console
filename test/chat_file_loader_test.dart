import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/project_files.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/utils/chat_file_path_policy.dart';
import 'package:hermes_android/core/widgets/chat/chat_file_loader.dart';

/// A gateway with a few files; every read is recorded.
class FakeFiles implements HermesProjectFilesGateway {
  FakeFiles({
    Map<String, String>? files,
    this.failures = const {},
    this.hang = false,
    this.served = const {},
    this.binary = const {},
    this.truncated = const {},
    this.images = const {},
  }) : files = files ?? {};

  final Map<String, String> files;
  final Map<String, Object> failures;
  final Map<String, String> served;
  final Set<String> binary;
  final Set<String> truncated;
  final Map<String, Uint8List> images;
  final bool hang;
  final List<String> reads = [];

  @override
  bool get projectFilesKnownUnsupported => false;

  @override
  Future<ProjectDirectoryListing> listProjectDirectory(String path) async =>
      const ProjectDirectoryListing(entries: []);

  @override
  Future<ProjectFilePreview> readProjectFileText(String path) async {
    reads.add(path);
    if (hang) return Completer<ProjectFilePreview>().future;
    final failure = failures[path];
    if (failure != null) throw failure;
    final text = files[path];
    if (text == null) {
      throw const DesktopControlFailure(
        DesktopControlFailureKind.unavailable,
        code: 404,
      );
    }
    return ProjectFilePreview(
      path: served[path] ?? path,
      text: text,
      binary: binary.contains(path),
      truncated: truncated.contains(path),
      byteSize: utf8.encode(text).length,
      mimeType: 'text/plain',
    );
  }

  @override
  Future<Uint8List> readProjectFileBytes(String path) async {
    reads.add(path);
    final failure = failures[path];
    if (failure != null) throw failure;
    return images[path] ??
        (throw const DesktopControlFailure(
          DesktopControlFailureKind.unavailable,
          code: 404,
        ));
  }
}

ChatPathResolution _resolve(
  String raw, {
  String? cwd = '/srv/p',
  List<String> roots = const [],
}) => chatResolveFilePath(raw, cwd: cwd, roots: roots);

Future<ChatFileContent> _load(
  FakeFiles files,
  String raw, {
  String? cwd = '/srv/p',
  List<String> roots = const [],
  bool confirmed = false,
  Duration timeout = const Duration(seconds: 5),
}) => loadChatFile(
  files: files,
  resolution: _resolve(raw, cwd: cwd, roots: roots),
  roots: [?cwd, ...roots],
  askedRelative: !raw.startsWith('/'),
  confirmedSensitive: confirmed,
  timeout: timeout,
);

Future<ChatFileErrorKind> _kind(Future<ChatFileContent> load) async {
  try {
    await load;
  } on ChatFileLoadException catch (e) {
    return e.kind;
  }
  fail('it should have failed');
}

void main() {
  test('an absolute server path is read as it is', () async {
    final files = FakeFiles(
      files: {'/home/ana/artifacts/informe.md': '# Hola\n'},
    );
    final content = await _load(files, '/home/ana/artifacts/informe.md');
    expect(files.reads, ['/home/ana/artifacts/informe.md']);
    expect(utf8.decode(content.bytes), '# Hola\n');
    expect(content.name, 'informe.md');
    expect(content.truncated, isFalse);
    expect(content.sensitive, isFalse);
  });

  test(
    'a path outside the conversation folder is asked, not blocked',
    () async {
      final files = FakeFiles(files: {'/var/log/app/today.log': 'ok'});
      await _load(files, '/var/log/app/today.log', cwd: '/srv/p');
      expect(files.reads, ['/var/log/app/today.log']);
    },
  );

  test(
    'a relative name falls to the next folder only when not found',
    () async {
      final files = FakeFiles(files: {'/srv/q/push.md': 'x'});
      final content = await _load(files, 'push.md', roots: ['/srv/q']);
      expect(files.reads, ['/srv/p/push.md', '/srv/q/push.md']);
      expect(content.path, '/srv/q/push.md');
    },
  );

  test('nowhere it was looked for is «not found»', () async {
    final files = FakeFiles();
    expect(
      await _kind(_load(files, 'push.md', roots: ['/srv/q'])),
      ChatFileErrorKind.notFound,
    );
    expect(files.reads.length, 2);
  });

  test('a denial stops the search: no other folder is tried', () async {
    for (final failure in [
      const DesktopControlFailure(
        DesktopControlFailureKind.forbidden,
        code: 403,
      ),
      const DesktopControlFailure(
        DesktopControlFailureKind.forbidden,
        code: 401,
      ),
    ]) {
      final files = FakeFiles(
        failures: {'/srv/p/a.md': failure},
        files: {'/srv/q/a.md': 'second'},
      );
      expect(
        await _kind(_load(files, 'a.md', roots: ['/srv/q'])),
        ChatFileErrorKind.forbidden,
      );
      expect(files.reads, ['/srv/p/a.md']);
    }
    final rejected = FakeFiles(
      failures: {
        '/srv/p/a.md': const DesktopControlFailure(
          DesktopControlFailureKind.rejected,
          code: 422,
        ),
      },
      files: {'/srv/q/a.md': 'second'},
    );
    expect(
      await _kind(_load(rejected, 'a.md', roots: ['/srv/q'])),
      ChatFileErrorKind.denied,
    );
    expect(rejected.reads, ['/srv/p/a.md']);
  });

  test('too large, an old server and a broken answer say so', () async {
    Future<ChatFileErrorKind> kindOf(DesktopControlFailure failure) =>
        _kind(_load(FakeFiles(failures: {'/srv/p/a.md': failure}), 'a.md'));
    expect(
      await kindOf(
        const DesktopControlFailure(
          DesktopControlFailureKind.unavailable,
          code: 413,
        ),
      ),
      ChatFileErrorKind.tooLarge,
    );
    expect(
      await kindOf(
        const DesktopControlFailure(
          DesktopControlFailureKind.unavailable,
          code: 500,
        ),
      ),
      ChatFileErrorKind.unreachable,
    );
    expect(
      await kindOf(
        const DesktopControlFailure(DesktopControlFailureKind.unsupported),
      ),
      ChatFileErrorKind.unsupported,
    );
    expect(
      await kindOf(
        const DesktopControlFailure(DesktopControlFailureKind.invalidResponse),
      ),
      ChatFileErrorKind.unreachable,
    );
  });

  test('a binary file is not shown', () async {
    final files = FakeFiles(
      files: {'/srv/p/a.bin': '\u0000'},
      binary: {'/srv/p/a.bin'},
    );
    expect(await _kind(_load(files, 'a.bin')), ChatFileErrorKind.binary);
  });

  test('a read that never answers times out', () async {
    final files = FakeFiles(hang: true);
    expect(
      await _kind(
        _load(files, 'a.md', timeout: const Duration(milliseconds: 20)),
      ),
      ChatFileErrorKind.timeout,
    );
  });

  test('what the server cut is marked, and so is the client ceiling', () async {
    final files = FakeFiles(
      files: {
        '/srv/p/a.md': 'corto',
        '/srv/p/big.txt': 'linea\n' * (chatFileMaxTextChars ~/ 6 + 100),
      },
      truncated: {'/srv/p/a.md'},
    );
    expect((await _load(files, 'a.md')).truncated, isTrue);
    final big = await _load(files, 'big.txt');
    expect(big.truncated, isTrue);
    expect(big.bytes.length <= chatFileMaxTextChars, isTrue);
  });

  test('text that is not clean UTF-8 text still shows', () async {
    final files = FakeFiles(files: {'/srv/p/a.txt': 'añb\uFFFDc'});
    final content = await _load(files, 'a.txt');
    expect(utf8.decode(content.bytes, allowMalformed: true), 'añb\uFFFDc');
  });

  test('an image is read as bytes and has a ceiling', () async {
    final files = FakeFiles(
      images: {
        '/srv/p/a.png': Uint8List.fromList([1, 2, 3]),
        '/srv/p/huge.png': Uint8List(chatFileMaxImageBytes + 1),
      },
    );
    expect((await _load(files, 'a.png')).bytes, [1, 2, 3]);
    expect(await _kind(_load(files, 'huge.png')), ChatFileErrorKind.tooLarge);
  });

  group('safety', () {
    test('a path that is refused is never asked', () async {
      final files = FakeFiles();
      for (final raw in [
        'file:///etc/passwd',
        '/srv/a\u0000.md',
        r'C:\x\a.md',
      ]) {
        expect(await _kind(_load(files, raw)), ChatFileErrorKind.badPath);
      }
      expect(
        await _kind(_load(files, '../../../a.md', cwd: '/srv')),
        ChatFileErrorKind.badPath,
      );
      expect(
        await _kind(_load(files, 'a.md', cwd: null)),
        ChatFileErrorKind.noBase,
      );
      expect(files.reads, isEmpty);
    });

    test(
      'a sensitive file asks first and is not read until it is confirmed',
      () async {
        final files = FakeFiles(files: {'/srv/p/.env': 'TOKEN=abc'});
        expect(
          await _kind(_load(files, '.env')),
          ChatFileErrorKind.needsConfirmation,
        );
        expect(files.reads, isEmpty, reason: 'nothing is read before the yes');
        final content = await _load(files, '.env', confirmed: true);
        expect(content.sensitive, isTrue);
        expect(files.reads, ['/srv/p/.env']);
      },
    );

    test('every kind of secret asks, in any folder', () async {
      final files = FakeFiles();
      for (final raw in [
        '/home/a/.ssh/id_ed25519',
        '/srv/server.pem',
        '/home/a/.aws/credentials',
        '/home/a/.netrc',
        'config/credentials.json',
        '/srv/.env.production',
      ]) {
        expect(
          await _kind(_load(files, raw)),
          ChatFileErrorKind.needsConfirmation,
          reason: raw,
        );
      }
      expect(files.reads, isEmpty);
    });

    test(
      'a link that lands on a secret asks, and discards what it read',
      () async {
        final files = FakeFiles(
          files: {'/srv/p/notes.md': 'TOKEN=abc'},
          served: {'/srv/p/notes.md': '/srv/p/.env'},
        );
        expect(
          await _kind(_load(files, 'notes.md')),
          ChatFileErrorKind.needsConfirmation,
        );
      },
    );

    test('a link out of the conversation folders is refused', () async {
      final files = FakeFiles(
        files: {'/srv/p/link.md': 'root:x:0:0'},
        served: {'/srv/p/link.md': '/etc/passwd'},
      );
      expect(await _kind(_load(files, 'link.md')), ChatFileErrorKind.outside);
    });

    test('an absolute path the user was shown is not second-guessed', () async {
      final files = FakeFiles(
        files: {'/opt/x/a.md': 'ok'},
        served: {'/opt/x/a.md': '/data/x/a.md'},
      );
      expect((await _load(files, '/opt/x/a.md')).path, '/opt/x/a.md');
    });

    test('nothing is written: the content lives in memory', () async {
      final files = FakeFiles(files: {'/srv/p/.env': 'TOKEN=abc'});
      final content = await _load(files, '.env', confirmed: true);
      expect(content.bytes, isA<Uint8List>());
      // The loader's API has no file, cache or path to write to.
      expect(content.path, '/srv/p/.env');
    });
  });
}
