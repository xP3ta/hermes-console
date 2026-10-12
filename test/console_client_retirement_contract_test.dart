// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/gateway_manager_screen.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Android installer runtime and flag cannot be re-enabled', () {
    for (final path in [
      'lib/core/screens/onboarding/local_install_screen.dart',
      'lib/core/screens/onboarding/local_uninstall_screen.dart',
      'lib/core/screens/onboarding/local_agent_setup_screen.dart',
      'lib/core/screens/local_instance_control_screen.dart',
      'lib/core/services/agent_runtime/local_termux_agent_provider.dart',
      'lib/core/services/agent_runtime/provider_catalog.dart',
    ]) {
      expect(
        File(path).existsSync(),
        isFalse,
        reason: '$path is retired, not flag-masked',
      );
    }
    final lib = Directory('lib/core');
    for (final file
        in lib
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final text = file.readAsStringSync();
      expect(
        text,
        isNot(contains('LocalTermuxAgentProvider')),
        reason: file.path,
      );
      expect(text, isNot(contains('kLocalAgentEnabled')), reason: file.path);
      expect(text, isNot(contains('LocalInstallScreen')), reason: file.path);
      expect(
        text,
        isNot(contains('LocalInstanceControlScreen')),
        reason: file.path,
      );
    }
    expect(
      File('android/app/src/full/AndroidManifest.xml').readAsStringSync(),
      isNot(contains('com.termux.permission.RUN_COMMAND')),
    );
  });
  testWidgets(
    'persisted inactive legacy localhost remains visible and activates unchanged',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'local_install_in_progress': true,
      });
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var manager = await ConnectionManager.create(prefs);
      await manager.upsertConnection(
        SavedConnection(
          id: 'legacy-local',
          label: 'Legacy existing server',
          host: '127.0.0.1',
          port: 9119,
          apiKey: 'synthetic-legacy-key',
          kind: InstanceKind.localhost,
          onDeviceLoopback: true,
        ),
      );
      await manager.upsertConnection(
        SavedConnection(
          id: 'explicit-remote',
          label: 'Existing remote server',
          host: 'server.example.test',
          port: 443,
          apiKey: 'synthetic-remote-key',
          useHttps: true,
        ),
      );
      await manager.setActiveConnection('explicit-remote');
      manager = await ConnectionManager.create(prefs);
      await manager.setActiveProfile('legacy-local', 'work_bot');
      final before = manager.getConnections().firstWhere(
        (c) => c.id == 'legacy-local',
      );
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          request.url.path == '/api/sessions'
              ? '{"data":[]}'
              : '{"status":"ok"}',
          200,
        );
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.hermesRedDark,
            locale: const Locale('en'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: GatewayManagerScreen(connManager: manager),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Legacy existing server'), findsOneWidget);
        expect(
          requests.where(
            (uri) =>
                uri.host == '127.0.0.1' &&
                uri.port == 9119 &&
                uri.path == '/health',
          ),
          isNotEmpty,
        );
        await tester.tap(
          find.byKey(const ValueKey('hermes-menu-legacy-local')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Set active'));
        await tester.pumpAndSettle();
        expect(manager.activeConnectionId.value, 'legacy-local');
        final after = manager.getConnections().firstWhere(
          (c) => c.id == 'legacy-local',
        );
        expect(after.toMap(), before.toMap());
        expect(after.apiKey, before.apiKey);
        expect(manager.activeProfileFor('legacy-local'), 'work_bot');
        expect(prefs.getBool('local_install_in_progress'), isTrue);
        await tester.tap(find.text('Legacy existing server'));
        await tester.pumpAndSettle();
        expect(find.byType(InstanceEditScreen), findsOneWidget);
        expect(
          manager
              .getConnections()
              .firstWhere((c) => c.id == 'legacy-local')
              .toMap(),
          before.toMap(),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      }, () => client);
    },
  );
}
