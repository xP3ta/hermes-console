import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;

/// Session token every [testDashboardClient] sends: with a manual token the
/// client never scrapes the Dashboard page first, so a fake does not have to
/// serve `/`.
const testDashboardToken = 'test-dashboard-token';

/// A Dashboard client on the origin of [baseUrl], answered by [httpClient].
///
/// A closed [DashboardClient] refuses every later read before it is sent.
/// With [answerAfterClose] it keeps sending to [httpClient] after `close()`,
/// as the plain HTTP fake behind a client without a Dashboard did: a test
/// that counts the requests made after a chat was disposed (which closes
/// its client) keeps seeing them.
DashboardClient testDashboardClient({
  String baseUrl = 'http://127.0.0.1:9119',
  http.Client? httpClient,
  bool answerAfterClose = false,
}) {
  final uri = Uri.parse(baseUrl);
  final https = uri.scheme == 'https';
  final host = uri.host;
  final port = uri.hasPort ? uri.port : (https ? 443 : 80);
  return answerAfterClose
      ? _AnsweringAfterCloseDashboardClient(
          host: host,
          port: port,
          useHttps: https,
          httpClient: httpClient,
        )
      : DashboardClient(
          host: host,
          port: port,
          useHttps: https,
          manualToken: testDashboardToken,
          httpClientOverride: httpClient,
        );
}

final class _AnsweringAfterCloseDashboardClient extends DashboardClient {
  _AnsweringAfterCloseDashboardClient({
    required super.host,
    required super.port,
    required super.useHttps,
    http.Client? httpClient,
  }) : super(
         manualToken: testDashboardToken,
         httpClientOverride: httpClient,
       );

  @override
  void close() {}
}

/// An [ApiClient] built the way production builds every one: with its
/// Dashboard attached (see `ids_and_constructors_test.dart`). [httpClient]
/// answers both; the Dashboard sits on [dashboardBaseUrl], by default the
/// same origin as [baseUrl].
///
/// A GET fake written for the legacy transport keeps working for
/// `/api/sessions/<id>/messages` and `/api/sessions/<id>` when it does not
/// look at headers: same paths, same query, `data` or `messages`, the row
/// bare or under `session`. Everything else takes the Dashboard's shapes:
/// the session list (`{sessions, total}`, at most 100 a page), liveness
/// (`/api/status`), named profiles (`?profile=`, never `/p/<profile>/`),
/// deletes (a `mutation-snapshot` read, then `DELETE` answering `{ok}`), the
/// `X-Hermes-Session-Token` header instead of an API-key bearer, a single
/// retry after a 401 and a 10 s deadline.
///
/// [answerAfterClose]: see [testDashboardClient].
ApiClient testApiClient({
  String baseUrl = 'http://127.0.0.1:9119',
  String? dashboardBaseUrl,
  http.Client? httpClient,
  String? connectionId,
  bool answerAfterClose = false,
}) => ApiClient(
  baseUrl: baseUrl,
  apiKey: '',
  connectionId: connectionId,
  httpClient: httpClient,
  profileDashboard: testDashboardClient(
    baseUrl: dashboardBaseUrl ?? baseUrl,
    httpClient: httpClient,
    answerAfterClose: answerAfterClose,
  ),
);
