import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/origin_bound_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('the default REST clients cut the TCP connect at the call deadline', () {
    final made = <HttpClient>[];
    final original = OriginBoundHttpClient.dartHttpClientFactory;
    OriginBoundHttpClient.dartHttpClientFactory = () {
      final client = HttpClient();
      made.add(client);
      return client;
    };
    addTearDown(() => OriginBoundHttpClient.dartHttpClientFactory = original);
    ApiClient(baseUrl: 'http://hermes.local:8642', apiKey: 'k');
    DashboardClient(host: 'hermes.local', manualToken: 't');
    expect(made.map((c) => c.connectionTimeout), [
      const Duration(seconds: 15),
      const Duration(seconds: 10),
    ]);
  });

  test('a client substituted by http.runWithClient is kept', () async {
    var hits = 0;
    final mock = MockClient((_) async {
      hits++;
      return http.Response('ok', 200);
    });
    await http.runWithClient(() async {
      final client = OriginBoundHttpClient(null, const Duration(seconds: 1));
      await client.get(Uri.parse('http://hermes.local:8642/x'));
    }, () => mock);
    expect(hits, 1);
  });
}
