// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';

import 's1/s1_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scheme in ['https', 'http']) {
    for (final explicitPort in [true, false]) {
      test('$scheme OAuth reuse explicitPort=$explicitPort', () async {
        final port = scheme == 'https' ? 443 : 80;
        final base = '$scheme://localhost${explicitPort ? ':$port' : ''}';
        final session = MobileOAuthSession(
          connectionId: 'fixture-owner',
          baseUrl: base,
          accessToken: 'synthetic-oauth-fixture',
          expiresAt:
              DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
          provider: 'fixture-provider',
          userId: 'fixture-user',
        );
        // S1: the store, not the client's memory, is the authority.
        final secure = SecureChannelFake()..install();
        secure.storage['dash_token_fixture-owner'] = session.encode();
        final conn = SavedConnection(
          id: 'fixture-owner',
          label: 'Fixture',
          host: 'localhost',
          port: 8642,
          apiKey: '',
          dashboardUrl: base,
          dashboardAuthMode: AuthMode.sessionToken,
        );
        var requests = 0;
        final client = DashboardClient.forConnection(
          conn,
          secrets: DashboardSecrets(sessionToken: session.encode()),
          httpClientOverride: MockClient((r) async {
            requests++;
            expect(
              r.headers['Authorization'],
              'Bearer synthetic-oauth-fixture',
            );
            return http.Response(jsonEncode({'ok': true}), 200);
          }),
        );
        addTearDown(client.close);
        expect(await client.apiGet('status'), {'ok': true});
        expect(requests, 1);
      });
    }
  }
}
