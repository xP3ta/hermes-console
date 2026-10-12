import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/models/companion_presence_level.dart';
import 'package:hermes_android/core/companion/render/spritesheet_renderer.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/home/board/home_board_data.dart';
import 'package:hermes_android/core/home/board/home_board_tiles.dart';
import 'package:hermes_android/core/models/profile_identity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/mission_profile_avatar.dart';
import 'package:hermes_android/core/widgets/profile_face.dart';
import 'package:hermes_android/core/widgets/profile_pet_avatar.dart';
import 'package:shared_preferences/shared_preferences.dart';

Companion _pet(String slug) => Companion(
  slug: slug,
  name: slug,
  author: 'Hermes Console',
  license: 'CC0-1.0',
  spritesheetAsset: 'assets/companions/$slug/spritesheet.webp',
  frameWidth: 192,
  frameHeight: 208,
  cols: 8,
  rows: 9,
  fps: 8,
  states: const {
    CompanionAnimationState.idle: RowSpec(row: 0, frameCount: 8, loop: true),
  },
);

class _Repo extends CompanionRepository {
  @override
  Future<List<Companion>> loadAll() async => [
    _pet('nimbus'),
    _pet('violet'),
    _pet('pixel'),
  ];
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProfileIdentities.instance.reset();
  });
  tearDown(() => ProfileIdentities.instance.reset());

  testWidgets(
    'the same profile pet is used on Home, Bots, cards and the switcher',
    (tester) async {
      final pet = _pet('nimbus');
      ProfileIdentities.instance.connectionId = () => 'c1';
      ProfileIdentities.instance.publish('c1', 'default', pet);
      final cache = MissionProfileAvatarCache(
        connectionId: 'c1',
        loader: (_) async => null,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedDark,
          home: Scaffold(
            body: Column(
              children: [
                MissionProfileAvatar(
                  profileName: 'default',
                  hasAvatar: false,
                  cache: cache,
                ),
                ProfileFace(profileName: 'default', avatarCache: cache),
                const LivingBotFace(
                  profileName: 'default',
                  signal: BotFaceSignal.idle,
                  animate: false,
                  entrance: false,
                ),
                HomeFace(
                  profileName: 'default',
                  data: HomeBoardData(now: DateTime(2026, 10, 12)),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProfilePetAvatar), findsNWidgets(4));
      for (final avatar in tester.widgetList<ProfilePetAvatar>(
        find.byType(ProfilePetAvatar),
      )) {
        expect(avatar.pet, same(pet));
      }
      expect(
        profileIdentityFor(profileName: 'default', connectionId: 'other').kind,
        ProfileIdentityKind.face,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    "a chat's island draws the pet of the profile the chat belongs to, still, "
    'even when another instance or profile is the active one',
    (tester) async {
      final mine = _pet('nimbus');
      final other = _pet('violet');
      // The active connection is c2; the chat belongs to c1.
      ProfileIdentities.instance.connectionId = () => 'c2';
      ProfileIdentities.instance.publish('c1', 'default', mine);
      ProfileIdentities.instance.publish('c2', 'default', other);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedDark,
          home: const Scaffold(
            body: LivingBotFace(
              profileName: 'default',
              connectionId: 'c1',
              signal: BotFaceSignal.idle,
              entrance: false,
              animate: false,
              stateMark: false,
            ),
          ),
        ),
      );
      await tester.pump();
      final avatar = tester.widget<ProfilePetAvatar>(
        find.byType(ProfilePetAvatar),
      );
      expect(avatar.pet, same(mine));
      // Its resting drawing: no clock behind it.
      expect(
        tester
            .widget<SpritesheetRenderer>(find.byType(SpritesheetRenderer))
            .animate,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'migration copies the current pet once; app and profile choices stay independent',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final settings = CompanionPreferences(prefs);
      await settings.setSelectedSlugFor('c1', 'default', 'nimbus');
      final source = CompanionController(
        _Repo(),
        settings,
        publishProfileIdentity: true,
      );
      final changes = ValueNotifier(0);
      var scope = const CompanionScope('c1', 'default');
      source.bindProfileScope(
        resolveScope: () => scope,
        resolvePetService: (_) => null,
        changes: changes,
      );
      await source.init();
      final app = CompanionController(_Repo(), settings, appPet: true);
      await app.initAppFromProfile(source);
      expect(app.activeCompanion?.slug, 'nimbus');
      // The record the app pet came from is not a profile's identity.
      expect(source.selectedSlug, 'nimbus');
      expect(source.activeCompanion, isNull);
      expect(prefs.getString(CompanionPreferences.appSlugKey), 'nimbus');
      await app.select('violet');
      expect(source.selectedSlug, 'nimbus');
      expect(settings.selectedSlugFor('c1', 'default'), 'nimbus');
      await source.select('pixel');
      expect(app.selectedSlug, 'violet');
      // The profile's identity comes from its own stores only.
      expect(ProfileIdentities.instance.pet('c1', 'default'), isNull);
      ProfileIdentities.instance.publish('c1', 'default', _pet('pixel'));
      expect(source.activeCompanion?.slug, 'pixel');
      await app.setVisibilityLevel(CompanionPresenceLevel.off);
      expect(source.enabled, isTrue);
      expect(ProfileIdentities.instance.pet('c1', 'default')?.slug, 'pixel');
      scope = const CompanionScope('c1', 'other');
      changes.value++;
      await Future<void>.delayed(Duration.zero);
      expect(app.selectedSlug, 'violet');
      final restored = CompanionController(_Repo(), settings, appPet: true);
      await restored.initAppFromProfile(source);
      expect(restored.selectedSlug, 'violet');
      expect(restored.enabled, isFalse);
      expect(settings.selectedSlugFor('c1', 'default'), 'pixel');
      source.dispose();
      app.dispose();
      restored.dispose();
      changes.dispose();
    },
  );

  test('a pet switched off in the old Mascotas stays off for the app only; '
      "the profile keeps its pet as its identity", () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = CompanionPreferences(prefs);
    await settings.setSelectedSlugFor('c1', 'default', 'nimbus');
    await settings.setEnabledFor('c1', 'default', false);
    await settings.setPresenceLevel(CompanionPresenceLevel.off);
    final source = CompanionController(
      _Repo(),
      settings,
      publishProfileIdentity: true,
    );
    source.bindProfileScope(
      resolveScope: () => const CompanionScope('c1', 'default'),
      resolvePetService: (_) => null,
      changes: ValueNotifier(0),
    );
    await source.init();
    // Nothing about the app's mascot switches a profile's identity off.
    ProfileIdentities.instance.publish('c1', 'default', _pet('nimbus'));
    expect(source.activeCompanion?.slug, 'nimbus');
    expect(source.presenceLevel.showsStatusPresence, isTrue);
    final app = CompanionController(_Repo(), settings, appPet: true);
    await app.initAppFromProfile(source);
    // What the owner saw for the floating pet is what the app keeps.
    expect(app.selectedSlug, 'nimbus');
    expect(app.enabled, isFalse);
    expect(app.presence, CompanionPresenceLevel.off);
    await app.setVisibilityLevel(CompanionPresenceLevel.full);
    expect(app.enabled, isTrue);
    expect(prefs.getString(CompanionPreferences.appPresenceKey), 'app');
    // The legacy per-profile keys are not touched by the app's choice.
    expect(settings.enabledFor('c1', 'default'), isFalse);
    expect(prefs.getString(CompanionPreferences.presenceLevelKey), 'off');
    source.dispose();
    app.dispose();
  });

  test('the device record Mascotas wrote is never a profile identity: the '
      "profile's own last answer is", () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = CompanionPreferences(prefs);
    // What the old Mascotas left: the app pet's copy of the legacy record.
    await settings.setSelectedSlugFor('c1', '', 'nimbus');
    final controller = CompanionController(
      _Repo(),
      settings,
      publishProfileIdentity: true,
    );
    await controller.init();
    final unknown = await controller.cachedIdentityFor('c1', 'default');
    expect(unknown.known, isFalse, reason: 'the legacy record says nothing');
    expect(unknown.pet, isNull);
    // The profile's own stores said violet (a kitten) at the last run.
    await settings.setIdentitySlugFor('c1', '', 'violet');
    final cached = await controller.cachedIdentityFor('c1', 'default');
    expect(cached.known, isTrue);
    expect(cached.pet?.slug, 'violet');
    // A profile that last answered "no pet" is a known answer.
    await settings.setIdentitySlugFor('c1', '', null);
    final none = await controller.cachedIdentityFor('c1', 'default');
    expect(none.known, isTrue);
    expect(none.pet, isNull);
    controller.dispose();
  });

  testWidgets('identities: the device copy paints first, the server answer '
      'replaces it, an edit re-reads, nothing is drawn before an answer', (
    tester,
  ) async {
    final ids = ProfileIdentities.instance;
    ids.connectionId = () => 'c1';
    var serverPet = _pet('violet');
    var serverUp = true;
    ids.cacheReader = (c, p) async => (known: true, pet: _pet('nimbus'));
    ids.loader = (c, p) async =>
        serverUp ? (known: true, pet: serverPet) : (known: false, pet: null);
    ids.requestAfterPaint('c1', 'default');
    // Nothing is known, nothing is drawn, until the first frame is done.
    expect(ids.pet('c1', 'default'), isNull);
    expect(ids.isKnown('c1', 'default'), isFalse);
    final seen = <String?>[];
    ids.addListener(() => seen.add(ids.pet('c1', 'default')?.slug));
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    await tester.pumpWidget(const SizedBox());
    await settle();
    expect(seen, ['nimbus', 'violet'], reason: 'cache first, then the server');
    expect(ids.isKnown('c1', 'default'), isTrue);
    // The profile is edited: the same read again, no restart.
    serverPet = _pet('pixel');
    ids.refresh('c1');
    await settle();
    expect(ids.pet('c1', 'default')?.slug, 'pixel');
    // The server unreachable keeps what is known.
    serverUp = false;
    ids.refresh('c1');
    await settle();
    expect(ids.pet('c1', 'default')?.slug, 'pixel');
    ids.reset();
  });

  testWidgets("another profile's chat draws its own identity, not the main "
      "profile's", (tester) async {
    ProfileIdentities.instance.connectionId = () => 'c1';
    ProfileIdentities.instance.publish('c1', 'default', _pet('nimbus'));
    ProfileIdentities.instance.publish('c1', 'astra', _pet('violet'));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        home: const Scaffold(
          body: Column(
            children: [
              LivingBotFace(
                profileName: 'astra',
                connectionId: 'c1',
                signal: BotFaceSignal.idle,
                animate: false,
                entrance: false,
              ),
              LivingBotFace(
                profileName: 'default',
                connectionId: 'c1',
                signal: BotFaceSignal.idle,
                animate: false,
                entrance: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widgetList<ProfilePetAvatar>(find.byType(ProfilePetAvatar))
          .map((a) => a.pet.slug),
      ['violet', 'nimbus'],
    );
    ProfileIdentities.instance.reset();
  });
}
