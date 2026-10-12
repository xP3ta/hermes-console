import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Screens that finish an await after the user already left must not touch
/// their disposed State: the late reply is dropped quietly instead of
/// surfacing an uncaught "setState() called after dispose()" error.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget app(Widget home) => MaterialApp(
    locale: const Locale('es'),
    theme: AppTheme.fromId('dark'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: home,
  );

  for (final failing in [false, true]) {
    testWidgets('external provider probe ends quietly after leaving '
        '(${failing ? 'failed' : 'answered'} probe)', (tester) async {
      final probeGate = Completer<http.Response>();
      var probeCalls = 0;
      final client = MockClient((request) {
        probeCalls++;
        return probeGate.future;
      });
      final connection = SavedConnection(
        id: 'local',
        label: 'Local',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'unused',
        kind: InstanceKind.localhost,
      );

      await tester.pumpWidget(
        app(ExternalProviderScreen(connection: connection)),
      );
      await tester.pump();
      await tester.enterText(
        find.byType(TextField).first,
        'http://192.168.1.5:11434',
      );
      await tester.pump();
      final probe = find.byWidgetPredicate(
        (widget) => widget is ButtonStyleButton && widget.onPressed != null,
      );
      await http.runWithClient(() async {
        await tester.ensureVisible(probe.first);
        await tester.tap(probe.first);
        await tester.pump();
      }, () => client);
      expect(probeCalls, 1);

      // The user leaves while the provider is still answering.
      await tester.pumpWidget(app(const SizedBox()));
      if (failing) {
        probeGate.completeError(const SocketException('unreachable'));
      } else {
        probeGate.complete(http.Response('{"data": []}', 200));
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
    });
  }

  // PackageInfo caches a successful lookup for the isolate: fail first.
  for (final failing in [true, false]) {
    testWidgets('settings version lookup ends quietly after leaving '
        '(${failing ? 'failed' : 'answered'} lookup)', (tester) async {
      const secure = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      const packageInfo = MethodChannel(
        'dev.fluttercommunity.plus/package_info',
      );
      final messenger =
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        secure,
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
      final versionGate = Completer<Map<String, dynamic>>();
      var versionCalls = 0;
      messenger.setMockMethodCallHandler(packageInfo, (call) {
        versionCalls++;
        return versionGate.future;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(secure, null);
        messenger.setMockMethodCallHandler(packageInfo, null);
      });
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final connection = SavedConnection(
        id: 'qa',
        label: 'QA',
        host: '192.168.1.20',
        port: 8642,
        apiKey: 'unused',
        dashboardUrl: 'http://192.168.1.20:9119',
      );

      await tester.pumpWidget(
        app(SettingsScreen(connection: connection, connManager: manager)),
      );
      await tester.pump();
      for (var i = 0; i < 40 && versionCalls == 0; i++) {
        await tester.drag(
          find.byType(Scrollable).first,
          const Offset(0, -600),
          warnIfMissed: false,
        );
        await tester.pump();
      }
      expect(versionCalls, 1);
      // Scrolling the full settings list reports an unrelated ListTile paint
      // diagnostic; only errors raised after leaving matter here.
      while (tester.takeException() != null) {}

      await tester.pumpWidget(app(const SizedBox()));
      if (failing) {
        versionGate.completeError(PlatformException(code: 'unavailable'));
      } else {
        versionGate.complete(<String, dynamic>{
          'appName': 'Hermes',
          'packageName': 'app',
          'version': '1.2.15',
          'buildNumber': '1',
        });
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
    });
  }
}
