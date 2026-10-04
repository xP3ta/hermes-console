import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/profile_transfer_service.dart';
import 'package:http/http.dart' as http;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('profile-transfer-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'export confirms exact post, download, share, and cleanup order',
    () async {
      final transport = _Transport((request) {
        if (request.url.path == '/api/profiles/ops/export') {
          expect(request.json, {
            'extra_files': <String, String>{},
            'output': '',
          });
          return _Response.json(200, {
            'ok': true,
            'archive': '/srv/ops.tar.gz',
          });
        }
        if (request.url.path == '/api/files/download') {
          expect(request.url.queryParameters, {'path': '/srv/ops.tar.gz'});
          return _Response.bytes(200, utf8.encode('archive'));
        }
        if (request.url.path == '/api/files') {
          expect(request.json, {'path': '/srv/ops.tar.gz', 'recursive': false});
          return _Response.json(200, {'ok': true});
        }
        return _Response.json(404, {'detail': 'not found'});
      });
      final shared = <String>[];
      final service = _service(transport, temp);

      await service.exportProfile(
        'ops',
        share: (file) async {
          expect(await file.readAsString(), 'archive');
          shared.add(file.path);
          expect(transport.requests.map((request) => request.method), [
            'POST',
            'GET',
          ]);
        },
      );

      expect(shared, hasLength(1));
      expect(await File(shared.single).exists(), isFalse);
      expect(transport.requests.map((request) => request.method), [
        'POST',
        'GET',
        'DELETE',
      ]);
    },
  );

  test('download 403 keeps the server archive and reports its path', () async {
    final transport = _Transport((request) {
      if (request.method == 'POST') {
        return _Response.json(200, {
          'ok': true,
          'archive': '/srv/restricted.tar.gz',
        });
      }
      return _Response.json(403, {'detail': 'outside managed root'});
    });

    await expectLater(
      _service(transport, temp).exportProfile('ops', share: (_) async {}),
      throwsA(
        isA<ProfileTransferException>()
            .having(
              (error) => error.code,
              'code',
              ProfileTransferErrorCode.downloadUnavailable,
            )
            .having(
              (error) => error.serverPath,
              'serverPath',
              '/srv/restricted.tar.gz',
            ),
      ),
    );
    expect(transport.requests.map((request) => request.method), [
      'POST',
      'GET',
    ]);
  });

  test(
    'export 404 reports unsupported and sends no follow-up request',
    () async {
      final transport = _Transport(
        (_) => _Response.json(404, {'detail': 'not found'}),
      );

      await expectLater(
        _service(transport, temp).exportProfile('ops', share: (_) async {}),
        throwsA(
          isA<ProfileTransferException>().having(
            (error) => error.code,
            'code',
            ProfileTransferErrorCode.unsupported,
          ),
        ),
      );
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'import uploads below hermes_home, imports, and always deletes upload',
    () async {
      final local = File('${temp.path}/trusted.tar.gz')
        ..writeAsBytesSync([1, 2, 3]);
      final transport = _importTransport();
      final service = _service(transport, temp, nowMillis: () => 1700000000000);

      final imported = await service.importProfile(local, name: null);

      expect(imported, 'trusted');
      expect(transport.requests.map((request) => request.url.path), [
        '/api/status',
        '/api/files/mkdir',
        '/api/files/upload-stream',
        '/api/profiles/import',
        '/api/files',
      ]);
      final upload = transport.requests[2];
      expect(upload.fields, {
        'path': '/srv/hermes/uploads/1700000000000_trusted.tar.gz',
        'overwrite': 'false',
      });
      expect(upload.files.single.field, 'file');
      expect(upload.files.single.filename, 'trusted.tar.gz');
      expect(transport.requests[3].json, {
        'archive': '/srv/hermes/uploads/1700000000000_trusted.tar.gz',
        'name': null,
      });
      expect(transport.requests[4].json, {
        'path': '/srv/hermes/uploads/1700000000000_trusted.tar.gz',
        'recursive': false,
      });
    },
  );

  test(
    'import preserves a typed name and cleans up after server 400',
    () async {
      final local = File('${temp.path}/trusted.tgz')..writeAsBytesSync([1]);
      final transport = _importTransport(importStatus: 400);

      await expectLater(
        _service(
          transport,
          temp,
          nowMillis: () => 42,
        ).importProfile(local, name: 'restored'),
        throwsA(
          isA<ProfileTransferException>()
              .having(
                (error) => error.code,
                'code',
                ProfileTransferErrorCode.server,
              )
              .having((error) => error.detail, 'detail', 'already exists'),
        ),
      );
      expect(transport.requests[3].json, {
        'archive': '/srv/hermes/uploads/42_trusted.tgz',
        'name': 'restored',
      });
      expect(transport.requests.last.method, 'DELETE');
    },
  );

  test('upload 413 maps to fileTooLarge', () async {
    final local = File('${temp.path}/trusted.tar.gz')..writeAsBytesSync([1]);
    final transport = _importTransport(uploadStatus: 413);

    await expectLater(
      _service(transport, temp).importProfile(local),
      throwsA(
        isA<ProfileTransferException>().having(
          (error) => error.code,
          'code',
          ProfileTransferErrorCode.fileTooLarge,
        ),
      ),
    );
  });

  test('late export result after a profile switch is dropped', () async {
    var current = true;
    final transport = _Transport((request) {
      current = false;
      return _Response.json(200, {'ok': true, 'archive': '/srv/ops.tar.gz'});
    });

    await expectLater(
      _service(
        transport,
        temp,
        isCurrent: () => current,
      ).exportProfile('ops', share: (_) async {}),
      throwsA(
        isA<ProfileTransferException>().having(
          (error) => error.code,
          'code',
          ProfileTransferErrorCode.stale,
        ),
      ),
    );
    expect(transport.requests, hasLength(1));
  });

  test('read-only service sends nothing', () async {
    final transport = _Transport(
      (_) => _Response.json(500, {'detail': 'must not run'}),
    );

    await expectLater(
      _service(
        transport,
        temp,
        readOnly: true,
      ).exportProfile('ops', share: (_) async {}),
      throwsA(
        isA<ProfileTransferException>().having(
          (error) => error.code,
          'code',
          ProfileTransferErrorCode.readOnly,
        ),
      ),
    );
    expect(transport.requests, isEmpty);
  });
}

ProfileTransferService _service(
  _Transport transport,
  Directory temp, {
  bool readOnly = false,
  int Function()? nowMillis,
  bool Function()? isCurrent,
}) => ProfileTransferService(
  client: DashboardClient(
    host: 'hermes.example.test',
    port: 443,
    useHttps: true,
    manualToken: 'test-token',
    httpClientOverride: transport,
  ),
  readOnly: readOnly,
  cacheDirectory: () async => temp,
  nowMillis: nowMillis,
  isCurrent: isCurrent,
);

_Transport _importTransport({int uploadStatus = 200, int importStatus = 200}) {
  return _Transport((request) {
    switch (request.url.path) {
      case '/api/status':
        return _Response.json(200, {'hermes_home': '/srv/hermes'});
      case '/api/files/mkdir':
        return _Response.json(200, {'ok': true});
      case '/api/files/upload-stream':
        return _Response.json(uploadStatus, {
          if (uploadStatus >= 400) 'detail': 'too large',
          if (uploadStatus < 400) 'ok': true,
        });
      case '/api/profiles/import':
        return _Response.json(importStatus, {
          if (importStatus >= 400) 'detail': 'already exists',
          if (importStatus < 400) ...{
            'ok': true,
            'name': 'trusted',
            'path': '/srv/hermes/profiles/trusted',
            'desktop': {'ignored': true},
          },
        });
      case '/api/files':
        return _Response.json(200, {'ok': true});
      default:
        return _Response.json(404, {'detail': 'not found'});
    }
  });
}

final class _CapturedRequest {
  const _CapturedRequest({
    required this.method,
    required this.url,
    required this.body,
    required this.fields,
    required this.files,
  });

  final String method;
  final Uri url;
  final String body;
  final Map<String, String> fields;
  final List<http.MultipartFile> files;

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
}

typedef _TransportHandler = _Response Function(_CapturedRequest request);

final class _Transport extends http.BaseClient {
  _Transport(this.handler);

  final _TransportHandler handler;
  final List<_CapturedRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final captured = _CapturedRequest(
      method: request.method,
      url: request.url,
      body: request is http.Request ? request.body : '',
      fields: request is http.MultipartRequest
          ? Map<String, String>.from(request.fields)
          : const {},
      files: request is http.MultipartRequest
          ? List<http.MultipartFile>.from(request.files)
          : const [],
    );
    requests.add(captured);
    final response = handler(captured);
    return http.StreamedResponse(
      Stream.value(response.bytes),
      response.status,
      headers: response.headers,
      contentLength: response.bytes.length,
    );
  }
}

final class _Response {
  const _Response(this.status, this.bytes, this.headers);

  factory _Response.json(int status, Map<String, dynamic> body) => _Response(
    status,
    utf8.encode(jsonEncode(body)),
    const {'content-type': 'application/json'},
  );

  factory _Response.bytes(int status, List<int> bytes) =>
      _Response(status, bytes, const {'content-type': 'application/gzip'});

  final int status;
  final List<int> bytes;
  final Map<String, String> headers;
}
