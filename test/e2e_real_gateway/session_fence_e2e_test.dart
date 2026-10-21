// Real-gateway E2E: archive, pin, rename and delete against a real Hermes
// Dashboard that refuses unfenced writes. Skipped without HERMES_E2E_*.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io' show Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/real_gateway.dart';

final _env = E2eEnv.current;
// Set by tool/e2e/run_local.sh when the Hermes under test descends from 22063fc0.
final _fence = Platform.environment['HERMES_E2E_FENCE'] == '1';

void main() {
  useRealNetwork();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'archive, pin, rename and delete commit against a fenced Dashboard',
    () async {
      final phone = E2eConsole(_env);
      final dashboard = phone.dashboard();
      addTearDown(() async {
        dashboard.close();
        await phone.close();
      });
      // A seeded session, resumed as the phone opens a chat: Hermes' owner
      // binds the row to a runtime, so the Dashboard can mutate it.
      const id = 'e2e-chat-01';
      final chat = phone.open(id);
      await chat.loadMessages();
      await waitFor(
        () => chat.desktopRuntimeSessionId != null,
        what: 'runtime attach of $id',
      );

      await expectLater(
        dashboard.apiPatch('sessions/$id', body: {'pinned': true}),
        throwsA(
          isA<DashboardHttpException>()
              .having((e) => e.statusCode, 'status', 409)
              .having((e) => e.body, 'body', contains('client_upgrade')),
        ),
      );

      final pin = await patchDashboardSessionState(dashboard, id, {
        'pinned': true,
      }, null);
      expect(pin['ok'], isTrue);
      final rename = await patchDashboardSessionState(dashboard, id, {
        'title': 'fenced title',
      }, null);
      expect(rename['ok'], isTrue);
      final archive = await patchDashboardSessionState(dashboard, id, {
        'archived': true,
        'pinned': false,
      }, null);
      expect(archive['ok'], isTrue);

      final deleted = await deleteDashboardSession(dashboard, id, null);
      expect(deleted['ok'], isTrue);
      final again = await deleteDashboardSession(dashboard, id, null);
      expect(again['already_absent'], isTrue);
    },
    skip:
        _env.skipReason ??
        (_fence ? null : 'needs Hermes >= 22063fc0 (mutation fence)'),
  );
}
