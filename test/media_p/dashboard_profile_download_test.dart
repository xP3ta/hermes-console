import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';

/// Loopback server shaped like the real Dashboard: `/api/files/download`
/// serves files, other `/api/*` paths 404 as JSON, and every non-`/api`
/// path (including the Gateway-only `/p/<profile>/` prefix) gets the SPA
/// catch-all: 200 text/html carrying the session token.
class _FakeDashboard {
  _FakeDashboard(this.root);
  final Directory root;
  late final HttpServer server;
  final requests = <Uri>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(req.uri);
      final res = req.response;
      final wanted = req.uri.queryParameters['path'] ?? '';
      if (req.uri.path == '/api/files/download' &&
          wanted.endsWith('/spa-trap.pdf')) {
        // A catch-all page answering where a file was expected.
        res.headers.contentType = ContentType.html;
        res.write(
          '<!doctype html><script>window.__HERMES_SESSION_TOKEN__='
          '"secret-t"</script>',
        );
      } else if (req.uri.path == '/api/files/download') {
        final file = File(req.uri.queryParameters['path'] ?? '');
        if (!file.path.startsWith(root.path) || !file.existsSync()) {
          res.statusCode = 404;
          res.headers.contentType = ContentType.json;
          res.write('{"detail":"not found"}');
        } else {
          res.headers.contentType = file.path.endsWith('.html')
              ? ContentType.html
              : ContentType.binary;
          res.headers.set(
            'content-disposition',
            'attachment; filename="${file.uri.pathSegments.last}"',
          );
          res.add(file.readAsBytesSync());
        }
      } else if (req.uri.path.startsWith('/api/')) {
        res.statusCode = 404;
        res.headers.contentType = ContentType.json;
        res.write('{"detail":"No such API endpoint"}');
      } else {
        res.headers.contentType = ContentType.html;
        res.write(
          '<!doctype html><script>window.__HERMES_SESSION_TOKEN__="secret-t"'
          '</script>',
        );
      }
      await res.close();
    });
  }

  DashboardClient client() => DashboardClient(
    host: '127.0.0.1',
    port: server.port,
    manualToken: 'session-token',
  );
}

const _jpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0];

void main() {
  late Directory root;
  late _FakeDashboard dash;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('media-p-');
    dash = _FakeDashboard(root);
    await dash.start();
  });
  tearDown(() async {
    await dash.server.close(force: true);
    await root.delete(recursive: true);
  });

  String q(String path) =>
      'files/download?path=${Uri.encodeQueryComponent(path)}';

  test(
    'named profile downloads from /api/files/download with profile=',
    () async {
      final img = File('${root.path}/profiles/pi/cache/scratch/poster.jpg')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_jpeg);
      final out = File('${root.path}/out.jpg');
      final client = dash.client();
      addTearDown(client.close);
      await client.apiDownloadToFile(
        q(img.path),
        out,
        maxBytes: 1024,
        profile: 'pi',
      );
      expect(out.readAsBytesSync(), _jpeg);
      expect(dash.requests.single.path, '/api/files/download');
      expect(dash.requests.single.queryParameters['profile'], 'pi');
      expect(dash.requests.any((u) => u.path.startsWith('/p/')), isFalse);
    },
  );

  for (final p in <String?>[null, '', 'default']) {
    test('default profile ($p) adds no profile parameter', () async {
      final img = File('${root.path}/a.jpg')..writeAsBytesSync(_jpeg);
      final out = File('${root.path}/out.jpg');
      final client = dash.client();
      addTearDown(client.close);
      await client.apiDownloadToFile(
        q(img.path),
        out,
        maxBytes: 1024,
        profile: p,
      );
      expect(dash.requests.single.path, '/api/files/download');
      expect(
        dash.requests.single.queryParameters.containsKey('profile'),
        isFalse,
      );
    });
  }

  test(
    'an SPA text/html 200 is a typed 404-like error, nothing on disk',
    () async {
      final out = File('${root.path}/out.pdf');
      final client = dash.client();
      addTearDown(client.close);
      // Simulates a server that lacks the route (SPA catch-all answers).
      await expectLater(
        client.apiDownloadToFile(
          q('${root.path}/spa-trap.pdf'),
          out,
          maxBytes: 1024,
        ),
        throwsA(
          isA<DashboardNotAFileException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
      expect(out.existsSync(), isFalse);
    },
  );

  test(
    'a real .html attachment (Content-Disposition) is still saved',
    () async {
      final html = File('${root.path}/report.html')
        ..writeAsStringSync('<html>ok</html>');
      final out = File('${root.path}/out.html');
      final client = dash.client();
      addTearDown(client.close);
      await client.apiDownloadToFile(q(html.path), out, maxBytes: 1024);
      expect(out.readAsStringSync(), '<html>ok</html>');
    },
  );

  test('a PDF reference is never cached as the SPA page', () async {
    final ref = GeneratedMediaService.referenceFromSource(
      '${root.path}/profiles/pi/spa-trap.pdf',
    )!;
    final cache = await Directory.systemTemp.createTemp('media-p-cache-');
    addTearDown(() => cache.delete(recursive: true));
    final client = dash.client();
    addTearDown(client.close);
    await expectLater(
      GeneratedMediaService.ensureDownloaded(
        'scope',
        ref,
        baseDir: cache,
        fetchServerPathToFile: (path, dest) async {
          await client.apiDownloadToFile(
            q(path),
            dest,
            maxBytes: 1024,
            profile: 'pi',
          );
        },
      ),
      throwsA(isA<DashboardHttpException>()),
    );
    final files = cache.listSync(recursive: true).whereType<File>();
    expect(
      files.where(
        (f) => utf8
            .decode(f.readAsBytesSync(), allowMalformed: true)
            .contains('secret-t'),
      ),
      isEmpty,
    );
  });
}
