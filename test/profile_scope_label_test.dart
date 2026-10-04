import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/bridge_file_editor_screen.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/profile_scope.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

AgentProfile _profile(String name, {bool isDefault = false, String? display}) =>
    AgentProfile.fromJson({
      'name': name,
      'path': '/home/u/.hermes/profiles/$name',
      'is_default': isDefault,
      'display_name': ?display,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const connectionId = 'conn-scope-label';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
  });

  tearDown(() {
    BotRosterRegistry.shared.forget(connectionId);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  Widget app(Widget home) => MaterialApp(
    locale: const Locale('en'),
    theme: AppTheme.fromId('dark'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: home,
  );

  testWidgets('the profile line names the default profile like the '
      'switcher, also when the roster lands later', (tester) async {
    await tester.pumpWidget(
      app(
        const Scaffold(
          body: ProfileScopeLabel(profile: '', connectionId: connectionId),
        ),
      ),
    );
    expect(find.text('Profile: Default'), findsOneWidget);
    BotRosterRegistry.shared.publish(connectionId, 'QA', [
      _profile('default', isDefault: true, display: 'Hermes'),
      _profile('ana'),
    ]);
    await tester.pump();
    expect(find.text('Profile: Hermes'), findsOneWidget);
  });

  testWidgets('a named profile keeps its own name', (tester) async {
    BotRosterRegistry.shared.publish(connectionId, 'QA', [
      _profile('default', isDefault: true, display: 'Hermes'),
      _profile('ana'),
    ]);
    await tester.pumpWidget(
      app(
        const Scaffold(
          body: ProfileScopeLabel(profile: 'ana', connectionId: connectionId),
        ),
      ),
    );
    expect(find.text('Profile: ana'), findsOneWidget);
  });

  testWidgets('config.yaml says which profile it shows', (tester) async {
    BotRosterRegistry.shared.publish(connectionId, 'QA', [
      _profile('default', isDefault: true, display: 'Hermes'),
    ]);
    await tester.pumpWidget(
      app(
        const BridgeFileEditorScreen(
          connectionId: connectionId,
          target: 'config',
          titleLabel: 'config.yaml',
          readOnly: true,
          scopeProfile: '',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('config.yaml'), findsOneWidget);
    expect(find.text('Profile: Hermes'), findsOneWidget);
  });
}
