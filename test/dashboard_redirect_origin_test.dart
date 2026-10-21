// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';

class _Real extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final status in [301, 302, 303, 307, 308]) {
    for (final topology in ['port', 'host', 'relative', 'same-origin']) {
      for (final operation in [
        'map',
        'list',
        'post',
        'put',
        'delete',
        'multipart',
        'download',
        'download-file',
        'password',
        'discovery',
        'cookie',
        'ticket',
        'gateway',
        'diagnostics',
      ]) {
        test(
          '$operation rejects $status $topology without destination contact',
          () => HttpOverrides.runZoned(() async {
            DashboardClient.resetSharedPasswordSessionsForTesting();
            final origin = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            final receiver = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            final destinations = <String>[];
            final secrets = <String>[];
            var sourceHits = 0;
            addTearDown(() async {
              await origin.close(force: true);
              await receiver.close(force: true);
            });
            Future<void> receive(HttpRequest r) async {
              destinations.add(r.uri.path);
              secrets.add(
                r.headers.value('x-hermes-session-token') ??
                    r.headers.value('authorization') ??
                    r.headers.value('cookie') ??
                    '',
              );
              await utf8.decoder.bind(r).join();
              r.response.write(
                '{"profiles":[],"sessions":[],"ticket":"synthetic-foreign-ticket"}',
              );
              await r.response.close();
            }

            receiver.listen(receive);
            origin.listen((r) async {
              if (r.uri.path == '/target') {
                await receive(r);
                return;
              }
              sourceHits++;
              final body = await utf8.decoder.bind(r).join();
              if (operation == 'diagnostics' && sourceHits == 1) {
                r.response.write('{"version":"synthetic"}');
              } else if (operation == 'cookie' &&
                  r.uri.path == '/auth/password-login') {
                expect(body, contains('synthetic-password'));
                r.response.headers.set(
                  'set-cookie',
                  'hermes_session_at=synthetic-cookie; Path=/',
                );
                r.response.write('{}');
              } else {
                if (operation == 'password') {
                  expect(body, contains('synthetic-password'));
                }
                if (operation == 'post') {
                  expect(body, contains('synthetic-body-secret'));
                }
                r.response.statusCode = status;
                final location = switch (topology) {
                  'port' => 'http://127.0.0.1:${receiver.port}/target',
                  'host' => 'http://localhost:${receiver.port}/target',
                  'relative' => '/target',
                  _ => 'http://127.0.0.1:${origin.port}/target',
                };
                r.response.headers.set('location', location);
                r.response.write('redirect rejected');
              }
              await r.response.close();
            });
            final password = operation == 'password' || operation == 'cookie';
            final dashboard = DashboardClient(
              host: '127.0.0.1',
              port: origin.port,
              manualToken: password || operation == 'discovery'
                  ? null
                  : 'synthetic-page-token',
              basicUser: password ? 'synthetic-user' : null,
              basicPass: password ? 'synthetic-password' : null,
            );
            final gateway = ApiClient(
              baseUrl: 'http://127.0.0.1:${origin.port}',
              apiKey: 'synthetic-gateway-key',
            );
            final diagnostics = ConnectionDiagnostics();
            final dir = await Directory.systemTemp.createTemp(
              'redirect-synthetic-',
            );
            final file = File('${dir.path}/synthetic.txt');
            await file.writeAsString('synthetic-body-secret');
            addTearDown(() => dir.delete(recursive: true));
            addTearDown(dashboard.close);
            addTearDown(gateway.close);
            addTearDown(diagnostics.close);
            Object? error;
            try {
              switch (operation) {
                case 'list':
                  await dashboard.apiGetList('profiles');
                case 'post':
                  await dashboard.apiPost(
                    'profiles',
                    body: {'secret': 'synthetic-body-secret'},
                  );
                case 'put':
                  await dashboard.apiPut(
                    'profiles',
                    body: {'secret': 'synthetic-body-secret'},
                  );
                case 'delete':
                  await dashboard.apiDelete(
                    'profiles',
                    body: {'secret': 'synthetic-body-secret'},
                  );
                case 'multipart':
                  await dashboard.apiPostMultipartFile(
                    'profiles',
                    fieldName: 'file',
                    filePath: file.path,
                    filename: 'synthetic.txt',
                  );
                case 'download':
                  await dashboard.apiDownload('profiles', maxBytes: 2048);
                case 'download-file':
                  await dashboard.apiDownloadToFile(
                    'profiles',
                    File('${dir.path}/output'),
                    maxBytes: 2048,
                  );
                case 'password':
                  await dashboard.authenticateExistingPassword();
                case 'ticket':
                  await dashboard.mintWsTicket();
                case 'gateway':
                  await gateway.getMessagesPage('synthetic-session');
                case 'diagnostics':
                  await diagnostics.probeDashboard(
                    SavedConnection(
                      id: 'synthetic',
                      label: 'synthetic',
                      host: '127.0.0.1',
                      port: origin.port,
                      apiKey: 'synthetic-gateway-key',
                      dashboardUrl: 'http://127.0.0.1:${origin.port}',
                    ),
                    const DashboardSecrets(),
                  );
                default:
                  await dashboard.apiGet('profiles');
              }
            } catch (e) {
              error = e;
            }
            expect(sourceHits, greaterThan(0));
            debugPrint(
              'redirect-receipt operation=$operation status=$status topology=$topology destination=${destinations.length} pageCanary=${secrets.contains('synthetic-page-token')} cookieCanary=${secrets.any((v) => v.contains('synthetic-cookie'))} bearerCanary=${secrets.contains('Bearer synthetic-gateway-key')}',
            );
            expect(
              destinations,
              isEmpty,
              reason:
                  'No redirect recipient may be contacted, even without credentials',
            );
            expect(
              secrets,
              isEmpty,
              reason: 'No credential may reach the recipient',
            );
            if (operation != 'diagnostics') {
              expect(error, isNotNull);
            }
          }, createHttpClient: _Real().createHttpClient),
        );
      }
    }
  }
  test(
    'accepted origin preserves token, password cookie, body and gateway bearer',
    () => HttpOverrides.runZoned(() async {
      DashboardClient.resetSharedPasswordSessionsForTesting();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = <String>[];
      server.listen((r) async {
        final body = await utf8.decoder.bind(r).join();
        if (r.uri.path == '/auth/password-login') {
          expect(body, contains('synthetic-password'));
          r.response.headers.set(
            'set-cookie',
            'hermes_session_at=synthetic-cookie; Path=/',
          );
        } else {
          seen.add(
            r.headers.value('x-hermes-session-token') ??
                r.headers.value('authorization') ??
                r.headers.value('cookie') ??
                '',
          );
          if (r.method == 'POST') {
            expect(body, contains('synthetic-body-secret'));
          }
        }
        r.response.write('{"ok":true,"messages":[],"profiles":[]}');
        await r.response.close();
      });
      final token = DashboardClient(
        host: '127.0.0.1',
        port: server.port,
        manualToken: 'synthetic-page-token',
      );
      final cookie = DashboardClient(
        host: '127.0.0.1',
        port: server.port,
        basicUser: 'synthetic-user',
        basicPass: 'synthetic-password',
      );
      final gateway = ApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'synthetic-gateway-key',
      );
      addTearDown(token.close);
      addTearDown(cookie.close);
      addTearDown(gateway.close);
      await token.apiGet('profiles');
      await token.apiPost(
        'profiles',
        body: {'secret': 'synthetic-body-secret'},
      );
      await cookie.apiGet('profiles');
      await gateway.getMessagesPage('synthetic-session');
      expect(seen, [
        'synthetic-page-token',
        'synthetic-page-token',
        'hermes_session_at=synthetic-cookie',
        'Bearer synthetic-gateway-key',
      ]);
    }, createHttpClient: _Real().createHttpClient),
  );
}
