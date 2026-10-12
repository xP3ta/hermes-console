import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion_mood.dart';
import 'package:hermes_android/core/companion/render/companion_preview.dart';
import 'package:hermes_android/core/companion/render/companion_view.dart';
import 'package:hermes_android/core/companion/render/spritesheet_renderer.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/companion/mascotas_screen.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/mission_profile_avatar.dart';
import 'package:hermes_android/core/companion/render/companion_face.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 1x1 opaque PNG: a real raster the avatar path decodes.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(body: Center(child: child)),
);

class _EmptyRepo extends CompanionRepository {
  _EmptyRepo({super.importedRootProvider});
}

MissionProfileAvatarCache _photoCache(List<String> calls) =>
    MissionProfileAvatarCache(
      connectionId: 'c1',
      loader: (name) async {
        calls.add(name);
        return AgentProfileAvatar(
          mimeType: 'image/png',
          bytes: base64Decode(_png),
          width: 1,
          height: 1,
        );
      },
    );

Future<CompanionController> _scoped(
  WidgetTester tester, {
  required String profile,
  MissionProfileAvatarCache? cache,
  CompanionRepository? repository,
  String? selectedSlug,
}) async {
  SharedPreferences.setMockInitialValues({});
  late CompanionController controller;
  await tester.runAsync(() async {
    final prefs = await CompanionPreferences.load();
    if (selectedSlug != null) {
      await prefs.setSelectedSlugFor('c1', profile, selectedSlug);
      await prefs.setSelectedSlug(selectedSlug);
    }
    controller = CompanionController(repository ?? _EmptyRepo(), prefs);
    controller.bindProfileScope(
      resolveScope: () => CompanionScope('c1', profile),
      resolvePetService: (_) => null,
      changes: ValueNotifier<int>(0),
      resolveAvatarCache: cache == null ? null : (_) => cache,
    );
    await controller.init();
  });
  return controller;
}

LivingBotFace _face(WidgetTester tester) =>
    tester.widget<LivingBotFace>(find.byType(LivingBotFace));

void main() {
  tearDown(BotRosterRegistry.shared.clear);

  group('profileFaceFor: avatar > bot face > Hermes face', () {
    test('nothing known → the standard Hermes face', () {
      final choice = profileFaceFor();
      expect(choice.source, ProfileFaceSource.hermesDefault);
      expect(choice.name, kHermesFaceName);
      expect(
        profileFaceFor(profileName: '  ').source,
        ProfileFaceSource.hermesDefault,
      );
    });

    test('a named profile wears its own original face', () {
      final choice = profileFaceFor(profileName: 'ada');
      expect(choice.source, ProfileFaceSource.botFace);
      expect(choice.name, 'ada');
    });

    test('a user-set photo wins when it can be loaded', () {
      const photo = AgentProfile(name: 'ada', hasAvatar: true);
      final cache = _photoCache([]);
      expect(
        profileFaceFor(profile: photo, avatarCache: cache).source,
        ProfileFaceSource.customAvatar,
      );
      // Without a loader the photo cannot be shown: the bot face, not a
      // generic sprite.
      expect(profileFaceFor(profile: photo).source, ProfileFaceSource.botFace);
      // Desktop's PNG backfill of a procedural face is not a photo.
      const backfill = AgentProfile(
        name: 'ada',
        hasAvatar: true,
        botModeUiMeta: {'shape': 'sun'},
      );
      expect(
        profileFaceFor(profile: backfill, avatarCache: cache).source,
        ProfileFaceSource.botFace,
      );
    });
  });

  test('companion moods map onto the original face states', () {
    expect(CompanionMood.idle.faceSignal, BotFaceSignal.idle);
    expect(CompanionMood.offline.faceSignal, BotFaceSignal.idle);
    expect(CompanionMood.thinking.faceSignal, BotFaceSignal.thinking);
    expect(CompanionMood.connecting.faceSignal, BotFaceSignal.thinking);
    expect(CompanionMood.waiting.faceSignal, BotFaceSignal.attention);
    expect(CompanionMood.error.faceSignal, BotFaceSignal.attention);
    expect(CompanionMood.success.faceSignal, BotFaceSignal.speaking);
    expect(CompanionMood.jump.faceSignal, BotFaceSignal.speaking);
  });

  testWidgets('no controller → the standard Hermes face, never a sprite', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const CompanionView(animate: false)));
    expect(find.byType(CompanionFace), findsOneWidget);
    expect(find.byType(SpritesheetRenderer), findsNothing);
    expect(_face(tester).profileName, kHermesFaceName);
    expect(_face(tester).signal, BotFaceSignal.idle);
  });

  testWidgets('no pet chosen → the active profile’s own face and state', (
    tester,
  ) async {
    BotRosterRegistry.shared.publish('c1', 'Lab', const [
      AgentProfile(name: 'ada', botModeUiMeta: {'shape': 'sun'}),
    ]);
    final controller = await _scoped(tester, profile: 'ada');
    await tester.pumpWidget(
      _app(CompanionView(controller: controller, mood: CompanionMood.thinking)),
    );
    final face = _face(tester);
    expect(face.profileName, 'ada');
    expect(face.profile?.botFaceShape, 'blobatar::sun');
    expect(face.signal, BotFaceSignal.thinking);
  });

  testWidgets('a user-set profile photo wins over the procedural face', (
    tester,
  ) async {
    BotRosterRegistry.shared.publish('c1', 'Lab', const [
      AgentProfile(name: 'ada', hasAvatar: true),
    ]);
    final calls = <String>[];
    final controller = await _scoped(
      tester,
      profile: 'ada',
      cache: _photoCache(calls),
    );
    await tester.pumpWidget(_app(CompanionView(controller: controller)));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final avatar = tester.widget<MissionProfileAvatar>(
      find.byType(MissionProfileAvatar),
    );
    expect(avatar.hasAvatar, isTrue);
    expect(avatar.cache, isNotNull);
    expect(calls, ['ada']);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a broken pet manifest falls back to the face without a crash', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('no-spark-pets-'),
    ))!;
    addTearDown(() => root.deleteSync(recursive: true));
    await tester.runAsync(() async {
      final dir = await Directory('${root.path}/broken').create();
      await File('${dir.path}/pet.json').writeAsString('{"name": 5,');
    });
    final controller = await _scoped(
      tester,
      profile: 'ada',
      selectedSlug: 'broken',
      repository: _EmptyRepo(importedRootProvider: () async => root),
    );
    expect(controller.selectedSlug, 'broken');
    expect(controller.activeCompanion, isNull);
    await tester.pumpWidget(_app(CompanionView(controller: controller)));
    expect(tester.takeException(), isNull);
    expect(find.byType(SpritesheetRenderer), findsNothing);
    expect(_face(tester).profileName, 'ada');
  });

  testWidgets('the default pet option previews the profile face', (
    tester,
  ) async {
    final controller = await _scoped(tester, profile: 'ada');
    await tester.pumpWidget(
      _app(CompanionPreview(companion: null, controller: controller)),
    );
    expect(find.byType(CompanionFace), findsOneWidget);
    expect(_face(tester).profileName, 'ada');
  });

  testWidgets('Mascotas: the default option and its preview show the face', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = await _scoped(tester, profile: 'ada');
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: MascotasScreen(controller: controller),
      ),
    );
    await tester.pump();
    expect(find.text('Cara de la app'), findsWidgets);
    final faces = tester
        .widgetList<LivingBotFace>(find.byType(LivingBotFace))
        .map((f) => f.profileName)
        .toList();
    expect(faces, hasLength(2)); // large preview + default option tile
    expect(faces, everyElement('ada'));
  });
}
