// What the in-app browser finds out about an address the WebView handed off
// as a download (#232): a PDF is read for the app's viewer, a page is told
// apart, and anything else is dropped after its headers.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/in_app_browser_download.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final pdf = Uint8List.fromList('%PDF-1.7\n1 0 obj'.codeUnits);

  test('a PDF is read whole, with no credential and no cookie', () async {
    late http.BaseRequest seen;
    final probe = await probeInAppBrowserDownload(
      Uri.parse('https://files.example/a'),
      client: MockClient((request) async {
        seen = request;
        return http.Response.bytes(
          pdf,
          200,
          headers: {'content-type': 'application/pdf'},
        );
      }),
    );
    expect(probe.kind, InAppBrowserDownloadKind.pdf);
    expect(probe.bytes, pdf);
    expect(seen.method, 'GET');
    expect(seen.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
    expect(seen.headers.keys.map((k) => k.toLowerCase()), isNot(contains('cookie')));
  });

  test('a .pdf served as octet-stream is still a PDF by its content', () async {
    final probe = await probeInAppBrowserDownload(
      Uri.parse('https://files.example/report.pdf'),
      client: MockClient(
        (_) async => http.Response.bytes(
          pdf,
          200,
          headers: {'content-type': 'application/octet-stream'},
        ),
      ),
    );
    expect(probe.kind, InAppBrowserDownloadKind.pdf);
  });

  test('something named .pdf that is not one cannot be shown', () async {
    final probe = await probeInAppBrowserDownload(
      Uri.parse('https://files.example/report.pdf'),
      client: MockClient(
        (_) async => http.Response('PK\u0003\u0004', 200, headers: {
          'content-type': 'application/pdf',
        }),
      ),
    );
    expect(probe.kind, InAppBrowserDownloadKind.other);
    expect(probe.bytes, isNull);
  });

  test('an HTML answer is a page; an HTML attachment is not', () async {
    Future<InAppBrowserDownloadProbe> ask(Map<String, String> headers) =>
        probeInAppBrowserDownload(
          Uri.parse('https://site.example/x'),
          client: MockClient(
            (_) async => http.Response('<html>', 200, headers: headers),
          ),
        );
    expect(
      (await ask({'content-type': 'text/html; charset=utf-8'})).kind,
      InAppBrowserDownloadKind.page,
    );
    expect(
      (await ask({
        'content-type': 'text/html',
        'content-disposition': 'attachment; filename="x.html"',
      })).kind,
      InAppBrowserDownloadKind.other,
    );
  });

  test('archives, office files and errors cannot be shown', () async {
    for (final (status, type) in [
      (200, 'application/zip'),
      (
        200,
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      ),
      (404, 'application/pdf'),
    ]) {
      final probe = await probeInAppBrowserDownload(
        Uri.parse('https://files.example/x'),
        client: MockClient(
          (_) async => http.Response('x', status, headers: {'content-type': type}),
        ),
      );
      expect(probe.kind, InAppBrowserDownloadKind.other, reason: '$status $type');
    }
  });

  test('a redirect is followed over http and https only', () async {
    final asked = <Uri>[];
    final probe = await probeInAppBrowserDownload(
      Uri.parse('https://files.example/go'),
      client: MockClient((request) async {
        asked.add(request.url);
        if (request.url.path == '/go') {
          return http.Response('', 302, headers: {'location': '/final.pdf'});
        }
        return http.Response.bytes(
          pdf,
          200,
          headers: {'content-type': 'application/pdf'},
        );
      }),
    );
    expect(probe.kind, InAppBrowserDownloadKind.pdf);
    expect(asked.last, Uri.parse('https://files.example/final.pdf'));

    final refused = await probeInAppBrowserDownload(
      Uri.parse('https://files.example/go'),
      client: MockClient(
        (_) async =>
            http.Response('', 302, headers: {'location': 'file:///etc/hosts'}),
      ),
    );
    expect(refused.kind, InAppBrowserDownloadKind.other);
  });

  test('a network failure is «cannot be shown», never an exception', () async {
    final probe = await probeInAppBrowserDownload(
      Uri.parse('https://files.example/a.pdf'),
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    expect(probe.kind, InAppBrowserDownloadKind.other);
  });
}
