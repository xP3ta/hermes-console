// Shared pieces of the navigation suites (profile hub, Ajustes de la app,
// dock): one connection, a manager over mock preferences, an app shell and a
// roster that has a main profile and a secondary one.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The secondary profile every navigation suite opens while the active one is
/// the main profile: any screen that quietly used the active profile would
/// show or write `default`, which these suites forbid.
const navSecondary = 'secundario';

SavedConnection navConnection({bool readOnly = false}) => SavedConnection(
  id: 'nav-test',
  label: 'Nav QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://hermes.local:9119',
  readOnly: readOnly,
);

/// A manager over empty mock preferences (or [initial]); the active profile
/// is the main one.
Future<ConnectionManager> navManager([
  Map<String, Object> initial = const {},
]) async {
  SharedPreferences.setMockInitialValues({...initial});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

Widget navApp(Widget home, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: home,
);

/// A roster with the main profile and [navSecondary].
BotRosterRegistry navRoster(SavedConnection connection) {
  final registry = BotRosterRegistry();
  registry.publish(connection.id, connection.label, const [
    AgentProfile(name: 'default', isDefault: true, model: 'base-model'),
    AgentProfile(
      name: navSecondary,
      description: 'Revisa pull requests y mantiene el changelog',
      model: 'gpt-5.5',
      provider: 'openai',
      skillCount: 7,
    ),
  ]);
  return registry;
}

void navView(
  WidgetTester tester, {
  Size size = const Size(390, 1800),
  double scale = 1,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}
