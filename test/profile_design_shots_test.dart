// Profiles list, profile editor and bot card at phone widths, Spanish, dark.
// A layout test (nothing overflows at 320/390/412 dp nor at 2× text); it
// also writes PNGs to `DESIGN_SHOTS_DIR`, or to `build/profile_shots/` when
// that folder exists.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/bot_profile_screen.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/models/profile_pet.dart';
import 'package:hermes_android/core/screens/profile_editor_screen.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/services/bot_profile_client.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/bot_roster_fakes.dart';
import 'support/design_shots.dart';

const _shotKey = ValueKey('profile-shot');

List<AgentProfile> _profiles() => [
  AgentProfile.fromJson({
    'name': 'default',
    'is_default': true,
    'gateway_running': true,
    'model': 'gpt-5.5',
    'provider': 'openai-codex',
    'skill_count': 42,
  }),
  AgentProfile.fromJson({
    'name': 'console-builder',
    'description': 'Compila, prueba y publica Hermes Console',
    'model': 'claude-opus-4.1',
    'provider': 'anthropic',
    'skill_count': 24,
    'ui_meta': {
      'hermes-bots': {'title': 'Console Builder'},
    },
  }),
  AgentProfile.fromJson({
    'name': 'investigador-de-mercados-y-competencia',
    'description': 'Sigue precios, lanzamientos y reseñas de la competencia',
    'model': 'antigravity/gemini-3.6-flash-high',
    'provider': 'omnirouter',
    'skill_count': 7,
  }),
  AgentProfile.fromJson({'name': 'oficina', 'skill_count': 0}),
];

final class _Gateway
    implements
        HermesDesktopProfileAssetsGateway,
        HermesDesktopPetGateway,
        BotModelGateway,
        BotProfileGateway {
  @override
  Stream<TuiGatewayEvent> get events => const Stream.empty();

  @override
  Future<AgentProfileAvatar?> profileAvatar(String profileName) async => null;

  @override
  Future<void> saveProfileBotMeta({
    required String profile,
    String? title,
    String? shape,
    String? colorHex,
    bool? hidden,
    bool? pinned,
    BotVisualIdentity? identity,
  }) async {}

  @override
  Future<void> setProfileAvatar({
    required String profile,
    required String dataUri,
  }) async {}

  @override
  Future<void> clearProfileAvatar(String profile) async {}

  @override
  Future<ProfilePetInfo> profilePetInfo({
    String profile = '',
    String? knownRevision,
  }) async => ProfilePetInfo.disabled;

  @override
  Future<ProfilePetGallery> profilePetGallery({
    String profile = '',
    bool localOnly = false,
  }) async => const ProfilePetGallery(enabled: false, active: '', pets: []);

  @override
  Future<String?> profilePetThumb({
    String profile = '',
    required String slug,
    String url = '',
  }) async => null;

  @override
  Future<ProfilePetSelection> profilePetSelect({
    String profile = '',
    required String slug,
  }) async => ProfilePetSelection(slug: slug);

  @override
  Future<bool> profilePetDisable({String profile = ''}) async => true;

  @override
  Future<DesktopModelCatalog> botModelOptions(String profile) async =>
      DesktopModelCatalog.fromJson({
        'model': 'claude-opus-4.1',
        'provider': 'anthropic',
        'providers': [
          {
            'slug': 'anthropic',
            'name': 'Anthropic',
            'is_current': true,
            'authenticated': true,
            'models': ['claude-opus-4.1', 'claude-sonnet-4.5'],
          },
          {
            'slug': 'openai-codex',
            'name': 'OpenAI Codex',
            'authenticated': true,
            'models': ['gpt-5.5', 'gpt-5.5-mini'],
          },
        ],
      });

  @override
  Future<String?> botReasoning(String profile) async => 'medium';

  @override
  Future<void> setBotReasoning(String profile, String effort) async {}

  @override
  Future<Map<String, dynamic>> describeBotProfile(String profile) async => {};

  @override
  Future<Map<String, dynamic>> configureBotProfile(
    String profile,
    Map<String, dynamic> changes,
  ) async => {
    'ok': true,
    'applied': {'model': true},
  };

  @override
  Future<void> patchBotMetadata(
    String profile,
    Map<String, dynamic> patch, {
    Set<String> remove = const {},
  }) async {}

  @override
  Future<String> duplicateBotProfile(String profile) async => '$profile-2';
}

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  double width = 390,
  double textScale = 1,
}) async {
  await loadDesignFonts();
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir =
      Platform.environment['DESIGN_SHOTS_DIR'] ??
      (Directory('build/profile_shots').existsSync()
          ? 'build/profile_shots'
          : null);
  if (dir == null || dir.isEmpty) return;
  final boundary =
      tester.renderObject(find.byKey(_shotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<Widget> _profilesList() async => ProfilesScreen(
  connection: connection,
  connManager: await manager(),
  rosterRegistry: BotRosterRegistry(),
  clientOverride: FakeProfilesServer().client,
  gatewayProfilesOverride: () async => _profiles(),
);

Widget _editor(_Gateway gateway) => ProfileEditorScreen(
  connection: connection,
  profile: _profiles()[1],
  gateway: gateway,
  petService: ProfilePetService(gateway),
);

Widget _botCard(_Gateway gateway) => BotProfileScreen(
  data: () => BotProfileData(
    profile: _profiles()[1],
    signal: BotFaceSignal.idle,
    roomCount: 2,
    taskCount: 3,
  ),
  modelGateway: gateway,
  profileGateway: gateway,
  machineLabel: 'homelab',
  onChat: () {},
  onRooms: () {},
  onRoutines: () {},
  onSoul: () {},
  onSkills: () {},
  onMemory: () {},
  onTasks: () {},
  onEditIdentity: () {},
);

void main() {
  // The dock the app has.
  setUp(() {
    FeatureFlags.instance.resetForTesting(gestureDock: true);
    GestureDockController.instance.resetForTesting();
  });
  tearDown(() {
    FeatureFlags.instance.resetForTesting();
    GestureDockController.instance.resetForTesting();
  });

  for (final (width, scale) in const [
    (390.0, 1.0),
    (320.0, 1.0),
    (412.0, 1.0),
    (390.0, 2.0),
  ]) {
    final tag = '${width.toInt()}${scale == 1 ? '' : '-x2'}';

    testWidgets('profiles list · $tag', (tester) async {
      await _pump(
        tester,
        await _profilesList(),
        width: width,
        textScale: scale,
      );
      expect(find.text('console-builder'), findsOneWidget);
      final overflow = tester.takeException();
      await _shot(tester, 'profiles-list-$tag');
      expect(overflow, isNull);
    });

    testWidgets('profile editor · $tag', (tester) async {
      await _pump(tester, _editor(_Gateway()), width: width, textScale: scale);
      // The header says «Editar bot» and nothing else; the identifier is in
      // the form, where it is said that it does not change.
      expect(find.text('@console-builder'), findsNothing);
      expect(find.textContaining('@console-builder'), findsOneWidget);
      await _shot(tester, 'profile-editor-$tag');
      // The rows under the identity: model, description, skills.
      await tester.drag(
        find.byKey(const ValueKey('profile-editor-scroll')),
        const Offset(0, -3000),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final overflow = tester.takeException();
      await _shot(tester, 'profile-editor-rows-$tag');
      expect(overflow, isNull);
    });

    testWidgets('bot card · $tag', (tester) async {
      await _pump(tester, _botCard(_Gateway()), width: width, textScale: scale);
      expect(find.text('Console Builder'), findsOneWidget);
      final overflow = tester.takeException();
      await _shot(tester, 'bot-card-$tag');
      expect(overflow, isNull);
    });
  }
}
