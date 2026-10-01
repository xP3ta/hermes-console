// Wire contract for the read-only project file browser: the exact Dashboard
// routes Hermes Desktop's remote file tree uses (`apps/desktop/src/lib/
// desktop-fs.ts` → `hermes_cli/web_routers/files.py`), and nothing else.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/project_files.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

typedef _Handler = http.Response Function(http.Request request);

({TuiGatewayClient client, List<http.Request> requests}) _client(
  _Handler handler,
) {
  final requests = <http.Request>[];
  final client = TuiGatewayClient(
    SavedConnection(
      id: 'pf1215-wire',
      label: 'QA',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'gateway-key',
      dashboardUrl: 'http://127.0.0.1:9119',
    ),
    dashboard: DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-test-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request);
        return handler(request);
      }),
    ),
  );
  addTearDown(client.close);
  return (client: client, requests: requests);
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Matcher _failure(DesktopControlFailureKind kind, {int? code}) =>
    isA<DesktopControlFailure>()
        .having((f) => f.kind, 'kind', kind)
        .having((f) => f.code, 'code', code);

void main() {
  test('lists a folder with GET /api/fs/list?path= like Desktop', () async {
    final h = _client(
      (_) => _json({
        'entries': [
          {'name': 'lib', 'path': '/srv/my repo/lib', 'isDirectory': true},
          {'name': 'README.md', 'path': '/srv/my repo/README.md'},
          {'name': '', 'path': '/srv/my repo/x', 'isDirectory': false},
          'junk',
        ],
      }),
    );

    final listing = await h.client.listProjectDirectory('/srv/my repo');

    expect(h.requests, hasLength(1));
    expect(h.requests.single.method, 'GET');
    expect(h.requests.single.url.path, '/api/fs/list');
    expect(h.requests.single.url.queryParameters, {'path': '/srv/my repo'});
    expect(listing.error, isNull);
    expect(
      [for (final e in listing.entries) (e.name, e.isDirectory)],
      [('lib', true), ('README.md', false)],
    );
    expect(listing.entries.first.path, '/srv/my repo/lib');
  });

  test(
    'a listing error code from the server is surfaced, not hidden',
    () async {
      final h = _client((_) => _json({'entries': [], 'error': 'EACCES'}));
      final listing = await h.client.listProjectDirectory('/root');
      expect(listing.entries, isEmpty);
      expect(listing.error, 'EACCES');
    },
  );

  test('reads a file preview with GET /api/fs/read-text?path=', () async {
    final h = _client(
      (_) => _json({
        'binary': false,
        'byteSize': 2048,
        'language': 'markdown',
        'mimeType': 'text/markdown',
        'path': '/srv/repo/README.md',
        'text': '# Hola',
        'truncated': true,
      }),
    );

    final preview = await h.client.readProjectFileText('/srv/repo/README.md');

    expect(h.requests.single.method, 'GET');
    expect(h.requests.single.url.path, '/api/fs/read-text');
    expect(h.requests.single.url.queryParameters, {
      'path': '/srv/repo/README.md',
    });
    expect(preview.text, '# Hola');
    expect(preview.binary, isFalse);
    expect(preview.truncated, isTrue);
    expect(preview.byteSize, 2048);
    expect(preview.mimeType, 'text/markdown');
  });

  test('reads image bytes with GET /api/fs/read-data-url?path=', () async {
    final h = _client(
      (_) => _json({
        'dataUrl': 'data:image/png;base64,${base64Encode([1, 2, 3])}',
      }),
    );
    final bytes = await h.client.readProjectFileBytes('/srv/repo/logo.png');
    expect(h.requests.single.url.path, '/api/fs/read-data-url');
    expect(h.requests.single.url.queryParameters, {
      'path': '/srv/repo/logo.png',
    });
    expect(bytes, [1, 2, 3]);
  });

  test('a backend without /api/fs is remembered as unsupported', () async {
    var status = 404;
    final h = _client((_) => _json({'detail': 'Not Found'}, status));
    await expectLater(
      h.client.listProjectDirectory('/srv/repo'),
      throwsA(_failure(DesktopControlFailureKind.unsupported, code: 404)),
    );
    status = 200;
    await expectLater(
      h.client.listProjectDirectory('/srv/repo'),
      throwsA(_failure(DesktopControlFailureKind.unsupported, code: 404)),
    );
    expect(h.requests, hasLength(1), reason: 'gated after a 404');
  });

  test('a too-large or sensitive file is rejected, not unsupported', () async {
    var status = 413;
    final h = _client((_) => _json({'detail': 'x'}, status));
    await expectLater(
      h.client.readProjectFileText('/srv/repo/big.log'),
      throwsA(_failure(DesktopControlFailureKind.unavailable, code: 413)),
    );
    status = 403;
    await expectLater(
      h.client.readProjectFileText('/srv/repo/.env'),
      throwsA(_failure(DesktopControlFailureKind.forbidden, code: 403)),
    );
    // Neither failure gates the folder listing.
    status = 200;
    expect(h.client.projectFilesKnownUnsupported, isFalse);
  });

  test(
    'a 404 on a file read means the file vanished, not an old server',
    () async {
      var status = 404;
      final h = _client(
        (_) => status == 404
            ? _json({'detail': 'File not found'}, 404)
            : _json({'entries': []}),
      );
      await expectLater(
        h.client.readProjectFileText('/srv/repo/gone.txt'),
        throwsA(_failure(DesktopControlFailureKind.unavailable, code: 404)),
      );
      expect(h.client.projectFilesKnownUnsupported, isFalse);
      status = 200;
      await h.client.listProjectDirectory('/srv/repo');
      expect(h.requests, hasLength(2));
    },
  );

  test('malformed payloads are an invalid response', () async {
    final h = _client((_) => _json({'entries': 'nope'}));
    await expectLater(
      h.client.listProjectDirectory('/srv/repo'),
      throwsA(_failure(DesktopControlFailureKind.invalidResponse)),
    );
  });

  test('blank or control-character paths never reach the wire', () async {
    final h = _client((_) => _json({'entries': []}));
    await expectLater(
      h.client.listProjectDirectory('  '),
      throwsA(_failure(DesktopControlFailureKind.rejected)),
    );
    await expectLater(
      h.client.readProjectFileText('/srv/a\u0000b'),
      throwsA(_failure(DesktopControlFailureKind.rejected)),
    );
    expect(h.requests, isEmpty);
  });

  test('ProjectFsEntry ignores rows without a name or path', () {
    expect(ProjectFsEntry.tryParse({'name': 'a'}), isNull);
    expect(ProjectFsEntry.tryParse({'path': '/a'}), isNull);
    expect(
      ProjectFsEntry.tryParse({'name': 'a', 'path': '/a', 'isDirectory': 1}),
      isA<ProjectFsEntry>().having((e) => e.isDirectory, 'isDirectory', false),
    );
  });
}
