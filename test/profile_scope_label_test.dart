import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
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

  testWidgets('the default profile is not named: the title stands alone', (
    tester,
  ) async {
    expect(
      ProfileScopeLabel.badgeFor(profile: '', connectionId: connectionId),
      isNull,
    );
    expect(
      ProfileScopeLabel.badgeFor(
        profile: 'default',
        connectionId: connectionId,
      ),
      isNull,
    );
    await tester.pumpWidget(
      app(
        const Scaffold(
          body: ProfileScopeLabel(profile: '', connectionId: connectionId),
        ),
      ),
    );
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('a named profile is named like the switcher names it, also '
      'when the roster lands later', (tester) async {
    BotRosterRegistry.shared.publish(connectionId, 'QA', const []);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ProfileScopeLabel.badgeFor(
            profile: 'ana',
            connectionId: connectionId,
          ),
        ),
      ),
    );
    expect(find.text('ana'), findsOneWidget);
    expect(tester.getSemantics(find.text('ana')).label, 'Profile: ana');
    BotRosterRegistry.shared.publish(connectionId, 'QA', [
      _profile('default', isDefault: true, display: 'Hermes'),
      _profile('ana', display: 'Ana B.'),
    ]);
    await tester.pump();
    expect(find.text('Ana B.'), findsOneWidget);
    expect(find.text('Hermes'), findsNothing);
  });
}
