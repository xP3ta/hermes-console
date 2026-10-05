// A fast fling to the bottom of Settings must come to rest. The app scrolls
// with bouncing physics, so at the bottom a section near the top edge of the
// lazy list's cache was disposed and rebuilt over and over: each rebuild
// re-ran its async check and changed its height, which moved the scroll
// position, which pushed the section out of the cache and back in again.
// On a Pixel 9 Pro the screen kept drawing frames at full CPU for as long as
// it stayed there.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/terminal_availability.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/scroll_behavior.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every request waits like a slow phone network and then fails, so each
/// section spends a while in its "checking" state, as it does on a device.
class _SlowOfflineHttp extends HttpOverrides {
  int requests = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _SlowClient(this);
}

class _SlowClient implements HttpClient {
  _SlowClient(this.owner);

  final _SlowOfflineHttp owner;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (!invocation.isMethod) return null;
    if (invocation.memberName == #close) return null;
    owner.requests++;
    return Future<HttpClientRequest>.delayed(
      const Duration(seconds: 3),
      () => throw const SocketException('offline'),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _SlowOfflineHttp http;

  setUp(() {
    http = _SlowOfflineHttp();
    HttpOverrides.global = http;
    SharedGatewayPool.debugDefaultLinger = Duration.zero;
    TerminalAvailability.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  tearDown(() {
    HttpOverrides.global = null;
    SharedGatewayPool.debugDefaultLinger = null;
  });

  // Several phone heights: which section sits on the cache edge at the
  // bottom depends on the viewport, and the loop needs one that changes.
  for (final height in [830.0, 840.0, 850.0, 860.0, 870.0, 880.0]) {
    testWidgets('a fast fling to the bottom comes to rest (viewport $height)', (
      tester,
    ) async {
      tester.view.physicalSize = Size(427, height) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final connection = SavedConnection(
        id: 'fling-settles',
        label: 'QA',
        host: 'hermes.example.test',
        port: 8642,
        apiKey: 'test-key',
        dashboardUrl: 'http://hermes.example.test:9119',
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          scrollBehavior: const MomentumScrollBehavior(),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: SettingsScreen(connection: connection, connManager: manager),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      while (tester.takeException() != null) {}

      final list = find.byType(Scrollable).first;
      final position = tester.state<ScrollableState>(list).position;
      for (var k = 0; k < 3; k++) {
        await tester.fling(list, const Offset(0, -900), 12000);
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }
      while (tester.takeException() != null) {}

      // Precondition: the fling really reached the bottom of Settings.
      expect(find.text('acerca de'), findsOneWidget);

      final requestsBefore = http.requests;
      final offsets = <double>{};
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        offsets.add(position.pixels);
      }
      expect(
        offsets.length,
        1,
        reason: 'the list must stand still at the bottom, it moved: $offsets',
      );
      expect(
        http.requests - requestsBefore,
        0,
        reason: 'no section may be rebuilt and re-check the server at rest',
      );

      // Once the slow checks have answered nothing is left animating.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      while (tester.takeException() != null) {}

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });
  }
}
