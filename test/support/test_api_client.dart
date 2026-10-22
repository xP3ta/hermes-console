import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;

/// Session token every [testDashboardClient] sends: with a manual token the
/// client never scrapes the Dashboard page first, so a fake does not have to
/// serve `/`.
const testDashboardToken = 'test-dashboard-token';

/// A Dashboard client on the origin of [baseUrl], answered by [httpClient].
DashboardClient testDashboardClient({
  String baseUrl = 'http://127.0.0.1:9119',
  http.Client? httpClient,
}) {
  final uri = Uri.parse(baseUrl);
  final https = uri.scheme == 'https';
  return DashboardClient(
    host: uri.host,
    port: uri.hasPort ? uri.port : (https ? 443 : 80),
    useHttps: https,
    manualToken: testDashboardToken,
    httpClientOverride: httpClient,
  );
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
/// retry after a 401, a 10 s deadline and no bounded streaming read.
ApiClient testApiClient({
  String baseUrl = 'http://127.0.0.1:9119',
  String? dashboardBaseUrl,
  http.Client? httpClient,
  String? connectionId,
}) => ApiClient(
  baseUrl: baseUrl,
  apiKey: '',
  connectionId: connectionId,
  httpClient: httpClient,
  profileDashboard: testDashboardClient(
    baseUrl: dashboardBaseUrl ?? baseUrl,
    httpClient: httpClient,
  ),
);
