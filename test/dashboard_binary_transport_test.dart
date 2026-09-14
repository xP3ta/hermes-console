import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;

void main() {
  DashboardClient dashboard(http.Client client) => DashboardClient(
    host: 'hermes.local',
    manualToken: 'session-token',
    httpClientOverride: client,
  );

  test(
    'descarga cancela el stream si Content-Length supera el límite',
    () async {
      final tracked = _TrackedStream([
        utf8.encode('body that must never be consumed'),
      ]);
      final transport = _StreamingClient((_, _) async {
        return http.StreamedResponse(tracked.stream, 200, contentLength: 100);
      });
      final client = dashboard(transport);
      addTearDown(client.close);

      await expectLater(
        client.apiDownload('plugins/kanban/attachments/1', maxBytes: 10),
        throwsA(isA<StateError>()),
      );
      expect(tracked.cancelled, isTrue);
    },
  );

  test('descarga cancela al superar el límite durante los chunks', () async {
    final tracked = _TrackedStream([
      [1, 2, 3],
      [4, 5, 6],
    ]);
    final transport = _StreamingClient((_, _) async {
      return http.StreamedResponse(tracked.stream, 200);
    });
    final client = dashboard(transport);
    addTearDown(client.close);

    await expectLater(
      client.apiDownload('plugins/kanban/attachments/1', maxBytes: 5),
      throwsA(isA<StateError>()),
    );
    expect(tracked.cancelled, isTrue);
  });

  test('descarga reintenta una sola vez tras 401 y conserva auth', () async {
    final transport = _StreamingClient((request, call) async {
      expect(request.headers['X-Hermes-Session-Token'], 'session-token');
      if (call == 1) {
        return http.StreamedResponse(Stream.value(const <int>[]), 401);
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode('ok')),
        200,
        contentLength: 2,
        headers: {'content-type': 'text/plain'},
      );
    });
    final client = dashboard(transport);
    addTearDown(client.close);

    final response = await client.apiDownload(
      'plugins/kanban/attachments/1',
      maxBytes: 10,
    );

    expect(transport.calls, 2);
    expect(utf8.decode(response.bytes), 'ok');
    expect(response.contentType, 'text/plain');
  });

  test('error HTTP conserva como máximo 2 KiB de cuerpo', () async {
    final tracked = _TrackedStream([List<int>.filled(4096, 'x'.codeUnitAt(0))]);
    final transport = _StreamingClient((_, _) async {
      return http.StreamedResponse(tracked.stream, 500);
    });
    final client = dashboard(transport);
    addTearDown(client.close);

    try {
      await client.apiDownload(
        'plugins/kanban/attachments/1',
        maxBytes: 25 * 1024 * 1024,
      );
      fail('expected DashboardHttpException');
    } on DashboardHttpException catch (error) {
      expect(error.statusCode, 500);
      expect(utf8.encode(error.body).length, 2048);
    }
    expect(tracked.cancelled, isTrue);
  });

  test(
    'descarga grande escribe por chunks sin construir el body en memoria',
    () async {
      final temp = await Directory.systemTemp.createTemp('dashboard-download-');
      addTearDown(() => temp.delete(recursive: true));
      final target = File('${temp.path}/generated.mp4');
      final transport = _StreamingClient((request, _) async {
        expect(request.headers['X-Hermes-Session-Token'], 'session-token');
        expect(request.url.path, '/p/media-qa/api/files/download');
        expect(request.url.queryParameters['path'], '/tmp/generated.mp4');
        return http.StreamedResponse(
          Stream.fromIterable(<List<int>>[
            utf8.encode('chunk-a'),
            utf8.encode('chunk-b'),
          ]),
          200,
          contentLength: 14,
          headers: {'content-type': 'video/mp4'},
        );
      });
      final client = dashboard(transport);
      addTearDown(client.close);

      final headers = await client.apiDownloadToFile(
        'files/download?path=%2Ftmp%2Fgenerated.mp4',
        target,
        maxBytes: 20,
        profile: 'media-qa',
      );

      expect(await target.readAsString(), 'chunk-achunk-b');
      expect(headers['content-type'], 'video/mp4');
    },
  );

  test('descarga a archivo elimina el parcial si supera el límite', () async {
    final temp = await Directory.systemTemp.createTemp('dashboard-download-');
    addTearDown(() => temp.delete(recursive: true));
    final target = File('${temp.path}/generated.mp4');
    final tracked = _TrackedStream([
      [1, 2, 3],
      [4, 5, 6],
    ]);
    final transport = _StreamingClient((_, _) async {
      return http.StreamedResponse(tracked.stream, 200);
    });
    final client = dashboard(transport);
    addTearDown(client.close);

    await expectLater(
      client.apiDownloadToFile('files/download', target, maxBytes: 5),
      throwsA(isA<StateError>()),
    );
    expect(await target.exists(), isFalse);
    expect(tracked.cancelled, isTrue);
  });

  test(
    'respuesta multipart queda acotada y cancela el stream excesivo',
    () async {
      final temp = await Directory.systemTemp.createTemp('dashboard-upload-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/trace.txt');
      await file.writeAsString('trace');
      final tracked = _TrackedStream([
        List<int>.filled(300 * 1024, 'x'.codeUnitAt(0)),
      ]);
      final transport = _StreamingClient((request, _) async {
        expect(request.headers['X-Hermes-Session-Token'], 'session-token');
        return http.StreamedResponse(tracked.stream, 200);
      });
      final client = dashboard(transport);
      addTearDown(client.close);

      await expectLater(
        client.apiPostMultipartFile(
          'plugins/kanban/tasks/t1/attachments',
          fieldName: 'file',
          filePath: file.path,
          filename: 'trace.txt',
        ),
        throwsA(isA<StateError>()),
      );
      expect(tracked.cancelled, isTrue);
    },
  );

  test('multipart reintenta una sola vez tras 401 sin perder auth', () async {
    final temp = await Directory.systemTemp.createTemp('dashboard-upload-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/trace.txt');
    await file.writeAsString('trace');
    final unauthorized = _TrackedStream([utf8.encode('unauthorized')]);
    final transport = _StreamingClient((request, call) async {
      expect(request.headers['X-Hermes-Session-Token'], 'session-token');
      if (call == 1) {
        return http.StreamedResponse(unauthorized.stream, 401);
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"attachment":{"id":1}}')),
        200,
      );
    });
    final client = dashboard(transport);
    addTearDown(client.close);

    final response = await client.apiPostMultipartFile(
      'plugins/kanban/tasks/t1/attachments',
      fieldName: 'file',
      filePath: file.path,
      filename: 'trace.txt',
    );

    expect(response['attachment'], {'id': 1});
    expect(transport.calls, 2);
    expect(unauthorized.cancelled, isTrue);
  });
}

typedef _SendHandler =
    Future<http.StreamedResponse> Function(http.BaseRequest request, int call);

class _StreamingClient extends http.BaseClient {
  final _SendHandler handler;
  int calls = 0;

  _StreamingClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls++;
    return handler(request, calls);
  }
}

class _TrackedStream {
  late final StreamController<List<int>> _controller;
  final List<List<int>> chunks;
  bool cancelled = false;

  _TrackedStream(this.chunks) {
    _controller = StreamController<List<int>>(
      onListen: () {
        for (final chunk in chunks) {
          _controller.add(chunk);
        }
        _controller.close();
      },
      onCancel: () {
        cancelled = true;
      },
    );
  }

  Stream<List<int>> get stream => _controller.stream;
}
