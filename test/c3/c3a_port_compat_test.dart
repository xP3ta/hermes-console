// C3a drops the "Chat port" field. A connection saved by 1.2.15 with a chat
// port must still save and reopen with the same port, Dashboard port and
// Dashboard URL.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/models/connection.dart';

import '../support/connection_editor_actions.dart';
import '../support/onboarding_fakes.dart';

void main() {
  final cases = <String, SavedConnection>{
    'http 8642': SavedConnection(
      id: 'legacy-http',
      label: 'Legacy',
      host: 'fixture.invalid',
      port: 8642,
      apiKey: '',
    ),
    'https 443': SavedConnection(
      id: 'legacy-https',
      label: 'Legacy',
      host: 'fixture.invalid',
      port: 443,
      apiKey: '',
      useHttps: true,
    ),
  };
  for (final entry in cases.entries) {
    testWidgets('${entry.key}: save and reopen keep the same ports', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final before = entry.value;
      final manager = await onboardingManager();
      await manager.upsertConnection(before);
      await tester.pumpWidget(
        onboardingHost(
          InstanceEditScreen(connManager: manager, initial: before),
        ),
      );
      await tester.pumpAndSettle();
      await openEditorAdvanced(tester);
      expect(find.byKey(const ValueKey('instance-chat-port')), findsNothing);
      await tapOnboarding(tester, 'instance-save');
      final after = manager.getConnections().single;
      expect(after.port, before.port);
      expect(after.dashboardPort, before.dashboardPort);
      expect(after.effectiveDashboardUrl, before.effectiveDashboardUrl);
      expect(after.useHttps, before.useHttps);
    });
  }
}
