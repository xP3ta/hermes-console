// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/origin_bound_http_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';

class _Real extends HttpOverrides {}

Future<void> _runFixtureCommand(
  String executable,
  List<String> arguments,
) async {
  final process = await Process.start(executable, arguments);
  final stdoutDone = process.stdout.drain<void>();
  final stderrDone = process.stderr.drain<void>();
  try {
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 15),
    );
    if (exitCode != 0) throw StateError('TLS fixture command failed');
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 5));
    rethrow;
  } finally {
    await Future.wait([stdoutDone, stderrDone]);
  }
}

Future<SecurityContext> _ephemeralTlsContext() async {
  final temporary = await Directory.systemTemp.createTemp('redirect-tls-');
  try {
    await _runFixtureCommand('chmod', ['700', temporary.path]);
    final key = File('${temporary.path}/key.pem');
    final handle = await key.open(mode: FileMode.write);
    await handle.close();
    await _runFixtureCommand('chmod', ['600', key.path]);
    final certificate = File('${temporary.path}/certificate.pem');
    await _runFixtureCommand('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      key.path,
      '-out',
      certificate.path,
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
    ]);
    // Native TLS owns the loaded key; no PEM strings or key buffers are logged
    // or retained in Dart, and both temporary files are removed before tests.
    return SecurityContext()
      ..useCertificateChain(certificate.path)
      ..usePrivateKey(key.path);
  } finally {
    await temporary.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecurityContext tlsContext;
  setUpAll(() async => tlsContext = await _ephemeralTlsContext());
  test(
    'send boundary disables redirects for injected client and every method',
    () async {
      final inner = MockClient.streaming((request, _) async {
        expect(request.followRedirects, isFalse);
        return http.StreamedResponse(Stream.value([]), 302);
      });
      final client = OriginBoundHttpClient(inner);
      addTearDown(client.close);
      for (final method in ['GET', 'POST', 'PUT', 'DELETE', 'HEAD', 'PATCH']) {
        final request = http.Request(
          method,
          Uri.parse('http://127.0.0.1:9131/api/fixture'),
        );
        expect((await client.send(request)).statusCode, 302);
      }
      final multipart = http.MultipartRequest(
        'POST',
        Uri.parse('http://127.0.0.1:8643/api/fixture'),
      );
      expect((await client.send(multipart)).statusCode, 302);
    },
  );
  test(
    'redirect rejection retains credential for a fresh same-origin request',
    () => HttpOverrides.runZoned(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var hits = 0;
      server.listen((r) async {
        hits++;
        expect(
          r.headers.value('x-hermes-session-token'),
          'synthetic-reuse-token',
        );
        if (hits == 1) {
          r.response.statusCode = 302;
          r.response.headers.set('location', '/must-not-contact');
        } else {
          r.response.write('{"ok":true}');
        }
        await r.response.close();
      });
      final client = DashboardClient(
        host: '127.0.0.1',
        port: server.port,
        manualToken: 'synthetic-reuse-token',
      );
      addTearDown(client.close);
      await expectLater(
        client.apiGet('fixture'),
        throwsA(
          isA<DashboardHttpException>().having(
            (e) => e.statusCode,
            'original status',
            302,
          ),
        ),
      );
      expect(hits, 1);
      expect(await client.apiGet('fixture'), {'ok': true});
      expect(hits, 2);
    }, createHttpClient: _Real().createHttpClient),
  );
  test(
    'authenticated request deadline still covers response body',
    () => HttpOverrides.runZoned(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await server.close(force: true);
      });
      server.listen((r) async {
        await r.drain<void>();
        r.response.write('{"ok":');
        await r.response.flush();
        await release.future;
        r.response.write('true}');
        await r.response.close();
      });
      final client = DashboardClient(
        host: '127.0.0.1',
        port: server.port,
        manualToken: 'synthetic-deadline-token',
      );
      addTearDown(client.close);
      await expectLater(
        client.apiPost('fixture', timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
      );
      release.complete();
    }, createHttpClient: _Real().createHttpClient),
  );
  test('transport policy rejects public cleartext before inner send', () async {
    var hits = 0;
    final client = OriginBoundHttpClient(
      MockClient((_) async {
        hits++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.get(Uri.parse('http://8.8.8.8/api/fixture')),
      throwsArgumentError,
    );
    expect(hits, 0);
    await client.get(Uri.parse('http://127.0.0.1:8643/api/fixture'));
    await client.get(Uri.parse('http://127.0.0.1:9131/api/fixture'));
    expect(hits, 2);
  });
  for (final status in [301, 302, 303, 307, 308]) {
    for (final authenticated in [false, true]) {
      test(
        'TLS downgrade $status authenticated=$authenticated never contacts HTTP receiver',
        () => HttpOverrides.runZoned(() async {
          final context = tlsContext;
          final origin = await HttpServer.bindSecure(
            InternetAddress.loopbackIPv4,
            0,
            context,
          );
          final receiver = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          var originHits = 0, receiverHits = 0;
          addTearDown(() async {
            await origin.close(force: true);
            await receiver.close(force: true);
          });
          origin.listen((r) async {
            originHits++;
            if (authenticated) {
              expect(
                r.headers.value('x-hermes-session-token'),
                'synthetic-tls-token',
              );
            }
            r.response.statusCode = status;
            r.response.headers.set(
              'location',
              'http://127.0.0.1:${receiver.port}/target',
            );
            await r.response.close();
          });
          receiver.listen((r) async {
            receiverHits++;
            r.response.write('{}');
            await r.response.close();
          });
          final raw = HttpClient()
            ..badCertificateCallback = ((cert, host, port) =>
                host == '127.0.0.1' && port == origin.port);
          final dashboard = DashboardClient(
            host: '127.0.0.1',
            port: origin.port,
            useHttps: true,
            manualToken: authenticated ? 'synthetic-tls-token' : null,
            httpClientOverride: IOClient(raw),
          );
          addTearDown(dashboard.close);
          await expectLater(dashboard.apiGet('profiles'), throwsException);
          expect(originHits, 1);
          expect(receiverHits, 0);
        }, createHttpClient: _Real().createHttpClient),
      );
    }
  }
}
