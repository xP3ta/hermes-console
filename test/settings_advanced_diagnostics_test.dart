// Settings › Advanced is ONE screen and Diagnostics is an entry inside it.
// Nothing of Diagnostics is read when Settings opens.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/screens/advanced_settings_screen.dart';
import 'package:hermes_android/core/screens/server_diagnostics_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_config_repository.dart';
import 'package:hermes_android/core/settings/settings_deep_link.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'capabilities/capabilities_fakes.dart';

final class _ConfigStore implements ServerConfigStore {
  @override
  bool get isWritable => true;

  @override
  Future<Map<String, dynamic>> readConfig() async => {};

  @override
  Future<Map<String, dynamic>> readSchema() async => {
    'fields': {
      'timezone': {'type': 'string'},
    },
  };

  @override
  Future<Object?> save(String path, Object? value) async => value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  tearDown(() {
    SettingsDeepLink.pending.value = null;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  // Building the "Data" block of Settings trips a framework assertion about a
  // `ListTile` inside a `DecoratedBox`. It happens on the base too; only that
  // message is let through, anything else still fails the test.
  void letKnownAssertionThrough(WidgetTester tester) {
    final error = tester.takeException();
    if (error == null) return;
    expect(
      error.toString(),
      contains('ListTile background color or ink splashes may be invisible'),
    );
  }

  Finder advancedRow() => find.byWidgetPredicate(
    (widget) => widget is HermesNavRow && widget.title == 'Avanzado',
  );

  Future<void> pumpSettings(WidgetTester tester, ScriptedRest rest) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final connection = SavedConnection(
      id: 'qa-adv-diag',
      label: 'QA',
      host: 'hermes.example.test',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'http://hermes.example.test:9119',
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SettingsScreen(
          connection: connection,
          connManager: manager,
          advancedStoreFor: (profile, {required writable}) => _ConfigStore(),
          advancedRepositoryFor: (profile) => CapabilitiesRepository(
            rest: rest,
            profile: profile,
            sleep: (_) async {},
            actionPollInterval: Duration.zero,
          ),
        ),
      ),
    );
    await tester.pump();
    letKnownAssertionThrough(tester);
    await tester.pump(const Duration(milliseconds: 50));
    letKnownAssertionThrough(tester);
    await tester.scrollUntilVisible(
      advancedRow(),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    letKnownAssertionThrough(tester);
  }

  Future<void> openAdvanced(WidgetTester tester) async {
    await tester.tap(advancedRow());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  ScriptedRest server() => ScriptedRest()
    ..gets['health'] = {'ok': true, 'version': '1'}
    ..gets['health/idle'] = {'ok': true, 'idle': true}
    ..gets['actions/doctor/status'] = {
      'name': 'doctor',
      'running': false,
      'exit_code': 0,
      'lines': <String>[],
    };

  testWidgets('Settings › Advanced opens one screen that lists Diagnostics', (
    tester,
  ) async {
    await pumpSettings(tester, server());
    await openAdvanced(tester);

    expect(find.byType(AdvancedSettingsScreen), findsOneWidget);
    final s = Strings.of(tester.element(find.byType(AdvancedSettingsScreen)));
    expect(
      find.descendant(
        of: find.byType(AdvancedSettingsScreen),
        matching: find.text(s.sd1215Diagnostics),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(s.sd1215Diagnostics));
    await tester.pumpAndSettle();
    expect(find.byType(ServerDiagnosticsScreen), findsOneWidget);
  });

  testWidgets('Settings makes no diagnostics call, the Advanced screen does', (
    tester,
  ) async {
    final rest = server();
    await pumpSettings(tester, rest);
    await tester.pump(const Duration(seconds: 30));
    letKnownAssertionThrough(tester);

    expect(rest.calls, isEmpty, reason: 'nothing before the row is tapped');

    await openAdvanced(tester);
    expect(rest.calls, isNotEmpty, reason: 'the probe belongs to Advanced');
  });
}
