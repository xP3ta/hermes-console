// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// PX2a: a connection made by hand is only the Dashboard, like Desktop's one
// URL per connection, and an old {8642, dashboard :9119} connection still
// round-trips unchanged.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:http/http.dart' as http;

import '../c3d/c3d_support.dart';
import '../support/desktop_chat_socket.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('flag on: saved with the Dashboard address and no :8642 request', (
    tester,
  ) async {
    final dash = Dash();
    Dash.current = dash;
    final counter = HostCounter(
      handler: (r) async =>
          http.Response.fromStream(await dash.newClient().send(r)),
    );
    await http.runWithClient(() async {
      final (rig, _) = await connectByHand(tester);
      final saved = rig.manager.getConnections().single;
      expect(saved.gatewayUrl, saved.effectiveDashboardUrl);
      expect(counter.byHost.keys.where((k) => k.endsWith(':8642')), isEmpty);
      expect(counter.byHost, isNotEmpty);
    }, () => counter);
  });

  test('an old {8642, dashboard :9119} connection round-trips unchanged', () {
    final map = <String, dynamic>{
      'id': 'old',
      'label': 'Old',
      'host': '192.168.1.40',
      'port': 8642,
      'dashboard_url': 'http://192.168.1.40:9119',
    };
    final first = jsonEncode(SavedConnection.fromMap(map).toMap());
    final second = jsonEncode(
      SavedConnection.fromMap(
        jsonDecode(first) as Map<String, dynamic>,
      ).toMap(),
    );
    expect(second, first);
    expect(SavedConnection.fromMap(map).port, 8642);
  });
}
