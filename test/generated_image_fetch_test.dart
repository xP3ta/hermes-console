import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/generated_image_fetch.dart';

void main() {
  final png = [0x89, 0x50, 0x4e, 0x47, 1, 2, 3];
  final pngUrl = 'data:image/png;base64,${base64Encode(png)}';

  test('loads through /api/media with the rebuilt cache path', () async {
    final calls = <String>[];
    final bytes = await GeneratedImageFetch.fetch(
      'render-1.png',
      apiGet: (endpoint) async {
        calls.add(endpoint);
        return {'data_url': pngUrl};
      },
    );
    expect(bytes, png);
    expect(calls, [
      'media?path=${Uri.encodeQueryComponent('~/.hermes/cache/images/render-1.png')}',
    ]);
  });

  test('falls back to /api/fs/read-data-url with the profile on 403', () async {
    final calls = <String>[];
    final bytes = await GeneratedImageFetch.fetch(
      'render-1.png',
      profile: 'work_bot',
      apiGet: (endpoint) async {
        calls.add(endpoint);
        if (endpoint.startsWith('media?')) {
          throw const DashboardHttpException(403);
        }
        return {'dataUrl': pngUrl};
      },
    );
    expect(bytes, png);
    final path = Uri.encodeQueryComponent('~/.hermes/cache/images/render-1.png');
    expect(calls.last, 'fs/read-data-url?path=$path&profile=work_bot');
  });

  test('the default profile adds no profile query on the fallback', () async {
    final calls = <String>[];
    await GeneratedImageFetch.fetch(
      'a.webp',
      profile: 'default',
      apiGet: (endpoint) async {
        calls.add(endpoint);
        if (endpoint.startsWith('media?')) {
          throw const DashboardHttpException(403);
        }
        return {'dataUrl': 'data:image/webp;base64,${base64Encode(png)}'};
      },
    );
    expect(calls.last, isNot(contains('profile=')));
  });

  test('a missing file (404) is reported without a second request', () async {
    final calls = <String>[];
    await expectLater(
      GeneratedImageFetch.fetch(
        'gone.png',
        apiGet: (endpoint) async {
          calls.add(endpoint);
          throw const DashboardHttpException(404);
        },
      ),
      throwsA(
        isA<DashboardHttpException>().having((e) => e.statusCode, 'status', 404),
      ),
    );
    expect(calls, hasLength(1));
  });

  test('hostile names never reach the server', () async {
    for (final name in const [
      '../secret.png',
      'a/b.png',
      '.hidden.png',
      'x.svg',
      'x.png?y=1',
      '',
      '..png',
    ]) {
      var calls = 0;
      await expectLater(
        GeneratedImageFetch.fetch(
          name,
          apiGet: (_) async {
            calls++;
            return {'data_url': pngUrl};
          },
        ),
        throwsArgumentError,
        reason: name,
      );
      expect(calls, 0, reason: name);
    }
  });

  test('non-image, empty and oversized payloads are refused', () {
    expect(
      () => GeneratedImageFetch.decodeImageDataUrl(
        'data:text/html;base64,${base64Encode(png)}',
        maxBytes: 100,
      ),
      throwsFormatException,
    );
    expect(
      () => GeneratedImageFetch.decodeImageDataUrl(
        'data:image/png;base64,',
        maxBytes: 100,
      ),
      throwsFormatException,
    );
    expect(
      () => GeneratedImageFetch.decodeImageDataUrl(pngUrl, maxBytes: 3),
      throwsFormatException,
    );
    expect(
      () => GeneratedImageFetch.decodeImageDataUrl(null, maxBytes: 100),
      throwsFormatException,
    );
  });
}
