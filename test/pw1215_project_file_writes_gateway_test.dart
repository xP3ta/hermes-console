// Wire contract for project file writes: exactly the Dashboard routes Hermes
// Desktop remote mode and the Web Files page use
// (`apps/desktop/src/lib/desktop-fs.ts`, `web/src/lib/api.ts` →
// `hermes_cli/web_routers/files.py`), each gated on its own, and never on a
// read-only connection.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;

class _Captured {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;
  final Map<String, String> fields;
  final List<http.MultipartFile> files;

  _Captured(
    this.method,
    this.url,
    this.headers,
    this.body,
    this.fields,
    this.files,
  );

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
}

typedef _Handler = (int, Object) Function(_Captured request);

class _Transport extends http.BaseClient {
  _Transport(this.handler);
  final _Handler handler;
  final List<_Captured> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var body = '';
    var fields = <String, String>{};
    var files = <http.MultipartFile>[];
    if (request is http.Request) {
      body = request.body;
    } else if (request is http.MultipartRequest) {
      fields = Map.of(request.fields);
      files = List.of(request.files);
    }
    final captured = _Captured(
      request.method,
      request.url,
      request.headers,
      body,
      fields,
      files,
    );
    requests.add(captured);
    final (status, payload) = handler(captured);
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(payload))),
      status,
      headers: {'content-type': 'application/json'},
    );
  }
}

({TuiGatewayClient client, _Transport transport}) _client(
  _Handler handler, {
  bool readOnly = false,
}) {
  final transport = _Transport(handler);
  final client = TuiGatewayClient(
    SavedConnection(
      id: 'pw1215-wire',
      label: 'QA',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'k',
      dashboardUrl: 'http://127.0.0.1:9119',
      readOnly: readOnly,
    ),
    dashboard: DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-test-token',
      httpClientOverride: transport,
    ),
  );
  addTearDown(client.close);
  return (client: client, transport: transport);
}

Matcher _failure(DesktopControlFailureKind kind, {int? code}) =>
    isA<DesktopControlFailure>()
        .having((f) => f.kind, 'kind', kind)
        .having((f) => f.code, 'code', code);

void main() {
  test('creates a folder with POST /api/files/mkdir {path}', () async {
    final h = _client((_) => (200, {'ok': true, 'path': '/srv/repo/new dir'}));

    final created = await h.client.createProjectFolder('/srv/repo/new dir');

    final request = h.transport.requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/api/files/mkdir');
    expect(request.json, {'path': '/srv/repo/new dir'});
    expect(created, '/srv/repo/new dir');
  });

  test('a file already at that path (409) is a rejection', () async {
    final h = _client((_) => (409, {'detail': 'A file already exists'}));
    await expectLater(
      h.client.createProjectFolder('/srv/repo/README.md'),
      throwsA(_failure(DesktopControlFailureKind.rejected, code: 409)),
    );
    expect(
      h.client.projectFileWriteKnownUnsupported(
        ProjectFileWriteAction.createFolder,
      ),
      isFalse,
    );
  });

  test('writes text with POST /api/fs/write-text {path, content}', () async {
    final h = _client(
      (_) => (200, {'ok': true, 'path': '/srv/repo/a.md', 'byteSize': 5}),
    );
    await h.client.writeProjectFileText('/srv/repo/a.md', 'hola\n');
    final request = h.transport.requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/api/fs/write-text');
    expect(request.json, {'path': '/srv/repo/a.md', 'content': 'hola\n'});
  });

  test(
    'uploads with multipart /api/files/upload-stream, never overwriting',
    () async {
      final temp = await Directory.systemTemp.createTemp('pw1215-upload-');
      addTearDown(() => temp.delete(recursive: true));
      final local = File('${temp.path}/photo.jpg')..writeAsBytesSync([1, 2, 3]);
      final h = _client(
        (_) => (200, {'ok': true, 'path': '/srv/repo/photo.jpg'}),
      );

      final stored = await h.client.uploadProjectFile(
        '/srv/repo/photo.jpg',
        localPath: local.path,
        filename: 'photo.jpg',
      );

      final request = h.transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/files/upload-stream');
      expect(request.fields, {
        'path': '/srv/repo/photo.jpg',
        'overwrite': 'false',
      });
      expect(request.files.single.field, 'file');
      expect(request.files.single.filename, 'photo.jpg');
      expect(stored, '/srv/repo/photo.jpg');
    },
  );

  test('deletes with DELETE /api/files {path, recursive: false}', () async {
    final h = _client((_) => (200, {'ok': true, 'path': '/srv/repo/old.txt'}));
    await h.client.deleteProjectEntry('/srv/repo/old.txt');
    final request = h.transport.requests.single;
    expect(request.method, 'DELETE');
    expect(request.url.path, '/api/files');
    expect(request.json, {'path': '/srv/repo/old.txt', 'recursive': false});
  });

  test(
    'a non-empty folder (409) is a rejection, not a recursive retry',
    () async {
      final h = _client((_) => (409, {'detail': 'Could not delete path'}));
      await expectLater(
        h.client.deleteProjectEntry('/srv/repo/lib'),
        throwsA(_failure(DesktopControlFailureKind.rejected, code: 409)),
      );
      expect(h.transport.requests, hasLength(1));
    },
  );

  test('a read-only connection never sends a write', () async {
    final h = _client((_) => (200, {'ok': true}), readOnly: true);
    expect(h.client.projectFileWritesAllowed, isFalse);
    for (final call in <Future<Object?> Function()>[
      () => h.client.createProjectFolder('/srv/repo/x'),
      () => h.client.writeProjectFileText('/srv/repo/x.md', ''),
      () => h.client.deleteProjectEntry('/srv/repo/x.md'),
      () => h.client.uploadProjectFile(
        '/srv/repo/x.bin',
        localPath: '/nonexistent',
        filename: 'x.bin',
      ),
    ]) {
      await expectLater(
        call(),
        throwsA(_failure(DesktopControlFailureKind.forbidden)),
      );
    }
    expect(h.transport.requests, isEmpty);
  });

  test('a missing write route gates only that action', () async {
    final h = _client(
      (r) => r.url.path == '/api/files/mkdir'
          ? (404, {'detail': 'Not Found'})
          : (200, {'ok': true}),
    );
    await expectLater(
      h.client.createProjectFolder('/srv/repo/x'),
      throwsA(_failure(DesktopControlFailureKind.unsupported, code: 404)),
    );
    await expectLater(
      h.client.createProjectFolder('/srv/repo/y'),
      throwsA(_failure(DesktopControlFailureKind.unsupported, code: 404)),
    );
    expect(h.transport.requests, hasLength(1), reason: 'gated after a 404');
    expect(
      h.client.projectFileWriteKnownUnsupported(
        ProjectFileWriteAction.createFolder,
      ),
      isTrue,
    );
    expect(
      h.client.projectFileWriteKnownUnsupported(
        ProjectFileWriteAction.writeText,
      ),
      isFalse,
    );
    await h.client.writeProjectFileText('/srv/repo/z.md', '');
    expect(h.transport.requests, hasLength(2));
  });

  test('delete: 404 means the entry vanished, 405 means no route', () async {
    var status = 404;
    final h = _client((_) => (status, {'detail': 'x'}));
    await expectLater(
      h.client.deleteProjectEntry('/srv/repo/gone'),
      throwsA(_failure(DesktopControlFailureKind.unavailable, code: 404)),
    );
    expect(
      h.client.projectFileWriteKnownUnsupported(ProjectFileWriteAction.delete),
      isFalse,
    );
    status = 405;
    await expectLater(
      h.client.deleteProjectEntry('/srv/repo/x'),
      throwsA(_failure(DesktopControlFailureKind.unsupported, code: 405)),
    );
    expect(
      h.client.projectFileWriteKnownUnsupported(ProjectFileWriteAction.delete),
      isTrue,
    );
  });

  test('403 from the path policy is forbidden', () async {
    final h = _client((_) => (403, {'detail': 'Path outside managed root'}));
    await expectLater(
      h.client.writeProjectFileText('/etc/passwd', ''),
      throwsA(_failure(DesktopControlFailureKind.forbidden, code: 403)),
    );
  });

  test('blank or control-character paths never reach the wire', () async {
    final h = _client((_) => (200, {'ok': true}));
    await expectLater(
      h.client.createProjectFolder('  '),
      throwsA(_failure(DesktopControlFailureKind.rejected)),
    );
    await expectLater(
      h.client.deleteProjectEntry('/srv/a\u0000b'),
      throwsA(_failure(DesktopControlFailureKind.rejected)),
    );
    expect(h.transport.requests, isEmpty);
  });
}
