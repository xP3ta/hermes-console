import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/origin_bound_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  // The Dashboard carries every REST call in production: the Gateway
  // client's 15 s connect cut is unused once a Dashboard is attached.
  test('the default REST client cuts the TCP connect at the call deadline', () {
    final made = <HttpClient>[];
    final original = OriginBoundHttpClient.dartHttpClientFactory;
    OriginBoundHttpClient.dartHttpClientFactory = () {
      final client = HttpClient();
      made.add(client);
      return client;
    };
    addTearDown(() => OriginBoundHttpClient.dartHttpClientFactory = original);
    DashboardClient(host: 'hermes.local', manualToken: 't');
    expect(made.map((c) => c.connectionTimeout), [const Duration(seconds: 10)]);
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
