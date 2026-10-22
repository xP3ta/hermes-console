import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/utils/api_error.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// What a gateway-hosted Dashboard (Hermes 0.22.3+) serves at `GET /`: the SPA
// bootstrap script without `__HERMES_SESSION_TOKEN__`.
const _withheldIndex =
    '<html><head><script>'
    'window.__HERMES_DASHBOARD_EMBEDDED_CHAT__=true;'
    'window.__HERMES_BASE_PATH__="";'
    'window.__HERMES_AUTH_REQUIRED__=false;'
    '</script></head><body></body></html>';

DashboardClient _client(List<String> requests, String indexBody) {
  DashboardClient.resetSharedPasswordSessionsForTesting();
  final client = DashboardClient(
    host: 'withheld.local',
    port: 9119,
    httpClientOverride: MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      if (request.url.path == '/') {
        return http.Response(indexBody, 200);
      }
      return http.Response('{}', 200);
    }),
  );
  addTearDown(client.close);
  return client;
}

void main() {
  test('a Dashboard that withholds the page token fails with a clear, '
      'specific code', () async {
    final requests = <String>[];
    final client = _client(requests, _withheldIndex);

    await expectLater(
      client.apiGet('sessions'),
      throwsA(
        isA<DashboardAuthException>().having(
          (error) => error.code,
          'code',
          DashboardAuthFailureCode.sessionTokenWithheld,
        ),
      ),
    );
    // Only the page was read: a ticket needs the owner-only control socket
    // (or an OAuth session) that Console cannot reach, so none is requested.
    expect(requests, ['GET /']);
  });

  test('the withheld case is localized in every shipped language', () {
    const error = DashboardAuthException(
      DashboardAuthFailureCode.sessionTokenWithheld,
    );
    for (final locale in Strings.supportedLocales) {
      final strings = lookupStrings(locale);
      final message = localizedApiError(strings, error);
      expect(message, isNotEmpty, reason: '$locale');
      expect(
        message,
        isNot(strings.dashboardAuthLoginRequired),
        reason: '$locale must not reuse the sign-in message',
      );
    }
  });

  test('an unrelated page keeps the generic not-a-Dashboard error', () async {
    final client = _client(<String>[], '<html><body>hello</body></html>');
    await expectLater(
      client.apiGet('sessions'),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Dashboard session token not found'),
        ),
      ),
    );
  });

  test('a page that publishes the token is read exactly as before', () async {
    final requests = <String>[];
    final client = _client(
      requests,
      '<script>window.__HERMES_SESSION_TOKEN__="t0k";'
      'window.__HERMES_AUTH_REQUIRED__=false;</script>',
    );
    final result = await client.apiGet('sessions');
    expect(result, isEmpty);
    expect(requests, ['GET /', 'GET /api/sessions']);
  });
}
