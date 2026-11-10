// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The refresh of the models page asks the server to refresh its own model
// cache too: an account that gained models (a subscription upgrade, a new
// release) shows them in the list without waiting for that cache to expire.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';

import 'support/models_server.dart';

void main() {
  late ActiveProfileScope scope;
  setUp(() async => scope = await modelsScope());

  testWidgets('the refresh button asks the server to refresh its cache', (
    tester,
  ) async {
    final server = ModelsServer()
      ..catalog = [
        {
          'slug': 'acme',
          'name': 'Acme',
          'authenticated': true,
          'is_user_defined': false,
          'source': 'built-in',
          'models': ['acme-large'],
        },
      ];
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    expect(server.optionsRefreshes, 0, reason: 'opening reads the cache');

    await tester.tap(find.byIcon(Icons.refresh).first);
    await tester.pumpAndSettle();
    expect(server.optionsRefreshes, 1);
  });
}
