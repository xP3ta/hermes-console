import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final code in [200, 401, 403, 404, 500, null, -1]) {
    testWidgets(
      'Home repeated configured localhost Gateway health $code never owns Android runtime',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        await manager.upsertConnection(
          SavedConnection(
            id: 'local-home-fixture',
            label: 'Local fixture',
            host: '127.0.0.1',
            port: 9119,
            apiKey: 'fixture-key',
            kind: InstanceKind.localhost,
            onDeviceLoopback: true,
          ),
        );
        await manager.setActiveConnection('local-home-fixture');
        var mutations = 0;
        const channel = MethodChannel('hermes/android_apps');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            mutations++;
            return false;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final paths = <String>[];
        var indirectProvision = 0;
        final client = MockClient((request) async {
          paths.add(request.url.path);
          if (request.method == 'POST' && request.url.path == '/v1/runs') {
            if (request.body.contains('hermes_bridge') ||
                request.body.contains('bridge/')) {
              indirectProvision++;
            }
          }
          if (request.url.path == '/health') {
            if (code == -1) {
              throw const SocketException(
                'synthetic refusal',
                osError: OSError('refused', 111),
              );
            }
            if (code == null) throw TimeoutException('synthetic timeout');
            return http.Response('{}', code);
          }
          if (request.url.path == '/api/sessions') {
            return http.Response('{"data":[],"has_more":false}', 200);
          }
          return http.Response('{}', 404);
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('en'),
              theme: AppTheme.fromId('dark'),
              localizationsDelegates: Strings.localizationsDelegates,
              supportedLocales: Strings.supportedLocales,
              home: HomeDashboardScreen(connManager: manager),
            ),
          );
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          for (var pass = 0; pass < 3; pass++) {
            expect(find.text('Start agent'), findsNothing);
            expect(find.text('Agent control panel'), findsNothing);
            expect(paths.where((path) => path.contains('bridge')), isEmpty);
            expect(mutations, 0);
            expect(indirectProvision, 0);
            final refresh = tester.widget<RefreshIndicator>(
              find.byType(RefreshIndicator).first,
            );
            var done = false;
            final future = refresh.onRefresh().whenComplete(() => done = true);
            for (var i = 0; i < 40 && !done; i++) {
              await tester.pump(const Duration(milliseconds: 50));
            }
            await future;
          }
          expect(
            paths.where((path) => path == '/health').length,
            greaterThanOrEqualTo(4),
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 30));
          expect(tester.takeException(), isNull);
        }, () => client);
      },
    );
  }
}
